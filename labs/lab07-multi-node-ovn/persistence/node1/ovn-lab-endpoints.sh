#!/usr/bin/env bash
set -euo pipefail

# Recreate lab endpoints for node1:
# - ns-a <-> ls1-port1 (10.0.1.10)
# - ns-c <-> ls2-port3 (10.0.2.10)

for ns in ns-a ns-c; do
  ip netns delete "$ns" 2>/dev/null || true
done

ovs-vsctl --may-exist add-br br-int
ip link set br-int up

for port in veth-a-ovs veth-c-ovs; do
  ovs-vsctl --if-exists del-port br-int "$port"
  ip link del "$port" 2>/dev/null || true
done

ip netns add ns-a
ip netns add ns-c
ip netns exec ns-a ip link set lo up
ip netns exec ns-c ip link set lo up

ip link add veth-a type veth peer name veth-a-ovs
ip link add veth-c type veth peer name veth-c-ovs

ip link set veth-a netns ns-a
ip link set veth-c netns ns-c

ovs-vsctl add-port br-int veth-a-ovs
ovs-vsctl add-port br-int veth-c-ovs
ip link set veth-a-ovs up
ip link set veth-c-ovs up

ovs-vsctl set interface veth-a-ovs external-ids:iface-id=ls1-port1
ovs-vsctl set interface veth-c-ovs external-ids:iface-id=ls2-port3

ip netns exec ns-a ip link set veth-a address aa:bb:cc:00:00:01
ip netns exec ns-a ip addr flush dev veth-a
ip netns exec ns-a ip addr add 10.0.1.10/24 dev veth-a
ip netns exec ns-a ip link set veth-a up
ip netns exec ns-a ip route replace default via 10.0.1.1

ip netns exec ns-c ip link set veth-c address aa:bb:cc:00:00:03
ip netns exec ns-c ip addr flush dev veth-c
ip netns exec ns-c ip addr add 10.0.2.10/24 dev veth-c
ip netns exec ns-c ip link set veth-c up
ip netns exec ns-c ip route replace default via 10.0.2.1
