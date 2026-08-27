#!/bin/bash
# tune_network_FULL.sh - SWAP-WINDOW ONLY (run AFTER any serving containers are
# stopped). Adds the link-level half: ring buffers (MTU is set idempotently).
# Why deferred: `ethtool -G` briefly pauses the queue, which stalls any RoCE
# traffic sharing the NIC - so this waits for a stop window. See RUNBOOK.md.
set -e
IFACE=$(ip -o link | awk -F': ' '/enp1s0f1np1/ {print $2; exit}')
[ -n "$IFACE" ] || IFACE=enp1s0f1np1

echo "Current state of $IFACE:"
ip link show dev $IFACE | grep -o 'mtu [0-9]*'
ethtool -g $IFACE 2>/dev/null | tail -4 || true

sudo ip link set dev $IFACE mtu 9000        # idempotent if already 9000
sudo ethtool -G $IFACE rx 4096 tx 4096      # ring buffers to max

echo "Post-tuning:"
ip link show dev $IFACE | grep -o 'mtu [0-9]*'
ethtool -g $IFACE 2>/dev/null | tail -4
echo "FULL TUNING DONE on $(hostname -s)"
