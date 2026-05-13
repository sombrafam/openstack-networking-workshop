# Lab 3 — Solution: OVS as an L2 Switch

> **This file is released with Lab 4.** It contains the full commands and
> expected output for Lab 3's exercises.

---

## Exercise 1 — Install Open vSwitch

```bash
sudo apt install -y openvswitch-switch
```

**Verify:**

```bash
ovs-vsctl show
```

**Expected output:**
```
xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    ovs_version: "X.XX.X"
```

```bash
systemctl status openvswitch-switch
```

> Service should show `active (exited)` or `active (running)`.

---

## Exercise 2 — Create an OVS Bridge

```bash
# Create the bridge
sudo ovs-vsctl add-br br-int

# Bring it up
sudo ip link set br-int up

# Verify
ovs-vsctl show
```

**Expected output:**
```
xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    Bridge br-int
        Port br-int
            Interface br-int
                type: internal
    ovs_version: "X.XX.X"
```

```bash
# Check default flows
sudo ovs-ofctl dump-flows br-int
```

**Expected output:**
```
 cookie=0x0, duration=X.XXXs, table=0, n_packets=0, n_bytes=0, priority=0 actions=NORMAL
```

> **What is this flow?** `priority=0, actions=NORMAL` is the default
> "catch-all" flow. The `NORMAL` action tells OVS to behave like a
> traditional learning switch — learn source MACs, lookup destination MACs,
> and flood unknowns. This makes OVS behave identically to a Linux bridge
> out of the box.

---

## Exercise 3 — Create Three Namespaces with Veth Pairs

```bash
# Clean up from previous labs
sudo ip netns delete ns-red 2>/dev/null
sudo ip netns delete ns-blue 2>/dev/null

# Create namespaces
for ns in ns-a ns-b ns-c; do
    sudo ip netns add $ns
    sudo ip netns exec $ns ip link set lo up
done

# Create veth pairs and wire them up
for ns in a b c; do
    # Create the veth pair
    sudo ip link add veth-${ns} type veth peer name veth-${ns}-ovs

    # Move one end into the namespace
    sudo ip link set veth-${ns} netns ns-${ns}

    # Add the other end to br-int as an OVS port
    sudo ovs-vsctl add-port br-int veth-${ns}-ovs

    # Bring up the host-side end
    sudo ip link set veth-${ns}-ovs up

    # Bring up the namespace-side end
    sudo ip netns exec ns-${ns} ip link set veth-${ns} up
done

# Verify OVS ports
ovs-vsctl show
```

**Expected output:**
```
xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    Bridge br-int
        Port veth-a-ovs
            Interface veth-a-ovs
        Port br-int
            Interface br-int
                type: internal
        Port veth-b-ovs
            Interface veth-b-ovs
        Port veth-c-ovs
            Interface veth-c-ovs
    ovs_version: "X.XX.X"
```

---

## Exercise 4 — Assign IP Addresses

```bash
sudo ip netns exec ns-a ip addr add 192.168.100.10/24 dev veth-a
sudo ip netns exec ns-b ip addr add 192.168.100.20/24 dev veth-b
sudo ip netns exec ns-c ip addr add 192.168.100.30/24 dev veth-c
```

**Verify:**
```bash
sudo ip netns exec ns-a ip addr show veth-a
```

**Expected output:**
```
X: veth-a@if Y: <BROADCAST,MULTICAST,UP,LOWER_UP> ...
    inet 192.168.100.10/24 scope global veth-a
```

---

## Exercise 5 — Verify Full Connectivity

```bash
# ns-a → ns-b
sudo ip netns exec ns-a ping -c 2 192.168.100.20

# ns-a → ns-c
sudo ip netns exec ns-a ping -c 2 192.168.100.30

# ns-b → ns-c
sudo ip netns exec ns-b ping -c 2 192.168.100.30
```

**Expected output (each):**
```
PING 192.168.100.XX (...) 56(84) bytes of data.
64 bytes from 192.168.100.XX: icmp_seq=1 ttl=64 time=0.0XX ms
64 bytes from 192.168.100.XX: icmp_seq=2 ttl=64 time=0.0XX ms
```

All pings succeed — the default `NORMAL` flow handles MAC learning and
forwarding just like a Linux bridge. 🎉

---

## Exercise 6 — Inspect OVS State

```bash
# Full OVS configuration
ovs-vsctl show

# Flow rules
sudo ovs-ofctl dump-flows br-int
```

**Expected output:**
```
 cookie=0x0, duration=XXX.XXXs, table=0, n_packets=XX, n_bytes=XXXX, priority=0 actions=NORMAL
```

> There is still only one flow — the default NORMAL rule. The `n_packets`
> counter now shows how many packets have been processed by this flow.

```bash
# Per-port statistics
sudo ovs-ofctl dump-ports br-int
```

**Expected output:**
```
OFPST_PORT reply ...
  port LOCAL: rx pkts=X, ...
  port  1: rx pkts=XX, bytes=XXX, ...
  port  2: rx pkts=XX, bytes=XXX, ...
  port  3: rx pkts=XX, bytes=XXX, ...
```

```bash
# MAC learning table (forwarding database)
sudo ovs-appctl fdb/show br-int
```

**Expected output:**
```
 port  VLAN  MAC                Age
    1     0  xx:xx:xx:xx:xx:xx    1
    2     0  xx:xx:xx:xx:xx:xx    1
    3     0  xx:xx:xx:xx:xx:xx    1
```

> Each port maps to a learned MAC — the MAC of the `veth-X` interface
> inside the corresponding namespace. You can verify by running
> `ip netns exec ns-a ip link show veth-a` and comparing the MAC.

```bash
# Port number to name mapping
sudo ovs-ofctl show br-int
```

**Expected output:**
```
OFPT_FEATURES_REPLY ...
 1(veth-a-ovs): addr:xx:xx:xx:xx:xx:xx
     ...
 2(veth-b-ovs): addr:xx:xx:xx:xx:xx:xx
     ...
 3(veth-c-ovs): addr:xx:xx:xx:xx:xx:xx
     ...
 LOCAL(br-int): addr:xx:xx:xx:xx:xx:xx
     ...
```

---

## Exercise 7 — Observe ARP and Broadcast Behavior

**Terminal 1:**
```bash
sudo tcpdump -i veth-a-ovs -nn -e
```

**Terminal 2:**
```bash
sudo tcpdump -i veth-b-ovs -nn -e
```

**Terminal 3:**
```bash
sudo tcpdump -i veth-c-ovs -nn -e
```

**Terminal 4:**
```bash
# Clear ARP cache and ping
sudo ip netns exec ns-a ip neigh flush all
sudo ip netns exec ns-a ping -c 2 192.168.100.20
```

**What you should observe:**

| Packet | veth-a-ovs | veth-b-ovs | veth-c-ovs |
|--------|-----------|-----------|-----------|
| ARP Request (broadcast) | ✅ | ✅ | ✅ |
| ARP Reply (unicast) | ✅ | ✅ | ❌ |
| ICMP Echo Request | ✅ | ✅ | ❌ |
| ICMP Echo Reply | ✅ | ✅ | ❌ |

> **Why?** The ARP request is a **broadcast** — OVS floods it to ALL
> ports (same as a physical switch). The ARP reply, ICMP request, and
> ICMP reply are all **unicast** — OVS already knows which port the
> destination MAC is on (from the ARP exchange), so it forwards only
> to the correct port. `ns-c` never sees traffic that isn't destined
> for it.
>
> This is identical behavior to a Linux bridge — the `NORMAL` action
> makes OVS behave as a traditional MAC-learning switch.

---

## Exercise 8 — Clean Up

```bash
sudo ovs-vsctl del-br br-int
sudo ip netns del ns-a
sudo ip netns del ns-b
sudo ip netns del ns-c
```

> Deleting the OVS bridge automatically removes all ports. Deleting the
> namespaces removes any interfaces that were inside them.

---

## Review Questions — Answers

1. **Three OVS CLI tools:**
   - `ovs-vsctl` — talks to `ovsdb-server` (the configuration database).
     Used for bridge/port management.
   - `ovs-ofctl` — talks to `ovs-vswitchd` via OpenFlow. Used for flow
     rule management and port statistics.
   - `ovs-appctl` — talks to `ovs-vswitchd` via a Unix control socket.
     Used for diagnostics (FDB, coverage stats, tracing).

2. **NORMAL action:** Makes OVS behave like a traditional learning switch —
   learn source MACs, lookup destination MACs, flood unknowns. A programmed
   flow can match specific fields and take precise actions (drop, output to
   a specific port, modify headers, etc.).

3. **Why OVN uses OVS:** OVN needs programmable flow tables (OpenFlow) to
   implement logical networking (switching, routing, ACLs, NAT, DHCP) —
   Linux bridges don't support OpenFlow or tunnel encapsulation natively.

4. **Unknown destination MAC:** OVS floods the frame to all ports except
   the one it arrived on — standard Ethernet behavior.

5. **VM TAP devices connect to:** `br-int` (the integration bridge).

6. **Host cannot reach namespaces:** The host has no interface on the
   `192.168.100.0/24` subnet. To reach the namespaces, you would need to
   assign an IP address to `br-int` (using an OVS internal port) or add
   a route through an interface on that subnet.

---

*Lab 3 Solution — OpenStack Networking Workshop*
