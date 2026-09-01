#!/usr/bin/env bash
# Test 01 — Smoke: tmux binary is invocable + reports the expected version.
# Robust against stderr pollution from libtinfo version mismatch (Ubuntu-build
# binary on ALT Linux host emits "no version information available" warnings;
# binary still works correctly).
set -uo pipefail
TMUX_BIN="${TMUX_BIN:?TMUX_BIN not set}"
EXPECTED_VERSION="${EXPECTED_VERSION:-3.7b}"
echo "── Test 01: smoke ──"
ACTUAL=$("$TMUX_BIN" -V 2>&1 | grep -v 'no version information' | head -1)
echo "  binary reports: $ACTUAL"
if echo "$ACTUAL" | grep -qE "tmux $EXPECTED_VERSION"; then
    echo "PASS"
    exit 0
else
    echo "FAIL: expected 'tmux $EXPECTED_VERSION', got '$ACTUAL'"
    exit 1
fi
