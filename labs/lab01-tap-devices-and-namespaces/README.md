# Lab 1 — TAP Devices & Network Namespaces

| | |
|---|---|
| **Tier** | 1 – Linux Networking Fundamentals |
| **Duration** | ~45 minutes |
| **Prerequisites** | A workstation or VM running Ubuntu 22.04+ with root/sudo access |

---

## 1. Objective

By the end of this lab you will be able to:

- Explain what a TAP device is and why it is used in virtualization.
- Explain what a network namespace is and what it isolates.
- Create network namespaces and TAP devices.
- Move a network interface into a namespace.
- Verify that namespaces are truly isolated from each other and from the host.

---

## 2. Background & Concepts

### 2.1 TAP / TUN Devices

In Linux, the kernel provides two types of virtual network devices that
user-space programs can read/write directly:

| Device | Layer | Typical use |
|--------|-------|-------------|
| **TUN** | Layer 3 (IP packets) | VPNs (e.g., OpenVPN, WireGuard) |
| **TAP** | Layer 2 (Ethernet frames) | Virtual machines (QEMU/KVM), containers |

When a VM is launched by QEMU/KVM, a **TAP** device is created on the host.
The VM's virtual NIC is connected to the host-side TAP — every Ethernet frame
the VM sends exits through the TAP device and can be forwarded by the host's
network stack (typically into a bridge or Open vSwitch).

```
  ┌────────────┐
  │     VM     │
  │   (eth0)   │
  └─────┬──────┘
        │  ← virtio / emulated NIC
  ┌─────┴──────┐
  │  TAP device │  (host kernel)
  │   tap0      │
  └─────┬──────┘
        │
   bridge / OVS
```

### 2.2 Network Namespaces

A **network namespace** is a kernel feature that creates an **isolated copy**
of the entire network stack. Each namespace has its own:

- Network interfaces (including its own `lo`)
- IP addresses
- Routing table
- ARP / neighbor table
- iptables / nftables rules
- Socket bindings

By default, every process runs in the **root (default) namespace**. When you
create a new namespace, it starts with **only** a loopback interface — no other
interfaces, no routes, completely disconnected.

```
 ┌──────────── Host (root namespace) ──────────────────┐
 │  lo, eth0, br0, …                                   │
 │                                                      │
 │   ┌─── ns-red ────┐    ┌─── ns-blue ───┐           │
 │   │  lo (down)     │    │  lo (down)     │           │
 │   │  (no routes)   │    │  (no routes)   │           │
 │   │  (own iptables)│    │  (own iptables)│           │
 │   └────────────────┘    └────────────────┘           │
 └──────────────────────────────────────────────────────┘
```

This is exactly how OpenStack (via Neutron) isolates DHCP agents, router
namespaces, and even metadata proxies — each runs inside its own network
namespace so that overlapping IP ranges from different tenants never conflict.

### 2.3 How They Come Together

In a real OpenStack deployment:

1. A **namespace** is created for every [1] Neutron router and DHCP agent.
2. A **TAP device** is created for every VM port.
3. The TAP device is plugged into a bridge (Linux bridge or OVS).
4. A **veth pair** (Lab 2) connects the namespace to the bridge.

In this lab we focus on steps 1 and 2 — namespaces and TAP devices — to
understand the building blocks before wiring them together.

> **[1] Note:** This is true for some networking configurations (l3ha, dvr, etc.)
> OVN uses a more advanced approach.

---

## 3. Architecture Diagram

The target state at the end of this lab:

```
 ┌───────────── Host (root namespace) ──────────────────────────┐
 │                                                               │
 │   ┌──── ns-red ──────┐       ┌──── ns-blue ─────┐           │
 │   │                   │       │                   │           │
 │   │  lo    ◄── up     │       │  lo    ◄── up     │           │
 │   │  tap-red          │       │  tap-blue         │           │
 │   │   10.0.1.1/24     │       │   10.0.2.1/24     │           │
 │   │                   │       │                   │           │
 │   └───────────────────┘       └───────────────────┘           │
 │                                                               │
 │   (no connectivity between ns-red and ns-blue — they are     │
 │    completely isolated at this point)                          │
 └───────────────────────────────────────────────────────────────┘
```

> **Note:** At this stage, `ns-red` and `ns-blue` **cannot** communicate with
> each other or with the host. This is by design — we have not yet created any
> connection between them. That comes in Lab 2.

---

## 4. Exercises

Work through the following exercises. All commands require **root** or
**sudo** privileges.

### Exercise 1 — Create Network Namespaces

Create two network namespaces called `ns-red` and `ns-blue`.

**Verify:**
- List all namespaces on the system.
- Run `ip link` inside each namespace — you should see **only** the `lo`
  interface, and it should be `DOWN`.

### Exercise 2 — Create TAP Devices

Create two TAP devices: `tap-red` and `tap-blue`.

**Verify:**
- List interfaces on the host — both TAP devices should appear.
- What is the default state of a newly created TAP device?

### Exercise 3 — Move TAP Devices into Namespaces

Move `tap-red` into `ns-red` and `tap-blue` into `ns-blue`.

**Verify:**
- The TAP devices should **disappear** from the host's interface list.
- They should now be visible inside their respective namespaces.

### Exercise 4 — Configure IP Addresses

Assign IP addresses inside each namespace:
- `tap-red` → `10.0.1.1/24`
- `tap-blue` → `10.0.2.1/24`

Remember to bring the interfaces **UP** (both the TAP device and `lo`).

**Verify:**
- `ip addr` inside each namespace shows the correct IP.
- `lo` is UP in each namespace.

### Exercise 5 — Verify Isolation

From inside `ns-red`, try to:
1. Ping `10.0.2.1` (the IP in `ns-blue`) — does it work? Why or why not?
2. Ping the host's IP address — does it work?
3. Check the routing table inside the namespace — what routes exist?
4. Check the ARP table — is it empty?

Now try the same from `ns-blue`.

### Exercise 6 — Explore with tcpdump

Open two terminal windows:
1. In terminal 1, start `tcpdump` inside `ns-red` listening on `tap-red`.
2. In terminal 2, try to ping `10.0.1.1` from `ns-blue`.

**Questions:**
- Do you see any packets in the tcpdump output? Why or why not?
- What would need to change for traffic to flow between the two namespaces?

---

## 5. Key Commands Reference

| Command | Description |
|---------|-------------|
| `ip netns add <name>` | Create a network namespace |
| `ip netns list` | List all network namespaces |
| `ip netns exec <name> <cmd>` | Run a command inside a namespace |
| `ip netns delete <name>` | Delete a namespace |
| `ip tuntap add dev <name> mode tap` | Create a TAP device |
| `ip link set <dev> netns <ns>` | Move an interface to a namespace |
| `ip link set <dev> up` | Bring an interface up |
| `ip addr add <ip>/<mask> dev <dev>` | Assign an IP address |
| `tcpdump -i <dev> -nn` | Capture packets on an interface |

---

## 6. Review Questions

1. What is the difference between a TUN and a TAP device?
2. What components of the network stack does a namespace isolate?
3. When you move an interface into a namespace, can you still see it from the
   host? Why?
4. If two namespaces each have interfaces with IPs on the same subnet, can they
   communicate? What is missing?
5. In OpenStack, what uses network namespaces? Name at least two components.

---

## 7. What's Next

In **Lab 2** we will create **veth pairs** — virtual Ethernet cables — that
connect two namespaces together so traffic can actually flow between them. We
will also provide the **solution** for this lab's exercises.

---

*Lab 1 of 5 — OpenStack Networking Workshop*
