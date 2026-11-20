#!/usr/bin/env bash
# helixqa_content_gate.sh — deterministic content oracle for captured evidence.
#
# Existence is NOT proof. For every manifest row `<evidence-file><TAB><marker>`
# this gate asserts the marker is present in the file's CONTENT. It is
# self-validated with a golden-good fixture (marker present -> analyzer MUST
# PASS) and a golden-bad fixture (only metadata, marker absent -> analyzer
# MUST FAIL). If either self-check is wrong the analyzer is BLIND and the gate
# fails closed — a passing analyzer cannot bluff.
#
# Usage: bash scripts/testing/helixqa_content_gate.sh
# Env:   HELIXQA_MANIFEST (optional single manifest override), RUN_ID
# Exit:  0 = analyzer calibrated and every manifest row verified; 1 otherwise.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$-helixqa-content}"
EVIDENCE_DIR="$REPO_ROOT/docs/qa/$RUN_ID/helixqa-content"
mkdir -p "$EVIDENCE_DIR/fixtures" || { echo "CM-HELIXQA-CONTENT: FAIL cannot create $EVIDENCE_DIR"; exit 1; }

SUMMARY="$EVIDENCE_DIR/summary.txt"
RESULTS="$EVIDENCE_DIR/results.tsv"
: > "$SUMMARY"; : > "$RESULTS"
printf 'ROW\tVERDICT\tREASON\tEVIDENCE\n' >> "$RESULTS"

# ── The analyzer under test (one definition, used for fixtures AND real rows) ─
analyze_file() {
    local path="$1" marker="$2"
    [ -r "$path" ] || return 1
    [ -n "$marker" ] || return 1
    grep -qF -- "$marker" "$path" || return 1
    return 0
}

# ── Golden fixtures ─────────────────────────────────────────────────────────
GOOD="$EVIDENCE_DIR/fixtures/golden_good.log"
BAD="$EVIDENCE_DIR/fixtures/golden_bad.log"
cat > "$GOOD" <<'EOF'
GATE=CM-GOLDEN-GOOD
PASS 42: golden-good fixture carries a real result marker
SUMMARY total=1 pass=1 fail=0 skip=0
EOF
# Deliberately metadata-only — file EXISTS and has bytes, but no SUMMARY marker.
cat > "$BAD" <<'EOF'
path=docs/qa/golden_bad.log
exists=true
bytes=57
EOF

calibration="NOT_RUN"
good_rc=1; bad_rc=0
analyze_file "$GOOD" "SUMMARY"; good_rc=$?
analyze_file "$BAD"  "SUMMARY"; bad_rc=$?
if [ "$good_rc" -eq 0 ] && [ "$bad_rc" -ne 0 ]; then
    calibration="CALIBRATED"
    echo "SELF_VALIDATION PASS golden-good=PASS golden-bad=FAIL" >> "$SUMMARY"
elif [ "$good_rc" -ne 0 ] && [ "$bad_rc" -ne 0 ]; then
    calibration="BLIND"
    echo "SELF_VALIDATION FAIL analyzer BLIND (golden-good not detected)" >> "$SUMMARY"
else
    calibration="BLIND"
    echo "SELF_VALIDATION FAIL analyzer PASSes golden-bad (metadata-only bluff)" >> "$SUMMARY"
fi

total=0; pass=0; fail=0

if [ "$calibration" = "CALIBRATED" ]; then
    if [ -n "${HELIXQA_MANIFEST:-}" ]; then
        manifests=("$HELIXQA_MANIFEST")
    else
        manifests=()
        while IFS= read -r m; do manifests+=("$m"); done < <(find "$REPO_ROOT/docs/qa" -name helixqa_manifest.tsv -type f 2>/dev/null | sort)
    fi

    for mf in "${manifests[@]}"; do
        [ -r "$mf" ] || continue
        while IFS=$'\t' read -r rel marker || [ -n "${rel:-}" ]; do
            case "${rel:-}" in ''|'#'*) continue ;; esac
            total=$((total + 1))
            target="$REPO_ROOT/$rel"
            if analyze_file "$target" "$marker"; then
                pass=$((pass + 1))
                printf '%s\tPASS\tmarker-found-in-content\t%s\n' "$rel" "$target" >> "$RESULTS"
            else
                fail=$((fail + 1))
                printf '%s\tFAIL\tmarker-absent-or-unreadable marker=%s\t%s\n' "$rel" "$marker" "$target" >> "$RESULTS"
            fi
        done < "$mf"
    done

    if [ "$total" -eq 0 ]; then
        echo "FAIL reason=no-evidence-manifests-found (content gate has nothing to verify)" >> "$SUMMARY"
        fail=1
    fi
else
    fail=1
fi

echo "SUMMARY total=$total pass=$pass fail=$fail calibration=$calibration" >> "$SUMMARY"
printf '%s\n' "CM-HELIXQA-CONTENT: calibration=$calibration total=$total pass=$pass fail=$fail"
printf 'EVIDENCE: %s\n' "$SUMMARY"
printf 'EVIDENCE_RESULTS: %s\n' "$RESULTS"
printf 'FIXTURES: %s %s\n' "$GOOD" "$BAD"
[ "$calibration" = "CALIBRATED" ] && [ "$fail" -eq 0 ] || exit 1
exit 0
