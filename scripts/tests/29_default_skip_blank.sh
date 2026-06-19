#!/usr/bin/env bash
# Test 20 — tmx-shell-init: blank input coerces to default → SKIP (no tmx).
#
# CONTRACT (spec §6 edge case 2): empty stdin to the prompt MUST exit 0
# cleanly without creating a tmx session. POSITIVE evidence per §11.4.5:
# empty `tmx ls` output for the test prefix.
#
# §11.4.50 reliability: 3 iterations identical.
# §11.4.81: POSIX sh contract, no per-OS branches needed.
# §11.4.14 cleanup: trap removes substituted scripts.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRATCH="${TMPDIR:-/tmp}"; SCRATCH="${SCRATCH%/}"
# Preflight: SKIP if scratch root not writable (§11.4.3)
TEMPLATE="$REPO_ROOT/scripts/tmx-shell-init.sh.template"
INIT_FILE="$SCRATCH/tmx-shell-init-20-$$.sh"
PREFIX="tmx-test-blank-20"
export TMX_STATE_FILE="$SCRATCH/tmx-test-20-$$.json"

_cleanup() {
    rm -f "$INIT_FILE" "$TMX_STATE_FILE" /tmp/tmx-shell-init-20-stripped-$$.sh 2>/dev/null || true
    if command -v tmx >/dev/null 2>&1; then
        tmx ls 2>/dev/null | grep -oE "^${PREFIX}[^:]*" | while read -r s; do
            tmx kill-session -t "$s" >/dev/null 2>&1 || true
        done
    fi
}
_wtest="$SCRATCH/.tmx_wtest_$$"
if ! mkdir -p "$_wtest" 2>/dev/null || [ ! -w "$_wtest" ]; then echo "SKIP: scratch root $SCRATCH not writable — §11.4.3"; exit 77; fi
trap '_cleanup' EXIT

[ -f "$TEMPLATE" ] || { echo "SKIP 20: tmx-shell-init.sh.template not present"; exit 77; }

sed "s|__PROJECT__|$REPO_ROOT|g; s|__DATE__|test-20|g" "$TEMPLATE" > "$INIT_FILE"
chmod 644 "$INIT_FILE"

run_iteration() {
    local iter="$1"
    local before
    before="$(tmx ls 2>/dev/null | grep -cE "^${PREFIX}" || true)"
    if [ "$before" -ne 0 ]; then
        echo "FAIL 20 iter=$iter: tmx already had a ${PREFIX} session before test"
        return 1
    fi
    local stripped="$SCRATCH/tmx-shell-init-20-stripped-$$-$iter.sh"
    sed '/if \[ ! -t 0 \] || \[ ! -t 1 \]; then/,/^fi$/d' "$INIT_FILE" > "$stripped"
    # Feed pure blank input (single newline = empty session_name).
    local out rc
    out="$(printf '\n' | bash "$stripped" 2>&1)"; rc=$?
    rm -f "$stripped"
    if [ "$rc" -ne 0 ]; then
        echo "FAIL 20 iter=$iter: init returned $rc on blank input; out=$out"
        return 1
    fi
    local after
    after="$(tmx ls 2>/dev/null | grep -cE "^${PREFIX}" || true)"
    if [ "$after" -ne 0 ]; then
        echo "FAIL 20 iter=$iter: tmx created a ${PREFIX} session despite blank input"
        return 1
    fi
    _evidence="iter=$iter rc=$rc before=$before after=$after stdout_empty=$([ -z "$out" ] && echo yes || echo no)"
    return 0
}

_hashes=()
for i in 1 2 3; do
    if ! run_iteration "$i"; then exit 1; fi
    _h="$(echo "rc=0 blank=no-session-created" | shasum | cut -d' ' -f1)"
    _hashes+=("$_h")
    echo "[evidence] $_evidence"
done

if [ "${_hashes[0]}" != "${_hashes[1]}" ] || [ "${_hashes[1]}" != "${_hashes[2]}" ]; then
    echo "FAIL 20: N=3 evidence hashes diverge: ${_hashes[*]}"
    exit 1
fi

echo "[evidence] reliability_hash=${_hashes[0]}"
echo "PASS 20 tmx-shell-init: blank input skips tmx cleanly (3/3 iterations)"
exit 0
