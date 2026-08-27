#!/bin/bash
# post_swap_revert_net.sh - remove GLM-staging internet workarounds (per node)
# Safe because ds4 is down by design after successful swap (no exit-node need).
TS=$(command -v tailscale || echo /usr/bin/tailscale)
sudo $TS set --exit-node= 2>/dev/null
sudo rm -f /etc/systemd/resolved.conf.d/glmfix.conf
if [ -f /etc/resolv.conf.glm-bak ]; then
  sudo mv /etc/resolv.conf.glm-bak /etc/resolv.conf
fi
sudo systemctl restart systemd-resolved 2>/dev/null || true
echo "NET-REVERTED $(hostname -s)"
