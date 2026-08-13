#!/usr/bin/env bash
# classify_verdict.sh — classify a test file's captured output as PASS,
# FAIL, or SKIP (§11.4.201(7)(a): match structure, not a bare substring).
#
# Purpose:    run_all.sh's aggregator needs to reduce a whole test file's
#             captured stdout+stderr to ONE of PASS/FAIL/SKIP. The naive
#             approach (grep for ANY line starting with the bare keyword)
#             mis-fires on INFORMATIONAL lines that happen to start with
#             the same keyword but are NOT the test's own final verdict
#             — e.g. a "SKIP-layer: <reason>" sub-check note, or a test's
#             own internal summary counter "PASS=$PASS FAIL=$FAIL
#             SKIP=$SKIP" (which literally contains the substring
#             "FAIL=0" on a perfectly healthy run with zero failures).
#
# Forensic anchor (FACT, 2026-08-13): tests 56/57 print an honest
# "SKIP-layer: <reason>" note for one optional GUI-only sub-check while
# the test's REAL final verdict is "PASS: 56 ..." / "PASS: 57 ...". The
# bare `grep -qE '^SKIP'` matched the informational line and, because the
# aggregator's priority is FAIL > SKIP > PASS, mis-classified an entirely
# passing test as SKIP. The SAME carrier shape is present, unfixed, on
# EVERY test file whose internal counters print "PASS=N", "SKIP=N", or
# "FAIL=N" — a "FAIL=0" counter line on a zero-failure run would
# mis-classify a genuinely PASSING test as FAILED.
#
# Fix:        require a genuine verdict-line delimiter (colon, space, an
#             open-paren, OR end-of-line — the last covering tests whose
#             ENTIRE verdict line is the bare keyword, e.g. `echo "PASS"`
#             in tests 01/02, discovered as a regression during this
#             fix's own pre-commit full-suite verification, §11.4.194) —
#             immediately after the keyword. "SKIP-layer:", "PASS=0", and
#             "FAIL=0" all fail this stricter match and are correctly
#             ignored; every genuine verdict line (delimited OR bare)
#             still matches.
#
# Usage:      . "$SELF_DIR/lib/classify_verdict.sh"
#             verdict=$(tmx_classify_verdict "$captured_output")
#             # verdict is exactly one of: PASS FAIL SKIP
#
# Inputs:     $1 = the test's captured stdout+stderr (one string, may be
#             multi-line). Outputs: PASS/FAIL/SKIP on stdout. No side-
#             effects.
# Dependencies: grep -E (POSIX extended regex), no bash-4-only features
#             (§11.4.67 — this file is sourced by run_all.sh before its
#             own Darwin bash-4 re-exec guard has necessarily run).
# Cross-refs: scripts/tests/run_all.sh (sole consumer),
#             scripts/tests/89_classify_verdict_carrier.sh (regression
#             guard), scripts/tests/56_real_mouse_drag_copy.sh +
#             57_reload_select_copy_paste.sh (the "SKIP-layer:" source),
#             Constitution §11.4.201(7)(a) (match structure, not
#             substring), §11.4.120 (this generalises the same fix class
#             test 77 already applied to ITS OWN assertion; run_all.sh's
#             aggregator had the identical latent defect, undiscovered
#             until it mis-classified 56/57).
# Last verified: 2026-08-13

# Priority: FAIL > SKIP > PASS (a test that genuinely FAILs anywhere
# still counts as FAIL even if a later line says PASS; a test with an
# honest partial SKIP-and-continue still counts as SKIP unless it also
# hit a genuine FAIL). Output is one of PASS/FAIL/SKIP/UNCLASSIFIED —
# UNCLASSIFIED (no genuine verdict line at all, e.g. an early-exit /
# crash) is a distinct diagnostic signal from a genuine FAIL verdict;
# callers that only care about pass/fail-for-gating treat both as FAIL,
# but MUST NOT silently count an unclassified crash as a PASS.
tmx_classify_verdict() {
    local out="$1"
    if echo "$out" | grep -qE '^FAIL([: (]|$)'; then
        echo "FAIL"
    elif echo "$out" | grep -qE '^SKIP([: (]|$)'; then
        echo "SKIP"
    elif echo "$out" | grep -qE '^PASS([: (]|$)'; then
        echo "PASS"
    else
        echo "UNCLASSIFIED"
    fi
}
