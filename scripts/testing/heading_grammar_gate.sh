#!/usr/bin/env bash
# heading_grammar_gate.sh
# ─────────────────────────────────────────────────────────────────────────
# Purpose:    §11.4.135 PERMANENT REGRESSION GUARD for the 2026-09-01
#             CODE-LESS TRACKER HEADING defect. CAPTURED root cause: the
#             tracker grammar never REQUIRED a `### ` item heading to carry
#             a block code, so a hand-added heading whose text did not
#             start with `<LETTER><DIGITS>` was silently INVISIBLE to
#             `cmd/workable-items/parser.go` — and its whole body was
#             absorbed into the `raw_body` of the PRECEDING coded block.
#             The item then had no row, no TMX-ID, no status of its own,
#             and no way to be reported on.
#
#             Three unrelated triggers produced the identical defect:
#               1. `Issues.md` `### M24-ESCAPE-001 — …` — a CLOSED record
#                  hand-written into the OPEN tracker (a §11.4.19
#                  atomic-migration miss). Absorbed into `D2`.
#               2. `Fixed.md` `### TMX-051 — Per-session color …` — commit
#                  `89324dc` (the ATM- → TMX- ticket-prefix migration)
#                  rewrote a heading whose text HAPPENED to begin with a
#                  ticket-id literal. Absorbed into `D1.`.
#               3. `Fixed.md` `### NEZHA-INSTALL-v1.0.26-001 (closed) — …`
#                  — commit `7aefdf2`, a §12.10 doc update. Also absorbed
#                  into `D1.`.
#             MEASURED: pre-repair, the parsed `D1.` block spanned 7703
#             chars and contained BOTH orphan bodies; post-repair it spans
#             2200 and contains neither. `md-to-db` went from
#             `fixed_parsed=83 inserted=0` to `fixed_parsed=86 inserted=3`.
#
#             Why nothing existing caught it: every other check in this
#             repo reasons about blocks the parser ALREADY SEES. A heading
#             the parser skips is, to all of them, not a heading at all —
#             the §11.4.201(6) FALSE NULL (a blind instrument and a clean
#             file return the identical quiet zero). This gate is the only
#             one that asserts on the raw document GRAMMAR, before the
#             parser's own filter has a chance to hide the defect.
#
# Asserts (per tracker file):
#   G1 CODE-BEARING  every `### ` heading carries a block code that
#                    `parser.go`'s `headingRE` can read:
#                      ^###\s+([A-Z])(\d+)(?:\.\s+|\s+)(\S.*)$
#                    i.e. ONE uppercase letter, then digits, then either
#                    `. ` or ` `, then a non-blank title. Both the
#                    period-form (`### A7. X`) and the space-form
#                    (`### G5 Y`) are VALID — this gate mirrors the
#                    parser's grammar exactly rather than inventing a
#                    stricter one, because a heading the parser CAN read
#                    is the whole property under test (§11.4.201(11):
#                    probe the artifact through its real path, never a
#                    proxy).
#
# Deliberately NOT flagged (§11.4.201(1) — a false-positive refusal is a
# FAIL-bluff exactly as a false-negative pass is a PASS-bluff):
#   * `## X.` section headers and `#### …` sub-headings — the parser's
#     item grammar does not apply to them.
#   * `###` inside a fenced code block (``` or ~~~, any fence length,
#     indented or not) — that is sample text, not a heading. This gate
#     tracks fences and skips their contents.
#   * indented `###` — the parser anchors at column 0, so an indented
#     line is never an item heading.
#   * `###` with no following whitespace (`###foo`) — not a Markdown
#     ATX heading at all (`parser.go`'s `anyHeadingRE` requires `#{1,6}\s`).
#
# §11.4.201(7)(b) CONTROL NEEDLE — a zero-finding result is refused unless
#             the instrument is PROVEN to see, in BOTH polarities, through
#             the SAME code path:
#               (a) SEEING   — the scanner must extract >0 `### ` headings
#                              from the file, and >0 of them must classify
#                              as CODED. Zero headings extracted ⇒ BLIND ⇒
#                              SKIP-with-reason, never a confident clean 0.
#               (b) POLARITY — two synthetic needle lines, one known-CODED
#                              and one known-CODE-LESS, are pushed through
#                              the SAME scanner before any file is judged.
#                              A classifier stuck at "everything is coded"
#                              would return a clean 0 on a broken file; the
#                              code-less needle is what refutes that. If
#                              either needle lands on the wrong side the
#                              gate reports BLIND and SKIPs.
#             The needle counts are PRINTED on every run so the null is
#             auditable, not merely asserted.
#
# Usage:      bash scripts/testing/heading_grammar_gate.sh
#               [--file <path>]   (repeatable; default: Issues.md + Fixed.md
#                                  at the repo root)
#               [--quiet]         (suppress the per-heading inventory line)
# Outputs:    `[evidence …]` lines (including the control-needle result and,
#             on FAIL, one `<file>:<line>: <heading text>` per offender),
#             then PASS/FAIL/SKIP lines, then a
#             `── summary heading-grammar: …` line.
# Exit codes: 0 = PASS or SKIP-with-reason ; 1 = FAIL (>=1 code-less heading).
#             A SKIP is always printed with its reason and never silently
#             counted as a pass.
# Side-effects: NONE. Read-only; one temp dir under ${TMPDIR:-/tmp}, removed
#             on every exit path (§11.4.14). Honours TMPDIR — never
#             hardcodes /tmp (`Fixed.md` D2 TMPDIR-HARDCODE-001 / TMX-092).
# Dependencies: awk, grep (POSIX). No git, no network, no build.
# Cross-refs: cmd/workable-items/parser.go `headingRE` (the grammar this
#             mirrors) ; Fixed.md `D2.` / `D3.` / `B54` (the three repaired
#             headings) ; scripts/testing/tracker_structural_integrity.sh
#             (the sibling gate this one complements: that one asserts a
#             tracker did not LOSE structure across revisions, this one
#             asserts every heading IS structure the parser can read) ;
#             docs/scripts/heading_grammar_gate.md (§11.4.18) ;
#             scripts/testing/heading_grammar_gate_test.sh (§1.1).
# §11.4.67:  POSIX `sh -n` clean AND `bash -n` clean (no arrays, no `[[`,
#             no herestrings, no `local`).
# Last verified: 2026-09-01
# ─────────────────────────────────────────────────────────────────────────
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"

PASS=0
FAIL=0
SKIP=0
QUIET=0

SCRATCH="${TMPDIR:-/tmp}"
SCRATCH="${SCRATCH%/}/tmx-hgg.$$"
mkdir -p "$SCRATCH" 2>/dev/null || {
    echo "SKIP heading-grammar: scratch dir $SCRATCH not creatable — §11.4.3"
    exit 0
}
# shellcheck disable=SC2064
trap "rm -rf '$SCRATCH'" EXIT INT TERM HUP

FILES_LIST="$SCRATCH/files.lst"
: > "$FILES_LIST"

_pass() { echo "PASS heading-grammar: $*"; PASS=$((PASS + 1)); }
_fail() { echo "FAIL heading-grammar: $*"; FAIL=$((FAIL + 1)); }
_skip() { echo "SKIP heading-grammar: $*"; SKIP=$((SKIP + 1)); }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --file)    echo "${2:-}" >> "$FILES_LIST"; shift 2 ;;
        --quiet)   QUIET=1; shift ;;
        -h|--help) sed -n '1,110p' "$0"; exit 0 ;;
        *)         echo "FAIL heading-grammar: unknown argument '$1'"; exit 1 ;;
    esac
done

if [ ! -s "$FILES_LIST" ]; then
    echo "$REPO_ROOT/Issues.md" >> "$FILES_LIST"
    echo "$REPO_ROOT/Fixed.md"  >> "$FILES_LIST"
fi

# ── the scanner ──────────────────────────────────────────────────────────
# ONE code path, used for BOTH the real trackers and the control needle.
# Emits, on stdout:
#     HEADINGS <n>        `### ` headings seen outside fenced code
#     CODED    <n>        of those, readable by parser.go's headingRE
#     CODELESS <n>        of those, NOT readable — the defect class
#     OFFENDER <line>\t<text>   one per code-less heading
#
# MUTATION SURFACE (§1.1): the `_hg_coded` regex below is the load-bearing
# assertion. The paired test in heading_grammar_gate_test.sh weakens it and
# asserts the golden-bad fixture is then MISSED.
_scan() {
    awk '
        function _hg_coded(l) {
            # Mirrors cmd/workable-items/parser.go headingRE:
            #   ^###\s+([A-Z])(\d+)(?:\.\s+|\s+)(\S.*)$
            # ONE uppercase letter, >=1 digit, then ". " or " ", then a
            # non-blank title. Both heading forms are legitimate.
            return (l ~ /^###[[:space:]]+[A-Z][0-9]+(\.[[:space:]]+|[[:space:]]+)[^[:space:]]/)
        }
        {
            line = $0

            # ── fenced-code tracking (``` / ~~~, any length, indented ok).
            # A heading inside a fence is sample text, not a heading
            # (§11.4.201(1) false-positive guard).
            if (match(line, /^[[:space:]]*(```+|~~~+)/)) {
                tok  = substr(line, RSTART, RLENGTH)
                sub(/^[[:space:]]*/, "", tok)
                mark = substr(tok, 1, 1)
                if (fence == "") { fence = mark; next }
                if (fence == mark) { fence = ""; next }
                # a different fence char while inside a fence: literal text
            }
            if (fence != "") next

            # ── only exactly-three-hash ATX headings at column 0.
            if (line ~ /^####/) next
            if (line !~ /^###[[:space:]]/) next

            headings++
            if (_hg_coded(line)) {
                coded++
            } else {
                codeless++
                printf "OFFENDER %d\t%s\n", FNR, line
            }
        }
        END {
            printf "HEADINGS %d\n", headings + 0
            printf "CODED %d\n",    coded + 0
            printf "CODELESS %d\n", codeless + 0
        }
    ' "$1" 2>/dev/null
}

_field() { grep -E "^$2 " "$1" | awk '{ print $2 + 0 }' | head -n 1; }

# ── §11.4.201(7)(b) CONTROL NEEDLE — run BEFORE judging any file ─────────
# Both polarities, through the SAME `_scan` above. A classifier that cannot
# tell the two apart cannot be trusted to report a clean zero.
NEEDLE_SRC="$SCRATCH/needle.md"
{
    echo "### A7. needle CODED period-form heading with a real title"
    echo "### G5 needle CODED space-form heading with a real title"
    echo "### NEEDLE-CODELESS-001 — a heading carrying no block code at all"
} > "$NEEDLE_SRC"

NEEDLE_OUT="$SCRATCH/needle.out"
_scan "$NEEDLE_SRC" > "$NEEDLE_OUT" 2>/dev/null

N_TOTAL=$(_field "$NEEDLE_OUT" HEADINGS)
N_CODED=$(_field "$NEEDLE_OUT" CODED)
N_LESS=$(_field "$NEEDLE_OUT" CODELESS)
: "${N_TOTAL:=0}" "${N_CODED:=0}" "${N_LESS:=0}"

echo "[evidence heading-grammar] control needle: 3 synthetic headings pushed through the SAME scanner → seen=$N_TOTAL coded=$N_CODED code-less=$N_LESS (expected seen=3 coded=2 code-less=1)"

if [ "$N_TOTAL" -ne 3 ] || [ "$N_CODED" -ne 2 ] || [ "$N_LESS" -ne 1 ]; then
    _skip "BLIND — the control needle did not classify both polarities correctly (seen=$N_TOTAL coded=$N_CODED code-less=$N_LESS, expected 3/2/1). A zero-finding result from this scanner would be a false null (§11.4.201(6)), not evidence. Refusing to report a clean pass."
    echo "── summary heading-grammar: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
    exit 0
fi

# ── per-file assertion ───────────────────────────────────────────────────
while IFS= read -r _f; do
    [ -n "$_f" ] || continue
    case "$_f" in
        /*) _path="$_f" ;;
        *)  _path="$REPO_ROOT/$_f" ;;
    esac
    _label="$(basename "$_path")"

    if [ ! -f "$_path" ]; then
        _skip "$_label — file not found at '$_path'; nothing to scan (§11.4.3)"
        continue
    fi

    _out="$SCRATCH/scan.$_label.out"
    _scan "$_path" > "$_out" 2>/dev/null

    _total=$(_field "$_out" HEADINGS)
    _coded=$(_field "$_out" CODED)
    _less=$(_field "$_out" CODELESS)
    : "${_total:=0}" "${_coded:=0}" "${_less:=0}"

    # Per-file SEEING half of the needle: a file with zero extracted
    # headings and a genuinely clean file both yield "0 code-less".
    if [ "$_total" -eq 0 ]; then
        _skip "$_label — BLIND: the scanner extracted 0 \`### \` headings from this file; a zero-code-less result here would be a false null, not evidence (§11.4.201(6))"
        continue
    fi

    if [ "$QUIET" -eq 0 ]; then
        echo "[evidence heading-grammar] $_label: scanner SEES headings=$_total coded=$_coded code-less=$_less"
    fi

    if [ "$_less" -eq 0 ]; then
        _pass "G1 $_label — all $_total \`### \` heading(s) carry a parser-readable block code"
    else
        # RESOLVED EVIDENCE on every refusal (§11.4.201(5)): the exact
        # file:line and the offending text, so the finding is actionable
        # in one step rather than requiring a re-hunt.
        grep '^OFFENDER ' "$_out" | while IFS= read -r _o; do
            _ln=$(printf '%s\n' "$_o" | awk '{ print $2 }')
            _tx=$(printf '%s\n' "$_o" | awk -F '\t' '{ print $2 }')
            echo "[evidence heading-grammar] OFFENDER $_path:$_ln: $_tx"
        done
        _fail "G1 $_label — $_less of $_total \`### \` heading(s) carry NO block code, so cmd/workable-items/parser.go skips them and their bodies are absorbed into the PRECEDING coded block (invisible to the DB). Give each a free \`<LETTER><DIGITS>\` code (period-form \`### D2. Title\` or space-form \`### D2 Title\`)."
    fi
done < "$FILES_LIST"

echo "── summary heading-grammar: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
