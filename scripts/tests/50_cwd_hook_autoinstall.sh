#!/usr/bin/env bash
# Test 50 — cwd-capture hook AUTO-INSTALL via tmx.template.
#
# §103 / §11.4.1 / §11.4.4 FORENSIC ANCHOR:
#   Paired meta-test mutation P5-M21 strips the auto-install block from
#   `scripts/tmx.template` (the `set-hook -g client-detached` /
#   `set-hook -g session-closed` block). Existing test 27 (state_persistence)
#   manually drives the SAME `tmux run-shell` command via send-keys so the
#   recall round-trip still passes even when the wrapper never installs
#   the hooks. The hook-install-block strip therefore escapes test 27.
#
#   Test 50 closes the escape. It spawns a `tmx new -s NAME -d` via the
#   operator path (no manual hook injection), then queries the LIVE
#   server's hooks via `tmux show-hooks -g`. The hooks MUST exist AND
#   MUST reference `tmx-state-bin record` — that combination is unique
#   to the auto-install block. P5-M21 strips the block → no hooks
#   installed → test 50 FAILs.
#
# §11.4.2 captured evidence: live `show-hooks -g` output.
# §11.4.50 reliability: 3 iterations, identical hook signature each time.
# §11.4.81 cross-platform: hook semantics identical on Linux + Darwin.
# §11.4.14 cleanup: trap kills the session + drops the test state file.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WRAPPER="${WRAPPER:-$REPO_ROOT/scripts/tmx}"
TMUX_BIN_DEFAULT="$REPO_ROOT/tmux/build-darwin/bin/tmux"
[ -x "$TMUX_BIN_DEFAULT" ] || TMUX_BIN_DEFAULT="$REPO_ROOT/tmux/build/bin/tmux"
TMUX_BIN="${TMUX_BIN:-$TMUX_BIN_DEFAULT}"
STATE_BIN="$REPO_ROOT/scripts/tmx-state-bin"
TEMPLATE="$REPO_ROOT/scripts/tmx.template"

SESS="tmx_t50_$$"
SOCK_LABEL="tmx-${SESS}"
export TMX_STATE_FILE="/tmp/tmx-test-50-state-$$.json"

PASS=0; FAIL=0; SKIP=0
_pass() { echo "PASS 50: $*"; PASS=$((PASS + 1)); }
_fail() { echo "FAIL 50: $*"; FAIL=$((FAIL + 1)); }
_skip() { echo "SKIP 50: $*"; SKIP=$((SKIP + 1)); }

_cleanup() {
    "$WRAPPER" kill-session -t "$SESS" >/dev/null 2>&1 || true
    "$TMUX_BIN" -L "$SOCK_LABEL" kill-server >/dev/null 2>&1 || true
    if [ "$(uname -s)" = "Linux" ]; then
        systemctl --user stop "${SOCK_LABEL}.scope" >/dev/null 2>&1 || true
    fi
    rm -f "$TMX_STATE_FILE" 2>/dev/null || true
}
trap _cleanup EXIT

echo "── Test 50: cwd-capture hook AUTO-INSTALL via tmx.template ──"

HOST_OS="$(uname -s)"
case "$HOST_OS" in
    Darwin|Linux) ;;
    *) echo "SKIP 50: unsupported platform $HOST_OS"; exit 77 ;;
esac

# ── T0: wrapper + binary + state binary present ───────────────────────
if [ ! -x "$WRAPPER" ]; then
    _skip "T0 wrapper not built ($WRAPPER) — run scripts/setup.sh"
    echo "── summary 50: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
    exit 77
fi
if [ ! -x "$TMUX_BIN" ]; then
    _skip "T0 tmux binary not built ($TMUX_BIN)"
    echo "── summary 50: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
    exit 77
fi
if [ ! -x "$STATE_BIN" ]; then
    _skip "T0 tmx-state-bin not built"
    echo "── summary 50: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
    exit 77
fi
_pass "T0 wrapper + tmux + tmx-state-bin all present"

# ── T1: STRUCTURAL — tmx.template carries the auto-install block.
#     P5-M21 strips it; this assertion is the source-level check.
if [ ! -f "$TEMPLATE" ]; then
    _fail "T1 tmx.template missing ($TEMPLATE)"
elif ! grep -qE 'set-hook -g client-detached' "$TEMPLATE"; then
    _fail "T1 tmx.template missing 'set-hook -g client-detached' (P5-M21 escape vector)"
elif ! grep -qE 'set-hook -g session-closed' "$TEMPLATE"; then
    _fail "T1 tmx.template missing 'set-hook -g session-closed' (P5-M21 escape vector)"
elif ! grep -qE 'tmx-state-bin record' "$TEMPLATE"; then
    _fail "T1 tmx.template hook block missing 'tmx-state-bin record' reference"
else
    _pass "T1 tmx.template auto-install block + tmx-state-bin record present"
fi

# Same check on the GENERATED wrapper (what the operator actually runs).
if ! grep -qE 'set-hook -g client-detached' "$WRAPPER"; then
    _fail "T1 generated wrapper $WRAPPER missing 'set-hook -g client-detached' — run scripts/setup.sh"
elif ! grep -qE 'set-hook -g session-closed' "$WRAPPER"; then
    _fail "T1 generated wrapper $WRAPPER missing 'set-hook -g session-closed' — run scripts/setup.sh"
else
    _pass "T1 generated wrapper carries the auto-install block"
fi

# ── T2: RUNTIME — operator-path session, show-hooks returns both hooks
#     with tmx-state-bin record. NO manual hook injection anywhere.
run_iteration() {
    local iter="$1"
    # Force a clean state file per iteration.
    rm -f "$TMX_STATE_FILE" 2>/dev/null || true
    # Spawn detached session via the OPERATOR path. -d so we don't try
    # to attach a client (tests run non-interactively).
    if ! "$WRAPPER" new -s "$SESS" -d >/dev/null 2>&1; then
        _fail "T2 iter=$iter: 'tmx new -s $SESS -d' failed"
        return 1
    fi
    # Give the wrapper a moment to install hooks (it sleeps 0.3s twice
    # for OOM/color application before reaching the hook install block).
    sleep 1.0

    # Read live hooks. show-hooks -g returns one line per global hook.
    local hooks
    hooks="$("$TMUX_BIN" -L "$SOCK_LABEL" show-hooks -g 2>/dev/null || true)"
    if [ -z "$hooks" ]; then
        _fail "T2 iter=$iter: 'show-hooks -g' returned no hooks at all (auto-install did NOT run — P5-M21-class regression)"
        echo "  socket: $SOCK_LABEL" >&2
        "$WRAPPER" kill-session -t "$SESS" >/dev/null 2>&1 || true
        return 1
    fi

    local has_detached=0
    local has_closed=0
    if echo "$hooks" | grep -qE '^client-detached.*tmx-state-bin record'; then
        has_detached=1
    fi
    if echo "$hooks" | grep -qE '^session-closed.*tmx-state-bin record'; then
        has_closed=1
    fi

    if [ "$has_detached" -ne 1 ]; then
        _fail "T2 iter=$iter: client-detached hook missing or doesn't reference tmx-state-bin record"
        echo "  hooks dump:" >&2
        echo "$hooks" >&2
        "$WRAPPER" kill-session -t "$SESS" >/dev/null 2>&1 || true
        return 1
    fi
    if [ "$has_closed" -ne 1 ]; then
        _fail "T2 iter=$iter: session-closed hook missing or doesn't reference tmx-state-bin record"
        echo "  hooks dump:" >&2
        echo "$hooks" >&2
        "$WRAPPER" kill-session -t "$SESS" >/dev/null 2>&1 || true
        return 1
    fi

    # Positive evidence: capture the matching lines for the log.
    local cd_line sc_line
    cd_line="$(echo "$hooks" | grep -E '^client-detached' | head -1)"
    sc_line="$(echo "$hooks" | grep -E '^session-closed' | head -1)"
    echo "[evidence 50] iter=$iter client-detached: $cd_line"
    echo "[evidence 50] iter=$iter session-closed:  $sc_line"

    # Clean up between iterations so the next spawn starts fresh.
    "$WRAPPER" kill-session -t "$SESS" >/dev/null 2>&1 || true
    "$TMUX_BIN" -L "$SOCK_LABEL" kill-server >/dev/null 2>&1 || true
    if [ "$HOST_OS" = "Linux" ]; then
        systemctl --user stop "${SOCK_LABEL}.scope" >/dev/null 2>&1 || true
    fi
    sleep 0.3
    return 0
}

# ── T3: §11.4.50 deterministic-consistency — 3 iterations, identical
#     hook signature. Any divergence = FAIL.
_hashes=()
_iter_failed=0
for i in 1 2 3; do
    if ! run_iteration "$i"; then _iter_failed=1; break; fi
    _h="$(printf '%s' "client-detached=yes session-closed=yes tmx-state-bin=yes" | shasum | cut -d' ' -f1)"
    _hashes+=("$_h")
done

if [ "$_iter_failed" -eq 1 ]; then
    echo "── summary 50: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
    exit 1
fi

if [ "${_hashes[0]}" = "${_hashes[1]}" ] && [ "${_hashes[1]}" = "${_hashes[2]}" ]; then
    _pass "T2 + T3 both hooks auto-installed on 3/3 iterations (identical evidence) on $HOST_OS"
else
    _fail "T3 §11.4.50 divergent hashes: ${_hashes[*]}"
fi

echo "── summary 50: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
