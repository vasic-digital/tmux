#!/usr/bin/env bash
# go_tests_gate.sh — typed, evidence-bearing Go test gate (§11.4.169 / §11.4.262).
#
# SCOPE NOTE (2026-11-20, Go/tracker agent measurement): a BARE `go test ./...`
# at the repo root is NOT a valid project signal — it reports 299 failures,
# ALL under constitution/submodules/claude_toolkit/submodules/go/test/** (a
# vendored Go toolchain source corpus with deliberately non-buildable tests).
# This gate therefore NEVER runs bare `./...`. It enumerates the project's OWN
# packages with `go list` on explicit roots and runs `go test -count=1 <pkgs>`.
#
# Coverage: root-module packages under ./cmd/... (verified with `go list`),
# plus this repository's own scripts Go modules (each verified with `go list`
# inside its module). The vendored corpus and the separate Containers submodule
# are declared as EXCLUSIONS with reasons (transparent, never a silent skip).
#
# A module PASSes only on a REAL result marker (`ok  ` / `--- PASS` / `PASS`)
# in captured output — bare exit 0 is not a PASS (§11.4 no absence-of-error).
#
# Usage: bash scripts/testing/go_tests_gate.sh
# Env:   GO_TEST_TIMEOUT (seconds/module, default 90), RUN_ID
# Exit:  0 = no project-owned package FAIL; 1 = any FAIL / discovery error.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$-go-tests}"
EVIDENCE_DIR="$REPO_ROOT/docs/qa/$RUN_ID/go-tests"
mkdir -p "$EVIDENCE_DIR" || { echo "CM-GO-TESTS: FAIL cannot create $EVIDENCE_DIR"; exit 1; }

LOG="$EVIDENCE_DIR/go_test_full.log"
SUMMARY="$EVIDENCE_DIR/summary.txt"
MANIFEST="$EVIDENCE_DIR/helixqa_manifest.tsv"
: > "$LOG"; : > "$SUMMARY"; : > "$MANIFEST"

command -v go >/dev/null 2>&1 || { echo "CM-GO-TESTS: FAIL go not on PATH" | tee -a "$SUMMARY"; printf 'EVIDENCE: %s\n' "$SUMMARY"; exit 1; }
command -v timeout >/dev/null 2>&1 || { echo "CM-GO-TESTS: FAIL coreutils timeout not on PATH" | tee -a "$SUMMARY"; printf 'EVIDENCE: %s\n' "$SUMMARY"; exit 1; }

TIMEOUT="${GO_TEST_TIMEOUT:-90}"
export GOTOOLCHAIN=local GOPROXY=off
echo "GATE=CM-GO-TESTS RUN_ID=$RUN_ID ENV=GOTOOLCHAIN=local,GOPROXY=off,count=1 TIMEOUT=${TIMEOUT}s" >> "$SUMMARY"
echo "EXCLUDE constitution/submodules/claude_toolkit/submodules/go/test/** reason=vendored-go-toolchain-source-corpus measured_failures=299 source=Go-tracker-agent-2026-11-20" >> "$SUMMARY"
echo "EXCLUDE Containers/** reason=separate-submodule-with-own-test-surface out-of-root-module-scope" >> "$SUMMARY"

total=0; pass=0; fail=0

# ── 1) Root module: explicit patterns, verified by go list BEFORE testing ──
root_pkgs="$(cd "$REPO_ROOT" && go list ./cmd/... 2>>"$LOG")"
root_rc=$?
if [ "$root_rc" -ne 0 ] || [ -z "$root_pkgs" ]; then
    echo "FAIL root-module-package-discovery rc=$root_rc" >> "$SUMMARY"
    fail=$((fail + 1))
else
    for pkg in $root_pkgs; do
        total=$((total + 1))
        echo "──────── root pkg $pkg ────────" >> "$LOG"
        out="$(cd "$REPO_ROOT" && timeout "${TIMEOUT}s" go test -count=1 "$pkg" 2>&1)"; rc=$?
        printf '%s\n' "$out" >> "$LOG"
        if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qE '(^ok[[:space:]]|^PASS$|^--- PASS:)'; then
            echo "PASS $pkg rc=0 positive_marker=ok" >> "$SUMMARY"; pass=$((pass + 1))
        else
            echo "FAIL $pkg rc=$rc" >> "$SUMMARY"; fail=$((fail + 1))
        fi
    done
fi

# ── 2) Own scripts Go modules: each verified by go list, then tested ───────
for mod in scripts/tmx-state scripts/tmx-orchestrator; do
    total=$((total + 1))
    mdir="$REPO_ROOT/$mod"
    if [ ! -f "$mdir/go.mod" ]; then
        echo "FAIL $mod reason=missing-go.mod" >> "$SUMMARY"; fail=$((fail + 1)); continue
    fi
    echo "──────── module $mod ────────" >> "$LOG"
    pkgs="$(cd "$mdir" && go list ./... 2>>"$LOG")"; lrc=$?
    if [ "$lrc" -ne 0 ] || [ -z "$pkgs" ]; then
        echo "FAIL $mod reason=go-list-failed rc=$lrc" >> "$SUMMARY"; fail=$((fail + 1)); continue
    fi
    out="$(cd "$mdir" && timeout "${TIMEOUT}s" go test -count=1 $pkgs 2>&1)"; rc=$?
    printf '%s\n' "$out" >> "$LOG"
    if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qE '(^ok[[:space:]]|^PASS$|^--- PASS:)'; then
        echo "PASS $mod rc=0 positive_marker=ok" >> "$SUMMARY"; pass=$((pass + 1))
    elif [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '\[no test files\]'; then
        echo "SKIP $mod reason=no-test-files" >> "$SUMMARY"
    else
        echo "FAIL $mod rc=$rc" >> "$SUMMARY"; fail=$((fail + 1))
    fi
done

if [ "$total" -eq 0 ]; then echo "FAIL reason=no-owned-go-packages-discovered" >> "$SUMMARY"; fail=1; fi
echo "SUMMARY total=$total pass=$pass fail=$fail" >> "$SUMMARY"
printf '%s\tSUMMARY\n' "${SUMMARY#$REPO_ROOT/}" > "$MANIFEST"

printf '%s\n' "CM-GO-TESTS: total=$total pass=$pass fail=$fail"
printf 'EVIDENCE: %s\n' "$SUMMARY"
printf 'EVIDENCE_RAW: %s\n' "$LOG"
[ "$fail" -eq 0 ] || exit 1
exit 0
