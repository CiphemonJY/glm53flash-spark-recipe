# serve_glm_commands.md - Llama recipe swapped to GLM-5.3-Flash (real flags)

## What changed in the swap (and why)
| Recipe (Llama-3.3-70B) | GLM fleet adaptation |
|---|---|
| vllm serve meta-llama/... | sglang docker image glm-5.3-flash (only engine w/ glm5_next + validated kernels for sm_121) |
| --cluster-config-file YAML | sglang: --tp-size 4 --nnodes 4 --node-rank N --dist-init-addr 192.168.88.11:25000 |
| TP=3 mesh + solo node4 decode | IMPOSSIBLE with 330GB FP8 weights: each instance needs all 4 nodes. Variant A = single TP=4 instance serving :8888 |
| EAGLE draft model | GLM ships NATIVE MTP weights; enable later via --speculative-algorithm MTP (+ draft args per --help) during tuning pass |
| --kv-cache-dtype fp8 | LEAVE DEFAULT on sm_121; nvfp4 flag exists but SM100+-gated (do not pass) |
| NixlConnector producer/consumer | PD-disagg is PHASE-2: needs sgl-router bootstrap registry (help shows no prefill-addressing CLI flag); transfer backends {mooncake,nixl,...} |
| HAProxy 4 backends | Phase-1 single backend primary:8888; phase-2 adds decode instances |

## Step A equivalent - launch variant A (AFTER swap window step 1)
Primary (=head, rank0):
    sudo docker rm -f glm-head 2>/dev/null || true
    sudo docker run -d --name glm-head --restart unless-stopped \
      --gpus all --shm-size 32g --net host \
      -v /home/syeung/models/GLM-5.3-Flash:/models/GLM-5.3-Flash:ro \
      lmsysorg/sglang:glm-5.3-flash python3 -m sglang.launch_server \
      --model-path /models/GLM-5.3-Flash --trust-remote-code \
      --tp-size 4 --nnodes 4 --node-rank 0 \
      --dist-init-addr 192.168.88.11:25000 --host 0.0.0.0 --port 8888
Workers secondary/.12 three/.13 four/.14: same with --node-rank 1..3
(headless, no --host/--port). Scripted: hive:~/avo/glm_serve/variant_a_tp4.sh

## Step B equivalent
NONE in phase-1 (single instance spans all nodes; nothing "dedicated" left).
Phase-2 PD sketch lives in variant_b_pddisagg.sh (needs sgl-router first).

## Step C equivalent - gateway (optional now, recommended at phase-2)
    sudo haproxy -c -f /etc/haproxy/haproxy.cfg && sudo systemctl restart haproxy

## Tuning pass (post-stability, honors ds4 baseline ambitions)
- --max-num-seqs toward 1024 (ds4 ran only 8!)
- speculative: --speculative-algorithm MTP n=3..5 sweep (graph size formula!)
- mem fraction sweep 0.85 -> 0.90 if KV headroom shows
- verify_battery.sh n=3 timing vs ds4 baseline ~58-60 tok/s single / 135-150 agg

## Network tuning state (recipe absorbed)
- buffers APPLIED all nodes (rmem/wmem 128MB max): verified fabric ssh
  stream 66 -> 385 MB/s single-flow (6x!).
- ring buffers (ethtool -G rx4096 tx4096): swap-window script ready
  tune_network_FULL_swapwindow.sh; mtu already 9000 everywhere.
