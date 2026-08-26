
# Lab 6 — OVN Native Services & Security Groups

| | |
|---|---|
| **Tier** | 3 – OVN |
| **Duration** | ~90 minutes |
| **Prerequisites** | Labs 1–5 completed; Lab 5 topology still up |
| **Builds on** | Lab 5 — OVN Basics |

---

## 1. Objective

In Lab 5 you built a working OVN network — but you **cheated twice**.

**You hardcoded identity.** Every IP and MAC was typed in by hand, both in the
OVN logical port *and* inside the namespace. A real cloud cannot work that way:
instances boot from a generic image and must *discover* their identity (IP,
gateway, DNS, hostname, SSH keys) over the wire.

**You faked security.** Lab 5's ACLs were attached to a whole **logical
switch**, were **stateless**, and matched **literal IPs**. A real OpenStack
security group is **per-port**, **stateful**, and defined against **named
groups** that update as members come and go.

This lab fixes both halves — the two things that turn a hand-built OVN topology
into something Neutron could actually have rendered.

By the end of this lab you will be able to:

**Part A — Native services**

- Replace the hardcoded namespace IPs from Lab 5 with **OVN-native DHCPv4**.
- Use **dynamic address assignment** (`dynamic`) and let OVN own the IPAM.
- Serve internal name resolution with **OVN DNS records**.
- Explain and demonstrate the **metadata** data-path (`localport` +
  `169.254.169.254`) and how `cloud-init` reaches Nova.

**Part B — Real security groups**

- Explain why Lab 5's per-switch, stateless ACLs don't model security groups.
- Create **Port Groups** and attach ACLs to them (per-port enforcement).
- Use **Address Sets** so "allow from the web tier" updates automatically.
- Write **stateful** ACLs with `allow-related` and observe the **conntrack**
  (`ct()`) actions OVN compiles into `br-int`.
- Map every construct to its **Neutron / `openstack` CLI** equivalent.

---

## 2. Background & Concepts — Part A: Native Services

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

---

## 3. Background & Concepts — Part B: Security Groups

### 3.1 Why Lab 5's ACLs were a toy

In Lab 5 you ran:

```bash
ovn-nbctl acl-add ls1 from-lport 1000 'ip4' drop
ovn-nbctl acl-add ls1 from-lport 1100 'ip4 && tcp && tcp.dst==22' allow-related
```

Two problems:

1. **Scope is the whole switch.** Every port on `ls1` gets the same rules. But
   in OpenStack, two VMs on the *same network* routinely belong to *different*
   security groups (a web server and a database, say). Per-switch ACLs can't
   express that.
2. **Literal matches don't scale.** "Allow SSH from the bastion" means editing
   the rule every time the bastion's IP changes or a second bastion appears.

OVN fixes both with Port Groups and Address Sets.

### 3.2 Port Groups = a security group's *members*

A **Port Group** is a named set of logical switch ports. ACLs attached to the
port group apply **only to those ports**, regardless of which switch they live
on:

```
  Port_Group "pg-web"   → { ls1-port1, ls2-port3 }
      │
      │  ACLs attached HERE apply only to pg-web's members
      ▼
  outport == @pg-web && tcp.dst == 80   →  allow-related
```

This is a near-exact model of a Neutron security group: a group has *members*
(ports), and the group's *rules* are enforced on each member. Adding a VM to a
security group is just adding its port to the port group.

OVN also gives every port group two **auto-maintained address sets**:

| Auto address set | Contains |
|------------------|----------|
| `@pg-web` (in `outport`/`inport` matches) | the member **ports** |
| `$pg-web_ip4` / `$pg-web_ip6` | the member **IP addresses** |

So a rule can say "allow from any IP that belongs to the web tier" with
`ip4.src == $pg-web_ip4` — and it updates itself as members change.

### 3.3 Address Sets = a security group used as a *remote*

An **Address Set** is a named, mutable set of IP addresses:

```bash
ovn-nbctl create Address_Set name=admins addresses='10.0.1.10,10.0.2.10'
```

referenced in a match as `$admins`. When a Neutron rule says
"allow TCP 22 **from security group `admins`**" (a remote *group* rather than a
remote *CIDR*), ML2/OVN renders it as `ip4.src == $admins` — and keeps the set
in sync as admin VMs are created or deleted. No rule rewriting.

### 3.4 Stateful ACLs and conntrack

Lab 5's ACLs were effectively stateless: to let a reply back you needed a
second rule. OVN's `allow-related` makes an ACL **stateful** by sending the
packet through the kernel **connection tracker** (`conntrack`):

```
  new connection  ──► ct(commit)   ── remembers the 5-tuple
  reply packet    ──► ct() match "est/rel"  ── allowed automatically
```

In `br-int` you'll see `ct(...)`, `ct_state`, and `ct_commit` actions — this is
**the same conntrack** Linux iptables uses, but driven by OVS flows instead of
`iptables` rules. There are *no iptables rules*, but the *conntrack subsystem*
is shared and very much in play.

ACL action cheat-sheet:

| Action | Meaning |
|--------|---------|
| `drop` | silently discard |
| `reject` | discard + send TCP RST / ICMP unreachable |
| `allow` | permit, **stateless** (no conntrack) |
| `allow-related` | permit + track; replies/related flows auto-allowed |
| `allow-stateless` | permit, explicitly bypass conntrack (perf) |

### 3.5 Direction, priority, and default-drop

- **`from-lport`** = traffic **leaving** the VM (ingress to the switch;
  egress from the VM's view). Matched with `inport`.
- **`to-lport`** = traffic **arriving** at the VM. Matched with `outport`.
- **Priority** 0–32767; highest wins. Neutron uses a fixed banding scheme.
- The moment *any* ACL exists on a port group, OVN applies an implicit
  **default drop** for unmatched IP traffic — exactly like a security group,
  which denies everything not explicitly allowed.

---

## 4. The Neutron Mapping

Everything you build in this lab has a direct OpenStack counterpart:

| What you'll build | Neutron / OpenStack equivalent |
|-------------------|--------------------------------|
| `DHCP_Options` + `lsp-set-dhcpv4-options` | `openstack subnet create --dhcp` |
| `dynamic` addresses | Neutron IPAM allocation on `port create` |
| `dns_server` DHCP option | subnet `--dns-nameserver` |
| `DNS` records on a switch | Neutron internal DNS (`dns_domain`) |
| `localport` + `169.254.169.254` | `neutron-ovn-metadata-agent` + `ovnmeta-*` ns |
| OVN-native DHCP (flows) | replaces the legacy `qdhcp-*` `dnsmasq` |
| Port Group | a Security Group (its *members*) |
| ACL on a port group | a Security Group **rule** |
| `$pg-<sg>_ip4` auto address set | the SG used as a *remote group* |
| `allow-related` + `ct()` | stateful security group semantics |
| default drop | the implicit "deny all" of every SG |
| `from-lport` / `to-lport` | egress / ingress rule direction |

> **How real Neutron renders security:** the ML2/OVN driver creates one Port
> Group per Neutron security group (named `pg_<sg_uuid>`), adds each port to the
> port groups of its security groups, and writes one ACL per SG rule. You're
> about to do that by hand.

---

## 5. Starting Point

This lab continues directly from Lab 5. You should still have:

- Logical switches `ls1` (`10.0.1.0/24`) and `ls2` (`10.0.2.0/24`).
- Logical router `lr1` routing between them.
- Namespaces `ns-a`, `ns-b` on `ls1`; `ns-c`, `ns-d` on `ls2`.

If you cleaned up, the **Lab 5 solution** (`lab05-solution.md`, in this folder)
rebuilds it end to end. Verify with:

```bash
ovn-nbctl show
```

Also clear the Lab 5 switch-level ACLs now, so Part B starts from a clean slate:

```bash
ovn-nbctl acl-del ls1     # drop the Lab 5 switch-level ACLs
ovn-nbctl acl-list ls1    # should be empty
```

> **The twist:** for this lab we will *remove* the static IPs from the
> namespaces and make them come up via DHCP instead — proving the fabric, not
> the operator, now owns addressing.

---

## 6. Exercises — Part A: Native Services

All commands require **root** or **sudo** privileges.

### Exercise 1 — Add DHCP and boot `ns-a` without typing an IP

1. Create a `DHCP_Options` row for the `10.0.1.0/24` subnet and attach it to
   `ls1-port1` and `ls1-port2`:

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
> Neutron's `path_mtu` calculation.

2. Now **remove** the static IP from `ns-a` and let DHCP provide it:

```bash
ip netns exec ns-a ip addr flush dev veth-a
ip netns exec ns-a ip route flush default
ip netns exec ns-a dhclient -v veth-a
```

**Verify:**
- `ovn-sbctl dump-flows ls1 | grep -i dhcp` shows `put_dhcp_opts` flows.
- `ip netns exec ns-a ip addr show veth-a` shows `10.0.1.10/24`.
- `ip netns exec ns-a ip route` shows a default route via `10.0.1.1` — pushed
  by the `router` DHCP option, *not* typed by you.
- A `tcpdump -i veth-a-ovs port 67 or port 68` capture shows the
  DISCOVER/OFFER/REQUEST/ACK handshake answered locally.

**Questions:**
- Where did the OFFER come from? Is there a `dnsmasq` process anywhere?
  (`ps aux | grep dnsmasq`)
- Which `server_mac` appears in the OFFER, and why does it matter for the
  reply path?

### Exercise 2 — Dynamic addressing (OVN as IPAM)

Give `ls1` an IPAM range, then add a port that lets OVN pick everything:

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

> Keep this port around — you'll use it in Exercise 6 to prove that remote-group
> rules cover new members automatically.

### Exercise 3 — Internal DNS with OVN

```bash
dns=$(ovn-nbctl create DNS records:vm-a.lab.local=10.0.1.10)
ovn-nbctl add DNS $dns records vm-c.lab.local=10.0.2.10
ovn-nbctl add Logical_Switch ls1 dns_records $dns
```

Point the DHCP `dns_server` option at OVN's DNS responder address.

**Verify:**
- From `ns-a`: `nslookup vm-a.lab.local <dns_server_ip>` resolves to
  `10.0.1.10`.
- `ovn-sbctl dump-flows ls1 | grep -i dns` shows `put_dns_opts` flows — the
  query is answered in OVS, not by an upstream resolver.

### Exercise 4 — The metadata data-path (`169.254.169.254`)

Recreate the metadata plumbing OVN uses, minus Nova.

1. Add a `localport` to `ls1` carrying the link-local metadata address:

```bash
ovn-nbctl lsp-add ls1 ls1-metadata
ovn-nbctl lsp-set-type ls1-metadata localport
ovn-nbctl lsp-set-addresses ls1-metadata "aa:bb:cc:00:0f:fe 169.254.169.254"
```

2. Bind that localport to a host-side interface and run a tiny HTTP responder
   on `169.254.169.254:80` (standing in for the metadata agent's haproxy):

```bash
sudo ip link add veth-md type veth peer name veth-md-ovs
sudo ovs-vsctl add-port br-int veth-md-ovs \
  -- set interface veth-md-ovs external-ids:iface-id=ls1-metadata
sudo ip link set veth-md-ovs up
sudo ip link set veth-md up
sudo ip addr add 169.254.169.254/32 dev veth-md
( echo '{"hostname":"vm-a","public-keys":"ssh-ed25519 AAAA..."}' > /tmp/meta.json
  cd /tmp && sudo python3 -m http.server 80 --bind 169.254.169.254 ) &
```

3. Query it the way cloud-init would:

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
  `X-Tenant-ID` headers, and how does Nova use them?

---

## 7. Exercises — Part B: Security Groups

### Exercise 5 — Model two tiers with Port Groups, then lock them down

You'll treat `ns-a` (`ls1-port1`) as a **web** server and `ns-c`
(`ls2-port3`) as a **database** server — on *different* switches, the case
per-switch ACLs cannot handle. `ns-b` (`ls1-port2`) is the admin/bastion host.

```bash
ovn-nbctl pg-add pg-web   ls1-port1
ovn-nbctl pg-add pg-db    ls2-port3
ovn-nbctl pg-add pg-admin ls1-port2
```

Now attach stateful ACLs to `pg-web`:

```bash
# Ingress: HTTP from anywhere, SSH only from the admin group, drop the rest.
ovn-nbctl acl-add pg-web to-lport 1000 \
  'outport == @pg-web && ip4 && tcp.dst == 80' allow-related
ovn-nbctl acl-add pg-web to-lport 1010 \
  'outport == @pg-web && ip4.src == $pg-admin_ip4 && tcp.dst == 22' allow-related
ovn-nbctl acl-add pg-web to-lport 900 \
  'outport == @pg-web && ip4' drop
# Egress: let the web tier start any outbound connection.
ovn-nbctl acl-add pg-web from-lport 1000 \
  'inport == @pg-web && ip4' allow-related
```

**Verify:**
- `ovn-nbctl list port_group` shows three groups; `ovn-nbctl list address_set`
  shows the auto-created `pg-web_ip4` etc.
- From `ns-b` (admin): port-22 probe to `ns-a` → **allowed**.
- From `ns-c` (db): port-22 probe to `ns-a` → **blocked**.
- From anywhere: port-80 → **allowed**; port-443 → **blocked** (default drop).

> Test ports without real servers using `ncat`:
> `ip netns exec ns-a ncat -l 80 &` then
> `ip netns exec ns-b ncat -zv 10.0.1.10 80`.

### Exercise 6 — Statefulness and remote-group rules

**Part 1 — prove the ACL is stateful.** Add a DB rule that allows Postgres
from the web *group* (not a literal IP), then connect outbound from `ns-a` and
confirm replies flow back with **no** matching inbound rule:

```bash
ovn-nbctl acl-add pg-db to-lport 1000 \
  'outport == @pg-db && ip4.src == $pg-web_ip4 && tcp.dst == 5432' allow-related
ovn-nbctl acl-add pg-db to-lport 900 'outport == @pg-db && ip4' drop
```

**Verify:**
- `ovs-ofctl dump-flows br-int | grep -i ct` shows `ct(commit...)` and
  `ct_state` matches; `conntrack -L | grep 10.0.1.10` shows the connection.
- Change the web egress rule from `allow-related` to `allow` (stateless) and
  watch the return traffic now require its own explicit rule.

**Part 2 — add a member, change no rules.** Add the dynamic port from
Exercise 2 to the web group:

```bash
ovn-nbctl pg-add pg-web ls1-port-dyn
ovn-nbctl get Address_Set pg-web_ip4 addresses
```

**Verify:**
- The new web IP appears in `$pg-web_ip4` automatically.
- The new web port can reach the DB on 5432 **without** adding any ACL — the
  rule referenced the group, not an IP. This is the whole point of remote
  security groups.

**Questions:**
- Which `ct_state` flags (`new`, `est`, `rel`, `inv`) gate the return packets?
- Why is `allow-related` the OpenStack default, and when would you pick
  `allow-stateless`?

### Exercise 7 — `drop` vs `reject`, and tie it back to OpenStack

Change the default web-tier deny from `drop` to `reject` and observe the
client-side difference, then inspect what everything compiled into:

```bash
ovn-nbctl list acl
ovn-sbctl lflow-list | grep -iE 'acl|ct'
ovs-ofctl dump-flows br-int | grep -i ct
```

**Verify:**
- With `drop`: `ncat -zv` hangs then times out.
- With `reject`: `ncat -zv` returns "Connection refused" immediately.
- You can fill in this mapping from memory:

| What you did | `openstack` equivalent |
|---|---|
| `ovn-nbctl pg-add pg-web ...` | `openstack security group create web` (+ add ports) |
| `acl-add pg-web to-lport ... tcp.dst==80 allow-related` | `openstack security group rule create --ingress --protocol tcp --dst-port 80 web` |
| `ip4.src == $pg-admin_ip4` | `... --remote-group admin` |
| default `drop` ACL | the implicit deny-all of a security group |
| `from-lport` allow | an **egress** SG rule |

---

## 8. Optional Stretch Goals

Skip these if you're short on time — they're worth doing before Lab 8.

- **DHCPv6.** Give `ls1` a ULA prefix (e.g. `fd00:1::/64`), create a DHCPv6
  `DHCP_Options` row, attach it with `lsp-set-dhcpv6-options`, and set the
  router advertisement `address_mode` on the `lr1` router port. Which mode does
  Neutron pick by default, and why? (Hint: `ipv6_address_mode` / `ipv6_ra_mode`.)
- **A "zero-touch" port.** Create one final port that uses all three services at
  once — dynamic IP via DHCP, a DNS name, and metadata reachability — then bring
  a fresh namespace up with nothing but a DHCP client. You should never type an
  IP. This is what Nova + cloud-init experience on every boot.

---

## 9. Key Commands Reference

**Native services**

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

**Security groups**

| Command | Description |
|---------|-------------|
| `ovn-nbctl pg-add <pg> [ports...]` | Create a port group (security group members) |
| `ovn-nbctl pg-set-ports <pg> <ports...>` | Replace a port group's members |
| `ovn-nbctl acl-add <pg> <dir> <prio> '<match>' <action>` | Add an ACL to a port group |
| `ovn-nbctl acl-del <pg>` | Remove ACLs from a port group/switch |
| `ovn-nbctl acl-list <pg>` | List ACLs |
| `ovn-nbctl create Address_Set name=<n> addresses='<ips>'` | Create an address set |
| `ovn-nbctl list address_set` | Inspect address sets (incl. auto `pg-*_ip4`) |
| `@<pg>` in a match | the port group's member ports |
| `$<pg>_ip4` / `$<set>` in a match | member IPs / address-set IPs |
| `allow-related` | stateful allow (conntrack) |
| `conntrack -L` | view tracked connections |

---

## 10. Review Questions

1. Where does an OVN DHCP OFFER physically originate, and why is there no
   `dnsmasq` process? How is this "distributed DHCP"?
2. What is the difference between `"<mac> <ip>"`, `"<mac> dynamic"`, and
   `dynamic` for `lsp-set-addresses`? Who owns the IP in each case?
3. Why does OVN push a *smaller* MTU (e.g. 1442) over DHCP? Relate it to
   Geneve overhead and Neutron's `path_mtu`.
4. Why is the metadata port a `localport`? What property of `localport` makes
   metadata work identically on every chassis?
5. Why can't Lab 5's per-switch ACLs represent two VMs on the same network in
   different security groups? How do port groups solve it?
6. What are the two address sets OVN auto-creates for a port group, and when do
   you use `@pg` vs `$pg_ip4`?
7. Explain the difference between `allow`, `allow-related`, and
   `allow-stateless`. Which `ct()` actions does each produce?
8. How does a "remote group" security-group rule stay correct as members are
   added or deleted, without rewriting the rule?
9. Map `openstack security group rule create --ingress --protocol tcp
   --dst-port 22 --remote-group admins web` to the exact OVN port group, ACL
   direction, match, and action.

---

## 11. What's Next

You've eliminated every hardcoded value from Lab 5 — the fabric assigns
addresses, names, and identity automatically — and rebuilt security the way
Neutron actually renders it: per-port, stateful, and group-based.

But it all still runs on **one chassis**. Lab 5's "Geneve tunnel" never
actually carried a packet, the router gateway was pinned to the only host you
had, and "DVR" was just a word.

Next you'll add a **second chassis**, watch OVN build a **real Geneve overlay**
between hosts, see **distributed east/west routing** happen locally on each
chassis, make the external gateway **highly available** with an HA chassis
group, and hand out **floating IPs** with `dnat_and_snat`.

---

*Lab 6 of 10 — OpenStack Networking Workshop*
