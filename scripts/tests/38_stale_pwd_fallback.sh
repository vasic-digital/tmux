#!/usr/bin/env bash
# Test 29 — wrapper falls back to $HOME when recalled cwd no longer exists.
#
# CONTRACT (spec §6 edge case 7): if tmx-state recall returns a path
# that has since been deleted, the wrapper MUST print
# `[tmx] last-pwd <path> no longer exists for <session>; using $HOME`
# to stderr AND start the new session with -c $HOME. POSITIVE evidence
# per §11.4.5: captured stderr line + the new session's pane_current_path
# = $HOME.
#
# §11.4.50 reliability: 3 iterations.
# §11.4.81 cross-platform: same wrapper logic on macOS/Linux.
# §11.4.14 cleanup.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WRAPPER="${WRAPPER:-$REPO_ROOT/scripts/tmx}"
TMUX_BIN_DEFAULT="$REPO_ROOT/tmux/build-darwin/bin/tmux"
[ -x "$TMUX_BIN_DEFAULT" ] || TMUX_BIN_DEFAULT="$REPO_ROOT/tmux/build/bin/tmux"
TMUX_BIN="${TMUX_BIN:-$TMUX_BIN_DEFAULT}"
STATE_BIN="$REPO_ROOT/scripts/tmx-state-bin"

SESS="tmx-test-29-stale-$$"
GONE_DIR="/tmp/tmx-test-29-gone-$$"
export TMX_STATE_FILE="/tmp/tmx-test-29-$$.json"
SOCK_LABEL="tmx-${SESS}"

_cleanup() {
    "$WRAPPER" kill-session -t "$SESS" >/dev/null 2>&1 || true
    "$TMUX_BIN" -L "$SOCK_LABEL" kill-server >/dev/null 2>&1 || true
    rm -rf "$GONE_DIR" "$TMX_STATE_FILE" 2>/dev/null || true
}
trap '_cleanup' EXIT

[ -x "$WRAPPER" ] || { echo "SKIP 29: tmx wrapper not built"; exit 77; }
[ -x "$STATE_BIN" ] || { echo "SKIP 29: tmx-state-bin not built"; exit 77; }
[ -x "$TMUX_BIN" ] || { echo "SKIP 29: tmux binary not built"; exit 77; }

# Pre-flight: generated wrapper must contain P4 integration; else
# operator hasn't re-run setup.sh and the stale-pwd path doesn't trigger.
if ! grep -q 'no longer exists for' "$WRAPPER" 2>/dev/null; then
    echo "SKIP 29: generated wrapper $WRAPPER lacks P4 stale-pwd fallback — run scripts/setup.sh to regenerate"
    exit 77
fi

HOST_OS="$(uname -s)"
case "$HOST_OS" in
    Darwin|Linux) ;;
    *) echo "SKIP 29: unsupported platform $HOST_OS"; exit 77 ;;
esac

run_iteration() {
    local iter="$1"
    "$WRAPPER" kill-session -t "$SESS" >/dev/null 2>&1 || true
    sleep 0.2
    rm -f "$TMX_STATE_FILE"
    # Record a path that does NOT exist.
    "$STATE_BIN" record "$SESS" "$GONE_DIR" >/dev/null
    # Confirm the path is absent (no race).
    if [ -d "$GONE_DIR" ]; then
        echo "FAIL 29 iter=$iter: $GONE_DIR exists when it should not"
        return 1
    fi
    # Run the wrapper — capture stderr to look for the notice.
    local stderr_file="/tmp/tmx-test-29-stderr-$$-$iter.txt"
    "$WRAPPER" new -s "$SESS" -d 2>"$stderr_file" >/dev/null || true
    sleep 0.5
    local stderr_content
    stderr_content="$(cat "$stderr_file")"
    rm -f "$stderr_file"
    if ! echo "$stderr_content" | grep -q "last-pwd .* no longer exists for $SESS"; then
        echo "FAIL 29 iter=$iter: missing stale-pwd notice on stderr; stderr=$stderr_content"
        return 1
    fi
    # Verify pane started in $HOME (not the gone dir).
    local pane_path
    pane_path="$("$TMUX_BIN" -L "$SOCK_LABEL" display-message -p '#{pane_current_path}' 2>/dev/null)"
    # Real HOME may be symlinked (e.g. /Users/x → /private/var/...). Resolve both.
    local home_real pane_real
    home_real="$(cd "$HOME" && pwd -P)"
    pane_real="$(cd "$pane_path" 2>/dev/null && pwd -P || echo "$pane_path")"
    if [ "$pane_real" != "$home_real" ]; then
        echo "FAIL 29 iter=$iter: pane_current_path='$pane_path' (resolved='$pane_real') != HOME='$home_real'"
        return 1
    fi
    _evidence="iter=$iter stale_notice=present pane_path=$pane_path home_real=$home_real match=yes"
    "$WRAPPER" kill-session -t "$SESS" >/dev/null 2>&1 || true
    sleep 0.3
    return 0
}

_hashes=()
for i in 1 2 3; do
    if ! run_iteration "$i"; then exit 1; fi
    _h="$(echo "notice=present pane=home" | shasum | cut -d' ' -f1)"
    _hashes+=("$_h")
    echo "[evidence] $_evidence"
done

if [ "${_hashes[0]}" != "${_hashes[1]}" ] || [ "${_hashes[1]}" != "${_hashes[2]}" ]; then
    echo "FAIL 29: N=3 evidence hashes diverge: ${_hashes[*]}"
    exit 1
fi

echo "[evidence] HOST_OS=$HOST_OS reliability_hash=${_hashes[0]}"
echo "PASS 29 wrapper falls back to \$HOME when stale recalled cwd missing (3/3 iterations)"
exit 0
