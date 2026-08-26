# Lab 7 — Solution: Multi-node OVN

> **This file is released with Lab 8.** It contains the full commands and expected output for Lab 7's exercises.

Throughout this solution:

- `node1` = `192.168.122.11` — OVN central + chassis
- `node2` = `192.168.122.12` — chassis only

Set the environment on **both** nodes before starting:

```bash
export NODE1_IP=192.168.122.11
export NODE2_IP=192.168.122.12
export CENTRAL_IP=$NODE1_IP
```

UUIDs, ofport numbers, and tunnel keys in the expected output below will differ
on your systems — the *shape* of the output is what matters.

---

## Exercise 1 — Install OVN packages on both nodes

On `node1`:

```bash
sudo apt install -y ovn-central ovn-host
sudo systemctl enable --now openvswitch-switch ovn-central ovn-controller
```

On `node2`:

```bash
sudo apt install -y ovn-host
sudo systemctl enable --now openvswitch-switch ovn-controller
```

**Verify** on `node1`:

```bash
sudo ovn-nbctl show
sudo ovn-sbctl show
systemctl is-active ovn-northd ovn-controller openvswitch-switch
```

**Expected output:**
```
# ovn-nbctl show  -> no output (empty NB DB)
# ovn-sbctl show  -> no output (no chassis registered yet)

active
active
active
```

> `ovn-central` pulls in `ovn-northd` plus the NB/SB `ovsdb-server` instances.
> `ovn-host` provides `ovn-controller`, the per-chassis agent that translates
> Southbound logical flows into OpenFlow rules on the local `br-int`.
> `node1` needs both because it is simultaneously control plane and chassis.

---

## Exercise 2 — Configure OVN persistently and register both chassis

On `node1`, make the OVN databases listen on the management IP:

```bash
sudo ovn-nbctl set-connection ptcp:6641:$NODE1_IP -- set connection . inactivity_probe=60000
sudo ovn-sbctl set-connection ptcp:6642:$NODE1_IP -- set connection . inactivity_probe=60000
```

On `node1`, store its chassis settings in OVSDB:

```bash
sudo ovs-vsctl set open . \
  external-ids:ovn-remote=tcp:$CENTRAL_IP:6642 \
  external-ids:ovn-encap-type=geneve \
  external-ids:ovn-encap-ip=$NODE1_IP
```

On `node2`:

```bash
sudo ovs-vsctl set open . \
  external-ids:ovn-remote=tcp:$CENTRAL_IP:6642 \
  external-ids:ovn-encap-type=geneve \
  external-ids:ovn-encap-ip=$NODE2_IP
```

**Verify** from `node1`:

```bash
sudo ovn-sbctl show
sudo ovn-sbctl list Chassis | grep -E 'name|hostname'
sudo ss -ltnp | grep -E '6641|6642'
```

**Expected output:**
```
Chassis "e2b0c1a4-1111-4c2a-9f30-aaaaaaaaaaaa"
    hostname: node1
    Encap geneve
        ip: "192.168.122.11"
        options: {csum="true"}
Chassis "7d41f9c8-2222-4bb1-8e77-bbbbbbbbbbbb"
    hostname: node2
    Encap geneve
        ip: "192.168.122.12"
        options: {csum="true"}

hostname            : node1
name                : "e2b0c1a4-1111-4c2a-9f30-aaaaaaaaaaaa"
hostname            : node2
name                : "7d41f9c8-2222-4bb1-8e77-bbbbbbbbbbbb"

LISTEN 0 10 192.168.122.11:6641 0.0.0.0:*
LISTEN 0 10 192.168.122.11:6642 0.0.0.0:*
```

**Verify** the tunnel endpoints were created on each node:

```bash
sudo ovs-vsctl show | grep -A3 'Port ovn-'
```

**Expected output** (on `node1`, pointing at `node2`):
```
        Port ovn-7d41f9-0
            Interface ovn-7d41f9-0
                type: geneve
                options: {csum="true", key=flow, remote_ip="192.168.122.12"}
```

> Three things make this persistent across reboot: `systemctl enable` for the
> services, `ovs-vsctl set open .` writing chassis settings into OVSDB (which
> has an on-disk database), and `set-connection` storing the listener config in
> the OVN databases themselves. Nothing lives only in a shell variable or a
> command-line flag.
>
> Note that `ovn-controller` builds the Geneve port **automatically** the moment
> a second chassis registers — you never run `ovs-vsctl add-port` for a tunnel.
> `key=flow` means the tunnel key (the logical datapath ID) is set per-packet by
> OpenFlow actions, which is how one tunnel carries every logical network.

---

## Exercise 3 — Create logical switch `ls1` and the first two logical ports

On `node1`:

```bash
sudo ovn-nbctl ls-add ls1

sudo ovn-nbctl lsp-add ls1 ls1-port1
sudo ovn-nbctl lsp-set-addresses ls1-port1 "aa:bb:cc:00:00:01 10.0.1.10"

sudo ovn-nbctl lsp-add ls1 ls1-port2
sudo ovn-nbctl lsp-set-addresses ls1-port2 "aa:bb:cc:00:00:02 10.0.1.20"
```

**Verify:**

```bash
sudo ovn-nbctl show
sudo ovn-sbctl list Port_Binding | grep -E 'logical_port|chassis'
```

**Expected output:**
```
switch 3f8a1c22-... (ls1)
    port ls1-port1
        addresses: ["aa:bb:cc:00:00:01 10.0.1.10"]
    port ls1-port2
        addresses: ["aa:bb:cc:00:00:02 10.0.1.20"]

chassis             : []
logical_port        : "ls1-port1"
chassis             : []
logical_port        : "ls1-port2"
```

> The ports exist and `ovn-northd` has already compiled logical flows for them,
> but `chassis` is empty — OVN does not yet know *where* these ports live. That
> binding happens in the next exercise when a real interface claims the
> `iface-id`. This is exactly the Neutron model: `openstack port create` makes
> the port, Nova plugging the TAP binds it to a host.

---

## Exercise 4 — Bind `ls1` ports to namespaces on different hosts

### 4.1 Clean up old namespaces and OVS ports

On `node1`:

```bash
sudo ip netns delete ns-a 2>/dev/null
sudo ip netns delete ns-c 2>/dev/null
sudo ovs-vsctl --if-exists del-port br-int veth-a-ovs
sudo ovs-vsctl --if-exists del-port br-int veth-c-ovs
```

On `node2`:

```bash
sudo ip netns delete ns-b 2>/dev/null
sudo ip netns delete ns-d 2>/dev/null
sudo ovs-vsctl --if-exists del-port br-int veth-b-ovs
sudo ovs-vsctl --if-exists del-port br-int veth-d-ovs
```

### 4.2–4.4 Create, attach, and address the endpoints

On `node1`:

```bash
sudo ip netns add ns-a
sudo ip netns exec ns-a ip link set lo up
sudo ip link add veth-a type veth peer name veth-a-ovs
sudo ip link set veth-a netns ns-a

sudo ovs-vsctl --may-exist add-br br-int
sudo ip link set br-int up
sudo ovs-vsctl add-port br-int veth-a-ovs
sudo ip link set veth-a-ovs up
sudo ovs-vsctl set interface veth-a-ovs external-ids:iface-id=ls1-port1

sudo ip netns exec ns-a ip link set veth-a address aa:bb:cc:00:00:01
sudo ip netns exec ns-a ip addr add 10.0.1.10/24 dev veth-a
sudo ip netns exec ns-a ip link set veth-a up
```

On `node2`:

```bash
sudo ip netns add ns-b
sudo ip netns exec ns-b ip link set lo up
sudo ip link add veth-b type veth peer name veth-b-ovs
sudo ip link set veth-b netns ns-b

sudo ovs-vsctl --may-exist add-br br-int
sudo ip link set br-int up
sudo ovs-vsctl add-port br-int veth-b-ovs
sudo ip link set veth-b-ovs up
sudo ovs-vsctl set interface veth-b-ovs external-ids:iface-id=ls1-port2

sudo ip netns exec ns-b ip link set veth-b address aa:bb:cc:00:00:02
sudo ip netns exec ns-b ip addr add 10.0.1.20/24 dev veth-b
sudo ip netns exec ns-b ip link set veth-b up
```

**Verify** from `node1`:

```bash
sudo ovn-sbctl show
sudo ip netns exec ns-a ping -c 3 10.0.1.20
```

**Expected output:**
```
Chassis "e2b0c1a4-..."
    hostname: node1
    Encap geneve
        ip: "192.168.122.11"
    Port_Binding ls1-port1
Chassis "7d41f9c8-..."
    hostname: node2
    Encap geneve
        ip: "192.168.122.12"
    Port_Binding ls1-port2

PING 10.0.1.20 (10.0.1.20) 56(84) bytes of data.
64 bytes from 10.0.1.20: icmp_seq=1 ttl=64 time=1.42 ms
64 bytes from 10.0.1.20: icmp_seq=2 ttl=64 time=0.71 ms
64 bytes from 10.0.1.20: icmp_seq=3 ttl=64 time=0.68 ms

--- 10.0.1.20 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss
```

> Each `Port_Binding` now appears under the chassis that owns it. The two
> namespaces are on **different physical hosts** yet see each other as
> same-subnet L2 neighbours with `ttl=64` — no routing happened, the frame was
> encapsulated in Geneve, carried over the underlay, and decapsulated on the
> far side.
>
> **Why MAC/IP must match the OVN port:** `lsp-set-addresses` defines the port's
> allowed source identity. `ovn-northd` compiles port-security logical flows in
> `ls_in_port_sec_l2` / `ls_in_port_sec_ip` that drop any frame whose source MAC
> or IP does not match. A mismatch produces silent packet loss that looks like a
> broken tunnel — check `ovn-nbctl lsp-get-addresses` first when debugging.

If the ping fails, work down the stack:

```bash
sudo ovn-sbctl show | grep -c Port_Binding   # are both ports bound?
sudo ovs-vsctl get Interface veth-a-ovs external_ids   # is iface-id set?
sudo ovs-vsctl show | grep -c geneve         # does the tunnel port exist?
sudo tcpdump -ni <underlay-if> udp port 6081 # is anything on the wire?
```

### 4.5 Persist namespace and veth endpoint wiring (optional)

On `node1`:

```bash
sudo install -m 0755 persistence/node1/ovn-lab-endpoints.sh /usr/local/sbin/ovn-lab-endpoints-node1.sh
sudo install -m 0644 persistence/node1/ovn-lab-endpoints.service /etc/systemd/system/ovn-lab-endpoints.service
sudo systemctl daemon-reload
sudo systemctl enable --now ovn-lab-endpoints.service
```

On `node2`, the same with `persistence/node2/`.

**Verify:**

```bash
sudo systemctl status --no-pager ovn-lab-endpoints.service
sudo ip netns list
sudo ip netns exec ns-a ip -br addr show veth-a
```

**Expected output:**
```
● ovn-lab-endpoints.service - OVN lab endpoint wiring
     Active: active (exited) since ...

ns-a
ns-c

veth-a           UP             10.0.1.10/24
```

> `Active: active (exited)` is correct for a `Type=oneshot` unit with
> `RemainAfterExit=yes`. The OVN databases are already persistent, so this unit
> only has to rebuild the *local* Linux-side plumbing: namespaces, veth pairs,
> OVS ports, `iface-id` bindings, and addresses.

---

## Exercise 5 — Inspect logical flows, OpenFlow, and the Geneve tunnel

On `node1`:

```bash
sudo ovn-sbctl lflow-list ls1
sudo ovs-ofctl dump-flows br-int | head -40
```

**Expected output (abridged):**
```
Datapath: "ls1" (3f8a1c22-...)  Pipeline: ingress
  table=0 (ls_in_port_sec_l2  ), priority=50   , match=(inport == "ls1-port1" && eth.src == {aa:bb:cc:00:00:01}), action=(next;)
  table=27(ls_in_l2_lkup      ), priority=50   , match=(eth.dst == aa:bb:cc:00:00:02), action=(outport = "ls1-port2"; output;)
Datapath: "ls1" (3f8a1c22-...)  Pipeline: egress
  table=9 (ls_out_port_sec_l2 ), priority=50   , match=(outport == "ls1-port2" && eth.dst == {aa:bb:cc:00:00:02}), action=(output;)

 cookie=0x..., table=0, priority=100,in_port="veth-a-ovs" actions=load:0x1->OXM_OF_METADATA[],...,resubmit(,8)
 cookie=0x..., table=38, priority=100,reg15=0x2,metadata=0x1 actions=load:0x2->NXM_NX_TUN_ID[0..23],...,output:"ovn-7d41f9-0"
```

**Capture a real packet and trace it.** On `node1`:

```bash
ns_a_mac=$(sudo ip netns exec ns-a ip link show veth-a | awk '/ether/{print $2}')
flow=$(sudo tcpdump -nXXi veth-a-ovs -c1 "ether src ${ns_a_mac}" 2>/dev/null | ovs-tcpundump)
echo "$flow"
```

In a second terminal on `node1`:

```bash
sudo ip netns exec ns-a ping -c1 10.0.1.20
```

Back in the first terminal:

```bash
in_port=$(sudo ovs-vsctl get Interface veth-a-ovs ofport)
sudo ovs-appctl ofproto/trace br-int in_port=${in_port} ${flow}
```

**Expected output (abridged):**
```
bridge("br-int")
-------------------
 0. in_port=3, priority 100
    set_field:0x1->metadata
    resubmit(,8)
 8. metadata=0x1,dl_src=aa:bb:cc:00:00:01, priority 50
    resubmit(,9)
...
37. reg15=0x2,metadata=0x1, priority 100
    set_field:0x2->tun_id
    set_field:0x2->tun_metadata0
    output:5      <-- ovn-7d41f9-0 (geneve)

Final flow: ...
Datapath actions: set(tunnel(...,dst=192.168.122.12,ttl=64,tp_dst=6081,geneve({...})),...),4
```

**Run a logical trace:**

```bash
sudo ovn-trace --minimal ls1 \
  'inport=="ls1-port1" && eth.src==aa:bb:cc:00:00:01 && eth.dst==aa:bb:cc:00:00:02 && ip4.src==10.0.1.10 && ip4.dst==10.0.1.20 && ip.ttl==64 && icmp4'
```

**Expected output:**
```
# icmp,reg14=0x1,vlan_tci=0x0000,dl_src=aa:bb:cc:00:00:01,dl_dst=aa:bb:cc:00:00:02,nw_src=10.0.1.10,nw_dst=10.0.1.20,...
output("ls1-port2");
```

**Optional — watch the overlay.** On either node, while pinging:

```bash
sudo tcpdump -ni <underlay-if> udp port 6081
```

**Expected output:**
```
IP 192.168.122.11.51423 > 192.168.122.12.6081: Geneve, Flags [C], vni 0x2, proto TEB (0x6558): \
   IP 10.0.1.10 > 10.0.1.20: ICMP echo request, id 12, seq 1, length 64
IP 192.168.122.12.39217 > 192.168.122.11.6081: Geneve, Flags [C], vni 0x2, proto TEB (0x6558): \
   IP 10.0.1.20 > 10.0.1.10: ICMP echo reply, id 12, seq 1, length 64
```

> This is the whole point of the lab in one capture. The inner packet is the
> unmodified tenant frame; the outer header is underlay-only. The `vni` is the
> **logical port key**, and the Geneve TLV options carry OVN metadata
> (`tun_metadata0`) so the receiving chassis knows which logical datapath and
> which ingress port the frame belongs to — that is why policy still works after
> the tunnel hop.
>
> Note the difference between the two traces: `ovn-trace` says
> `output("ls1-port2")` and never mentions tunnels or chassis, because it
> simulates **logical intent**. `ofproto/trace` shows `output:5` into the Geneve
> port, because it simulates **this chassis's physical realization** of that
> intent. Same decision, two levels of abstraction.

---

## Exercise 6 — Create a second logical switch `ls2` across both hosts

On `node1`:

```bash
sudo ovn-nbctl ls-add ls2

sudo ovn-nbctl lsp-add ls2 ls2-port3
sudo ovn-nbctl lsp-set-addresses ls2-port3 "aa:bb:cc:00:00:03 10.0.2.10"

sudo ovn-nbctl lsp-add ls2 ls2-port4
sudo ovn-nbctl lsp-set-addresses ls2-port4 "aa:bb:cc:00:00:04 10.0.2.20"

sudo ip netns add ns-c
sudo ip netns exec ns-c ip link set lo up
sudo ip link add veth-c type veth peer name veth-c-ovs
sudo ip link set veth-c netns ns-c
sudo ovs-vsctl add-port br-int veth-c-ovs
sudo ip link set veth-c-ovs up
sudo ovs-vsctl set interface veth-c-ovs external-ids:iface-id=ls2-port3
sudo ip netns exec ns-c ip link set veth-c address aa:bb:cc:00:00:03
sudo ip netns exec ns-c ip addr add 10.0.2.10/24 dev veth-c
sudo ip netns exec ns-c ip link set veth-c up
```

On `node2`:

```bash
sudo ip netns add ns-d
sudo ip netns exec ns-d ip link set lo up
sudo ip link add veth-d type veth peer name veth-d-ovs
sudo ip link set veth-d netns ns-d
sudo ovs-vsctl add-port br-int veth-d-ovs
sudo ip link set veth-d-ovs up
sudo ovs-vsctl set interface veth-d-ovs external-ids:iface-id=ls2-port4
sudo ip netns exec ns-d ip link set veth-d address aa:bb:cc:00:00:04
sudo ip netns exec ns-d ip addr add 10.0.2.20/24 dev veth-d
sudo ip netns exec ns-d ip link set veth-d up
```

**Verify** on `node1`:

```bash
sudo ip netns exec ns-c ping -c 2 10.0.2.20
sudo ip netns exec ns-a ping -c 2 -W 2 10.0.2.10
```

**Expected output:**
```
PING 10.0.2.20 (10.0.2.20) 56(84) bytes of data.
64 bytes from 10.0.2.20: icmp_seq=1 ttl=64 time=1.31 ms
64 bytes from 10.0.2.20: icmp_seq=2 ttl=64 time=0.66 ms
--- 10.0.2.20 ping statistics ---
2 packets transmitted, 2 received, 0% packet loss

PING 10.0.2.10 (10.0.2.10) 56(84) bytes of data.
--- 10.0.2.10 ping statistics ---
2 packets transmitted, 0 received, 100% packet loss, time 1002ms
```

> The first ping crosses hosts on `ls2` and succeeds. The second fails **from
> the same host** (`ns-a` and `ns-c` are both on `node1`) — proving the failure
> is a *logical* one, not a physical one. Two logical switches are two separate
> broadcast domains regardless of where their ports are bound. Physical locality
> is irrelevant to OVN; only the logical topology decides reachability.
>
> Also note both tunnels reuse the **same** Geneve port. One tunnel per chassis
> pair carries every logical network, disambiguated by the tunnel key.

---

## Exercise 7 — Create logical router `lr1` for inter-subnet routing

On `node1`:

```bash
sudo ovn-nbctl lr-add lr1

sudo ovn-nbctl lrp-add lr1 lr1-ls1 aa:bb:cc:00:01:01 10.0.1.1/24
sudo ovn-nbctl lsp-add ls1 ls1-lr1
sudo ovn-nbctl lsp-set-type ls1-lr1 router
sudo ovn-nbctl lsp-set-addresses ls1-lr1 router
sudo ovn-nbctl lsp-set-options ls1-lr1 router-port=lr1-ls1

sudo ovn-nbctl lrp-add lr1 lr1-ls2 aa:bb:cc:00:01:02 10.0.2.1/24
sudo ovn-nbctl lsp-add ls2 ls2-lr1
sudo ovn-nbctl lsp-set-type ls2-lr1 router
sudo ovn-nbctl lsp-set-addresses ls2-lr1 router
sudo ovn-nbctl lsp-set-options ls2-lr1 router-port=lr1-ls2
```

Add default routes inside the namespaces.

On `node1`:

```bash
sudo ip netns exec ns-a ip route add default via 10.0.1.1
sudo ip netns exec ns-c ip route add default via 10.0.2.1
```

On `node2`:

```bash
sudo ip netns exec ns-b ip route add default via 10.0.1.1
sudo ip netns exec ns-d ip route add default via 10.0.2.1
```

**Verify** on `node1`:

```bash
sudo ovn-nbctl show
sudo ip netns exec ns-a ping -c 3 10.0.2.20
```

**Expected output:**
```
router 9c2e77a1-... (lr1)
    port lr1-ls1
        mac: "aa:bb:cc:00:01:01"
        networks: ["10.0.1.1/24"]
    port lr1-ls2
        mac: "aa:bb:cc:00:01:02"
        networks: ["10.0.2.1/24"]

PING 10.0.2.20 (10.0.2.20) 56(84) bytes of data.
64 bytes from 10.0.2.20: icmp_seq=1 ttl=63 time=1.55 ms
64 bytes from 10.0.2.20: icmp_seq=2 ttl=63 time=0.79 ms
64 bytes from 10.0.2.20: icmp_seq=3 ttl=63 time=0.74 ms
--- 10.0.2.20 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss
```

**Verify** on `node2`:

```bash
sudo ip netns exec ns-b ping -c 3 10.0.2.10
```

**Expected output:**
```
64 bytes from 10.0.2.10: icmp_seq=1 ttl=63 time=1.61 ms
3 packets transmitted, 3 received, 0% packet loss
```

> **`ttl=63`, not 64** — one hop was decremented, so the packet was genuinely
> routed. But look at where: there is **no router namespace** on either host, no
> `qrouter-*`, and no process forwarding packets. Confirm it:
>
> ```bash
> ip netns list | grep -c qrouter    # 0
> ```
>
> This is **distributed logical routing**. `ovn-northd` compiles the router's
> pipeline into logical flows that *every* chassis installs, so the routing
> decision for `ns-b → ns-d` is made locally on `node2` and never transits
> `node1`. In legacy ML2/OVS this traffic would have been hairpinned through a
> centralized network node. `ttl=63` on `node2` with no `node1` involvement is
> the proof.

---

## Exercise 8 — Add OVN ACLs in a multi-node topology

On `node1`:

```bash
sudo ovn-nbctl acl-add ls1 from-lport 1000 'ip4' drop
sudo ovn-nbctl acl-add ls1 from-lport 1100 'ip4 && icmp4' allow-related
sudo ovn-nbctl acl-add ls1 from-lport 1100 'ip4 && tcp && tcp.dst==22' allow-related
```

**Verify** on `node1`:

```bash
sudo ovn-nbctl acl-list ls1
sudo ip netns exec ns-a ping -c 2 10.0.1.20
```

**Expected output:**
```
from-lport  1100 (ip4 && icmp4) allow-related
from-lport  1100 (ip4 && tcp && tcp.dst==22) allow-related
from-lport  1000 (ip4) drop

64 bytes from 10.0.1.20: icmp_seq=1 ttl=64 time=1.18 ms
2 packets transmitted, 2 received, 0% packet loss
```

**Test the allowed TCP port.** On `node2`:

```bash
sudo ip netns exec ns-b bash -c 'nc -l -p 22'
```

On `node1`:

```bash
sudo ip netns exec ns-a bash -c 'echo hello | nc -w 2 10.0.1.20 22'
```

**Expected output:** `hello` appears in the `node2` listener; the `node1`
command exits `0` immediately.

**Test the blocked TCP port.** On `node2`:

```bash
sudo ip netns exec ns-b bash -c 'nc -l -p 80'
```

On `node1`:

```bash
sudo ip netns exec ns-a bash -c 'echo hello | nc -w 2 10.0.1.20 80'
```

**Expected output:** nothing arrives on `node2`; the `node1` command hangs for
2 seconds and exits non-zero. Confirm the drop is counted:

```bash
sudo ovs-ofctl dump-flows br-int | grep -i 'priority=1000' | grep drop
```

**Expected output:**
```
 cookie=0x..., n_packets=3, n_bytes=222, table=44, priority=1000,ip,metadata=0x1 actions=drop
```

Clean up the ACLs before continuing:

```bash
sudo ovn-nbctl acl-del ls1
```

> The ACL was written **once** on `node1` and enforced on **both** chassis —
> and critically, it was enforced on `node1` at the *source*, so the blocked
> packet never entered the tunnel at all. Policy is attached to the logical
> port, so it follows a workload if it is rebuilt on another chassis. That is
> the property OpenStack relies on for live migration: the security group moves
> with the port, not with the hypervisor.
>
> Recall from Lab 6 that per-switch ACLs like these are a teaching device;
> production Neutron renders security groups onto **port groups** instead.

---

## Exercise 9 — Enable OVN-native DHCP across both hosts

On `node1`:

```bash
DHCP_OPTS=$(sudo ovn-nbctl create DHCP_Options cidr=10.0.1.0/24 \
  options='"server_id"="10.0.1.1" "server_mac"="aa:bb:cc:00:01:01" "lease_time"="3600" "router"="10.0.1.1"')

sudo ovn-nbctl lsp-set-dhcpv4-options ls1-port1 $DHCP_OPTS
sudo ovn-nbctl lsp-set-dhcpv4-options ls1-port2 $DHCP_OPTS
```

On `node1`:

```bash
sudo apt install -y isc-dhcp-client
sudo ip netns exec ns-a ip addr flush dev veth-a
sudo ip netns exec ns-a dhclient -v veth-a
sudo ip netns exec ns-a ip addr show veth-a
```

**Expected output:**
```
DHCPDISCOVER on veth-a to 255.255.255.255 port 67 interval 3
DHCPOFFER of 10.0.1.10 from 10.0.1.1
DHCPREQUEST for 10.0.1.10 on veth-a to 255.255.255.255 port 67
DHCPACK of 10.0.1.10 from 10.0.1.1
bound to 10.0.1.10 -- renewal in 1620 seconds.

    inet 10.0.1.10/24 brd 10.0.1.255 scope global dynamic veth-a
```

On `node2`:

```bash
sudo apt install -y isc-dhcp-client
sudo ip netns exec ns-b ip addr flush dev veth-b
sudo ip netns exec ns-b dhclient -v veth-b
sudo ip netns exec ns-b ip addr show veth-b
```

**Expected output:**
```
DHCPOFFER of 10.0.1.20 from 10.0.1.1
DHCPACK of 10.0.1.20 from 10.0.1.1
bound to 10.0.1.20 -- renewal in 1791 seconds.

    inet 10.0.1.20/24 brd 10.0.1.255 scope global dynamic veth-b
```

**Verify no DHCP crossed the tunnel:**

```bash
# Run on node1 while node2's dhclient is running:
sudo tcpdump -ni <underlay-if> udp port 6081 -c 5
ps aux | grep '[d]nsmasq'
```

**Expected output:** no Geneve packets carrying DHCP, and no `dnsmasq` process
on either node.

> One `DHCP_Options` row, defined once on `node1`, served two clients on two
> different hosts — and **neither DISCOVER left its own chassis**. Each
> `ovn-controller` compiled the same `put_dhcp_opts` logical flow into its local
> `br-int` and answered from there.
>
> This is the clearest example of the OVN model in the whole lab: **centralized
> intent, distributed enforcement**. A legacy ML2/OVS deployment would have run
> a `dnsmasq` in a `qdhcp-*` namespace on a network node, and every DHCP request
> from every compute host would have had to reach it.

---

## Exercise 10 — Deep inspection of the final multi-node state

On `node1`:

```bash
sudo ovn-sbctl show
sudo ovn-sbctl list Chassis | grep -E '^name|hostname'
sudo ovs-ofctl dump-flows br-int | wc -l
sudo ovn-sbctl lflow-list ls1 | grep -i arp
```

**Expected output:**
```
Chassis "e2b0c1a4-..."
    hostname: node1
    Encap geneve
        ip: "192.168.122.11"
    Port_Binding ls1-port1
    Port_Binding ls2-port3
Chassis "7d41f9c8-..."
    hostname: node2
    Encap geneve
        ip: "192.168.122.12"
    Port_Binding ls1-port2
    Port_Binding ls2-port4

412

  table=24(ls_in_arp_rsp), priority=50, match=(arp.tpa == 10.0.1.20 && arp.op == 1),
    action=(eth.dst = eth.src; eth.src = aa:bb:cc:00:00:02; arp.op = 2; ... outport = inport; output;)
```

On `node2`:

```bash
sudo ovs-ofctl dump-flows br-int | wc -l
sudo ovs-vsctl show
```

**Expected output:**
```
409

    Bridge br-int
        Port veth-b-ovs
            Interface veth-b-ovs
        Port veth-d-ovs
            Interface veth-d-ovs
        Port ovn-e2b0c1-0
            Interface ovn-e2b0c1-0
                type: geneve
                options: {csum="true", key=flow, remote_ip="192.168.122.11"}
```

> Three observations that summarize the lab:
>
> 1. **Both chassis carry a near-identical flow count** (412 vs 409) even though
>    they host different ports. Each host installs the *entire* logical pipeline
>    for every datapath it participates in — that is what makes routing, DHCP,
>    and ACLs distributed rather than centralized.
> 2. **ARP is answered locally.** The `ls_in_arp_rsp` flow means `node1` replies
>    on behalf of `ns-b` without ever broadcasting across the tunnel. OVN knows
>    every port's MAC from the NB DB, so ARP suppression is free.
> 3. **Exactly one tunnel per chassis pair.** `node2` has a single Geneve port
>    back to `node1` carrying both `ls1` and `ls2` traffic, keyed per logical
>    datapath. Adding a third network adds zero tunnels; adding a third chassis
>    adds one tunnel per existing chassis.

---

## Exercise 11 — Capstone mapping to OpenStack

| OVN command in this lab | OpenStack equivalent |
|---|---|
| `ovn-nbctl ls-add ls1` | `openstack network create net1` (+ its subnet) |
| `ovn-nbctl lsp-add ls1 ls1-port1` | `openstack port create --network net1 port1` |
| `ovn-nbctl lsp-set-addresses ...` | Neutron IPAM writing the fixed IP + MAC onto the port |
| `ovn-nbctl lr-add lr1` | `openstack router create router1` |
| `ovn-nbctl lrp-add lr1 ...` + router-type LSP | `openstack router add subnet router1 subnet1` |
| `ovn-nbctl acl-add ...` | `openstack security group rule create ...` |
| `ovn-nbctl create DHCP_Options ...` | `openstack subnet create --dhcp ...` |
| `ovs-vsctl set interface ... iface-id=...` | Nova/`os-vif` plugging a VM TAP into `br-int` |
| `external-ids:ovn-remote` / `ovn-encap-ip` | `ovn_sb_connection` / `ovn_encap_ip` in `ml2_conf.ini` |
| Geneve tunnel between nodes | the OVN overlay between compute nodes |
| `ovn-sbctl show` chassis list | `openstack network agent list` (OVN controller agents) |

**The debugging workflow this unlocks:**

```
OpenStack object          →  OVN object                  →  Local datapath
--------------------------------------------------------------------------
openstack port show <id>  →  ovn-nbctl find Logical_Switch_Port name=<id>
                          →  ovn-sbctl find Port_Binding logical_port=<id>   (which chassis?)
                          →  ssh that chassis
                          →  ovs-vsctl find Interface external_ids:iface-id=<id>
                          →  ovs-appctl ofproto/trace br-int in_port=<n> <flow>
```

> When an OpenStack deployment misbehaves, this translation chain is almost
> always the shortest path to a root cause: find the Neutron port UUID, look it
> up in the NB DB to confirm intent is correct, look it up in the SB DB to find
> which chassis owns it, then trace the datapath on that host. If NB is right
> but SB is wrong, suspect `ovn-northd`. If SB is right but the datapath is
> wrong, suspect that chassis's `ovn-controller`.

---

## Cleanup

Remove the logical topology and local wiring, but keep the persistent control
plane configuration so the environment can be reused.

If you enabled the endpoint persistence unit in Exercise 4.5, disable it first:

```bash
sudo systemctl disable --now ovn-lab-endpoints.service
```

On `node1`:

```bash
sudo ovn-nbctl --if-exists lr-del lr1
sudo ovn-nbctl --if-exists ls-del ls1
sudo ovn-nbctl --if-exists ls-del ls2

for ns in ns-a ns-c; do sudo ip netns delete $ns 2>/dev/null; done
sudo ovs-vsctl --if-exists del-port br-int veth-a-ovs
sudo ovs-vsctl --if-exists del-port br-int veth-c-ovs
```

On `node2`:

```bash
for ns in ns-b ns-d; do sudo ip netns delete $ns 2>/dev/null; done
sudo ovs-vsctl --if-exists del-port br-int veth-b-ovs
sudo ovs-vsctl --if-exists del-port br-int veth-d-ovs
```

**Verify:**

```bash
sudo ovn-nbctl show          # empty
sudo ovn-sbctl show          # both chassis still registered, no port bindings
sudo ip netns list           # empty
```

> The chassis remain registered and the Geneve tunnel stays up — the control
> plane configuration from Exercise 2 lives in OVSDB and survives both this
> cleanup and a reboot. Only the logical topology and the local Linux plumbing
> were removed.

---

*Lab 7 Solution — OpenStack Networking Workshop*
