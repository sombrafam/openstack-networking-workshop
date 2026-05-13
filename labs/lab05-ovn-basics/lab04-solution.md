# Lab 4 — Solution: OVS Advanced — OpenFlow Rules & Tunnels

> **This file is released with Lab 5.** It contains the full commands and
> expected output for Lab 4's exercises.

---

## Prerequisites — Rebuild Lab 3 Topology

Lab 4 starts from the end-state of Lab 3. If you cleaned up, recreate it:

```bash
# Install OVS (if not already)
sudo apt install -y openvswitch-switch

# Create the bridge
sudo ovs-vsctl add-br br-int
sudo ip link set br-int up

# Create namespaces and wire them up
for ns in a b c; do
    sudo ip netns add ns-${ns}
    sudo ip netns exec ns-${ns} ip link set lo up
    sudo ip link add veth-${ns} type veth peer name veth-${ns}-ovs
    sudo ip link set veth-${ns} netns ns-${ns}
    sudo ovs-vsctl add-port br-int veth-${ns}-ovs
    sudo ip link set veth-${ns}-ovs up
    sudo ip netns exec ns-${ns} ip link set veth-${ns} up
done

# Assign IPs
sudo ip netns exec ns-a ip addr add 192.168.100.10/24 dev veth-a
sudo ip netns exec ns-b ip addr add 192.168.100.20/24 dev veth-b
sudo ip netns exec ns-c ip addr add 192.168.100.30/24 dev veth-c
```

---

## Exercise 1 — Inspect the Default Flow and Port Counters

```bash
sudo ovs-ofctl dump-flows br-int
```

**Expected output:**
```
 cookie=0x0, duration=X.XXXs, table=0, n_packets=0, n_bytes=0, priority=0 actions=NORMAL
```

```bash
sudo ovs-ofctl dump-ports br-int
```

**Expected output:**
```
OFPST_PORT reply ...
  port LOCAL: rx pkts=0, bytes=0, ...
  port  1: rx pkts=0, bytes=0, ...
  port  2: rx pkts=0, bytes=0, ...
  port  3: rx pkts=0, bytes=0, ...
```

```bash
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
```

> The default flow has `priority=0` and `actions=NORMAL` — making OVS
> behave as a learning switch. Port numbers (1, 2, 3) are assigned
> sequentially as ports are added.

```bash
# Generate traffic and re-check
sudo ip netns exec ns-a ping -c 3 192.168.100.20
sudo ovs-ofctl dump-flows br-int
```

> `n_packets` should now be > 0, reflecting the ARP + ICMP traffic
> processed by the NORMAL flow.

```bash
sudo ovs-dpctl dump-flows
```

> This shows the **kernel datapath** flows — the cached fast-path entries
> that the kernel uses to forward packets without going back to
> `ovs-vswitchd`. These are different from OpenFlow flows: they are
> exact-match, per-connection entries with a short idle timeout.

---

## Exercise 2 — Add a Custom ACL Flow

```bash
sudo ovs-ofctl add-flow br-int \
  "priority=100,ip,nw_src=192.168.100.30,nw_dst=192.168.100.10,actions=drop"
```

**Verify:**

```bash
sudo ovs-ofctl dump-flows br-int
```

**Expected output:**
```
 cookie=0x0, duration=X.XXXs, table=0, n_packets=0, n_bytes=0, priority=100,ip,nw_src=192.168.100.30,nw_dst=192.168.100.10 actions=drop
 cookie=0x0, duration=XXX.XXXs, table=0, n_packets=XX, n_bytes=XXXX, priority=0 actions=NORMAL
```

```bash
# Ping from ns-c to ns-a — BLOCKED
sudo ip netns exec ns-c ping -c 2 -W 2 192.168.100.10
```

**Expected output:**
```
PING 192.168.100.10 (192.168.100.10) 56(84) bytes of data.

--- 192.168.100.10 ping statistics ---
2 packets transmitted, 0 received, 100% packet loss, time XXXX ms
```

```bash
# Ping from ns-c to ns-b — still works (different destination)
sudo ip netns exec ns-c ping -c 2 192.168.100.20
```

**Expected:** Success.

```bash
# Ping from ns-a to ns-c — still works (reverse direction not blocked)
sudo ip netns exec ns-a ping -c 2 192.168.100.30
```

**Expected:** Success.

> **Why doesn't the reverse direction get blocked?** The flow matches
> `nw_src=192.168.100.30,nw_dst=192.168.100.10` — it only matches
> packets FROM ns-c TO ns-a, not the other way around. To block both
> directions you would need a second flow with src/dst reversed, or
> you could match on just one of the two IPs (e.g., drop all traffic
> where either src or dst is a specific IP).

---

## Exercise 3 — Remove the ACL Flow

```bash
sudo ovs-ofctl del-flows br-int \
  "ip,nw_src=192.168.100.30,nw_dst=192.168.100.10"
```

**Verify:**

```bash
sudo ovs-ofctl dump-flows br-int
```

**Expected output:** Only the default flow remains.

```bash
# Ping from ns-c to ns-a — restored
sudo ip netns exec ns-c ping -c 2 192.168.100.10
```

**Expected:** Success.

---

## Exercise 4 — Add a Flow Using Port-Based Match

```bash
# Find the MAC of veth-b inside ns-b
sudo ip netns exec ns-b ip link show veth-b
```

**Expected output:**
```
X: veth-b@if Y: <BROADCAST,MULTICAST,UP,LOWER_UP> ...
    link/ether xx:xx:xx:xx:xx:xx brd ff:ff:ff:ff:ff:ff ...
```

Note the MAC address (e.g., `4a:3b:2c:1d:00:02`).

```bash
# Find the OVS port number for veth-a-ovs
sudo ovs-ofctl show br-int | grep veth-a-ovs
```

Note the port number (e.g., `1`).

```bash
# Add the flow (replace <port-num-a> and <mac-of-veth-b> with actual values)
sudo ovs-ofctl add-flow br-int \
  "priority=100,in_port=<port-num-a>,dl_dst=<mac-of-veth-b>,actions=drop"
```

**Verify:**

```bash
# ARP from ns-a to ns-b still resolves (ARP uses broadcast dl_dst)
# But ICMP is blocked because ICMP uses the unicast MAC
sudo ip netns exec ns-a ping -c 2 -W 2 192.168.100.20
```

**Expected:** Timeout (100% packet loss). The ARP request goes through
(broadcast MAC `ff:ff:ff:ff:ff:ff` doesn't match the flow), ARP reply
returns, but the ICMP echo request with the unicast destination MAC is
dropped.

> **Note:** If ARP was already cached from the earlier exercises, the first
> ping attempt already uses the unicast MAC. Clear ARP first with
> `sudo ip netns exec ns-a ip neigh flush all` to see the full sequence.

```bash
# Clean up
sudo ovs-ofctl del-flows br-int \
  "in_port=<port-num-a>,dl_dst=<mac-of-veth-b>"
```

---

## Exercise 5 — Port Statistics and Flow Counters

```bash
# Generate some traffic
sudo ip netns exec ns-a ping -c 5 192.168.100.20
sudo ip netns exec ns-b ping -c 5 192.168.100.30

# Check port statistics
sudo ovs-ofctl dump-ports br-int
```

**Expected output:**
```
OFPST_PORT reply ...
  port  1: rx pkts=XX, bytes=XXXX, drop=0, errs=0, ...
           tx pkts=XX, bytes=XXXX, drop=0, errs=0, ...
  port  2: rx pkts=XX, bytes=XXXX, drop=0, errs=0, ...
           tx pkts=XX, bytes=XXXX, drop=0, errs=0, ...
  port  3: rx pkts=XX, bytes=XXXX, drop=0, errs=0, ...
           tx pkts=XX, bytes=XXXX, drop=0, errs=0, ...
```

```bash
# Check flow counters
sudo ovs-ofctl dump-flows br-int
```

> The `n_packets` and `n_bytes` counters show how many packets matched
> each flow rule. This is invaluable for troubleshooting — if a flow
> shows `n_packets=0`, no traffic is matching it.

```bash
# Datapath flows (kernel fast-path)
sudo ovs-dpctl dump-flows
```

> **`ovs-ofctl dump-flows` vs `ovs-dpctl dump-flows`:**
> - `ovs-ofctl dump-flows` shows the **OpenFlow rules** in the userspace
>   flow tables — these are the programmed rules (what you installed).
> - `ovs-dpctl dump-flows` shows the **kernel datapath cache** — these are
>   exact-match entries created on a per-connection basis when the first
>   packet of a flow is sent to userspace for processing. They expire
>   after a short idle timeout.

---

## Cleanup

```bash
sudo ovs-vsctl del-br br-int
for ns in ns-a ns-b ns-c; do
    sudo ip netns delete $ns
done
```

---

## Review Questions — Answers

1. **Three components of a flow rule:**
   - **Match fields** — what the packet looks like (ingress port, MACs, IPs,
     protocols, ports).
   - **Priority** — which rule wins when multiple rules match (higher wins).
   - **Actions** — what to do with the packet (output, drop, modify, resubmit).

2. **Two rules match:** The one with the **higher priority** wins. If they
   have the same priority, the behavior is undefined (OVS may match either).

3. **`resubmit(,1)`:** Sends the packet to be evaluated against the rules
   in **table 1** (instead of continuing in the current table). This allows
   multi-stage processing pipelines — OVN uses ~30 tables to implement its
   logical pipeline.

4. **VNI:** The VXLAN Network Identifier is a 24-bit field, allowing up to
   16,777,216 (2²⁴) distinct virtual networks — far more than the 4094
   VLANs available with 802.1Q.

5. **Multiple tables:** OVN uses multiple tables to implement a staged
   pipeline (ingress port security → pre-ACL → ACL → routing → egress ACL
   → output). This is cleaner, easier to reason about, and avoids
   combinatorial explosion of rules that would occur in a single flat table.

---

*Lab 4 Solution — OpenStack Networking Workshop*
