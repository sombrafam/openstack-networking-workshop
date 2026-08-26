# Lab 6 — Solution: OVN Native Services & Security Groups

> **This file is released with Lab 7.** It contains the full commands and expected output for Lab 6's exercises.

---

## Prerequisites — Rebuild the Lab 5 Topology and Clear its ACLs



Lab 6 starts from the Lab 5 end-state: `ls1`, `ls2`, router `lr1`, and
namespaces `ns-a` through `ns-d`. If you cleaned up, rebuild from the Lab 5
solution first.

**Verify:**
```bash
ovn-nbctl show
```

**Expected output:** `ls1`, `ls2`, router `lr1`, and ports `ls1-port1`,
`ls1-port2`, `ls2-port3`, `ls2-port4` are present with the Lab 5 addresses.



Lab 7 starts from the Lab 6 topology. Remove the old Lab 5 switch ACLs first:
```bash
ovn-nbctl acl-del ls1
ovn-nbctl acl-list ls1
```

**Expected output:** empty.

> Lab 5 used switch-scoped ACLs. Security groups need per-port scope, dynamic
> remote groups, and stateful return traffic.

---

# Part A — Native Services

---

## Exercise 1 — Add DHCP and boot `ns-a` without typing an IP

### Step 1 — Create the DHCP server for `ls1`



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

### Step 2 — Boot `ns-a` via DHCP



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

## Exercise 2 — Dynamic addressing (OVN as IPAM)



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

## Exercise 3 — Internal DNS with OVN



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

## Exercise 4 — The metadata data-path (`169.254.169.254`)



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

# Part B — Security Groups

---

## Exercise 5 — Model two tiers with Port Groups, then lock them down

### Step 1 — Create the port groups



Create security-group-like port groups. `ns-a` is web, `ns-c` is database, and
`ns-b` is admin/bastion:
```bash
ovn-nbctl pg-add pg-web  ls1-port1
ovn-nbctl pg-add pg-db   ls2-port3
ovn-nbctl pg-add pg-admin ls1-port2
```

**Verify:**
```bash
ovn-nbctl list port_group
```
**Expected output:**
```
_uuid : 5d6d0a9e-4f47-4a73-a78f-6cc7d71b6f32
name  : pg-web
ports : [3a2f5e32-f9ef-4b43-a6c3-5e9edbd9a2f1]
_uuid : 7f189056-c38e-4ce1-92a8-7ce5b245b43b
name  : pg-db
ports : [fd7c1d75-8e70-4c80-b27a-9ffce0bb5f95]
_uuid : d7f9b51f-0afe-40a4-98aa-d3a70b9617c1
name  : pg-admin
ports : [cf9d79c8-0be4-479a-bd4f-3d9a581b3759]
```
```bash
ovn-nbctl --format=table --columns=name,addresses list address_set
```
**Expected output:**
```
name          addresses
------------  ----------------
pg-admin_ip4  ["10.0.1.20"]
pg-admin_ip6  []
pg-db_ip4     ["10.0.2.10"]
pg-db_ip6     []
pg-web_ip4    ["10.0.1.10"]
pg-web_ip6    []
```

> **Why per-switch ACLs are wrong:** a web VM and DB VM can be on the same
> network but in different security groups. A switch ACL affects all ports on
> that switch; a Port Group ACL affects only members of that group.

> Use `@pg-web` for member **ports** in `inport`/`outport` matches. Use
> `$pg-web_ip4` / `$pg-web_ip6` for member **addresses**. ML2/OVN names real
> Neutron security-group port groups `pg_<sg_uuid>` and uses `neutron_pg_drop`
> for shared default-drop behavior.

### Step 2 — Default-deny, then allow only what's needed (web tier)



Add stateful web ingress rules, a default deny, and default-allow egress:
```bash
ovn-nbctl acl-add pg-web to-lport 1000 \
  'outport == @pg-web && ip4 && tcp.dst == 80' allow-related
ovn-nbctl acl-add pg-web to-lport 1010 \
  'outport == @pg-web && ip4.src == $pg-admin_ip4 && tcp.dst == 22' allow-related
ovn-nbctl acl-add pg-web to-lport 900 \
  'outport == @pg-web && ip4' drop
ovn-nbctl acl-add pg-web from-lport 1000 \
  'inport == @pg-web && ip4' allow-related
```

**Verify:**
```bash
ovn-nbctl acl-list pg-web
```
**Expected output:**
```
from-lport  1000 (inport == @pg-web && ip4) allow-related
to-lport    1010 (outport == @pg-web && ip4.src == $pg-admin_ip4 && tcp.dst == 22) allow-related
to-lport    1000 (outport == @pg-web && ip4 && tcp.dst == 80) allow-related
to-lport     900 (outport == @pg-web && ip4) drop
```

Start test listeners on `ns-a`:
```bash
sudo ip netns exec ns-a ncat -lk -p 80 >/dev/null &
sudo ip netns exec ns-a ncat -lk -p 22 >/dev/null &
```
```bash
sudo ip netns exec ns-b ncat -zv -w 2 10.0.1.10 22
sudo ip netns exec ns-c ncat -zv -w 2 10.0.1.10 22
sudo ip netns exec ns-c ncat -zv -w 2 10.0.1.10 80
sudo ip netns exec ns-c ncat -zv -w 2 10.0.1.10 443
```
**Expected output:**
```
Ncat: Connected to 10.0.1.10:22.
Ncat: 0 bytes sent, 0 bytes received in 0.02 seconds.
Ncat: Connection timed out.
Ncat: Connected to 10.0.1.10:80.
Ncat: 0 bytes sent, 0 bytes received in 0.01 seconds.
Ncat: Connection timed out.
```

> `to-lport` is traffic arriving at the VM (`outport == @pg-web`).
> `from-lport` is traffic leaving the VM (`inport == @pg-web`). Once ACLs exist,
> unmatched IP traffic is denied, mirroring a security group's implicit deny.

---

## Exercise 6 — Statefulness and remote-group rules

### Part 1 — Prove the ACL is stateful



Add the DB-side rule needed for web-to-DB Postgres. There is no explicit inbound
rule for return packets back to the web client.
```bash
ovn-nbctl acl-add pg-db to-lport 1000 \
  'outport == @pg-db && ip4.src == $pg-web_ip4 && tcp.dst == 5432' allow-related
ovn-nbctl acl-add pg-db to-lport 900 'outport == @pg-db && ip4' drop
sudo ip netns exec ns-c ncat -lk -p 5432 >/dev/null &
sudo ip netns exec ns-a ncat -zv -w 2 10.0.2.10 5432
```
**Expected output:**
```
Ncat: Connected to 10.0.2.10:5432.
Ncat: 0 bytes sent, 0 bytes received in 0.02 seconds.
```

**Verify:**
```bash
sudo ovs-ofctl dump-flows br-int | grep -i ct | head -12
```
**Expected output:**
```
 cookie=0x..., table=8, priority=65535,ct_state=-trk,ip actions=ct(table=9,zone=NXM_NX_REG13[0..15])
 cookie=0x..., table=9, priority=65535,ct_state=+inv+trk,ip actions=drop
 cookie=0x..., table=9, priority=65535,ct_state=+est+rpl+trk,ip actions=resubmit(,10)
 cookie=0x..., table=9, priority=65535,ct_state=+rel+rpl+trk,ip actions=resubmit(,10)
 cookie=0x..., table=10, priority=2002,tcp,tp_dst=5432 actions=ct(commit,zone=NXM_NX_REG13[0..15]),resubmit(,11)
```
```bash
sudo conntrack -L | grep 10.0.1.10 | grep 5432
```
**Expected output:**
```
tcp 6 431999 ESTABLISHED src=10.0.1.10 dst=10.0.2.10 sport=49832 dport=5432 src=10.0.2.10 dst=10.0.1.10 sport=5432 dport=49832 [ASSURED] mark=0 use=1
```

Temporarily make web egress stateless and retry:
```bash
ovn-nbctl -- --id=@acl find ACL direction=from-lport \
  match='inport == @pg-web && ip4' -- set ACL @acl action=allow
sudo conntrack -D -s 10.0.1.10 2>/dev/null || true
sudo ip netns exec ns-a ncat -zv -w 2 10.0.2.10 5432
```
**Expected output:**
```
Ncat: Connection timed out.
```

Restore it:
```bash
ovn-nbctl -- --id=@acl find ACL direction=from-lport \
  match='inport == @pg-web && ip4' -- set ACL @acl action=allow-related
```

> **`ct_state` answer:** first packets are `+new+trk` and are committed by the
> matching `allow-related` ACL. Replies match `+est+rpl+trk`; related traffic
> matches `+rel+rpl+trk`; invalid packets (`+inv+trk`) are dropped.

> **Why `allow-related` by default?** OpenStack security groups are stateful, so
> users write one rule and expect replies to work. Choose `allow-stateless` only
> when you deliberately want to bypass conntrack, usually for trusted high-rate
> traffic that does not need state.

### Part 2 — A remote group rule with an Address Set



Confirm the DB ACL references the web group address set:
```bash
ovn-nbctl acl-list pg-db
ovn-nbctl get Address_Set pg-web_ip4 addresses
```
**Expected output:**
```
to-lport  1000 (outport == @pg-db && ip4.src == $pg-web_ip4 && tcp.dst == 5432) allow-related
to-lport   900 (outport == @pg-db && ip4) drop
["10.0.1.10"]
```

Add the dynamic Lab 6 port as another web member:
```bash
ovn-nbctl pg-add pg-web ls1-port-dyn
ovn-nbctl get Address_Set pg-web_ip4 addresses
sudo ip netns exec ns-d ncat -zv -w 2 10.0.2.10 5432
```
**Expected output:**
```
["10.0.1.10", "10.0.1.101"]
Ncat: Connected to 10.0.2.10:5432.
Ncat: 0 bytes sent, 0 bytes received in 0.02 seconds.
```

> The ACL did not change. The port group changed, OVN updated `pg-web_ip4`, and
> the remote-group rule matched the new member. OpenStack equivalent:
> `openstack security group rule create --ingress --protocol tcp --dst-port 5432 --remote-group web db`.

---

## Exercise 7 — `drop` vs `reject`, and tie it back to OpenStack

### Step 1 — `drop` vs `reject`



Observe silent drop, then replace it with reject:
```bash
sudo ip netns exec ns-c ncat -zv -w 3 10.0.1.10 443
ovn-nbctl -- --id=@acl find ACL direction=to-lport \
  match='outport == @pg-web && ip4' -- set ACL @acl action=reject
sudo ip netns exec ns-c ncat -zv -w 3 10.0.1.10 443
```
**Expected output:**
```
Ncat: Connection timed out.
Ncat: Connection refused.
```

Restore drop:
```bash
ovn-nbctl -- --id=@acl find ACL direction=to-lport \
  match='outport == @pg-web && ip4' -- set ACL @acl action=drop
```

> `drop` silently discards and clients wait. `reject` sends TCP RST or ICMP
> unreachable and clients fail immediately. Security groups usually prefer drop
> at the perimeter because it reveals less and avoids response traffic.

### Step 2 — See it compile, and tie back to OpenStack



Inspect northbound ACLs:
```bash
ovn-nbctl list acl
```
**Expected output:**
```
_uuid     : 3d2f0f8e-9a21-4d7e-b41d-c7241bceab9d
action    : allow-related
direction : to-lport
match     : "outport == @pg-web && ip4.src == $pg-admin_ip4 && tcp.dst == 22"
priority  : 1010
_uuid     : 9f9a861c-8f4b-4fb4-baa3-a81ed2b6f483
action    : allow-related
direction : to-lport
match     : "outport == @pg-web && ip4 && tcp.dst == 80"
priority  : 1000
_uuid     : b11c7e54-8918-4fb6-b422-31d0c5366243
action    : allow-related
direction : from-lport
match     : "inport == @pg-web && ip4"
priority  : 1000
_uuid     : d35855c8-3b8d-424a-bf8d-c3a8777015fb
action    : allow-related
direction : to-lport
match     : "outport == @pg-db && ip4.src == $pg-web_ip4 && tcp.dst == 5432"
priority  : 1000
```
```bash
ovn-sbctl lflow-list | grep -iE 'acl|ct' | head -20
sudo ovs-ofctl dump-flows br-int | grep -i ct | head -10
```
**Expected output:**
```
  table=8 (ls_in_acl), priority=65535, match=(ct.inv), action=(drop;)
  table=8 (ls_in_acl), priority=65535, match=(ct.est && !ct.rel && !ct.new && !ct.inv), action=(next;)
  table=8 (ls_in_acl), priority=2002, match=(inport == @pg-web && ip4), action=(reg0[1] = 1; next;)
  table=8 (ls_in_acl), priority=1, match=(ip), action=(drop;)
  table=6 (ls_out_acl), priority=2002, match=(outport == @pg-web && ip4 && tcp.dst == 80), action=(reg0[1] = 1; next;)
 cookie=0x..., table=8, priority=65535,ct_state=-trk,ip actions=ct(table=9,zone=NXM_NX_REG13[0..15])
 cookie=0x..., table=9, priority=65535,ct_state=+inv+trk,ip actions=drop
 cookie=0x..., table=9, priority=65535,ct_state=+est+rpl+trk,ip actions=resubmit(,10)
 cookie=0x..., table=10, priority=2002,tcp actions=ct(commit,zone=NXM_NX_REG13[0..15]),resubmit(,11)
```

> `allow` is a stateless permit. `allow-related` sends packets through `ct()`,
> commits allowed new flows with `ct(commit,...)`, and permits established or
> related replies. `allow-stateless` explicitly bypasses conntrack.

OpenStack equivalents:
```bash
openstack security group create web
openstack security group create db
openstack security group create admin
openstack port set --security-group web <web-port>
openstack port set --security-group db <db-port>
openstack port set --security-group admin <admin-port>
openstack security group rule create --ingress --protocol tcp --dst-port 80 web
openstack security group rule create --ingress --protocol tcp --dst-port 22 --remote-group admin web
openstack security group rule create --egress --ethertype IPv4 web
openstack security group rule create --ingress --protocol tcp --dst-port 5432 --remote-group web db
```

| OpenStack flag | OVN field |
|---|---|
| target SG `web` | Port_Group `pg_<web_sg_uuid>` |
| `--ingress` / `--egress` | `to-lport` + `outport` / `from-lport` + `inport` |
| `--protocol tcp --dst-port 22` | `tcp && tcp.dst == 22` |
| `--remote-group admin` | `ip4.src == $pg_<admin_uuid>_ip4` |
| stateful rule / implicit deny | `allow-related` / default drop (`neutron_pg_drop`) |

> Exact mapping for
> `openstack security group rule create --ingress --protocol tcp --dst-port 22 --remote-group admins web`:
> ACL on `pg_<web_uuid>`, direction `to-lport`, match
> `outport == @pg_<web_uuid> && ip4.src == $pg_<admins_uuid>_ip4 && tcp && tcp.dst == 22`,
> action `allow-related`.

---

# Optional Stretch Goals

---

## Stretch 1 — Add DHCPv6



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

## Stretch 2 — Tie it together: a "zero-touch" port



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
