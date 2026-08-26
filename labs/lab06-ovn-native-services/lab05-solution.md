# Lab 5 — Solution: OVN Basics (Open Virtual Network)

> **This is the final lab's solution.** It contains the full commands and
> expected output for Lab 5's exercises.

---

## Exercise 1 — Install OVN

```bash
sudo apt install -y ovn-central ovn-host
```

**Verify:**

```bash
ovn-nbctl show
```

**Expected output:** (empty — no logical resources)

```bash
ovn-sbctl show
```

**Expected output:**
```
Chassis "<hostname>"
    hostname: "<hostname>"
    Encap geneve
        ip: "127.0.0.1"
        options: {csum="true"}
```

> If `ovn-sbctl show` is completely empty, `ovn-controller` may not be
> running yet — it will be configured in Exercise 2.

---

## Exercise 2 — Initialize OVN and Register the Chassis

```bash
# Ensure OVN central services are running
sudo systemctl start ovn-central
sudo systemctl start ovn-controller

# Configure ovn-controller to connect to the local Southbound DB
sudo ovs-vsctl set open . \
  external-ids:ovn-remote=unix:/var/run/ovn/ovnsb_db.sock \
  external-ids:ovn-encap-type=geneve \
  external-ids:ovn-encap-ip=127.0.0.1
```

**Verify:**

```bash
ovn-sbctl show
```

**Expected output:**
```
Chassis "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    hostname: "ubuntu"
    Encap geneve
        ip: "127.0.0.1"
        options: {csum="true"}
```

> The chassis UUID is auto-generated from the OVS system UUID. The
> `ovn-encap-ip` is set to `127.0.0.1` because we're running everything
> on a single host. In a multi-node setup, this would be the host's
> management IP.

---

## Exercise 3 — Create a Logical Switch and Ports

```bash
# Create the logical switch
ovn-nbctl ls-add ls1

# Add ports with static MAC + IP bindings
ovn-nbctl lsp-add ls1 ls1-port1
ovn-nbctl lsp-set-addresses ls1-port1 "aa:bb:cc:00:00:01 10.0.1.10"

ovn-nbctl lsp-add ls1 ls1-port2
ovn-nbctl lsp-set-addresses ls1-port2 "aa:bb:cc:00:00:02 10.0.1.20"
```

**Verify:**

```bash
ovn-nbctl show
```

**Expected output:**
```
switch xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx (ls1)
    port ls1-port2
        addresses: ["aa:bb:cc:00:00:02 10.0.1.20"]
    port ls1-port1
        addresses: ["aa:bb:cc:00:00:01 10.0.1.10"]
```

---

## Exercise 4 — Bind Logical Ports to Namespaces

```bash
# Clean up any previous namespaces
for ns in ns-a ns-b ns-c ns-d; do
    sudo ip netns delete $ns 2>/dev/null
done

# Ensure br-int exists (OVN creates it, but make sure it's up)
sudo ovs-vsctl --may-exist add-br br-int
sudo ip link set br-int up

# --- ns-a (ls1-port1) ---
sudo ip netns add ns-a
sudo ip netns exec ns-a ip link set lo up

sudo ip link add veth-a type veth peer name veth-a-ovs
sudo ip link set veth-a netns ns-a
sudo ovs-vsctl add-port br-int veth-a-ovs
sudo ip link set veth-a-ovs up

# Bind to OVN logical port
sudo ovs-vsctl set interface veth-a-ovs \
  external-ids:iface-id=ls1-port1

# Configure namespace with matching MAC + IP
sudo ip netns exec ns-a ip link set veth-a address aa:bb:cc:00:00:01
sudo ip netns exec ns-a ip addr add 10.0.1.10/24 dev veth-a
sudo ip netns exec ns-a ip link set veth-a up

# --- ns-b (ls1-port2) ---
sudo ip netns add ns-b
sudo ip netns exec ns-b ip link set lo up

sudo ip link add veth-b type veth peer name veth-b-ovs
sudo ip link set veth-b netns ns-b
sudo ovs-vsctl add-port br-int veth-b-ovs
sudo ip link set veth-b-ovs up

# Bind to OVN logical port
sudo ovs-vsctl set interface veth-b-ovs \
  external-ids:iface-id=ls1-port2

# Configure namespace with matching MAC + IP
sudo ip netns exec ns-b ip link set veth-b address aa:bb:cc:00:00:02
sudo ip netns exec ns-b ip addr add 10.0.1.20/24 dev veth-b
sudo ip netns exec ns-b ip link set veth-b up
```

**Verify — port binding:**

```bash
ovn-sbctl show
```

**Expected output:**
```
Chassis "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    hostname: "ubuntu"
    Encap geneve
        ip: "127.0.0.1"
        options: {csum="true"}
    Port_Binding ls1-port1
    Port_Binding ls1-port2
```

> Both ports show as bound to the local chassis. This is the equivalent of
> a VM's TAP device being attached to `br-int` with the correct `iface-id`.

**Verify — L2 connectivity:**

```bash
sudo ip netns exec ns-a ping -c 3 10.0.1.20
```

**Expected output:**
```
PING 10.0.1.20 (10.0.1.20) 56(84) bytes of data.
64 bytes from 10.0.1.20: icmp_seq=1 ttl=64 time=0.XXX ms
64 bytes from 10.0.1.20: icmp_seq=2 ttl=64 time=0.XXX ms
64 bytes from 10.0.1.20: icmp_seq=3 ttl=64 time=0.XXX ms
```

🎉 L2 connectivity through OVN!

> **Important:** The MAC address inside the namespace **must** match the one
> configured in OVN (`lsp-set-addresses`). OVN implements port security by
> default — it drops frames whose source MAC doesn't match the expected value.

---

## Exercise 5 — Inspect Logical Flows and OpenFlow Rules

```bash
# Logical flows for ls1
ovn-sbctl lflow-list ls1
```

> You'll see dozens of logical flows across multiple tables (ingress and
> egress pipelines). Key tables include:
> - **Table 0 (ls_in_check_port_sec):** Port security checks.
> - **Table 8 (ls_in_pre_acl / ls_in_acl):** ACL processing.
> - **Table 13 (ls_in_l2_lkup):** L2 lookup and forwarding.
> - ARP responder flows that reply to ARP queries with known MAC→IP mappings.

```bash
# OpenFlow rules on br-int
sudo ovs-ofctl dump-flows br-int | head -40
```

> You'll see many more flows than the single `NORMAL` rule from Lab 3.
> OVN replaces the `NORMAL` action with precise per-packet flow rules.

**Tracing a packet through the OpenFlow pipeline:**

**Terminal 1** — capture an outgoing packet:

```bash
ns_a_mac=$(sudo ip netns exec ns-a ip link show veth-a | awk '/ether/{print $2}')
flow=$(sudo tcpdump -nXXi veth-a-ovs -c1 "ether src ${ns_a_mac}" 2>/dev/null \
  | ovs-tcpundump)
echo "Captured flow: $flow"
```

**Terminal 2** — generate traffic to trigger the capture:

```bash
sudo ip netns exec ns-a ping -c1 10.0.1.20
```

**Terminal 1** (after capture completes):

```bash
in_port=$(sudo ovs-vsctl get Interface veth-a-ovs ofport)
sudo ovs-appctl ofproto/trace br-int in_port=${in_port} ${flow}
```

**Expected output (abbreviated):**

```
Flow: in_port=X,dl_src=aa:bb:cc:00:00:01,dl_dst=aa:bb:cc:00:00:02,...
bridge("br-int")
-----------------
 0. in_port=X, priority 100
    set_field:0x...->reg13
    set_field:0x...->reg11
    ...
    resubmit(,8)
 8. ..., priority 100
    resubmit(,9)
...
41. ..., priority 100
    output:Y

Final flow: ...
Megaflow: ...
Datapath actions: Y
```

> The trace shows the packet traversing OVN's multi-table pipeline —
> port security → pre-ACL → ACL → L2 lookup → output. The final
> `Datapath actions: Y` confirms the packet exits on the port connected
> to `ns-b`.

**Using ovn-trace (logical level):**

```bash
ovn-trace --minimal ls1 \
  'inport=="ls1-port1" && eth.src==aa:bb:cc:00:00:01 && eth.dst==aa:bb:cc:00:00:02 && ip4.src==10.0.1.10 && ip4.dst==10.0.1.20 && ip.ttl==64 && icmp4'
```

**Expected output:**
```
# icmp,reg14=0x...,vlan_tci=0x0000,...
output("ls1-port2");
```

> `ovn-trace` works at the **logical** level — it shows what OVN intends
> to do (output to ls1-port2). `ofproto/trace` works at the **physical**
> level — it shows the actual OpenFlow tables and actions on this host.

---

## Exercise 6 — Create a Second Logical Switch

```bash
# Create ls2 with two ports
ovn-nbctl ls-add ls2

ovn-nbctl lsp-add ls2 ls2-port3
ovn-nbctl lsp-set-addresses ls2-port3 "aa:bb:cc:00:00:03 10.0.2.10"

ovn-nbctl lsp-add ls2 ls2-port4
ovn-nbctl lsp-set-addresses ls2-port4 "aa:bb:cc:00:00:04 10.0.2.20"

# --- ns-c (ls2-port3) ---
sudo ip netns add ns-c
sudo ip netns exec ns-c ip link set lo up

sudo ip link add veth-c type veth peer name veth-c-ovs
sudo ip link set veth-c netns ns-c
sudo ovs-vsctl add-port br-int veth-c-ovs
sudo ip link set veth-c-ovs up

sudo ovs-vsctl set interface veth-c-ovs \
  external-ids:iface-id=ls2-port3

sudo ip netns exec ns-c ip link set veth-c address aa:bb:cc:00:00:03
sudo ip netns exec ns-c ip addr add 10.0.2.10/24 dev veth-c
sudo ip netns exec ns-c ip link set veth-c up

# --- ns-d (ls2-port4) ---
sudo ip netns add ns-d
sudo ip netns exec ns-d ip link set lo up

sudo ip link add veth-d type veth peer name veth-d-ovs
sudo ip link set veth-d netns ns-d
sudo ovs-vsctl add-port br-int veth-d-ovs
sudo ip link set veth-d-ovs up

sudo ovs-vsctl set interface veth-d-ovs \
  external-ids:iface-id=ls2-port4

sudo ip netns exec ns-d ip link set veth-d address aa:bb:cc:00:00:04
sudo ip netns exec ns-d ip addr add 10.0.2.20/24 dev veth-d
sudo ip netns exec ns-d ip link set veth-d up
```

**Verify — intra-switch connectivity on ls2:**

```bash
sudo ip netns exec ns-c ping -c 2 10.0.2.20
```

**Expected:** Success.

**Verify — cross-switch connectivity does NOT work yet:**

```bash
sudo ip netns exec ns-a ping -c 2 -W 2 10.0.2.10
```

**Expected:**
```
PING 10.0.2.10 (10.0.2.10) 56(84) bytes of data.
From 10.0.1.10 icmp_seq=1 Destination Host Unreachable
```

> Cross-switch traffic fails because there is no router connecting `ls1`
> and `ls2`. The namespaces are on different subnets with no route between
> them.

---

## Exercise 7 — Create a Logical Router

```bash
# Create the logical router
ovn-nbctl lr-add lr1

# Connect lr1 to ls1
ovn-nbctl lrp-add lr1 lr1-ls1 aa:bb:cc:00:01:01 10.0.1.1/24
ovn-nbctl lsp-add ls1 ls1-lr1
ovn-nbctl lsp-set-type ls1-lr1 router
ovn-nbctl lsp-set-addresses ls1-lr1 router
ovn-nbctl lsp-set-options ls1-lr1 router-port=lr1-ls1

# Connect lr1 to ls2
ovn-nbctl lrp-add lr1 lr1-ls2 aa:bb:cc:00:01:02 10.0.2.1/24
ovn-nbctl lsp-add ls2 ls2-lr1
ovn-nbctl lsp-set-type ls2-lr1 router
ovn-nbctl lsp-set-addresses ls2-lr1 router
ovn-nbctl lsp-set-options ls2-lr1 router-port=lr1-ls2
```

**Add default routes in the namespaces:**

```bash
sudo ip netns exec ns-a ip route add default via 10.0.1.1
sudo ip netns exec ns-b ip route add default via 10.0.1.1
sudo ip netns exec ns-c ip route add default via 10.0.2.1
sudo ip netns exec ns-d ip route add default via 10.0.2.1
```

**Verify — the full OVN topology:**

```bash
ovn-nbctl show
```

**Expected output:**
```
switch xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx (ls1)
    port ls1-lr1
        type: router
        router-port: lr1-ls1
    port ls1-port2
        addresses: ["aa:bb:cc:00:00:02 10.0.1.20"]
    port ls1-port1
        addresses: ["aa:bb:cc:00:00:01 10.0.1.10"]
switch xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx (ls2)
    port ls2-lr1
        type: router
        router-port: lr1-ls2
    port ls2-port4
        addresses: ["aa:bb:cc:00:00:04 10.0.2.20"]
    port ls2-port3
        addresses: ["aa:bb:cc:00:00:03 10.0.2.10"]
router xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx (lr1)
    port lr1-ls2
        mac: "aa:bb:cc:00:01:02"
        networks: ["10.0.2.1/24"]
    port lr1-ls1
        mac: "aa:bb:cc:00:01:01"
        networks: ["10.0.1.1/24"]
```

**Verify — cross-subnet routing:**

```bash
# ls1 → ls2
sudo ip netns exec ns-a ping -c 3 10.0.2.10
```

**Expected output:**
```
PING 10.0.2.10 (10.0.2.10) 56(84) bytes of data.
64 bytes from 10.0.2.10: icmp_seq=1 ttl=63 time=0.XXX ms
64 bytes from 10.0.2.10: icmp_seq=2 ttl=63 time=0.XXX ms
64 bytes from 10.0.2.10: icmp_seq=3 ttl=63 time=0.XXX ms
```

> **Note the TTL=63** (decremented from 64) — this confirms the packet was
> routed through `lr1`. OVN decrements TTL just like a real router.

```bash
# ls2 → ls1
sudo ip netns exec ns-c ping -c 2 10.0.1.20
```

**Expected:** Success (TTL=63).

**Trace the cross-subnet path with ovn-trace:**

```bash
ovn-trace --minimal ls1 \
  'inport=="ls1-port1" && eth.src==aa:bb:cc:00:00:01 && eth.dst==aa:bb:cc:00:01:01 && ip4.src==10.0.1.10 && ip4.dst==10.0.2.10 && ip.ttl==64 && icmp4'
```

**Expected output:**
```
# icmp,reg14=0x...,vlan_tci=0x0000,...
ip.ttl--;
eth.src = aa:bb:cc:00:01:02;
eth.dst = aa:bb:cc:00:00:03;
output("ls2-port3");
```

> The trace shows: TTL decrement → source MAC changed to the router's
> `lr1-ls2` port MAC → destination MAC changed to `ns-c`'s MAC →
> output to `ls2-port3`. This is exactly what a real router does.

---

## Exercise 8 — Add OVN ACLs

```bash
# Default deny: drop all IPv4 traffic from ls1 ports
ovn-nbctl acl-add ls1 from-lport 1000 'ip4' drop

# Allow ICMP
ovn-nbctl acl-add ls1 from-lport 1100 'ip4 && icmp4' allow-related

# Allow SSH (TCP port 22)
ovn-nbctl acl-add ls1 from-lport 1100 'ip4 && tcp && tcp.dst==22' allow-related
```

**Verify — list ACLs:**

```bash
ovn-nbctl acl-list ls1
```

**Expected output:**
```
from-lport  1000 (ip4) drop
from-lport  1100 (ip4 && icmp4) allow-related
from-lport  1100 (ip4 && tcp && tcp.dst==22) allow-related
```

**Verify — ICMP is allowed:**

```bash
sudo ip netns exec ns-a ping -c 2 10.0.1.20
```

**Expected:** Success. (ICMP matches the `allow-related` rule at priority 1100,
which beats the `drop` at priority 1000.)

**Verify — SSH (TCP 22) is allowed:**

```bash
# Start a listener on port 22 in ns-b
sudo ip netns exec ns-b bash -c 'nc -l -p 22 &'

# Connect from ns-a
sudo ip netns exec ns-a bash -c 'echo "hello" | nc -w 2 10.0.1.20 22'
```

**Expected:** The connection succeeds and "hello" is received.

**Verify — TCP 80 is blocked:**

```bash
# Start a listener on port 80 in ns-b
sudo ip netns exec ns-b bash -c 'nc -l -p 80 &'

# Try to connect from ns-a
sudo ip netns exec ns-a bash -c 'echo "hello" | nc -w 2 10.0.1.20 80'
```

**Expected:** The connection times out or is refused — TCP 80 matches the
`drop` rule at priority 1000 and does not match any `allow` rule.

**Verify — ls2 is unaffected:**

```bash
sudo ip netns exec ns-c ping -c 2 10.0.2.20
```

**Expected:** Success. (No ACLs on `ls2`.)

> **How OVN ACLs differ from iptables:**
> - ACLs are defined on a **logical switch** and apply to all its ports.
> - They are compiled into OVS OpenFlow rules — no iptables involved.
> - `allow-related` uses OVS connection tracking (`ct()`) to allow reply
>   traffic automatically.
> - They are enforced in the OVS flow pipeline, not in the kernel's
>   netfilter stack.

**Clean up ACLs for the remaining exercises:**

```bash
ovn-nbctl acl-del ls1
```

---

## Exercise 9 — Enable OVN-Native DHCP

```bash
# Create DHCP options for ls1's subnet
DHCP_OPTS=$(ovn-nbctl create DHCP_Options cidr=10.0.1.0/24 \
  options='"server_id"="10.0.1.1" "server_mac"="aa:bb:cc:00:01:01" "lease_time"="3600" "router"="10.0.1.1"')

echo "DHCP Options UUID: $DHCP_OPTS"
```

```bash
# Associate DHCP options with ls1 ports
ovn-nbctl lsp-set-dhcpv4-options ls1-port1 $DHCP_OPTS
ovn-nbctl lsp-set-dhcpv4-options ls1-port2 $DHCP_OPTS
```

**Verify — DHCP options are set:**

```bash
ovn-nbctl list DHCP_Options
```

**Expected output:**
```
_uuid               : xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
cidr                : "10.0.1.0/24"
external_ids        : {}
options             : {lease_time="3600", router="10.0.1.1", server_id="10.0.1.1", server_mac="aa:bb:cc:00:01:01"}
```

**Test DHCP from ns-a:**

First, remove the static IP to test DHCP assignment:

```bash
# Remove static IP
sudo ip netns exec ns-a ip addr flush dev veth-a

# Install dhclient if needed
sudo apt install -y isc-dhcp-client

# Request a DHCP lease
sudo ip netns exec ns-a dhclient -v veth-a
```

**Expected output (abbreviated):**
```
Listening on LPF/veth-a/aa:bb:cc:00:00:01
Sending on   LPF/veth-a/aa:bb:cc:00:00:01
DHCPDISCOVER on veth-a ...
DHCPOFFER of 10.0.1.10 from 10.0.1.1
DHCPREQUEST for 10.0.1.10 on veth-a ...
DHCPACK of 10.0.1.10 from 10.0.1.1
bound to 10.0.1.10 -- renewal in ...
```

**Verify — IP was assigned:**

```bash
sudo ip netns exec ns-a ip addr show veth-a
```

**Expected:** Shows `inet 10.0.1.10/24` assigned by DHCP.

**Verify — no dnsmasq process:**

```bash
ps aux | grep dnsmasq
```

**Expected:** No `dnsmasq` processes related to this setup. DHCP was handled
entirely by OVS flows generated from OVN's logical flows.

**Capture DHCP packets (optional):**

```bash
# In one terminal
sudo ip netns exec ns-a tcpdump -i veth-a -nn port 67 or port 68

# In another terminal, release and re-request
sudo ip netns exec ns-a dhclient -r veth-a
sudo ip netns exec ns-a dhclient veth-a
```

> You'll see the full DHCP exchange: Discover → Offer → Request → Ack.
> The "server" is OVS itself, responding via flow-generated packets.

---

## Exercise 10 — Deep Inspection

```bash
# Full logical topology
ovn-nbctl show
```

> Shows all logical switches (ls1, ls2), their ports, the router (lr1),
> and router ports — the complete virtual network topology.

```bash
# Physical bindings
ovn-sbctl show
```

> Shows the local chassis with all bound ports (ls1-port1, ls1-port2,
> ls2-port3, ls2-port4).

```bash
# Count OpenFlow rules
sudo ovs-ofctl dump-flows br-int | wc -l
```

> You'll likely see 50–100+ rules depending on your OVN version. Compare
> this to the single `NORMAL` rule from Lab 3!

```bash
# Find ARP responder flows in logical flows
ovn-sbctl lflow-list ls1 | grep -i arp
```

**Expected output (example):**
```
  table=XX(ls_in_arp_rsp), priority=50, match=(arp.tpa == 10.0.1.10 && arp.op == 1), action=(... arp.spa = 10.0.1.10; arp.tpa = ...; arp.op = 2; outport = inport; ...)
  table=XX(ls_in_arp_rsp), priority=50, match=(arp.tpa == 10.0.1.20 && arp.op == 1), action=(... arp.spa = 10.0.1.20; ...)
```

> **ARP suppression:** Instead of flooding ARP requests to all ports, OVN
> responds directly with the known MAC address — eliminating broadcast
> storms in large-scale deployments.

```bash
# Look for Geneve tunnel metadata in OpenFlow rules
sudo ovs-ofctl dump-flows br-int | grep -i "tun"
```

> On a single-node setup you won't see tunnel output actions (since all
> ports are local), but you'll see `reg` fields that carry logical
> datapath and port metadata — the same fields that would be encoded in
> Geneve TLV headers for cross-chassis traffic.

---

## Exercise 11 — (Capstone) Map to OpenStack Concepts

| What you did in this lab | OpenStack CLI equivalent |
|---|---|
| `ovn-nbctl ls-add ls1` | `openstack network create net1` |
| `ovn-nbctl lsp-add ls1 ls1-port1` | `openstack port create --network net1 port1` |
| `ovn-nbctl lsp-set-addresses ls1-port1 "mac ip"` | Neutron auto-assigns; or `--mac-address` / `--fixed-ip` |
| `ovn-nbctl lr-add lr1` | `openstack router create router1` |
| `ovn-nbctl lrp-add lr1 lr1-ls1 mac ip/mask` | `openstack router add subnet sub1` |
| `ovn-nbctl acl-add ls1 from-lport 1000 'ip4' drop` | `openstack security group rule create --protocol ip --ingress sg1` |
| `ovn-nbctl acl-add ls1 from-lport 1100 'icmp4' allow-related` | `openstack security group rule create --protocol icmp sg1` |
| `ovn-nbctl create DHCP_Options cidr=... options=...` | `openstack subnet create --dhcp-enabled --network net1 sub1` |
| `ovs-vsctl set interface ... external-ids:iface-id=...` | Nova does this when attaching a VM's TAP to `br-int` |

> In OpenStack, you never run `ovn-nbctl` manually. The **ML2/OVN mechanism
> driver** translates Neutron API calls into OVN Northbound DB operations
> automatically. Everything you did by hand in this lab is what Neutron does
> behind the scenes.

---

## Cleanup

```bash
# Remove OVN logical resources
ovn-nbctl lr-del lr1
ovn-nbctl ls-del ls1
ovn-nbctl ls-del ls2

# Remove DHCP options
for uuid in $(ovn-nbctl --no-headings --columns=_uuid find DHCP_Options | awk '{print $3}'); do
    ovn-nbctl destroy DHCP_Options $uuid
done

# Remove namespaces (also removes veth interfaces inside them)
for ns in ns-a ns-b ns-c ns-d; do
    sudo ip netns delete $ns 2>/dev/null
done

# Remove OVS ports (the veth-X-ovs ends)
for port in veth-a-ovs veth-b-ovs veth-c-ovs veth-d-ovs; do
    sudo ovs-vsctl --if-exists del-port br-int $port
done

# Optionally stop OVN services
# sudo systemctl stop ovn-controller
# sudo systemctl stop ovn-central
```

---

## Review Questions — Answers

1. **Two OVN databases:**
   - **Northbound DB (NB):** Stores the logical topology — switches, routers,
     ports, ACLs, DHCP options. This is what Neutron (or you) writes to.
   - **Southbound DB (SB):** Stores the compiled logical flows, chassis
     registrations, and port bindings. This is what `ovn-controller` reads.

2. **Role of `ovn-northd`:** It is the compiler. It watches the Northbound DB
   for changes, compiles the logical topology into logical flows, and writes
   them to the Southbound DB. It runs centrally (not on every host).

3. **Role of `ovn-controller`:** It runs on **every hypervisor/chassis**. It
   reads logical flows from the Southbound DB, combines them with local
   binding information, and programs the resulting OpenFlow rules into the
   local `br-int` OVS bridge.

4. **OVN DHCP vs. legacy Neutron:** Legacy Neutron runs a `dnsmasq` process
   inside a `qdhcp-*` namespace for each network. OVN implements DHCP entirely
   in OVS flows — when a DHCP request arrives, the flow pipeline generates
   a DHCP reply directly. No process, no namespace, better scalability.

5. **Overlay protocol — Geneve, not VXLAN:** OVN uses Geneve (RFC 8926) because
   it supports extensible TLV metadata headers. OVN encodes logical datapath
   ID and logical port ID in these headers, allowing `ovn-controller` to
   efficiently dispatch packets on the receiving end. VXLAN's fixed header
   only has a VNI field — not enough for OVN's needs.

6. **OVN ACL → OpenStack security group:** An OVN ACL is a match + action
   rule applied to a logical switch in a specific direction (`from-lport` or
   `to-lport`). In OpenStack, each security group rule becomes one or more
   OVN ACLs. `allow-related` maps to `conntrack` — stateful tracking that
   automatically permits reply traffic.

7. **OVN logical router vs. namespace-based router:** A traditional
   namespace-based router uses a Linux namespace with IP forwarding enabled
   and iptables for NAT — it processes packets in the kernel's network stack.
   An OVN logical router exists only in the OVN databases — routing is
   implemented as OpenFlow rules in OVS. There is no namespace, no iptables,
   and routing is **distributed**: every chassis with connected ports can
   route locally without hairpinning through a central network node.

8. **`ovn-trace` vs `ofproto/trace`:**
   - `ovn-trace`: Traces at the **logical** level. Works with logical switches,
     routers, and ports. Shows what OVN intends to do.
   - `ofproto/trace`: Traces at the **physical** level. Works with OVS OpenFlow
     tables and actual port numbers. Shows what happens to a real packet on
     this specific host.
   - Use `ovn-trace` to debug OVN logic; use `ofproto/trace` to debug the
     physical datapath on a specific chassis.

9. **Packet lifecycle (VM A → VM B, same logical switch):**
   1. VM A sends an Ethernet frame out its TAP device into `br-int`.
   2. `br-int`'s OpenFlow pipeline (installed by `ovn-controller`) processes it:
      - **Ingress pipeline:** port security check → pre-ACL → ACL → L2 lookup.
      - L2 lookup finds the destination port binding on the same chassis.
   3. If same chassis: the packet is output directly to VM B's port.
      If different chassis: the packet is encapsulated in a Geneve tunnel,
      sent to the remote chassis, decapsulated, and processed through the
      egress pipeline there.
   4. **Egress pipeline:** egress ACL → output to VM B's port.
   5. VM B receives the frame on its TAP device.

---

*Lab 5 Solution — OpenStack Networking Workshop*

