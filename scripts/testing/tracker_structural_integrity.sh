#!/usr/bin/env bash
# tracker_structural_integrity.sh
# ─────────────────────────────────────────────────────────────────────────
# Purpose:    §11.4.135 PERMANENT REGRESSION GUARD for the 2026-09-01
#             over-deletion defect (commit 8dad4e3, review round 2,
#             BLOCKING). CAPTURED root cause: an ad-hoc corpus-repair loop
#             deleted four `### G1..G4` item blocks from `Issues.md` and
#             ALSO took the `## H.` SECTION HEADER and that section's
#             §11.4.114 preamble with it. It was caught only by an
#             independent human-driven review and restored verbatim from
#             `git show HEAD:Issues.md` BEFORE the commit landed.
#
#             The defect was possible because NO check anywhere in this
#             repo compares a tracker document against its PREVIOUS
#             COMMITTED REVISION. The existing machinery
#             (`cmd/workable-items` + `scripts/tests/51_*`) asserts a
#             `md-to-db` → `db-to-md` ROUND TRIP is byte-identical — a
#             SELF-REFERENTIAL check: `sync_md_to_db.go` reads the file
#             verbatim into `document_sources`, so content deleted BEFORE
#             the sync is absorbed into the DB and replayed back
#             identically. The round trip stays green on a damaged file.
#             This gate supplies the missing prior-revision assertion.
#
# Asserts (per tracker file, baseline-revision vs current):
#   A1 SECTION-SURVIVAL     every `## <LETTER>.` section present in the
#                           baseline is still present, keyed on the LETTER
#                           (so RETITLING a section is legitimate and does
#                           not fire). A vanished letter FAILs unless it is
#                           declared in the removals manifest.
#   A2 PREAMBLE-NOT-EMPTIED a section whose baseline preamble had content
#                           MUST still have content. Binary, threshold-free
#                           (§11.4.6): rewording and annotating pass;
#                           gutting fires.
#   A3 ANCHOR-SURVIVAL      every governing `§N.N…` anchor cited in a
#                           baseline preamble is still cited in that
#                           section's current preamble. This is the clause
#                           that catches the exact historical loss (the
#                           `## H.` preamble cited §11.4.114).
#
# Removals are POSSIBLE but never SILENT. Two declared paths:
#   (a) TOMBSTONE  — keep the `## X.` header, annotate it as closed. A1
#                    passes naturally. This is the corpus's own precedent
#                    (`## G.` was annotated, not deleted, in 8dad4e3).
#   (b) MANIFEST   — to remove the header itself, add a row to
#                    scripts/testing/tracker_section_removals.tsv:
#                      <file>\t<letter>\t<ISO-date>\t<reason>\t<authority>
#                    ALL FIVE fields must be non-empty; a blank reason or
#                    authority is NOT a declaration (a rubber stamp is not
#                    a decision). The row lands in the same commit as the
#                    removal, so a reviewer sees an ADDED line rather than
#                    having to notice an ABSENCE — the failure mode that
#                    made this defect nearly ship.
#   There is deliberately NO env-var / CLI escape: an override that leaves
#   no trace in the tree is a bypass, not a recorded deferral.
#
# Usage:      bash scripts/testing/tracker_structural_integrity.sh
#               [--baseline <git-ref>]      (default: HEAD)
#               [--file <path>]             (repeatable; default Issues.md
#                                            + Fixed.md at repo root)
#               [--manifest <path>]         (default:
#                                            scripts/testing/tracker_section_removals.tsv)
#               [--pair <label>:<baseline-file>:<current-file>]
#                                           (repeatable; FIXTURE mode —
#                                            compares two plain files, no
#                                            git. Used by the paired test.)
# Outputs:    `[evidence …]` lines, then PASS/FAIL/SKIP lines, then a
#             `── summary tracker-structural: …` line.
# Exit codes: 0 = PASS or SKIP-with-reason ; 1 = FAIL (>=1 assertion).
#             A SKIP is always printed with its reason and never silently
#             counted as a pass.
# Side-effects: NONE. Read-only: `git show` into a temp dir under
#             ${TMPDIR:-/tmp}, removed on every exit path (§11.4.14).
# Dependencies: awk, grep, sed, sort (POSIX). `git` only in the default
#             (non-`--pair`) mode; absent git → SKIP-with-reason (§11.4.3),
#             never a false refusal (§11.4.201(1)).
# Cross-refs: Issues.md §H (the section that was over-deleted) ;
#             commit 8dad4e3 message, review round 2 ;
#             scripts/tests/51_workable_items_db_integrity.sh (the
#             self-referential round-trip this gate complements) ;
#             cmd/workable-items/sync_md_to_db.go (verbatim absorption) ;
#             docs/scripts/tracker_structural_integrity.md (§11.4.18) ;
#             scripts/testing/tracker_structural_integrity_test.sh (§1.1).
# §11.4.201: the extractor is control-needle-proven on every run — if the
#             BASELINE yields ZERO sections the gate reports BLIND and
#             SKIPs rather than returning a confident clean zero.
# §11.4.67:  POSIX `sh -n` clean AND `bash -n` clean (no arrays, no `[[`,
#             no herestrings).
# Last verified: 2026-09-01
# ─────────────────────────────────────────────────────────────────────────
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"

BASELINE_REF="HEAD"
MANIFEST="$SELF_DIR/tracker_section_removals.tsv"
PASS=0
FAIL=0
SKIP=0

SCRATCH="${TMPDIR:-/tmp}"
SCRATCH="${SCRATCH%/}/tmx-tsi.$$"
mkdir -p "$SCRATCH" 2>/dev/null || {
    echo "SKIP tracker-structural: scratch dir $SCRATCH not creatable — §11.4.3"
    exit 0
}
# shellcheck disable=SC2064
trap "rm -rf '$SCRATCH'" EXIT INT TERM HUP

FILES_LIST="$SCRATCH/files.lst"
PAIRS_LIST="$SCRATCH/pairs.lst"
: > "$FILES_LIST"
: > "$PAIRS_LIST"

_pass() { echo "PASS tracker-structural: $*"; PASS=$((PASS + 1)); }
_fail() { echo "FAIL tracker-structural: $*"; FAIL=$((FAIL + 1)); }
_skip() { echo "SKIP tracker-structural: $*"; SKIP=$((SKIP + 1)); }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --baseline) BASELINE_REF="${2:-}"; shift 2 ;;
        --file)     echo "${2:-}" >> "$FILES_LIST"; shift 2 ;;
        --manifest) MANIFEST="${2:-}"; shift 2 ;;
        --pair)     echo "${2:-}" >> "$PAIRS_LIST"; shift 2 ;;
        -h|--help)  sed -n '1,95p' "$0"; exit 0 ;;
        *)          echo "FAIL tracker-structural: unknown argument '$1'"; exit 1 ;;
    esac
done

if [ ! -s "$FILES_LIST" ]; then
    echo "Issues.md" >> "$FILES_LIST"
    echo "Fixed.md"  >> "$FILES_LIST"
fi

# ── extractors ───────────────────────────────────────────────────────────
# Non-blank line count. MUST be awk, not `grep -c . f || echo 0`: grep prints
# "0" AND exits 1 on an empty file, so the `|| echo 0` appends a SECOND zero
# and every later `[ "$n" -gt 0 ]` dies with "integer expected" — the test's
# A2 assertion was silently BLIND until this was measured (§11.4.201(6)).
_countlines() { awk 'NF { n++ } END { print n + 0 }' "$1" 2>/dev/null; }

# Section letters, in file order. A "section" is a line of the exact shape
# `## <LETTER>. <title>`; the LETTER is the stable identity (§11.4.111
# resolve-by-stable-name — a retitle must not read as a removal).
_letters() {
    awk '
        /^## [A-Za-z]+\./ {
            match($0, /^## [A-Za-z]+\./)
            print substr($0, 4, RLENGTH - 4)
        }
    ' "$1"
}

# Preamble of one section: the content lines strictly between the `## X.`
# header and the first `### ` item heading (or the next `## ` / EOF).
# Blank lines and `---` rules are scaffolding, not content, and are dropped.
_preamble() {
    awk -v want="$2" '
        /^## [A-Za-z]+\./ {
            inseg = 0
            match($0, /^## [A-Za-z]+\./)
            if (substr($0, 4, RLENGTH - 4) == want) { inseg = 1 }
            next
        }
        /^### / { inseg = 0; next }
        inseg {
            if ($0 ~ /^[[:space:]]*$/) next
            if ($0 ~ /^-{3,}[[:space:]]*$/) next
            print
        }
    ' "$1"
}

# Governing anchor literals cited in a block of text, de-duplicated.
_anchors() { grep -oE '§[0-9]+(\.[0-9]+)*' "$1" 2>/dev/null | sort -u; }

# A removal is DECLARED only by a manifest row whose five fields are ALL
# non-empty. `<file>` is matched on basename so the manifest is
# path-layout independent.
_declared() {
    _d_file="$1"; _d_letter="$2"
    [ -f "$MANIFEST" ] || return 1
    awk -F '\t' -v f="$_d_file" -v l="$_d_letter" '
        /^[[:space:]]*#/ { next }
        NF < 5 { next }
        {
            n = split($1, parts, "/")
            base = parts[n]
            if (base == f && $2 == l &&
                $3 != "" && $4 != "" && $5 != "") { found = 1 }
        }
        END { exit(found ? 0 : 1) }
    ' "$MANIFEST"
}

# ── the comparison ───────────────────────────────────────────────────────
# $1 label   $2 baseline file   $3 current file   $4 basename for manifest
_compare() {
    _label="$1"; _base="$2"; _cur="$3"; _bn="$4"
    _lb="$SCRATCH/lb.$$"; _lc="$SCRATCH/lc.$$"
    _letters "$_base" | sort -u > "$_lb"
    _letters "$_cur"  | sort -u > "$_lc"
    _nb=$(_countlines "$_lb")
    _nc=$(_countlines "$_lc")

    # §11.4.201(6)(7)(b) CONTROL NEEDLE. A baseline with zero extracted
    # sections and a genuinely clean file both produce "0 missing". Refuse
    # to report the clean zero unless the extractor is proven to SEE.
    if [ "$_nb" -eq 0 ]; then
        _skip "$_label — BLIND: the extractor found 0 sections in the baseline; a zero-missing result here would be a false null, not evidence"
        rm -f "$_lb" "$_lc"
        return 0
    fi
    echo "[evidence tracker-structural] $_label: extractor SEES baseline sections=$_nb current sections=$_nc (control needle satisfied)"

    # ── A1 SECTION-SURVIVAL ──
    _missing=""
    _undeclared=0
    for _L in $(cat "$_lb"); do
        if ! grep -qx "$_L" "$_lc"; then
            if _declared "$_bn" "$_L"; then
                echo "[evidence tracker-structural] $_label: section '$_L' absent AND declared in $(basename "$MANIFEST") — removal is recorded, not silent"
            else
                _missing="$_missing $_L"
                _undeclared=$((_undeclared + 1))
            fi
        fi
    done
    if [ "$_undeclared" -eq 0 ]; then
        _pass "A1 $_label — all $_nb baseline sections survive (or are declared removals)"
    else
        _fail "A1 $_label — $_undeclared baseline section header(s) VANISHED with no declaration:$_missing (add a tombstone annotation, or a row to $(basename "$MANIFEST"))"
    fi

    # ── A2 PREAMBLE-NOT-EMPTIED + A3 ANCHOR-SURVIVAL ──
    _emptied=""
    _lostanchor=""
    _anchors_checked=0
    for _L in $(cat "$_lb"); do
        grep -qx "$_L" "$_lc" || continue      # gone: A1 owns that verdict
        _pb="$SCRATCH/pb.$$"; _pc="$SCRATCH/pc.$$"
        _preamble "$_base" "$_L" > "$_pb"
        _preamble "$_cur"  "$_L" > "$_pc"
        _cb=$(_countlines "$_pb")
        _cc=$(_countlines "$_pc")
        if [ "$_cb" -gt 0 ] && [ "$_cc" -eq 0 ]; then
            _emptied="$_emptied $_L"
        fi
        if [ "$_cb" -gt 0 ]; then
            for _A in $(_anchors "$_pb"); do
                _anchors_checked=$((_anchors_checked + 1))
                if ! grep -qF "$_A" "$_pc"; then
                    _lostanchor="$_lostanchor ${_L}:${_A}"
                fi
            done
        fi
        rm -f "$_pb" "$_pc"
    done

    if [ -z "$_emptied" ]; then
        _pass "A2 $_label — no surviving section had its preamble emptied"
    else
        _fail "A2 $_label — preamble content silently dropped from section(s):$_emptied"
    fi

    if [ "$_anchors_checked" -eq 0 ]; then
        _skip "A3 $_label — no governing §N.N anchors cited in any baseline preamble; nothing for this assertion to check (honest gap, not a pass)"
    elif [ -z "$_lostanchor" ]; then
        _pass "A3 $_label — all $_anchors_checked baseline preamble anchor citation(s) survive"
    else
        _fail "A3 $_label — governing anchor citation(s) LOST from the preamble:$_lostanchor"
    fi

    rm -f "$_lb" "$_lc"
}

# ── mode: fixture pairs ──────────────────────────────────────────────────
if [ -s "$PAIRS_LIST" ]; then
    while IFS= read -r _spec; do
        [ -n "$_spec" ] || continue
        _lbl="${_spec%%:*}"; _rest="${_spec#*:}"
        _bfile="${_rest%%:*}"; _cfile="${_rest#*:}"
        if [ ! -f "$_bfile" ] || [ ! -f "$_cfile" ]; then
            _fail "pair '$_lbl' — baseline '$_bfile' or current '$_cfile' missing"
            continue
        fi
        _compare "$_lbl" "$_bfile" "$_cfile" "$(basename "$_cfile")"
    done < "$PAIRS_LIST"
    echo "── summary tracker-structural: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
    [ "$FAIL" -eq 0 ] || exit 1
    exit 0
fi

# ── mode: live repo, baseline = a git revision ───────────────────────────
if ! command -v git >/dev/null 2>&1; then
    _skip "git not on PATH — cannot read the baseline revision (§11.4.3)"
    echo "── summary tracker-structural: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
    exit 0
fi
if ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    _skip "$REPO_ROOT is not a git work tree — no baseline revision to compare against (§11.4.3)"
    echo "── summary tracker-structural: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
    exit 0
fi

while IFS= read -r _rel; do
    [ -n "$_rel" ] || continue
    _cur="$REPO_ROOT/$_rel"
    _bn="$(basename "$_rel")"
    _base="$SCRATCH/base.$_bn"
    if ! git -C "$REPO_ROOT" show "$BASELINE_REF:$_rel" > "$_base" 2>/dev/null; then
        _skip "$_rel — not present at baseline '$BASELINE_REF' (new file); nothing to compare (§11.4.3)"
        continue
    fi
    if [ ! -f "$_cur" ]; then
        _fail "$_rel — present at baseline '$BASELINE_REF' but ABSENT from the working tree (whole-file loss)"
        continue
    fi
    _compare "$_rel@$BASELINE_REF→worktree" "$_base" "$_cur" "$_bn"
done < "$FILES_LIST"

echo "── summary tracker-structural: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
