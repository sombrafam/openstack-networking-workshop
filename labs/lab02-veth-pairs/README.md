# Lab 2 — Veth Pairs (Virtual Ethernet Pairs)

| | |
|---|---|
| **Tier** | 1 – Linux Networking Fundamentals |
| **Duration** | ~45 minutes |
| **Prerequisites** | Lab 1 completed |
| **Builds on** | Lab 1 — TAP Devices & Network Namespaces |

---

## 1. Objective

By the end of this lab you will be able to:

- Explain what a veth pair is and how it differs from a TAP device.
- Create a veth pair and place each end in a different namespace.
- Verify L2/L3 connectivity between two namespaces through a veth pair.
- Observe ARP resolution and packet flow with `tcpdump`.
- Understand why veth pairs are the fundamental building block for container
  and VM networking.

---

## 2. Background & Concepts

### 2.1 What Is a Veth Pair?

A **veth pair** (Virtual Ethernet pair) is a pair of virtual network interfaces
that are directly connected to each other — like a virtual crossover cable (or
a virtual patch cord). Any frame written to one end appears immediately on the
other end.

Key properties:
- Always created in pairs — you cannot have just one end without the other.
- If you delete one end, the other end is automatically deleted too.
- Both ends can be in the **same** or **different** network namespaces.
- When one end goes DOWN, the other end also signals link-down.

```
  ┌──── ns-red ──────┐       ┌──── ns-blue ─────┐
  │                   │       │                   │
  │  veth-red ●───────┼───────┼──● veth-blue      │
  │  10.0.0.1/24      │       │  10.0.0.2/24      │
  │                   │       │                   │
  └───────────────────┘       └───────────────────┘
       virtual crossover cable
```

### 2.2 Veth vs. TAP

| Feature | TAP device | Veth pair end |
|---------|-----------|---------------|
| Counterpart | User-space process (e.g., QEMU) | Another veth end (kernel) |
| Layer | Layer 2 (Ethernet) | Layer 2 (Ethernet) |
| Use case | VM NICs, TUN/TAP VPNs | Connecting namespaces, bridges |
| Created alone? | Yes | No — always in pairs |

### 2.3 ARP Across a Veth Pair

When namespace A wants to send an IP packet to namespace B:

1. A's kernel checks its routing table — destination is on the same subnet,
   so it will ARP for the destination IP.
2. An ARP Request (broadcast) is sent out `veth-red`.
3. The other end `veth-blue` receives it in `ns-blue`.
4. `ns-blue` recognizes its own IP in the ARP request and replies.
5. Now `ns-red` knows the MAC and can send the ICMP echo request.

This is exactly what happens in a real Ethernet network — veth pairs simply
make the "cable" virtual.

### 2.4 Veth Pairs in OpenStack

OpenStack Neutron uses veth pairs extensively:

- **DHCP agent namespace** (`qdhcp-<net-id>`): One end of a veth pair sits
  inside the namespace; the other end is plugged into the integration bridge
  (`br-int`).
- **Router namespace** (`qrouter-<router-id>`): Same pattern for the router's
  internal and external interfaces.
- In OVS-based deployments, patch ports replace veth pairs for some
  connections (better performance, no kernel crossing), but conceptually they
  are identical.

---

## 3. Architecture Diagram

Target state at the end of this lab:

```
 ┌───────────── Host (root namespace) ──────────────────────────────┐
 │                                                                   │
 │   ┌──── ns-red ──────┐           ┌──── ns-blue ─────┐           │
 │   │                   │           │                   │           │
 │   │  lo (UP)          │           │  lo (UP)          │           │
 │   │  veth-red         │           │  veth-blue        │           │
 │   │   10.0.0.1/24  ●──┼───────────┼──● 10.0.0.2/24   │           │
 │   │                   │  veth pair│                   │           │
 │   └───────────────────┘           └───────────────────┘           │
 │                                                                   │
 │   (ns-red and ns-blue can now ping each other)                    │
 └───────────────────────────────────────────────────────────────────┘
```

---

## 4. Exercises

All commands require **root** or **sudo** privileges.

### Exercise 1 — Create Namespaces

Clean up Lab 1 leftovers (if any) and create fresh namespaces `ns-red` and
`ns-blue`. Bring their loopback interfaces up.

**Verify:**
- `ip netns list` shows both namespaces.
- Each namespace has only `lo` (UP) visible inside it.

### Exercise 2 — Create a Veth Pair

Create a veth pair named `veth-red` and `veth-blue`. At this point both ends
are in the **host** (root) namespace.

**Verify:**
- `ip link show veth-red` and `ip link show veth-blue` both appear on the host.
- Notice the `@` annotation in the interface name — what does it indicate?

### Exercise 3 — Place Each End in a Namespace

Move `veth-red` into `ns-red` and `veth-blue` into `ns-blue`.

**Verify:**
- Both veth devices **disappear** from the host interface list.
- Each device is visible only inside its respective namespace.
- Check the `link-netns` attribute in `ip -d link show` — can you see the
  peer relationship?

### Exercise 4 — Assign IP Addresses and Bring Up

Assign IP addresses and bring up the interfaces in each namespace:
- `veth-red` → `10.0.0.1/24` in `ns-red`
- `veth-blue` → `10.0.0.2/24` in `ns-blue`

**Verify:**
- `ip addr show veth-red` inside `ns-red` shows the correct address.
- The interface state shows `UP` (or `LOWER_UP`).

### Exercise 5 — Test Connectivity

Ping from `ns-red` to `ns-blue` and vice versa.

**Verify:**
- Pings succeed in both directions.
- Check the ARP table inside `ns-red` — whose MAC address was learned?
- Check the routing table — what route was automatically added?

**Questions:**
- What changed compared to Lab 1 where the two namespaces could not
  communicate?
- Can the **host** (root namespace) reach `10.0.0.1` or `10.0.0.2`? Why
  or why not?

### Exercise 6 — Observe Traffic with tcpdump

Open two terminals and capture simultaneously:
- **Terminal 1:** `tcpdump` on `veth-red` inside `ns-red`
- **Terminal 2:** `tcpdump` on `veth-blue` inside `ns-blue`

Then from a third terminal, clear the ARP cache in `ns-red` and send a few
pings.

**Questions:**
- Do you see the same packets on both ends? What does this tell you about the
  veth pair?
- Can you identify the ARP request/reply separately from the ICMP packets?
- Is there any packet that appears on one side but not the other?

### Exercise 7 — Test Isolation from Host

From the host (NOT inside any namespace), try to ping `10.0.0.1` and
`10.0.0.2`.

**Questions:**
- Do the pings succeed? Why or why not?
- What would you need to add so the host can reach these IPs? (Think ahead to
  Lab 3 and Lab 4.)

### Exercise 8 — Break the Pair

Delete `veth-red` from inside `ns-red`.

**Verify:**
- Check what happened to `veth-blue` in `ns-blue`. Was it also deleted?
- What does this tell you about the lifecycle of veth pairs?

---

## 5. Key Commands Reference

| Command | Description |
|---------|-------------|
| `ip link add <name> type veth peer name <peer>` | Create a veth pair |
| `ip link set <dev> netns <ns>` | Move interface to a namespace |
| `ip link show <dev>` | Show interface details |
| `ip -d link show <dev>` | Show detailed info (incl. peer/veth metadata) |
| `ip addr add <ip>/<mask> dev <dev>` | Assign an IP address |
| `ip link set <dev> up` | Bring an interface up |
| `ip neigh` | View ARP/neighbor table |
| `ip route` | View routing table |
| `ip link delete <dev>` | Delete an interface (and its peer) |

---

## 6. Review Questions

1. What happens to the other end of a veth pair when you delete one end?
2. Why are veth interfaces always created in pairs and not as individual
   devices?
3. Can both ends of a veth pair be placed in the same namespace? Give a
   use case where that might be useful.
4. In OpenStack Neutron, how are veth pairs used to connect namespace-based
   services (DHCP, router) to the virtual switch?
5. If you have three namespaces that all need to communicate, is a veth pair
   sufficient? What is the limitation and what is the solution?

---

## 7. What's Next

In **Lab 3** we will introduce **Open vSwitch (OVS)** — a programmable virtual
switch that lets us connect **more than two** namespaces together through a
single bridge, without a full mesh of veth pairs. We will also provide the
**solution** for this lab's exercises.

---

*Lab 2 of 5 — OpenStack Networking Workshop*


