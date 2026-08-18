# Deep Dive: OVN / Charmed OpenStack Upgrade Impact (Zed → Antelope)

Briefing material for assessing data-plane and control-plane impact during a
Charmed OpenStack upgrade that moves OVN from **22.09** to **23.03** (typical
Jammy Zed → Antelope path).

---

## Scenario context

Typical questions that arise during the activity:

1. After
   `juju refresh ovn-chassis --channel 23.03/stable` and
   `juju config ovn-chassis ovn-source=cloud:jammy-antelope`,
   does a cloud-wide data-plane outage start? Is that only APT source updates,
   or a chassis restart that deletes installed flows?
2. Does the cloud-wide OVN **control-plane** outage persist until the **last**
   `nova-compute` unit is upgraded?
3. Fear: flows deleted on every chassis from the chassis refresh/`ovn-source`
   step until nova-compute finishes — implying parallel compute upgrades.

### Example upgrade path

| Component | From | To |
|-----------|------|----|
| OVN Southbound schema | 20.25.0 | 20.27.0 |
| OVN Northbound schema | 6.3.0 | 7.0.0 |
| ovn-central channel | 22.09/stable | 23.03/stable |
| neutron-api | zed/stable | 2023.1/stable |

Schema versions map to upstream OVN tags:

| Schema | OVN release |
|--------|-------------|
| SB 20.25.0 / NB 6.3.0 | `v22.09.0` |
| SB 20.27.0 / NB 7.0.0 | `v23.03.0` |

Confirm on `ovn-central`:

```bash
ovsdb-tool schema-version /usr/share/ovn/ovn-nb.ovsschema
ovsdb-tool schema-version /usr/share/ovn/ovn-sb.ovsschema
ovsdb-client get-schema-version unix:/var/run/ovn/ovnnb_db.sock OVN_Northbound
ovsdb-client get-schema-version unix:/var/run/ovn/ovnsb_db.sock OVN_Southbound
```

### External references often cited in the field

| Ref | URL | Notes |
|-----|-----|-------|
| [1] Action plan | https://pastebin.canonical.com/p/29jgsCn7qV/ | Canonical SSO; obtain local copy for the exact procedure |
| [2] Support KB | https://support-portal.canonical.com/knowledge-base/OVN-upgrade-from-Yoga-to-Caracal-in-Charmed-OpenStack#zed-to-antelope-upgrade | Internal; section on Zed→Antelope / flows |
| [3] Charm-guide OpenStack upgrade | https://docs.openstack.org/charm-guide/2023.1/admin/upgrades/openstack.html | Public |

---

## Version and topology facts

- OpenStack Charms only support **N+1** OpenStack upgrades (no skipping releases).
- `ovn-chassis` is a **subordinate** of `nova-compute` (data plane on hypervisors).
- `ovn-central` hosts NB/SB OVSDB and `ovn-northd` (control plane).
- On Jammy, OVN packages normally ride the OpenStack UCA pocket
  (`jammy-zed`, `jammy-antelope`, …). The `ovn-source` option was introduced
  primarily for the Focal overlay pocket `cloud:focal-ovn-22.03`.

Local trees useful for code/docs inspection:

- Charms / layer: `/home/erlon/internal_git/charms/layers/charm-layer-ovn` (use `stable/23.03`)
- Charm guide: `/home/erlon/internal_git/charms/charm-guide`
- OVN: `/home/erlon/internal_git/ovn`
- OVS: `/home/erlon/internal_git/ovs`

---

## Material for Q1 — `juju refresh` + `ovn-source=`

Treat the two commands as **different** operations:

```bash
juju refresh ovn-chassis --channel 23.03/stable
juju config ovn-chassis ovn-source=cloud:jammy-antelope
```

### Charm vs payload (official)

- [Upgrades overview](https://docs.openstack.org/charm-guide/latest/admin/upgrades/overview.html):
  upgrade **charms** first, then OpenStack **payload**, then series.
- [OpenStack upgrade](https://docs.openstack.org/charm-guide/2023.1/admin/upgrades/openstack.html):
  with channel charms, changing channel is required; **“a channel change will
  typically cause the underlying cloud service to restart.”**

### Charm code: refresh alone vs `ovn-source` change

Source: `charm-layer-ovn` branch `stable/23.03`
(`/home/erlon/internal_git/charms/layers/charm-layer-ovn`).

1. **Charm upgrade must not false-trigger payload upgrade**  
   On upgrade-charm, the layer clears `config.changed.ovn-source` so a newly
   introduced option does not look “changed”.  
   - Commit `ad6862a` — “Fix issues with charm and payload upgrade”  
   - LP: https://bugs.launchpad.net/charm-ovn-chassis/+bug/1991319

2. **Payload upgrade is tied to config change** of `source` / `ovn-source`
   (in `configure_ovs()`):

   ```python
   if (reactive.is_flag_set('config.changed.source')
           or reactive.is_flag_set('config.changed.ovn-source')):
       charm_instance.upgrade_if_available(...)
   ```

3. **`upgrade_if_available()`** compares installed vs apt-cache `ovn-host`.
   If newer: `do_openstack_pkg_upgrade(upgrade_openstack=False)` →
   `apt_update` + **`apt_upgrade(..., dist=True)`** + install charm packages.

4. Config option text (23.03):

   > Note that updating this setting to a source that is known to provide a
   > later version of OVN will trigger a software upgrade.

5. Charmhub: https://charmhub.io/ovn-chassis/configure?channel=23.03/stable

### What `ovn-source` was designed for

- Overlay repository for OVN (especially Focal `cloud:focal-ovn-22.03`), not
  the usual Jammy OpenStack upgrade path.
- Documented pattern (Focal 22.03 procedure):  
  https://docs.openstack.org/charm-guide/latest/project/procedures/ovn-upgrade-2203.html  

  ```bash
  juju refresh ovn-chassis --channel 22.03/stable
  juju config ovn-chassis ovn-source=cloud:focal-ovn-22.03
  ```

- Discussion (COU #494): chassis `ovn-source` is mainly for that Focal pocket;
  for normal OpenStack upgrades, **nova-compute’s openstack upgrade is expected
  to upgrade chassis packages** (subordinate co-located).  
  https://github.com/canonical/charmed-openstack-upgrader/issues/494

Using `ovn-source=cloud:jammy-antelope` points at a **full Antelope UCA**
pocket via the overlay key — check whether that exposes newer OVN packages on
**all** chassis units at once.

### Scope if `ovn-source` triggers upgrade

- `juju config` is **application-wide**.
- Every `ovn-chassis` unit runs config-changed; if an upgrade is available,
  package upgrade can run on **all hypervisors**, unlike paused-single-unit
  nova-compute.

### Flow deletion / controller restart

- LP #1940043 — upgrading OVN without fail-safe / `--restart` can clear OVS
  flows → data-plane outage:  
  https://bugs.launchpad.net/charm-ovn-chassis/+bug/1940043
- Upstream `ovn-ctl`: `restart_controller` sets `RESTART=yes` and passes
  `--restart` on stop so flows/SB records are not cleared.  
  Local: `/home/erlon/internal_git/ovn/utilities/ovn-ctl`
- Package upgrade uses apt; whether systemd stop uses `--restart` depends on
  the installed unit. Verify on a hypervisor:

  ```bash
  systemctl cat ovn-controller
  # and/or
  systemctl cat ovn-host
  ```

### Related case: Zed → 2023.1 chassis / compute

https://github.com/canonical/charmed-openstack-upgrader/issues/494

- Refreshing chassis channel alone can leave packages on Zed until UCA /
  `openstack-origin` changes.
- Upgrading nova-compute flips cloud-archive toward Antelope and upgrades OVN
  packages on that host.
- Chicken-egg: upstream OVN wants chassis before central; charm-guide OpenStack
  order has `ovn-central` before `nova-compute`.

---

## Material for Q2 — control-plane outage until last nova-compute?

From [OpenStack upgrade (2023.1 charm-guide)](https://docs.openstack.org/charm-guide/2023.1/admin/upgrades/openstack.html)
(local: `charms/charm-guide/doc/source/admin/upgrades/openstack.rst`):

> The OVN control plane will not be available between the commencement of the
> ovn-central upgrade and the completion of the nova-compute upgrade.

Upgrade order excerpt (same page):

| Order | Charm |
|------:|-------|
| … | … |
| 16 | neutron-api |
| 17 | neutron-gateway or ovn-dedicated-chassis |
| 18 | **ovn-central** |
| … | … |
| 21 | **nova-compute** |

Also noted: charms mainly change apt sources; co-located services get package
updates with the targeted application.

Paused-single-unit nova-compute upgrades units one-by-one → lengthens the
window if the Important note above holds.

---

## Material for “cloud-wide DP from chassis step until nova-compute finishes”

### Upstream OVN upgrade procedures

https://docs.ovn.org/en/latest/intro/install/ovn-upgrades.html  

Local: `/home/erlon/internal_git/ovn/Documentation/intro/install/ovn-upgrades.rst`

**Rolling upgrade order:**

1. Upgrade ovn-controller (chassis)
2. Upgrade OVN databases and ovn-northd (central)
3. Upgrade OVN integration (e.g. Neutron)

**Rolling upgrade support span (LTS):**

- LTS → next LTS (or non-LTS between them)
- Any non-LTS → next LTS
- First LTS: 22.03; subsequent LTS every two years (24.03, …)

**22.09 → 23.03 is non-LTS → non-LTS** → outside the documented rolling-upgrade
paths; upstream points to **fail-safe upgrade** (version pinning /
`northd_internal_version`).

Fail-safe intent: ovn-controller refrains from changing local flow state when
controller and northd versions mismatch.

Charm option: `enable-version-pinning` →
`external_ids:ovn-match-northd-version` (layer-ovn / Charmhub).

### Field / product issues for this span

- COU #686 — Yoga→Zed→Antelope; chassis upgraded to Antelope while DB still
  older → `database needs upgrade?` / Mirror / Chassis_Template_Var warnings:  
  https://github.com/canonical/charmed-openstack-upgrader/issues/686
- COU PR #641 — reorders COU toward upstream OVN; notes chassis **payload**
  upgrades when **nova-compute** upgrades, so central/neutron should follow
  compute:  
  https://github.com/canonical/charmed-openstack-upgrader/pull/641

### Competing official orders (tension to resolve)

| Source | Order |
|--------|-------|
| Charm-guide OpenStack upgrade | … → neutron-api → ovn-dedicated-chassis → **ovn-central** → … → **nova-compute** |
| Upstream OVN | **ovn-controller / chassis** → **central** → Neutron |
| COU PR #641 rationale | Effective chassis payload with **nova-compute**, then central / neutron |
| Field datapoint often reported | nova-compute **before** ovn-central → immediate network issue |

---

## Parallel nova-compute?

Charm-guide upgrade methods (same OpenStack upgrade page):

| Method | Time | Downtime character |
|--------|------|--------------------|
| all-in-one | shortest | most disruption |
| single-unit | medium | medium |
| paused-single-unit | longest | least per-unit disruption |

COU: control-plane typically sequential; data-plane/hypervisors more cautious
(often unit-by-unit `openstack-upgrade`), with optional grouping/parallelism
across machines.  
Docs: https://canonical-charmed-openstack-upgrader.readthedocs-hosted.com/

If charm-guide’s “CP down from ovn-central start until **last** nova-compute
finishes” applies, serial compute extends CP outage; parallel compute shortens
it. That is separate from whether chassis flows were already wiped earlier by
an application-wide `ovn-source` package upgrade.

---

## Practical checks (lab / pre-prod)

Before answering operationally, capture before/after evidence:

1. **Baseline** on several hypervisors and central:

   ```bash
   dpkg -l 'ovn-*' 'openvswitch-*'
   ovs-ofctl dump-flows br-int | wc -l
   ovs-vsctl get Open_vSwitch . external_ids
   systemctl status ovn-controller
   ```

2. Run **only** `juju refresh ovn-chassis --channel 23.03/stable`  
   Watch hooks, package versions, flow counts, controller restarts.

3. Run **only** `juju config ovn-chassis ovn-source=cloud:jammy-antelope`  
   Same checks on **multiple** hypervisors (application-wide).

4. Compare to upgrading a **single** `nova-compute` with
   `openstack-origin=cloud:jammy-antelope` **without** chassis `ovn-source`.

5. Confirm `enable-version-pinning` and whether fail-safe steps were used for
   22.09 → 23.03.

---

## Primary reference list

1. https://docs.openstack.org/charm-guide/2023.1/admin/upgrades/openstack.html — CP outage note; upgrade order; channel restart note  
2. https://docs.openstack.org/charm-guide/latest/admin/upgrades/overview.html — charm vs payload order  
3. https://docs.openstack.org/charm-guide/latest/project/procedures/ovn-upgrade-2203.html — refresh + `ovn-source` pattern; fail-safe for older OVN  
4. https://docs.ovn.org/en/latest/intro/install/ovn-upgrades.html — rolling vs fail-safe; controller-first  
5. https://bugs.launchpad.net/charm-ovn-chassis/+bug/1940043 — flow clear / data-plane on upgrade  
6. https://bugs.launchpad.net/charm-ovn-chassis/+bug/1991319 — refresh must not false-trigger `ovn-source` payload upgrade  
7. https://github.com/canonical/charmed-openstack-upgrader/issues/494 — Zed→Antelope chassis/compute packaging and order  
8. https://github.com/canonical/charmed-openstack-upgrader/pull/641 — COU order vs upstream OVN  
9. https://github.com/canonical/charmed-openstack-upgrader/issues/686 — 22.09→23.03 non-LTS span / DP symptoms  
10. Local: `charms/layers/charm-layer-ovn` (`stable/23.03`) — `ovn-source` → `upgrade_if_available` → apt dist-upgrade  
11. Local: `charms/charms.openstack/charms_openstack/charm/core.py` — `do_openstack_pkg_upgrade`  
12. Local: `ovn/utilities/ovn-ctl` — `--restart` behaviour  

---

## Related local helpers

- Hotsos OVN upgrade mismatch scenarios:  
  `/home/erlon/internal_git/hotsos/hotsos/defs/scenarios/openvswitch/ovn/ovn_upgrades.yaml`
- Charm-guide OVN 22.03 procedure (rst):  
  `/home/erlon/internal_git/charms/charm-guide/doc/source/project/procedures/ovn-upgrade-2203.rst`
