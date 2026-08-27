# GLM-5.3-Flash SWAP RUNBOOK (staged ds4 -> GLM)

## Prerequisites gate (ALL must be true before step 1)
- [ ] four: `.pull_finished` present (hf_dl log "MARKER SET")
- [ ] spread log on primary shows "SPREAD COMPLETE markers set"
- [ ] all 4 sparks: `sudo docker images | grep sglang` non-empty
- [ ] image flag check done non-GPU: sglang.launch_server --help contains
      disaggregation-mode / transfer-backend (or plan A fallback)
- [ ] user given heads-up moment (ds4 downtime ~10-20 min total)

## Step 0 - freeze watchdog + prevent zombie restart
(primary) sudo docker update --restart=no dspark-recipe-vllm-dspark-1
(verify other nodes have their own dspark worker container; repeat there)
touch ~/ds4/WATCH_PAUSED            # if watchdog path exists on hive side

## Step 1 - stop ds4 fleet (REVERSIBLE - never rm)
(primary) sudo docker stop dspark-recipe-vllm-dspark-1
(each node w/ worker) sudo docker stop $(sudo docker ps -q --filter name=dspark)
NOTE: old stack ports freed => 8888 + 25000 now available for GLM.

## Step 2 - launch GLM (choose after --help evidence)
***HELP EVIDENCE R20 (secondary image, 2365-line --help):***
disaggregation-mode {null,prefill,decode} EXISTS; transfer backends are
{mooncake,nixl,ascend,fake,mori,mooncake_tcp} - NO roce (my draft had it
wrong). bootstrap-port takes an INT only; NO --disaggregation-prefill
host:port flag exists in this build => true PD serving also needs a
router/bootstrap registry layer (sgl-router). ATTENTION BACKENDS include
dsa/nsa/dsv4 (relevant to GLM sparse indexer; defaults auto-select).
kv nvfp4 present but SM100+ gated => DO NOT pass it on sm_121.
=> DECISION: launch variant A (TP=4 classic) FIRST; variant B deferred to
phase-2 experiment after stable serve (needs sgl-router setup too).
Speculative: --speculative-algorithm exists (MTP later during tuning).

Option B (EXPERIMENTAL phase-2; script corrected r20):
  variant_b now uses --disaggregation-transfer-backend nixl; removed fake
  --disaggregation-prefill flag; requires sgl-router before useful.
Option A fallback NOW DEFAULT LAUNCH:
  bash variant_a_tp4.sh          # head primary:8888 (+workers .12/.13/.14)
Both scripts staged under hive:~/avo/glm_serve/.

## Step 3 - verify (hive:~/avo/glm_serve/verify_battery.sh $BASE)
- /v1/models lists glm
- 16-token chat probe answers
- n=3 timing sweep (record tok/s vs ds4 baseline ~58-60 single / 135-150 agg)

## Step 4 - decision point
KEEP => leave running; monitoring next; tuning round (nccl/qdisc etc.)
ROLLBACK => sudo docker start dspark-recipe-vllm-dspark-1 (+workers each node);
  restore restart policy: docker update --restart=<old-policy> ; GLM down
  (docker rm -f glm-head glm-w* glm-decode* glm-prefill as needed).

## Post-swap cleanup (any time later)
- exit nodes + dns pins revert per node (see GLM_STAGE_NOTES r17 REVERT SET)
- re-enable watchdog (rm WATCH_PAUSED)
- restore ds4 restart policies if keeping dual-stack option open

## ENGINE GATE RESULT r25 (DECISIVE)
In-image source proof: srt/models/glm5_next.py exports
Glm5NextForConditionalGeneration; glm5_next_nextn.py defines
...NextN(DeepseekV3ForCausalLMNextN) => NATIVE MTP DRAFT SUPPORT.
Tuning flag set (verified in --help):
  --mem-fraction-static X   (start ds4-parity 0.85, then sweep)
  --max-num-seqs N          (ds4 ran 8; push toward 256/1024 in steps)
  --chunked-prefill-size    (default auto)
  --speculative-algorithm (MTP) + --speculative-num-steps /
   --speculative-num-draft-tokens / --speculative-dspark-block-size
TUNING ORDER post-success: mem fraction -> concurrency -> speculative ->
chunked sizes, one at a time, verify battery after each.

## Post-tuning restoration (after stability confirmed - DO NOT rush)
Restore crons incrementally from each node's /tmp/crontab_pre_glm.txt:
1. qwen_watch.sh (three/four) FIRST - unrelated to ds4, keeps those serves alive
2. dspark_watch.sh (primary) ONLY IF deliberately keeping ds4 revival off;
   NEVER re-enable while GLM occupies 8888/25000 - it would fight the port
3. ds4_proxy_watch.sh LAST and only if rolling back to ds4 someday
The two killed supervisors (ds4gw_shadow.py, ds4_ratelimit_proxy.py) belong
to the OLD stack only if rollback ever happens again; otherwise obsolete.
Watchdog files: /home/syeung/ds4/WATCH_PAUSED stays while any crons remain off.

## Hard-won cautions
- pgrep 'docker pull' lies; verify images by `docker images`.
- resolved.conf.d dir must exist BEFORE restart else DNS wipes.
- .pull_finished markers MUST come from verified pipelines only.
- Never write daemon.json or data-root while serving stacks run.
