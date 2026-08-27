# GLM-5.3-Flash on 4x DGX Spark (GB10) - TP=4 serving recipe

Reference recipe for serving `zai-org/GLM-5.3-Flash` with SGLang on a
four-node NVIDIA DGX Spark cluster (GB10, sm_121, 128 GB unified memory per
node): one instance, tensor parallel 4, RoCE fabric. Includes launch scripts,
network tuning, a benchmark, and an operations runbook.

Everything deployment-specific is env-driven (`HEAD_IP`, `WORKER_IPS`,
`MODEL_DIR`, ...) - no script here is hardcoded to the cluster the measurements
come from. All numbers below were measured on that cluster (4x GB10, image
`lmsysorg/sglang:glm-5.3-flash`, August 2026) and are reference points, not
guarantees. The method is described so you can reproduce them on yours.

## The model (from its config.json)

- `Glm5NextForConditionalGeneration`, text model `glm5_next_text`
- native FP8 weights (e4m3, dynamic activations, 128x128 weight blocks),
  ~330 GB across 62 safetensors shards. Upstream card: 320B total / ~18B active.
- 45 layers: 3 dense + 42 MoE; 288 routed + 1 shared expert, top-8 routing
- hybrid attention: 34 KDA linear-attention layers + 11 DeepSeek-style
  sparse-MLA layers (index_topk 2048, 32 indexer heads)
- context 1,048,576; vocab 154,880; 1 native MTP draft layer
- multimodal (vision tower present)

## Requirements

- 4x DGX Spark GB10. Physics: ~330 GB of FP8 weights against 128 GB of unified
  memory per node means every serving instance needs ALL FOUR nodes - a
  "3-node mesh plus a dedicated decode node" cannot hold the model.
- Weights present on every node's local disk (TP ranks load from local caches;
  there is no shared filesystem). The launcher mounts them read-only at
  `/models/GLM-5.3-Flash`; any host path works via `MODEL_DIR`.
- The arm64 `lmsysorg/sglang:glm-5.3-flash` image on every node. If the nodes
  have no external egress, ship it with `docker save | ssh | docker load`.
- From the head node: key-based SSH to each worker with `sudo docker` rights
  (the launcher starts the worker containers remotely).
- Upstream also lists vLLM >= 0.27 as an engine option. Not tested here; the
  SGLang image is what this recipe validated on sm_121.

## Quick start

```bash
# 0. optional, safe beside a live serve: TCP buffer tuning (all nodes)
bash recipes/tune_network_SAFE.sh

# 1. launch variant A from the head node (workers first, then rank 0)
HEAD_IP=10.0.0.11 WORKER_IPS="10.0.0.12 10.0.0.13 10.0.0.14" \
MODEL_DIR=/data/GLM-5.3-Flash \
bash recipes/variant_a_ip.sh          # expect: RANKS-LAUNCHED-4

# 2. wait out the cold boot (13-20 min Triton JIT on this hardware), then
curl -s http://$HEAD_IP:8888/v1/models

# 3. measure
MODEL_ID=glm-5.3-flash bash recipes/bench_glm.sh
```

Full bring-up / replace-an-existing-serve procedure: [RUNBOOK.md](RUNBOOK.md).

## Measured findings (this hardware + image build)

| Config | seq | x8 | x16 | x32 | x64 (agg tok/s) | Verdict |
|---|---|---|---|---|---|---|
| A - BASE (`variant_a_ip.sh`) | 7.5 | 32 | 42 | 57 | 81 | canonical |
| B - capacity levers | 6.4 | - | 24 | - | - | rejected |
| C - NEXTN spec decode | - | - | - | - | - | blocked (code-level) |
| D - admission 96 only | 6.8 | 34 | 51 | 59 | 73 | conditional |

- Harness: `recipes/bench_glm.sh` - fixed prompt, 256-token completions,
  throughput from `usage.completion_tokens` (not estimates), warm server,
  5-run median for sequential, zero failed requests in the reported ladders,
  run-to-run noise about +/-10%.
- For scale, the DeepSeek-V4-Flash vLLM TP=4 serve that previously ran on this
  cluster measured 27.1 tok/s single-stream under this same harness. Its
  aggregate was not re-measured with this harness.
- Under the triton attention backend this model favors concurrency over
  single-stream: aggregate keeps climbing to x64 while single-stream stays low.
- B's deeper cuda-graph capture squeezed the fixed KV pool and dropped
  aggregate; D (admission alone) is a reasonable pick only for workloads
  clustering at <= 24 concurrent streams.
- C crashes in decode under the required triton backend: this image build's
  `TritonAttenBackend.forward_decode()` lacks the `topk_indices` kwarg that
  eagle-verify passes. Re-test on a newer image (`variant_c_spec.sh`).

## sm_121 cautions

- Pass `--attention-backend triton` on every rank. The auto-selected
  flashinfer trtllm DSA backend crashes at cuda-graph capture on sm_121.
- Do not pass `--kv-cache-dtype nvfp4` - SM100+-gated in this build.
- The hybrid-KDA mamba state capped real admissions at 21 (5 state slots per
  request) regardless of `--max-running-requests`. Admission levers fight this
  ceiling; expect it until an engine version changes the accounting.
- Cold boots run ~13-20 minutes of Triton JIT before the first token.
- Pin `NCCL_IB_HCA` per rank with NCCL's exact-match syntax (leading `=`),
  e.g. `=mlx5_1:1` on one node and `=rocep1s0f1:1` on another - device names
  differ per node; find them with `ibdev2netdev`. Wrong pins fail silently:
  all ranks block in comm-init for minutes with no error.
- Network: TCP buffer sysctls (`tune_network_SAFE.sh`) alone moved a
  single-flow SSH stream from 66 to 385 MB/s on the reference fabric
  (2x 200-Gbps-class links per node, jumbo MTU 9000). Ring-buffer changes
  (`ethtool -G`) pause the queue - stop-window only.

## Files

| Path | Purpose |
|---|---|
| `recipes/variant_a_ip.sh` | Canonical TP=4 launch (env-configured) |
| `recipes/variant_a_tuned.sh` | Capacity levers - measured, rejected; reference only |
| `recipes/variant_c_spec.sh` | Native MTP (NEXTN) - blocked in this image build; re-test on newer |
| `recipes/variant_d_adm96.sh` | Admission-only bump - conditional win at <= 24 streams |
| `recipes/serve_glm_commands.md` | Flag mapping from a Llama multi-node recipe, manual launch sketch, engine gate |
| `recipes/cluster_nodes.yaml` | Cluster map template (placeholders) + sharding physics note |
| `recipes/haproxy.cfg` | Optional gateway, single-backend phase-1 |
| `recipes/tune_network_SAFE.sh` | TCP buffer sysctls, safe beside a live serve |
| `recipes/tune_network_FULL_swapwindow.sh` | Ring buffers + MTU, stop-window only |
| `recipes/fire2.sh` | Detached launch + 40 s inspection |
| `recipes/bench_glm.sh` | Sequential + concurrency ladder, usage-token counted |
| `RUNBOOK.md` | Bring-up, verify, replace-an-existing-serve, rollback |

## Scope and method

One cluster, one image build, one model revision. Each verdict row is a warm
ladder on the same server with the stated harness; the absolute numbers belong
to that machine, the deltas between configs are the part expected to transfer.
Topology and tuning approach were adapted from an internal multi-node
Llama-3.3-70B vLLM recipe; flags were verified against the image's own
`--help` rather than assumed.
