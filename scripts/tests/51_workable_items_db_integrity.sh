#!/usr/bin/env bash
# Test 51 — workable-items DB integrity (§11.4.93 / §11.4.95 anti-bluff).
#
# §11.4.93 / §11.4.95 FORENSIC ANCHOR:
#   The §11.4.93 mandate makes `docs/workable_items.db` the single
#   source of truth for the workable-item lifecycle. §11.4.95 makes
#   the DB itself a tracked artefact (SQLite blob committed to git).
#   Both rules collapse to a §11.4 PASS-bluff the moment the DB and
#   the human-readable Markdown trackers (Issues.md / Fixed.md)
#   silently diverge — operators read the Markdown, automation reads
#   the DB, both report PASS, neither is wrong about its own input.
#
#   Test 51 closes the gap. It runs the canonical `workable-items`
#   binary against the live corpus and verifies (a) the schema
#   embedded in the binary applies cleanly, (b) `validate` reports
#   ZERO findings against the on-disk DB, (c) a round-trip
#   `sync md-to-db` → `sync db-to-md` produces byte-identical
#   Markdown — the only mechanical proof that nothing was lost in
#   either direction.
#
# §11.4.2 captured evidence: validate output, file hashes before/after
#   round-trip, diff output if any.
# §11.4.50 reliability: 3 iterations of round-trip identical.
# §11.4.14 cleanup: trap removes the test working copy of the DB.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$REPO_ROOT/cmd/workable-items/workable-items"
DB="$REPO_ROOT/docs/workable_items.db"
# Project carve-out per Constitution §11.4.48: the 5 canonical tracker
# documents (Issues.md, Issues_Summary.md, Fixed.md, Fixed_Summary.md,
# CONTINUATION.md) sit at REPO_ROOT for this project, not docs/. See the
# carve-out anchor in constitution/CLAUDE.md.
ISSUES="$REPO_ROOT/Issues.md"
FIXED="$REPO_ROOT/Fixed.md"

# §11.4.3 / D2 TMPDIR-HARDCODE-001 — route scratch through $TMPDIR so a full
# host `/` cannot false-FAIL this test. Preflight below.
SCRATCH="${TMPDIR:-/tmp}"
_wtest="$SCRATCH/.tmx_wtest_$$"
if ! mkdir -p "$_wtest" 2>/dev/null || [ ! -w "$_wtest" ]; then
    echo "SKIP 51: scratch root $SCRATCH not writable — §11.4.3"
    exit 77
fi
rmdir "$_wtest" 2>/dev/null || true

WORK_DIR="$SCRATCH/tmx-test-51-roundtrip-$$"

PASS=0; FAIL=0; SKIP=0
_pass() { echo "PASS 51: $*"; PASS=$((PASS + 1)); }
_fail() { echo "FAIL 51: $*"; FAIL=$((FAIL + 1)); }
_skip() { echo "SKIP 51: $*"; SKIP=$((SKIP + 1)); }

_cleanup() {
    rm -rf "$WORK_DIR" 2>/dev/null || true
}
trap _cleanup EXIT

echo "── Test 51: workable-items DB integrity (§11.4.93 / §11.4.95) ──"

# ── T0: binary built ──────────────────────────────────────────────────
if [ ! -x "$BIN" ]; then
    _skip "T0 workable-items binary not built at $BIN (run: cd cmd/workable-items && go build)"
    echo "── summary 51: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
    exit 77
fi
_pass "T0 binary executable at $BIN"

# ── T1: STRUCTURAL — docs/workable_items.db exists + tracked in git ───
if [ ! -f "$DB" ]; then
    _fail "T1 docs/workable_items.db missing — §11.4.93 SSoT not on disk"
elif ! git -C "$REPO_ROOT" ls-files --error-unmatch "docs/workable_items.db" >/dev/null 2>&1; then
    _fail "T1 docs/workable_items.db NOT tracked in git — §11.4.95 violation"
else
    db_size="$(wc -c < "$DB" | tr -d ' ')"
    _pass "T1 docs/workable_items.db present + git-tracked (size=${db_size} bytes)"
fi

# ── T2: schema applies cleanly (matches the constitution schema) ──────
if "$BIN" validate --schema-only >"$SCRATCH/tmx-test-51-schema-$$.txt" 2>&1; then
    schema_out="$(cat "$SCRATCH/tmx-test-51-schema-$$.txt")"
    if echo "$schema_out" | grep -qE 'schema OK'; then
        _pass "T2 schema applies cleanly: $schema_out"
    else
        _fail "T2 validate --schema-only exited 0 but output unexpected: $schema_out"
    fi
else
    _fail "T2 validate --schema-only failed: $(cat "$SCRATCH/tmx-test-51-schema-$$.txt")"
fi
rm -f "$SCRATCH/tmx-test-51-schema-$$.txt"

# ── T3: validate against the live DB reports ZERO findings ────────────
if [ -f "$DB" ]; then
    validate_out="$("$BIN" validate --db "$DB" 2>&1)"
    validate_rc=$?
    if [ "$validate_rc" -ne 0 ]; then
        _fail "T3 'workable-items validate --db $DB' returned rc=$validate_rc: $validate_out"
    elif echo "$validate_out" | grep -qE '0 findings'; then
        _pass "T3 validate clean: $validate_out"
    else
        _fail "T3 validate did not report '0 findings': $validate_out"
    fi
fi

# ── T4: round-trip md-to-db then db-to-md → byte-identical markdown ───
#   This proves the parser + serializer are inverses on the live corpus.
#   ANY divergence (whitespace, ordering, missing fields, character
#   escaping) surfaces as a non-zero diff and fails the test.
mkdir -p "$WORK_DIR"
cp "$ISSUES" "$WORK_DIR/Issues.md.orig"
cp "$FIXED" "$WORK_DIR/Fixed.md.orig"

run_roundtrip_iter() {
    local iter="$1"
    local work_db="$WORK_DIR/workable_items.iter${iter}.db"
    local out_dir="$WORK_DIR/iter${iter}"
    mkdir -p "$out_dir"
    cp "$DB" "$work_db"

    # md-to-db: bring the markdown in, overwriting the working DB content.
    if ! "$BIN" sync md-to-db --db "$work_db" --issues "$ISSUES" --fixed "$FIXED" >"$WORK_DIR/iter${iter}.md2db.log" 2>&1; then
        _fail "T4 iter=$iter: sync md-to-db failed: $(tail -3 "$WORK_DIR/iter${iter}.md2db.log")"
        return 1
    fi

    # db-to-md: write back into a separate directory.
    if ! "$BIN" sync db-to-md --db "$work_db" --out-dir "$out_dir" >"$WORK_DIR/iter${iter}.db2md.log" 2>&1; then
        _fail "T4 iter=$iter: sync db-to-md failed: $(tail -3 "$WORK_DIR/iter${iter}.db2md.log")"
        return 1
    fi

    # Byte-identical comparison: the round-trip MUST be the identity
    # function on the corpus committed to git.
    if ! diff -q "$ISSUES" "$out_dir/Issues.md" >/dev/null 2>&1; then
        _fail "T4 iter=$iter: Issues.md diverged on round-trip"
        echo "  --- first 10 differing lines:" >&2
        diff "$ISSUES" "$out_dir/Issues.md" 2>&1 | head -20 >&2 || true
        return 1
    fi
    if ! diff -q "$FIXED" "$out_dir/Fixed.md" >/dev/null 2>&1; then
        _fail "T4 iter=$iter: Fixed.md diverged on round-trip"
        echo "  --- first 10 differing lines:" >&2
        diff "$FIXED" "$out_dir/Fixed.md" 2>&1 | head -20 >&2 || true
        return 1
    fi
    # Captured evidence: file sizes (proxies for content).
    local is_sz fx_sz
    is_sz="$(wc -c < "$out_dir/Issues.md" | tr -d ' ')"
    fx_sz="$(wc -c < "$out_dir/Fixed.md" | tr -d ' ')"
    echo "[evidence 51] iter=$iter Issues.md=${is_sz}b Fixed.md=${fx_sz}b byte-identical=yes"
    return 0
}

# ── T5: §11.4.50 deterministic-consistency — 3 iterations identical ──
_hashes=()
_iter_failed=0
for i in 1 2 3; do
    if ! run_roundtrip_iter "$i"; then _iter_failed=1; break; fi
    iter_hash="$(cat "$WORK_DIR/iter${i}/Issues.md" "$WORK_DIR/iter${i}/Fixed.md" | shasum | cut -d' ' -f1)"
    _hashes+=("$iter_hash")
done

if [ "$_iter_failed" -eq 1 ]; then
    echo "── summary 51: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
    exit 1
fi

if [ "${_hashes[0]}" = "${_hashes[1]}" ] && [ "${_hashes[1]}" = "${_hashes[2]}" ]; then
    _pass "T4 + T5 round-trip byte-identical on 3/3 iterations (hash=${_hashes[0]})"
else
    _fail "T5 §11.4.50 round-trip hashes diverge across 3 iterations: ${_hashes[*]}"
fi

echo "── summary 51: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
