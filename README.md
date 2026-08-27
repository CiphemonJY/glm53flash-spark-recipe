# glm53flash-spark-recipe

Serving recipe for `zai-org/GLM-5.3-Flash` on a 4-node DGX Spark GB10 cluster
(sm_121, 128 GB unified memory per node), using the dedicated SGLang image
`lmsysorg/sglang:glm-5.3-flash` with TP=4 over a RoCE fabric. This replaced a
DeepSeek-V4-Flash vLLM TP=4 serve on the same hardware, keeping its model alias
(`deepseek-v4-flash-dspark`) so clients needed no edits.

## Model facts (from `config.json` on the cluster)

- `Glm5NextForConditionalGeneration`, text model `glm5_next_text`, native FP8
  (e4m3, dynamic activations, weight blocks 128x128), bfloat16 activations.
- 45 layers: 3 dense + 42 MoE. 288 routed experts + 1 shared, top-8 routing
  (`noaux_tc`, sigmoid scoring), moe_intermediate 2048, dense intermediate 12288.
- Hybrid attention: 34 KDA linear-attention layers + 11 DeepSeek-style sparse
  MLA layers (index_topk 2048, 32 indexer heads).
- max_position_embeddings 1,048,576. vocab_size 154,880.
- 1 native MTP draft layer (`num_nextn_predict_layers: 1`).
- 320B total / ~18B active parameters is the upstream card figure, not a
  field in `config.json`. Weights are ~330 GB across 62 safetensors shards.

## Layout

| Path | Purpose |
|---|---|
| `recipes/cluster_nodes.yaml` | Authoritative cluster map (fabric IPs 192.168.88.11-.14, CRS812 switch, MTU 9000) |
| `recipes/variant_a_ip.sh` | **Canonical production launch** — TP=4, all ranks by IP, `--attention-backend triton`, served under the ds4 alias |
| `recipes/variant_a_tuned.sh` | Capacity levers on top of A (max-running 96, graph bs 96, chunked prefill 16384) — measured, rejected |
| `recipes/variant_c_spec.sh` | Native MTP (NEXTN) speculative trial — blocked by this image build, see verdicts |
| `recipes/variant_d_adm96.sh` | Isolated admission bump (max-running 96 only) — conditional option |
| `recipes/serve_glm_commands.md` | Llama-recipe → GLM flag translation, launch + tuning notes |
| `recipes/haproxy.cfg` | Gateway config, phase-1 single backend |
| `recipes/tune_network_SAFE.sh` | TCP buffer sysctls (safe beside a live serve) |
| `recipes/tune_network_FULL_swapwindow.sh` | Ring buffers + MTU (swap window only; pauses the queue) |
| `recipes/post_swap_revert_net.sh` | Revert the staging-era DNS/exit-node workarounds |
| `recipes/fire2.sh` | Detached launcher + 40 s inspection for variant A |
| `recipes/bench_glm.sh` | Sequence + concurrency bench, usage-token counted |
| `glm_swap_runbook.md` | Full swap runbook: gates, watchdog freeze, rollback, watchdog restoration |

## Configuration verdicts (all measured on this cluster)

- **BASE (`variant_a_ip.sh`) is canonical.** Single-stream 7.5 tok/s;
  aggregate x8 = 32, x16 = 42, x32 = 57, x64 = 81 tok/s (warm ladder,
  zero failures, ±10% noise band). Same-harness ds4 reference: 27.1 tok/s
  single-stream, ~135-150 aggregate. GLM favors concurrency over
  single-stream under the Triton backend.
- **B (capacity levers) rejected**: aggregate dropped at x16 (44 → 24).
- **D (admission 96 only)** wins mid-concurrency (~+15% at x16), loses
  high concurrency (~-10% at x64). Reasonable pick for workloads
  clustering at ≤24 streams.
- **C (NEXTN spec decode) blocked at code level**: this image build's
  `TritonAttenBackend.forward_decode()` lacks the `topk_indices` kwarg that
  eagle-verify passes. Revisit with a newer sglang image.

## GB10 / sm_121 cautions

- Pass `--attention-backend triton` on every rank. The auto-selected
  flashinfer trtllm DSA backend crashes at cuda-graph capture on sm_121.
- Do NOT pass `--kv-cache-dtype nvfp4` — it is SM100+-gated in this build.
- Hybrid-KDA mamba state caps `max_running_requests` at 21 (5 slots per
  request) regardless of scheduler flags; admission levers fight this ceiling.
- Cold boots run ~13-20 min of Triton JIT before first token.
- Per-rank NCCL HCA pinning is required: head `=mlx5_1:1`, workers
  `=rocep1s0f1:1`, with `NCCL/GLOO_SOCKET_IFNAME=enp1s0f1np1`.

## Requirements

- 4× DGX Spark GB10, weights present on every node at
  `/home/syeung/models/GLM-5.3-Flash` (TP ranks load from local caches; there
  is no shared filesystem).
- `lmsysorg/sglang:glm-5.3-flash` arm64 image on each node. The nodes have no
  external egress — ship the image with `docker save | ssh | docker load`.
- TCP buffer tuning (`tune_network_SAFE.sh`) measured a 66 → 385 MB/s
  single-flow SSH gain over the fabric.
