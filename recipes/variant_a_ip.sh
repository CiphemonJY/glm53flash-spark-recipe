#!/bin/bash
# variant_a_ip.sh - GLM-5.3-Flash TP=4 launch, ranks addressed by fabric IP.
# No hostnames anywhere: serving nodes frequently have no working resolver.
# Workers start first (ranks 1-3), then the head (rank 0, API server).
#
# REQUIRED env (no defaults - set these for YOUR cluster):
#   HEAD_IP      rank-0 node IP; hosts the dist-init endpoint and the API
#   WORKER_IPS   space-separated IPs of the three worker nodes (ranks 1-3)
#
# Optional env (defaults shown):
#   IMAGE        lmsysorg/sglang:glm-5.3-flash
#   MODEL_DIR    /opt/models/GLM-5.3-Flash   host path, mounted ro at /models/GLM-5.3-Flash
#   SERVED_NAME  glm-5.3-flash               model id clients see on /v1/models
#   SERVE_PORT   8888
#   DIST_PORT    25000
#   IFACE        enp1s0f1np1                 NIC carrying the RDMA/fabric traffic
#   HCA_HEAD     =mlx5_1:1                   NCCL_IB_HCA for rank 0
#   HCA_WORKER   =rocep1s0f1:1               NCCL_IB_HCA for ranks 1-3
#   SSH_USER     $USER                       user for cross-node docker calls
#
# The leading '=' in HCA_* is NCCL's exact-match syntax and is part of the
# value; find your per-node devices with `ibdev2netdev`. Leave HCA_* empty to
# let NCCL pick devices itself (fine on single-HCA nodes).
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

echo "head=$HEAD_IP workers=[$WORKER_IPS] model=$MODEL_DIR served-as=$SERVED_NAME"

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
        --attention-backend triton \
        --trust-remote-code --host 0.0.0.0 --port $SERVE_PORT
  else
    ssh -o BatchMode=yes $SSH_USER@$NODEIP "sudo docker rm -f glm-w$RANK >/dev/null 2>&1 && echo RM-GONE-w$RANK; sudo docker run -d --name glm-w$RANK --restart unless-stopped --gpus all --shm-size 32g --net host $ENV_COMMON $EXTRA_HCA -v $MODEL_DIR:/models/GLM-5.3-Flash:ro $IMAGE python3 -m sglang.launch_server --model-path /models/GLM-5.3-Flash --tp-size 4 --nnodes 4 --node-rank $RANK --dist-init-addr $DIS --attention-backend triton --trust-remote-code"
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
echo "$(date +%FT%T) VARIANT-A LAUNCHED all ranks"

# launch verification: the destructive ops above must leave proof
sleep 20
EXPECTED=$((NWORKERS+1))
N=$(sudo docker ps -a --format '{{.Names}}' | grep -c '^glm')
if [ "$N" -eq "$EXPECTED" ]; then echo "RANKS-LAUNCHED-$EXPECTED"
else echo "LAUNCH-SHORTFALL n=$N expected=$EXPECTED"; sudo docker ps -a --format '{{.Names}} {{.Status}}' | grep glm || true; fi
