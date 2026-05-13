
# Lab 5 — OVN Basics (Open Virtual Network)

| | |
|---|---|
| **Tier** | 3 – OVN |
| **Duration** | ~2.5 hours |
| **Prerequisites** | Labs 1–4 completed |
| **Builds on** | Lab 4 — OVS Advanced: OpenFlow Rules & Tunnels |

---

## 1. Objective

By the end of this lab you will be able to:

- Explain the OVN architecture and how it relates to OVS.
- Install and configure OVN components (central + host).
- Create logical switches and logical switch ports.
- Bind logical ports to OVS interfaces connected to namespaces.
- Create logical routers and connect logical switches.
- Implement ACLs (the OVN equivalent of OpenStack security groups).
- Enable OVN-native DHCP.
- Trace logical flows and see how they compile into OVS OpenFlow rules.
- Map every OVN concept to its OpenStack Neutron equivalent.

---

## 2. Background & Concepts

### 2.1 Why OVN?

In Lab 4, we manually programmed OVS flows and namespace-based routing to
implement forwarding and connectivity. This works for a few ports but doesn't
scale — in a real cloud with thousands of VMs, you need **automation**.

**OVN (Open Virtual Network)** is the SDN controller built on top of OVS. It:
- Accepts high-level intent ("create a network", "add a router").
- Compiles intent into **logical flows**.
- Distributes logical flows to every host.
- Each host's `ovn-controller` translates logical flows into **physical OVS
  OpenFlow rules**.

No iptables. No router namespaces. No manual `sysctl`. OVN handles all of
it in OVS flows.

### 2.2 OVN Architecture

```
                     ┌───────────────────────────┐
                     │       Northbound DB        │  ← Logical topology
                     │  (networks, routers, ACLs) │     (what Neutron writes to)
                     └─────────────┬─────────────┘
                                   │
                     ┌─────────────▼─────────────┐
                     │        ovn-northd          │  ← Compiles NB → SB
                     └─────────────┬─────────────┘
                                   │
                     ┌─────────────▼─────────────┐
                     │       Southbound DB        │  ← Physical bindings +
                     │  (logical flows, chassis)  │     compiled flows
                     └──────┬─────────────┬──────┘
                            │             │
              ┌─────────────▼──┐   ┌──────▼───────────┐
              │ ovn-controller │   │  ovn-controller   │
              │   (Host A)     │   │    (Host B)       │
              └───────┬────────┘   └───────┬───────────┘
                      │                     │
              ┌───────▼────────┐   ┌───────▼───────────┐
              │  OVS br-int    │   │   OVS br-int      │
              │  (Host A)      │   │   (Host B)        │
              └────────────────┘   └───────────────────┘
```

### 2.3 Key OVN Concepts

| OVN Concept | OpenStack Equivalent | Description |
|-------------|---------------------|-------------|
| Logical Switch | Neutron Network | A virtual L2 network |
| Logical Switch Port | Neutron Port | A virtual NIC on a network |
| Logical Router | Neutron Router | A virtual L3 router |
| Logical Router Port | Router interface | Connects a router to a switch |
| ACL | Security Group Rule | Allow/deny rules on a port |
| DHCP Options | Subnet DHCP settings | DHCP server configuration |
| Address Set | Security Group | Named group of IPs/MACs |
| Chassis | Compute/Network Node | A physical host running ovn-controller |

### 2.4 Logical Flows vs. OpenFlow Flows

OVN operates at two levels:

1. **Logical flows** (`ovn-sbctl lflow-list`): Express intent in terms of
   logical ports and switches — **location-independent**.

2. **OpenFlow flows** (`ovs-ofctl dump-flows br-int`): The physical
   realization on a specific host. `ovn-controller` generates these by
   combining logical flows with local binding information.

### 2.5 OVN-Native DHCP

Instead of running a `dnsmasq` process (as legacy Neutron does), OVN
implements DHCP **entirely in logical flows**:
- When a VM sends a DHCP Discover/Request, the OVS flow pipeline recognizes
  it and generates a DHCP Reply directly — no external process needed.
- Faster, scales better, and eliminates DHCP agent namespaces.

### 2.6 Geneve Tunnels

OVN uses **Geneve** as its overlay protocol. Unlike VXLAN, Geneve supports
extensible TLV headers — OVN uses these to carry logical datapath and port
metadata. OVN automatically manages tunnel creation between all chassis.

### 2.7 External Connectivity

OVN connects to the physical network via **localnet ports** and a provider
bridge (`br-ex`):

```
  br-int (OVS)           br-ex (OVS)
  ┌─────────────┐  patch  ┌─────────────┐
  │ OVN logical │─────────│ physical NIC│──→ external network
  │ flows       │  ports  │ (e.g. eth0) │
  └─────────────┘         └─────────────┘
```

OVN programs SNAT and DNAT (floating IPs) as logical router NAT rules —
compiled into OVS flows, no iptables involved.

---

## 3. Architecture Diagram

Target state at the end of this lab:

```
 ┌─────────────────────────────────────────────────────────────────────┐
 │                          OVN Central                                │
 │   ┌─────────────┐    ┌─────────────┐    ┌─────────────┐           │
 │   │ Northbound DB│    │  ovn-northd  │    │ Southbound DB│           │
 │   └──────┬──────┘    └──────────────┘    └──────┬──────┘           │
 └──────────┼──────────────────────────────────────┼──────────────────┘
            │                                       │
  ┌─────────▼───────────────────────────────────────▼─────────────────┐
  │                        ovn-controller                              │
  │                        (local chassis)                             │
  └──────────────────────────┬────────────────────────────────────────┘
                             │
  ┌──────────────────────────▼────────────────────────────────────────┐
  │                       br-int (OVS)                                 │
  │                                                                    │
  │  ┌────────┐  ┌────────┐     ┌────────┐  ┌────────┐               │
  │  │ port1  │  │ port2  │     │ port3  │  │ port4  │               │
  │  └───┬────┘  └───┬────┘     └───┬────┘  └───┬────┘               │
  └──────┼───────────┼──────────────┼───────────┼─────────────────────┘
         │           │              │           │
   ┌─────▼───┐ ┌─────▼───┐   ┌─────▼───┐ ┌─────▼───┐
   │  ns-a   │ │  ns-b   │   │  ns-c   │ │  ns-d   │
   │  ls1    │ │  ls1    │   │  ls2    │ │  ls2    │
   │10.0.1.10│ │10.0.1.20│   │10.0.2.10│ │10.0.2.20│
   └─────────┘ └─────────┘   └─────────┘ └─────────┘
         ↑                          ↑
         └───── Logical Switch 1 ───┘
                      │
              ┌───────▼────────┐
              │  Logical Router │  lr1
              │  (OVN-managed)  │
              └───────┬────────┘
                      │
         ┌───── Logical Switch 2 ───┐
         ↓                          ↓
```

---

## 4. Exercises

All commands require **root** or **sudo** privileges.

### Exercise 1 — Install OVN

Install OVN central components and the host-side controller.

```bash
sudo apt install -y ovn-central ovn-host
```

**Verify:**
- `ovn-nbctl show` returns empty (no logical resources yet).
- `ovn-sbctl show` returns empty or shows the local chassis.

### Exercise 2 — Initialize OVN and Register the Chassis

1. Start the OVN central services (`ovn-northd`, NB/SB databases).
2. Configure `ovn-controller` to connect to the Southbound DB.
3. Set the OVS external-ids so `ovn-controller` knows the local chassis
   identity and the encapsulation type/IP.

```bash
sudo ovs-vsctl set open . \
  external-ids:ovn-remote=unix:/var/run/ovn/ovnsb_db.sock \
  external-ids:ovn-encap-type=geneve \
  external-ids:ovn-encap-ip=127.0.0.1
```

**Verify:**
- `ovn-sbctl show` shows your chassis with a Geneve encapsulation entry.

### Exercise 3 — Create a Logical Switch and Ports

1. Create a logical switch `ls1`.
2. Add two logical switch ports: `ls1-port1`, `ls1-port2`.
3. Set the MAC addresses and IP addresses for each port.

```bash
ovn-nbctl ls-add ls1
ovn-nbctl lsp-add ls1 ls1-port1
ovn-nbctl lsp-set-addresses ls1-port1 "aa:bb:cc:00:00:01 10.0.1.10"
ovn-nbctl lsp-add ls1 ls1-port2
ovn-nbctl lsp-set-addresses ls1-port2 "aa:bb:cc:00:00:02 10.0.1.20"
```

**Verify:**
- `ovn-nbctl show` displays the switch and ports.

### Exercise 4 — Bind Logical Ports to Namespaces

1. Create namespaces `ns-a` and `ns-b`.
2. Create veth pairs and add the host-side ends to OVS `br-int`.
3. Set `external_ids:iface-id` on the OVS interface to bind it to the OVN
   logical port:

```bash
sudo ovs-vsctl set interface veth-a-ovs \
  external-ids:iface-id=ls1-port1
sudo ovs-vsctl set interface veth-b-ovs \
  external-ids:iface-id=ls1-port2
```

4. Configure IP and MAC inside each namespace to match the OVN port config.

**Verify:**
- `ovn-sbctl show` shows the ports as **bound** to the local chassis.
- Ping from `ns-a` to `ns-b` — L2 connectivity via OVN!

### Exercise 5 — Inspect Logical Flows and OpenFlow Rules

Start by dumping the current state of the bridge:

```bash
ovn-sbctl lflow-list ls1
ovs-ofctl dump-flows br-int
```

1. In one terminal, capture one **outgoing** packet on the OVS-side of
   `veth-a` (filter by source MAC so we only capture frames leaving `ns-a`,
   not replies coming back):

```bash
# namespace a
ns_a_mac=$(sudo ip netns exec ns-a ip link show veth-a | awk '/ether/{print $2}')
# root namespace
flow=$(sudo tcpdump -nXXi veth-a-ovs -c1 "ether src ${ns_a_mac}" 2>/dev/null | ovs-tcpundump)
```

2. In another terminal, generate traffic to trigger the capture:

```bash
sudo ip netns exec ns-a ping -c1 10.0.1.20
```

3. Once `$flow` is populated, get the ingress port number and run the trace:

```bash
in_port=$(sudo ovs-vsctl get Interface veth-a-ovs ofport)
sudo ovs-appctl ofproto/trace br-int in_port=${in_port} ${flow}
```

This shows exactly how `br-int`'s OpenFlow pipeline processes a real packet
from `ns-a` — each table, each action, and the final output port.

**Questions:**
- How many logical flow tables are there?
- Can you find the ARP responder flows? What does OVN do instead of
  flooding ARP requests to all ports?
- How does `ovs-appctl ofproto/trace` differ from `ovn-trace`? Which one
  operates at the logical level and which at the physical level?

### Exercise 6 — Create a Second Logical Switch

1. Create `ls2` with ports `ls2-port3` and `ls2-port4`.
2. Create namespaces `ns-c`, `ns-d` on subnet `10.0.2.0/24`.
3. Bind the ports (same process as Exercise 4).

**Verify:**
- Intra-switch pings work within `ls2`.
- Cross-switch pings (`ns-a` → `ns-c`) do **not** work yet — no router.

### Exercise 7 — Create a Logical Router

1. Create logical router `lr1`.
2. Add a router port connected to `ls1` (IP: `10.0.1.1/24`).
3. Add a router port connected to `ls2` (IP: `10.0.2.1/24`).
4. Set the gateway port on each logical switch port that faces the router.

```bash
ovn-nbctl lr-add lr1

ovn-nbctl lrp-add lr1 lr1-ls1 aa:bb:cc:00:01:01 10.0.1.1/24
ovn-nbctl lsp-add ls1 ls1-lr1
ovn-nbctl lsp-set-type ls1-lr1 router
ovn-nbctl lsp-set-addresses ls1-lr1 router
ovn-nbctl lsp-set-options ls1-lr1 router-port=lr1-ls1

ovn-nbctl lrp-add lr1 lr1-ls2 aa:bb:cc:00:01:02 10.0.2.1/24
ovn-nbctl lsp-add ls2 ls2-lr1
ovn-nbctl lsp-set-type ls2-lr1 router
ovn-nbctl lsp-set-addresses ls2-lr1 router
ovn-nbctl lsp-set-options ls2-lr1 router-port=lr1-ls2
```

Set the default gateway inside each namespace:

```bash
ip netns exec ns-a ip route add default via 10.0.1.1
ip netns exec ns-c ip route add default via 10.0.2.1
```

**Verify:**
- Ping from `ns-a` (`10.0.1.10`) to `ns-c` (`10.0.2.10`) — cross-subnet
  routing through the OVN logical router!
- Use `ovn-trace` to trace the cross-subnet path and observe the logical
  router pipeline.

### Exercise 8 — Add OVN ACLs

Implement security-group-like rules on `ls1`:

```bash
ovn-nbctl acl-add ls1 from-lport 1000 'ip4' drop
ovn-nbctl acl-add ls1 from-lport 1100 'ip4 && icmp4' allow-related
ovn-nbctl acl-add ls1 from-lport 1100 'ip4 && tcp && tcp.dst==22' allow-related
```

**Verify:**
- Ping from `ns-a` to `ns-b` — works (ICMP allowed).
- TCP 22 from `ns-a` to `ns-b` — works.
- TCP 80 from `ns-a` to `ns-b` — blocked.
- All traffic on `ls2` — works (no ACLs).

**Questions:**
- How do OVN ACLs differ from iptables rules?
- Where are the ACL rules enforced — on the logical switch or in OVS flows?

### Exercise 9 — Enable OVN-Native DHCP

1. Create DHCP options for `ls1`'s subnet:

```bash
DHCP_OPTS=$(ovn-nbctl create DHCP_Options cidr=10.0.1.0/24 \
  options='"server_id"="10.0.1.1" "server_mac"="aa:bb:cc:00:01:01" \
  "lease_time"="3600" "router"="10.0.1.1"')
```

2. Associate the DHCP options with the logical switch ports:

```bash
ovn-nbctl lsp-set-dhcpv4-options ls1-port1 $DHCP_OPTS
ovn-nbctl lsp-set-dhcpv4-options ls1-port2 $DHCP_OPTS
```

3. Inside a namespace, run `dhclient` to get an address:

```bash
sudo ip netns exec ns-a dhclient veth-a
```

**Verify:**
- The namespace gets the correct IP via DHCP.
- `tcpdump` inside the namespace shows DHCP Discover → Offer → Request → Ack.
- Confirm no `dnsmasq` process is running — DHCP is handled by OVS flows.

### Exercise 10 — Deep Inspection

```bash
ovn-nbctl show
ovn-sbctl show
ovn-sbctl lflow-list
ovs-ofctl dump-flows br-int
```

**Questions:**
- How many OpenFlow rules are in `br-int`?
- Can you trace ARP suppression in the logical flows?
- Can you find Geneve tunnel metadata in the OpenFlow rules?

### Exercise 11 — (Capstone) Map to OpenStack Concepts

Fill in this mental mapping:

| What you just did | OpenStack CLI equivalent |
|---|---|
| `ovn-nbctl ls-add ls1` | `openstack network create net1` |
| `ovn-nbctl lsp-add ls1 port1` | `openstack port create --network net1 port1` |
| `ovn-nbctl lr-add lr1` | `openstack router create router1` |
| `ovn-nbctl lrp-add ...` | `openstack router add subnet ...` |
| `ovn-nbctl acl-add ...` | `openstack security group rule create ...` |
| DHCP options | `openstack subnet create --dhcp-enabled ...` |

---

## 5. Key Commands Reference

| Command | Description |
|---------|-------------|
| `ovn-nbctl ls-add <name>` | Create a logical switch |
| `ovn-nbctl lsp-add <switch> <port>` | Add a port to a switch |
| `ovn-nbctl lsp-set-addresses <port> "<mac> <ip>"` | Set port addresses |
| `ovn-nbctl lsp-set-port-security <port> "<mac> <ip>"` | Enable port security |
| `ovn-nbctl lr-add <name>` | Create a logical router |
| `ovn-nbctl lrp-add <router> <port> <mac> <ip/mask>` | Add router port |
| `ovn-nbctl lsp-set-type <port> router` | Set port type to router |
| `ovn-nbctl lsp-set-options <port> router-port=<rtr-port>` | Link switch port to router port |
| `ovn-nbctl acl-add <switch> <direction> <priority> <match> <action>` | Add ACL |
| `ovn-nbctl show` | Show logical topology |
| `ovn-sbctl show` | Show physical bindings |
| `ovn-sbctl lflow-list` | List logical flows |
| `ovn-trace <datapath> '<packet>'` | Trace a packet through logical flows |
| `ovn-detrace` | Map OpenFlow rules back to logical flows |

---

## 6. Review Questions

1. What are the two OVN databases? What does each store?
2. What is the role of `ovn-northd`?
3. What is the role of `ovn-controller`? Where does it run?
4. How does OVN handle DHCP differently from legacy Neutron?
5. What overlay protocol does OVN use by default? Why not VXLAN?
6. What is an OVN ACL? How does it map to an OpenStack security group?
7. In OVN, what happens when you create a logical router? How does it differ
   from a traditional namespace-based router with IP forwarding enabled?
8. What is `ovn-trace` and how does it differ from `ofproto/trace`?
9. Describe the full lifecycle of a packet from VM A to VM B on the same
   logical switch, going through all OVN/OVS stages.

---

## 7. Capstone Discussion

Now that you've built the entire stack by hand, let's map it all to
OpenStack:

### The Lifecycle of a Neutron Port

```
  openstack port create --network net1 --fixed-ip subnet=sub1
      │
      ▼
  Neutron API → ML2/OVN mechanism driver
      │
      ▼
  ovn-nbctl lsp-add <switch> <port>
  ovn-nbctl lsp-set-addresses <port> "<mac> <ip>"
      │
      ▼
  ovn-northd compiles NB → SB (logical flows)
      │
      ▼
  ovn-controller on each chassis receives updated flows
      │
      ▼
  OVS OpenFlow rules updated on br-int
      │
      ▼
  Nova creates the VM, attaches TAP device to br-int
  with iface-id matching the OVN logical port
      │
      ▼
  ovn-controller detects the binding → port is UP
```

### Topics to Discuss

- **Floating IPs:** Implemented as OVN NAT rules on the logical router.
- **Security groups:** OVN ACLs applied to logical switch ports.
- **Metadata service:** A special OVN logical port that intercepts traffic
  to `169.254.169.254` and redirects it to the metadata agent.
- **Provider networks:** Mapped to physical networks via OVN's bridge
  mapping (localnet ports on `br-ex`).
- **DVR:** OVN's distributed routing — every chassis can route locally
  without going through a centralized network node.

---

## 8. What's Next

🎉 **Congratulations!** You've completed the workshop. You've built, by hand,
the same network topology that OpenStack Neutron + OVN creates automatically.

### Suggested Further Learning

- [ ] Deploy a real OpenStack cluster and compare `ovn-nbctl show` with what
      you built here.
- [ ] Explore OVN load balancing (`ovn-nbctl lb-add`).
- [ ] Set up a multi-node lab using the `virt-tools/kvm/spawn-vm.sh` scripts.
- [ ] Study OVS-DPDK for high-performance data-plane.
- [ ] Read the OVN architecture document: `man 7 ovn-architecture`.

---

*Lab 5 of 5 — OpenStack Networking Workshop*

