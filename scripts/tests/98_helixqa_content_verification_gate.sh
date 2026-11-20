#!/usr/bin/env bash
# Test 98 — HelixQA-style captured-content verification gate (§11.4.107(10),
# §11.4.158/§11.4.163, §11.4.169 type 6). Distinct from the scripts/testing/*
# HelixQA surface authored separately.
#
# Proves the content analyzer is REAL, not a rubber stamp:
#   golden-good = a genuinely captured `workable-items validate` artifact
#                 containing "validate OK: 0 findings" -> MUST be ACCEPTed
#   golden-bad  = (a) same capture with findings flipped to non-zero
#                 (b) a metadata-only counter line "PASS=0 FAIL=0 SKIP=0"
#                 (c) an LLM-error / traceback artifact  -> all MUST be REJECTed
# A single captured frame / a bare PASS substring is NOT proof (§11.4.201(7)(a)).
#
# Analyzer prints only ACCEPT/REJECT — never artifact content or secret values.
# Evidence: docs/qa/<run-id>/98_helixqa_content_verification.log (override TMX_QA_DIR).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
RUN_ID="${TMX_RUN_ID:-testtypes-$(date -u +%Y%m%dT%H%M%SZ)}"
QA_DIR="${TMX_QA_DIR:-$REPO_ROOT/docs/qa/$RUN_ID}"
EVID="$QA_DIR/98_helixqa_content_verification.log"
if ! mkdir -p "$QA_DIR" 2>/dev/null; then echo "SKIP: evidence dir $QA_DIR not writable (§11.4.3)"; exit 0; fi
: > "$EVID"

PASS=0; FAIL=0; SKIP=0
log(){ echo "$*" | tee -a "$EVID"; }
_pass(){ log "PASS: $*"; PASS=$((PASS+1)); }
_fail(){ log "FAIL: $*"; FAIL=$((FAIL+1)); }
_skip(){ log "SKIP: $*"; SKIP=$((SKIP+1)); }

log "── Test 98: HelixQA-style content verification gate (run-id $RUN_ID) ──"

BIN="$REPO_ROOT/cmd/workable-items/workable-items"
DB="$REPO_ROOT/docs/workable_items.db"
[ -x "$BIN" ] || { _skip "workable-items binary not built"; log "PASS: 98 SKIPped (binary absent)"; exit 0; }
[ -f "$DB" ] || { _skip "docs/workable_items.db missing"; exit 0; }

SCRATCH="${TMPDIR:-/tmp}"; SCRATCH="${SCRATCH%/}"
W="$SCRATCH/tmx_t98_$$"; mkdir -p "$W" 2>/dev/null || { _skip "scratch $SCRATCH not writable"; exit 0; }
trap 'rm -rf "$W" 2>/dev/null || true' EXIT

# Content oracle: structural success verdict + evidence marker + zero failure
# markers. A bare "PASS=0" counter or a single frame never satisfies it.
verify_artifact(){
  local f="$1"
  [ -f "$f" ] || { echo REJECT; return; }
  # genuine success verdict (delimiter required: PASS=... does NOT match)
  grep -qE '^(PASS([: (]|$)|validate OK: 0 findings|.*json_ok)' "$f" || { echo REJECT; return; }
  # independent evidence marker
  grep -qE '(findings|json_ok|evidence|integrity|sessions=)' "$f" || { echo REJECT; return; }
  # any failure marker vetoes acceptance
  grep -qiE '^(FAIL([: (]|$)|ERROR|Traceback|panic|FATAL)' "$f" && { echo REJECT; return; }
  echo ACCEPT
}

# Golden-good: a REAL captured artifact (validate against a private DB copy).
cp "$DB" "$W/w.db"
"$BIN" validate --db "$W/w.db" > "$W/good.txt" 2>&1
g="$(verify_artifact "$W/good.txt")"
[ "$g" = "ACCEPT" ] && _pass "golden-good: genuine captured validate artifact ACCEPTed" \
  || _fail "golden-good: genuine artifact got '$g' (analyzer blind)"

# Golden-bad (a): flip the success content to non-zero findings.
sed 's/0 findings/3 findings/' "$W/good.txt" > "$W/bad_a.txt"
a="$(verify_artifact "$W/bad_a.txt")"
[ "$a" = "REJECT" ] && _pass "golden-bad(a): flipped-findings artifact REJECTed" \
  || _fail "golden-bad(a): artifact got '$a' (present-cue-is-correct bluff)"

# Golden-bad (b): metadata-only counter line — a bare PASS substring is not proof.
printf 'PASS=0 FAIL=0 SKIP=0\n' > "$W/bad_b.txt"
b="$(verify_artifact "$W/bad_b.txt")"
[ "$b" = "REJECT" ] && _pass "golden-bad(b): metadata-only counter artifact REJECTed" \
  || _fail "golden-bad(b): artifact got '$b' (counter-line bluff)"

# Golden-bad (c): LLM error / traceback passed off as success.
printf 'ERROR: provider unavailable\nTraceback (most recent call last):\n' > "$W/bad_c.txt"
c="$(verify_artifact "$W/bad_c.txt")"
[ "$c" = "REJECT" ] && _pass "golden-bad(c): error/traceback artifact REJECTed" \
  || _fail "golden-bad(c): artifact got '$c' (error-as-success bluff)"

# End-to-end: fresh capture accepted again (reproducibility, §11.4.50).
"$BIN" validate --db "$W/w.db" > "$W/fresh.txt" 2>&1
f="$(verify_artifact "$W/fresh.txt")"
[ "$f" = "ACCEPT" ] && _pass "end-to-end: fresh capture ACCEPTed (reproducible)" \
  || _fail "end-to-end: fresh capture got '$f'"

if [ "$FAIL" -gt 0 ] || [ "$SKIP" -gt 0 ]; then
  log "FAIL: content-verification gate FAIL=$FAIL SKIP=$SKIP"
  exit 1
fi
log "PASS: HelixQA-style content gate green — analyzer self-validated (1 good / 3 bad)"
exit 0
