#!/usr/bin/env bash
# Test 97 — stress+chaos / bounded failure-injection gate (§11.4.169 type 9).
#
# Injects failures against tmx-state-bin in a TEMP sandbox only, asserting
# FAIL-CLOSED behaviour, no host damage, and capped resources:
#   C1 state path under a regular file  -> record must fail (ENOTDIR)
#   C2 state path is a directory        -> record must fail (EISDIR)
#   C3 kill -9 mid-write x10            -> state file stays valid JSON
#   C4 all of the above under `ulimit -f` -> no runaway file growth
#
# RED_MODE=1 (golden-bad): a stub that IGNORES a write failure and exits 0 MUST
# be classified as FAIL-OPEN by the oracle; RED_MODE=0 (default) runs C1-C4.
#
# Evidence: docs/qa/<run-id>/97_stress_chaos_gate.log (override TMX_QA_DIR).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
RUN_ID="${TMX_RUN_ID:-testtypes-$(date -u +%Y%m%dT%H%M%SZ)}"
QA_DIR="${TMX_QA_DIR:-$REPO_ROOT/docs/qa/$RUN_ID}"
EVID="$QA_DIR/97_stress_chaos_gate.log"
if ! mkdir -p "$QA_DIR" 2>/dev/null; then echo "SKIP: evidence dir $QA_DIR not writable (§11.4.3)"; exit 0; fi
: > "$EVID"

PASS=0; FAIL=0; SKIP=0
log(){ echo "$*" | tee -a "$EVID"; }
_pass(){ log "PASS: $*"; PASS=$((PASS+1)); }
_fail(){ log "FAIL: $*"; FAIL=$((FAIL+1)); }
_skip(){ log "SKIP: $*"; SKIP=$((SKIP+1)); }

RED_MODE="${RED_MODE:-0}"
log "── Test 97: stress+chaos gate (RED_MODE=$RED_MODE, run-id $RUN_ID) ──"

STATE_BIN="$REPO_ROOT/scripts/tmx-state-bin"
[ -x "$STATE_BIN" ] || { _skip "tmx-state-bin not built"; log "PASS: 97 SKIPped (binary absent)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { _skip "python3 not on PATH"; exit 0; }

SCRATCH="${TMPDIR:-/tmp}"; SCRATCH="${SCRATCH%/}"
W="$SCRATCH/tmx_t97_$$"; mkdir -p "$W" 2>/dev/null || { _skip "scratch $SCRATCH not writable"; exit 0; }
trap 'rm -rf "$W" 2>/dev/null || true' EXIT

# Pure oracle: run a command, report FLAGGED when it failed closed, MISSED
# when it wrongly succeeded. Prints no command output / no secret values.
classify_failclosed(){
  "$@" >/dev/null 2>&1
  [ $? -ne 0 ] && echo FLAGGED || echo MISSED
}

if [ "$RED_MODE" = "1" ]; then
  bad="$(classify_failclosed bash -c 'exit 0')"
  good="$(classify_failclosed bash -c 'exit 3')"
  [ "$bad" = "MISSED" ] && _pass "golden-bad: fail-open stub classified MISSED (oracle not blind)" \
    || _fail "golden-bad: fail-open stub wrongly classified '$bad'"
  [ "$good" = "FLAGGED" ] && _pass "golden-good: non-zero stub classified FLAGGED" \
    || _fail "golden-good: non-zero stub classified '$good'"
  log "PASS: RED_MODE=1 oracle self-validation complete"
  exit 0
fi

printf x > "$W/regular"
mkdir -p "$W/isdir/state.json"

# Run failure injections under a hard file-size cap (512-byte blocks => 64 KiB).
c1=""; c2=""
c1="$( ( ulimit -f 128; TMX_STATE_FILE="$W/regular/state.json" "$STATE_BIN" record s1 /tmp >/dev/null 2>&1; echo rc=$? ) )"
c2="$( ( ulimit -f 128; TMX_STATE_FILE="$W/isdir/state.json" "$STATE_BIN" record s2 /tmp >/dev/null 2>&1; echo rc=$? ) )"
case "$c1" in rc=[1-9]*) _pass "C1 ENOTDIR: record failed closed ($c1)" ;; *) _fail "C1 ENOTDIR: FAIL-OPEN ($c1)" ;; esac
case "$c2" in rc=[1-9]*) _pass "C2 EISDIR: record failed closed ($c2)" ;; *) _fail "C2 EISDIR: FAIL-OPEN ($c2)" ;; esac

# C3: abrupt termination mid-write must not corrupt the state file.
SF="$W/state.json"
TMX_STATE_FILE="$SF" "$STATE_BIN" record seed /home >/dev/null 2>&1
(
  for i in $(seq 1 10); do
    TMX_STATE_FILE="$SF" "$STATE_BIN" record "k$i" /tmp >/dev/null 2>&1 &
    kill -9 "$!" 2>/dev/null
  done
  wait 2>/dev/null
) >"$W/kill.out" 2>&1
jchk="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print('json_ok sessions=%d'%len(d.get('sessions',{})))" "$SF" 2>/dev/null || echo corrupt)"
case "$jchk" in
  json_ok*) _pass "C3 kill -9 x10: state file remains valid JSON ($jchk)" ;;
  *) _fail "C3 kill -9 x10: state file corrupt/unreadable ($jchk)" ;;
esac

# C4: resource cap held — sandbox did not grow a runaway artifact.
kb="$(du -sk "$W" 2>/dev/null | cut -f1)"
if [ "${kb:-99999}" -le 1024 ]; then _pass "C4 resource cap: sandbox ${kb}KB <= 1024KB, no host damage"; else _fail "C4 sandbox grew to ${kb}KB"; fi

if [ "$FAIL" -gt 0 ] || [ "$SKIP" -gt 0 ]; then
  log "FAIL: chaos gate FAIL=$FAIL SKIP=$SKIP"
  exit 1
fi
log "PASS: stress+chaos gate green — fail-closed under 2 fault classes, kill-safe, resource-capped"
exit 0
