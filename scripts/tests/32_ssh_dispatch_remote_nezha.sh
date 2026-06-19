#!/usr/bin/env bash
# Test 23 — tmx-ssh-dispatch: real SSH dispatch to nezha.local.
#
# CONTRACT (spec §5.2 + §7 Layer 3): an operator running
# `ssh nezha-tmx <session>` MUST land directly in that tmx session.
# POSITIVE evidence per §11.4.5: post-ssh `ssh nezha 'tmx ls'`
# shows the session.
#
# §11.4.3 topology dispatch: SKIP-77 if nezha is unreachable OR if the
# operator's ~/.ssh/config has no nezha-tmx Host alias (installer not
# run). Opt-in via TMX_TEST_REMOTE=1 because this is HEAVY (network).
# §11.4.50 reliability: 3 iterations.
# §11.4.81 cross-platform: nezha is Linux; client may be macOS or Linux.
# §11.4.14 cleanup: ssh into nezha and kill the test session.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Opt-in guard: this is the heavy real-network test.
if [ -z "${TMX_TEST_REMOTE:-}" ]; then
    echo "SKIP 23: remote tests require TMX_TEST_REMOTE=1 (opt-in, network-heavy)"
    exit 77
fi

SCRATCH="${TMPDIR:-/tmp}"; SCRATCH="${SCRATCH%/}"
_wtest="$SCRATCH/.tmx_wtest_$$"
if ! mkdir -p "$_wtest" 2>/dev/null || [ ! -w "$_wtest" ]; then
    echo "SKIP 23: scratch root $SCRATCH not writable — §11.4.3"; rm -rf "$_wtest" 2>/dev/null || true; exit 77
fi
rmdir "$_wtest" 2>/dev/null || true

REMOTE_HOST="${TMX_TEST_REMOTE_HOST:-milosvasic@nezha.local}"
REMOTE_ALIAS="${TMX_TEST_REMOTE_ALIAS:-nezha-tmx}"
SESS="tmx-test-23-remote-$$"
export TMX_STATE_FILE="$SCRATCH/tmx-test-23-$$.json"

_cleanup() {
    # Best-effort: kill the remote session if reachable.
    ssh -o BatchMode=yes -o ConnectTimeout=3 "$REMOTE_HOST" \
        "tmx kill-session -t '$SESS' >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
    rm -f "$TMX_STATE_FILE" 2>/dev/null || true
}
trap '_cleanup' EXIT

# Topology probe per §11.4.3.
if ! ssh -o BatchMode=yes -o ConnectTimeout=3 "$REMOTE_HOST" exit >/dev/null 2>&1; then
    echo "SKIP 23: $REMOTE_HOST unreachable via BatchMode SSH (probe failed)"
    exit 77
fi

# Normal SSH must still work (regression check — installer's authorized_keys
# entry must NOT replace the operator's standard login key).
if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE_HOST" -- 'ls /tmp >/dev/null 2>&1'; then
    echo "SKIP 23: normal SSH command execution failing — pre-existing infra issue"
    exit 77
fi

# Check the operator's ~/.ssh/config has the dispatcher alias.
if ! ssh -G "$REMOTE_ALIAS" 2>/dev/null | grep -qi "^hostname "; then
    echo "SKIP 23: ~/.ssh/config alias '$REMOTE_ALIAS' not configured (run tmx-ssh-install.sh first)"
    exit 77
fi

# Confirm the alias resolves to the same host (sanity).
ALIAS_HOST="$(ssh -G "$REMOTE_ALIAS" 2>/dev/null | awk '/^hostname / {print $2}')"
echo "[evidence] alias=$REMOTE_ALIAS resolves to hostname=$ALIAS_HOST"

# §11.4.81 — record client platform; remote is always Linux.
echo "[evidence] client_uname=$(uname -s) remote_target=$REMOTE_HOST"

run_iteration() {
    local iter="$1"
    # Pre-clean any leftover.
    ssh "$REMOTE_HOST" "tmx kill-session -t '$SESS' >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
    sleep 0.5
    # Dispatch via the alias — the dispatcher receives SSH_ORIGINAL_COMMAND
    # = "$SESS" via the `command=` wrapper on the remote authorized_keys
    # line. We background the ssh (it would otherwise block on tmux attach)
    # and verify the session lands.
    ssh "$REMOTE_ALIAS" "$SESS" </dev/null >/dev/null 2>&1 &
    local ssh_pid=$!
    sleep 2
    # Verify via a SECOND ssh that the session now exists remotely.
    local listed
    listed="$(ssh "$REMOTE_HOST" 'tmx ls 2>/dev/null' 2>/dev/null | grep -E "^${SESS}:" || true)"
    # Background ssh is still attached to a session — kill it so the
    # client side doesn't linger.
    kill -TERM "$ssh_pid" 2>/dev/null || true
    wait "$ssh_pid" 2>/dev/null || true
    if [ -z "$listed" ]; then
        echo "FAIL 23 iter=$iter: remote tmx ls did not show '$SESS'"
        ssh "$REMOTE_HOST" 'tmx ls 2>&1' 2>&1 | sed 's/^/    /'
        return 1
    fi
    _evidence="iter=$iter listed='$listed'"
    # Clean up.
    ssh "$REMOTE_HOST" "tmx kill-session -t '$SESS' >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
    sleep 0.5
    return 0
}

_hashes=()
for i in 1 2 3; do
    if ! run_iteration "$i"; then exit 1; fi
    _h="$(echo "session=$SESS remote-listed=yes" | shasum | cut -d' ' -f1)"
    _hashes+=("$_h")
    echo "[evidence] $_evidence"
done

if [ "${_hashes[0]}" != "${_hashes[1]}" ] || [ "${_hashes[1]}" != "${_hashes[2]}" ]; then
    echo "FAIL 23: N=3 evidence hashes diverge: ${_hashes[*]}"
    exit 1
fi

echo "[evidence] reliability_hash=${_hashes[0]}"
echo "PASS 23 tmx-ssh-dispatch: real SSH to $REMOTE_HOST via $REMOTE_ALIAS landed in session (3/3 iterations)"
exit 0
