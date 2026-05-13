# Lab 4 — OVS Advanced: OpenFlow Rules & Tunnels

| | |
|---|---|
| **Tier** | 2 – Open vSwitch |
| **Duration** | ~1.5 hours |
| **Prerequisites** | Labs 1–3 completed |
| **Builds on** | Lab 3 — OVS as an L2 Switch |

---

## 1. Objective

By the end of this lab you will be able to:

- Understand the structure of an OpenFlow flow (match + priority + action).
- Add and delete custom flow rules with `ovs-ofctl`.
- Implement a simple ACL by dropping traffic with a flow rule.
- Create a VXLAN overlay tunnel between two OVS bridges.
- Explain why OVN uses Geneve instead of VXLAN.

---

## 2. Background & Concepts

### 2.1 OpenFlow Basics

OVS implements the **OpenFlow** protocol, which lets a controller (or you,
manually) install **flow rules** into the switch's flow tables. A flow rule
consists of:

- **Match fields:** ingress port, VLAN, source/destination MAC, IP addresses,
  TCP/UDP ports, and more.
- **Priority:** higher priority rules are evaluated first (range 0–65535).
- **Actions:** `output:<port>`, `drop`, `mod_vlan_vid`, `resubmit(<table>)`,
  `NORMAL`, etc.

```
  Incoming packet
       │
       ▼
  ┌─ Table 0 ────────────────────────────────────────────┐
  │  priority=200, ip, nw_src=10.0.0.1 → actions=drop   │
  │  priority=100, ip                   → actions=NORMAL │
  │  priority=0                         → actions=NORMAL │
  └──────────────────────────────────────────────────────┘
```

The **first matching rule** (by descending priority) wins.

Below are some common OpenFlow rules:

```
# ovs-ofctl dump-flows br-int
cookie=0x819fbe8e, duration=191.647s, table=14, n_packets=0, n_bytes=0, idle_age=191, priority=110,   ipv6,reg14=0x1,metadata=0x9   actions=resubmit(,15)
cookie=0xb89f2b5c, duration=191.833s, table=24, n_packets=0, n_bytes=0, idle_age=191, priority=65532,   icmp6,metadata=0x7,ipv6_dst=ff02::16,icmp_type=143    actions=resubmit(,25)
cookie=0x112d7e8c, duration=191.834s, table=44, n_packets=0, n_bytes=0, idle_age=191, priority=65532,   ct_state=+inv+trk,metadata=0x7    actions=drop

```

### 2.2 Flow Tables and Chaining

OVS supports up to 255 flow tables (0–254). A packet starts at **table 0**
and can be directed to other tables via `resubmit(,<table>)`. OVN uses
multiple tables to implement a rich logical pipeline (ingress ACL, routing,
egress ACL, etc.). In this lab we work only with table 0.

### 2.3 VXLAN Overlay Tunnels

**VXLAN (Virtual eXtensible LAN)** encapsulates Layer 2 Ethernet frames
inside UDP packets (port 4789). This allows two OVS bridges on different
hosts to share a broadcast domain across a routed network.

```
  Host A                                    Host B
  ┌──────────────────┐                     ┌──────────────────┐
  │ br-int           │                     │ br-int           │
  │  ns-a  ns-b      │                     │  ns-c  ns-d      │
  │    ↕     ↕       │──── VXLAN (UDP) ────│    ↕     ↕       │
  └──────────────────┘                     └──────────────────┘
```

Each VXLAN tunnel carries a **VNI (VXLAN Network Identifier)**, a 24-bit
value that identifies which virtual network the frame belongs to
(equivalent to a VLAN ID but with 16 million possible values).

### 2.4 Geneve vs. VXLAN

OVN uses **Geneve** (Generic Network Virtualization Encapsulation) rather
than VXLAN as its overlay protocol. Key differences:

| | VXLAN | Geneve |
|--|-------|--------|
| Header | Fixed | Extensible TLV options |
| OVN metadata | Not supported | Carries logical datapath + port IDs |
| Standard | RFC 7348 | RFC 8926 |

OVN embeds logical port and datapath metadata directly in Geneve TLV headers,
allowing `ovn-controller` to efficiently dispatch packets without extra lookup
tables. OVS supports both — in this lab we use VXLAN for simplicity since
the tunneling mechanics are identical.

---

## 3. Architecture Diagram

### Single-host topology (Exercises 1–5)

```
 ┌──────────────────── Host ───────────────────────────────────────────┐
 │                                                                      │
 │   ┌──── ns-a ──────┐  ┌──── ns-b ──────┐  ┌──── ns-c ──────┐     │
 │   │  veth-a         │  │  veth-b         │  │  veth-c         │     │
 │   │  192.168.100.10 │  │  192.168.100.20 │  │  192.168.100.30 │     │
 │   └───────┬─────────┘  └───────┬─────────┘  └───────┬─────────┘     │
 │      veth-a-ovs          veth-b-ovs          veth-c-ovs              │
 │           └──────────────────┬──────────────────────┘               │
 │                         br-int (OVS)                                 │
 │              custom flows: ACL drop, then NORMAL                     │
 └──────────────────────────────────────────────────────────────────────┘
```


---

## 4. Exercises

All commands require **root** or **sudo** privileges. Start from the end-state
of Lab 3 (`br-int` with `ns-a`, `ns-b`, `ns-c` connected).

### Exercise 1 — Inspect the Default Flow and Port Counters

```bash
sudo ovs-ofctl dump-flows br-int
sudo ovs-ofctl dump-ports br-int
sudo ovs-ofctl show br-int
sudo ovs-dpctl dump-flows
```

**Questions:**
- What is the priority and action of the default flow?
- What port numbers are assigned to each veth?
- Generate some traffic (ping between namespaces) and re-run `dump-flows`.
  What changed in the `n_packets` counter?


### Exercise 2 — Add a Custom ACL Flow

Install a flow that **drops** IP traffic from `ns-c` (`192.168.100.30`)
destined for `ns-a` (`192.168.100.10`):

```bash
sudo ovs-ofctl add-flow br-int \
  "priority=100,ip,nw_src=192.168.100.30,nw_dst=192.168.100.10,actions=drop"
```

**Verify:**
- `sudo ovs-ofctl dump-flows br-int` — your new flow appears alongside the
  default.
- Ping from `ns-c` to `ns-a` — **blocked**.
- Ping from `ns-c` to `ns-b` — **still works** (different destination).
- Ping from `ns-a` to `ns-c` — **still works** (different source direction).

**Questions:**
- Why doesn't the reverse direction (`ns-a` → `ns-c`) get blocked?
- How would you block traffic in both directions with a single rule?

### Exercise 3 — Remove the ACL Flow

```bash
sudo ovs-ofctl del-flows br-int \
  "ip,nw_src=192.168.100.30,nw_dst=192.168.100.10"
```

**Verify:**
- `dump-flows` shows only the default flow again.
- Ping from `ns-c` to `ns-a` — restored.

### Exercise 4 — Add a Flow Using Port-Based Match

Instead of matching on IP, drop traffic **ingressing on veth-a-ovs** destined
for a specific MAC. First find the MAC of `veth-b` (inside `ns-b`):

```bash
sudo ip netns exec ns-b ip link show veth-b
```

Then add:

```bash
sudo ovs-ofctl add-flow br-int \
  "priority=100,in_port=<port-num-a>,dl_dst=<mac-of-veth-b>,actions=drop"
```

**Verify:**
- ARP from `ns-a` to `ns-b` still works (ARP uses broadcast `dl_dst`,
  not the specific MAC). Does this matter?
- ICMP ping from `ns-a` to `ns-b` — blocked.
- Remove the flow when done.

### Exercise 5 — Port Statistics and Flow Counters

Generate traffic between namespaces, then:

```bash
sudo ovs-ofctl dump-ports br-int
sudo ovs-ofctl dump-flows br-int
sudo ovs-dpctl dump-flows
```

**Questions:**
- Can you see per-port byte/packet counters?
- Can you see per-flow hit counters?
- How would you use these in a real troubleshooting scenario?
- What is the difference between `ovs-ofctl dump-flows` and `ovs-dpctl dump-flows`?


---

## 5. Key Commands Reference

| Command | Description |
|---------|-------------|
| `ovs-ofctl dump-flows <bridge>` | Show all flow rules with counters |
| `ovs-ofctl dump-ports <bridge>` | Show per-port statistics |
| `ovs-dpctl dump-flows` | Show datapath flows |
| `ovs-ofctl show <bridge>` | Show port numbers and names |
| `ovs-ofctl add-flow <bridge> <flow>` | Install a flow rule |
| `ovs-ofctl del-flows <bridge> <match>` | Delete matching flow rules |

---

## 6. Review Questions

1. What are the three components of an OpenFlow flow rule?
2. If two flow rules both match a packet, which one wins?
3. What does `resubmit(,1)` do in a flow action?
4. What is the VNI in a VXLAN header? What is its bit width and maximum
   number of distinct values?
5. OVN installs dozens of flow tables on `br-int`. Why does it use multiple
   tables rather than a flat list?

---

## 7. What's Next

In **Lab 5** we will move from manual OVS flow programming to **OVN (Open
Virtual Network)** — the SDN controller that sits on top of OVS and
automates logical switching, routing, ACLs, NAT, and DHCP. We will also
provide the **solution** for this lab's exercises.

---

*Lab 4 of 5 — OpenStack Networking Workshop*

