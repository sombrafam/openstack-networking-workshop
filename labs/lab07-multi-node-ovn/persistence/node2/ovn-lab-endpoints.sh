#!/usr/bin/env bash
set -euo pipefail

# Recreate lab endpoints for node2:
# - ns-b <-> ls1-port2 (10.0.1.20)
# - ns-d <-> ls2-port4 (10.0.2.20)

for ns in ns-b ns-d; do
  ip netns delete "$ns" 2>/dev/null || true
done

ovs-vsctl --may-exist add-br br-int
ip link set br-int up

for port in veth-b-ovs veth-d-ovs; do
  ovs-vsctl --if-exists del-port br-int "$port"
  ip link del "$port" 2>/dev/null || true
done

ip netns add ns-b
ip netns add ns-d
ip netns exec ns-b ip link set lo up
ip netns exec ns-d ip link set lo up

ip link add veth-b type veth peer name veth-b-ovs
ip link add veth-d type veth peer name veth-d-ovs

ip link set veth-b netns ns-b
ip link set veth-d netns ns-d

ovs-vsctl add-port br-int veth-b-ovs
ovs-vsctl add-port br-int veth-d-ovs
ip link set veth-b-ovs up
ip link set veth-d-ovs up

ovs-vsctl set interface veth-b-ovs external-ids:iface-id=ls1-port2
ovs-vsctl set interface veth-d-ovs external-ids:iface-id=ls2-port4

ip netns exec ns-b ip link set veth-b address aa:bb:cc:00:00:02
ip netns exec ns-b ip addr flush dev veth-b
ip netns exec ns-b ip addr add 10.0.1.20/24 dev veth-b
ip netns exec ns-b ip link set veth-b up
ip netns exec ns-b ip route replace default via 10.0.1.1

ip netns exec ns-d ip link set veth-d address aa:bb:cc:00:00:04
ip netns exec ns-d ip addr flush dev veth-d
ip netns exec ns-d ip addr add 10.0.2.20/24 dev veth-d
ip netns exec ns-d ip link set veth-d up
ip netns exec ns-d ip route replace default via 10.0.2.1
