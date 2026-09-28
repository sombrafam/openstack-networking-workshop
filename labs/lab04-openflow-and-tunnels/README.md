# Lab 4 — OVS Advanced: OpenFlow Rules & Tunnels

| | |
|---|---|
| **Tier** | 2 – Open vSwitch |
| **Duration** | ~2 hours |
| **Prerequisites** | Labs 1–3 completed. A second host for Exercise 6. |
| **Builds on** | Lab 3 — OVS as an L2 Switch |

---

## 1. Objective

By the end of this lab you will be able to:

- Understand the structure of an OpenFlow flow (match + priority + action).
- Add and delete custom flow rules with `ovs-ofctl`.
- Implement a simple ACL by dropping traffic with a flow rule.
- Create a VXLAN overlay tunnel between two OVS bridges on separate hosts.
- Capture and read encapsulated VXLAN traffic with `tcpdump`, at both the
  underlay and overlay layers.
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

In OVS, a tunnel is simply **another port on the bridge**. You create it with
`ovs-vsctl add-port ... -- set interface ... type=vxlan` and configure it with
these options:

| Option | Meaning |
|--------|---------|
| `type=vxlan` | Encapsulate in VXLAN (UDP 4789 by default) |
| `options:remote_ip` | The **peer** host's underlay IP — the far tunnel endpoint |
| `options:local_ip` | Optional; pin the source address on multi-homed hosts |
| `options:key` | The VNI. A number pins it; `key=flow` lets flow rules set it |
| `options:dst_port` | Override the UDP port (Linux VXLAN often uses 8472) |

Once the port exists, OVS treats it like any other: the `NORMAL` action floods
broadcasts out of it and learns MAC addresses on it, which is all that is
needed for two bridges to merge into one broadcast domain.

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

### Two-host topology (Exercise 6)

Both hosts run an **identical** set of namespaces — same names, same interface
names, same bridge. Only the addresses differ. The VXLAN tunnel merges the two
`br-int` bridges into a single broadcast domain.

```
       Host A — underlay 192.168.122.11        Host B — underlay 192.168.122.12
 ┌──────────────────────────────────────┐ ┌──────────────────────────────────────┐
 │  ┌─ns-a──┐  ┌─ns-b──┐  ┌─ns-c──┐     │ │  ┌─ns-a──┐  ┌─ns-b──┐  ┌─ns-c──┐     │
 │  │veth-a │  │veth-b │  │veth-c │     │ │  │veth-a │  │veth-b │  │veth-c │     │
 │  │  .10  │  │  .20  │  │  .30  │     │ │  │ .110  │  │ .120  │  │ .130  │     │
 │  └───┬───┘  └───┬───┘  └───┬───┘     │ │  └───┬───┘  └───┬───┘  └───┬───┘     │
 │  veth-a-ovs veth-b-ovs veth-c-ovs    │ │  veth-a-ovs veth-b-ovs veth-c-ovs    │
 │      └──────────┼──────────┘         │ │      └──────────┼──────────┘         │
 │            ┌────┴─────┐              │ │            ┌────┴─────┐              │
 │            │  br-int  │              │ │            │  br-int  │              │
 │            │  vxlan0 ─┼──────────────┼─┼────────────┼─ vxlan0  │              │
 │            └──────────┘   VNI 100    │ │            └──────────┘              │
 │                 ens3 ────────────────┼─┼─ UDP/4789 ─── ens3                   │
 └──────────────────────────────────────┘ └──────────────────────────────────────┘

   Overlay  192.168.100.0/24  — ONE broadcast domain spanning both hosts
   Underlay 192.168.122.0/24  — the routed network that carries the tunnel
```

Note that `ns-a` exists on **both** hosts. Network namespaces are host-local
objects, so the names may repeat freely — there is no conflict, exactly as two
different hypervisors can each host a VM called `web-01`. The **IP addresses**,
however, share one overlay subnet and must be unique, which is why Host B uses
the `.110`/`.120`/`.130` range.

Two IP layers are in play at once, and keeping them straight is the whole point
of the exercise. The **underlay** addresses (`192.168.122.x`) belong to the
physical hosts and appear in the outer UDP packet. The **overlay** addresses
(`192.168.100.x`) belong to the namespaces and travel *inside* the
encapsulation. `ns-a` on Host A and `ns-b` on Host B believe they share an
Ethernet segment, even though their frames cross a routed network.

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


### Exercise 6 — Connect Two Hosts with a VXLAN Tunnel

> **This exercise needs a second machine.** Any two Linux hosts that can ping
> each other will do — two VMs, two cloud instances, or a VM and your laptop.
> Substitute your own underlay addresses for `192.168.122.11` (Host A) and
> `192.168.122.12` (Host B) throughout.
>
> **Solutions are not given here.** Work through the tasks using the concepts
> in §2.3 and the reference table in §5. The full commands and expected output
> are published in `lab04-solution.md`, released with Lab 5.

Everything so far has happened inside one kernel. A real cloud spreads a single
tenant network across many hypervisors, and the mechanism that makes that
possible is the **overlay tunnel**. Here you will build one by hand.

**Goal:** make `ns-a` on Host A ping `ns-b` on Host B, as though every
namespace on both machines were plugged into the same physical switch.

#### Task 6.1 — Mirror the topology onto Host B

Host A already has `br-int` with `ns-a`, `ns-b`, and `ns-c` from Lab 3. Build
the **same** topology on Host B, with identical namespace, veth, and bridge
names. Only the addresses change:

| | Host A | Host B |
|---|---|---|
| `ns-a` / `veth-a` | 192.168.100.10/24 | 192.168.100.110/24 |
| `ns-b` / `veth-b` | 192.168.100.20/24 | 192.168.100.120/24 |
| `ns-c` / `veth-c` | 192.168.100.30/24 | 192.168.100.130/24 |

**Requirements:**
- Open vSwitch installed, with a bridge named `br-int` that is up.
- Three namespaces, each holding one end of a veth pair; the other end is a
  port on `br-int`.
- Note the `/24` prefix: every namespace on **both** hosts is in one subnet.

**Verify before continuing:**
- `ns-a` → `ns-b` ping works *within* Host B (`.110` → `.120`).
- `ns-a` on Host A cannot yet reach `.110` — there is no path between the
  bridges.
- Both hosts can ping each other on the **underlay** (`192.168.122.x`).

> **Hint:** the Lab 3 build loop works unchanged on Host B; only the three
> `ip addr add` lines need new values.

#### Task 6.2 — Create the tunnel

Add a VXLAN port called `vxlan0` to `br-int` on **each** host so that the two
bridges join a single broadcast domain.

**Requirements:**
- Use VNI **100** on both ends.
- Each end points at the *peer's* underlay address, not its own.
- Leave the UDP port at the default.

Review the options table in §2.3 to decide which settings you need.

**Verify:**
- `ovs-vsctl show` lists `vxlan0` on both hosts with no `error:` field.
- `ovs-ofctl show br-int` gives the tunnel an OpenFlow port number.
- `ovs-appctl dpif/show` lists the tunnel in the datapath.

#### Task 6.3 — Prove the overlay works

Demonstrate that the two bridges are now one Layer 2 segment.

**Verify:**
- `ns-a` on Host A pings `192.168.100.120` (`ns-b` on Host B).
- Every namespace can reach all six addresses across both hosts.
- The ARP table inside `ns-a` gains an entry for a remote address — ARP, a
  **broadcast** protocol, crossed the tunnel.
- The MAC learning table on Host A shows remote MACs learned on the `vxlan0`
  port rather than on a veth port.

> **Hint:** `ovs-appctl fdb/show br-int` prints the MAC learning table, with
> the port each address was learned on.

#### Task 6.4 — Observe the encapsulation

This is the part worth slowing down for. Start a continuous ping between two
namespaces on **different** hosts, then capture the same traffic from three
vantage points and compare what each one shows you.

| # | Capture point | What you should see |
|---|---------------|---------------------|
| 1 | The **underlay** interface (`ens3`), filtered to UDP 4789 | The outer host-to-host packet, the VNI, and the inner frame |
| 2 | The **tunnel device** (`vxlan_sys_4789`) | The same frame, already decapsulated |
| 3 | `veth-b` **inside the namespace** on Host B | Only the overlay — what a VM would see |

**For each capture, answer:**
- Which source and destination addresses appear?
- Is the VNI visible? What value?
- How many IP headers are present?

**Then extend the observation:**
- Flush the ARP cache in `ns-a` and ping again while capturing. What does a
  **broadcast** look like on the wire, and where is it sent?
- Write a capture to a `.pcap` file and reopen it. Wireshark has a full VXLAN
  dissector if you prefer a GUI.
- Check the tunnel port's packet counters and confirm they increment.

> **Hints:** `vxlan_sys_4789` is the kernel-side device OVS creates for all
> VXLAN tunnels sharing that UDP port. If tcpdump shows only opaque UDP
> payload — which happens on a non-standard port — force the decoder with
> `-T vxlan`. Use `-w <file>` to save a capture and `-r <file>` to read it
> back. See §5 for the full command shapes.

**Questions:**
- How many IP headers does a single ping packet carry on the wire, and what
  are the source and destination of each?
- Why does the outer source UDP port change from packet to packet? (Hint:
  it is derived from a hash of the inner flow — what is that good for?)
- The overlay ping works, but `ping -s 1500` from `ns-a` fails or fragments.
  How much overhead does VXLAN add, and what MTU should the namespaces use?
- Both hosts have a namespace called `ns-a`. Why is that not a conflict, and
  what *would* conflict if you got it wrong?
- If you set `options:key=flow` instead of a fixed VNI, what would have to
  supply the VNI, and why is that what OVN does?
- Host A and Host B each have one tunnel port. How many tunnel ports would a
  20-hypervisor cloud need if built this way? What does that suggest about
  managing overlays by hand?

#### Task 6.5 — Clean up

Remove the tunnel from both hosts, and tear down the bridge and namespaces on
Host B. Leave Host A's topology intact — Lab 5 starts from it.

> **Troubleshooting:** if the overlay ping fails, check in this order —
> underlay reachability (`ping` the peer), UDP 4789 not blocked by a firewall
> or security group, `remote_ip` pointing at the *peer* rather than the local
> host, matching `key` on both ends, and `ovs-vsctl show` reporting no
> `error:` field on the interface.

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

**Tunnels and capture**

| Command | Description |
|---------|-------------|
| `ovs-vsctl add-port <br> vxlan0 -- set interface vxlan0 type=vxlan options:remote_ip=<ip> options:key=<vni>` | Create a VXLAN tunnel port |
| `ovs-vsctl del-port <br> vxlan0` | Remove the tunnel |
| `ovs-appctl dpif/show` | Show datapath ports including tunnels |
| `ovs-appctl fdb/show <bridge>` | MAC learning table — shows MACs learned via the tunnel |
| `ovs-ofctl dump-ports <bridge> vxlan0` | Per-tunnel packet/byte counters |
| `tcpdump -ni <underlay-if> -vv udp port 4789` | Watch encapsulated VXLAN traffic |
| `tcpdump -ni <underlay-if> -vv -T vxlan udp port <port>` | Force the VXLAN decoder on a non-standard port |
| `tcpdump -ni vxlan_sys_4789 -vv` | Watch decapsulated traffic on the tunnel device |
| `tcpdump -ni <if> -s0 -w <file>.pcap udp port 4789` | Capture to a file for Wireshark |
| `ip netns exec <ns> tcpdump -ni <veth>` | Watch the overlay from inside the namespace |

---

## 6. Review Questions

1. What are the three components of an OpenFlow flow rule?
2. If two flow rules both match a packet, which one wins?
3. What does `resubmit(,1)` do in a flow action?
4. What is the VNI in a VXLAN header? What is its bit width and maximum
   number of distinct values?
5. OVN installs dozens of flow tables on `br-int`. Why does it use multiple
   tables rather than a flat list?
6. In the Exercise 6 capture, which addresses appear in the outer IP header
   and which in the inner one? Which pair would a physical router on the
   path be able to see?
7. VXLAN adds roughly 50 bytes of overhead. If the underlay MTU is 1500,
   what MTU should the overlay interfaces use, and what symptom appears if
   you get this wrong?
8. Your overlay ping fails but the two hosts ping each other fine. List
   three things you would check, and the command for each.
9. Why is a full mesh of manually created tunnel ports impractical at
   scale, and how does OVN avoid that problem?

---

## 7. What's Next

In **Lab 5** we will move from manual OVS flow programming to **OVN (Open
Virtual Network)** — the SDN controller that sits on top of OVS and
automates logical switching, routing, ACLs, NAT, and DHCP. We will also
provide the **solution** for this lab's exercises.

---

*Lab 4 of 10 — OpenStack Networking Workshop*

