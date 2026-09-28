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

## Exercise 6 — Connect Two Hosts with a VXLAN Tunnel

Underlay addresses used below: **Host A `192.168.122.11`**, **Host B
`192.168.122.12`**, physical interface `ens3`. Substitute your own.

### Task 6.1 — Mirror the topology onto Host B

The Lab 3 build loop is reused verbatim; only the addresses differ. Run this
on **Host B**:

```bash
sudo apt install -y openvswitch-switch

sudo ovs-vsctl add-br br-int
sudo ip link set br-int up

for ns in a b c; do
    sudo ip netns add ns-${ns}
    sudo ip netns exec ns-${ns} ip link set lo up
    sudo ip link add veth-${ns} type veth peer name veth-${ns}-ovs
    sudo ip link set veth-${ns} netns ns-${ns}
    sudo ovs-vsctl add-port br-int veth-${ns}-ovs
    sudo ip link set veth-${ns}-ovs up
    sudo ip netns exec ns-${ns} ip link set veth-${ns} up
done

# Host B uses the .110/.120/.130 range — same subnet, different addresses
sudo ip netns exec ns-a ip addr add 192.168.100.110/24 dev veth-a
sudo ip netns exec ns-b ip addr add 192.168.100.120/24 dev veth-b
sudo ip netns exec ns-c ip addr add 192.168.100.130/24 dev veth-c
```

**Verify:**

```bash
# Local connectivity within Host B
sudo ip netns exec ns-a ping -c2 192.168.100.120
```

**Expected:** Success — both namespaces hang off the same local bridge.

```bash
# No path to Host A yet
sudo ip netns exec ns-a ping -c2 -W2 192.168.100.10
```

**Expected output:**
```
2 packets transmitted, 0 received, 100% packet loss, time XXXXms
```

> The two bridges are still completely independent. Nothing connects them.

```bash
# Underlay reachability (run on either host)
ping -c3 192.168.122.12
ip -brief addr show
```

### Task 6.2 — Create the tunnel

```bash
# On Host A — remote_ip is HOST B
sudo ovs-vsctl add-port br-int vxlan0 \
  -- set interface vxlan0 type=vxlan \
     options:remote_ip=192.168.122.148 \
     options:key=100
```

```bash
# On Host B — remote_ip is HOST A
sudo ovs-vsctl add-port br-int vxlan0 \
  -- set interface vxlan0 type=vxlan \
     options:remote_ip=192.168.122.68 \
     options:key=100
```

**Verify:**

```bash
sudo ovs-vsctl show
```

**Expected output (Host A):**
```
    Bridge br-int
        Port vxlan0
            Interface vxlan0
                type: vxlan
                options: {key="100", remote_ip="192.168.122.12"}
        Port veth-a-ovs
            Interface veth-a-ovs
        ...
```

> If the interface shows an `error:` field, the tunnel was rejected — most
> often because `remote_ip` is malformed or identical to the local address.

```bash
sudo ovs-ofctl show br-int | grep vxlan
```

**Expected output:**
```
 4(vxlan0): addr:xx:xx:xx:xx:xx:xx
     config:     0
     state:      0
     speed: 0 Mbps now, 0 Mbps max
```

> The tunnel received OpenFlow port number 4 (after the three veths). It is an
> ordinary port as far as the flow tables are concerned — which is why the
> default `priority=0 actions=NORMAL` flow forwards over it with no extra
> configuration.

```bash
sudo ovs-appctl dpif/show
```

**Expected output:**
```
system@ovs-system: hit:XXX missed:XX
  br-int:
    br-int 65534/1: (internal)
    veth-a-ovs 1/2: (system)
    veth-b-ovs 2/3: (system)
    veth-c-ovs 3/4: (system)
    vxlan0 4/5: (vxlan: key=100, remote_ip=192.168.122.12)
```

### Task 6.3 — Prove the overlay works

```bash
# From Host A: ns-a → ns-b ON HOST B
sudo ip netns exec ns-a ping -c4 192.168.100.120
```

**Expected output:**
```
PING 192.168.100.120 (192.168.100.120) 56(84) bytes of data.
64 bytes from 192.168.100.120: icmp_seq=1 ttl=64 time=0.9XX ms
...
4 packets transmitted, 4 received, 0% packet loss
```

> **`ttl=64` is the detail to notice.** The TTL was not decremented, so no
> routing took place — as far as the namespaces are concerned this is a flat
> Layer 2 segment, despite the packets crossing a routed network.

```bash
# Full mesh: every namespace reaches all six addresses
for ip in 10 20 30 110 120 130; do
    echo -n "192.168.100.$ip: "
    sudo ip netns exec ns-a ping -c1 -W1 192.168.100.$ip >/dev/null 2>&1 \
        && echo OK || echo FAIL
done
```

**Expected:** all six report `OK` (`.10` is `ns-a` pinging itself).

```bash
# ARP crossed the tunnel
sudo ip netns exec ns-a ip neigh
```

**Expected output:**
```
192.168.100.120 dev veth-a lladdr xx:xx:xx:xx:xx:xx REACHABLE
```

```bash
# MAC learning table on Host A
sudo ovs-appctl fdb/show br-int
```

**Expected output:**
```
 port  VLAN  MAC                Age
    4     0  xx:xx:xx:xx:xx:xx    5      <- remote MACs on the vxlan0 port
    4     0  xx:xx:xx:xx:xx:xx    5
    1     0  xx:xx:xx:xx:xx:xx    7      <- local MACs on veth ports
```

> Remote namespaces are learned on **port 4** (`vxlan0`). OVS did not need to
> be told where they are; standard MAC learning discovered them, and the
> tunnel is simply the port they were heard on.

### Task 6.4 — Observe the encapsulation

Start a continuous ping on **Host A** and leave it running:

```bash
sudo ip netns exec ns-a ping 192.168.100.120
```

**Capture point 1 — the underlay interface (Host B):**

```bash
sudo tcpdump -ni ens3 -vv udp port 4789
```

**Expected output:**
```
12:04:51.123456 IP (tos 0x0, ttl 64, id 0, offset 0, flags [DF], proto UDP (17), length 134)
    192.168.122.11.49152 > 192.168.122.12.4789: VXLAN, flags [I] (0x08), vni 100
IP (tos 0x0, ttl 64, id 1234, offset 0, flags [DF], proto ICMP (1), length 84)
    192.168.100.10 > 192.168.100.120: ICMP echo request, id 12, seq 1, length 64
```

> This is the entire concept in one packet. **Two IP headers:** the outer is
> host-to-host on the underlay (`192.168.122.11 → .12`), the inner is
> namespace-to-namespace on the overlay (`192.168.100.10 → .120`). `vni 100`
> is the `options:key=100` you configured. A physical router between the hosts
> sees only the outer header — it has no idea the overlay exists.

**Capture point 2 — the tunnel device (Host B):**

```bash
sudo tcpdump -ni vxlan_sys_4789 -vv icmp
```

**Expected output:**
```
12:04:51.123512 IP (tos 0x0, ttl 64, id 1234, offset 0, flags [DF], proto ICMP (1), length 84)
    192.168.100.10 > 192.168.100.120: ICMP echo request, id 12, seq 1, length 64
```

> Same packet, one header gone. The kernel has stripped the outer UDP/VXLAN
> encapsulation before handing the frame to the datapath. `vxlan_sys_4789` is
> shared by every VXLAN tunnel using that UDP port.

**Capture point 3 — inside the destination namespace (Host B):**

```bash
sudo ip netns exec ns-b tcpdump -ni veth-b -vv icmp
```

**Expected output:**
```
12:04:51.123598 IP (tos 0x0, ttl 64, id 1234, offset 0, flags [DF], proto ICMP (1), length 84)
    192.168.100.10 > 192.168.100.120: ICMP echo request, id 12, seq 1, length 64
12:04:51.123644 IP ... 192.168.100.120 > 192.168.100.10: ICMP echo reply, ...
```

> The namespace sees a plain ICMP exchange with a directly-attached peer. It
> has no visibility into the tunnel whatsoever — which is exactly what a VM
> experiences on a tenant network.

**Answers to the per-capture questions:**

| | Capture 1 (underlay) | Capture 2 (tunnel dev) | Capture 3 (namespace) |
|---|---|---|---|
| Source / dest | `192.168.122.11` → `.12` **and** `192.168.100.10` → `.120` | `192.168.100.10` → `.120` | `192.168.100.10` → `.120` |
| VNI visible? | Yes — `vni 100` | No | No |
| IP headers | 2 | 1 | 1 |

**Broadcast traffic:**

```bash
# Host A
sudo ip netns exec ns-a ip neigh flush all
sudo ip netns exec ns-a ping -c2 192.168.100.120
```

**Expected output on the Host B underlay capture:**
```
192.168.122.11.49152 > 192.168.122.12.4789: VXLAN, flags [I] (0x08), vni 100
    ARP, Request who-has 192.168.100.120 tell 192.168.100.10, length 28
192.168.122.12.38294 > 192.168.122.11.4789: VXLAN, flags [I] (0x08), vni 100
    ARP, Reply 192.168.100.120 is-at xx:xx:xx:xx:xx:xx, length 28
```

> The broadcast ARP request was encapsulated and unicast to the remote tunnel
> endpoint. With only two hosts this is cheap; with 20 hosts, OVS would have to
> replicate every broadcast 19 times. That cost is a large part of why OVN
> replaces flooding with pre-programmed flows.

**Capture to a file:**

```bash
sudo tcpdump -ni ens3 -s0 -w /tmp/vxlan.pcap udp port 4789
# Ctrl-C after a few packets
tcpdump -nr /tmp/vxlan.pcap -vv
```

**Forcing the decoder** (only needed on a non-standard port):

```bash
sudo tcpdump -ni ens3 -vv -T vxlan udp port 8472
```

> Without `-T vxlan`, tcpdump prints `UDP, length 134` and nothing more,
> because it only auto-detects VXLAN on port 4789.

**Tunnel counters:**

```bash
sudo ovs-ofctl dump-ports br-int vxlan0
```

**Expected output:**
```
OFPST_PORT reply (xid=0x4): 1 ports
  port  4: rx pkts=24, bytes=2352, drop=0, errs=0, frame=0, over=0, crc=0
           tx pkts=24, bytes=2352, drop=0, errs=0, coll=0
```

### Task 6.5 — Clean up

```bash
# Both hosts — remove the tunnel
sudo ovs-vsctl del-port br-int vxlan0

# Host B only — tear down the mirrored topology
sudo ovs-vsctl del-br br-int
for ns in ns-a ns-b ns-c; do
    sudo ip netns delete $ns
done
```

> Leave Host A's bridge and namespaces in place — Lab 5 starts from them.

### Exercise 6 — Answers

1. **How many IP headers?** Two. The outer header is
   `192.168.122.11 → 192.168.122.12` (host to host, the underlay); the inner
   is `192.168.100.10 → 192.168.100.120` (namespace to namespace, the
   overlay). Only the outer one is visible to the physical network.

2. **Why does the outer source UDP port change?** The sending VTEP derives it
   from a hash of the *inner* packet headers. Since the outer destination port
   is always 4789 and the outer IPs are always the same host pair, the source
   port is the only field that varies — so it is what ECMP and LAG hashing in
   the underlay use to spread tunnelled flows across multiple paths. Without
   it, all overlay traffic between two hosts would pin to a single link.

3. **MTU overhead.** VXLAN adds 50 bytes: 14 (outer Ethernet) + 20 (outer IP)
   + 8 (UDP) + 8 (VXLAN). With a 1500-byte underlay MTU, the overlay MTU must
   be **1450** or lower. Set it with
   `sudo ip netns exec ns-a ip link set veth-a mtu 1450`. Get this wrong and
   you see the classic silent failure: ping and SSH handshakes work (small
   packets) while large transfers hang (big packets are dropped, and the
   `DF` bit means no fragmentation happens). Geneve overhead is slightly
   larger because of its TLV options, which is why OVN typically pushes 1442.

4. **Why is `ns-a` on both hosts not a conflict?** A network namespace is a
   kernel object local to one host; the name is just a file in
   `/var/run/netns/` on that machine. Nothing is shared. What *would* conflict
   is duplicate **IP or MAC addresses**, because those are carried inside the
   tunnel onto a shared Layer 2 segment. Giving Host B's `ns-a` the address
   `192.168.100.10` would produce a duplicate-address conflict with Host A's
   `ns-a` — two machines answering the same ARP request. This mirrors a real
   cloud, where hypervisors reuse device names freely but Neutron's IPAM must
   guarantee address uniqueness per network.

5. **`options:key=flow`.** The VNI would come from the **flow rules** instead
   of the port configuration — a flow sets `tun_id` before outputting to the
   tunnel port. This lets *one* tunnel port carry many logical networks,
   rather than needing a port per network. It is exactly what OVN does: a
   single Geneve port per peer chassis, with the logical datapath ID supplied
   per-packet from the flow tables.

6. **Scaling.** A full mesh over 20 hypervisors needs
   `20 × 19 / 2 = 190` tunnels, or 19 tunnel ports on every host, each one
   created and maintained by hand — and every host must be reconfigured
   whenever a hypervisor is added or removed. This does not scale, which is
   precisely the problem OVN solves: `ovn-controller` reads the chassis list
   from the Southbound DB and creates the tunnel mesh automatically.

---

## Cleanup

Only when you are finished with Lab 4 **and** do not intend to start Lab 5
immediately — Lab 5 builds on this same topology.

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

6. **Outer vs inner addresses:** the outer IP header carries the **underlay**
   addresses of the two hosts (`192.168.122.11 → 192.168.122.12`); the inner
   header carries the **overlay** addresses of the namespaces
   (`192.168.100.10 → 192.168.100.120`). A physical router between the hosts
   sees only the outer pair — the overlay is opaque to it, which is precisely
   what makes the tunnel work across a network that knows nothing about the
   tenant subnet.

7. **MTU:** VXLAN adds 50 bytes (14 outer Ethernet + 20 outer IP + 8 UDP +
   8 VXLAN), so the overlay interfaces need an MTU of **1450** or less. The
   symptom of getting it wrong is a distinctive one: small packets work, so
   ping and connection setup succeed, but anything that fills a full-size
   frame hangs — a large file transfer, or an SSH session that connects and
   then freezes after the banner. Because the outer header sets `DF`,
   oversized packets are dropped rather than fragmented, and if the ICMP
   "fragmentation needed" messages are also filtered, Path MTU Discovery
   cannot recover.

8. **Overlay fails, underlay works — what to check:**
   - The tunnel port exists and has no error:
     `sudo ovs-vsctl show` (look for an `error:` field on `vxlan0`).
   - `remote_ip` points at the **peer**, not the local host, and the VNI
     matches on both ends:
     `sudo ovs-vsctl list interface vxlan0`.
   - UDP 4789 is actually arriving and is not blocked by a firewall or
     cloud security group:
     `sudo tcpdump -ni ens3 udp port 4789` on the receiving host.
   - Further candidates: overlapping/duplicate overlay addresses
     (`sudo ovs-appctl fdb/show br-int` showing a MAC flapping between
     ports), a leftover `drop` flow from Exercises 2–4
     (`sudo ovs-ofctl dump-flows br-int`), or an MTU mismatch if only
     large packets fail.

9. **Manual full mesh does not scale:** *n* hosts need *n*(*n*−1)/2 tunnels
   — 190 for 20 hypervisors, or 19 tunnel ports per host — and every host
   must be reconfigured whenever one is added or removed. Broadcast traffic
   also has to be replicated once per remote endpoint. OVN removes the
   manual work entirely: each `ovn-controller` reads the `Chassis` table
   from the Southbound DB and creates or destroys the tunnel mesh
   automatically as hypervisors come and go. It further uses
   `options:key=flow`, so a single Geneve port per peer carries every
   logical network, with the datapath ID supplied per packet by the flow
   tables.

---

*Lab 4 Solution — OpenStack Networking Workshop*
