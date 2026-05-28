#!/usr/bin/env bash
# Test 46 — PASTE-INTO from OS clipboard, physical proof.
#
# Forensic anchor: operator mandate (this turn) — "we can always copy /
# paste FROM AND TO the terminal window and current tmux (tmx) session!"
# v1.0.14 (test 44) proved copy-OUT but never proved paste-IN. tmux's
# `set-clipboard external` is COPY-OUT only — OSC-52 paste is not part
# of any standard. Without an explicit @clip-read user-option + a
# `prefix + P` binding that pipes the system clipboard through
# `tmux load-buffer -` and then `paste-buffer -p`, the operator
# CANNOT paste OS-clipboard contents into a tmux pane via tmux's own
# keystroke path.
#
# §101 physical-proof + §102 operator-path: this test seeds a unique
# marker in the host's clipboard via `pbcopy` / `wl-copy` / `xclip` /
# `termux-clipboard-set`, spawns the session via `tmx new -s NAME`,
# then directly invokes the SAME command sequence the `prefix + P`
# binding would invoke — `tmux set-buffer -- "$(#{@clip-read})" \;
# tmux paste-buffer -p`. After the paste, `capture-pane -p` MUST
# contain the marker. Anti-bluff: a metadata-only PASS (binding text
# present but paste never happens) is explicitly disallowed.
#
# §11.4.43 RED-first: this test is authored BEFORE the conf addition
# of @clip-read + prefix+P. On current code it FAILs at T1 (the
# template lacks @clip-read) and at T3/T4 (the live server has no
# such bindings).
#
# §11.4.14 cleanup: pre-test save + post-test restore of clipboard.
# §104: skip-with-reason on headless Linux (no clipboard tool).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WRAPPER="${WRAPPER:-$REPO_ROOT/scripts/tmx}"
HOST_OS="$(uname -s)"
case "$HOST_OS" in
    Darwin) TMUX_BIN_DEFAULT="$REPO_ROOT/tmux/build-darwin/bin/tmux" ;;
    *)      TMUX_BIN_DEFAULT="$REPO_ROOT/tmux/build/bin/tmux" ;;
esac
TMUX_BIN="${TMUX_BIN:-$TMUX_BIN_DEFAULT}"
CONF_TPL="$REPO_ROOT/scripts/tmux.conf.template"

echo "── Test 46: PASTE-INTO from OS clipboard physical proof (operator-path) ──"

PASS=0; FAIL=0; SKIP=0
S_NAME="tmx_t46_$$"
S_SOCK="tmx-${S_NAME}"
MARKER="PASTEMARK_${$}_$(date +%s)"

_pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
_fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }
_skip() { echo "SKIP: $*"; SKIP=$((SKIP + 1)); }

# Detect OS clipboard tool.
PASTE_CMD="" ; COPY_CMD="" ; CLIP_KIND="(none)"
case "$HOST_OS" in
    Darwin)
        if command -v pbpaste >/dev/null 2>&1 && command -v pbcopy >/dev/null 2>&1; then
            PASTE_CMD="pbpaste" ; COPY_CMD="pbcopy" ; CLIP_KIND="pbcopy/pbpaste"
        fi
        ;;
    Linux)
        if [ -n "${WAYLAND_DISPLAY:-}" ] && command -v wl-paste >/dev/null 2>&1 \
            && command -v wl-copy >/dev/null 2>&1; then
            PASTE_CMD="wl-paste -n" ; COPY_CMD="wl-copy" ; CLIP_KIND="wl-copy (Wayland)"
        elif [ -n "${DISPLAY:-}" ] && command -v xclip >/dev/null 2>&1; then
            PASTE_CMD="xclip -o -selection clipboard"
            COPY_CMD="xclip -i -selection clipboard" ; CLIP_KIND="xclip (X11)"
        elif command -v termux-clipboard-get >/dev/null 2>&1 \
            && command -v termux-clipboard-set >/dev/null 2>&1; then
            PASTE_CMD="termux-clipboard-get" ; COPY_CMD="termux-clipboard-set"
            CLIP_KIND="termux-clipboard (Termux/Android)"
        fi
        ;;
esac

# Save operator's prior clipboard so we restore on exit.
OLD_CLIP=""
if [ -n "$PASTE_CMD" ]; then
    OLD_CLIP="$(eval "$PASTE_CMD" 2>/dev/null || true)"
fi

_cleanup() {
    "$WRAPPER" kill-session -t "$S_NAME" 2>/dev/null || true
    "$TMUX_BIN" -L "$S_SOCK" kill-server 2>/dev/null || true
    if [ -n "$COPY_CMD" ]; then
        printf '%s' "$OLD_CLIP" | eval "$COPY_CMD" 2>/dev/null || true
    fi
}
trap _cleanup EXIT

# Pre-checks.
if [ ! -f "$CONF_TPL" ]; then
    _fail "T0: $CONF_TPL missing"
    echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"; exit 1
fi
if [ ! -x "$TMUX_BIN" ]; then
    _skip "T0: tmux binary $TMUX_BIN not built — run setup.sh first"
    echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"; exit 0
fi
if [ ! -x "$WRAPPER" ]; then
    _skip "T0: tmx wrapper $WRAPPER not generated — run setup.sh first"
    echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"; exit 0
fi
if [ -z "$PASTE_CMD" ] || [ -z "$COPY_CMD" ]; then
    _skip "T0: no system clipboard tool reachable (host=$HOST_OS) — paste-IN cannot be physically validated; T1 binding-presence still tested below"
    # We still want to PROVE the bindings exist on the template (T1) +
    # the live server (T2). Only the actual paste round-trip (T3/T4)
    # honestly SKIPs. So we do NOT early-exit here.
fi

echo "  marker: $MARKER"
echo "  clipboard tool: $CLIP_KIND"

# T1 — structural: the conf template carries the @clip-read user
#      option + the `prefix P` binding that pastes it in.
T1_OK=1
_t1() {
    if grep -Eq "$2" "$CONF_TPL"; then
        echo "  ✓ template: $1"
    else
        echo "  ✗ template MISSING: $1  (pattern: $2)"
        T1_OK=0
    fi
}
_t1 "@clip-read user option"   '^set +-g +@clip-read '
_t1 "prefix+P bind to paste"   '^bind +P +.*load-buffer|^bind +P +.*set-buffer|^bind +P +.*paste-buffer'
if [ "$T1_OK" -eq 1 ]; then
    _pass "T1: tmux.conf.template carries @clip-read + prefix+P paste binding"
else
    _fail "T1: tmux.conf.template is missing the paste-IN bindings (@clip-read or prefix+P)"
fi

# Spawn operator-path session.
"$WRAPPER" new -s "$S_NAME" -d >/dev/null 2>&1
sleep 2

if ! "$TMUX_BIN" -L "$S_SOCK" ls >/dev/null 2>&1; then
    _fail "T2.0: 'tmx new -s $S_NAME -d' did not create a server on socket $S_SOCK"
    echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"; exit 1
fi
_pass "T2.0: operator-path session created"

# T2 — live readback: the @clip-read user option is set on the server
#      AND the prefix+P binding is present.
LIVE_CR="$("$TMUX_BIN" -L "$S_SOCK" show-options -gv @clip-read 2>/dev/null || true)"
if [ -n "$LIVE_CR" ]; then
    _pass "T2.1: live server has @clip-read user-option set"
else
    _fail "T2.1: live server has no @clip-read user-option (paste-IN routing broken)"
fi

P_BIND="$("$TMUX_BIN" -L "$S_SOCK" list-keys -T prefix P 2>/dev/null || true)"
if printf '%s' "$P_BIND" | grep -Eq 'load-buffer|set-buffer|paste-buffer'; then
    _pass "T2.2: live prefix+P binding present (paste-IN keystroke path active)"
else
    _fail "T2.2: live prefix+P binding is not a paste binding"
    echo "  observed: $P_BIND"
fi

# T3 — put MARKER in OS clipboard, drive the SAME command sequence the
#      prefix+P binding would invoke, then capture-pane for MARKER.
if [ -n "$COPY_CMD" ] && [ -n "$PASTE_CMD" ]; then
    printf '%s' "$MARKER" | eval "$COPY_CMD" 2>/dev/null
    sleep 0.2
    # Verify the clipboard now contains MARKER (the seeding worked).
    SEED_OK="$(eval "$PASTE_CMD" 2>/dev/null || true)"
    if printf '%s' "$SEED_OK" | grep -q "$MARKER"; then
        # Now drive the SAME command sequence prefix+P would run.
        # @clip-read is shell-quoted in the conf; use it via show-options.
        CLIP_READ_CMD="$("$TMUX_BIN" -L "$S_SOCK" show-options -gv @clip-read 2>/dev/null || true)"
        if [ -n "$CLIP_READ_CMD" ]; then
            # Pipe clipboard through load-buffer + paste-buffer.
            eval "$CLIP_READ_CMD" 2>/dev/null \
              | "$TMUX_BIN" -L "$S_SOCK" load-buffer -t "$S_NAME" -
            sleep 0.2
            "$TMUX_BIN" -L "$S_SOCK" paste-buffer -p -t "$S_NAME" 2>/dev/null || true
            sleep 0.4
            VIS_OR_BUF="$("$TMUX_BIN" -L "$S_SOCK" capture-pane -p -S - -t "$S_NAME" 2>/dev/null || true)"
            # The marker might land on the prompt or be partially typed
            # so we grep on captured pane content.
            if printf '%s' "$VIS_OR_BUF" | grep -q "$MARKER"; then
                _pass "T3: PHYSICAL paste-IN proven — clipboard marker reached the tmux pane via @clip-read + paste-buffer"
            else
                _fail "T3: paste-IN did NOT route OS clipboard marker into pane (pane capture lacks marker)"
                echo "  pane tail: $(printf '%s' "$VIS_OR_BUF" | tail -c 200)"
            fi
        else
            _fail "T3: @clip-read not set on live server — cannot exercise paste-IN flow"
        fi
    else
        _skip "T3: clipboard seeding via $COPY_CMD did not stick — paste-IN test inert this run"
    fi
else
    _skip "T3: no OS clipboard tool — paste-IN physical proof cannot run (T1/T2 binding-presence still verify the wiring)"
fi

# T4 — verify the prefix+P binding's command body matches the
#      @clip-read mechanism (defensive: catches drift where the bind
#      changes to a non-@clip-read paste).
if printf '%s' "$P_BIND" | grep -q '@clip-read'; then
    _pass "T4: prefix+P bind body references @clip-read (mechanism wired end-to-end at binding layer)"
else
    _fail "T4: prefix+P bind does not reference @clip-read — paste-IN bypasses the OS-adaptive read"
    echo "  observed: $P_BIND"
fi

echo ""
echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
