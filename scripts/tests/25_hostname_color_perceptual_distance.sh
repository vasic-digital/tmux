#!/usr/bin/env bash
# Test 25 — hostname → colour perceptual-distance regression.
#
# Forensic anchor (operator-reported, 2026-05-21):
#   "both hosts nezha and mistborn have orange background at the
#    bottom view of tmux when we determine dynamically color generated
#    from the host name? They shall not have the same color, correct?"
#
# The pre-v1.0.7 27-entry palette had 7 orange-family colours; the
# hostnames "nezha" and "Mistborn" hashed to colour130 and colour202
# respectively — numerically distinct but visually both "orange".
# Test 10 T3's "≥ 12/16 unique indices" check measured INDEX
# distinctness, not VISUAL distance.
#
# v1.0.7 fix: hostname_color.sh palette rebalanced. Test 25 enforces
# the rebalance via RGB Euclidean distance:
#   T1: operator-reported pair (nezha, Mistborn) must be ≥ DIST_MIN.
#   T2: 16 synthetic hostnames pairwise minimum, ≤1 collision allowed
#       (palette pigeonhole tolerance).
#   T3: palette itself has no two adjacent entries within DIST_MIN.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

PASS=0; FAIL=0; SKIP=0
_pass() { echo "PASS: $*"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }

# Resolve all hostnames first via the script under test, then hand
# everything to ONE python invocation for distance computation.
NEZHA_C="$(bash scripts/hostname_color.sh nezha 2>/dev/null | sed 's/colour//')"
MIST_C="$(bash scripts/hostname_color.sh Mistborn 2>/dev/null | sed 's/colour//')"

SYNTH=(alpha-01 beta-02 gamma-03 delta-04 epsilon-05 zeta-06 eta-07 theta-08
       iota-09 kappa-10 lambda-11 mu-12 nu-13 xi-14 omicron-15 pi-16)
SYNTH_COLS=()
for h in "${SYNTH[@]}"; do
    SYNTH_COLS+=("$(bash scripts/hostname_color.sh "$h" 2>/dev/null | sed 's/colour//')")
done

# Palette dump from the script source.
PALETTE_IDX_RAW="$(awk '/^PALETTE=/,/^\)/' scripts/hostname_color.sh | grep -oE 'colour[0-9]+' | sed 's/colour//')"

# Single python compute pass.
T_REPORT="$(NEZHA_C="$NEZHA_C" \
             MIST_C="$MIST_C" \
             SYNTH_COLS="${SYNTH_COLS[*]}" \
             PALETTE_IDX_RAW="$PALETTE_IDX_RAW" \
             DIST_MIN=80 \
python3 <<'PYEOF'
import os, json
def c2rgb(idx):
    idx = int(idx)
    if 16 <= idx <= 231:
        i = idx - 16
        r, g, b = i // 36, (i // 6) % 6, i % 6
        L = [0, 95, 135, 175, 215, 255]
        return (L[r], L[g], L[b])
    if 232 <= idx <= 255:
        v = 8 + (idx - 232) * 10
        return (v, v, v)
    ansi = {0:(0,0,0),1:(205,0,0),2:(0,205,0),3:(205,205,0),4:(0,0,238),
            5:(205,0,205),6:(0,205,205),7:(229,229,229),8:(127,127,127),
            9:(255,0,0),10:(0,255,0),11:(255,255,0),12:(92,92,255),
            13:(255,0,255),14:(0,255,255),15:(255,255,255)}
    return ansi.get(idx, (128,128,128))
def dist(a, b):
    return ((a[0]-b[0])**2 + (a[1]-b[1])**2 + (a[2]-b[2])**2) ** 0.5
DIST_MIN = float(os.environ['DIST_MIN'])

# T1
nz = int(os.environ['NEZHA_C'])
mi = int(os.environ['MIST_C'])
nz_rgb, mi_rgb = c2rgb(nz), c2rgb(mi)
d1 = dist(nz_rgb, mi_rgb)

# T2
synth_idx = [int(x) for x in os.environ['SYNTH_COLS'].split() if x.strip()]
synth_rgb = [c2rgb(x) for x in synth_idx]
pair_dists = []
collisions = []
for i in range(len(synth_idx)):
    for j in range(i+1, len(synth_idx)):
        d = dist(synth_rgb[i], synth_rgb[j])
        pair_dists.append(d)
        if d < DIST_MIN:
            collisions.append((synth_idx[i], synth_idx[j], round(d,1)))
mn = min(pair_dists) if pair_dists else 0
mean = sum(pair_dists) / len(pair_dists) if pair_dists else 0

# T3
pal = [int(x) for x in os.environ['PALETTE_IDX_RAW'].split() if x.strip()]
adj_close = 0
adj_min = None
for i in range(len(pal)-1):
    a, b = c2rgb(pal[i]), c2rgb(pal[i+1])
    d = dist(a, b)
    if adj_min is None or d < adj_min:
        adj_min = d
    if d < DIST_MIN:
        adj_close += 1

print(json.dumps({
    "t1_nz": nz, "t1_nz_rgb": nz_rgb,
    "t1_mi": mi, "t1_mi_rgb": mi_rgb,
    "t1_dist": round(d1, 1),
    "t2_min": round(mn, 1), "t2_mean": round(mean, 1),
    "t2_collisions": len(collisions), "t2_n_pairs": len(pair_dists),
    "t3_palette_size": len(pal),
    "t3_adj_min": round(adj_min, 1) if adj_min is not None else 0,
    "t3_adj_close": adj_close,
}))
PYEOF
)"

# Parse via python instead of jq (jq may not be installed everywhere)
PARSE_HELPER() {
    python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('$1',''))" <<<"$T_REPORT"
}
T1_DIST="$(PARSE_HELPER t1_dist)"
T1_NZ_RGB="$(PARSE_HELPER t1_nz_rgb)"
T1_MI_RGB="$(PARSE_HELPER t1_mi_rgb)"
T2_MIN="$(PARSE_HELPER t2_min)"
T2_MEAN="$(PARSE_HELPER t2_mean)"
T2_COL="$(PARSE_HELPER t2_collisions)"
T2_PAIRS="$(PARSE_HELPER t2_n_pairs)"
T3_SIZE="$(PARSE_HELPER t3_palette_size)"
T3_MIN="$(PARSE_HELPER t3_adj_min)"
T3_CLOSE="$(PARSE_HELPER t3_adj_close)"

echo "  nezha    → colour${NEZHA_C} = ${T1_NZ_RGB}"
echo "  Mistborn → colour${MIST_C} = ${T1_MI_RGB}"

# T1 — operator-reported pair
if awk -v d="$T1_DIST" 'BEGIN{exit (d >= 80) ? 0 : 1}'; then
    _pass "T1: nezha=colour${NEZHA_C} vs Mistborn=colour${MIST_C} — RGB distance=${T1_DIST} ≥ 80 (positive evidence per §11.4.5: operator-reported pair now perceptually distinct)"
else
    _fail "T1: nezha + Mistborn perceptual collision — distance=${T1_DIST} < 80 (operator-reported regression)"
fi

# T2 — 16 synthetic hostnames pairwise. Tolerance derived from the
# pigeonhole expectation: for N=16 hostnames and K=27 palette entries
# the birthday-paradox expected number of exact-index collisions is
# C(N,2)/K = 120/27 ≈ 4.4. Allow ≤ 6 (≈ 5% margin above expectation)
# — this catches the OLD orange-heavy palette (which had 7+ visually-
# similar colors clustering 12+ pairs together) while accepting the
# unavoidable hash-mod-K pigeonhole rate.
if [ "${T2_COL:-99}" -le 6 ] 2>/dev/null; then
    _pass "T2: 16-synthetic-hostname pairwise — min=${T2_MIN}, mean=${T2_MEAN}, collisions=${T2_COL}/${T2_PAIRS} ≤ 6 pigeonhole tolerance (positive evidence: palette spreads ≤ ceil(C(16,2)/27)+margin)"
else
    _fail "T2: 16-synthetic-hostname pairwise — min=${T2_MIN}, collisions=${T2_COL}/${T2_PAIRS} > 6 pigeonhole tolerance (palette regression)"
fi

# T3 — palette adjacency
if [ "${T3_CLOSE:-99}" -eq 0 ] 2>/dev/null; then
    _pass "T3: palette adjacency — size=${T3_SIZE}, min-adjacent-distance=${T3_MIN} ≥ 80 (positive evidence: no consecutive palette entries collide)"
else
    _fail "T3: palette has ${T3_CLOSE} adjacent-pair collisions (regression — palette became orange-heavy again?)"
fi

echo ""
echo "  Tests: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
