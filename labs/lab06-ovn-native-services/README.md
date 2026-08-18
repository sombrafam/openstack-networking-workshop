
# Lab 6 — OVN Native Services: DHCP, DNS & Metadata

| | |
|---|---|
| **Tier** | 3 – OVN |
| **Duration** | ~45 minutes |
| **Prerequisites** | Labs 1–5 completed; Lab 5 topology still up |
| **Builds on** | Lab 5 — OVN Basics |

---

## 1. Objective

In Lab 5 you built a working OVN network — but you **cheated**. Every IP and
MAC address was typed in by hand, both in the OVN logical port *and* inside the
namespace. A real cloud cannot work that way: instances boot from a generic
image and must *discover* their identity (IP, gateway, DNS, hostname,
SSH keys) over the wire. That discovery is the job of three OVN-native
services that Lab 5 skipped:

- **DHCP** — hands out IP, gateway, MTU, and DNS to a booting port.
- **DNS** — resolves instance and service names without an external resolver.
- **Metadata** — the magic `169.254.169.254` endpoint cloud-init queries for
  hostname, SSH keys, and user-data.

By the end of this lab you will be able to:

- Replace the hardcoded namespace IPs from Lab 5 with **OVN-native DHCPv4**.
- Add **DHCPv6** and understand the SLAAC vs. stateful-DHCPv6 choice.
- Use **dynamic address assignment** (`dynamic`) and let OVN pick the IP.
- Serve internal name resolution with **OVN DNS records**.
- Explain and demonstrate the **metadata** data-path (`localport` +
  `169.254.169.254`) and how `cloud-init` reaches Nova.
- Map every one of these to its **Neutron agent** equivalent and explain why
  OVN moved them out of `dnsmasq` and into logical flows.

---

## 2. Background & Concepts

### 2.1 What Lab 5 hardcoded — and why that doesn't scale

In Lab 5 you ran, for each namespace:

```bash
ip netns exec ns-a ip addr add 10.0.1.10/24 dev veth-a
ip netns exec ns-a ip route add default via 10.0.1.1
```

and separately told OVN the same thing:

```bash
ovn-nbctl lsp-set-addresses ls1-port1 "aa:bb:cc:00:00:01 10.0.1.10"
```

The information lives in **two places** and you maintain it by hand. In a real
cloud the guest image is generic — it has no idea what IP it should use. The
fabric must *tell* it. That is exactly what DHCP, DNS, and metadata do.

### 2.2 OVN-native DHCP — no `dnsmasq` on the data path

Legacy ML2/OVS Neutron ran a **`dnsmasq` process per network**, living in a
`qdhcp-<net>` namespace on the network node. Every DHCP DISCOVER traveled all
the way to that process.

OVN does it differently. DHCP is a **logical flow**:

```
  ┌────────────────────────────────────────────────────────────┐
  │ DHCP_Options row (NB DB):                                  │
  │   cidr   = 10.0.1.0/24                                     │
  │   options= router, server_id, server_mac, lease_time, dns  │
  └───────────────────────────┬────────────────────────────────┘
                              │ attached to a port via
                              │ lsp-set-dhcpv4-options
                              ▼
  ovn-northd compiles a "put_dhcp_opts" logical flow that the
  *local* ovn-controller answers — the DISCOVER never leaves br-int.
```

The DHCP server is **distributed**: every chassis answers locally, in OVS
flows, with zero round-trips to a central process. There is no `qdhcp`
namespace and no `dnsmasq`.

A `DHCP_Options` row carries, at minimum:

| Option | Meaning | Neutron source |
|--------|---------|----------------|
| `server_id` | DHCP server IP (usually the subnet gateway) | subnet gateway |
| `server_mac` | MAC the offer comes from | OVN-generated |
| `lease_time` | Lease duration in seconds | `dhcp_lease_duration` |
| `router` | Default gateway pushed to the client | subnet `gateway_ip` |
| `dns_server` | DNS resolver(s) | `dns_nameservers` |
| `mtu` | Path MTU (overlay-aware!) | `path_mtu` |

### 2.3 Dynamic addressing — let OVN own the IPAM

Instead of `"<mac> <ip>"`, a port can be set to:

```bash
ovn-nbctl lsp-set-addresses ls1-port1 "aa:bb:cc:00:00:01 dynamic"
# or fully dynamic (OVN picks the MAC too):
ovn-nbctl lsp-set-addresses ls1-port1 dynamic
```

OVN then allocates an IP from the switch's `other_config:subnet` /
`exclude_ips` range and records it in `dynamic_addresses`. This is OVN acting
as the **IPAM** (IP Address Management) authority — the same role Neutron's
IPAM driver plays.

### 2.4 OVN DNS

OVN can answer DNS queries directly in logical flows via `DNS` records
attached to a logical switch:

```
  DNS record:  "vm-a.lab.local" → 10.0.1.10
       │ attached to ls1 via   ovn-nbctl set Logical_Switch ls1 dns_records=<uuid>
       ▼
  put_dns_opts logical flow answers A/AAAA/PTR locally on br-int.
```

This is how Neutron's **internal DNS** (`dns_domain`, port `dns_name`) is
served when ML2/OVN is in use — again, no `dnsmasq`.

### 2.5 Metadata — the `169.254.169.254` story

When a cloud instance boots, `cloud-init` issues:

```
GET http://169.254.169.254/latest/meta-data/...
```

to learn its hostname, public SSH keys, and user-data. That link-local IP is
not a real host — it is intercepted and proxied. With OVN:

```
  instance ──HTTP──► 169.254.169.254
                         │  (a logical switch port of type "localport"
                         │   present on EVERY chassis, never tunneled)
                         ▼
                 ovn-controller redirects to the local
                 ovn metadata agent (haproxy) in namespace
                 ovnmeta-<datapath-uuid>
                         │
                         ▼
                 Nova metadata API  ──►  instance-specific data
```

Key points:

- The metadata port is type **`localport`**: it exists identically on every
  chassis and is **never** sent across a Geneve tunnel. Traffic to it is
  always served by the *local* chassis — that is what makes metadata
  distributed.
- The **`ovn-metadata-agent`** (in OpenStack: `neutron-ovn-metadata-agent`)
  spins up a per-network `haproxy` inside an `ovnmeta-*` namespace and adds
  the chassis-identifying `X-OVN-...` / `X-Instance-ID` headers Nova needs.

In this lab we won't run Nova, but we **will** create the `localport`, wire a
tiny HTTP responder to `169.254.169.254`, and prove a namespace can reach it —
demonstrating the exact data-path cloud-init uses.

### 2.6 The Neutron mapping

| What you'll build in this lab | Neutron / OpenStack equivalent |
|-------------------------------|--------------------------------|
| `DHCP_Options` + `lsp-set-dhcpv4-options` | `openstack subnet create --dhcp` |
| `dynamic` addresses | Neutron IPAM allocation on `port create` |
| `dns_server` DHCP option | subnet `--dns-nameserver` |
| `DNS` records on a switch | Neutron internal DNS (`dns_domain`) |
| `localport` + `169.254.169.254` | `neutron-ovn-metadata-agent` + `ovnmeta-*` ns |
| OVN-native DHCP (flows) | replaces the legacy `qdhcp-*` `dnsmasq` |

---

## 3. Starting Point

This lab continues directly from Lab 5. You should still have:

- Logical switches `ls1` (`10.0.1.0/24`) and `ls2` (`10.0.2.0/24`).
- Logical router `lr1` routing between them.
- Namespaces `ns-a`, `ns-b` on `ls1`; `ns-c`, `ns-d` on `ls2`.

If you cleaned up, the **Lab 5 solution** (`lab05-solution.md`, in this folder)
rebuilds it end to end. Verify with:

```bash
ovn-nbctl show
```

> **The twist:** for this lab we will *remove* the static IPs from the
> namespaces and make them come up via DHCP instead — proving the fabric, not
> the operator, now owns addressing.

---

## 4. Exercises

All commands require **root** or **sudo** privileges.

### Exercise 1 — Add a DHCP server for `ls1`

1. Create a `DHCP_Options` row for the `10.0.1.0/24` subnet, including
   `router`, `server_id`, `server_mac`, `lease_time`, and a `dns_server`.
2. Attach it to `ls1-port1` and `ls1-port2` with
   `ovn-nbctl lsp-set-dhcpv4-options`.

```bash
d1=$(ovn-nbctl create DHCP_Options cidr=10.0.1.0/24 \
  options='"server_id"="10.0.1.1" "server_mac"="aa:bb:cc:00:01:01" \
           "lease_time"="3600" "router"="10.0.1.1" \
           "dns_server"="{8.8.8.8}" "mtu"="1442"')
ovn-nbctl lsp-set-dhcpv4-options ls1-port1 $d1
ovn-nbctl lsp-set-dhcpv4-options ls1-port2 $d1
```

> **MTU `1442`?** Geneve adds overhead to a 1500-byte underlay. Handing the
> guest a smaller MTU over DHCP avoids fragmentation — this is exactly
> Neutron's `path_mtu` calculation. (See SPEC §5.1.)

**Verify:**
- `ovn-nbctl list DHCP_Options` shows your row.
- `ovn-sbctl dump-flows ls1 | grep -i dhcp` shows `put_dhcp_opts` flows.

### Exercise 2 — Boot `ns-a` via DHCP

1. Inside `ns-a`, **remove** the static IP and default route from Lab 5.
2. Run a DHCP client on the veth and watch it receive `10.0.1.10`.

```bash
ip netns exec ns-a ip addr flush dev veth-a
ip netns exec ns-a ip route flush default
ip netns exec ns-a dhclient -v veth-a
```

**Verify:**
- `ip netns exec ns-a ip addr show veth-a` shows `10.0.1.10/24` (the address
  OVN has for that MAC).
- `ip netns exec ns-a ip route` shows a default route via `10.0.1.1` — pushed
  by the `router` DHCP option, *not* typed by you.
- A `tcpdump -i veth-a-ovs port 67 or port 68` capture shows the
  DISCOVER/OFFER/REQUEST/ACK handshake answered locally.

**Questions:**
- Where did the OFFER come from? Is there a `dnsmasq` process anywhere?
  (`ps aux | grep dnsmasq`)
- Which `server_mac` appears in the OFFER, and why does it matter for the
  reply path?

### Exercise 3 — Dynamic addressing (OVN as IPAM)

1. Configure `ls1` with a subnet so OVN can allocate from it.
2. Add a brand-new port `ls1-port-dyn` set to `dynamic` and observe the IP OVN
   assigns.

```bash
ovn-nbctl set Logical_Switch ls1 \
  other_config:subnet=10.0.1.0/24 \
  other_config:exclude_ips=10.0.1.1..10.0.1.9
ovn-nbctl lsp-add ls1 ls1-port-dyn
ovn-nbctl lsp-set-addresses ls1-port-dyn dynamic
ovn-nbctl lsp-set-dhcpv4-options ls1-port-dyn $d1
```

**Verify:**
- `ovn-nbctl get Logical_Switch_Port ls1-port-dyn dynamic_addresses` returns a
  MAC + IP that OVN chose.
- The IP is **not** in the excluded range.

### Exercise 4 — Add DHCPv6 (optional but recommended)

1. Give `ls1` an IPv6 ULA prefix (e.g. `fd00:1::/64`).
2. Create a DHCPv6 `DHCP_Options` row and attach it with
   `lsp-set-dhcpv6-options`.
3. Decide: SLAAC, stateless DHCPv6, or stateful DHCPv6? Set the router
   advertisement `address_mode` accordingly on the `lr1` router port.

**Verify:**
- `ip netns exec ns-a ip -6 addr` shows a `fd00:1::` address.
- Discuss: which mode did Neutron pick by default, and why? (Hint:
  `ipv6_address_mode` / `ipv6_ra_mode` on the subnet.)

### Exercise 5 — Internal DNS with OVN

1. Create a `DNS` record mapping `vm-a.lab.local → 10.0.1.10` and
   `vm-c.lab.local → 10.0.2.10`.
2. Attach it to `ls1` (and `ls2`).
3. Make the DHCP `dns_server` option point at OVN's DNS responder address.

```bash
dns=$(ovn-nbctl create DNS records:vm-a.lab.local=10.0.1.10)
ovn-nbctl add DNS $dns records vm-c.lab.local=10.0.2.10
ovn-nbctl add Logical_Switch ls1 dns_records $dns
```

**Verify:**
- From `ns-a`: `nslookup vm-a.lab.local <dns_server_ip>` resolves to
  `10.0.1.10`.
- `ovn-sbctl dump-flows ls1 | grep -i dns` shows `put_dns_opts` flows — the
  query is answered in OVS, not by an upstream resolver.

### Exercise 6 — The metadata data-path (`169.254.169.254`)

This is the conceptual heart of the lab. You will recreate the metadata
plumbing OVN uses, minus Nova.

1. Add a `localport` to `ls1` carrying the link-local metadata address:

```bash
ovn-nbctl lsp-add ls1 ls1-metadata
ovn-nbctl lsp-set-type ls1-metadata localport
ovn-nbctl lsp-set-addresses ls1-metadata "aa:bb:cc:00:0f:fe 169.254.169.254"
```

2. Bind that localport to a host-side interface and run a tiny HTTP responder
   on `169.254.169.254:80` (standing in for the metadata agent's haproxy):

```bash
# Wire a veth from the host root ns into br-int, bound to the localport
sudo ip link add veth-md type veth peer name veth-md-ovs
sudo ovs-vsctl add-port br-int veth-md-ovs \
  -- set interface veth-md-ovs external-ids:iface-id=ls1-metadata
sudo ip link set veth-md-ovs up
sudo ip link set veth-md up
sudo ip addr add 169.254.169.254/32 dev veth-md
# Minimal metadata stub
( echo '{"hostname":"vm-a","public-keys":"ssh-ed25519 AAAA..."}' > /tmp/meta.json
  cd /tmp && sudo python3 -m http.server 80 --bind 169.254.169.254 ) &
```

3. From the instance namespace, query it the way cloud-init would. Note that
   instances reach metadata via a host route to `169.254.169.254` over their
   default interface:

```bash
ip netns exec ns-a ip route add 169.254.169.254/32 dev veth-a
ip netns exec ns-a curl -s http://169.254.169.254/meta.json
```

**Verify:**
- The `curl` returns the JSON stub — proving the `169.254.169.254` data-path
  works through `br-int`.
- `ovn-sbctl find Port_Binding logical_port=ls1-metadata` shows the port type
  is `localport` (not bound to a chassis — present everywhere).

**Questions:**
- Why must the metadata port be a `localport` and not a normal port? What
  would break if it were tunneled to a single chassis?
- In real OpenStack, what process injects the `X-Instance-ID` /
  `X-Tenant-ID` headers, and how does Nova use them to return the *right*
  instance's data?
- Trace the difference vs. legacy ML2/OVS, where metadata was served by a
  `neutron-metadata-agent` proxy reached through the `qdhcp`/`qrouter`
  namespace.

### Exercise 7 — Tie it together: a "zero-touch" port

Create one final port that uses **all three** services at once — dynamic IP
via DHCP, DNS name, and metadata reachability — then bring a fresh namespace up
with nothing but a DHCP client.

**Verify:**
- The namespace obtains its IP, gateway, DNS, and MTU purely over DHCP.
- It can resolve another instance by name.
- It can `curl` the metadata endpoint.
- You never typed an IP into the namespace. This is what Nova + cloud-init
  experience on every boot.

---

## 5. Key Commands Reference

| Command | Description |
|---------|-------------|
| `ovn-nbctl create DHCP_Options cidr=<cidr> options=...` | Create a DHCP server row |
| `ovn-nbctl lsp-set-dhcpv4-options <port> <uuid>` | Attach DHCPv4 to a port |
| `ovn-nbctl lsp-set-dhcpv6-options <port> <uuid>` | Attach DHCPv6 to a port |
| `ovn-nbctl lsp-set-addresses <port> dynamic` | Let OVN allocate MAC/IP (IPAM) |
| `ovn-nbctl set Logical_Switch <ls> other_config:subnet=<cidr>` | Define IPAM range |
| `ovn-nbctl create DNS records:<name>=<ip>` | Create a DNS record set |
| `ovn-nbctl add Logical_Switch <ls> dns_records <uuid>` | Attach DNS to a switch |
| `ovn-nbctl lsp-set-type <port> localport` | Make a chassis-local (metadata) port |
| `ovn-sbctl dump-flows <ls> \| grep -i dhcp` | See compiled `put_dhcp_opts` flows |
| `dhclient -v <iface>` | Run a DHCP client inside the namespace |

---

## 6. Review Questions

1. Where does an OVN DHCP OFFER physically originate, and why is there no
   `dnsmasq` process? How is this "distributed DHCP"?
2. What is the difference between `"<mac> <ip>"`, `"<mac> dynamic"`, and
   `dynamic` for `lsp-set-addresses`? Who owns the IP in each case?
3. Why does OVN push a *smaller* MTU (e.g. 1442) over DHCP? Relate it to
   Geneve overhead and Neutron's `path_mtu`.
4. What logical-flow stage answers DNS queries, and why doesn't the query
   reach an upstream resolver?
5. Why is the metadata port a `localport`? What property of `localport` makes
   metadata work identically on every chassis?
6. Draw the full metadata path from `cloud-init` → `169.254.169.254` → Nova in
   a real ML2/OVN deployment. Which agent and which namespace are involved?

---

## 7. What's Next

You've now eliminated every hardcoded value from Lab 5 — the fabric assigns
addresses, names, and identity automatically, exactly like a real cloud.

But your security is still crude: Lab 5's ACLs were attached **per logical
switch** and were **stateless**. Real OpenStack security groups are
**per-port**, **stateful** (conntrack), and grouped with **address sets**. In
**Lab 7** you'll rebuild security the way Neutron actually renders it.

---

*Lab 6 of 9 — OpenStack Networking Workshop*
