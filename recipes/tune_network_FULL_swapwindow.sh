#!/bin/bash
# tune_network_FULL.sh - SWAP-WINDOW ONLY (run AFTER ds4 containers stopped).
# Adds link-level half of user recipe: ring buffers. MTU already 9000.
# Why deferred: ethtool -G briefly pauses the queue; ds4 RoCE shares these
# NICs until teardown, so this waits for the stop window (runbook step 0.5).
set -e
IFACE=$(ip -o link | awk -F': ' '/enp1s0f1np1/ {print $2; exit}')
[ -n "$IFACE" ] || IFACE=enp1s0f1np1

echo "Current state of $IFACE:"
ip link show dev $IFACE | grep -o 'mtu [0-9]*'
ethtool -g $IFACE 2>/dev/null | tail -4 || true

sudo ip link set dev $IFACE mtu 9000        # idempotent (already 9000)
sudo ethtool -G $IFACE rx 4096 tx 4096      # ring buffers to max

echo "Post-tuning:"
ip link show dev $IFACE | grep -o 'mtu [0-9]*'
ethtool -g $IFACE 2>/dev/null | tail -4
echo "FULL TUNING DONE on $(hostname -s)"
