#!/bin/bash
# variant_a_tuned.sh - variant A + capacity levers. MEASURED, REJECTED on the
# reference cluster: aggregate DROPPED at x16 (44 -> 24 tok/s); deeper
# cuda-graph capture squeezed the fixed KV pool. Kept as a reference for what
# not to repeat - do not run in production. See README "Measured findings".
#   max-running-requests 96      (admission was auto=46)
#   cuda-graph-max-bs-decode 96  (match admission so decodes stay on-graph)
#   chunked-prefill-size 16384   (2x default)
#   schedule-conservativeness 0.9
set -u

: "${HEAD_IP:?set HEAD_IP (rank-0 fabric IP)}"
: "${WORKER_IPS:?set WORKER_IPS (space-separated worker IPs)}"

IMAGE=${IMAGE:-lmsysorg/sglang:glm-5.3-flash}
MODEL_DIR=${MODEL_DIR:-/opt/models/GLM-5.3-Flash}
SERVED_NAME=${SERVED_NAME:-glm-5.3-flash}
SERVE_PORT=${SERVE_PORT:-8888}
DIST_PORT=${DIST_PORT:-25000}
IFACE=${IFACE:-enp1s0f1np1}
HCA_HEAD=${HCA_HEAD:-"=mlx5_1:1"}
HCA_WORKER=${HCA_WORKER:-"=rocep1s0f1:1"}
SSH_USER=${SSH_USER:-$USER}
DIS="$HEAD_IP:$DIST_PORT"
ENV_COMMON="-e NCCL_SOCKET_IFNAME=$IFACE -e GLOO_SOCKET_IFNAME=$IFACE -e MASTER_ADDR=$HEAD_IP -e MASTER_PORT=$DIST_PORT"
TUNED="--max-running-requests 96 --cuda-graph-max-bs-decode 96 --chunked-prefill-size 16384 --schedule-conservativeness 0.9"

run_node(){
  NODEIP=$1; RANK=$2
  if [ "$RANK" = "0" ]; then HCA="$HCA_HEAD"; else HCA="$HCA_WORKER"; fi
  EXTRA_HCA=""
  [ -n "$HCA" ] && EXTRA_HCA="-e NCCL_IB_HCA=$HCA"
  if [ "$NODEIP" = "local" ]; then
    sudo docker rm -f glm-head 2>/dev/null && echo RM-GONE-head || true
    sudo docker run -d --name glm-head --restart unless-stopped \
      --gpus all --shm-size 32g --net host $ENV_COMMON $EXTRA_HCA \
      -v "$MODEL_DIR":/models/GLM-5.3-Flash:ro \
      $IMAGE python3 -m sglang.launch_server \
        --model-path /models/GLM-5.3-Flash \
        --tp-size 4 --nnodes 4 --node-rank 0 \
        --dist-init-addr $DIS \
        --served-model-name $SERVED_NAME \
        --attention-backend triton $TUNED \
        --trust-remote-code --host 0.0.0.0 --port $SERVE_PORT
  else
    ssh -o BatchMode=yes $SSH_USER@$NODEIP "sudo docker rm -f glm-w$RANK >/dev/null 2>&1 && echo RM-GONE-w$RANK; sudo docker run -d --name glm-w$RANK --restart unless-stopped --gpus all --shm-size 32g --net host $ENV_COMMON $EXTRA_HCA -v $MODEL_DIR:/models/GLM-5.3-Flash:ro $IMAGE python3 -m sglang.launch_server --model-path /models/GLM-5.3-Flash --tp-size 4 --nnodes 4 --node-rank $RANK --dist-init-addr $DIS --attention-backend triton $TUNED --trust-remote-code"
  fi
}

NWORKERS=$(echo $WORKER_IPS | wc -w)
RANK=1
for WIP in $WORKER_IPS; do
  run_node "$WIP" "$RANK"
  sleep 3
  RANK=$((RANK+1))
done
run_node local 0
echo "$(date +%FT%T) VARIANT-A-TUNED LAUNCHED all ranks"

sleep 20
EXPECTED=$((NWORKERS+1))
N=$(sudo docker ps -a --format '{{.Names}}' | grep -c '^glm')
if [ "$N" -eq "$EXPECTED" ]; then echo "RANKS-LAUNCHED-$EXPECTED"
else echo "LAUNCH-SHORTFALL n=$N expected=$EXPECTED"; sudo docker ps -a --format '{{.Names}} {{.Status}}' | grep glm || true; fi
