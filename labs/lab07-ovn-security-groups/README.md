
# Lab 7 — Real Security Groups: Port Groups, Address Sets & Stateful ACLs

| | |
|---|---|
| **Tier** | 3 – OVN |
| **Duration** | ~45 minutes |
| **Prerequisites** | Labs 1–6 completed; Lab 6 topology still up |
| **Builds on** | Lab 6 — OVN Native Services |

---

## 1. Objective

In Lab 5 you added ACLs — but the way you did it is **not** how OpenStack
security groups actually work. Lab 5's ACLs were:

- attached to a whole **logical switch** (so they hit *every* port on it), and
- **stateless** (you had to reason about return traffic yourself), and
- written against **literal IP matches** that you'd have to edit by hand every
  time a member joined or left.

A real OpenStack security group is **per-port**, **stateful** (connection
tracking lets replies back automatically), and defined against **named groups**
of members that update dynamically. OVN expresses all three with **Port
Groups**, **Address Sets**, and **stateful ACLs**.

By the end of this lab you will be able to:

- Explain why Lab 5's per-switch, stateless ACLs don't model security groups.
- Create **Port Groups** and attach ACLs to them (per-port enforcement).
- Use **Address Sets** so a rule like "allow from the web tier" updates
  automatically as members come and go.
- Write **stateful** ACLs with `allow-related` / `allow-stateless` and observe
  the **conntrack** (`ct()`) actions OVN compiles into `br-int`.
- Understand ACL **direction** (`from-lport` / `to-lport`), **priority**, and
  the **default-drop** model.
- Map the whole thing, rule for rule, to `openstack security group rule create`.

---

## 2. Background & Concepts

### 2.1 Why Lab 5's ACLs were a toy

In Lab 5 you ran:

```bash
ovn-nbctl acl-add ls1 from-lport 1000 'ip4' drop
ovn-nbctl acl-add ls1 from-lport 1100 'ip4 && tcp && tcp.dst==22' allow-related
```

Two problems:

1. **Scope is the whole switch.** Every port on `ls1` gets the same rules. But
   in OpenStack, two VMs on the *same network* routinely belong to *different*
   security groups (a web server and a database, say). Per-switch ACLs can't
   express that.
2. **Literal matches don't scale.** "Allow SSH from the bastion" means editing
   the rule every time the bastion's IP changes or a second bastion appears.

OVN fixes both with Port Groups and Address Sets.

### 2.2 Port Groups = a security group's *members*

A **Port Group** is a named set of logical switch ports. ACLs attached to the
port group apply **only to those ports**, regardless of which switch they live
on:

```
  Port_Group "pg-web"   → { ls1-port1, ls2-port3 }
      │
      │  ACLs attached HERE apply only to pg-web's members
      ▼
  outport == @pg-web && tcp.dst == 80   →  allow-related
```

This is a near-exact model of a Neutron security group: a group has *members*
(ports), and the group's *rules* are enforced on each member. Adding a VM to a
security group is just adding its port to the port group.

OVN also gives every port group two **auto-maintained address sets**:

| Auto address set | Contains |
|------------------|----------|
| `@pg-web` (the port group name, in `outport`/`inport` matches) | the member **ports** |
| `$pg-web_ip4` / `$pg-web_ip6` | the member **IP addresses** |

So a rule can say "allow from any IP that belongs to the web tier" with
`ip4.src == $pg-web_ip4` — and it updates itself as members change.

### 2.3 Address Sets = a security group used as a *remote*

An **Address Set** is a named, mutable set of IP addresses:

```bash
ovn-nbctl create Address_Set name=admins addresses='10.0.1.10,10.0.2.10'
```

referenced in a match as `$admins`. When a Neutron rule says
"allow TCP 22 **from security group `admins`**" (a remote *group* rather than a
remote *CIDR*), ML2/OVN renders it as `ip4.src == $admins` — and keeps the set
in sync as admin VMs are created or deleted. No rule rewriting.

### 2.4 Stateful ACLs and conntrack

Lab 5's ACLs were effectively stateless: to let a reply back you needed a
second rule. OVN's `allow-related` makes an ACL **stateful** by sending the
packet through the kernel **connection tracker** (`conntrack`):

```
  new connection  ──► ct(commit)   ── remembers the 5-tuple
  reply packet    ──► ct() match "est/rel"  ── allowed automatically
```

In `br-int` you'll see `ct(...)`, `ct_state`, and `ct_commit` actions — this is
**the same conntrack** Linux iptables uses, but driven by OVS flows instead of
`iptables` rules. (This is the one place the SPEC's "no iptables" rule is
subtle: there are *no iptables rules*, but the *conntrack subsystem* is shared
and very much in play.)

ACL action cheat-sheet:

| Action | Meaning |
|--------|---------|
| `drop` | silently discard |
| `reject` | discard + send TCP RST / ICMP unreachable |
| `allow` | permit, **stateless** (no conntrack) |
| `allow-related` | permit + track; replies/related flows auto-allowed |
| `allow-stateless` | permit, explicitly bypass conntrack (perf) |

### 2.5 Direction, priority, and default-drop

- **`from-lport`** = traffic **leaving** the VM (ingress to the switch;
  egress from the VM's view). Matched with `inport`.
- **`to-lport`** = traffic **arriving** at the VM. Matched with `outport`.
- **Priority** 0–32767; highest wins. Neutron uses a fixed banding scheme.
- The moment *any* ACL exists on a port group, OVN applies an implicit
  **default drop** for unmatched IP traffic (the `to-lport` priority-0 drop) —
  exactly like a security group, which denies everything not explicitly
  allowed.

### 2.6 The Neutron mapping

| OVN construct | Neutron / OpenStack |
|---------------|---------------------|
| Port Group | a Security Group (its *members*) |
| ACL on a port group | a Security Group **rule** |
| `$pg-<sg>_ip4` auto address set | the SG used as a *remote group* |
| Address Set | a remote security group / allowed-address pairs |
| `allow-related` + `ct()` | stateful security group semantics |
| default drop | the implicit "deny all" of every SG |
| `from-lport` / `to-lport` | egress / ingress rule direction |

> **How real Neutron renders it:** the ML2/OVN driver creates one Port Group
> per Neutron security group (named `pg_<sg_uuid>`), adds each port to the port
> groups of its security groups, and writes one ACL per SG rule. You're about
> to do that by hand.

---

## 3. Starting Point

Continue from Lab 6. You should have `ls1`/`ls2`, `lr1`, namespaces `ns-a`..
`ns-d` (now coming up via DHCP), DNS, and metadata working.

**Important:** remove the Lab 5 per-switch ACLs first so we start from a clean
slate and rebuild security the *right* way:

```bash
ovn-nbctl acl-del ls1     # drop the Lab 5 switch-level ACLs
ovn-nbctl acl-list ls1    # should be empty
```

If your topology was torn down, `lab06-solution.md` (in this folder) rebuilds
everything through Lab 6.

---

## 4. Exercises

All commands require **root** or **sudo** privileges.

### Exercise 1 — Model two tiers with Port Groups

You'll treat `ns-a` (`ls1-port1`) as a **web** server and `ns-c`
(`ls2-port3`) as a **database** server — on *different* switches, the case
per-switch ACLs cannot handle.

```bash
ovn-nbctl pg-add pg-web  ls1-port1
ovn-nbctl pg-add pg-db   ls2-port3
ovn-nbctl pg-add pg-admin ls1-port2     # ns-b acts as the admin/bastion host
```

**Verify:**
- `ovn-nbctl list port_group` shows three groups with the right ports.
- Note the auto-created address sets: `ovn-nbctl list address_set` shows
  `pg-web_ip4` etc. populated from the ports' configured IPs.

### Exercise 2 — Default-deny, then allow only what's needed (web tier)

Attach stateful ACLs to `pg-web`:

```bash
# Ingress: allow HTTP from anywhere, SSH only from the admin group, drop rest.
ovn-nbctl acl-add pg-web to-lport 1000 \
  'outport == @pg-web && ip4 && tcp.dst == 80' allow-related
ovn-nbctl acl-add pg-web to-lport 1010 \
  'outport == @pg-web && ip4.src == $pg-admin_ip4 && tcp.dst == 22' allow-related
ovn-nbctl acl-add pg-web to-lport 900 \
  'outport == @pg-web && ip4' drop
# Egress: let the web tier start any outbound connection (default-allow egress,
# like a default Neutron SG).
ovn-nbctl acl-add pg-web from-lport 1000 \
  'inport == @pg-web && ip4' allow-related
```

**Verify:**
- From `ns-b` (admin): `ssh`/port-22 probe to `ns-a` → **allowed**.
- From `ns-c` (db): port-22 probe to `ns-a` → **blocked** (not in `pg-admin`).
- From anywhere: HTTP/port-80 to `ns-a` → **allowed**.
- From anywhere: port-443 to `ns-a` → **blocked** (default drop).

> Test ports without real servers using `ncat`:
> `ip netns exec ns-a ncat -l 80 &` then
> `ip netns exec ns-b ncat -zv 10.0.1.10 80`.

### Exercise 3 — Prove the ACL is *stateful*

1. Allow the web tier to *initiate* outbound (done in Ex. 2 egress rule), but
   add **no** explicit inbound rule for the return traffic.
2. From `ns-a`, open a connection outbound (e.g. to `ns-c`'s DB port — add a
   `pg-db` rule allowing `5432` from `$pg-web_ip4` first).
3. Confirm the **replies** flow back even though no inbound rule names them.

**Verify:**
- `ovs-ofctl dump-flows br-int | grep -i ct` shows `ct(commit...)` and
  `ct_state` matches.
- `conntrack -L | grep 10.0.1.10` shows the tracked connection.
- Change the web egress rule from `allow-related` to `allow` (stateless) and
  watch the return traffic now require its own explicit rule — demonstrating
  exactly what conntrack buys you.

**Questions:**
- Which `ct_state` flags (`new`, `est`, `rel`, `inv`) gate the return packets?
- Why is `allow-related` the OpenStack default, and when would you ever pick
  `allow-stateless`?

### Exercise 4 — A remote *group* rule with an Address Set

Model the Neutron rule "allow Postgres to the DB tier **from the web security
group**" using the auto-maintained web address set:

```bash
ovn-nbctl acl-add pg-db to-lport 1000 \
  'outport == @pg-db && ip4.src == $pg-web_ip4 && tcp.dst == 5432' allow-related
ovn-nbctl acl-add pg-db to-lport 900 'outport == @pg-db && ip4' drop
```

Now **add a second web server** and watch the DB rule cover it with no edit:

```bash
ovn-nbctl pg-add pg-web ls1-port-dyn      # the dynamic port from Lab 6
ovn-nbctl get Address_Set pg-web_ip4 addresses
```

**Verify:**
- The new web IP appears in `$pg-web_ip4` automatically.
- The new web port can reach the DB on 5432 **without** adding any ACL — the
  rule referenced the group, not an IP. This is the whole point of remote
  security groups.

### Exercise 5 — `drop` vs `reject`

Change the default web-tier deny from `drop` to `reject` and observe the
client-side difference (connection refused / RST vs. timeout).

**Verify:**
- With `drop`: `ncat -zv` hangs then times out.
- With `reject`: `ncat -zv` returns "Connection refused" immediately.
- Relate to Neutron: which behavior do default security groups give, and why is
  `drop` usually preferred at the perimeter?

### Exercise 6 — See it compile, and tie back to OpenStack

```bash
ovn-nbctl list acl
ovn-sbctl lflow-list | grep -iE 'acl|ct'
ovs-ofctl dump-flows br-int | grep -i ct
```

Fill in the mapping for everything you just built:

| What you did | `openstack` equivalent |
|---|---|
| `ovn-nbctl pg-add pg-web ...` | `openstack security group create web` (+ add ports) |
| `acl-add pg-web to-lport ... tcp.dst==80 allow-related` | `openstack security group rule create --ingress --protocol tcp --dst-port 80 web` |
| `ip4.src == $pg-admin_ip4` | `... --remote-group admin` |
| default `drop` ACL | the implicit deny-all of a security group |
| `from-lport` allow | an **egress** SG rule |

**Verify:**
- You can articulate, for any `openstack security group rule create` flag,
  which OVN ACL field it becomes.

---

## 5. Key Commands Reference

| Command | Description |
|---------|-------------|
| `ovn-nbctl pg-add <pg> [ports...]` | Create a port group (security group members) |
| `ovn-nbctl pg-set-ports <pg> <ports...>` | Replace a port group's members |
| `ovn-nbctl acl-add <pg> <dir> <prio> '<match>' <action>` | Add an ACL to a port group |
| `ovn-nbctl acl-del <pg>` | Remove ACLs from a port group/switch |
| `ovn-nbctl acl-list <pg>` | List ACLs |
| `ovn-nbctl create Address_Set name=<n> addresses='<ips>'` | Create an address set |
| `ovn-nbctl list address_set` | Inspect address sets (incl. auto `pg-*_ip4`) |
| `@<pg>` in a match | the port group's member ports |
| `$<pg>_ip4` / `$<set>` in a match | member IPs / address-set IPs |
| `allow-related` | stateful allow (conntrack) |
| `conntrack -L` | view tracked connections |

---

## 6. Review Questions

1. Why can't Lab 5's per-switch ACLs represent two VMs on the same network in
   different security groups? How do port groups solve it?
2. What are the two address sets OVN auto-creates for a port group, and when do
   you use `@pg` vs `$pg_ip4`?
3. Explain the difference between `allow`, `allow-related`, and
   `allow-stateless`. Which `ct()` actions does each produce?
4. How does a "remote group" security-group rule stay correct as members are
   added or deleted, without rewriting the rule?
5. What is the implicit default action once an ACL exists, and how does it
   mirror an OpenStack security group?
6. Map `openstack security group rule create --ingress --protocol tcp
   --dst-port 22 --remote-group admins web` to the exact OVN port group, ACL
   direction, match, and action.

---

## 7. What's Next

Your network now has real addressing (Lab 6) and real, stateful, group-based
security (Lab 7) — but it all still runs on **one chassis**. Lab 5's "Geneve
tunnel" never actually carried a packet, the router gateway was pinned to the
only host you had, and "DVR" was just a word.

In **Lab 8** you'll add a **second chassis** (a KVM VM via the `virt-tools`
submodule), watch OVN build a **real Geneve overlay** between hosts, see
**distributed east/west routing** happen locally on each chassis, make the
external gateway **highly available** with an HA chassis group, and hand out
**floating IPs** with `dnat_and_snat`.

---

*Lab 7 of 9 — OpenStack Networking Workshop*
