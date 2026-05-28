#!/usr/bin/env bash
# Test 23 — `tmx kill` shorthand resolves to `tmx kill-session`.
#
# AUDIT-2 fix anchor (2026-05-21): README + AGENTS commands table list
# `tmx {new|attach|ls|kill}` as the friendly operator vocabulary. Until
# AUDIT-2, the bare `tmx kill` was passed through to tmux which rejected
# it as ambiguous ("could be: kill-pane, kill-server, kill-session,
# kill-window"). Documented operator-path silently broken — a §11.4
# UX-layer PASS-bluff at the doc layer.
#
# This test exercises the operator path per §102: spawn a real session
# via `tmx new -s NAME -d`, prove it's listed, kill it via the friendly
# verb `tmx kill -t NAME`, prove it's gone, capture stderr to confirm
# no "ambiguous" message leaked.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0
SKIP=0
_pass() { echo "PASS: $*"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
_skip() { echo "SKIP: $*"; SKIP=$((SKIP+1)); }

WRAPPER="${WRAPPER:-$REPO_ROOT/scripts/tmx}"
TMUX_BIN_OS="$(uname -s)"
case "$TMUX_BIN_OS" in
    Darwin) TMUX_BIN="${TMUX_BIN:-$REPO_ROOT/tmux/build-darwin/bin/tmux}" ;;
    Linux)  TMUX_BIN="${TMUX_BIN:-$REPO_ROOT/tmux/build/bin/tmux}" ;;
esac

if [ ! -x "$WRAPPER" ]; then
    _skip "T0: $WRAPPER not executable — run setup.sh"
    echo ""; echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
    exit 0
fi
if [ ! -x "$TMUX_BIN" ]; then
    _skip "T0: $TMUX_BIN not built — run setup.sh"
    echo ""; echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
    exit 0
fi

SESS="t23_kill_$$"
SOCK="tmx-${SESS}"

# Cleanup on every exit path (§11.4.14 test playback cleanup).
trap '
    "$WRAPPER" kill-session -t "$SESS" >/dev/null 2>&1 || true
    "$TMUX_BIN" -L "$SOCK" kill-server >/dev/null 2>&1 || true
' EXIT

# T1 — create the session via the operator path.
if "$WRAPPER" new -s "$SESS" -d >/dev/null 2>&1; then
    _pass "T1: tmx new -s $SESS -d succeeded"
else
    _fail "T1: tmx new -s $SESS -d failed"
    echo ""; echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
    exit 1
fi

# T2 — ls shows it.
if "$WRAPPER" ls 2>/dev/null | grep -q "$SESS"; then
    _pass "T2: tmx ls shows '$SESS' (positive evidence: tmx ls output)"
else
    _fail "T2: tmx ls did not list '$SESS'"
fi

# T3 — friendly `kill` verb resolves (no "ambiguous" stderr).
KILL_STDERR="$("$WRAPPER" kill -t "$SESS" 2>&1 >/dev/null)"
if echo "$KILL_STDERR" | grep -qi 'ambiguous'; then
    _fail "T3: 'tmx kill -t $SESS' emitted 'ambiguous' stderr — shorthand translation broken"
    echo "  >>> stderr: $KILL_STDERR"
else
    _pass "T3: tmx kill -t $SESS resolved (no 'ambiguous' stderr; AUDIT-2 fix active)"
fi

# T4 — session is gone (positive evidence: tmx ls no longer shows it).
#       Q1 flake-fix (v1.0.16, 2026-05-28 per §11.4.50 deterministic-
#       consistency + §11.4.1 source-layer fix): the original `sleep 0.5`
#       was a §11.4.6 guess — under load (concurrent codegraph daemon,
#       parallel test suite, large meta-test in flight) the kill takes
#       longer than 0.5s to flush through the wrapper's systemd-run
#       scope teardown. Poll for the session to disappear with a 6 s
#       budget — same evidence shape, robust to load.
T4_OK=0
for _i in $(seq 1 30); do
    if ! "$WRAPPER" ls 2>/dev/null | grep -q "$SESS"; then
        T4_OK=1; break
    fi
    sleep 0.2
done
if [ "$T4_OK" -eq 1 ]; then
    _pass "T4: '$SESS' removed from tmx ls within poll budget (positive evidence: post-kill listing absent)"
else
    _fail "T4: '$SESS' still appears in tmx ls after 6 s poll — kill did not take effect"
fi

# T5 — server gone (positive evidence: tmux -L SOCK ls says no server).
#       Same flake-fix rationale as T4 — poll instead of relying on T4's
#       sleep having been long enough.
T5_OK=0
for _i in $(seq 1 30); do
    if ! "$TMUX_BIN" -L "$SOCK" ls 2>/dev/null | grep -q .; then
        T5_OK=1; break
    fi
    sleep 0.2
done
if [ "$T5_OK" -eq 1 ]; then
    _pass "T5: tmux server on socket $SOCK terminated within poll budget (positive evidence: direct -L socket query empty)"
else
    _fail "T5: tmux server on socket $SOCK still running after 6 s poll"
fi

echo ""
echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
