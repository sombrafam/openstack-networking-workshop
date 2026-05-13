# Lab 2 — Solution: Veth Pairs (Virtual Ethernet Pairs)

> **This file is released with Lab 3.** It contains the full commands and
> expected output for Lab 2's exercises.

---

## Exercise 1 — Create Namespaces

```bash
# Clean up from Lab 1 if needed
sudo ip netns delete ns-red 2>/dev/null
sudo ip netns delete ns-blue 2>/dev/null

# Create fresh namespaces
sudo ip netns add ns-red
sudo ip netns add ns-blue

# Bring up loopback in each
sudo ip netns exec ns-red ip link set lo up
sudo ip netns exec ns-blue ip link set lo up
```

---

## Exercise 2 — Create a Veth Pair

```bash
# Create the veth pair
sudo ip link add veth-red type veth peer name veth-blue

# Verify both ends exist on the host
ip link show veth-red
ip link show veth-blue
```

**Expected output (veth-red):**
```
X: veth-red@veth-blue: <BROADCAST,MULTICAST> mtu 1500 qdisc noop state DOWN mode DEFAULT group default qlen 1000
    link/ether xx:xx:xx:xx:xx:xx brd ff:ff:ff:ff:ff:ff
```

> Notice the `@veth-blue` — this shows the peer relationship. You can also
> see the peer's ifindex with `ip -d link show veth-red` (look for
> `link-netns` or the ifindex reference).

---

## Exercise 3 — Place Each End in a Namespace

```bash
sudo ip link set veth-red netns ns-red
sudo ip link set veth-blue netns ns-blue

# Verify they're gone from the host
ip link show veth-red 2>&1
# Output: Device "veth-red" does not exist.

# Verify they're in their namespaces
sudo ip netns exec ns-red ip link
sudo ip netns exec ns-blue ip link
```

**Expected output (ns-red):**
```
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN ...
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
X: veth-red@if Y: <BROADCAST,MULTICAST> mtu 1500 qdisc noop state DOWN ...
    link/ether xx:xx:xx:xx:xx:xx brd ff:ff:ff:ff:ff:ff link-netns ns-blue
```

> The `@if Y` indicates the peer's interface index, and `link-netns ns-blue`
> confirms the peer is in the `ns-blue` namespace.

---

## Exercise 4 — Assign IP Addresses and Bring Up

```bash
# --- ns-red ---
sudo ip netns exec ns-red ip addr add 10.0.0.1/24 dev veth-red
sudo ip netns exec ns-red ip link set veth-red up

# --- ns-blue ---
sudo ip netns exec ns-blue ip addr add 10.0.0.2/24 dev veth-blue
sudo ip netns exec ns-blue ip link set veth-blue up

# Verify
sudo ip netns exec ns-red ip addr show veth-red
sudo ip netns exec ns-blue ip addr show veth-blue
```

**Expected output (ns-red):**
```
X: veth-red@if Y: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 ... state UP ...
    link/ether xx:xx:xx:xx:xx:xx brd ff:ff:ff:ff:ff:ff link-netns ns-blue
    inet 10.0.0.1/24 scope global veth-red
       valid_lft forever preferred_lft forever
```

---

## Exercise 5 — Test Connectivity

```bash
sudo ip netns exec ns-red ping -c 3 10.0.0.2
```

**Expected output:**
```
PING 10.0.0.2 (10.0.0.2) 56(84) bytes of data.
64 bytes from 10.0.0.2: icmp_seq=1 ttl=64 time=0.045 ms
64 bytes from 10.0.0.2: icmp_seq=2 ttl=64 time=0.038 ms
64 bytes from 10.0.0.2: icmp_seq=3 ttl=64 time=0.041 ms

--- 10.0.0.2 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2045ms
```

> **What changed compared to Lab 1?** In Lab 1, the TAP devices were isolated
> — there was no link between the namespaces. Now the veth pair provides a
> direct Layer 2 connection.

```bash
# Check ARP table in ns-red
sudo ip netns exec ns-red ip neigh
```

**Expected output:**
```
10.0.0.2 dev veth-red lladdr xx:xx:xx:xx:xx:xx REACHABLE
```

> ARP resolved the MAC address of `veth-blue` (the peer in `ns-blue`).

```bash
# Check routing table in ns-red
sudo ip netns exec ns-red ip route
```

**Expected output:**
```
10.0.0.0/24 dev veth-red proto kernel scope link src 10.0.0.1
```

> The kernel automatically added a connected route for the `10.0.0.0/24`
> subnet when we assigned the IP address.

---

## Exercise 6 — Observe Traffic with tcpdump

**Terminal 1:**
```bash
sudo ip netns exec ns-red tcpdump -i veth-red -nn -e
```

**Terminal 2:**
```bash
sudo ip netns exec ns-blue tcpdump -i veth-blue -nn -e
```

**Terminal 3:**
```bash
sudo ip netns exec ns-red ping -c 2 10.0.0.2
```

**Expected tcpdump output (Terminal 1 — veth-red in ns-red):**
```
xx:xx:xx:xx:xx:xx > ff:ff:ff:ff:ff:ff, ethertype ARP (0x0806), length 42: Request who-has 10.0.0.2 tell 10.0.0.1, length 28
xx:xx:xx:xx:xx:xx > xx:xx:xx:xx:xx:xx, ethertype ARP (0x0806), length 42: Reply 10.0.0.2 is-at xx:xx:xx:xx:xx:xx, length 28
xx:xx:xx:xx:xx:xx > xx:xx:xx:xx:xx:xx, ethertype IPv4 (0x0800), length 98: 10.0.0.1 > 10.0.0.2: ICMP echo request, id ..., seq 1, length 64
xx:xx:xx:xx:xx:xx > xx:xx:xx:xx:xx:xx, ethertype IPv4 (0x0800), length 98: 10.0.0.2 > 10.0.0.1: ICMP echo reply, id ..., seq 1, length 64
```

> You see the exact same packets on both sides — the veth pair is a
> transparent pipe. The ARP request/reply happens only for the first ping
> (subsequent pings use the cached ARP entry).

---

## Exercise 7 — Test Isolation from Host

```bash
# From the host (NOT inside any namespace)
ping -c 2 10.0.0.1
ping -c 2 10.0.0.2
```

**Expected output:**
```
ping: connect: Network is unreachable
```

> **Why?** The host has no interface on the `10.0.0.0/24` subnet. Both veth
> endpoints are inside namespaces — the host cannot see them. For the host
> to reach the namespaces, you would need a bridge with an IP on the same
> subnet (covered in Labs 3 and 4).

---

## Exercise 8 — Break the Pair

```bash
# Delete veth-red from inside ns-red
sudo ip netns exec ns-red ip link delete veth-red

# Check what happened to veth-blue in ns-blue
sudo ip netns exec ns-blue ip link
```

**Expected output:**
```
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 ...
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
```

> `veth-blue` was **automatically deleted** when its peer `veth-red` was
> removed. This is a fundamental property of veth pairs — they live and die
> together. You cannot recreate just one end; you must create a new pair.

---

## Cleanup

```bash
# Delete the namespaces (this also cleans up any remaining interfaces)
sudo ip netns delete ns-red
sudo ip netns delete ns-blue
```

---

## Review Questions — Answers

1. **One end deleted:** The other end is automatically deleted. Veth pairs
   are always a linked pair.

2. **Why always pairs:** A single-ended veth would have nowhere to send
   frames — it would be a dead-end. The pair defines a point-to-point link.

3. **Both ends in the same namespace:** Yes, it works. A use case is creating
   a looped test interface or connecting two bridges within the same namespace.
   OVS uses patch ports (similar concept) internally.

4. **OpenStack usage:** Neutron uses veth pairs to connect DHCP agent
   namespaces (`qdhcp-*`) and router namespaces (`qrouter-*`) to the
   integration bridge (`br-int`). One end sits in the namespace, the other
   is plugged into OVS or a Linux bridge.

5. **Three namespaces:** You'd need 3 veth pairs for a full mesh (A↔B, A↔C,
   B↔C). This doesn't scale — for N namespaces you need N×(N-1)/2 pairs.
   A **virtual switch** (Lab 3) lets you connect all namespaces to a single
   point with only N veth pairs.

---

*Lab 2 Solution — OpenStack Networking Workshop*

