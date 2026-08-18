# Lab 7 — Solution: Real Security Groups — Port Groups, Address Sets & Stateful ACLs

> **This file is released with Lab 8.** It contains the full commands and expected output for Lab 7's exercises.

---

## Prerequisites — Clean Lab 5 ACLs

Lab 7 starts from the Lab 6 topology. Remove the old Lab 5 switch ACLs first:
```bash
ovn-nbctl acl-del ls1
ovn-nbctl acl-list ls1
```

**Expected output:** empty.

> Lab 5 used switch-scoped ACLs. Security groups need per-port scope, dynamic
> remote groups, and stateful return traffic.

---

## Exercise 1 — Model two tiers with Port Groups

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

---

## Exercise 2 — Default-deny, then allow only what's needed (web tier)

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

## Exercise 3 — Prove the ACL is stateful

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

---

## Exercise 4 — A remote group rule with an Address Set

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

## Exercise 5 — `drop` vs `reject`

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

---

## Exercise 6 — See it compile, and tie back to OpenStack

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

*Lab 7 Solution — OpenStack Networking Workshop*
