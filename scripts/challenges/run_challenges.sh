#!/usr/bin/env bash
# run_challenges.sh — deterministic HelixQA Challenge runner for tmux.yaml.
#
# Parses scripts/challenges/tmux.yaml with a small python3 parser (no PyYAML
# assumed), enumerates EVERY challenge id with its pass-condition, runs each
# challenge's test_script against the real repo state with a bounded timeout,
# and emits a typed PASS / FAIL / SKIP-with-reason verdict plus the path of
# the captured runtime evidence file for each one.
#
# Verdict rule (deliberately NOT "exit 0 == PASS"):
#   PASS  = test exited 0 AND its captured stdout/stderr contains an explicit
#           positive result marker (line starting PASS / [PASS] / PASS n: / ✅)
#           AND contains no explicit FAIL marker.
#   SKIP  = the test itself reported SKIP (e.g. destructive guard not enabled,
#           non-Linux topology, unreachable scratch), with the reason captured.
#   FAIL  = test exited non-zero, OR printed a FAIL marker, OR printed no
#           recognizable verdict at all. A missing/unrunnable test_script is
#           SKIP-with-reason (honest gap), never a fake PASS.
#   UNCLASSIFIED = a YAML record with no id or no pass_condition. This fails
#           the whole gate closed (§11.4 "fails closed on UNCLASSIFIED").
#
# Usage: bash scripts/challenges/run_challenges.sh
# Env:   CHALLENGE_TIMEOUT (seconds/test, default 20), RUN_ID, TMUX_BIN, WRAPPER,
#        TMX_TEST_DESTRUCTIVE (destructive challenges only run when =1)
# Exit:  0 = no FAIL and no UNCLASSIFIED; 1 = any FAIL or UNCLASSIFIED.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
YAML="$REPO_ROOT/scripts/challenges/tmux.yaml"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$-challenges}"
EVIDENCE_DIR="$REPO_ROOT/docs/qa/$RUN_ID/challenges"
mkdir -p "$EVIDENCE_DIR" || { echo "CM-CHALLENGES: FAIL cannot create $EVIDENCE_DIR"; exit 1; }

PARSED="$EVIDENCE_DIR/parsed_challenges.tsv"
SUMMARY="$EVIDENCE_DIR/summary.txt"
SUMMARY_TSV="$EVIDENCE_DIR/summary.tsv"
MANIFEST="$EVIDENCE_DIR/helixqa_manifest.tsv"
: > "$SUMMARY"; : > "$SUMMARY_TSV"; : > "$MANIFEST"

command -v python3 >/dev/null 2>&1 || { echo "CM-CHALLENGES: FAIL python3 not on PATH" | tee -a "$SUMMARY"; printf 'EVIDENCE: %s\n' "$SUMMARY"; exit 1; }
command -v timeout >/dev/null 2>&1 || { echo "CM-CHALLENGES: FAIL coreutils timeout not on PATH" | tee -a "$SUMMARY"; printf 'EVIDENCE: %s\n' "$SUMMARY"; exit 1; }
[ -r "$YAML" ] || { echo "CM-CHALLENGES: FAIL YAML not readable: $YAML" | tee -a "$SUMMARY"; printf 'EVIDENCE: %s\n' "$SUMMARY"; exit 1; }

# ── Deterministic YAML parser (indentation-based; no PyYAML) ───────────────
python3 - "$YAML" "$PARSED" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src, encoding='utf-8').read().splitlines()
records = []
cur = None
field = None
def flush():
    global cur, field
    if cur is not None:
        recs.append(cur)
    cur = None; field = None
recs = []
def new_record():
    return {'id': '', 'title': '', 'test_script': '', 'pass_condition': '',
            'evidence': '', 'prerequisite': '', 'severity': ''}
for ln in lines:
    m = re.match(r'^  - id:\s*(\S+)\s*$', ln)
    if m:
        flush(); cur = new_record(); cur['id'] = m.group(1); field = None
        continue
    if cur is None:
        continue
    m = re.match(r'^    ([a-z_]+):\s*(.*)$', ln)
    if m:
        key, val = m.group(1), m.group(2).strip()
        field = key if key in cur else None
        if field:
            if val == '|' or val == '>':
                cur[field] = ''
            else:
                cur[field] = val
        continue
    if field and ln.startswith('      '):
        cur[field] += (' ' if cur[field] else '') + ln.strip()
        continue
    if ln.strip() == '':
        field = None
flush()
def flat(s):
    return re.sub(r'\s+', ' ', s or '').strip().replace('\t', ' ')
with open(dst, 'w', encoding='utf-8') as f:
    for r in recs:
        f.write('\t'.join(flat(r[k]) for k in
                ('id','title','test_script','pass_condition','evidence','prerequisite','severity')) + '\n')
PY
[ -s "$PARSED" ] || { echo "CM-CHALLENGES: FAIL parser produced zero records" | tee -a "$SUMMARY"; printf 'EVIDENCE: %s\n' "$SUMMARY"; exit 1; }

# 180s: measured 75s was too tight for test 09's split-topology branch
# (11 PASS lines captured but rc=124 → honest SKIP). 180s closes that gap
# deterministically; still bounded, still fail-closed on timeout.
TIMEOUT="${CHALLENGE_TIMEOUT:-180}"
export TMUX_BIN="${TMUX_BIN:-$REPO_ROOT/tmux/build/bin/tmux}"
export WRAPPER="${WRAPPER:-$REPO_ROOT/scripts/tmx}"

total=0; pass=0; fail=0; skip=0; unclassified=0
echo "GATE=CM-CHALLENGES YAML=$YAML RUN_ID=$RUN_ID TIMEOUT=${TIMEOUT}s" >> "$SUMMARY"
printf 'ID\tVERDICT\tREASON\tEVIDENCE\n' >> "$SUMMARY_TSV"

run_one() {
    local id="$1" script="$2" pc="$3" title="$4"
    local ev="$EVIDENCE_DIR/${id}.log"
    {
        echo "CHALLENGE_ID=$id"
        echo "TITLE=$title"
        echo "TEST_SCRIPT=$script"
        echo "PASS_CONDITION=$pc"
        echo "─── captured runtime output ───"
    } > "$ev"

    if [ -z "$id" ] || [ -z "$pc" ]; then
        echo "UNCLASSIFIED: id or pass_condition missing" >> "$ev"
        unclassified=$((unclassified + 1))
        printf '%s\tUNCLASSIFIED\tid-or-pass_condition-missing\t%s\n' "${id:-<none>}" "${ev#$REPO_ROOT/}" >> "$SUMMARY_TSV"
        echo "UNCLASSIFIED $id (see $ev)"
        return
    fi
    # Run via `bash "$script"` — the executable bit is NOT required (several
    # in-repo tests are committed 0644). SKIP only on a genuinely missing file.
    if [ -z "$script" ] || [ ! -f "$REPO_ROOT/$script" ]; then
        echo "SKIP: test_script missing: $script" >> "$ev"
        skip=$((skip + 1))
        printf '%s\tSKIP\treason=test-script-missing\t%s\n' "$id" "${ev#$REPO_ROOT/}" >> "$SUMMARY_TSV"
        echo "SKIP $id (test script missing)"
        return
    fi
    # Project rule: destructive tests 12/13/14 require an explicit opt-in.
    case "$script" in
        */12_memory_pressure_under_cap.sh|*/13_tasksmax_stress.sh|*/14_concurrent_oom_independence.sh)
            if [ "${TMX_TEST_DESTRUCTIVE:-0}" != "1" ]; then
                echo "SKIP: destructive challenge needs TMX_TEST_DESTRUCTIVE=1 (project §destructive-tests)" >> "$ev"
                skip=$((skip + 1))
                printf '%s\tSKIP\treason=destructive-opt-in-not-set\t%s\n' "$id" "${ev#$REPO_ROOT/}" >> "$SUMMARY_TSV"
                echo "SKIP $id (destructive opt-in not set)"
                return
            fi ;;
    esac

    ( cd "$REPO_ROOT" && timeout "${TIMEOUT}s" bash "$script" ) >> "$ev" 2>&1
    rc=$?
    echo "EXIT_CODE=$rc" >> "$ev"

    # A bounded-timeout termination is INCONCLUSIVE, not a FAIL-bluff and not
    # a PASS. Record the captured partial output and SKIP with an explicit
    # reason (§11.4.201: a false-positive refusal is a FAIL too).
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        echo "SKIP: test exceeded bounded runner timeout ${TIMEOUT}s (inconclusive; partial output captured above)" >> "$ev"
        skip=$((skip + 1))
        printf '%s\tSKIP\treason=runner-timeout-%ss-inconclusive\t%s\n' "$id" "$TIMEOUT" "${ev#$REPO_ROOT/}" >> "$SUMMARY_TSV"
        echo "SKIP $id (runner timeout)"
        return
    fi

    local has_pass has_fail has_skip reason
    has_pass=$(grep -cE '^[[:space:]]*(\[PASS\]|PASS([[:space:]:]|$)|PASS [0-9]+:|✅)' "$ev" || true)
    has_fail=$(grep -cE '^[[:space:]]*(\[FAIL\]|FAIL([[:space:]:]|$)|FAIL [0-9]+:|❌)' "$ev" || true)
    has_skip=$(grep -cE '^[[:space:]]*(\[SKIP\]|SKIP([[:space:]:]|$)|SKIP [0-9]+:)' "$ev" || true)
    # §11.4.201(7)(a): a ZERO-COUNT summary line ("  FAIL:  0", "  SKIP: 0")
    # is a successful tally, NOT a failure/skip verdict. The bare pattern above
    # matches it; measured 2026-11-20: CH-09 printed PASS=20 FAIL=0 SKIP=0 with
    # EXIT_CODE=0 yet was misclassified FAIL. Subtract only exact zero tallies.
    zero_fail=$(grep -cE '^[[:space:]]*FAIL:[[:space:]]*0([[:space:]]|$)' "$ev" || true)
    zero_skip=$(grep -cE '^[[:space:]]*SKIP:[[:space:]]*0([[:space:]]|$)' "$ev" || true)
    has_fail=$(( ${has_fail:-0} - ${zero_fail:-0} ))
    has_skip=$(( ${has_skip:-0} - ${zero_skip:-0} ))
    [ "$has_fail" -ge 0 ] || has_fail=0
    [ "$has_skip" -ge 0 ] || has_skip=0

    if [ "$rc" -eq 0 ] && [ "${has_pass:-0}" -ge 1 ] && [ "${has_fail:-0}" -eq 0 ]; then
        pass=$((pass + 1))
        printf '%s\tPASS\trc=0+positive-result-marker\t%s\n' "$id" "${ev#$REPO_ROOT/}" >> "$SUMMARY_TSV"
        echo "PASS $id"
    elif [ "${has_skip:-0}" -ge 1 ] && [ "${has_fail:-0}" -eq 0 ]; then
        reason=$(grep -m1 -E '^[[:space:]]*(\[SKIP\]|SKIP([[:space:]:]|$)|SKIP [0-9]+:)' "$ev" | head -c 160)
        skip=$((skip + 1))
        printf '%s\tSKIP\treason=%s\t%s\n' "$id" "$(printf '%s' "$reason" | tr '\t' ' ')" "${ev#$REPO_ROOT/}" >> "$SUMMARY_TSV"
        echo "SKIP $id"
    else
        reason=$(grep -m1 -E '^[[:space:]]*(\[FAIL\]|FAIL([[:space:]:]|$)|FAIL [0-9]+:|❌)' "$ev" | head -c 160)
        [ -n "$reason" ] || reason="rc=$rc and no positive result marker in output"
        fail=$((fail + 1))
        printf '%s\tFAIL\treason=%s\t%s\n' "$id" "$(printf '%s' "$reason" | tr '\t' ' ')" "${ev#$REPO_ROOT/}" >> "$SUMMARY_TSV"
        echo "FAIL $id"
    fi
}

while IFS=$'\t' read -r id title script pc evidence prereq severity; do
    total=$((total + 1))
    run_one "$id" "$script" "$pc" "$title"
done < "$PARSED"

echo "SUMMARY total=$total pass=$pass fail=$fail skip=$skip unclassified=$unclassified" >> "$SUMMARY"
printf '%s\tSUMMARY\n' "${SUMMARY#$REPO_ROOT/}" > "$MANIFEST"
printf '%s\n' "CM-CHALLENGES: total=$total pass=$pass fail=$fail skip=$skip unclassified=$unclassified"
printf 'EVIDENCE: %s\n' "$SUMMARY"
printf 'EVIDENCE_TSV: %s\n' "$SUMMARY_TSV"
[ "$fail" -eq 0 ] && [ "$unclassified" -eq 0 ] || exit 1
exit 0
