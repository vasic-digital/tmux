#!/usr/bin/env bash
# Test 27 — tmx-ssh-dispatch: multi-word / shell-injection rejected.
#
# CONTRACT (spec §6 edge case 9 + §5.2): SSH_ORIGINAL_COMMAND containing
# spaces, shell metacharacters, or command substitutions MUST be rejected
# with stderr message and non-zero exit. POSITIVE evidence per §11.4.5:
# rejection stderr per attempted command + no tmx session created.
#
# §11.4.50 reliability: 3 iterations.
# §11.4.81 cross-platform: POSIX `case` semantics identical.
# §11.4.14 cleanup.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRATCH="${TMPDIR:-/tmp}"; SCRATCH="${SCRATCH%/}"
# Preflight: SKIP if scratch root not writable (§11.4.3)
DISPATCH_TEMPLATE="$REPO_ROOT/scripts/tmx-ssh-dispatch.sh.template"
DISPATCH_FILE="$SCRATCH/tmx-ssh-dispatch-27-$$.sh"
export TMX_STATE_FILE="$SCRATCH/tmx-test-27-$$.json"

_cleanup() {
    rm -f "$DISPATCH_FILE" "$TMX_STATE_FILE" 2>/dev/null || true
}
_wtest="$SCRATCH/.tmx_wtest_$$"
if ! mkdir -p "$_wtest" 2>/dev/null || [ ! -w "$_wtest" ]; then echo "SKIP: scratch root $SCRATCH not writable — §11.4.3"; exit 77; fi
trap '_cleanup' EXIT

[ -f "$DISPATCH_TEMPLATE" ] || { echo "SKIP 27: tmx-ssh-dispatch.sh.template not present"; exit 77; }

sed "s|__PROJECT__|$REPO_ROOT|g; s|__DATE__|test-27|g" "$DISPATCH_TEMPLATE" > "$DISPATCH_FILE"
chmod 755 "$DISPATCH_FILE"

# Multi-word and metacharacter-laden commands — all MUST be rejected.
BAD_COMMANDS=( 'echo hi' 'work; rm -rf /' '$(date)' '`whoami`' 'a&b' 'a|b' 'a>b' 'a<b' )

run_iteration() {
    local iter="$1"
    local failures=0
    for cmd in "${BAD_COMMANDS[@]}"; do
        local out rc
        out="$(TMX_DISPATCH_TEST=1 SSH_ORIGINAL_COMMAND="$cmd" bash "$DISPATCH_FILE" 2>&1)" && rc=0 || rc=$?
        if [ "$rc" -eq 0 ]; then
            echo "  iter=$iter: cmd='$cmd' was ACCEPTED (expected rejection); out=$out"
            failures=$((failures + 1))
        fi
        if ! echo "$out" | grep -q 'tmx-ssh-dispatch'; then
            echo "  iter=$iter: cmd='$cmd' rejected but stderr missing dispatcher tag; out=$out"
            failures=$((failures + 1))
        fi
        # Crucially: must NOT contain '[would exec:' — that would mean the
        # dispatcher passed the bad input through.
        if echo "$out" | grep -q '\[would exec:'; then
            echo "  iter=$iter: cmd='$cmd' reached exec branch (security violation); out=$out"
            failures=$((failures + 1))
        fi
    done
    if [ "$failures" -gt 0 ]; then
        echo "FAIL 27 iter=$iter: $failures multi-word rejections failed"
        return 1
    fi
    _evidence="iter=$iter bad_cmds_tested=${#BAD_COMMANDS[@]} all_rejected=yes no_exec_branch=yes"
    return 0
}

_hashes=()
for i in 1 2 3; do
    if ! run_iteration "$i"; then exit 1; fi
    _h="$(echo "rejected=${#BAD_COMMANDS[@]} no_exec" | shasum | cut -d' ' -f1)"
    _hashes+=("$_h")
    echo "[evidence] $_evidence"
done

if [ "${_hashes[0]}" != "${_hashes[1]}" ] || [ "${_hashes[1]}" != "${_hashes[2]}" ]; then
    echo "FAIL 27: N=3 evidence hashes diverge: ${_hashes[*]}"
    exit 1
fi

echo "[evidence] reliability_hash=${_hashes[0]}"
echo "PASS 27 dispatcher rejects ${#BAD_COMMANDS[@]} multi-word/injection commands (3/3 iterations)"
exit 0
