#!/bin/bash
# variant_a_tuned.sh - STEP-1 capacity tuning over variant_a_ip base.
# Levers chosen for unified-memory reality (hosts ~8-11GB avail at idle serve):
#   mem-fraction-static   UNCHANGED (KV pool fixed at 8.88GB/1.35M tok fp8;
#                         raising risks GB10 wedge)
#   max-running-requests  96      (was auto=46; scheduler admission only,
#                         no standing memory cost; lets ladder breathe)
#   cuda-graph-max-bs-decode 96    (match new ceiling so decodes stay on-graph
#                         without bloating capture memory toward 256)
#   chunked-prefill-size 16384   (2x default: faster mixed long-prefill)
#   schedule-conservativeness 0.9 (admit slightly deeper queues before retract)
IMG=lmsysorg/sglang:glm-5.3-flash
MODEL=/home/syeung/models/GLM-5.3-Flash
DIS=192.168.88.11:25000
ENV_COMMON="-e NCCL_SOCKET_IFNAME=enp1s0f1np1 -e GLOO_SOCKET_IFNAME=enp1s0f1np1 \
  -e MASTER_ADDR=192.168.88.11 -e MASTER_PORT=25000"
TUNED="--max-running-requests 96 --cuda-graph-max-bs-decode 96 --chunked-prefill-size 16384 --schedule-conservativeness 0.9"
run_node(){
  NODEIP=$1; RANK=$2
  EXTRA_HCA=""
  [ "$RANK" = "0" ] && EXTRA_HCA="-e NCCL_IB_HCA==mlx5_1:1" || EXTRA_HCA="-e NCCL_IB_HCA==rocep1s0f1:1"
  if [ "$NODEIP" = "local" ]; then
    sudo docker rm -f glm-head 2>/dev/null && echo RM-GONE-head || true
    sudo docker run -d --name glm-head --restart unless-stopped \
      --gpus all --shm-size 32g --net host $ENV_COMMON $EXTRA_HCA \
      -v $MODEL:/models/GLM-5.3-Flash:ro \
      $IMG python3 -m sglang.launch_server \
        --model-path /models/GLM-5.3-Flash \
        --tp-size 4 --nnodes 4 --node-rank 0 \
        --dist-init-addr $DIS \
        --served-model-name deepseek-v4-flash-dspark \
        --attention-backend triton $TUNED \
        --trust-remote-code --host 0.0.0.0 --port 8888
  else
    ssh -o BatchMode=yes syeung@$NODEIP "sudo docker rm -f glm-w$RANK >/dev/null 2>&1 && echo RM-GONE-w$RANK; sudo docker run -d --name glm-w$RANK --restart unless-stopped --gpus all --shm-size 32g --net host $ENV_COMMON $EXTRA_HCA -v $MODEL:/models/GLM-5.3-Flash:ro $IMG python3 -m sglang.launch_server --model-path /models/GLM-5.3-Flash --tp-size 4 --nnodes 4 --node-rank $RANK --dist-init-addr $DIS --attention-backend triton $TUNED --trust-remote-code"
  fi
}
run_node 192.168.88.12 1
sleep 3
run_node 192.168.88.13 2
sleep 3
run_node 192.168.88.14 3
sleep 3
run_node local 0
echo "$(date +%FT%T) VARIANT-A-TUNED LAUNCHED all ranks"
sleep 20
N=$(sudo docker ps -a --format '{{.Names}}' | grep -c '^glm')
if [ "$N" -eq 4 ]; then echo RANKS-LAUNCHED-4
else echo "LAUNCH-SHORTFALL n=$N"; sudo docker ps -a --format '{{.Names}} {{.Status}}' | grep glm || true; fi