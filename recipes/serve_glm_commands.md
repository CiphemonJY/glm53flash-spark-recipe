# serve_glm_commands.md - GLM-5.3-Flash flags on the sglang image: what maps where

## Flag mapping from a Llama-3.3-70B multi-node vLLM recipe
| Original recipe | GLM-5.3-Flash adaptation |
|---|---|
| `vllm serve meta-llama/...` | sglang docker image `lmsysorg/sglang:glm-5.3-flash` (glm5_next support + kernels that run on sm_121) |
| `--cluster-config-file` YAML | `--tp-size 4 --nnodes 4 --node-rank N --dist-init-addr HEAD_IP:25000` |
| TP=3 mesh + solo node-4 decode | IMPOSSIBLE with ~330 GB of FP8 weights: each instance needs all 4 nodes. Variant A = single TP=4 instance serving :8888 |
| EAGLE draft model | GLM ships a NATIVE MTP draft layer; enable via `--speculative-algorithm NEXTN` (crashes in decode in the image build tested - see README) |
| `--kv-cache-dtype fp8` | LEAVE DEFAULT on sm_121; the nvfp4 option is SM100+-gated (do not pass it) |
| disagg producer/consumer connectors | PD-disaggregation is phase-2: needs sgl-router; transfer backends in the build tested are {mooncake,nixl,ascend,fake,mori,mooncake_tcp} - no roce |
| HAProxy 4 backends | Phase-1: single backend = the head node (see haproxy.cfg) |

## Launch
Use `variant_a_ip.sh` (env-configured: HEAD_IP, WORKER_IPS, MODEL_DIR, ...;
starts workers first, then the head). Manual sketch, rank 0:

    sudo docker run -d --name glm-head --restart unless-stopped \
      --gpus all --shm-size 32g --net host \
      -e NCCL_SOCKET_IFNAME=$IFACE -e GLOO_SOCKET_IFNAME=$IFACE \
      -e MASTER_ADDR=$HEAD_IP -e MASTER_PORT=25000 \
      -v $MODEL_DIR:/models/GLM-5.3-Flash:ro \
      lmsysorg/sglang:glm-5.3-flash python3 -m sglang.launch_server \
      --model-path /models/GLM-5.3-Flash --trust-remote-code \
      --tp-size 4 --nnodes 4 --node-rank 0 \
      --dist-init-addr $HEAD_IP:25000 --attention-backend triton \
      --served-model-name glm-5.3-flash --host 0.0.0.0 --port 8888

Workers: the same without `--host`/`--port`, with `--node-rank 1..3`.

Tip: if this serve replaces another model that clients already target, keep
the OLD `--served-model-name` and no client needs an edit.

## Engine gate - check YOUR image before trusting any of this
    docker run --rm $IMAGE python3 -m sglang.launch_server --help
Confirmed in the build tested (Aug 2026): `--disaggregation-mode
{null,prefill,decode}`, attention backends incl. dsa/nsa/dsv4,
`--speculative-algorithm`. NOT present: a `--disaggregation-prefill
host:port` flag - true PD serving also needs a router/bootstrap registry
layer (sgl-router). Flags drift between builds; verify, don't assume.

## Tuning pass (one lever at a time, bench_glm.sh after each)
1. `--mem-fraction-static` sweep upward only with KV headroom evidence
2. concurrency: the hybrid-KDA mamba state capped real admissions at 21
   (5 state slots/request) on the reference cluster regardless of
   `--max-running-requests` - admission levers fight this ceiling
3. speculative NEXTN (blocked in the image build tested; kept in
   variant_c_spec.sh for a newer image)
4. `--chunked-prefill-size`

## Network tuning order
1. `tune_network_SAFE.sh` on every node - safe beside a live serve
2. `tune_network_FULL_swapwindow.sh` only inside a stop window (ethtool -G
   pauses the queue)
Measured on the reference fabric: buffer tuning alone moved a single-flow
ssh stream 66 -> 385 MB/s.
