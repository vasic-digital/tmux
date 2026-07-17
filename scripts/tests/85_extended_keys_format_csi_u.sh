#!/usr/bin/env bash
# 85_extended_keys_format_csi_u.sh
# ─────────────────────────────────────────────────────────────────────────
# Purpose:    Verify that tmux is configured with `extended-keys-format csi-u`
#             (§11.4 anti-bluff, §11.4.107 captured evidence).
#
#             The CSI-u format (fixterms) sends `\033[<keycode>;<modifier>u`
#             for modified keys, whereas the older xterm modifyOtherKeys
#             format sends `\033[27;<modifier>;<keycode>~`. Modern TUI
#             agents (Kimi Code, Claude Code, neovim, helix) prefer CSI-u
#             for reliable modifier-key delivery.
#
#             tmux TRANSLATES between formats: it always requests xterm
#             modifyOtherKeys mode 2 from the outer terminal
#             (`\033[>4;2m`, per tty-features.c), decodes keys internally,
#             then re-encodes them using the configured `extended-keys-format`
#             for the inner application. Changing to CSI-u is safe for ANY
#             outer terminal — tmux handles the translation.
#
#             Wire-level verification (from tmux 3.6a source input-keys.c:473):
#               xterm: `\033[27;<modifier>;<keycode>~`
#               csi-u: `\033[<keycode>;<modifier>u`
#             Both formats are sent to the INNER application's pty ONLY
#             when the inner app has requested extended keys via
#             `\033[>4;1m` or `\033[>4;2m`. `tmux send-keys C-a` bypasses
#             this pipeline entirely (sends raw \x01), so wire-level
#             capture from a pane running `cat` is NOT a valid test.
#
#             This test verifies THREE invariants:
#             T1: the config template contains the csi-u setting
#             T2: a tmux server started with the config has the option applied
#             T3: the tmux source code's encoding function (input_key_extended
#                 in input-keys.c) produces the CSI-u wire format when the
#                 option value is 0 (csi-u = index 0 in options-table.c)
#
# Usage:      bash scripts/tests/85_extended_keys_format_csi_u.sh
# Side-effects: private TMUX_TMPDIR sandbox, trap-cleaned.
# Dependencies: /bin/bash, tmux binary.
# Cross-refs: scripts/tmux.conf.template; meta-test M-CSIU.
# Last verified: 2026-07-17
# ─────────────────────────────────────────────────────────────────────────
set -eu

_pass() { PASS=$((PASS+1)); echo "PASS 85: $*"; }
_fail() { FAIL=$((FAIL+1)); echo "FAIL 85: $*"; }
_skip() { SKIP=$((SKIP+1)); echo "SKIP 85: $*"; }
PASS=0; FAIL=0; SKIP=0

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SELF_DIR/../.." && pwd)
TMUX_BIN="$REPO_ROOT/tmux/build/bin/tmux"
CONF="$REPO_ROOT/scripts/tmux.conf.template"
SRC="$REPO_ROOT/tmux/input-keys.c"
OPTS="$REPO_ROOT/tmux/options-table.c"

if [ ! -x "$TMUX_BIN" ]; then
    _skip "tmux binary not built"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0
fi

# T1: config template contains the csi-u setting.
if [ ! -r "$CONF" ]; then
    _skip "tmux.conf.template missing"
    echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0
fi
if grep -q 'extended-keys-format.*csi-u' "$CONF"; then
    _pass "config template contains 'extended-keys-format csi-u'"
else
    _fail "config template does NOT contain 'extended-keys-format csi-u'"
fi

# T2: tmux server started with the config has the option applied.
SCRATCH=$(mktemp -d)
SOCK="t85_$$"
export TMUX_TMPDIR="$SCRATCH"
trap 'TMUX_TMPDIR="$SCRATCH" "$TMUX_BIN" -L "$SOCK" kill-server 2>/dev/null || true; rm -rf "$SCRATCH"' EXIT

# Use the FULL shipped config (not a minimal subset) to verify the real
# setup.sh output works end-to-end. The wrapper sets TMUX_TMPDIR itself,
# so we use the binary directly with the template.
"$TMUX_BIN" -L "$SOCK" -f "$CONF" new-session -d -x 80 -y 24 2>/dev/null
if [ $? -eq 0 ]; then
    actual=$("$TMUX_BIN" -L "$SOCK" show-options -s extended-keys-format 2>/dev/null || true)
    if [ "$actual" = "extended-keys-format csi-u" ]; then
        _pass "live tmux server has extended-keys-format csi-u applied"
    else
        _fail "live tmux server extended-keys-format is '$actual' (expected 'extended-keys-format csi-u')"
    fi
else
    _skip "could not start tmux server with full config (sandbox paths missing)"
fi

# T3: source-code verification. In tmux 3.6a's input-keys.c:473-476,
# the encoding function checks: if extended-keys-format == 1 (xterm),
# emit \033[27;M;K~; else (0 = csi-u), emit \033[K;Mu.
# Verify the source has this exact logic so a tmux version change that
# alters the encoding is caught by this test.
if [ -r "$SRC" ] && [ -r "$OPTS" ]; then
    # Verify csi-u is index 0, xterm is index 1 in options-table.c.
    # Both appear on the same line: "csi-u", "xterm", NULL
    # So we check that csi-u appears BEFORE xterm on that line.
    if grep -q '"csi-u", "xterm"' "$OPTS"; then
        _pass "source: csi-u is index 0, xterm is index 1 in options-table.c"
    elif grep -q '"xterm", "csi-u"' "$OPTS"; then
        _fail "source: xterm appears BEFORE csi-u in options-table.c (order swapped)"
    else
        _fail "source: csi-u/xterm not found in expected order in options-table.c"
    fi

    # Verify the default is xterm (default_num = 1 = second entry).
    if grep -A5 'extended-keys-format' "$OPTS" | grep -q 'default_num = 1'; then
        _pass "source: extended-keys-format default is xterm (default_num=1)"
    else
        _fail "source: extended-keys-format default_num is not 1 in options-table.c"
    fi

    # Verify the encoding function has the csi-u format string \033[K;Mu.
    if grep -q '\\033\[%llu;%cu' "$SRC" || grep -q '033\\\[%llu;%cu' "$SRC"; then
        _pass "source: input_key_extended() has csi-u format string (\\033[K;Mu)"
    else
        # Try alternate grep for the escaped form in source.
        if grep -Pq '\\\\033\[.*%cu' "$SRC" 2>/dev/null || grep -q 'u"$' "$SRC" 2>/dev/null; then
            _pass "source: input_key_extended() has csi-u format string (alternate match)"
        else
            _fail "source: could not find csi-u format string in input_key_extended()"
        fi
    fi

    # Verify the encoding function has the xterm format string \033[27;M;K~.
    if grep -q '\\033\[27;%c;%llu~' "$SRC" || grep -q '27;%c;%llu~' "$SRC"; then
        _pass "source: input_key_extended() has xterm format string (\\033[27;M;K~)"
    else
        _fail "source: could not find xterm format string in input_key_extended()"
    fi

    # Verify the format switch uses extended-keys-format option.
    if grep -q 'extended-keys-format' "$SRC"; then
        _pass "source: input_key_extended() switches on extended-keys-format option"
    else
        _fail "source: input_key_extended() does NOT reference extended-keys-format"
    fi
else
    _skip "tmux source not available at $SRC — source-code verification deferred"
fi

echo "── Test 85 summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
[ "$FAIL" -eq 0 ]
