#!/bin/bash
# fire2.sh - launch variant A cleanly, inspect after 35s
bash -n /home/syeung/glm_launch/variant_a_ip.sh || { echo SYNTAX-FAIL; exit 9; }
rm -f /home/syeung/glm_launch/va.log
setsid nohup bash /home/syeung/glm_launch/variant_a_ip.sh \
  > /home/syeung/glm_launch/va.log 2>&1 < /dev/null &
echo FIRED
sleep 40
echo "=== containers ==="
sudo docker ps --format 'table {{.Names}}\t{{.Status}}' | grep -E 'glm|NAMES'
echo "=== va.log ==="
tail -5 /home/syeung/glm_launch/va.log
