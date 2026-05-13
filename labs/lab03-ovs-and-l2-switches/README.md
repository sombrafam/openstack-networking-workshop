# Lab 3 — OVS as an L2 Switch

| | |
|---|---|
| **Tier** | 2 – Open vSwitch |
| **Duration** | ~1 hour |
| **Prerequisites** | Labs 1–2 completed |
| **Builds on** | Lab 2 — Veth Pairs |

---

## 1. Objective

By the end of this lab you will be able to:

- Explain what Open vSwitch is and why it is used in OpenStack instead of
  Linux bridges.
- Install OVS and create an OVS bridge.
- Connect three or more namespaces through a single OVS bridge using veth pairs.
- Inspect OVS configuration and the default flow table.
- Observe MAC learning and ARP broadcast behavior on an OVS bridge.

---

## 2. Background & Concepts

### 2.1 Why a Virtual Switch?

In Lab 2, we connected **two** namespaces with a single veth pair. But what
if we have **three or more** namespaces?

- **Full mesh of veths:** N×(N-1)/2 pairs — does not scale.
- **A virtual switch (star topology):** Each namespace gets **one** veth pair.
  One end goes in the namespace, the other is plugged into the switch. The
  switch handles forwarding. For N namespaces that is just N veth pairs.

```
  Full mesh (3 namespaces):     Star via switch:

    ns-a ──── ns-b                ns-a ─┐
      \      /                    ns-b ─┼── br-int (OVS)
       ns-c                       ns-c ─┘
    (3 pairs, O(N²))            (3 pairs, O(N))
```

### 2.2 Why OVS Instead of a Linux Bridge?

The Linux kernel has a built-in bridge (`ip link add type bridge`) that does
the same L2 switching job. However, it has fundamental limitations:

| Feature | Linux Bridge | Open vSwitch |
|---------|-------------|-------------|
| MAC learning / forwarding | ✅ | ✅ |
| Programmable flow rules | ❌ | ✅ |
| OpenFlow controller support | ❌ | ✅ |
| VXLAN / Geneve tunnels | ❌ | ✅ |
| Used by OVN | ❌ | ✅ |

**OVN sits directly on top of OVS.** It programs OVS via OpenFlow to
implement all logical networking: switching, routing, ACLs, NAT, and DHCP.
Linux bridges are not part of the OVN data path — which is why this workshop
goes straight to OVS.

### 2.3 OVS Architecture

```
  ┌──────────────────────────────────────────┐
  │               Open vSwitch               │
  │                                          │
  │  ┌────────────┐    ┌──────────────────┐  │
  │  │ovs-vswitchd│◄──►│   ovsdb-server   │  │
  │  │(data plane)│    │  (config DB)     │  │
  │  └─────┬──────┘    └──────────────────┘  │
  │        │  OpenFlow                        │
  │  ┌─────▼──────┐                          │
  │  │ Flow tables│ ← programmed by          │
  │  │ (kernel    │   controller or          │
  │  │  datapath) │   ovs-ofctl manually     │
  │  └────────────┘                          │
  └──────────────────────────────────────────┘

  Management:  ovs-vsctl   (talks to ovsdb-server)
  Flow mgmt:   ovs-ofctl   (talks to ovs-vswitchd via OpenFlow)
  Diagnostics: ovs-appctl  (talks to ovs-vswitchd)
```

### 2.4 The Default NORMAL Flow

When you create an OVS bridge, it comes with a single default flow:

```
table=0, priority=0, actions=NORMAL
```

The `NORMAL` action tells OVS to behave like a traditional learning switch —
identical to a Linux bridge. It learns source MACs, looks up destination MACs
in its forwarding table, and floods unknowns. In later labs (and in OVN) this
flow is replaced by precise programmed rules.

### 2.5 OVS Forwarding Database

Like a Linux bridge, OVS maintains a MAC → port mapping table. You can
inspect it with `ovs-appctl fdb/show br-int`. When a frame arrives:

1. **Learn:** Record source MAC → ingress port.
2. **Lookup:** Search destination MAC.
3. **Forward or flood:** Send to the known port, or flood to all ports.

### 2.6 OVS in OpenStack

In an OpenStack compute node with the OVN mechanism driver:
- `br-int` is the integration bridge — VM TAP devices and namespace veths
  connect here.
- `br-ex` / `br-provider` is the external bridge — connects to the physical
  network.
- All forwarding rules on `br-int` are installed as OpenFlow rules by
  `ovn-controller` (covered in Lab 6).

---

## 3. Architecture Diagram

Target state at the end of this lab:

```
 ┌──────────────────── Host (root namespace) ──────────────────────────┐
 │                                                                      │
 │   ┌──── ns-a ──────┐  ┌──── ns-b ──────┐  ┌──── ns-c ──────┐     │
 │   │  veth-a         │  │  veth-b         │  │  veth-c         │     │
 │   │  192.168.100.10 │  │  192.168.100.20 │  │  192.168.100.30 │     │
 │   └───────┬─────────┘  └───────┬─────────┘  └───────┬─────────┘     │
 │           │                     │                     │               │
 │      veth-a-ovs            veth-b-ovs            veth-c-ovs          │
 │           │                     │                     │               │
 │   ┌───────┴─────────────────────┴─────────────────────┴───────┐      │
 │   │                      br-int  (OVS bridge)                  │      │
 │   │           default flow: table=0 priority=0 NORMAL          │      │
 │   └────────────────────────────────────────────────────────────┘      │
 │                                                                      │
 └──────────────────────────────────────────────────────────────────────┘
```

> **Naming convention:** For each namespace `ns-X`, we create a veth pair:
> - `veth-X` — the end that goes **inside** the namespace.
> - `veth-X-ovs` — the end that stays in the **host** and is added to `br-int`.

---

## 4. Exercises

All commands require **root** or **sudo** privileges.

### Exercise 1 — Install Open vSwitch

```bash
sudo apt install -y openvswitch-switch
```

**Verify:**
- `ovs-vsctl show` — should show an empty OVS configuration with a version.
- `systemctl status openvswitch-switch` — service should be active/running.

### Exercise 2 — Create an OVS Bridge

Create an OVS bridge called `br-int` and bring it up.

**Verify:**
- `ovs-vsctl show` — shows `br-int`.
- `ip link show br-int` — the bridge appears as a kernel interface.
- `ovs-ofctl dump-flows br-int` — what flows exist by default?

**Questions:**
- What is the default flow installed on a new OVS bridge?
- What does `actions=NORMAL` mean?

### Exercise 3 — Create Three Namespaces with Veth Pairs

For each of `ns-a`, `ns-b`, and `ns-c`:
1. Create the namespace and bring up its loopback.
2. Create a veth pair (`veth-X` / `veth-X-ovs`).
3. Move `veth-X` into the namespace.
4. Add `veth-X-ovs` to `br-int` using `ovs-vsctl add-port`.
5. Bring all interfaces UP (both ends of each veth pair).

**Verify:**
- `ovs-vsctl show` — lists all three ports on `br-int`.

### Exercise 4 — Assign IP Addresses

Inside each namespace, assign an IP from `192.168.100.0/24`:
- `ns-a`: `192.168.100.10/24`
- `ns-b`: `192.168.100.20/24`
- `ns-c`: `192.168.100.30/24`

### Exercise 5 — Verify Full Connectivity

Ping between all pairs:
- `ns-a` → `ns-b`
- `ns-a` → `ns-c`
- `ns-b` → `ns-c`

All pings should succeed — the default `NORMAL` flow handles MAC learning.

### Exercise 6 — Inspect OVS State

Run the following and understand the output:

```bash
ovs-vsctl show
ovs-ofctl dump-flows br-int
ovs-ofctl dump-ports br-int

ovs-appctl fdb/show br-int
```

**Questions:**
- How many flows are installed in `dump-flows`?
- After pinging, what does `ovs-appctl fdb/show br-int` show?
- Can you match each MAC in the FDB to the correct `veth-X-ovs` port?
- What does `n_packets` in `dump-flows` tell you?

### Exercise 7 — Observe ARP and Broadcast Behavior

Open `tcpdump` on all three `veth-X-ovs` ports (three terminals), then:
1. Clear the ARP cache in `ns-a`: `ip netns exec ns-a ip neigh flush all`
2. Ping from `ns-a` to `ns-b`.

**Questions:**
- Do you see the ARP request on `veth-c-ovs` as well? Why?
- Do you see the ARP **reply** on `veth-c-ovs`? Why or why not?
- What about the ICMP echo request/reply — do they appear on `veth-c-ovs`?
- How is this behavior identical to a Linux bridge or a physical switch?

### Exercise 8 — Clean Up

```bash
sudo ovs-vsctl del-br br-int
sudo ip netns del ns-a
sudo ip netns del ns-b
sudo ip netns del ns-c
```

---

## 5. Key Commands Reference

| Command | Description |
|---------|-------------|
| `ovs-vsctl add-br <name>` | Create an OVS bridge |
| `ovs-vsctl del-br <name>` | Delete an OVS bridge |
| `ovs-vsctl add-port <bridge> <port>` | Add a port to a bridge |
| `ovs-vsctl del-port <bridge> <port>` | Remove a port from a bridge |
| `ovs-vsctl show` | Show full OVS configuration |
| `ovs-ofctl dump-flows <bridge>` | Show all flow rules |
| `ovs-ofctl dump-ports <bridge>` | Show per-port statistics |
| `ovs-ofctl show <bridge>` | Show port numbers and names |
| `ovs-appctl fdb/show <bridge>` | Show the MAC learning table |

---

## 6. Review Questions

1. What are the three main OVS CLI tools and what does each one talk to?
2. What does the default `NORMAL` action do? How does it differ from a
   programmed OpenFlow flow?
3. Why does OVN use OVS instead of Linux bridges?
4. What happens when a frame arrives at OVS with a destination MAC that is
   not in the forwarding table?
5. In OpenStack, what OVS bridge do VM TAP devices connect to?
6. In the current setup, can the **host** communicate with the namespaces at
   the IP level? What is missing? (Hint: think about what IP the host needs)

---

## 7. What's Next

In **Lab 4** we will go beyond the default `NORMAL` flow and program **custom
OpenFlow rules** — implementing ACLs by flow, tracing simulated packets
through the pipeline, and creating **VXLAN overlay tunnels** between OVS
bridges. We will also provide the **solution** for this lab's exercises.

---

*Lab 3 of 5 — OpenStack Networking Workshop*

