#!/usr/bin/env bash
# tracker_structural_integrity_test.sh
# ─────────────────────────────────────────────────────────────────────────
# Purpose:    Paired test for scripts/testing/tracker_structural_integrity.sh.
#             Proves the gate has TEETH (fires on the real historical
#             defect) and is not a DEADLOCK (does not fire on the live
#             corpus, nor on any of four legitimate ordinary edits), then
#             runs the §1.1 mutation pair: a weakened gate MUST miss the
#             defect it was built to catch.
#
# Checks:
#   T1  RED           baseline → bad_over_deleted (the ACTUAL 2026-09-01
#                     over-deletion) MUST FAIL, naming section H.
#   T2  golden-FALSE  baseline → good_repaired (same intended item removal,
#                     done correctly with a tombstone) MUST NOT fire.
#   T3  golden-FALSE  an item ADDED MUST NOT fire.
#   T4  golden-FALSE  a section RETITLED MUST NOT fire (identity is the
#                     LETTER, §11.4.111).
#   T5  golden-FALSE  an item MIGRATED out (Issues → Fixed) MUST NOT fire.
#   T6  RED (A2)      header survives, preamble GUTTED MUST FAIL.
#   T7  RED (A3)      preamble reworded but the governing §11.4.114
#                     citation DROPPED MUST FAIL.
#   T8  DECLARED      the same removal as T1, declared in a manifest, MUST
#                     NOT fire — removal is possible, silence is not.
#   T9  RUBBER-STAMP  a manifest row with an EMPTY reason/authority MUST
#                     NOT count as a declaration (T1 still FAILs).
#   T10 LIVE          the real Issues.md + Fixed.md vs HEAD MUST NOT fire.
#   T11 §1.1 MUTATION a copy of the gate with its A1 counter neutered MUST
#                     PASS on the T1 defect — proving T1's PASS is produced
#                     by the assertion and not by the harness.
#   T12 §1.1 MUTATION a copy with the A3 anchor comparison neutered MUST
#                     PASS on the T7 defect.
#
# Usage:      bash scripts/testing/tracker_structural_integrity_test.sh
# Outputs:    PASS/FAIL lines + a summary. Exit 0 = all green, 1 = any red.
# Side-effects: NONE on the tree. Derived fixtures, manifests and the two
#             MUTATED gate copies live only under ${TMPDIR:-/tmp} and are
#             removed on every exit path (§11.4.14) — the tracked gate is
#             never edited, so no mutation residue can be staged (§11.4.84).
# Dependencies: awk, sed, grep. git only for T10 (SKIP-with-reason without).
# Cross-refs: scripts/testing/tracker_structural_integrity.sh ;
#             docs/scripts/tracker_structural_integrity.md ;
#             commit 8dad4e3 (the defect) ; Issues.md §H.
# §11.4.67:  POSIX `sh -n` clean AND `bash -n` clean.
# Last verified: 2026-09-01
# ─────────────────────────────────────────────────────────────────────────
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
GATE="$SELF_DIR/tracker_structural_integrity.sh"
FIX="$SELF_DIR/fixtures/tracker_structural"
BASE="$FIX/baseline_issues.md"

PASS=0
FAIL=0

W="${TMPDIR:-/tmp}"
W="${W%/}/tmx-tsi-test.$$"
mkdir -p "$W" || { echo "FAIL test: scratch $W not creatable"; exit 1; }
# shellcheck disable=SC2064
trap "rm -rf '$W'" EXIT INT TERM HUP

_pass() { echo "PASS test: $*"; PASS=$((PASS + 1)); }
_fail() { echo "FAIL test: $*"; FAIL=$((FAIL + 1)); }

# Run a gate binary over one fixture pair; capture output + exit code.
# $1 gate  $2 label  $3 baseline  $4 current  [$5 manifest]
_run() {
    _g="$1"; _l="$2"; _b="$3"; _c="$4"; _m="${5:-$W/empty.tsv}"
    OUT="$(bash "$_g" --manifest "$_m" --pair "$_l:$_b:$_c" 2>&1)"
    RC=$?
    return 0
}

: > "$W/empty.tsv"

# ── derived fixtures ─────────────────────────────────────────────────────
# Each is the baseline with exactly ONE documented transformation, so a
# fired assertion can only be attributed to that transformation.

# T3: an item ADDED to section H.
awk '
    { print }
    /^### H1 / && !done {
        # nothing: marker only
    }
' "$BASE" > "$W/item_added.md"
cat >> "$W/item_added.md" <<'EOF'

### I2 NEW-ITEM-001 — a brand-new item appended to an existing section

**Type:** Task
**Status:** Queued

Body text.
EOF

# T4: section H RETITLED (letter unchanged).
sed 's|^## H\. .*|## H. Timing issues (RETITLED during a routine edit)|' \
    "$BASE" > "$W/title_reworded.md"

# T5: item H1 MIGRATED out (block deleted, header + preamble untouched) —
# the ordinary Issues → Fixed closure move.
awk '
    /^### H1 / { skip = 1 }
    /^## I\./  { skip = 0 }
    !skip      { print }
' "$BASE" > "$W/item_migrated.md"

# T6: section H header survives, its preamble GUTTED (every content line
# between the header and the first ### removed).
awk '
    /^## H\./ { print; inH = 1; print ""; next }
    inH && /^### / { inH = 0 }
    inH { next }
    { print }
' "$BASE" > "$W/preamble_gutted.md"

# T7: H preamble REWORDED, keeping prose but dropping the §11.4.114 anchor.
sed 's|Confirmed via §11\.4\.114|Confirmed via A/B isolation|' \
    "$BASE" > "$W/anchor_lost.md"

# ── T1 RED: the actual historical defect ─────────────────────────────────
_run "$GATE" "T1-historical" "$BASE" "$FIX/bad_over_deleted.md"
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'FAIL tracker-structural: A1' \
   && printf '%s' "$OUT" | grep -q 'VANISHED'; then
    _pass "T1 RED — gate FAILS (rc=$RC) on the 2026-09-01 over-deletion, naming the vanished section"
    echo "$OUT" | sed 's/^/    | /'
else
    _fail "T1 RED — gate did NOT fail on the historical defect (rc=$RC). A gate that cannot fail here is unvalidated instrumentation (§11.4.115(F))."
    echo "$OUT" | sed 's/^/    | /'
fi

# ── T2..T5 golden-FALSE: legitimate ordinary edits ───────────────────────
for _case in "T2-repaired:$FIX/good_repaired.md" \
             "T3-item-added:$W/item_added.md" \
             "T4-retitled:$W/title_reworded.md" \
             "T5-item-migrated:$W/item_migrated.md"; do
    _nm="${_case%%:*}"; _f="${_case#*:}"
    _run "$GATE" "$_nm" "$BASE" "$_f"
    if [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -q '^FAIL '; then
        _pass "$_nm golden-FALSE — gate correctly does NOT fire (rc=0)"
    else
        _fail "$_nm golden-FALSE — gate FIRED on a legitimate edit (rc=$RC). A wrong refusal is as forbidden as a missed defect (§11.4.201(1))."
        echo "$OUT" | sed 's/^/    | /'
    fi
done

# ── T6 / T7 the narrower RED cases ───────────────────────────────────────
_run "$GATE" "T6-preamble-gutted" "$BASE" "$W/preamble_gutted.md"
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'FAIL tracker-structural: A2'; then
    _pass "T6 RED — A2 fires when a surviving section's preamble is emptied"
else
    _fail "T6 RED — A2 did not fire on a gutted preamble (rc=$RC)"
    echo "$OUT" | sed 's/^/    | /'
fi

_run "$GATE" "T7-anchor-lost" "$BASE" "$W/anchor_lost.md"
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'FAIL tracker-structural: A3'; then
    _pass "T7 RED — A3 fires when a governing §11.4.114 citation is dropped from a preamble"
else
    _fail "T7 RED — A3 did not fire on a dropped anchor citation (rc=$RC)"
    echo "$OUT" | sed 's/^/    | /'
fi

# ── T8 the declared-removal path ─────────────────────────────────────────
printf '# declared\nbad_over_deleted.md\tH\t2026-09-01\tsuperseded by Fixed.md\toperator, commit 8dad4e3\n' \
    > "$W/declared.tsv"
_run "$GATE" "T8-declared" "$BASE" "$FIX/bad_over_deleted.md" "$W/declared.tsv"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'declared in'; then
    _pass "T8 DECLARED — a fully-populated manifest row makes the same removal pass, and says so out loud"
else
    _fail "T8 DECLARED — a declared removal was still refused (rc=$RC). Removals must be POSSIBLE, only never silent."
    echo "$OUT" | sed 's/^/    | /'
fi

# ── T9 the rubber-stamp rejection ────────────────────────────────────────
printf 'bad_over_deleted.md\tH\t2026-09-01\t\t\n' > "$W/stamp.tsv"
_run "$GATE" "T9-rubber-stamp" "$BASE" "$FIX/bad_over_deleted.md" "$W/stamp.tsv"
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'FAIL tracker-structural: A1'; then
    _pass "T9 RUBBER-STAMP — an empty reason/authority is NOT a declaration; the gate still FAILs"
else
    _fail "T9 RUBBER-STAMP — a blank-field row was accepted as a declaration (rc=$RC)"
    echo "$OUT" | sed 's/^/    | /'
fi

# ── T10 the LIVE corpus ──────────────────────────────────────────────────
if command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    OUT="$(bash "$GATE" 2>&1)"; RC=$?
    if [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -q '^FAIL '; then
        _pass "T10 LIVE — the real Issues.md + Fixed.md pass against HEAD (rc=0); the gate is not a deadlock"
        echo "$OUT" | sed 's/^/    | /'
    else
        _fail "T10 LIVE — the gate refuses the real corpus (rc=$RC)"
        echo "$OUT" | sed 's/^/    | /'
    fi
else
    echo "SKIP test: T10 — no git work tree available (§11.4.3)"
fi

# ── T11 / T12 §1.1 PAIRED MUTATIONS ──────────────────────────────────────
# Mutate a COPY. The tracked gate is never edited, so nothing can be staged
# by accident (§11.4.84).

# M1 — neuter A1's counter: a vanished section is recorded but never counted,
# so the "all sections survive" branch is taken unconditionally.
sed 's|_undeclared=\$((_undeclared + 1))|_undeclared=$((_undeclared + 0))  # MUTATED for paired §1.1 proof|' \
    "$GATE" > "$W/mut_a1.sh"
if ! grep -q 'MUTATED for paired' "$W/mut_a1.sh"; then
    _fail "T11 §1.1 — the M1 mutation did NOT land in the copy; the result below would prove nothing"
else
    _run "$W/mut_a1.sh" "T11-mutated" "$BASE" "$FIX/bad_over_deleted.md"
    if [ "$RC" -eq 0 ]; then
        _pass "T11 §1.1 — the A1-weakened gate MISSES the historical defect (rc=0), so T1's failure is produced by A1 itself"
    else
        _fail "T11 §1.1 — the weakened gate still failed (rc=$RC): T1's verdict does not depend on the A1 assertion"
    fi
fi

# M2 — neuter A3: the anchor comparison always reports a hit.
sed 's|                if ! grep -qF "\$_A" "\$_pc"; then|                if false; then  # MUTATED for paired §1.1 proof|' \
    "$GATE" > "$W/mut_a3.sh"
if ! grep -q 'MUTATED for paired' "$W/mut_a3.sh"; then
    _fail "T12 §1.1 — the M2 mutation did NOT land in the copy; the result below would prove nothing"
else
    _run "$W/mut_a3.sh" "T12-mutated" "$BASE" "$W/anchor_lost.md"
    if [ "$RC" -eq 0 ]; then
        _pass "T12 §1.1 — the A3-weakened gate MISSES the dropped anchor (rc=0), so T7's failure is produced by A3 itself"
    else
        _fail "T12 §1.1 — the weakened gate still failed (rc=$RC): T7's verdict does not depend on the A3 assertion"
    fi
fi

echo "── summary tracker-structural-test: PASS=$PASS FAIL=$FAIL ──"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
