#!/bin/bash
# fire2.sh - detached launch of variant A + inspection after 40s.
# Run from the directory holding variant_a_ip.sh (or set LAUNCH_DIR).
# Env for variant_a_ip.sh (HEAD_IP, WORKER_IPS, ...) pass straight through.
set -u
LAUNCH_DIR=${LAUNCH_DIR:-$(cd "$(dirname "$0")" && pwd)}
bash -n "$LAUNCH_DIR/variant_a_ip.sh" || { echo SYNTAX-FAIL; exit 9; }
rm -f "$LAUNCH_DIR/va.log"
setsid nohup bash "$LAUNCH_DIR/variant_a_ip.sh" \
  > "$LAUNCH_DIR/va.log" 2>&1 < /dev/null &
echo FIRED
sleep 40
echo "=== containers ==="
sudo docker ps --format 'table {{.Names}}\t{{.Status}}' | grep -E 'glm|NAMES'
echo "=== va.log ==="
tail -5 "$LAUNCH_DIR/va.log"
