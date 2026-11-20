#!/usr/bin/env bash
# constitution_gates_gate.sh — runs the constitution's CM-COVENANT-114-*-PROPAGATION
# gate fleet (anchors >170) against THIS consumer with the consumer-owned
# exclusions TSV, and records per-gate PASS/FAIL counts plus full captured
# output under docs/qa/<run-id>/constitution-gates/.
#
# No metadata-only PASS: a gate counts as PASS only if it exits 0 AND its
# captured output carries the fleet's own `: PASS` verdict line.
#
# Usage: bash scripts/testing/constitution_gates_gate.sh
# Env:   COVENANT_GATE_TIMEOUT (seconds/gate, default 60), RUN_ID
# Exit:  0 = every discovered gate PASSed; 1 = any FAIL or discovery error.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATES_DIR="$REPO_ROOT/constitution/scripts/gates"
EXCLUSIONS="constitution/config/covenant_propagation_exclusions.tsv"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$-constitution-gates}"
EVIDENCE_DIR="$REPO_ROOT/docs/qa/$RUN_ID/constitution-gates"
mkdir -p "$EVIDENCE_DIR/gates" || { echo "CM-CONSTITUTION-GATES: FAIL cannot create $EVIDENCE_DIR"; exit 1; }

SUMMARY="$EVIDENCE_DIR/summary.txt"
SUMMARY_TSV="$EVIDENCE_DIR/summary.tsv"
MANIFEST="$EVIDENCE_DIR/helixqa_manifest.tsv"
: > "$SUMMARY"; : > "$SUMMARY_TSV"; : > "$MANIFEST"
printf 'GATE\tVERDICT\tRC\tEVIDENCE\n' >> "$SUMMARY_TSV"

[ -d "$GATES_DIR" ] || { echo "CM-CONSTITUTION-GATES: FAIL gates dir missing: $GATES_DIR" | tee -a "$SUMMARY"; printf 'EVIDENCE: %s\n' "$SUMMARY"; exit 1; }
if [ ! -r "$REPO_ROOT/$EXCLUSIONS" ]; then
    echo "CM-CONSTITUTION-GATES: FAIL exclusions TSV not readable: $EXCLUSIONS" | tee -a "$SUMMARY"
    printf 'EVIDENCE: %s\n' "$SUMMARY"; exit 1
fi
command -v timeout >/dev/null 2>&1 || { echo "CM-CONSTITUTION-GATES: FAIL coreutils timeout not on PATH" | tee -a "$SUMMARY"; printf 'EVIDENCE: %s\n' "$SUMMARY"; exit 1; }

TIMEOUT="${COVENANT_GATE_TIMEOUT:-60}"
echo "GATE=CM-CONSTITUTION-GATES RUN_ID=$RUN_ID EXCLUSIONS=$EXCLUSIONS TIMEOUT=${TIMEOUT}s" >> "$SUMMARY"

total=0; pass=0; fail=0
for gate_script in "$GATES_DIR"/cm_covenant_114_*_propagation.sh; do
    [ -f "$gate_script" ] || continue
    base="$(basename "$gate_script")"
    anchor="$(printf '%s' "$base" | sed -nE 's/^cm_covenant_114_([0-9]+)_propagation\.sh$/\1/p')"
    [ -n "$anchor" ] || continue
    [ "$anchor" -gt 170 ] || continue   # scope: anchors >170 (per task contract)

    total=$((total + 1))
    gate_name="CM-COVENANT-114-${anchor}-PROPAGATION"
    ev="$EVIDENCE_DIR/gates/${base%.sh}.log"
    {
        echo "GATE=$gate_name"
        echo "SCRIPT=${gate_script#$REPO_ROOT/}"
        echo "ANCHOR=11.4.$anchor"
        echo "EXCLUSIONS=$EXCLUSIONS"
        echo "─── captured gate output ───"
    } > "$ev"

    # Fail-closed env: explicit consumer root + the consumer-owned exclusion
    # TSV. No HELIX_TEST_MODE, so the engine's guarded overrides cannot be
    # (mis)used to narrow the audited carrier set.
    ( cd "$REPO_ROOT" && \
      CONSUMER_ROOT="$REPO_ROOT" \
      COVENANT_PROPAGATION_EXCLUSIONS="$EXCLUSIONS" \
      timeout "${TIMEOUT}s" bash "$gate_script" --root "$REPO_ROOT" ) >> "$ev" 2>&1
    rc=$?
    echo "EXIT_CODE=$rc" >> "$ev"

    if [ "$rc" -eq 0 ] && grep -qF ': PASS' "$ev"; then
        pass=$((pass + 1))
        printf '%s\tPASS\t%s\t%s\n' "$gate_name" "$rc" "${ev#$REPO_ROOT/}" >> "$SUMMARY_TSV"
    else
        fail=$((fail + 1))
        printf '%s\tFAIL\t%s\t%s\n' "$gate_name" "$rc" "${ev#$REPO_ROOT/}" >> "$SUMMARY_TSV"
    fi
done

if [ "$total" -eq 0 ]; then
    echo "FAIL reason=zero-propagation-gates-discovered" >> "$SUMMARY"
fi
echo "SUMMARY total=$total pass=$pass fail=$fail" >> "$SUMMARY"
printf '%s\tSUMMARY\n' "${SUMMARY#$REPO_ROOT/}" > "$MANIFEST"

printf '%s\n' "CM-CONSTITUTION-GATES: total=$total pass=$pass fail=$fail"
printf 'EVIDENCE: %s\n' "$SUMMARY"
printf 'EVIDENCE_TSV: %s\n' "$SUMMARY_TSV"
[ "$total" -gt 0 ] && [ "$fail" -eq 0 ] || exit 1
exit 0
