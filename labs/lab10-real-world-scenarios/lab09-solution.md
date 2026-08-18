# Lab 9 — Solution: The OpenStack Layer — Neutron ML2/OVN

> **This is the final lab's solution.** It contains the full commands and expected output for Lab 9's exercises.

---

## Exercise 1 — Deploy OpenStack with ML2/OVN

```bash
cat > local.conf <<'CONF'
[[local|localrc]]
ADMIN_PASSWORD=secret
DATABASE_PASSWORD=$ADMIN_PASSWORD
RABBIT_PASSWORD=$ADMIN_PASSWORD
SERVICE_PASSWORD=$ADMIN_PASSWORD
Q_AGENT=ovn
Q_ML2_PLUGIN_MECHANISM_DRIVERS=ovn
Q_ML2_TENANT_NETWORK_TYPE=geneve
enable_service ovn-northd ovn-controller q-ovn-metadata-agent
CONF

./stack.sh
source openrc admin admin
```

**Verify:**

```bash
openstack network agent list
```

**Expected output:**
```
+--------------------------------------+------------------------------+----------+-------+-------+----------------------------+
| ID                                   | Agent Type                   | Host     | Alive | State | Binary                     |
+--------------------------------------+------------------------------+----------+-------+-------+----------------------------+
| 4e96c4fb-3a51-4d0e-bcbb-9e3f4f23b120 | OVN Controller agent         | devstack | :-)   | UP    | ovn-controller             |
| 3ccbd0a7-96b4-4c38-bf64-2c77c2c70af9 | OVN Metadata agent           | devstack | :-)   | UP    | neutron-ovn-metadata-agent |
+--------------------------------------+------------------------------+----------+-------+-------+----------------------------+
```

```bash
openstack extension list --network | grep -i ovn
ovn-nbctl show
```

**Expected output:**
```
| OVN Agent Scheduler    | ovn-agent-scheduler | Schedule Neutron resources to OVN agents. |

switch 11111111-1111-1111-1111-111111111111 (neutron-0d6a5d51-8e80-48c4-a698-0e5afc19bf11) (aka public)
    port provnet-0d6a5d51-8e80-48c4-a698-0e5afc19bf11
        type: localnet
        addresses: ["unknown"]
switch 22222222-2222-2222-2222-222222222222 (neutron-2a4c2e51-4c94-4b10-9b9e-3e3f838a9c91) (aka private)
    port 8c407ba8-984e-4d60-8634-cccb4ec53b26
        type: router
        router-port: lrp-8c407ba8-984e-4d60-8634-cccb4ec53b26
router 33333333-3333-3333-3333-333333333333 (neutron-df39ff6e-0ec1-4ef2-91a7-e2f795b4c891) (aka router1)
    port lrp-8c407ba8-984e-4d60-8634-cccb4ec53b26
        mac: "fa:16:3e:af:7c:a0"
        networks: ["10.0.0.1/24"]
```

> A request flows through: `openstack` CLI → Neutron REST API → ML2 plugin →
> OVN mechanism driver → OVN NB DB → `ovn-northd` → OVN SB DB →
> `ovn-controller` → OVS flows on `br-int`.

> The ML2/OVN mechanism driver's only job is translation: Neutron objects become
> OVN NB rows over OVSDB. It is the automated replacement for the `ovn-nbctl`
> commands you typed in Labs 5–8.

---

## Exercise 2 — Create a Tenant Network and Diff Against OVN

```bash
openstack network create demo-net
openstack subnet create demo-sub --network demo-net \
  --subnet-range 10.0.1.0/24 --gateway 10.0.1.1 --dns-nameserver 8.8.8.8
```

**Verify:**

```bash
ovn-nbctl show
ovn-nbctl list DHCP_Options
```

**Expected output:**
```
switch a81d32fd-1170-4f0b-b55d-2655b9cfe21a (neutron-7f2c9f7a-f3e9-4f9a-b7a0-8d0d2ff0a7ce) (aka demo-net)

_uuid               : 6dbd02b1-9912-44ac-95ed-519f47d95cc5
cidr                : "10.0.1.0/24"
external_ids        : {subnet_id="5bdc9a8e-6e1b-42de-84c1-32afd3a74f6b"}
options             : {classless_static_route="{169.254.169.254/32,10.0.1.2, 0.0.0.0/0,10.0.1.1}",
                       dns_server="{8.8.8.8}", lease_time="43200", mtu="1442",
                       router="10.0.1.1", server_id="10.0.1.1",
                       server_mac="fa:16:3e:6b:7c:d2"}
```

> `openstack network create demo-net` produced
> `Logical_Switch neutron-7f2c...`, the same thing as `ovn-nbctl ls-add ls1`.
> `openstack subnet create` produced the Lab 6 `DHCP_Options`: subnet range →
> `cidr`, gateway → `router`/`server_id`, DNS flag → `dns_server`, and Neutron's
> MTU configuration → `mtu`.

---

## Exercise 3 — Ports, Security Groups, and the Auto-Created Port Groups

```bash
openstack security group create web
openstack security group rule create --ingress --protocol tcp \
  --dst-port 80 web
openstack port create --network demo-net --security-group web web-port
```

**Verify:**

```bash
ovn-nbctl list Port_Group
ovn-nbctl list ACL
ovn-nbctl --columns=name,addresses,dhcpv4_options,port_security list Logical_Switch_Port 2dce9ac7-66e1-4f70-9c92-715c0f9682ff
```

**Expected output:**
```
_uuid               : 7a0f045f-d5ad-4385-b19c-4a64f2f03b2f
name                : pg_9f3ec56d_0fe3_46e5_a01a_d154160041b4
ports               : [2dce9ac7-66e1-4f70-9c92-715c0f9682ff]
external_ids        : {"neutron:security_group_id"="9f3ec56d-0fe3-46e5-a01a-d154160041b4"}

_uuid               : 31fbcc31-6842-4bf6-8c43-cd436dcf4f9d
name                : neutron_pg_drop
ports               : []

_uuid               : 51ea4d3f-4ae1-4a7d-b65c-62d7a7e691f3
action              : allow-related
direction           : to-lport
match               : "outport == @pg_9f3ec56d_0fe3_46e5_a01a_d154160041b4 && ip4 && tcp && tcp.dst == 80"
priority            : 1002

name                : "2dce9ac7-66e1-4f70-9c92-715c0f9682ff"
addresses           : ["fa:16:3e:5c:21:1d 10.0.1.44"]
dhcpv4_options      : 6dbd02b1-9912-44ac-95ed-519f47d95cc5
port_security       : ["fa:16:3e:5c:21:1d 10.0.1.44"]
```

> The security group became `pg_<sg-uuid>`, with Neutron's `neutron_pg_drop`
> default-drop group beside it. The HTTP rule became a stateful OVN ACL using
> `allow-related`, just like Lab 7. The Neutron port is a normal
> `Logical_Switch_Port` with DHCP and port-security state attached.

---

## Exercise 4 — Router, External Network, and Floating IP

```bash
openstack router create r1
openstack router add subnet r1 demo-sub
openstack router set r1 --external-gateway public
openstack floating ip create public
openstack floating ip set --port web-port 172.24.4.181
```

**Verify:**

```bash
ovn-nbctl show
ovn-nbctl lr-nat-list neutron-f69da7c7-54b7-41a8-96d6-0a99592dfc22
ovn-sbctl show
```

**Expected output:**
```
switch a81d32fd-1170-4f0b-b55d-2655b9cfe21a (neutron-7f2c9f7a-f3e9-4f9a-b7a0-8d0d2ff0a7ce) (aka demo-net)
    port 3f7a4c19-0b55-4fd6-a258-9101e6754efe
        type: router
        router-port: lrp-3f7a4c19-0b55-4fd6-a258-9101e6754efe
    port 2dce9ac7-66e1-4f70-9c92-715c0f9682ff
        addresses: ["fa:16:3e:5c:21:1d 10.0.1.44"]
router 0db15c4c-0444-4b0b-a14c-75e60acb15f8 (neutron-f69da7c7-54b7-41a8-96d6-0a99592dfc22) (aka r1)
    port lrp-3f7a4c19-0b55-4fd6-a258-9101e6754efe
        mac: "fa:16:3e:8f:1a:20"
        networks: ["10.0.1.1/24"]
    port lrp-9d8a6132-e965-4b4c-9727-884e48e6d871
        mac: "fa:16:3e:22:91:e8"
        networks: ["172.24.4.226/28"]
        gateway chassis: [devstack]

TYPE             EXTERNAL_IP    EXTERNAL_PORT    LOGICAL_IP    EXTERNAL_MAC        LOGICAL_PORT
snat             172.24.4.226                    10.0.1.0/24
dnat_and_snat    172.24.4.181                    10.0.1.44    fa:16:3e:5c:21:1d   2dce9ac7-66e1-4f70-9c92-715c0f9682ff

Chassis "b08c1899-17b8-494e-9c9f-6c3af4f84f65"
    hostname: "devstack"
    Encap geneve
        ip: "192.0.2.10"
        options: {csum="true"}
    Port_Binding "cr-lrp-9d8a6132-e965-4b4c-9727-884e48e6d871"
```

> `router create` produced a `Logical_Router`; `router add subnet` produced the
> internal router port; `--external-gateway` produced the external router port,
> `snat`, and the `cr-lrp` gateway binding; the floating IP produced
> `dnat_and_snat`. If the NAT row includes logical port + MAC, this cloud is
> using distributed floating IP behavior from Lab 8.

---

## Exercise 5 — Provider Network = `localnet`

```bash
openstack network create --provider-network-type flat \
  --provider-physical-network physnet1 --external provnet
```

**Verify:**

```bash
ovn-nbctl show
ovn-nbctl --columns=name,type,options list Logical_Switch_Port provnet-d17f6f38-817d-43c2-90d1-c17e8f0f8994
ovs-vsctl get Open_vSwitch . external_ids:ovn-bridge-mappings
```

**Expected output:**
```
switch 19a6b639-b6d1-4ba8-8f33-c88abf7704d1 (neutron-d17f6f38-817d-43c2-90d1-c17e8f0f8994) (aka provnet)
    port provnet-d17f6f38-817d-43c2-90d1-c17e8f0f8994
        type: localnet
        addresses: ["unknown"]

name                : provnet-d17f6f38-817d-43c2-90d1-c17e8f0f8994
type                : localnet
options             : {network_name=physnet1}

"public:br-ex,physnet1:br-ex"
```

> Tenant networks are Geneve overlays and do not have a `localnet` port.
> Provider flat/VLAN networks use `localnet` plus `ovn-bridge-mappings`, here
> `physnet1:br-ex`. That is the same `ls-ext` and bridge-mapping design from
> Lab 5 §9.

---

## Exercise 6 — Boot a VM and Trace the Full Port Lifecycle

```bash
openstack server create --flavor m1.tiny --image cirros \
  --network demo-net --security-group web vm1
openstack server list
openstack port list --server vm1
```

**Expected output:**
```
+--------------------------------------+------+--------+---------------------+--------+---------+
| ID                                   | Name | Status | Networks            | Image  | Flavor  |
+--------------------------------------+------+--------+---------------------+--------+---------+
| 0fdb4a2e-3f3e-47c2-9433-df926e3ea51e | vm1  | ACTIVE | demo-net=10.0.1.121 | cirros | m1.tiny |
+--------------------------------------+------+--------+---------------------+--------+---------+

+--------------------------------------+------+-------------------+-------------------------------------------------------------+--------+
| ID                                   | Name | MAC Address       | Fixed IP Addresses                                          | Status |
+--------------------------------------+------+-------------------+-------------------------------------------------------------+--------+
| a173d5ef-d021-47d3-a6a4-156712b6e2c6 |      | fa:16:3e:2f:90:33 | ip_address='10.0.1.121', subnet_id='5bdc9a8e-6e1b-42de...' | ACTIVE |
+--------------------------------------+------+-------------------+-------------------------------------------------------------+--------+
```

```bash
ovn-sbctl find Port_Binding logical_port=a173d5ef-d021-47d3-a6a4-156712b6e2c6
ovs-vsctl --columns=name,external_ids find interface \
  external_ids:iface-id=a173d5ef-d021-47d3-a6a4-156712b6e2c6
ovs-vsctl get Interface tap7030e873-39 ofport
ovs-ofctl dump-flows br-int | grep 'in_port=6'
```

**Expected output:**
```
_uuid               : 56b46bc5-0371-47bc-9ac7-4a81c1623ec1
chassis             : b08c1899-17b8-494e-9c9f-6c3af4f84f65
logical_port        : "a173d5ef-d021-47d3-a6a4-156712b6e2c6"
mac                 : ["fa:16:3e:2f:90:33 10.0.1.121"]

name                : tap7030e873-39
external_ids        : {attached-mac="fa:16:3e:2f:90:33", iface-id="a173d5ef-d021-47d3-a6a4-156712b6e2c6",
                       iface-status=active, vm-id="0fdb4a2e-3f3e-47c2-9433-df926e3ea51e"}

6
 cookie=0x..., table=0, priority=100,in_port=6 actions=load:0x7->NXM_NX_REG13[],resubmit(,8)
```

```bash
ovn-trace --minimal neutron-7f2c9f7a-f3e9-4f9a-b7a0-8d0d2ff0a7ce \
  'inport=="a173d5ef-d021-47d3-a6a4-156712b6e2c6" && eth.src==fa:16:3e:2f:90:33 && ip4.src==10.0.1.121 && ip4.dst==8.8.8.8 && ip.ttl==64 && tcp'
```

**Expected output:**
```
# tcp,reg14=0x7,vlan_tci=0x0000,dl_src=fa:16:3e:2f:90:33,...
ip.ttl--;
outport = "cr-lrp-9d8a6132-e965-4b4c-9727-884e48e6d871";
output;
```

> Port lifecycle: Nova asks Neutron for a port; ML2/OVN writes the
> `Logical_Switch_Port`; `ovn-northd` creates SB `Port_Binding`; Nova/libvirt
> creates the TAP and sets `external-ids:iface-id=<neutron-port-uuid>`; then
> `ovn-controller` binds that SB port to the chassis and installs OVS flows.
> The `iface-id` step is exactly the manual binding from Lab 5.

---

## Exercise 7 — Capstone Synthesis

```bash
openstack network create demo-net
# replaced:
ovn-nbctl ls-add ls1

openstack subnet create demo-sub --network demo-net --subnet-range 10.0.1.0/24 --gateway 10.0.1.1
# replaced:
ovn-nbctl dhcp-options-create 10.0.1.0/24
ovn-nbctl dhcp-options-set-options <dhcp> router=10.0.1.1 server_id=10.0.1.1 dns_server="{8.8.8.8}"

openstack port create --network demo-net --security-group web web-port
# replaced:
ovn-nbctl lsp-add ls1 ls1-port1
ovn-nbctl lsp-set-addresses ls1-port1 "fa:16:3e:5c:21:1d 10.0.1.44"
ovn-nbctl lsp-set-port-security ls1-port1 "fa:16:3e:5c:21:1d 10.0.1.44"

openstack security group rule create --ingress --protocol tcp --dst-port 80 web
# replaced:
ovn-nbctl pg-add pg_9f3ec56d_0fe3_46e5_a01a_d154160041b4
ovn-nbctl acl-add pg_9f3ec56d_0fe3_46e5_a01a_d154160041b4 to-lport 1002 \
  'outport == @pg_9f3ec56d_0fe3_46e5_a01a_d154160041b4 && ip4 && tcp && tcp.dst == 80' allow-related

openstack router create r1 && openstack router add subnet r1 demo-sub
# replaced:
ovn-nbctl lr-add lr1
ovn-nbctl lrp-add lr1 lr1-ls1 fa:16:3e:8f:1a:20 10.0.1.1/24

openstack router set r1 --external-gateway public
openstack floating ip set --port web-port 172.24.4.181
# replaced:
ovn-nbctl lr-nat-add lr1 snat 172.24.4.226 10.0.1.0/24
ovn-nbctl lr-nat-add lr1 dnat_and_snat 172.24.4.181 10.0.1.44 \
  2dce9ac7-66e1-4f70-9c92-715c0f9682ff fa:16:3e:5c:21:1d

openstack network create --provider-network-type flat --provider-physical-network physnet1 --external provnet
# replaced:
ovn-nbctl ls-add ls-ext
ovn-nbctl lsp-add ls-ext ln-physnet1
ovn-nbctl lsp-set-type ln-physnet1 localnet
ovn-nbctl lsp-set-options ln-physnet1 network_name=physnet1
```

**Verify:**

```bash
ovn-nbctl show
ovn-nbctl list ACL
ovn-nbctl lr-nat-list neutron-f69da7c7-54b7-41a8-96d6-0a99592dfc22
ovn-sbctl show
```

**Expected output:**
```
# switch neutron-7f2c...          <- openstack network create demo-net
# DHCP_Options 10.0.1.0/24        <- openstack subnet create demo-sub
# port 2dce9ac7...                <- openstack port create web-port
# pg_9f3ec56d... + ACL tcp/80     <- openstack security group rule create
# router neutron-f69da7c7...      <- openstack router create r1
# snat + dnat_and_snat            <- external gateway + floating IP
# localnet network_name=physnet1  <- provider network create
# bound Port_Binding + TAP iface  <- server create / Nova plug
```

> You can defend the workshop claim with concrete rows: OpenStack created the
> same `Logical_Switch`, `Logical_Switch_Port`, `DHCP_Options`, `Port_Group`,
> `ACL`, `Logical_Router`, `snat`, `dnat_and_snat`, `localnet`, and
> `Port_Binding` objects you built manually. OpenStack adds REST APIs, IPAM,
> quotas, scheduling, lifecycle automation, and metadata integration; the OVN
> topology and datapath primitives are the same.

---

🎉 **Capstone takeaway:** given any production `ovn-nbctl show` line, you can
state which Neutron API object produced it — and predict which OVN rows an
`openstack` command will create.
