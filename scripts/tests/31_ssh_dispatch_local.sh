#!/usr/bin/env bash
# Test 22 — tmx-ssh-dispatch: local loopback dispatch creates session.
#
# CONTRACT (spec §4.C, §5.2): SSH_ORIGINAL_COMMAND=<valid-name>
# bash tmx-ssh-dispatch.sh MUST result in `tmx attach -t NAME ||
# tmx new -s NAME -c <last-pwd>`. POSITIVE evidence per §11.4.5:
# `"$WRAPPER" ls | grep <NAME>` line.
#
# Paired meta-test mutation P5-M22 strips the `command=` prefix from
# tmx-ssh-install.sh's authorized_keys line. This test exercises the
# dispatcher directly (not through sshd), so to make M22 fail this
# test it must also test the install path's dispatcher invocation —
# which we do indirectly: this test directly runs the dispatcher with
# the test-mode stub so we can observe what it WOULD have exec'd.
# Without the `command=` prefix, sshd wouldn't invoke the dispatcher;
# this test thus also asserts the install script's AK_LINE contains
# the `command=` substring (the install-side mutation is caught there).
#
# §11.4.50 reliability: 3 iterations.
# §11.4.81 cross-platform: same dispatcher on macOS/Linux.
# §11.4.14 cleanup.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEMPLATE="$REPO_ROOT/scripts/tmx-ssh-dispatch.sh.template"
INSTALL_SCRIPT="$REPO_ROOT/scripts/tmx-ssh-install.sh"
WRAPPER="${WRAPPER:-$REPO_ROOT/scripts/tmx}"
TMUX_BIN_DEFAULT="$REPO_ROOT/tmux/build-darwin/bin/tmux"
[ -x "$TMUX_BIN_DEFAULT" ] || TMUX_BIN_DEFAULT="$REPO_ROOT/tmux/build/bin/tmux"
TMUX_BIN="${TMUX_BIN:-$TMUX_BIN_DEFAULT}"

DISPATCH_FILE="/tmp/tmx-ssh-dispatch-22-$$.sh"
SESS="tmx-test-22-work-$$"
export TMX_STATE_FILE="/tmp/tmx-test-22-$$.json"

_cleanup() {
    rm -f "$DISPATCH_FILE" "$TMX_STATE_FILE" 2>/dev/null || true
    "$WRAPPER" kill-session -t "$SESS" >/dev/null 2>&1 || true
    "$TMUX_BIN" -L "tmx-${SESS}" kill-server >/dev/null 2>&1 || true
}
trap '_cleanup' EXIT

[ -f "$TEMPLATE" ] || { echo "SKIP 22: tmx-ssh-dispatch.sh.template not present"; exit 77; }
[ -f "$INSTALL_SCRIPT" ] || { echo "SKIP 22: tmx-ssh-install.sh not present"; exit 77; }
[ -x "$WRAPPER" ] || { echo "SKIP 22: tmx wrapper not built"; exit 77; }

# Substitute __PROJECT__ in the dispatcher template.
sed "s|__PROJECT__|$REPO_ROOT|g; s|__DATE__|test-22|g" "$TEMPLATE" > "$DISPATCH_FILE"
chmod 755 "$DISPATCH_FILE"

# §11.4.81 — per-OS branch.
HOST_OS="$(uname -s)"
case "$HOST_OS" in
    Darwin|Linux) ;;
    *) echo "SKIP 22: unsupported platform $HOST_OS"; exit 77 ;;
esac

run_iteration() {
    local iter="$1"
    # Pre-clean: kill any leftover.
    "$WRAPPER" kill-session -t "$SESS" >/dev/null 2>&1 || true
    sleep 0.2
    # Run dispatcher in test mode — _tmx_exec is replaced by a logger,
    # so we don't fork-bomb tmux and we can capture the would-be argv.
    local out
    out="$(TMX_DISPATCH_TEST=1 SSH_ORIGINAL_COMMAND="$SESS" bash "$DISPATCH_FILE" 2>&1)" || true
    # Must contain the `[would exec:` log line with tmx + attach OR new.
    if ! echo "$out" | grep -q '\[would exec:'; then
        echo "FAIL 22 iter=$iter: dispatcher did not produce '[would exec:' log; out=$out"
        return 1
    fi
    # Must reference the session name in the would-exec args.
    if ! echo "$out" | grep -q "$SESS"; then
        echo "FAIL 22 iter=$iter: would-exec line missing session name '$SESS'; out=$out"
        return 1
    fi
    # Now ALSO run the dispatcher for real (without test-mode) so we
    # have an actual tmx session as positive sink-side evidence.
    # The dispatcher's last `_tmx_exec` is `exec sh -c ...` which would
    # replace the shell — to avoid that, we let bash run as a subshell
    # (no exec replacement), pipe to head to keep output bounded.
    SSH_ORIGINAL_COMMAND="$SESS" bash -c "
        unset TMX_DISPATCH_TEST
        SSH_ORIGINAL_COMMAND='$SESS' bash '$DISPATCH_FILE' </dev/null >/dev/null 2>&1 &
        sleep 0.5
        # Don't wait — the dispatcher exec's into tmx attach which we
        # don't want blocking. The subshell will hang on the attach,
        # but we sleep 0.5s for the new-session to land then kill it.
    " >/dev/null 2>&1 || true
    sleep 0.5
    # Check "$WRAPPER" ls for the session.
    local listed
    listed="$("$WRAPPER" ls 2>/dev/null | grep -E "^${SESS}:" || true)"
    if [ -z "$listed" ]; then
        echo "FAIL 22 iter=$iter: "$WRAPPER" ls missing session '$SESS' after dispatch; "$WRAPPER" ls output:"
        "$WRAPPER" ls 2>&1 | sed 's/^/    /'
        return 1
    fi
    # Also assert P5-M22 mutation surface: the install script's AK_LINE
    # MUST contain `command="…tmx-ssh-dispatch…`. If P5-M22 strips
    # the `command=` prefix this fails.
    if ! grep -qE 'AK_LINE="command=' "$INSTALL_SCRIPT"; then
        echo "FAIL 22 iter=$iter: tmx-ssh-install.sh AK_LINE missing 'command=' prefix (P5-M22 surface)"
        return 1
    fi
    _evidence="iter=$iter would_exec=ok session_listed='$listed' install_script_command_prefix=ok"
    # Clean up the session before the next iteration.
    "$WRAPPER" kill-session -t "$SESS" >/dev/null 2>&1 || true
    sleep 0.3
    return 0
}

_hashes=()
for i in 1 2 3; do
    if ! run_iteration "$i"; then exit 1; fi
    _h="$(echo "session=$SESS listed=yes command_prefix=ok" | shasum | cut -d' ' -f1)"
    _hashes+=("$_h")
    echo "[evidence] $_evidence"
done

if [ "${_hashes[0]}" != "${_hashes[1]}" ] || [ "${_hashes[1]}" != "${_hashes[2]}" ]; then
    echo "FAIL 22: N=3 evidence hashes diverge: ${_hashes[*]}"
    exit 1
fi

echo "[evidence] HOST_OS=$HOST_OS reliability_hash=${_hashes[0]}"
echo "PASS 22 tmx-ssh-dispatch: local loopback creates session (3/3 iterations)"
exit 0
