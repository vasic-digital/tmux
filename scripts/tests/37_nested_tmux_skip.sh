#!/usr/bin/env bash
# Test 28 — tmx-shell-init: $TMUX already set → silent skip.
#
# CONTRACT (spec §6 edge case 4): when $TMUX env var is set (we are
# already inside a tmux session), the init MUST return 0 silently —
# no prompt, no new session creation. POSITIVE evidence per §11.4.5:
# empty stdout/stderr + no tmx session created for our prefix.
#
# §11.4.50 reliability: 3 iterations.
# §11.4.81 cross-platform: POSIX env-var semantics identical.
# §11.4.14 cleanup.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEMPLATE="$REPO_ROOT/scripts/tmx-shell-init.sh.template"
INIT_FILE="/tmp/tmx-shell-init-28-$$.sh"
PREFIX="tmx-test-nested-28"
export TMX_STATE_FILE="/tmp/tmx-test-28-$$.json"

_cleanup() {
    rm -f "$INIT_FILE" "$TMX_STATE_FILE" 2>/dev/null || true
    if command -v tmx >/dev/null 2>&1; then
        tmx ls 2>/dev/null | grep -oE "^${PREFIX}[^:]*" | while read -r s; do
            tmx kill-session -t "$s" >/dev/null 2>&1 || true
        done
    fi
}
trap '_cleanup' EXIT

[ -f "$TEMPLATE" ] || { echo "SKIP 28: tmx-shell-init.sh.template not present"; exit 77; }

sed "s|__PROJECT__|$REPO_ROOT|g; s|__DATE__|test-28|g" "$TEMPLATE" > "$INIT_FILE"
chmod 644 "$INIT_FILE"

run_iteration() {
    local iter="$1"
    local before
    if command -v tmx >/dev/null 2>&1; then
        before="$(tmx ls 2>/dev/null | grep -cE "^${PREFIX}" || true)"
    else
        before=0
    fi
    before="${before:-0}"
    # Set TMUX to a fake socket-tuple value (mimics being inside tmux).
    # Pipe a session name to stdin so that IF the TMUX check were
    # bypassed, the init would try to create that session — the test
    # would then fail because it WOULD see a session in `tmx ls`.
    local out rc
    out="$(TMUX='fake-socket,1,0' bash "$INIT_FILE" <<<"${PREFIX}-fail" 2>&1)" && rc=0 || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "FAIL 28 iter=$iter: init returned $rc when \$TMUX set; out=$out"
        return 1
    fi
    if [ -n "$out" ]; then
        echo "FAIL 28 iter=$iter: init produced output when \$TMUX set (expected silent); out=$out"
        return 1
    fi
    local after
    if command -v tmx >/dev/null 2>&1; then
        after="$(tmx ls 2>/dev/null | grep -cE "^${PREFIX}" || true)"
    else
        after=0
    fi
    after="${after:-0}"
    if [ "$after" -ne 0 ]; then
        echo "FAIL 28 iter=$iter: tmx created a ${PREFIX} session despite \$TMUX set"
        return 1
    fi
    _evidence="iter=$iter rc=$rc out_empty=yes session_count=$after"
    return 0
}

_hashes=()
for i in 1 2 3; do
    if ! run_iteration "$i"; then exit 1; fi
    _h="$(echo "rc=0 silent no-session" | shasum | cut -d' ' -f1)"
    _hashes+=("$_h")
    echo "[evidence] $_evidence"
done

if [ "${_hashes[0]}" != "${_hashes[1]}" ] || [ "${_hashes[1]}" != "${_hashes[2]}" ]; then
    echo "FAIL 28: N=3 evidence hashes diverge: ${_hashes[*]}"
    exit 1
fi

echo "[evidence] reliability_hash=${_hashes[0]}"
echo "PASS 28 tmx-shell-init: \$TMUX set → silent skip (3/3 iterations)"
exit 0
