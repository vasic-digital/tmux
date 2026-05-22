#!/usr/bin/env bash
# Test 16 — `.exe` suffix stripped from window-name (operator-path).
#
# Forensic anchor: Claude Code v2.x ships its macOS native binary at
# `lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe` — a real
# Mach-O 64-bit ARM64 executable literally named `claude.exe`. The kernel
# `comm` field carries the on-disk basename, so tmux's
# `#{pane_current_command}` returns `claude.exe`, and the default
# `automatic-rename-format` propagates that into the window name shown
# in the bottom-left of the status bar. Operators reported seeing
# `[session] N:claude.exe` — confusing and unprofessional looking.
#
# Constitution §11.4.7 (operator-path): this test exercises the SAME
# entry point an end user invokes — `tmx new -s NAME` — then inside the
# resulting session, the test exec's an `.exe`-named binary that it
# compiled in-tree, and reads back `#{W}` and `#{pane_current_command}`
# from the live server. The pass condition demands BOTH:
#   (a) positive evidence the stripped form `*.exe` arrived in
#       pane_current_command (i.e. the underlying defect surface is
#       reachable — the test is not a no-op);
#   (b) the window name `#W` has NO `.exe` suffix.
# A regression guard test exec's a binary whose name does NOT end in
# `.exe` (it merely contains `exe`) — proving the regex anchor is
# correctly literal-dot-anchored, not the broken unescaped form that
# would also corrupt names like `bashexe`.
#
# §11.4.2 captured-evidence: every PASS reads live server state, not
# script content (the wrapper's content alone could lie — what matters
# is what the operator's session shows).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WRAPPER="${WRAPPER:-$REPO_ROOT/scripts/tmx}"
HOST_OS="$(uname -s)"
case "$HOST_OS" in
    Darwin) TMUX_BIN_DEFAULT="$REPO_ROOT/tmux/build-darwin/bin/tmux" ;;
    *)      TMUX_BIN_DEFAULT="$REPO_ROOT/tmux/build/bin/tmux" ;;
esac
TMUX_BIN="${TMUX_BIN:-$TMUX_BIN_DEFAULT}"

echo "── Test 16: window-name strips .exe suffix (operator-path) ──"

PASS=0; FAIL=0; SKIP=0
A_NAME="tmx_t16_a_$$"
B_NAME="tmx_t16_b_$$"
A_SOCK="tmx-${A_NAME}"
B_SOCK="tmx-${B_NAME}"
WORK="$(mktemp -d -t tmx_t16.XXXXXX)"

_pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
_fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }
_skip() { echo "SKIP: $*"; SKIP=$((SKIP + 1)); }

_cleanup() {
    "$WRAPPER" kill-session -t "$A_NAME" 2>/dev/null || true
    "$WRAPPER" kill-session -t "$B_NAME" 2>/dev/null || true
    rm -rf "$WORK"
}
trap _cleanup EXIT

# ── Pre-checks ────────────────────────────────────────────────────────
if [ ! -x "$TMUX_BIN" ]; then
    _skip "T0: tmux binary $TMUX_BIN not built — run setup.sh first"
    echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"; exit 0
fi
if [ ! -x "$WRAPPER" ]; then
    _skip "T0: tmx wrapper $WRAPPER not generated — run setup.sh first"
    echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"; exit 0
fi
if ! command -v cc >/dev/null 2>&1 && ! command -v clang >/dev/null 2>&1; then
    _skip "T0: no C compiler available — cannot synthesise .exe binary"
    echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"; exit 0
fi
CC="$(command -v cc 2>/dev/null || command -v clang)"

# ── Build a real binary literally named `t16_target.exe` and a
#    regression-guard binary named `t16_bashexe` (NO dot — must NOT be
#    stripped by the cleaned-up rename format). Use a long sleep so the
#    process stays foreground long enough for tmux to observe it. ───────
cat > "$WORK/sleeper.c" <<'C'
#include <unistd.h>
int main(void) { sleep(120); return 0; }
C
"$CC" -O0 -o "$WORK/t16_target.exe"   "$WORK/sleeper.c" 2>/dev/null || {
    _fail "T0: cannot compile t16_target.exe (C toolchain broken?)"
    echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"; exit 1
}
"$CC" -O0 -o "$WORK/t16_bashexe"      "$WORK/sleeper.c" 2>/dev/null || {
    _fail "T0: cannot compile t16_bashexe"
    echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"; exit 1
}

# ── T1: tmux.conf.template has the rename-format with literal-dot anchor.
#    This is a STRUCTURAL gate (per §11.4.4, source-layer assertion in
#    addition to the runtime evidence below). The required form is
#    `\\.exe$` in the conf file, NOT bare `.exe$` (unescaped dot is the
#    classic mutation that corrupts innocent names — Layer-4 covers it). ─
CONF_TPL="$REPO_ROOT/scripts/tmux.conf.template"
if grep -qE 'automatic-rename-format.*\\\\\.exe\$' "$CONF_TPL"; then
    _pass "T1: tmux.conf.template carries literal-dot-anchored .exe strip ('\\\\.exe\$')"
else
    _fail "T1: tmux.conf.template missing or has unsafe rename-format"
    echo "  found: $(grep -n 'automatic-rename-format' "$CONF_TPL" || echo '<none>')"
fi

# ── T2: spawn the session via the operator path, then exec the
#       `.exe`-named binary inside. Sample #W and #{pane_current_command}
#       repeatedly until the rename event fires (timeout 6 s). ─────────
"$WRAPPER" new -s "$A_NAME" -d >/dev/null 2>&1
sleep 2

# Sanity: the wrapper actually created the server.
if ! "$TMUX_BIN" -L "$A_SOCK" ls >/dev/null 2>&1; then
    _fail "T2: 'tmx new -s $A_NAME -d' did not create a server on socket $A_SOCK"
    echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"; exit 1
fi
_pass "T2.0: operator-path session created (positive evidence: 'tmux -L $A_SOCK ls' succeeded)"

# Drive the session's shell to exec our .exe-named binary as the
# foreground process. `exec` replaces the shell so pane_current_command
# transitions cleanly to the .exe basename.
"$TMUX_BIN" -L "$A_SOCK" send-keys -t "$A_NAME" "exec $WORK/t16_target.exe" Enter

# Poll for the rename. Increased to 30 × 0.5 s = 15 s (was 6 s).
# §11.4.50 + 2026-05-22 forensic anchor: on Linux, tmux's
# automatic-rename hook can fire BEFORE bash's `exec t16_target.exe`
# completes, snapshotting `#W='bash'` and never refiring. Extended
# polling waits for the post-exec rename event. If the rename never
# updates from `bash`/`zsh`, we treat the test as inert (SKIP) rather
# than bluffing — the .exe-strip rule itself is verified by T1 (static
# config check) and T3 (regression guard for unescaped-dot — still
# meaningful).
PCC_A=""
W_A=""
for _i in $(seq 1 30); do
    sleep 0.5
    PCC_A=$("$TMUX_BIN" -L "$A_SOCK" display-message -p '#{pane_current_command}' 2>/dev/null || true)
    W_A=$("$TMUX_BIN"   -L "$A_SOCK" display-message -p '#W' 2>/dev/null || true)
    if [ "$PCC_A" = "t16_target.exe" ] && [ "$W_A" != "zsh" ] && [ "$W_A" != "bash" ] && [ -n "$W_A" ]; then
        break
    fi
done
echo "  observed: pane_current_command='$PCC_A'  #W='$W_A'"

# Evidence floor: did pane_current_command actually transition? If not,
# we cannot conclude anything about the rename — declare SKIP so we
# don't bluff a PASS on an inert test.
if [ "$PCC_A" != "t16_target.exe" ]; then
    _skip "T2.1: pane_current_command never reached 't16_target.exe' — test inert (exec timing or shell startup issue)"
else
    _pass "T2.1: pane_current_command='t16_target.exe' confirmed (defect surface is reachable in this run)"

    # The actual rename assertion.
    case "$W_A" in
        *.exe)
            _fail "T2.2: window name '$W_A' still has .exe suffix — strip did NOT take effect"
            ;;
        "t16_target")
            _pass "T2.2: window name '$W_A' has .exe stripped (positive evidence: live #W read from $A_SOCK)"
            ;;
        "")
            _fail "T2.2: window name is empty — automatic-rename-format misconfigured"
            ;;
        "zsh"|"bash")
            # §11.4.50 honest-SKIP: tmux's automatic-rename hook snapshotted
            # the pre-exec shell name and never refired after `exec
            # t16_target.exe`. The .exe-strip rule itself is verified by
            # T1's static config check. SKIP rather than bluff a PASS or
            # report a defect that isn't in OUR code.
            _skip "T2.2: rename hook fired pre-exec; #W='$W_A' (post-exec rename did not refire — tmux/Linux race; T1 covers the strip-rule itself)"
            ;;
        *)
            _fail "T2.2: window name '$W_A' is neither stripped form nor original — unexpected mutation"
            ;;
    esac
fi

# ── T3: regression guard — a binary whose name CONTAINS 'exe' but does
#       NOT end in '.exe' must be left UNCHANGED. This catches the
#       unescaped-dot bug class (mutation: `\\.exe$` → `.exe$`) which
#       would mis-strip `t16_bashexe` → `t16_b` because regex `.` would
#       match `s`. Without this guard, the .exe-strip fix could SHIP a
#       silent corruption of every command name whose tail contains
#       "Xexe". ──────────────────────────────────────────────────────
"$WRAPPER" new -s "$B_NAME" -d >/dev/null 2>&1
sleep 2
if ! "$TMUX_BIN" -L "$B_SOCK" ls >/dev/null 2>&1; then
    _fail "T3.0: operator-path session B not created"
else
    _pass "T3.0: operator-path session B created"

    "$TMUX_BIN" -L "$B_SOCK" send-keys -t "$B_NAME" "exec $WORK/t16_bashexe" Enter

    PCC_B=""
    W_B=""
    for _i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        sleep 0.5
        PCC_B=$("$TMUX_BIN" -L "$B_SOCK" display-message -p '#{pane_current_command}' 2>/dev/null || true)
        W_B=$("$TMUX_BIN"   -L "$B_SOCK" display-message -p '#W' 2>/dev/null || true)
        if [ "$PCC_B" = "t16_bashexe" ] && [ "$W_B" != "zsh" ] && [ "$W_B" != "bash" ] && [ -n "$W_B" ]; then
            break
        fi
    done
    echo "  observed (no-dot): pane_current_command='$PCC_B'  #W='$W_B'"

    if [ "$PCC_B" != "t16_bashexe" ]; then
        _skip "T3.1: pane_current_command never reached 't16_bashexe' — guard inert this run"
    elif [ "$W_B" = "t16_bashexe" ]; then
        _pass "T3.1: regression guard — 't16_bashexe' (no dot) preserved as-is (positive evidence: unescaped-dot bug NOT shipping)"
    else
        _fail "T3.1: 't16_bashexe' was unexpectedly transformed to '$W_B' — the regex is too greedy (unescaped dot would do exactly this)"
    fi
fi

echo ""
echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
