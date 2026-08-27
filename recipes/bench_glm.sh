#!/bin/bash
# bench_glm.sh - honest usage-token bench: sequential median + concurrency ladder.
# usage: bash bench_glm.sh                        -> full battery, local serve
#        BENCH_URL=http://head:8888 bash bench_glm.sh
#        MODEL_ID=my-alias bash bench_glm.sh      (must match --served-model-name)
URL=${BENCH_URL:-http://127.0.0.1:8888}
MID=${MODEL_ID:-glm-5.3-flash}
python3 -u - "$URL" "$MID" <<'PY'
import json, sys, time, threading, urllib.request

url, mid = sys.argv[1], sys.argv[2]
PROMPT = "Write a detailed story about a lighthouse keeper."
def one(max_tok):
    body = json.dumps({"model": mid,
                       "messages": [{"role": "user", "content": PROMPT}],
                       "max_tokens": max_tok}).encode()
    t0 = time.time()
    r = urllib.request.urlopen(urllib.request.Request(
        f"{url}/v1/chat/completions", data=body,
        headers={"Content-Type": "application/json"}), timeout=900)
    d = json.loads(r.read())
    dt = time.time() - t0
    ct = d.get("usage", {}).get("completion_tokens", 0)
    return dt, ct, (ct / dt if dt > 0 else 0)

print(f"== seq x5 ({mid}) ==")
rates = []
for i in range(5):
    try:
        dt, ct, tps = one(256)
        rates.append(tps)
        print(f"run{i+1}: {ct}tok {dt:.1f}s {tps:.1f}tok/s")
    except Exception as e:
        print(f"run{i+1}: FAIL {type(e).__name__} {str(e)[:60]}")
if rates:
    print("MEDIAN-SEQ-TOKPS: %.1f" % sorted(rates)[len(rates)//2])

for n in (8, 16, 32, 64):
    res = []
    def w():
        try: res.append(one(256))
        except Exception as e: res.append(("F", str(e)[:40]))
    ths = [threading.Thread(target=w) for _ in range(n)]
    t0 = time.time()
    [t.start() for t in ths]; [t.join() for t in ths]
    wall = max(time.time() - t0, 0.001)
    oks = [r for r in res if len(r) == 3]
    tot = sum(r[1] for r in oks)
    per = [r[2] for r in oks]
    agg = tot / wall
    mpersum = (sum(per) / len(per)) if per else 0
    print(f"x{n}: AGG={agg:.0f}tok/s MEAN-PERSTREAM={mpersum:.1f} "
          f"fails={len(res)-len(oks)} wall={wall:.0f}s")
PY
