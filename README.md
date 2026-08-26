# OpenStack Networking Workshop

A progressive, hands-on workshop to learn how networking works in OpenStack
with OVN — from basic Linux networking primitives all the way to a fully
working OVN-based virtual networking setup.

## 🎯 Who Is This For?

SE, SEG, ManSol, and other engineers aim to develop a solid understanding of
the networking data plane and control plane that underpin OpenStack/OVN.

## 📋 Prerequisites

- Basic Linux CLI skills (bash, ip, ss, tcpdump)
- Ubuntu 22.04+ with root/sudo access
- KVM/libvirt (optional — needed for multi-node labs)

## 🗺️ Course Roadmap

A progressive, hands-on workshop — from basic Linux networking primitives all
the way to a fully working OVN-based virtual networking setup, grouped into
four tiers:

1. **Fundamentals** — Linux networking primitives (Labs 1–2)
2. **Open vSwitch** — L2 switching, OpenFlow & tunnels (Labs 3–4)
3. **OVN** — Open Virtual Network, from basics to the full OpenStack/Neutron integration (Labs 5–9)
4. **Field Ops** — Debugging real-world scenarios (Lab 10)

See the [Workshop Structure](#️-workshop-structure) table below for the full
lab-by-lab breakdown.

## 🚚 Delivery Format

The training is planned to be offered with the following format:

- **8 bi-weekly presentations on Fridays** — each presentation covers the
  fundamentals of the week's module and provides instructions on executing
  the take-home exercises.
- After every presentation, a **take-home exercise** will be proposed. Before
  each presentation, the content from the previous module is quickly
  recapped.
- In the week following the presentation, **office hours** will be held for
  people to discuss questions regarding the previous labs and what they
  learned from previous lessons.
- A **dedicated channel** will be open in Mattermost for people to share
  their achievements, challenges and ask for help.

## 🗂️ Workshop Structure

| Lab | Topic | Tier | Duration   |
|-----|-------|------|------------|
| [Lab 1](labs/lab01-tap-devices-and-namespaces/) | TAP Devices & Network Namespaces | Fundamentals | ~45 min    |
| [Lab 2](labs/lab02-veth-pairs/) | Veth Pairs | Fundamentals | ~45 min    |
| [Lab 3](labs/lab03-ovs-and-l2-switches/) | OVS as an L2 Switch | Open vSwitch | ~60 min    |
| [Lab 4](labs/lab04-openflow-and-tunnels/) | OVS Advanced: OpenFlow Rules & Tunnels | Open vSwitch | ~60 min   |
| [Lab 5](labs/lab05-ovn-basics/) | OVN Basics (Open Virtual Network) | OVN | ~60 min |
| [Lab 6](labs/lab06-ovn-native-services/) | OVN Native Services & Security Groups: DHCP, DNS, Metadata, Port Groups & Stateful ACLs | OVN | ~90 min    |
| [Lab 7](labs/lab07-multi-node-ovn/) | Multi-node OVN | OVN | ~60 min    |
| [Lab 8](labs/lab08-ovn-multi-chassis/) | Multi-Chassis OVN: Geneve Tunnels, DVR, Gateway HA & Floating IPs | OVN | ~45 min    |
| [Lab 9](labs/lab09-openstack-ml2-ovn/) | The OpenStack Layer: Neutron ML2/OVN (Capstone) | OVN | ~45 min    |
| [Lab 10](labs/lab10-real-world-scenarios/) | Real-World Scenarios | Field Operations | ~45 min    |

**Total estimated time:** ~9.25 hours (spread across bi-weekly sessions)

## 📚 How It Works

Each lab folder includes:
- **`README.md`** — The lab description: objectives, concepts, architecture
  diagrams, and exercises to work through. **No solutions.**
- **`labXX-solution.md`** — The full walkthrough with commands and expected
  output for the **previous** lab (released in the next lab folder).

### Class-by-Class Delivery

In each class, students attempt the current lab independently before seeing the
solution in the next class. The solution for the **previous** lab is always
bundled inside the **current** lab's folder — students only see it after the
next session is unlocked.


## 📖 Further Reading

- `man 7 ovn-architecture`
- [OVN documentation](https://www.ovn.org/)
- [Open vSwitch documentation](https://www.openvswitch.org/)
