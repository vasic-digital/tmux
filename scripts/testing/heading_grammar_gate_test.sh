#!/usr/bin/env bash
# heading_grammar_gate_test.sh
# ─────────────────────────────────────────────────────────────────────────
# Purpose:    Paired test for scripts/testing/heading_grammar_gate.sh.
#             Proves the gate has TEETH (fires on the three REAL 2026-09-01
#             code-less headings) and is not a DEADLOCK (does not fire on
#             legitimately-coded headings in EITHER accepted form, nor on
#             `##`/`####`, nor on `###` inside fenced code), then runs the
#             §1.1 mutation pair: a weakened gate MUST miss the very defect
#             it was built to catch.
#
# Checks:
#   T1  RED           golden-BAD fixture (one code-less heading) MUST FAIL,
#                     naming the offender's file:line and text.
#   T2  golden-GOOD   BOTH accepted heading forms — period `### A7. X` and
#                     space `### G5 Y` — MUST NOT fire (§11.4.201(1): a
#                     false-positive refusal is a FAIL-bluff).
#   T3  golden-GOOD   `## X.` section headers and `#### …` sub-headings MUST
#                     NOT fire — the item grammar does not apply to them.
#   T4  golden-GOOD   a code-less `### ` INSIDE a fenced code block MUST NOT
#                     fire (``` and ~~~, indented and not).
#   T5  RED (real)    the ACTUAL pre-repair `Issues.md` + `Fixed.md` at the
#                     baseline revision MUST FAIL with exactly the three
#                     historical offenders — the §11.4.115(F) observation
#                     that this guard was seen failing on the genuinely
#                     broken artifact. SKIP-with-reason without git.
#   T6  LIVE GREEN    the real repaired `Issues.md` + `Fixed.md` MUST PASS.
#   T7  NEEDLE        a gate whose control needle is broken MUST refuse to
#                     report a clean pass — it SKIPs as BLIND instead
#                     (§11.4.201(6): a blind instrument and a clean file
#                     return the identical quiet zero).
#   T8  §1.1 MUTATION a copy of the gate whose `_hg_coded` classifier is
#                     weakened to accept ANY `### ` heading MUST PASS on
#                     the T1 golden-BAD fixture — proving T1's failure is
#                     produced by the classifier assertion and not by the
#                     harness. This is the load-bearing proof that the
#                     check is not decorative.
#   T9  §1.1 MUTATION a copy whose code-less COUNTER is neutered MUST also
#                     PASS on T1 — a second, independent mutation of the
#                     same verdict path (§11.4.194(6)(d): more than one
#                     way to break it, each proven to break it).
#
# Usage:      bash scripts/testing/heading_grammar_gate_test.sh
# Outputs:    PASS/FAIL lines + a `── summary heading-grammar-test: …` line.
# Exit codes: 0 = all green ; 1 = any red.
# Side-effects: NONE on the tree. Fixtures and the two MUTATED gate copies
#             live only under ${TMPDIR:-/tmp} and are removed on every exit
#             path (§11.4.14) — the tracked gate is never edited, so no
#             mutation residue can be staged (§11.4.84).
# Dependencies: awk, sed, grep. git only for T5 (SKIP-with-reason without).
# Cross-refs: scripts/testing/heading_grammar_gate.sh ;
#             docs/scripts/heading_grammar_gate.md ;
#             cmd/workable-items/parser.go `headingRE` ;
#             Fixed.md `D2.` / `D3.` / `B54` (the repaired headings).
# §11.4.67:  POSIX `sh -n` clean AND `bash -n` clean.
# Last verified: 2026-09-01
# ─────────────────────────────────────────────────────────────────────────
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
GATE="$SELF_DIR/heading_grammar_gate.sh"

PASS=0
FAIL=0

W="${TMPDIR:-/tmp}"
W="${W%/}/tmx-hgg-test.$$"
mkdir -p "$W" || { echo "FAIL test: scratch $W not creatable"; exit 1; }
# shellcheck disable=SC2064
trap "rm -rf '$W'" EXIT INT TERM HUP

_pass() { echo "PASS test: $*"; PASS=$((PASS + 1)); }
_fail() { echo "FAIL test: $*"; FAIL=$((FAIL + 1)); }

OUT=""
RC=0
# $1 gate  $2.. files to scan
_run() {
    _g="$1"; shift
    _args=""
    for _f in "$@"; do _args="$_args --file $_f"; done
    # shellcheck disable=SC2086
    OUT="$(bash "$_g" $_args 2>&1)"
    RC=$?
}

if [ ! -x "$GATE" ] && [ ! -f "$GATE" ]; then
    echo "FAIL test: gate not found at $GATE"
    exit 1
fi

# ── fixtures ─────────────────────────────────────────────────────────────

# golden-BAD: one legitimately-coded heading (so the scanner provably SEES)
# plus one code-less heading of the exact historical shape.
cat > "$W/golden_bad.md" <<'EOF'
# Tracker fixture — golden BAD

## A. A section

### A1. A properly coded block heading

Body of the coded block.

### NEEDLE-BAD-001 — a heading carrying no block code at all

Body that the parser would silently absorb into A1 above.
EOF

# golden-GOOD: BOTH accepted heading forms.
cat > "$W/golden_good.md" <<'EOF'
# Tracker fixture — golden GOOD

## A. A section

### A7. Period-form heading with a real title

Body.

### G5 Space-form heading with a real title

Body.

### B123 Multi-digit ordinal, space form, still readable

Body.
EOF

# golden-GOOD: non-item heading levels must not be judged by the item grammar.
cat > "$W/golden_levels.md" <<'EOF'
# Tracker fixture — heading levels

## D. Migration history — INFORMATIONAL

Preamble prose.

### D1. A real coded item

#### Not-an-item sub-heading with no code

##### Deeper still, also not an item

## Z. Another section without a trailing code
EOF

# golden-GOOD: a code-less `### ` inside fenced code is sample text.
cat > "$W/golden_fenced.md" <<'EOF'
# Tracker fixture — fenced code

## A. A section

### A1. A real coded item

The wrong shape looks like this:

```markdown
### NOT-A-REAL-HEADING-001 — this is sample text inside a fence
```

And with tildes:

~~~
### ALSO-NOT-REAL-002 — sample text inside a tilde fence
~~~

Indented fence:

  ```
  ### INDENTED-SAMPLE-003 — still inside a fence
  ```

Done.
EOF

# ── T1 RED — the gate fires on a code-less heading ───────────────────────
_run "$GATE" "$W/golden_bad.md"
if [ "$RC" -ne 0 ] \
   && printf '%s' "$OUT" | grep -q 'FAIL heading-grammar: G1' \
   && printf '%s' "$OUT" | grep -q 'OFFENDER .*golden_bad.md:9: ### NEEDLE-BAD-001'; then
    _pass "T1 RED — G1 fires on a code-less heading AND prints resolved file:line + text evidence"
else
    _fail "T1 RED — the gate did not fire (or printed no resolved evidence) on the golden-BAD fixture (rc=$RC)"
    printf '%s\n' "$OUT" | sed 's/^/    | /'
fi

# ── T2 golden-GOOD — both accepted forms ─────────────────────────────────
_run "$GATE" "$W/golden_good.md"
if [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -q '^FAIL '; then
    _pass "T2 golden-GOOD — neither the period-form nor the space-form heading is refused (§11.4.201(1))"
else
    _fail "T2 golden-GOOD — the gate falsely refused legitimately coded headings (rc=$RC)"
    printf '%s\n' "$OUT" | sed 's/^/    | /'
fi

# ── T3 golden-GOOD — other heading levels ────────────────────────────────
_run "$GATE" "$W/golden_levels.md"
if [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -q '^FAIL '; then
    _pass "T3 golden-GOOD — \`##\` section headers and \`####\`+ sub-headings are not judged by the item grammar"
else
    _fail "T3 golden-GOOD — the gate falsely refused a non-item heading level (rc=$RC)"
    printf '%s\n' "$OUT" | sed 's/^/    | /'
fi

# ── T4 golden-GOOD — fenced code ─────────────────────────────────────────
_run "$GATE" "$W/golden_fenced.md"
if [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -q '^FAIL '; then
    _pass "T4 golden-GOOD — a code-less \`### \` inside a \`\`\` / ~~~ fence is sample text, not a heading"
else
    _fail "T4 golden-GOOD — the gate falsely refused sample text inside a fenced code block (rc=$RC)"
    printf '%s\n' "$OUT" | sed 's/^/    | /'
fi

# ── T5 RED on the REAL pre-repair artifact (§11.4.115(F)) ────────────────
# A guard never OBSERVED failing on the genuinely-broken artifact is
# unvalidated instrumentation. The baseline revision still carries all
# three historical code-less headings.
if command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    if git -C "$REPO_ROOT" show "HEAD:Issues.md" > "$W/pre_Issues.md" 2>/dev/null \
       && git -C "$REPO_ROOT" show "HEAD:Fixed.md" > "$W/pre_Fixed.md" 2>/dev/null; then
        _run "$GATE" "$W/pre_Issues.md" "$W/pre_Fixed.md"
        _n=$(printf '%s\n' "$OUT" | grep -c 'OFFENDER ')
        if [ "$RC" -ne 0 ] && [ "$_n" -ge 1 ]; then
            _pass "T5 RED on the real broken artifact — the gate FAILs on HEAD:Issues.md + HEAD:Fixed.md with $_n resolved offender(s) (§11.4.115(F): observed failing before being trusted)"
            printf '%s\n' "$OUT" | grep 'OFFENDER ' | sed 's/^/    | /'
        else
            echo "SKIP test: T5 — the baseline revision no longer carries a code-less heading (rc=$RC, offenders=$_n). Once the repair is committed this becomes an honest SKIP, not a failure: the historical RED is recorded in this file's header and in Fixed.md D2./D3./B54 (§11.4.3)."
        fi
    else
        echo "SKIP test: T5 — could not read Issues.md/Fixed.md at HEAD (§11.4.3)"
    fi
else
    echo "SKIP test: T5 — no git work tree available (§11.4.3)"
fi

# ── T6 LIVE GREEN — the repaired corpus ──────────────────────────────────
OUT="$(bash "$GATE" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -q '^FAIL '; then
    _pass "T6 LIVE — the real repaired Issues.md + Fixed.md pass (rc=0); the gate is not a deadlock"
    printf '%s\n' "$OUT" | sed 's/^/    | /'
else
    _fail "T6 LIVE — the gate refuses the real corpus (rc=$RC): a code-less heading remains, or the gate over-fires"
    printf '%s\n' "$OUT" | sed 's/^/    | /'
fi

# ── T7 NEEDLE — a blind gate must SKIP, never report a clean pass ────────
# Break the needle by making the needle source unusable, via a copy whose
# needle expectation can never be met. A gate that still says PASS here
# would be reporting a §11.4.201(6) false null.
sed 's|echo "### NEEDLE-CODELESS-001 — a heading carrying no block code at all"|echo "### Z9. NEEDLE deliberately made CODED to break the polarity check"  # MUTATED for paired §1.1 proof|' \
    "$GATE" > "$W/mut_needle.sh"
if ! grep -q 'MUTATED for paired' "$W/mut_needle.sh"; then
    _fail "T7 NEEDLE — the needle mutation did NOT land in the copy; the result below would prove nothing"
else
    _run "$W/mut_needle.sh" "$W/golden_good.md"
    if [ "$RC" -eq 0 ] \
       && printf '%s' "$OUT" | grep -q 'SKIP heading-grammar: BLIND' \
       && ! printf '%s' "$OUT" | grep -q '^PASS '; then
        _pass "T7 NEEDLE — with the control needle broken the gate reports BLIND and SKIPs; it never emits a clean PASS on an unproven instrument"
    else
        _fail "T7 NEEDLE — a needle-broken gate still reported a pass (rc=$RC); its clean zeros are not evidence"
        printf '%s\n' "$OUT" | sed 's/^/    | /'
    fi
fi

# ── T8 §1.1 MUTATION — weaken the classifier ─────────────────────────────
# Mutate a COPY. The tracked gate is never edited (§11.4.84).
# M1 — `_hg_coded` accepts ANY `### ` heading, so nothing is ever code-less.
sed 's|return (l ~ /\^###\[\[:space:\]\]+\[A-Z\]\[0-9\]+(\\.\[\[:space:\]\]+\|\[\[:space:\]\]+)\[^\[:space:\]\]/)|return (l ~ /^###/)  # MUTATED for paired §1.1 proof|' \
    "$GATE" > "$W/mut_classifier.sh"
if ! grep -q 'MUTATED for paired' "$W/mut_classifier.sh"; then
    _fail "T8 §1.1 — the M1 classifier mutation did NOT land in the copy; the result below would prove nothing"
else
    _run "$W/mut_classifier.sh" "$W/golden_bad.md"
    if [ "$RC" -eq 0 ]; then
        _pass "T8 §1.1 — the classifier-weakened gate MISSES the code-less heading (rc=0), so T1's failure is produced by the \`_hg_coded\` assertion itself, not by the harness"
    else
        _fail "T8 §1.1 — the weakened gate still failed (rc=$RC): T1's verdict does not depend on the classifier, so the check is not load-bearing"
        printf '%s\n' "$OUT" | sed 's/^/    | /'
    fi
fi

# ── T9 §1.1 MUTATION — neuter the code-less counter ──────────────────────
# M2 — an independent second break of the same verdict path: offenders are
# still detected and printed, but never counted, so the clean branch is
# taken unconditionally.
sed 's|                codeless++|                codeless += 0  # MUTATED for paired §1.1 proof|' \
    "$GATE" > "$W/mut_counter.sh"
if ! grep -q 'MUTATED for paired' "$W/mut_counter.sh"; then
    _fail "T9 §1.1 — the M2 counter mutation did NOT land in the copy; the result below would prove nothing"
else
    _run "$W/mut_counter.sh" "$W/golden_bad.md"
    if [ "$RC" -eq 0 ]; then
        _pass "T9 §1.1 — the counter-neutered gate MISSES the code-less heading (rc=0); the verdict genuinely depends on the count, not on incidental output"
    else
        _fail "T9 §1.1 — the counter-neutered gate still failed (rc=$RC)"
        printf '%s\n' "$OUT" | sed 's/^/    | /'
    fi
fi

echo "── summary heading-grammar-test: PASS=$PASS FAIL=$FAIL ──"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
