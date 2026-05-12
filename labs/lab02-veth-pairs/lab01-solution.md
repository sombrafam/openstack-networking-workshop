# Lab 1 — Solution: TAP Devices & Network Namespaces

> **This file is released with Lab 2.** It contains the full commands and
> expected output for Lab 1's exercises.

---

## Exercise 1 — Create Network Namespaces

```bash
# Create the namespaces
sudo ip netns add ns-red
sudo ip netns add ns-blue

# List them
ip netns list
```

**Expected output:**
```
ns-blue
ns-red
```

```bash
# Verify each namespace starts with only a loopback interface (DOWN)
sudo ip netns exec ns-red ip link
```

**Expected output:**
```
1: lo: <LOOPBACK> mtu 65536 qdisc noop state DOWN mode DEFAULT group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
```

```bash
sudo ip netns exec ns-blue ip link
```

**Expected output:** (same — only `lo`, state DOWN)

---

## Exercise 2 — Create TAP Devices

```bash
# Create TAP devices in the host (root) namespace
sudo ip tuntap add dev tap-red mode tap
sudo ip tuntap add dev tap-blue mode tap

# Verify they exist on the host
ip link show tap-red
ip link show tap-blue
```

**Expected output (for tap-red):**
```
X: tap-red: <BROADCAST,MULTICAST> mtu 1500 qdisc noop state DOWN mode DEFAULT group default qlen 1000
    link/ether xx:xx:xx:xx:xx:xx brd ff:ff:ff:ff:ff:ff
```

> The default state of a newly created TAP device is **DOWN** and it has no IP
> address assigned.

---

## Exercise 3 — Move TAP Devices into Namespaces

```bash
# Move tap-red into ns-red
sudo ip link set tap-red netns ns-red

# Move tap-blue into ns-blue
sudo ip link set tap-blue netns ns-blue
```

**Verify — TAP devices are gone from the host:**

```bash
ip link show tap-red 2>&1
```

**Expected output:**
```
Device "tap-red" does not exist.
```

**Verify — TAP devices are now inside their namespaces:**

```bash
sudo ip netns exec ns-red ip link
```

**Expected output:**
```
1: lo: <LOOPBACK> mtu 65536 qdisc noop state DOWN mode DEFAULT group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
X: tap-red: <BROADCAST,MULTICAST> mtu 1500 qdisc noop state DOWN mode DEFAULT group default qlen 1000
    link/ether xx:xx:xx:xx:xx:xx brd ff:ff:ff:ff:ff:ff
```

---

## Exercise 4 — Configure IP Addresses

```bash
# --- ns-red ---
# Bring loopback up
sudo ip netns exec ns-red ip link set lo up

# Bring tap-red up
sudo ip netns exec ns-red ip link set tap-red up

# Assign IP address
sudo ip netns exec ns-red ip addr add 10.0.1.1/24 dev tap-red

# Verify
sudo ip netns exec ns-red ip addr show tap-red
```

**Expected output:**
```
X: tap-red: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc ... state UP ...
    link/ether xx:xx:xx:xx:xx:xx brd ff:ff:ff:ff:ff:ff
    inet 10.0.1.1/24 scope global tap-red
       valid_lft forever preferred_lft forever
```

> **Note:** The state may show `UNKNOWN` instead of `UP` for TAP devices that
> have no user-space process attached. This is normal.

```bash
# --- ns-blue ---
sudo ip netns exec ns-blue ip link set lo up
sudo ip netns exec ns-blue ip link set tap-blue up
sudo ip netns exec ns-blue ip addr add 10.0.2.1/24 dev tap-blue

# Verify
sudo ip netns exec ns-blue ip addr show tap-blue
```

---

## Exercise 5 — Verify Isolation

```bash
# From ns-red, try to ping ns-blue's IP
sudo ip netns exec ns-red ping -c 2 10.0.2.1
```

**Expected output:**
```
ping: connect: Network is unreachable
```

> **Why?** There is no route to `10.0.2.0/24` from inside `ns-red`. The only
> connected route is `10.0.1.0/24` via `tap-red`. Even if there were a route,
> there is **no physical or virtual link** connecting the two namespaces.

```bash
# Check the routing table inside ns-red
sudo ip netns exec ns-red ip route
```

**Expected output:**
```
10.0.1.0/24 dev tap-red proto kernel scope link src 10.0.1.1
```

```bash
# Check the ARP table — should be empty
sudo ip netns exec ns-red ip neigh
```

**Expected output:** (empty — no neighbors discovered)

```bash
# Try to ping the host's IP (e.g., 192.168.1.100)
sudo ip netns exec ns-red ping -c 2 192.168.1.100
```

**Expected output:**
```
ping: connect: Network is unreachable
```

> The namespace has no default route and no interface connected to the host's
> network. It is completely isolated.

---

## Exercise 6 — Explore with tcpdump

**Terminal 1:**
```bash
sudo ip netns exec ns-red tcpdump -i tap-red -nn
```

**Terminal 2:**
```bash
sudo ip netns exec ns-blue ping -c 3 10.0.1.1
```

**Expected result:**

- The ping from `ns-blue` fails with "Network is unreachable".
- The tcpdump in `ns-red` shows **nothing** — zero packets.

> **Why?** The two namespaces have no connection between them. The ping never
> leaves `ns-blue` because there is no route and no link to the destination.
> For traffic to flow, we need a **veth pair** (Lab 2) or a **bridge** (Lab 3)
> connecting the two namespaces.

---

## Cleanup (optional)

If you need to tear down this lab:

```bash
sudo ip netns delete ns-red
sudo ip netns delete ns-blue
```

> Deleting a namespace automatically removes all interfaces that were moved
> into it (including the TAP devices).

---

## Review Questions — Answers

1. **TUN vs TAP:** TUN operates at Layer 3 (IP packets), TAP operates at
   Layer 2 (Ethernet frames). TAP is used for VMs because they need full
   Ethernet emulation.

2. **Namespace isolation:** Interfaces, IP addresses, routing tables, ARP
   tables, iptables/nftables rules, and socket bindings.

3. **Interface moved to namespace:** No, it disappears from the host because
   it now belongs to the other namespace's network stack. You can only see it
   with `ip netns exec <ns> ip link`.

4. **Same subnet, no communication:** They cannot communicate because there
   is no physical or virtual link between them. A veth pair, bridge, or
   other forwarding mechanism is needed.

5. **OpenStack components using namespaces:** Neutron DHCP agent
   (`qdhcp-<net-id>`), Neutron router (`qrouter-<router-id>`), and the
   metadata proxy.

---

*Lab 1 Solution — OpenStack Networking Workshop*

