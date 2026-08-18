# Lab 6 — Solution: OVN Native Services — DHCP, DNS & Metadata

> **This file is released with Lab 7.** It contains the full commands and expected output for Lab 6's exercises.

---

## Prerequisites — Rebuild Lab 5 Topology

Lab 6 starts from the Lab 5 end-state: `ls1`, `ls2`, router `lr1`, and
namespaces `ns-a` through `ns-d`. If you cleaned up, rebuild from the Lab 5
solution first.

**Verify:**
```bash
ovn-nbctl show
```

**Expected output:** `ls1`, `ls2`, router `lr1`, and ports `ls1-port1`,
`ls1-port2`, `ls2-port3`, `ls2-port4` are present with the Lab 5 addresses.
---

## Exercise 1 — Add a DHCP server for `ls1`

```bash
d1=$(ovn-nbctl create DHCP_Options cidr=10.0.1.0/24 \
  options='"server_id"="10.0.1.1" "server_mac"="aa:bb:cc:00:01:01" \
           "lease_time"="3600" "router"="10.0.1.1" \
           "dns_server"="{8.8.8.8}" "mtu"="1442"')
ovn-nbctl lsp-set-dhcpv4-options ls1-port1 $d1
ovn-nbctl lsp-set-dhcpv4-options ls1-port2 $d1
```

**Verify:**

```bash
ovn-nbctl list DHCP_Options
ovn-sbctl dump-flows ls1 | grep -i dhcp
```

**Expected output:**
```
_uuid               : xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
cidr                : "10.0.1.0/24"
options             : {dns_server="{8.8.8.8}", lease_time="3600", mtu="1442", router="10.0.1.1", server_id="10.0.1.1", server_mac="aa:bb:cc:00:01:01"}

  table=12(ls_in_dhcp_options), priority=100, match=(inport == "ls1-port1" && udp.src == 68 && udp.dst == 67), action=(reg0[3] = put_dhcp_opts(...); next;)
  table=13(ls_in_dhcp_response), priority=100, match=(inport == "ls1-port1" && reg0[3]), action=(eth.dst = eth.src; eth.src = aa:bb:cc:00:01:01; ip4.dst = 10.0.1.10; ip4.src = 10.0.1.1; udp.src = 67; udp.dst = 68; output;)
```

> MTU `1442` accounts for Geneve overlay overhead. Neutron does the same using
> `path_mtu`, then writes the value into OVN DHCP options.

---

## Exercise 2 — Boot `ns-a` via DHCP

```bash
sudo ip netns exec ns-a ip addr flush dev veth-a
sudo ip netns exec ns-a ip route flush default
sudo ip netns exec ns-a dhclient -v veth-a
```

**Expected output:**
```
Listening on LPF/veth-a/aa:bb:cc:00:00:01
DHCPDISCOVER on veth-a to 255.255.255.255 port 67 interval 3
DHCPOFFER of 10.0.1.10 from 10.0.1.1
DHCPREQUEST for 10.0.1.10 on veth-a to 255.255.255.255 port 67
DHCPACK of 10.0.1.10 from 10.0.1.1
bound to 10.0.1.10 -- renewal in 1620 seconds.
```

**Verify:**

```bash
sudo ip netns exec ns-a ip addr show veth-a
sudo ip netns exec ns-a ip route
sudo tcpdump -ni veth-a-ovs 'port 67 or port 68'
ps aux | grep '[d]nsmasq'
```

**Expected output:**
```
2: veth-a@ifX: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1442 state UP
    link/ether aa:bb:cc:00:00:01 brd ff:ff:ff:ff:ff:ff
    inet 10.0.1.10/24 brd 10.0.1.255 scope global dynamic veth-a

default via 10.0.1.1 dev veth-a
10.0.1.0/24 dev veth-a proto kernel scope link src 10.0.1.10

IP 0.0.0.0.68 > 255.255.255.255.67: BOOTP/DHCP, Request from aa:bb:cc:00:00:01
IP 10.0.1.1.67 > 10.0.1.10.68: BOOTP/DHCP, Reply
# grep dnsmasq: no output
```

> The OFFER is generated locally by `ovn-controller` through `br-int` flows
> compiled from `put_dhcp_opts`; there is no `dnsmasq` or `qdhcp-*` namespace.
> The source MAC is the configured `server_mac` (`aa:bb:cc:00:01:01`), giving
> the guest a stable L2 peer for replies to the DHCP server IP.

---

## Exercise 3 — Dynamic addressing (OVN as IPAM)

```bash
ovn-nbctl set Logical_Switch ls1 \
  other_config:subnet=10.0.1.0/24 \
  other_config:exclude_ips=10.0.1.1..10.0.1.9
ovn-nbctl lsp-add ls1 ls1-port-dyn
ovn-nbctl lsp-set-addresses ls1-port-dyn dynamic
ovn-nbctl lsp-set-dhcpv4-options ls1-port-dyn $d1
```

**Verify:**

```bash
ovn-nbctl get Logical_Switch_Port ls1-port-dyn dynamic_addresses
ovn-nbctl list Logical_Switch_Port ls1-port-dyn
```

**Expected output:**
```
"0a:00:00:00:00:03 10.0.1.11"

_uuid               : xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
addresses           : [dynamic]
dhcpv4_options      : xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
dynamic_addresses   : "0a:00:00:00:00:03 10.0.1.11"
name                : ls1-port-dyn
```

> `dynamic` lets OVN pick MAC and IP. `"aa:bb:cc:00:00:05 dynamic"` keeps your
> MAC and lets OVN pick only the IP. `"aa:bb:cc:00:00:05 10.0.1.50"` is fully
> static. The assigned IP is outside the excluded infrastructure range.

---

## Exercise 4 — Add DHCPv6 (optional but recommended)

Use stateful DHCPv6 here so the result is visible and deterministic.

```bash
ovn-nbctl set Logical_Router_Port lr1-ls1 networks='["10.0.1.1/24", "fd00:1::1/64"]'
ovn-nbctl set Logical_Router_Port lr1-ls1 \
  ipv6_ra_configs:send_periodic=true \
  ipv6_ra_configs:address_mode=dhcpv6_stateful
ovn-nbctl lsp-set-addresses ls1-port1 "aa:bb:cc:00:00:01 10.0.1.10 fd00:1::10"

d6=$(ovn-nbctl create DHCP_Options cidr=fd00:1::/64 \
  options='"server_id"="00:00:00:00:00:01" "dns_server"="{fd00:1::1}"')
ovn-nbctl lsp-set-dhcpv6-options ls1-port1 $d6
ovn-nbctl lsp-set-dhcpv6-options ls1-port2 $d6
```

**Verify:**

```bash
ovn-nbctl list DHCP_Options
ovn-sbctl dump-flows ls1 | grep -i dhcpv6
sudo ip netns exec ns-a dhclient -6 -v veth-a
sudo ip netns exec ns-a ip -6 addr show dev veth-a
```

**Expected output:**
```
cidr                : "fd00:1::/64"
options             : {dns_server="{fd00:1::1}", server_id="00:00:00:00:00:01"}

table=12(ls_in_dhcp_options), priority=100, match=(inport == "ls1-port1" && ip6 && udp.src == 546 && udp.dst == 547), action=(reg0[3] = put_dhcpv6_opts(...); next;)

inet6 fd00:1::10/128 scope global dynamic
inet6 fe80::a8bb:ccff:fe00:1/64 scope link
```

> Neutron exposes this as subnet `ipv6_ra_mode` and `ipv6_address_mode`. Many
> clouds use SLAAC or stateless DHCPv6; stateful DHCPv6 is chosen here because it
> clearly demonstrates OVN handing a lease to the guest.

---

## Exercise 5 — Internal DNS with OVN

```bash
dns=$(ovn-nbctl create DNS records:vm-a.lab.local=10.0.1.10)
ovn-nbctl add DNS $dns records vm-c.lab.local=10.0.2.10
ovn-nbctl add Logical_Switch ls1 dns_records $dns
ovn-nbctl add Logical_Switch ls2 dns_records $dns
ovn-nbctl set DHCP_Options $d1 \
  options='"server_id"="10.0.1.1" "server_mac"="aa:bb:cc:00:01:01" \
           "lease_time"="3600" "router"="10.0.1.1" \
           "dns_server"="{10.0.1.1}" "mtu"="1442"'
sudo ip netns exec ns-a dhclient -r veth-a
sudo ip netns exec ns-a dhclient -v veth-a
```

**Verify:**

```bash
ovn-nbctl list DNS
sudo ip netns exec ns-a nslookup vm-a.lab.local 10.0.1.1
sudo ip netns exec ns-a nslookup vm-c.lab.local 10.0.1.1
ovn-sbctl dump-flows ls1 | grep -i dns
```

**Expected output:**
```
records             : {vm-a.lab.local="10.0.1.10", vm-c.lab.local="10.0.2.10"}

Server:         10.0.1.1
Address:        10.0.1.1#53
Name:   vm-a.lab.local
Address: 10.0.1.10

Name:   vm-c.lab.local
Address: 10.0.2.10

table=12(ls_in_dns_lookup), priority=100, match=(udp.dst == 53), action=(reg0[4] = dns_lookup(); next;)
table=13(ls_in_dns_response), priority=100, match=(reg0[4]), action=(eth.dst <-> eth.src; ip4.dst <-> ip4.src; udp.src = 53; output;)
```

> OVN DNS records compile into local logical flows. Matching queries are handled
> by `dns_lookup()` / DNS response actions in OVS instead of an upstream resolver.

---

## Exercise 6 — The metadata data-path (`169.254.169.254`)

```bash
ovn-nbctl lsp-add ls1 ls1-metadata
ovn-nbctl lsp-set-type ls1-metadata localport
ovn-nbctl lsp-set-addresses ls1-metadata "aa:bb:cc:00:0f:fe 169.254.169.254"

sudo ip link add veth-md type veth peer name veth-md-ovs
sudo ovs-vsctl add-port br-int veth-md-ovs \
  -- set interface veth-md-ovs external-ids:iface-id=ls1-metadata
sudo ip link set veth-md-ovs up
sudo ip link set veth-md up
sudo ip addr add 169.254.169.254/32 dev veth-md

mkdir -p metadata-stub
echo '{"hostname":"vm-a","public-keys":"ssh-ed25519 AAAA..."}' > metadata-stub/meta.json
sudo python3 -m http.server 80 --bind 169.254.169.254 --directory metadata-stub &

sudo ip netns exec ns-a ip route add 169.254.169.254/32 dev veth-a
sudo ip netns exec ns-a curl -s http://169.254.169.254/meta.json
```

**Expected output:**
```
{"hostname":"vm-a","public-keys":"ssh-ed25519 AAAA..."}
```

**Verify:**

```bash
ovn-sbctl find Port_Binding logical_port=ls1-metadata
```

**Expected output:**
```
_uuid               : xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
chassis             : []
logical_port        : ls1-metadata
mac                 : ["aa:bb:cc:00:0f:fe 169.254.169.254"]
type                : localport
```

> Metadata must be a `localport` because every chassis must answer
> `169.254.169.254` locally. A normal port would bind to one chassis and tunnel
> traffic there, breaking locality, scale, and failure isolation.
>
> In real OpenStack, `neutron-ovn-metadata-agent` starts `haproxy` in an
> `ovnmeta-*` namespace. That proxy injects `X-Instance-ID`, `X-Tenant-ID`, and
> related headers before forwarding to Nova, which uses them to return the right
> instance data. Legacy ML2/OVS instead reached metadata through `qdhcp-*` or
> `qrouter-*` namespaces and `neutron-metadata-agent`.

---

## Exercise 7 — Tie it together: a "zero-touch" port

```bash
ovn-nbctl lsp-add ls1 ls1-port-zero
ovn-nbctl lsp-set-addresses ls1-port-zero dynamic
ovn-nbctl lsp-set-dhcpv4-options ls1-port-zero $d1
zero_addr=$(ovn-nbctl get Logical_Switch_Port ls1-port-zero dynamic_addresses | tr -d '"')
zero_mac=$(echo $zero_addr | awk '{print $1}')
zero_ip=$(echo $zero_addr | awk '{print $2}')
ovn-nbctl add DNS $dns records vm-zero.lab.local=$zero_ip
echo "zero-touch port: $zero_mac $zero_ip"
```

**Expected output:**
```
zero-touch port: 0a:00:00:00:00:04 10.0.1.12
```

```bash
sudo ip netns add ns-zero
sudo ip netns exec ns-zero ip link set lo up
sudo ip link add veth-zero type veth peer name veth-zero-ovs
sudo ip link set veth-zero netns ns-zero
sudo ovs-vsctl add-port br-int veth-zero-ovs \
  -- set interface veth-zero-ovs external-ids:iface-id=ls1-port-zero
sudo ip link set veth-zero-ovs up
sudo ip netns exec ns-zero ip link set veth-zero address $zero_mac
sudo ip netns exec ns-zero ip link set veth-zero up
sudo ip netns exec ns-zero dhclient -v veth-zero
sudo ip netns exec ns-zero ip route add 169.254.169.254/32 dev veth-zero
```

**Expected output:**
```
Listening on LPF/veth-zero/0a:00:00:00:00:04
DHCPDISCOVER on veth-zero to 255.255.255.255 port 67 interval 3
DHCPOFFER of 10.0.1.12 from 10.0.1.1
DHCPREQUEST for 10.0.1.12 on veth-zero to 255.255.255.255 port 67
DHCPACK of 10.0.1.12 from 10.0.1.1
bound to 10.0.1.12 -- renewal in 1700 seconds.
```

**Verify:**

```bash
sudo ip netns exec ns-zero ip addr show veth-zero
sudo ip netns exec ns-zero ip route
sudo ip netns exec ns-zero nslookup vm-a.lab.local 10.0.1.1
sudo ip netns exec ns-zero curl -s http://169.254.169.254/meta.json
```

**Expected output:**
```
inet 10.0.1.12/24 brd 10.0.1.255 scope global dynamic veth-zero

default via 10.0.1.1 dev veth-zero
10.0.1.0/24 dev veth-zero proto kernel scope link src 10.0.1.12
169.254.169.254 dev veth-zero scope link

Name:   vm-a.lab.local
Address: 10.0.1.10

{"hostname":"vm-a","public-keys":"ssh-ed25519 AAAA..."}
```

> No IP, gateway, DNS server, or MTU was typed inside `ns-zero`: Nova plugs
> the TAP, cloud-init runs DHCP, OVN provides DNS, and metadata stays local.

---

*Lab 6 Solution — OpenStack Networking Workshop*
