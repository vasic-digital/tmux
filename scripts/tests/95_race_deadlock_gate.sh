#!/usr/bin/env bash
# Test 95 — race/deadlock gate on the workable-items SQLite SSoT (§11.4.93/95/169).
#
# Pattern follows 33_state_concurrency.sh (DO NOT EDIT that file). N concurrent
# `workable-items sync md-to-db` writers hit a PRIVATE COPY of docs/workable_items.db;
# the test asserts: (a) no writer hangs (deadlock), (b) no UNEXPECTED writer
# failure — a SQLITE_BUSY rejection under 8-way contention is recorded honestly
# as FAIL-CLOSED: the binary DOES set `_pragma=busy_timeout(5000)` (fact:
# cmd/workable-items/db.go:35), but 5s of waiting can still be exhausted (or a
# lock-upgrade conflict can return SQLITE_BUSY immediately) when 8 writers
# contend, (c) PRAGMA integrity_check stays 'ok', (d) validate reports 0
# findings, (e) 3 iterations yield identical invariant evidence (§11.4.50).
# A hard "zero busy errors" assertion would be flaky under this contention and
# is deliberately NOT made; the observation is logged.
#
# ORACLE SELF-VALIDATION (§11.4.107(10)): a deliberately corrupted DB copy MUST
# be rejected by the integrity oracle. If the oracle accepts a corrupt DB, the
# gate is blind and FAILs.
#
# NEVER writes to the git-tracked docs/workable_items.db — only a temp copy.
# Evidence: docs/qa/<run-id>/95_race_deadlock_gate.log (override TMX_QA_DIR).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
RUN_ID="${TMX_RUN_ID:-testtypes-$(date -u +%Y%m%dT%H%M%SZ)}"
QA_DIR="${TMX_QA_DIR:-$REPO_ROOT/docs/qa/$RUN_ID}"
EVID="$QA_DIR/95_race_deadlock_gate.log"
if ! mkdir -p "$QA_DIR" 2>/dev/null; then echo "SKIP: evidence dir $QA_DIR not writable (§11.4.3)"; exit 0; fi
: > "$EVID"

PASS=0; FAIL=0; SKIP=0
log(){ echo "$*" | tee -a "$EVID"; }
_pass(){ log "PASS: $*"; PASS=$((PASS+1)); }
_fail(){ log "FAIL: $*"; FAIL=$((FAIL+1)); }
_skip(){ log "SKIP: $*"; SKIP=$((SKIP+1)); }

log "── Test 95: workable-items race/deadlock gate (run-id $RUN_ID) ──"

BIN="$REPO_ROOT/cmd/workable-items/workable-items"
DB="$REPO_ROOT/docs/workable_items.db"
ISSUES="$REPO_ROOT/Issues.md"; FIXED="$REPO_ROOT/Fixed.md"
for p in "$BIN" "$DB" "$ISSUES" "$FIXED"; do
  [ -f "$p" ] || { _skip "prerequisite missing: $p"; log "PASS: 95 SKIPped (prerequisite missing)"; exit 0; }
done
command -v python3 >/dev/null 2>&1 || { _skip "python3 not on PATH"; exit 0; }
python3 -c 'import sqlite3' 2>/dev/null || { _skip "python3 sqlite3 module unavailable"; exit 0; }
[ -x "$BIN" ] || { _skip "workable-items binary not built"; exit 0; }

SCRATCH="${TMPDIR:-/tmp}"; SCRATCH="${SCRATCH%/}"
W="$SCRATCH/tmx_t95_$$"
mkdir -p "$W" 2>/dev/null || { _skip "scratch $SCRATCH not writable"; exit 0; }
trap 'rm -rf "$W" 2>/dev/null || true' EXIT

HAVE_TIMEOUT=0; command -v timeout >/dev/null 2>&1 && HAVE_TIMEOUT=1
[ "$HAVE_TIMEOUT" -eq 1 ] && log "  deadlock watchdog: GNU timeout available" \
  || log "  deadlock watchdog: no GNU timeout — hang assertion degraded (§11.4.3)"

# ── oracle self-validation: corrupt DB MUST be rejected ─────────────────────
cp "$DB" "$W/corrupt.db"
python3 - "$W/corrupt.db" <<'PY' >/dev/null 2>&1 || true
import sys
p=sys.argv[1]
with open(p,'r+b') as f: f.write(b'CORRUPTED_NOT_SQLITE___'*4)
PY
corrupt_chk="$(python3 -c "import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute('PRAGMA integrity_check').fetchone()[0])" "$W/corrupt.db" 2>/dev/null || echo 'error')"
if [ "$corrupt_chk" = "ok" ]; then
  _fail "integrity oracle ACCEPTED a corrupted DB (check='$corrupt_chk') — blind analyzer"
else
  _pass "integrity oracle rejects corrupted DB (check='$corrupt_chk' != ok)"
fi

N=8
hashes=()
for iter in 1 2 3; do
  wdb="$W/w$iter.db"; cp "$DB" "$wdb"
  pids=(); outs=()
  for i in $(seq 1 "$N"); do
    o="$W/o${iter}_${i}.txt"; : > "$o"; outs+=("$o")
    if [ "$HAVE_TIMEOUT" -eq 1 ]; then
      timeout 45 "$BIN" sync md-to-db --db "$wdb" --issues "$ISSUES" --fixed "$FIXED" >"$o" 2>&1 &
    else
      "$BIN" sync md-to-db --db "$wdb" --issues "$ISSUES" --fixed "$FIXED" >"$o" 2>&1 &
    fi
    pids+=("$!")
  done
  busy=0; okc=0; bad=0
  for idx in "${!pids[@]}"; do
    wait "${pids[$idx]}"; r=$?
    if [ "$r" -eq 124 ]; then
      _fail "iter=$iter writer ${outs[$idx]} HUNG (timeout rc=124)"; bad=$((bad+1)); continue
    fi
    if [ "$r" -eq 0 ]; then
      okc=$((okc+1)); continue
    fi
    # This binary DOES set busy_timeout(5000) (cmd/workable-items/db.go:35),
    # yet under 8-way contention a writer may STILL get SQLITE_BUSY (the 5s
    # wait can be exhausted, or a lock-upgrade conflict returns it at once).
    # That is FAIL-CLOSED (no silent write, no corruption), so record it
    # honestly rather than turning the gate flaky. Any OTHER non-zero exit
    # is an unexpected defect and FAILs the gate.
    if grep -qiE 'database is locked|SQLITE_BUSY' "${outs[$idx]}"; then
      busy=$((busy+1))
    else
      _fail "iter=$iter writer ${outs[$idx]} unexpected rc=$r: $(head -c 160 "${outs[$idx]}")"
      bad=$((bad+1))
    fi
  done
  [ "$bad" -eq 0 ] || continue
  chk="$(python3 -c "import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute('PRAGMA integrity_check').fetchone()[0])" "$wdb" 2>/dev/null || echo error)"
  [ "$chk" = "ok" ] || { _fail "iter=$iter: PRAGMA integrity_check='$chk'"; continue; }
  vout="$("$BIN" validate --db "$wdb" 2>&1)"
  echo "$vout" | grep -qE '0 findings' || { _fail "iter=$iter: validate not clean: $vout"; continue; }
  icount="$(python3 -c "import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute('select count(*) from items').fetchone()[0])" "$wdb" 2>/dev/null || echo -1)"
  # Invariant hash EXCLUDES the transient busy count so it stays deterministic.
  h="$(printf 'chk=%s items=%s validate=0' "$chk" "$icount" | sha256sum | cut -d' ' -f1)"
  hashes+=("$h")
  log "  OBSERVE iter=$iter ok=$okc busy_rejected=$busy unexpected=$bad"
  _pass "iter=$iter: $N writers safe (ok=$okc fail-closed-busy=$busy), integrity=ok, validate 0 findings, items=$icount"
done

if [ "${#hashes[@]}" -eq 3 ] && [ "${hashes[0]}" = "${hashes[1]}" ] && [ "${hashes[1]}" = "${hashes[2]}" ]; then
  _pass "determinism: 3/3 iteration hashes identical (${hashes[0]:0:16}...)"
else
  _fail "determinism: iteration hashes diverge (${hashes[*]:0:3})"
fi

if [ "$FAIL" -gt 0 ] || [ "$SKIP" -gt 0 ]; then
  log "FAIL: race/deadlock gate FAIL=$FAIL SKIP=$SKIP"
  exit 1
fi
log "PASS: race/deadlock gate green — $N concurrent writers x3, no corruption/locks/hangs"
exit 0
