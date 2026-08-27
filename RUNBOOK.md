# RUNBOOK - bring up GLM-5.3-Flash, or replace an existing serve

General procedure for a 4-node TP=4 serve of GLM-5.3-Flash on the sglang
image. Substitute your own container names, ports, and monitoring in the
places marked.

## Gates - ALL true before touching a running serve

- [ ] weights complete on all 4 nodes and identical (verify per-file sizes or
      hashes - not `du` alone; a rank holding a different revision boots fine
      and emits subtly wrong tokens forever)
- [ ] image present on all 4 nodes: `sudo docker images`
- [ ] API port and dist-init port free on the head (8888 / 25000 by default)
- [ ] engine gate done from YOUR image, without grabbing GPUs:
      `docker run --rm $IMAGE python3 -m sglang.launch_server --help`
      (flags drift between builds - verify, don't assume)
- [ ] users warned about the downtime window (cold boot is 13-20 min)

## Step 0 - freeze existing automation

If anything else lives on these nodes - a previous serve, watchdogs, cron
respawners, restart policies - switch it ALL off first, or it will resurrect
its workload mid-boot and OOM-collide with yours:

- `sudo docker update --restart=no <existing-serve-container>` (keep the
  container; stopping is reversible, removing is not)
- pause watchdog/cron entries; back up the crontab you are changing
- snapshot every restart policy you change, for restore

## Step 1 - stop the previous serve (reversible)

    sudo docker stop <containers...>

Stopped-but-not-removed containers are your rollback. With the old stack
stopped, the API and dist-init ports are free.

## Step 2 - launch GLM (variant A)

From the head node:

    HEAD_IP=<head-fabric-ip> WORKER_IPS="<w1> <w2> <w3>" MODEL_DIR=<host-path> \
      bash recipes/variant_a_ip.sh

Expect `RANKS-LAUNCHED-4`. Then wait out the Triton JIT (13-20 min cold).

## Step 3 - verify

    curl -s http://$HEAD_IP:8888/v1/models            # model id present
    # 16-token chat probe at temperature 0 - coherent answer, deterministic
    MODEL_ID=<served-name> bash recipes/bench_glm.sh  # record your baseline

## Step 4 - decision point

- KEEP: proceed to step 5.
- ROLLBACK: remove the GLM containers (`glm-head`, `glm-w1..3`), then
  `sudo docker start` the old containers and restore their restart policies
  from the step-0 snapshot.

## Step 5 - post-stability

Re-enable what you froze in step 0 ONE piece at a time, benching between.
Never re-arm a previous serve's watchdog while GLM holds its ports - it will
see the port as dead and fight for it.

Tuning order: mem fraction -> concurrency -> speculative -> chunk sizes, one
lever at a time, `bench_glm.sh` after each. Expect the mamba-state admission
ceiling described in the README.

## Cautions (each of these bit someone)

- `pgrep docker pull` lies; verify images with `docker images`.
- If you touch DNS drop-ins: the `resolved.conf.d` directory must exist BEFORE
  a systemd-resolved restart, or a stub placed there is wiped.
- Never edit `daemon.json` or the docker data-root while serving stacks run.
- The dist-init port (25000) is a common default for other distributed stacks;
  free it before launching.
- `ethtool -G` pauses the NIC queue: ring-buffer tuning only in a stop window.
