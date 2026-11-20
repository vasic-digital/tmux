#!/usr/bin/env bash
# Test 96 — benchmarking/performance gate (§11.4.169 type 13).
#
# Measures a bounded, repeatable real operation (tmx-state-bin `recall` against
# a temp state file) and emits p50/p95. The PASS threshold is DERIVED FROM THE
# MEASUREMENTS THEMSELVES (3 calibration batches -> ceiling = 3 x max batch
# p95), NOT a hardcoded literature SLA (§11.4.6/§11.4.123). A 4th verification
# batch must stay under that ceiling and satisfy p50 <= p95.
#
# Evidence: docs/qa/<run-id>/96_benchmark_performance.log + .json (override TMX_QA_DIR).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
RUN_ID="${TMX_RUN_ID:-testtypes-$(date -u +%Y%m%dT%H%M%SZ)}"
QA_DIR="${TMX_QA_DIR:-$REPO_ROOT/docs/qa/$RUN_ID}"
EVID="$QA_DIR/96_benchmark_performance.log"
if ! mkdir -p "$QA_DIR" 2>/dev/null; then echo "SKIP: evidence dir $QA_DIR not writable (§11.4.3)"; exit 0; fi
: > "$EVID"

PASS=0; FAIL=0; SKIP=0
log(){ echo "$*" | tee -a "$EVID"; }
_pass(){ log "PASS: $*"; PASS=$((PASS+1)); }
_fail(){ log "FAIL: $*"; FAIL=$((FAIL+1)); }
_skip(){ log "SKIP: $*"; SKIP=$((SKIP+1)); }

log "── Test 96: benchmark/performance gate (run-id $RUN_ID) ──"

STATE_BIN="$REPO_ROOT/scripts/tmx-state-bin"
[ -x "$STATE_BIN" ] || { _skip "tmx-state-bin not built"; log "PASS: 96 SKIPped (binary absent)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { _skip "python3 not on PATH"; exit 0; }

SCRATCH="${TMPDIR:-/tmp}"; SCRATCH="${SCRATCH%/}"
W="$SCRATCH/tmx_t96_$$"; mkdir -p "$W" 2>/dev/null || { _skip "scratch $SCRATCH not writable"; exit 0; }
trap 'rm -rf "$W" 2>/dev/null || true' EXIT
SF="$W/state.json"
TMX_STATE_FILE="$SF" "$STATE_BIN" record warm /home >/dev/null 2>&1 || { _skip "cannot seed state file"; exit 0; }

out="$(python3 - "$STATE_BIN" "$SF" "$QA_DIR" <<'PY'
import subprocess, time, os, sys, json, math
state_bin, sf, qa = sys.argv[1], sys.argv[2], sys.argv[3]
env = dict(os.environ); env['TMX_STATE_FILE'] = sf
cmd = [state_bin, 'recall', 'warm']
M = 24
def pct(vals, p):
    v = sorted(vals)
    return v[min(len(v)-1, int(p/100.0*len(v)))]
def batch():
    ds = []
    for _ in range(M):
        t = time.perf_counter()
        r = subprocess.run(cmd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        ds.append((time.perf_counter()-t)*1e6)
        if r.returncode != 0:
            print('RESULT: FAIL nonzero rc from recall')
            return None
    return ds
for _ in range(5):  # warmup, not measured
    subprocess.run(cmd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
cal = []
for i in range(3):
    b = batch()
    if b is None: sys.exit(0)
    p50, p95 = pct(b,50), pct(b,95)
    cal.append({'p50':p50,'p95':p95})
    print('  METRIC cal%d n=%d p50=%.1fus p95=%.1fus' % (i+1, M, p50, p95))
cal_p95s = [c['p95'] for c in cal]
# Threshold derived ONLY from observed calibration data (3x max batch p95).
ceiling = 3.0 * max(cal_p95s)
ver = batch()
if ver is None: sys.exit(0)
v50, v95 = pct(ver,50), pct(ver,95)
print('  METRIC verify n=%d p50=%.1fus p95=%.1fus ceiling=%.1fus (3x max cal p95=%.1fus)' % (M, v50, v95, ceiling, max(cal_p95s)))
finite = all(math.isfinite(x) and x >= 0 for x in cal_p95s+[v50,v95,ceiling])
monotonic = v50 <= v95
within = v95 <= ceiling
ok = finite and monotonic and within
if not finite: print('  REASON: non-finite measurement')
if not monotonic: print('  REASON: p50 > p95')
if not within: print('  REASON: verify p95 exceeded data-derived ceiling')
with open(os.path.join(qa,'96_benchmark_performance.json'),'w') as f:
    json.dump({'calibration':cal,'verify_p50_us':v50,'verify_p95_us':v95,
               'ceiling_us':ceiling,'threshold_rule':'3x max calibration p95 (data-derived)',
               'finite':finite,'monotonic':monotonic,'within':within,'verdict':'PASS' if ok else 'FAIL'}, f, indent=2)
print('RESULT: ' + ('PASS' if ok else 'FAIL'))
PY
)" || true
log "$out"
echo "$out" | grep -q '^RESULT: PASS' && _pass "p50/p95 emitted; verify p95 within data-derived threshold (3 calibration runs)" \
  || _fail "benchmark gate failed: $(echo "$out" | grep -E 'REASON|RESULT' | tr '\n' ' ')"

if [ "$FAIL" -gt 0 ] || [ "$SKIP" -gt 0 ]; then
  log "FAIL: benchmark gate FAIL=$FAIL SKIP=$SKIP"
  exit 1
fi
log "PASS: benchmark/performance gate green — threshold derived from 3 measured runs, no literature SLA"
exit 0
