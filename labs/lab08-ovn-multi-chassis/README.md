
# Lab 8 — Multi-Chassis OVN: Geneve Tunnels, DVR, Gateway HA & Floating IPs

| | |
|---|---|
| **Tier** | 3 – OVN |
| **Duration** | ~45 minutes |
| **Prerequisites** | Labs 1–7 completed; KVM/libvirt available (`virt-tools/`) |
| **Builds on** | Lab 7 — Multi-node OVN |

---

## 1. Objective

Everything so far ran on **one host**. That hid the single most important
property of a cloud network: it is **distributed across many hypervisors**. On
one chassis, OVN's Geneve tunnels never carried a packet, "DVR" was just a word,
and the external gateway was trivially pinned to the only host you had.

In this lab you add a **second chassis** and watch OVN behave like a real
deployment: a live **Geneve overlay** between hosts, **distributed east/west
routing** that happens locally on each hypervisor, a **highly-available**
external gateway, and **floating IPs**.

By the end of this lab you will be able to:

- Stand up a **second OVN chassis** (a KVM VM) and join it to the same OVN
  control plane over **TCP** (not the unix socket).
- Observe OVN **auto-create Geneve tunnels** between chassis and identify
  tunnelled traffic on the underlay.
- Prove OVN routing is **distributed** — east/west traffic is routed on the
  *source* chassis, never funneled through a central node.
- Understand **`chassisredirect` (cr-lrp)** ports and why the *gateway* (SNAT /
  N–S) is centralized while east/west routing is not.
- Configure a **gateway HA chassis group** and trigger a **failover**.
- Create **floating IPs** with `dnat_and_snat`, including the **distributed**
  (per-port) variant Neutron uses.
- Map all of it to OpenStack: compute nodes, network nodes, L3 HA, and DVR.

---

## 2. Background & Concepts

### 2.1 A chassis is a hypervisor

A **chassis** is any host running `ovn-controller` and an OVS `br-int`. In
OpenStack terms each compute node and each network/gateway node is a chassis.
Adding a chassis is how a cloud scales out. All chassis share **one** OVN
control plane (NB DB, SB DB, `ovn-northd`); each runs its **own**
`ovn-controller` that renders the *same* logical flows into *local* OVS flows.

```
            ┌──────────────── OVN Central (host1) ─────────────────┐
            │   NB DB    ──►   ovn-northd   ──►   SB DB (TCP 6642) │
            └───────┬───────────────────────────────────┬──────────┘
                    │ ovn-controller                    │ ovn-controller
            ┌───────▼────────┐                  ┌───────▼────────┐
            │ chassis1/host1 │  ◄── Geneve ──►  │ chassis2/VM    │
            │  br-int        │   (udp 6081)     │  br-int        │
            │  ns-a, ns-b    │                  │  ns-e, ns-f    │
            └────────────────┘                  └────────────────┘
```

### 2.2 From unix socket to TCP

In Lab 5 you pointed `ovn-controller` at
`unix:/var/run/ovn/ovnsb_db.sock` — fine for one host. A second chassis must
reach the Southbound DB **over the network**, so OVN central has to listen on
TCP:

```bash
# on host1 (OVN central)
ovn-sbctl set-connection ptcp:6642:0.0.0.0
ovn-nbctl  set-connection ptcp:6641:0.0.0.0
```

and each chassis sets `ovn-remote=tcp:<host1-mgmt-ip>:6642`. (Production uses
**SSL** with certificates; we use plain TCP in the lab.)

### 2.3 Geneve, the real overlay

Each chassis advertises an **encap IP** (its management address):

```bash
ovs-vsctl set open . external-ids:ovn-encap-ip=<this-host-mgmt-ip>
ovs-vsctl set open . external-ids:ovn-encap-type=geneve
```

`ovn-controller` then **automatically** builds a full mesh of Geneve tunnels —
you'll see `ovn-<remote>` ports and a `genev_sys_6081` device appear in
`ovs-vsctl show` with **no manual tunnel commands**. Geneve TLV options carry
the **logical datapath** and **logical ingress/egress port** so the far chassis
knows exactly where the packet belongs.

### 2.4 Distributed east/west routing (DVR)

Here is the property that makes OVN scale. When `ns-a` on chassis1 pings `ns-e`
on chassis2 *across subnets*, the logical router `lr1` does the routing **on
chassis1** (the source), and the packet then crosses **one** Geneve tunnel
straight to chassis2:

```
  ns-a ──► [lr1 pipeline runs on chassis1] ──► Geneve ──► chassis2 ──► ns-e
```

There is **no hop through a central network node**. Every chassis has the full
router pipeline. This is OVN's built-in **distributed virtual routing** — the
feature OpenStack calls **DVR**, on by default with ML2/OVN.

### 2.5 Why the *gateway* is still centralized: `cr-lrp`

East/west is distributed, but **north/south** (SNAT to the outside, the
external `localnet`) needs a **single** chassis to own the external IP — you
can't have two hosts ARP-replying for the same gateway IP on the physical LAN.
OVN models this with a special **`chassisredirect`** port, shown as
**`cr-<lrp>`** in `ovn-sbctl show`. Traffic that needs the gateway is redirected
(over Geneve) to whichever chassis currently owns the `cr-lrp`.

In Lab 5 you pinned it with a single `lrp-set-gateway-chassis`. With two
chassis you can make it **HA**.

### 2.6 Gateway HA chassis groups

Give the gateway port a **prioritized list** of candidate chassis:

```bash
ovn-nbctl lrp-set-gateway-chassis lr1-ext chassis1 30
ovn-nbctl lrp-set-gateway-chassis lr1-ext chassis2 20
```

OVN elects the highest-priority *available* chassis to host the `cr-lrp`, using
**BFD** over the Geneve tunnels to detect failure. If chassis1 dies, the
`cr-lrp` (and SNAT) **fail over** to chassis2 automatically. This is the OVN
realization of Neutron **L3 HA**.

### 2.7 Floating IPs: centralized vs. distributed `dnat_and_snat`

A **floating IP** is a 1:1 NAT — an external address mapped to one instance:

```bash
ovn-nbctl lr-nat-add lr1 dnat_and_snat <FIP> <instance-ip>
```

By default this NAT is performed on the **gateway** chassis (`cr-lrp`). But OVN
can make a floating IP **distributed** — NAT'd on the *instance's own* chassis —
by also giving it the instance's MAC and logical port:

```bash
ovn-nbctl lr-nat-add lr1 dnat_and_snat <FIP> <instance-ip> \
  <instance-lsp> <fip-mac>
```

Now `ns-a`'s floating IP traffic is NAT'd locally on whatever chassis `ns-a`
runs on — no gateway round-trip. This is exactly what OpenStack DVR floating IPs
do.

### 2.8 The Neutron mapping

| OVN construct | OpenStack |
|---------------|-----------|
| chassis | compute / network node |
| auto Geneve mesh | tenant-network overlay between nodes |
| distributed router pipeline | **DVR** (east/west on each compute node) |
| `cr-lrp` / `chassisredirect` | the centralized SNAT gateway port |
| gateway HA chassis group + BFD | **L3 HA** (failover of the gateway) |
| `dnat_and_snat` (centralized) | floating IP via the network node |
| `dnat_and_snat` + port + MAC (distributed) | **DVR floating IP** on the compute node |

---

## 3. Starting Point

Continue from Lab 7 on **host1** (this becomes OVN central + chassis1). You will
add **chassis2** as a second VM.

### 3.1 Provision chassis2

Use the `virt-tools` submodule (initialize it if needed):

```bash
git submodule update --init virt-tools
sudo virt-tools/kvm/setup_kvm_tools.sh         # one-time: KVM, libvirt, images
virt-tools/kvm/spawn-vm.sh chassis2            # cloud-init Ubuntu VM
```

> **No KVM?** Any second Ubuntu 22.04+ machine, cloud VM, or LXD container with
> its own kernel works — you just need a host that can run `ovn-host` and reach
> host1's management IP. Note the two hosts' management IPs as
> `<HOST1_IP>` and `<HOST2_IP>`.

### 3.2 Record your addresses

| Placeholder | Meaning | Example |
|-------------|---------|---------|
| `<HOST1_IP>` | host1 management IP (OVN central + chassis1 encap) | `192.168.122.10` |
| `<HOST2_IP>` | chassis2 management IP (chassis2 encap) | `192.168.122.20` |

---

## 4. Exercises

All commands require **root** or **sudo** privileges.

### Exercise 1 — Open OVN central to the network

On **host1**, make the SB/NB databases listen on TCP and set host1's own encap
IP to its real management address (not `127.0.0.1` from Lab 5).

```bash
ovn-sbctl set-connection ptcp:6642:0.0.0.0
ovn-nbctl  set-connection ptcp:6641:0.0.0.0
ovs-vsctl set open . external-ids:ovn-encap-ip=<HOST1_IP>
ovs-vsctl set open . external-ids:ovn-remote=tcp:<HOST1_IP>:6642
```

**Verify:**
- `ss -tlnp | grep 664` shows OVN listening on 6641/6642.
- `ovn-sbctl show` still lists chassis1 (now with encap IP `<HOST1_IP>`).

### Exercise 2 — Join chassis2 to the control plane

On **chassis2**, install `ovn-host` and point it at host1:

```bash
sudo apt install -y ovn-host
sudo ovs-vsctl set open . \
  external-ids:ovn-remote=tcp:<HOST1_IP>:6642 \
  external-ids:ovn-encap-type=geneve \
  external-ids:ovn-encap-ip=<HOST2_IP>
sudo systemctl restart ovn-controller
```

**Verify (on host1):**
- `ovn-sbctl show` now lists **two** chassis with their respective encap IPs.

### Exercise 3 — Watch the Geneve overlay appear

Without running a single tunnel command, inspect both hosts:

```bash
ovs-vsctl show          # look for an "ovn-<remote>" port, type geneve
ip -d link show genev_sys_6081
```

Then bind a namespace on **chassis2** to a *new* port on the **existing** `ls1`
(reuse the Lab 5/6 binding recipe: veth → `br-int`, `iface-id=<lsp>`,
DHCP inside). Call it `ns-e` (`ls1-port5`).

**Verify:**
- `ns-a` (chassis1) can ping `ns-e` (chassis2) — **same logical switch, two
  physical hosts**.
- On the **underlay**, `tcpdump -ni any udp port 6081` on either host shows
  **Geneve-encapsulated** frames carrying the ping.
- Inner traffic in `br-int` is plain; only the inter-host hop is encapsulated.

**Questions:**
- Who created the tunnel? Compare with the manual VXLAN tunnel of Lab 4.
- What logical metadata does Geneve carry that plain VXLAN would not?

### Exercise 4 — Prove routing is distributed (DVR)

Put `ns-e` on `ls2` instead (subnet `10.0.2.0/24`) so reaching `ns-a`
(`ls1`, chassis1) now requires **routing** through `lr1`.

```bash
sudo ovs-appctl ofproto/trace br-int <a-real-packet-from-ns-a>   # as in Lab 5
ovn-trace ls1 'inport=="ls1-port1" && eth.src==... && ip4.dst==10.0.2.x'
```

**Verify:**
- `ns-a` → `ns-e` works across subnets and chassis.
- `ovn-trace` shows the **`lr1` pipeline executing on chassis1** (the source),
  then a single Geneve hop to chassis2 — **no** detour through a gateway node.
- Confirm with underlay `tcpdump`: exactly one encapsulated hop, host1→host2.

### Exercise 5 — Make the external gateway HA

Recreate (or reuse) the Lab 5 external `lr1-ext` gateway port, but give it a
**prioritized chassis list** instead of a single pin:

```bash
c1=$(ovn-sbctl --bare --columns=name find chassis hostname=host1)
c2=$(ovn-sbctl --bare --columns=name find chassis hostname=chassis2)
ovn-nbctl lrp-set-gateway-chassis lr1-ext $c1 30
ovn-nbctl lrp-set-gateway-chassis lr1-ext $c2 20
```

**Verify:**
- `ovn-sbctl show` shows a **`cr-lr1-ext`** (chassisredirect) port bound to the
  priority-30 chassis.
- `ovn-nbctl lrp-get-gateway-chassis lr1-ext` lists both candidates.

Now trigger a **failover**: stop `ovn-controller` (or power off) the active
gateway chassis and re-check.

**Verify:**
- The `cr-lr1-ext` port **moves** to chassis2.
- Outbound SNAT traffic from a namespace keeps working after a brief blip.
- `ovs-appctl bfd/show` (or SB `Chassis`/`BFD` state) shows how failure was
  detected.

**Questions:**
- Why must N–S SNAT live on a single chassis at a time, while E–W routing is
  distributed across all of them?
- What protocol detects the failure, and over what transport does it run?

### Exercise 6 — Floating IPs (centralized, then distributed)

1. **Centralized FIP.** Give `ns-a` a floating IP on the external subnet:

```bash
ovn-nbctl lr-nat-add lr1 dnat_and_snat <FIP_A> 10.0.1.10
```

**Verify:**
- From an external host, `ping <FIP_A>` reaches `ns-a`; reply comes from
  `<FIP_A>`.
- `tcpdump` on the external NIC shows the FIP, not `10.0.1.10`.
- The NAT happens on the **gateway** chassis (the `cr-lrp` owner).

2. **Distributed FIP.** Re-add it bound to the instance's port + MAC:

```bash
ovn-nbctl lr-nat-del lr1 dnat_and_snat <FIP_A>
ovn-nbctl lr-nat-add lr1 dnat_and_snat <FIP_A> 10.0.1.10 \
  ls1-port1 aa:bb:cc:00:00:01
```

**Verify:**
- The FIP now NATs on **`ns-a`'s own chassis** — confirm by checking which
  chassis shows the NAT flows (`ovs-ofctl dump-flows br-int | grep <FIP_A>`)
  and that gateway-chassis traffic no longer carries it.
- This is the OVN behaviour behind **DVR floating IPs**.

### Exercise 7 — Map it to OpenStack

| What you did | OpenStack reality |
|---|---|
| Added chassis2 | added a compute node |
| Auto Geneve mesh | tenant overlay between compute nodes |
| `ns-a`→`ns-e` routed on source chassis | **DVR** east/west |
| `cr-lr1-ext` on one chassis | the SNAT gateway on a network node |
| gateway HA chassis group + BFD | **Neutron L3 HA** |
| centralized `dnat_and_snat` | floating IP via the network node |
| distributed `dnat_and_snat` (+port/MAC) | **DVR floating IP** on the compute node |

---

## 5. Key Commands Reference

| Command | Description |
|---------|-------------|
| `ovn-sbctl set-connection ptcp:6642:0.0.0.0` | Make SB DB listen on TCP |
| `ovs-vsctl set open . external-ids:ovn-encap-ip=<ip>` | Set a chassis's tunnel IP |
| `ovs-vsctl set open . external-ids:ovn-remote=tcp:<ip>:6642` | Point a chassis at central |
| `ovn-sbctl show` | List chassis + bindings (look for `cr-*` ports) |
| `ovn-nbctl lrp-set-gateway-chassis <lrp> <chassis> <prio>` | Add an HA gateway candidate |
| `ovn-nbctl lrp-get-gateway-chassis <lrp>` | List gateway candidates |
| `ovn-nbctl lr-nat-add lr1 dnat_and_snat <fip> <ip> [<lsp> <mac>]` | Floating IP (distributed if port+mac) |
| `ovs-appctl bfd/show` | Tunnel liveness used for gateway failover |
| `tcpdump -ni any udp port 6081` | Capture Geneve overlay traffic |

---

## 6. Review Questions

1. What exactly is a "chassis," and what does each chassis run locally vs.
   share centrally?
2. Who creates the Geneve tunnels between chassis, and what extra information
   does Geneve carry that VXLAN does not?
3. Explain why east/west routing is distributed but north/south SNAT is
   centralized on a `cr-lrp`.
4. How does a gateway HA chassis group elect the active chassis, and how is
   failure detected?
5. What is the difference, in data-path terms, between a centralized and a
   distributed (`dnat_and_snat` + port + MAC) floating IP?
6. Map this whole lab onto an OpenStack cloud with 3 compute nodes and 2
   network nodes: where do DVR, L3 HA, and FIPs live?

---

## 7. What's Next

You've now reproduced, by hand, a **multi-node** OVN deployment: real overlay,
distributed routing, HA gateway, and floating IPs. Functionally, this is what
OpenStack Neutron + OVN gives you — **but you wrote every `ovn-nbctl` command
yourself**.

In the final lab, **Lab 9**, you'll close the loop: stand up **real OpenStack**
(DevStack/MicroStack) with the **ML2/OVN** mechanism driver, drive it with the
`openstack` CLI, and then run `ovn-nbctl show` to discover that Neutron created
**exactly the logical resources you built by hand** — proving you now
understand the full control-plane-to-data-plane path of OpenStack networking.

---

*Lab 8 of 10 — OpenStack Networking Workshop*
