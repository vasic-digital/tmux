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

# ─── T5: detach simulation (verify session survives without attached client) ──
echo ""
echo "--- T5: session survives without attached client (analogue of Ctrl-B d) ---"
sleep 1
if bash scripts/tmx ls 2>&1 | grep -v "libtinfo" | grep -q "^$SESSION:"; then
    _pass "T5: session '$SESSION' still alive after send-keys exit"
else
    _fail "T5: session '$SESSION' disappeared after send-keys"
fi

# ─── T6: kill-session cleanup ───────────────────────────────────────
echo ""
echo "--- T6: tmx kill-session -t $SESSION ---"
bash scripts/tmx kill-session -t "$SESSION" 2>&1 | grep -v "libtinfo" || true
sleep 1
if bash scripts/tmx ls 2>&1 | grep -v "libtinfo" | grep -q "^$SESSION:"; then
    _fail "T6: session '$SESSION' still listed after kill-session"
else
    _pass "T6: session '$SESSION' removed (positive evidence: tmx ls no longer shows it)"
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
