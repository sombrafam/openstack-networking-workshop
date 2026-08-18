# Lab 8 — Solution: Multi-Chassis OVN — Geneve Tunnels, DVR, Gateway HA & Floating IPs

> **This file is released with Lab 9.** It contains the full commands and expected output for Lab 8's exercises.

---

## Prerequisites — Two Hosts

Use **host1** as OVN central + chassis1 and **chassis2** as the second VM/host.
Replace `<HOST1_IP>` and `<HOST2_IP>` with each host's management IP.
> Continue from the Lab 7 end state: `ls1`, `ls2`, `lr1`, `ns-a`, and the
> external `ls-ext` / `lr1-ext` resources exist or can be recreated below.
> If chassis2 does not exist yet, create it from `virt-tools` as shown in the
> README and note its management IP as `<HOST2_IP>`.

---

## Exercise 1 — Open OVN central to the network

**On host1:**
```bash
ovn-sbctl set-connection ptcp:6642:0.0.0.0
ovn-nbctl  set-connection ptcp:6641:0.0.0.0
sudo ovs-vsctl set open . \
  external-ids:ovn-remote=tcp:<HOST1_IP>:6642 \
  external-ids:ovn-encap-type=geneve \
  external-ids:ovn-encap-ip=<HOST1_IP>
sudo systemctl restart ovn-controller
```
**Verify:**
```bash
ss -tlnp | grep 664
ovn-sbctl show
```
**Expected output:**
```
LISTEN 0 64 0.0.0.0:6641 0.0.0.0:* users:(("ovsdb-server",pid=1234,fd=18))
LISTEN 0 64 0.0.0.0:6642 0.0.0.0:* users:(("ovsdb-server",pid=1235,fd=18))
Chassis "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    hostname: "host1"
    Encap geneve
        ip: "<HOST1_IP>"
        options: {csum="true"}
    Port_Binding ls1-port1
```
> `ptcp:6641` is the Northbound DB listener and `ptcp:6642` is the Southbound DB
> listener. Remote chassis connect to SB with `tcp:<HOST1_IP>:6642`.

---

## Exercise 2 — Join chassis2 to the control plane

**On chassis2:**
```bash
sudo apt update
sudo apt install -y ovn-host openvswitch-switch tcpdump
sudo ovs-vsctl set open . \
  external-ids:ovn-remote=tcp:<HOST1_IP>:6642 \
  external-ids:ovn-encap-type=geneve \
  external-ids:ovn-encap-ip=<HOST2_IP>
sudo systemctl restart openvswitch-switch ovn-controller
```
**Verify on host1:**
```bash
ovn-sbctl show
```
**Expected output:**
```
Chassis "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    hostname: "host1"
    Encap geneve
        ip: "<HOST1_IP>"
        options: {csum="true"}
Chassis "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    hostname: "chassis2"
    Encap geneve
        ip: "<HOST2_IP>"
        options: {csum="true"}
```
> A chassis is a hypervisor from OVN's point of view. It runs local OVS,
> `br-int`, and `ovn-controller`, while sharing the central OVN databases.

---

## Exercise 3 — Watch the Geneve overlay appear

**On both hosts:**
```bash
sudo ovs-vsctl show
ip -d link show genev_sys_6081
```
**Expected output on host1/chassis2:**
```
Bridge br-int
    Port ovn-bbbbb-0
        Interface ovn-bbbbb-0
            type: geneve
            options: {csum="true", key=flow, remote_ip="<HOST2_IP>"}
...
genev_sys_6081: ... geneve id 0 remote any dstport 6081 external
```
> On chassis2 the tunnel port points back to `remote_ip="<HOST1_IP>"`.
Create a new `ls1` port **on host1**:
```bash
ovn-nbctl --may-exist lsp-add ls1 ls1-port5
ovn-nbctl lsp-set-addresses ls1-port5 "aa:bb:cc:00:00:05 10.0.1.50"
```
Bind it to `ns-e` **on chassis2**:
```bash
sudo ip netns add ns-e
sudo ip netns exec ns-e ip link set lo up
sudo ip link add veth-e type veth peer name veth-e-ovs
sudo ip link set veth-e netns ns-e
sudo ovs-vsctl add-port br-int veth-e-ovs
sudo ip link set veth-e-ovs up
sudo ovs-vsctl set interface veth-e-ovs external-ids:iface-id=ls1-port5
sudo ip netns exec ns-e ip link set veth-e address aa:bb:cc:00:00:05
sudo ip netns exec ns-e ip addr add 10.0.1.50/24 dev veth-e
sudo ip netns exec ns-e ip link set veth-e up
```
**Verify on host1:**
```bash
ovn-sbctl show | grep -A8 chassis2
sudo tcpdump -ni any udp port 6081
```
In another terminal **on host1**:
```bash
sudo ip netns exec ns-a ping -c 3 10.0.1.50
```
**Expected output:**
```
    hostname: "chassis2"
    Encap geneve
        ip: "<HOST2_IP>"
    Port_Binding ls1-port5
PING 10.0.1.50 (10.0.1.50) 56(84) bytes of data.
64 bytes from 10.0.1.50: icmp_seq=1 ttl=64 time=1.2 ms
64 bytes from 10.0.1.50: icmp_seq=2 ttl=64 time=0.8 ms
64 bytes from 10.0.1.50: icmp_seq=3 ttl=64 time=0.9 ms
IP <HOST1_IP>.42318 > <HOST2_IP>.6081: Geneve, Flags [C], vni 0x0, proto TEB
IP <HOST2_IP>.37142 > <HOST1_IP>.6081: Geneve, Flags [C], vni 0x0, proto TEB
```
> `ovn-controller` created the Geneve tunnel automatically from SB chassis
> records. In Lab 4 you manually created VXLAN ports. Geneve also carries OVN
> TLVs for logical datapath and logical ingress/egress port metadata; VXLAN only
> carries a VNI.

---

## Exercise 4 — Prove routing is distributed (DVR)

Move `ns-e` to `ls2` so `ns-a` → `ns-e` must route through `lr1`.
**On host1:**
```bash
ovn-nbctl --if-exists lsp-del ls1-port5
ovn-nbctl --may-exist lsp-add ls2 ls2-port5
ovn-nbctl lsp-set-addresses ls2-port5 "aa:bb:cc:00:00:05 10.0.2.50"
```
**On chassis2:**
```bash
sudo ovs-vsctl set interface veth-e-ovs external-ids:iface-id=ls2-port5
sudo ip netns exec ns-e ip addr flush dev veth-e
sudo ip netns exec ns-e ip addr add 10.0.2.50/24 dev veth-e
sudo ip netns exec ns-e ip route add default via 10.0.2.1
```
**On host1:**
```bash
sudo ip netns exec ns-a ip route replace default via 10.0.1.1
sudo ip netns exec ns-a ping -c 3 10.0.2.50
```

**Expected output:**
```
PING 10.0.2.50 (10.0.2.50) 56(84) bytes of data.
64 bytes from 10.0.2.50: icmp_seq=1 ttl=63 time=1.4 ms
64 bytes from 10.0.2.50: icmp_seq=2 ttl=63 time=0.9 ms
64 bytes from 10.0.2.50: icmp_seq=3 ttl=63 time=1.0 ms
```

**Verify with `ovn-trace` on host1:**

```bash
ovn-trace --minimal ls1 \
  'inport=="ls1-port1" && eth.src==aa:bb:cc:00:00:01 && eth.dst==aa:bb:cc:00:01:01 && ip4.src==10.0.1.10 && ip4.dst==10.0.2.50 && ip.ttl==64 && icmp4'
```

**Expected output:**
```
# icmp,reg14=0x1,...,nw_src=10.0.1.10,nw_dst=10.0.2.50,nw_ttl=64
ip.ttl--;
eth.src = aa:bb:cc:00:01:02;
eth.dst = aa:bb:cc:00:00:05;
output("ls2-port5");
```

**Verify with `ofproto/trace` and tcpdump on host1:**

```bash
in_port=$(sudo ovs-vsctl get Interface veth-a-ovs ofport)
sudo ovs-appctl ofproto/trace br-int \
  "in_port=${in_port},icmp,dl_src=aa:bb:cc:00:00:01,dl_dst=aa:bb:cc:00:01:01,nw_src=10.0.1.10,nw_dst=10.0.2.50,nw_ttl=64"
sudo tcpdump -ni any "udp port 6081 and host <HOST2_IP>" -c 4
```

**Expected output (abbreviated):**
```
28. lr_in_ip_routing, priority 49
    ip.ttl--
    eth.src=aa:bb:cc:00:01:02
    eth.dst=aa:bb:cc:00:00:05
Datapath actions: set(tunnel(...)),6081

IP <HOST1_IP>.41637 > <HOST2_IP>.6081: Geneve, Flags [C], proto TEB
IP <HOST2_IP>.38391 > <HOST1_IP>.6081: Geneve, Flags [C], proto TEB
```

> The `lr1` pipeline runs on the **source chassis** and then sends one Geneve hop
> to chassis2. There is no detour through a network node for east/west traffic.

---

## Exercise 5 — Make the external gateway HA

Recreate the Lab 5 external gateway if needed, using your external values.
**On host1:**

```bash
ovn-nbctl --may-exist lrp-add lr1 lr1-ext aa:bb:cc:00:01:fe <EXT_ROUTER_IP>/<PREFIX>
ovn-nbctl --may-exist lsp-add ls-ext ls-ext-lr1
ovn-nbctl lsp-set-type ls-ext-lr1 router
ovn-nbctl lsp-set-addresses ls-ext-lr1 router
ovn-nbctl lsp-set-options ls-ext-lr1 router-port=lr1-ext
ovn-nbctl lr-route-add lr1 0.0.0.0/0 <EXT_GW_IP>
ovn-nbctl lr-nat-add lr1 snat <EXT_ROUTER_IP> 10.0.1.0/24
ovn-nbctl lr-nat-add lr1 snat <EXT_ROUTER_IP> 10.0.2.0/24
```
> If `ls-ext` / `ln-ext` / `br-ex` are missing, recreate them exactly as in
> Lab 5 before adding `lr1-ext`.

Add gateway candidates **on host1**:

```bash
c1=$(ovn-sbctl --bare --columns=name find chassis hostname=host1)
c2=$(ovn-sbctl --bare --columns=name find chassis hostname=chassis2)
ovn-nbctl lrp-set-gateway-chassis lr1-ext ${c1} 30
ovn-nbctl lrp-set-gateway-chassis lr1-ext ${c2} 20
ovn-nbctl lrp-get-gateway-chassis lr1-ext
ovn-sbctl show
```

**Expected output:**
```
aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa 30
bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb 20

Chassis "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    hostname: "host1"
    Encap geneve
        ip: "<HOST1_IP>"
    Port_Binding cr-lr1-ext
Chassis "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    hostname: "chassis2"
    Encap geneve
        ip: "<HOST2_IP>"
```

**Verify BFD and failover:**

```bash
sudo ovs-appctl bfd/show
sudo systemctl stop ovn-controller     # on active gateway chassis, host1 here
ovn-sbctl show | grep -A6 -B2 cr-lr1-ext
sudo systemctl start ovn-controller
```

**Expected output:**
```
Interface ovn-bbbbb-0
    Forwarding: true
    Remote State: up
    Local State: up

Chassis "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    hostname: "chassis2"
    Encap geneve
        ip: "<HOST2_IP>"
    Port_Binding cr-lr1-ext
```

> N/S SNAT is centralized because one chassis must own the external IP/MAC on the
> provider network. E/W routing is distributed because no physical LAN ownership
> is involved. BFD over the Geneve tunnel detects gateway failure and moves the
> `chassisredirect` (`cr-lr1-ext`) port to the next HA candidate.

---

## Exercise 6 — Floating IPs (centralized, then distributed)

Choose a free external IP and call it `<FIP_A>`.

### 6.1 Centralized FIP

**On host1:**

```bash
ovn-nbctl lr-nat-add lr1 dnat_and_snat <FIP_A> 10.0.1.10
ovn-nbctl lr-nat-list lr1
```

**Expected output:**
```
TYPE             EXTERNAL_IP        LOGICAL_IP    EXTERNAL_MAC LOGICAL_PORT
snat             <EXT_ROUTER_IP>    10.0.1.0/24
snat             <EXT_ROUTER_IP>    10.0.2.0/24
dnat_and_snat    <FIP_A>            10.0.1.10
```

**Verify from an external host, then on the gateway chassis:**

```bash
ping -c 3 <FIP_A>
sudo ovs-ofctl dump-flows br-int | grep <FIP_A> | head
```

**Expected output:**
```
64 bytes from <FIP_A>: icmp_seq=1 ttl=63 time=1.1 ms
64 bytes from <FIP_A>: icmp_seq=2 ttl=63 time=0.8 ms

 cookie=0x..., table=15, priority=100,ip,nw_dst=<FIP_A> actions=ct(commit,nat(dst=10.0.1.10)),...
 cookie=0x..., table=41, priority=100,ip,nw_src=10.0.1.10 actions=ct(commit,nat(src=<FIP_A>)),...
```

> The centralized FIP is translated on the active `cr-lr1-ext` gateway chassis.

### 6.2 Distributed FIP

**On host1:**

```bash
ovn-nbctl lr-nat-del lr1 dnat_and_snat <FIP_A>
ovn-nbctl lr-nat-add lr1 dnat_and_snat <FIP_A> 10.0.1.10 \
  ls1-port1 aa:bb:cc:00:00:01
ovn-nbctl lr-nat-list lr1
```

**Expected output:**
```
TYPE             EXTERNAL_IP        LOGICAL_IP    EXTERNAL_MAC          LOGICAL_PORT
dnat_and_snat    <FIP_A>            10.0.1.10    aa:bb:cc:00:00:01     ls1-port1
snat             <EXT_ROUTER_IP>    10.0.1.0/24
snat             <EXT_ROUTER_IP>    10.0.2.0/24
```

**Verify on host1 (the instance chassis) and chassis2:**

```bash
sudo ovs-ofctl dump-flows br-int | grep <FIP_A> | head
```

**Expected output on host1:**
```
 cookie=0x..., table=15, priority=120,ip,nw_dst=<FIP_A> actions=ct(commit,nat(dst=10.0.1.10)),...
 cookie=0x..., table=41, priority=120,ip,nw_src=10.0.1.10 actions=ct(commit,nat(src=<FIP_A>)),...
```

**Expected output on chassis2:**
```
# no output, unless ls1-port1 has moved to chassis2
```

> Adding `logical_port` plus `external_mac` makes the FIP distributed. NAT is
> installed on the chassis that hosts `ls1-port1`, matching OpenStack DVR FIPs on
> compute nodes instead of centralized FIPs on network nodes.

---

## Exercise 7 — Map it to OpenStack

| What you did | OpenStack reality |
|---|---|
| Added `chassis2` | Added a compute or network node |
| Auto Geneve mesh | Tenant overlay between compute nodes |
| Source-chassis `lr1` routing | DVR east/west routing |
| `cr-lr1-ext` on one chassis | Centralized SNAT gateway on a network node |
| Gateway chassis priority + BFD | Neutron L3 HA |
| Centralized `dnat_and_snat` | Floating IP via the network node |
| `dnat_and_snat` + port + MAC | DVR floating IP on the compute node |

> In a cloud with several computes and network nodes, every compute is a chassis
> in the Geneve mesh. DVR runs the router pipeline on computes for east/west and
> distributed FIP traffic; L3 HA keeps external SNAT active on one gateway chassis
> at a time.

*Lab 8 Solution — OpenStack Networking Workshop*
