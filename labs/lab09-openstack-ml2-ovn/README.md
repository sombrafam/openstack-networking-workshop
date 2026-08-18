
# Lab 9 — The OpenStack Layer: Neutron ML2/OVN (Capstone)

| | |
|---|---|
| **Tier** | 3 – OVN |
| **Duration** | ~45 minutes |
| **Prerequisites** | Labs 1–8 completed |
| **Builds on** | Lab 8 — Multi-Chassis OVN |

---

## 1. Objective

Across Labs 5–8 you built, **by hand**, the entire OVN topology a cloud needs:
logical switches, routers, DHCP, DNS, metadata, security groups, a multi-chassis
Geneve overlay, distributed routing, an HA gateway, and floating IPs. Every one
of those was an `ovn-nbctl` command *you* typed.

This final lab reveals the punchline: **OpenStack Neutron types those exact same
commands for you.** You will stand up a real OpenStack control plane with the
**ML2/OVN** mechanism driver, drive it with the `openstack` CLI, and then look
at the OVN Northbound DB to find the **same logical resources you built by
hand** — created automatically.

By the end of this lab you will be able to:

- Explain the **Neutron ML2/OVN** control-plane stack end to end:
  `openstack` CLI → Neutron API → ML2 plugin → OVN mechanism driver →
  OVN NB DB → `ovn-northd` → OVN SB DB → `ovn-controller` → OVS.
- Stand up an all-in-one OpenStack (DevStack or MicroStack) using OVN.
- Create networks, subnets, routers, ports, security groups, and floating IPs
  with the **`openstack` CLI**, then **diff** the result against your hand-built
  OVN from Labs 5–8.
- Distinguish **provider** networks from **tenant (self-service)** networks and
  see how each maps to OVN (`localnet` vs. Geneve).
- Trace the **full lifecycle of a Neutron port** from API call to OVS flow.
- Confidently read a production `ovn-nbctl show` / `ovn-sbctl show` and know
  what Neutron action produced each row.

---

## 2. Background & Concepts

### 2.1 The control-plane stack

Everything you did manually sits **below** Neutron. Here is the whole stack,
with the layer you've owned until now highlighted:

```
   openstack network create ...            ← user / Horizon / Heat
        │  REST
        ▼
   ┌─────────────────────────────┐
   │ Neutron Server (API)        │         ← validation, quotas, IPAM
   │   └─ ML2 plugin             │
   │        └─ OVN mech driver   │         ← translates intent to OVN
   └─────────────┬───────────────┘
                 │  ovsdb (OVSDB protocol)
                 ▼
   ┌─────────────────────────────┐
   │ OVN Northbound DB           │  ◄────── *** everything you did in
   │  (logical_switch, router,   │           Labs 5–8 lives here ***
   │   acl, dhcp_options, nat...) │
   └─────────────┬───────────────┘
                 ▼  ovn-northd
   ┌─────────────────────────────┐
   │ OVN Southbound DB           │         ← logical flows + bindings
   └─────────────┬───────────────┘
                 ▼  ovn-controller (per chassis)
   ┌─────────────────────────────┐
   │ OVS br-int (OpenFlow)       │         ← the data path (Labs 3–4)
   └─────────────────────────────┘
```

The **ML2/OVN mechanism driver** is the only new piece. Its entire job is to
turn Neutron API objects into rows in the OVN **Northbound** DB — i.e., to run
the `ovn-nbctl`-equivalent operations you've been running yourself.

### 2.2 The object mapping you already know

Because you built the OVN side by hand, this table should now read like a
glossary of things you've *done*, not things you need to learn:

| Neutron object | OVN NB object | You built it in |
|----------------|---------------|-----------------|
| `network` (tenant) | `Logical_Switch` (Geneve) | Lab 5 |
| `network` (provider) | `Logical_Switch` + `localnet` port | Lab 5 §9 |
| `subnet` (with DHCP) | `DHCP_Options` + dynamic addrs | Lab 6 |
| `port` | `Logical_Switch_Port` | Lab 5 |
| internal DNS | `DNS` records | Lab 6 |
| metadata | `localport` + `ovn-metadata-agent` | Lab 6 |
| `router` | `Logical_Router` | Lab 5 |
| router interface | `Logical_Router_Port` | Lab 5 |
| external gateway / SNAT | `lr` NAT `snat` + `cr-lrp` | Labs 5, 8 |
| `security group` | `Port_Group` | Lab 7 |
| `security group rule` | `ACL` | Lab 7 |
| `floating ip` | `lr` NAT `dnat_and_snat` | Lab 8 |
| DVR / L3 HA | distributed pipeline / gateway chassis group | Lab 8 |

### 2.3 Provider vs. tenant networks

- **Tenant (self-service) network:** isolated per project, carried over the
  **Geneve** overlay between chassis. This is the `ls1`/`ls2` you built.
- **Provider network:** maps directly onto a **physical** L2 (flat or VLAN) via
  a **`localnet`** port and `ovn-bridge-mappings`. This is the `br-ex` /
  `ls-ext` plumbing from Lab 5 §9.

Floating IPs and SNAT live on a router that bridges a tenant network to a
provider (external) network — precisely the `lr1` → `ls-ext` setup of Labs 5
and 8.

### 2.4 The lifecycle of a port (the capstone trace)

When Nova boots a VM:

```
 openstack server create ...
   │
   ├─► Neutron: openstack port create  →  ML2/OVN writes Logical_Switch_Port
   │      (addresses, dhcpv4_options, port_security, port-group membership)
   │
   ├─► ovn-northd compiles NB → SB logical flows
   │
   ├─► Nova/libvirt boots the VM, creates a tap, plugs it into br-int
   │      with  external-ids:iface-id=<neutron-port-uuid>
   │
   ├─► ovn-controller sees the iface-id, binds the Port_Binding to this chassis
   │
   ├─► logical flows become OpenFlow rules in br-int
   │
   └─► VM DHCPs (Lab 6), hits metadata (Lab 6), is filtered by its SG (Lab 7),
       routes E/W (Lab 8 DVR), and reaches the world via SNAT/FIP (Labs 5/8)
```

Every arrow after "ML2/OVN writes..." is a mechanism you have already operated
by hand. The `iface-id` binding trick in particular is exactly the
`external-ids:iface-id=<lsp>` you used to bind namespaces in Lab 5.

---

## 3. Starting Point

This lab needs a machine that can run an all-in-one OpenStack with OVN. Either:

- **DevStack** on a fresh Ubuntu 22.04+ VM (4 vCPU / 8 GB+), or
- **MicroStack / OpenStack via snap or Kolla** — any all-in-one that uses
  **ML2/OVN** (the default in current OpenStack).

> Do **not** install this on top of your Lab 5–8 host's hand-built OVN — give
> OpenStack its own VM so its Neutron owns the OVN databases cleanly. You can
> reuse a `virt-tools/kvm/spawn-vm.sh` VM from Lab 8 for this.

---

## 4. Exercises

### Exercise 1 — Deploy OpenStack with ML2/OVN

Deploy DevStack with OVN. A minimal `local.conf`:

```ini
[[local|localrc]]
ADMIN_PASSWORD=secret
DATABASE_PASSWORD=$ADMIN_PASSWORD
RABBIT_PASSWORD=$ADMIN_PASSWORD
SERVICE_PASSWORD=$ADMIN_PASSWORD
# OVN is the default ML2 mechanism in modern DevStack; make it explicit:
Q_AGENT=ovn
Q_ML2_PLUGIN_MECHANISM_DRIVERS=ovn
Q_ML2_TENANT_NETWORK_TYPE=geneve
enable_service ovn-northd ovn-controller q-ovn-metadata-agent
```

```bash
./stack.sh        # ~20–40 min
source openrc admin admin
```

**Verify:**
- `openstack network agent list` shows OVN agents (controller + metadata).
- `ovn-nbctl show` runs and is **non-empty** (DevStack created a public/private
  network during stacking).
- `openstack extension list --network | grep -i ovn` confirms the driver.

### Exercise 2 — Create a tenant network and diff against OVN

```bash
openstack network create demo-net
openstack subnet create demo-sub --network demo-net \
  --subnet-range 10.0.1.0/24 --gateway 10.0.1.1 --dns-nameserver 8.8.8.8
```

Now look at what Neutron wrote into OVN:

```bash
ovn-nbctl show
ovn-nbctl list Logical_Switch
ovn-nbctl list DHCP_Options
```

**Verify & compare:**
- A new `Logical_Switch` (named `neutron-<network-uuid>`) appeared — the same
  object you created with `ovn-nbctl ls-add ls1` in Lab 5.
- A `DHCP_Options` row appeared with `router`, `server_id`, `dns_server`,
  `mtu` — the same row you hand-built in Lab 6.
- **Map every field**: which `openstack subnet create` flag produced which
  `DHCP_Options` option?

### Exercise 3 — Ports, security groups, and the auto-created Port Groups

```bash
openstack security group create web
openstack security group rule create --ingress --protocol tcp \
  --dst-port 80 web
openstack port create --network demo-net --security-group web web-port
```

```bash
ovn-nbctl list Port_Group
ovn-nbctl list ACL
ovn-nbctl list Logical_Switch_Port
```

**Verify & compare:**
- Neutron created a **`Port_Group`** named `pg_<sg-uuid>` (plus the default
  `neutron_pg_drop`) — exactly the construct from Lab 7.
- Your `--dst-port 80` rule became an **`ACL`** with `allow-related` and a
  `outport == @pg_... && tcp.dst == 80`-style match — identical to what you
  wrote by hand in Lab 7.
- The port carries `dhcpv4_options` and `port_security` — Labs 6 & 7.

### Exercise 4 — Router, external network, and floating IP

```bash
openstack router create r1
openstack router add subnet r1 demo-sub
openstack router set r1 --external-gateway public
openstack floating ip create public
# associate it to web-port
openstack floating ip set --port web-port <FIP>
```

```bash
ovn-nbctl list Logical_Router
ovn-nbctl lr-nat-list neutron-<router-uuid>
ovn-sbctl show          # find the cr-lrp gateway port
```

**Verify & compare:**
- A `Logical_Router` with router ports appeared — Lab 5.
- `--external-gateway` produced an **`snat`** NAT rule and a **`cr-lrp`**
  gateway port — Labs 5 & 8.
- The floating IP produced a **`dnat_and_snat`** rule — Lab 8. Check whether
  it's the **distributed** variant (has a logical port + MAC) — that tells you
  if this cloud runs DVR FIPs.

### Exercise 5 — Provider network = `localnet`

```bash
openstack network create --provider-network-type flat \
  --provider-physical-network physnet1 --external provnet
ovn-nbctl show     # find the new switch's localnet port
```

**Verify & compare:**
- The provider network's `Logical_Switch` has a **`localnet`** port mapped to
  `physnet1` — exactly the `ls-ext` + `ovn-bridge-mappings` you built in
  Lab 5 §9.
- Contrast with `demo-net`, which uses **Geneve** (no localnet).

### Exercise 6 — Boot a VM and trace the full port lifecycle

```bash
openstack server create --flavor m1.tiny --image cirros \
  --network demo-net --security-group web vm1
```

Watch the lifecycle from §2.4 actually happen:

```bash
# the Neutron port → OVN logical port:
openstack port list --server vm1
ovn-sbctl find Port_Binding logical_port=<port-uuid>   # bound to which chassis?
# the OVS side binding Nova created:
ovs-vsctl --columns=name,external_ids find interface \
  external_ids:iface-id=<port-uuid>
ovs-ofctl dump-flows br-int | grep <of-port>
```

**Verify & compare:**
- The `Port_Binding` is bound to the compute chassis — the same binding you did
  manually with `external-ids:iface-id=<lsp>` in Lab 5.
- The VM gets its IP via OVN DHCP (Lab 6), reaches `169.254.169.254` metadata
  (Lab 6), is filtered by `web` (Lab 7), and reaches the FIP (Lab 8).
- Run `ovn-trace` and `ovs-appctl ofproto/trace` on a real VM packet — the same
  tools, now on a Neutron-managed port.

### Exercise 7 — Capstone synthesis

Produce a one-page diff: for **each** `openstack` command you ran in this lab,
write the **equivalent `ovn-nbctl` command from Labs 5–8** that it replaced.

**Verify:**
- You can take any line of `ovn-nbctl show` from a production cloud and state
  which Neutron API object created it — and vice versa. That is the complete
  mental model this workshop set out to build.

---

## 5. Key Commands Reference

| Command | Description |
|---------|-------------|
| `openstack network create <name>` | Tenant (Geneve) network → `Logical_Switch` |
| `openstack network create --provider-network-type flat ...` | Provider net → `localnet` |
| `openstack subnet create ... --dhcp` | Subnet → `DHCP_Options` |
| `openstack port create --security-group ...` | Port → `Logical_Switch_Port` + Port_Group |
| `openstack security group rule create ...` | SG rule → `ACL` |
| `openstack router create / add subnet / set --external-gateway` | `Logical_Router` + `snat` + `cr-lrp` |
| `openstack floating ip create / set` | `dnat_and_snat` NAT |
| `ovn-nbctl show` / `list <table>` | See what Neutron wrote into OVN |
| `ovn-sbctl find Port_Binding logical_port=<uuid>` | Which chassis a port is bound to |
| `openstack network agent list` | Confirm OVN controller/metadata agents |

---

## 6. Review Questions

1. Name every layer a `openstack network create` call passes through before a
   packet can flow, from REST to OpenFlow.
2. What is the *only* job of the ML2/OVN mechanism driver?
3. Given a line of `ovn-nbctl show` output (a `Logical_Switch`, an `ACL`, a
   `nat`), state the `openstack` command that produced it.
4. How does a provider network differ from a tenant network in both Neutron and
   OVN terms?
5. Walk through the full lifecycle of a Neutron port from `port create` to a
   bound `Port_Binding` and OVS flow. Where does the `iface-id` binding happen?
6. The workshop claimed you'd build "by hand the same topology OpenStack creates
   automatically." Defend or refute that claim using concrete evidence from this
   lab's diffs.

---

## 7. The Difference: Basic OVN vs. Full OpenStack/OVN

You set out to understand exactly what separates the **basic OVN scenario**
(Lab 5) from a **full OpenStack/OVN network**. Here is the complete answer you
built across Labs 6–9:

| Capability | Basic OVN (Lab 5) | Full OpenStack/OVN | Added in |
|------------|-------------------|--------------------|----------|
| Addressing | hardcoded MAC/IP both sides | OVN-native DHCP + IPAM | Lab 6 |
| Name resolution | none | OVN DNS / Neutron internal DNS | Lab 6 |
| Metadata | none | `localport` + metadata agent (cloud-init) | Lab 6 |
| Security | per-switch, stateless ACLs | per-port, stateful, grouped (SGs) | Lab 7 |
| Scale | single chassis | many chassis, Geneve overlay | Lab 8 |
| Routing | local-only, "DVR" in name only | true distributed routing (DVR) | Lab 8 |
| Gateway | single pinned chassis | HA chassis group + BFD failover | Lab 8 |
| Floating IPs | one manual SNAT | `dnat_and_snat`, distributed FIPs | Lab 8 |
| Control plane | you type `ovn-nbctl` | Neutron ML2/OVN types it for you | Lab 9 |
| Provider networks | one `localnet` by hand | flat/VLAN provider nets via Neutron | Lab 9 |

The data plane is **identical** — the same OVN logical flows, the same OVS
OpenFlow rules. What "full OpenStack" adds is the **automation, services, scale,
HA, and multi-tenancy** layered on top. You now understand the whole stack from
the kernel TAP device of Lab 1 to the Neutron API of Lab 9.

---

## 8. What's Next — Going Further

- [ ] **OVN load balancing** (`ovn-nbctl lb-add`) → Octavia's OVN provider.
- [ ] **OVN database HA**: RAFT-clustered NB/SB across 3 nodes.
- [ ] **SR-IOV / hardware offload** and **OVS-DPDK** for high-performance
      data-plane (SPEC §8).
- [ ] **BGP** advertisement of provider/FIP networks (OVN-BGP-agent).
- [ ] **IPv6** end to end: SLAAC vs. DHCPv6, OVN ND, IPv6 SGs (SPEC §5.8).
- [ ] Deploy a multi-node OpenStack and re-run every diff from this lab at
      scale.

---

In **Lab 10** you'll apply everything to real incidents and operational tasks
drawn from the team's day-to-day production work.

---

*Lab 9 of 10 — OpenStack Networking Workshop*
