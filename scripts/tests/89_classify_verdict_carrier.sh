#!/usr/bin/env bash
# 89_classify_verdict_carrier.sh — regression guard: run_all.sh's verdict
# classifier MUST NOT mis-fire on an informational line that merely starts
# with the same keyword as a genuine PASS/FAIL/SKIP verdict.
#
# ─── RED_MODE POLARITY (Constitution §11.4.115) ──────────────────────────
# RED_MODE=1  reproduce-and-assert-DEFECT-PRESENT: feed the classifier
#             fixture text on the PRE-FIX classification behaviour (a bare
#             `grep -qE '^SKIP'`/`^FAIL'`/`^PASS'` prefix match) and assert
#             it mis-classifies. Demonstrates the defect is real.
# RED_MODE=0  (default) regression GUARD: assert the CURRENT (fixed)
#             tmx_classify_verdict correctly classifies every fixture by
#             its genuine final verdict line, ignoring carrier lines.
#
# TMX-ID:     TMX-084
# Root cause: scripts/tests/56_real_mouse_drag_copy.sh and
#             57_reload_select_copy_paste.sh print an honest
#             "SKIP-layer: <reason>" note for one optional GUI-only
#             sub-check while their REAL final verdict is a clean
#             "PASS: 56 ..." / "PASS: 57 ...". Dozens of OTHER test files
#             print their own internal "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
#             summary counters. run_all.sh's aggregator scanned for ANY
#             line starting with the bare keyword FAIL/SKIP/PASS (no
#             delimiter check) with priority FAIL > SKIP > PASS — so
#             "SKIP-layer:" was misread as a top-level SKIP verdict, and a
#             counter line like "FAIL=0" (reporting ZERO failures, the
#             best possible outcome) would misclassify an entirely
#             healthy PASS as FAILED. §11.4.201(7)(a): match structure
#             (a genuine verdict-line delimiter), never a bare substring.
#
# Dependencies: bash, grep -E. No tmux/systemd/session dependency — this
#             tests the CLASSIFIER in isolation, not a live session
#             (fast, hermetic, no host-topology dependency).
# Last verified: 2026-08-13

set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
LIB="$REPO_ROOT/scripts/tests/lib/classify_verdict.sh"

RED_MODE="${RED_MODE:-0}"

PASS=0
FAIL=0

_pass() { echo "PASS 89: $*"; PASS=$((PASS + 1)); }
_fail() { echo "FAIL 89: $*"; FAIL=$((FAIL + 1)); }

[ -f "$LIB" ] || { echo "FAIL: 89(0) — $LIB missing"; exit 1; }
# shellcheck disable=SC1090
. "$LIB"

# ─── Pre-fix classifier (reproduces the exact bare-prefix bug for RED_MODE=1) ──
tmx_classify_verdict_prefix() {
    local out="$1"
    if echo "$out" | grep -qE '^FAIL'; then
        echo "FAIL"
    elif echo "$out" | grep -qE '^SKIP'; then
        echo "SKIP"
    elif echo "$out" | grep -qE '^PASS'; then
        echo "PASS"
    else
        echo "UNCLASSIFIED"
    fi
}

# ─── Fixtures: (name, captured-output, TRUE final verdict) ──────────────
# F1: mirrors tests 56/57 — an honest "SKIP-layer:" sub-check note, then a
#     genuine PASS verdict. TRUE verdict: PASS.
F1_OUT=$(printf 'EVIDENCE: drag copied the token\nSKIP-layer: 56 GUI cliclick proof not run (opt-in)\nPASS: 56 plain mouse-drag selects+copies\n')
F1_TRUE="PASS"

# F2: mirrors a test's own internal healthy-run summary counter. TRUE
#     verdict: PASS (zero failures, one line happens to start "FAIL=0").
F2_OUT=$(printf 'PASS 1: sub-check A\nPASS 2: sub-check B\nFAIL=0\nPASS: 89 all sub-checks green\n')
F2_TRUE="PASS"

# F3: mirrors a test whose internal counter shows a nonzero SKIP but whose
#     overall verdict is still PASS. TRUE verdict: PASS.
F3_OUT=$(printf 'PASS 1: sub-check A\nSKIP=2\nPASS: 89 partial-skip but overall PASS\n')
F3_TRUE="PASS"

# F4: a genuine top-level FAIL verdict MUST still classify as FAIL
#     (regression safety — the fix must not lose real-failure detection).
F4_OUT=$(printf 'EVIDENCE: probe ran\nFAIL: 89(A) — real defect reproduced\n')
F4_TRUE="FAIL"

# F5: a genuine top-level SKIP verdict (topology-unsupported) MUST still
#     classify as SKIP.
F5_OUT=$(printf 'SKIP: 89 topology unsupported on this host\n')
F5_TRUE="SKIP"

# F6: a genuine "(RED)"/"(GREEN)"-suffixed verdict line (the §11.4.115
#     polarity-switch convention used by tests 59/86/87/88) MUST still
#     classify correctly.
F6_OUT=$(printf 'PASS (GREEN): scope has ManagedOOMPreference=avoid\n')
F6_TRUE="PASS"

# F7: a genuine BARE verdict line — the ENTIRE line is just the keyword,
#     nothing after it (tests 01/02's `echo "PASS"` convention). MUST
#     still classify correctly. (Regression discovered during this
#     fix's own pre-commit full-suite verification, §11.4.194 — the
#     first delimiter-only regex excluded this genuine convention.)
F7_OUT=$(printf 'binary reports: tmux 3.6a\nPASS\n')
F7_TRUE="PASS"

run_fixture() {
    local label="$1" out="$2" true_verdict="$3"
    local got
    if [ "$RED_MODE" = "1" ]; then
        got=$(tmx_classify_verdict_prefix "$out")
        # RED mode: assert the PRE-FIX classifier REPRODUCES a wrong
        # classification on at least the carrier fixtures (F1/F2/F3);
        # the non-carrier fixtures (F4/F5/F6) have no carrier collision
        # and are expected to classify correctly even pre-fix.
        case "$label" in
            F1|F2|F3)
                if [ "$got" != "$true_verdict" ]; then
                    _pass "$label RED: pre-fix classifier mis-classified as '$got' (expected '$true_verdict') — defect reproduced"
                else
                    _fail "$label RED — pre-fix classifier classified correctly ('$got'); defect NOT reproduced (RED_MODE mismatch or fixture stale)"
                fi
                ;;
            *)
                if [ "$got" = "$true_verdict" ]; then
                    _pass "$label RED: non-carrier fixture classifies correctly even pre-fix ('$got')"
                else
                    _fail "$label RED — unexpected pre-fix misclassification '$got' (expected '$true_verdict')"
                fi
                ;;
        esac
    else
        got=$(tmx_classify_verdict "$out")
        if [ "$got" = "$true_verdict" ]; then
            _pass "$label GREEN: classified '$got' (expected '$true_verdict')"
        else
            _fail "$label GREEN — classified '$got', expected '$true_verdict' (TMX-084 regression)"
        fi
    fi
}

echo "── Test 89: run_all.sh verdict classifier ignores carrier lines (RED_MODE=$RED_MODE) ──"
run_fixture F1 "$F1_OUT" "$F1_TRUE"
run_fixture F2 "$F2_OUT" "$F2_TRUE"
run_fixture F3 "$F3_OUT" "$F3_TRUE"
run_fixture F4 "$F4_OUT" "$F4_TRUE"
run_fixture F5 "$F5_OUT" "$F5_TRUE"
run_fixture F6 "$F6_OUT" "$F6_TRUE"
run_fixture F7 "$F7_OUT" "$F7_TRUE"

echo ""
echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=0"

if [ "$FAIL" -gt 0 ]; then
    echo "FAIL: 89 verdict classifier regression"
    exit 1
fi
echo "PASS: 89 verdict classifier correctly ignores carrier lines"
exit 0
