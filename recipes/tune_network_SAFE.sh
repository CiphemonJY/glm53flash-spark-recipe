#!/bin/bash
# tune_network_SAFE.sh - GLM adaptation of James's recipe (buffer half ONLY).
# NO mtu/ring/link changes here (ds4 live RoCE traffic shares these NICs).
# Jumbo MTU 9000 already active on fabric ifaces (verified).
set -e
cat <<'EOF' | sudo tee /etc/sysctl.d/99-glm-net.conf >/dev/null
# glm-5.3-flash staging/serve network tuning (adapted from user recipe)
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.core.rmem_default=67108864
net.core.wmem_default=67108864
net.core.optmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 134217728
net.ipv4.tcp_wmem=4096 65536 134217728
EOF
sudo sysctl --system >/dev/null 2>&1 || true
echo "APPLIED $(hostname -s):"
sysctl -n net.core.rmem_max net.ipv4.tcp_rmem | cut -c1-50