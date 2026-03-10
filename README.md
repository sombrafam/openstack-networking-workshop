# OpenStack Networking Workshop

A progressive, hands-on workshop to learn how networking works in OpenStack
with OVN — from basic Linux networking primitives all the way to a fully
working OVN-based virtual networking setup.

## 🎯 Who Is This For?

Engineers joining the team who need a solid understanding of the networking
data-plane and control-plane that underpin OpenStack/OVN.

## 📋 Prerequisites

- Basic Linux CLI skills (bash, ip, ss, tcpdump)
- Ubuntu 22.04+ with root/sudo access
- KVM/libvirt (optional — needed for multi-node labs)

## 🗂️ Workshop Structure

| Lab | Topic | Tier | Duration |
|-----|-------|------|----------|
| [Lab 1](labs/lab01-tap-devices-and-namespaces/) | TAP Devices & Network Namespaces | Fundamentals | ~45 min |
| [Lab 2](labs/lab02-veth-pairs/) | Veth Pairs | Fundamentals | ~45 min |
| [Lab 3](labs/lab03-ovs-and-l2-switches/) | OVS as an L2 Switch | Open vSwitch | ~1 hour |
| [Lab 4](labs/lab04-openflow-and-tunnels/) | OVS Advanced: OpenFlow Rules & Tunnels | Open vSwitch | ~1.5 hours |
| [Lab 5](labs/lab05-ovn-basics/) | OVN Basics (Open Virtual Network) | OVN | ~2.5 hours |

**Total estimated time:** ~6.5 hours (spread across 3–4 sessions)

## 📚 How It Works

Each lab has two files:
- **`README.md`** — The lab description: objectives, concepts, architecture
  diagrams, and exercises to work through. **No solutions.**
- **`solution.md`** — The full walkthrough with commands and expected output.

### Class-by-Class Delivery

On each new class students attempt each lab independently before seeing the
solution in the next class. The solution for the **previous** lab is always
bundled inside the **current** lab's folder — students only see it after the
next session is unlocked.


## 📖 Further Reading

- [Full Project Spec](untracked/SPEC.md)
- `man 7 ovn-architecture`
- [OVN documentation](https://www.ovn.org/)
- [Open vSwitch documentation](https://www.openvswitch.org/)

