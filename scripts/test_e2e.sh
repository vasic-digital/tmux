#!/usr/bin/env bash
# test_e2e.sh — full end-to-end automation: build + setup + session
# lifecycle (create / send command / capture / detach / kill).
#
# Exercises the COMPLETE stack from the operator's shell:
#   macOS:  zsh/bash → scripts/tmx (bridge) → ssh -t → VM scripts/tmx-vm
#           → systemd-run --user --scope → tmux server → session/pane
#   Linux:  zsh/bash → scripts/tmx (wrapper) → systemd-run --user --scope
#           → tmux server → session/pane
#
# Constitution §1: every PASS carries positive runtime evidence — the
# actual tmux pane content, captured via `tmux capture-pane -p`, is what
# the operator would see if they were attached.
#
# This complements the in-VM verify suite (scripts/verify.sh inside the
# VM) by exercising the BRIDGE + WRAPPER + SESSION lifecycle as a single
# integrated path.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0
SKIP=0
SESSION="tmx_e2e_$$"
MARKER="tmx-e2e-marker-$$-$(date +%s)"

_pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
_fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }
_skip() { echo "SKIP: $*"; SKIP=$((SKIP + 1)); }

_cleanup() {
    bash scripts/tmx kill-session -t "$SESSION" 2>/dev/null || true
}
trap _cleanup EXIT

echo "════════════════════════════════════════════════════════════════"
echo "  tmx end-to-end automation test"
echo "════════════════════════════════════════════════════════════════"

# ─── T1: prerequisites ──────────────────────────────────────────────
echo ""
echo "--- T1: prerequisites ---"
if [ ! -x scripts/tmx ]; then
    _fail "T1.0: scripts/tmx not generated — run: bash scripts/setup.sh"
    echo ""
    echo "Tests: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
    exit 1
fi
_pass "T1.0: scripts/tmx is generated and executable"

if [ "$(uname -s)" = "Darwin" ]; then
    if ! command -v podman >/dev/null 2>&1; then
        _fail "T1.1: podman missing on Darwin (the bridge requires it)"
        exit 1
    fi
    if ! podman machine list --format '{{.LastUp}}' 2>/dev/null | grep -qi "currently running"; then
        _fail "T1.2: podman machine not running — start: podman machine start"
        exit 1
    fi
    _pass "T1.1+T1.2: podman machine running on Darwin host"
else
    _pass "T1.1+T1.2: Linux host (no bridge layer needed)"
fi

# ─── T2: smoke (binary + version) ───────────────────────────────────
echo ""
echo "--- T2: tmx -V smoke ---"
VERSION_OUT=$(bash scripts/tmx -V 2>&1 | tail -1 | tr -d '\r')
if echo "$VERSION_OUT" | grep -q "tmux 3.6a"; then
    _pass "T2: tmx -V → '$VERSION_OUT'"
else
    _fail "T2: tmx -V returned '$VERSION_OUT' (expected 'tmux 3.6a')"
fi

# ─── T3: create detached session ────────────────────────────────────
echo ""
echo "--- T3: tmx new -s $SESSION -d (detached create) ---"
bash scripts/tmx new -s "$SESSION" -d 2>&1 | grep -v "libtinfo" || true
sleep 1
if bash scripts/tmx ls 2>&1 | grep -v "libtinfo" | grep -q "^$SESSION:"; then
    _pass "T3: session '$SESSION' visible in tmx ls (positive evidence: tmx ls output)"
else
    _fail "T3: session '$SESSION' NOT visible in tmx ls"
    bash scripts/tmx ls 2>&1 | grep -v "libtinfo" | sed 's/^/  ls: /'
fi

# ─── T4: send-keys (interact with the session) ──────────────────────
echo ""
echo "--- T4: send-keys (run a command inside the session) ---"
bash scripts/tmx send-keys -t "$SESSION" "echo $MARKER" Enter 2>&1 | grep -v "libtinfo" || true
sleep 1.5
PANE=$(bash scripts/tmx capture-pane -t "$SESSION" -p 2>&1 | grep -v "libtinfo" || true)
if echo "$PANE" | grep -q "$MARKER"; then
    _pass "T4: marker '$MARKER' echoed in pane (positive evidence: tmx capture-pane -p)"
else
    _fail "T4: marker '$MARKER' not found in pane"
    echo "$PANE" | sed 's/^/  pane: /'
fi

# ─── T4.5: status-bar colour reflects host (proves _apply_host_color ran) ──
echo ""
echo "--- T4.5: status-bar colour applied (NOT the default green) ---"
if [ "$(uname -s)" = "Darwin" ]; then
    if command -v scutil >/dev/null 2>&1; then
        HOST_HN=$(scutil --get LocalHostName 2>/dev/null || hostname)
    else
        HOST_HN=$(hostname)
    fi
else
    HOST_HN=$(hostname)
fi
EXPECTED_COLOR=$(bash scripts/hostname_color.sh "$HOST_HN" 2>/dev/null || echo "")
ACTUAL_STYLE=$(bash scripts/tmx -L "tmx-${SESSION}" show -g status-style 2>&1 | grep -v "libtinfo" | tail -1 | tr -d '\r')
ACTUAL_BG=$(echo "$ACTUAL_STYLE" | grep -oE 'bg=[^,[:space:]]+' | head -1 | sed 's/^bg=//')
if [ -z "$ACTUAL_BG" ]; then
    _fail "T4.5: could not read status-style bg (raw: '$ACTUAL_STYLE')"
elif [ "$ACTUAL_BG" = "green" ]; then
    _fail "T4.5: status-bg is 'green' — that's the tmux DEFAULT, color was not applied (host '$HOST_HN' should hash to '$EXPECTED_COLOR')"
elif [ -n "$EXPECTED_COLOR" ] && [ "$ACTUAL_BG" = "$EXPECTED_COLOR" ]; then
    _pass "T4.5: status-bg '$ACTUAL_BG' matches hostname-derived '$EXPECTED_COLOR' for '$HOST_HN' (positive evidence: tmx show -g status-style)"
else
    _pass "T4.5: status-bg '$ACTUAL_BG' set (non-default; expected '$EXPECTED_COLOR' for '$HOST_HN')"
fi

# ─── T5: detach simulation (verify session survives without attached client) ──
echo ""
echo "--- T5: session survives without attached client (analogue of Ctrl-B d) ---"
sleep 1
if bash scripts/tmx ls 2>&1 | grep -v "libtinfo" | grep -q "^$SESSION:"; then
    _pass "T5: session '$SESSION' still alive after send-keys exit"
else
    _fail "T5: session '$SESSION' disappeared after send-keys"
fi

# ─── T7: per-session isolation (operator-path, OS-aware) ────────────
# Create a second session via the native wrapper and verify it lands in
# its OWN isolation primitive — distinct cgroup scope on Linux, distinct
# tmux server (with its own rlimit wrapper) on Darwin. Same end-user
# guarantee: A's resource pressure doesn't affect B.
echo ""
echo "--- T7: per-session isolation (two sessions, distinct primitives) ---"
SESSION_B="${SESSION}_b"
bash scripts/tmx new -s "$SESSION_B" -d 2>&1 | grep -v "libtinfo" || true
sleep 1

HOST_OS_E2E="$(uname -s)"
case "$HOST_OS_E2E" in
    Darwin)
        # Darwin: verify distinct tmux server PIDs (per-session servers).
        BIN="$(pwd)/tmux/build-darwin/bin/tmux"
        A_PID=$("$BIN" -L "tmx-${SESSION}" display-message -p '#{pid}' 2>/dev/null || echo "")
        B_PID=$("$BIN" -L "tmx-${SESSION_B}" display-message -p '#{pid}' 2>/dev/null || echo "")
        if [ -n "$A_PID" ] && [ -n "$B_PID" ] && [ "$A_PID" != "$B_PID" ]; then
            _pass "T7: distinct tmux server PIDs A=$A_PID B=$B_PID (positive evidence: per-session server isolation on Darwin)"
        else
            _fail "T7: sessions share a server. A=$A_PID B=$B_PID"
        fi
        ;;
    Linux)
        # Linux: verify distinct cgroup-v2 scope units.
        ACTIVE_SCOPES=$(systemctl --user list-units --type=scope --no-legend --all 2>/dev/null | awk '{print $1}' | grep -E "^tmx-(${SESSION}|${SESSION_B})\.scope$" | sort -u)
        SCOPE_COUNT=$(printf '%s\n' "$ACTIVE_SCOPES" | grep -c '^tmx-' || echo 0)
        if [ "$SCOPE_COUNT" -eq 2 ]; then
            _pass "T7: two distinct scopes active for two sessions (positive evidence: systemctl list-units shows $(printf '%s ' $ACTIVE_SCOPES))"
        else
            _fail "T7: expected 2 scopes, found $SCOPE_COUNT — sessions share a cgroup (§11.4.7 violation)"
        fi
        ;;
    *)
        _skip "T7: unsupported OS $HOST_OS_E2E"
        ;;
esac

# Cleanup B
bash scripts/tmx kill-session -t "$SESSION_B" 2>&1 | grep -v "libtinfo" || true

# ─── T8: kill-session cleanup ───────────────────────────────────────
echo ""
echo "--- T8: tmx kill-session -t $SESSION ---"
bash scripts/tmx kill-session -t "$SESSION" 2>&1 | grep -v "libtinfo" || true
sleep 1
if bash scripts/tmx ls 2>&1 | grep -v "libtinfo" | grep -q "^$SESSION:"; then
    _fail "T8: session '$SESSION' still listed after kill-session"
else
    _pass "T8: session '$SESSION' removed (positive evidence: tmx ls no longer shows it)"
fi

# ─── summary ────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  SUMMARY: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
echo "════════════════════════════════════════════════════════════════"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
echo "  GREEN: tmx end-to-end stack verified (bridge + wrapper + session lifecycle)"
exit 0
