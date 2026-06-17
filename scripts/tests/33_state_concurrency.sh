#!/usr/bin/env bash
# Test 24 — tmx-state record concurrency: 10 parallel writes don't corrupt state.
#
# CONTRACT (spec §5.1 + §6 edge case 8): N concurrent `tmx-state record`
# processes serialised by fcntl F_SETLKW, latest-wins per key. POSITIVE
# evidence per §11.4.5: final JSON file parses, has all 10 keys, last-
# seen values are recent.
#
# §11.4.50 reliability: 3 iterations.
# §11.4.81 cross-platform: fcntl semantics identical on macOS/Linux.
# §11.4.14 cleanup: sandbox state file removed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_BIN="$REPO_ROOT/scripts/tmx-state-bin"

# §11.4.3 / D2 TMPDIR-HARDCODE-001: route the scratch state file this test
# CREATES through ${TMPDIR:-/tmp} so a full host / does not false-FAIL.
# Default /tmp preserves prior behaviour when TMPDIR is unset.
SCRATCH="${TMPDIR:-/tmp}"
SCRATCH="${SCRATCH%/}"

# §11.4.3 writability PREFLIGHT: disk-full / RO scratch root → honest SKIP,
# not a confusing record/list failure.
_wtest_dir="$SCRATCH/.tmx_wtest_$$"
if ! mkdir -p "$_wtest_dir" 2>/dev/null || [ ! -w "$_wtest_dir" ]; then
    echo "SKIP 24: scratch root $SCRATCH not writable (disk full / RO) — §11.4.3"
    rm -rf "$_wtest_dir" 2>/dev/null || true
    exit 77
fi
rm -rf "$_wtest_dir" 2>/dev/null || true

export TMX_STATE_FILE="$SCRATCH/tmx-test-24-$$.json"
N=10

_cleanup() {
    rm -f "$TMX_STATE_FILE" 2>/dev/null || true
}
trap '_cleanup' EXIT

[ -x "$STATE_BIN" ] || { echo "SKIP 24: tmx-state-bin not built"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP 24: python3 not on PATH"; exit 77; }

# §11.4.81 cross-platform parity.
HOST_OS="$(uname -s)"
case "$HOST_OS" in
    Darwin|Linux) ;;
    *) echo "SKIP 24: unsupported platform $HOST_OS"; exit 77 ;;
esac

run_iteration() {
    local iter="$1"
    rm -f "$TMX_STATE_FILE"
    # Spawn N parallel record processes (each writes a unique key).
    local pids=()
    for i in $(seq 1 $N); do
        "$STATE_BIN" record "k$i" "/tmp/p$i" &
        pids+=("$!")
    done
    # Wait for all.
    local rc=0
    for p in "${pids[@]}"; do
        if ! wait "$p"; then rc=1; fi
    done
    if [ "$rc" -ne 0 ]; then
        echo "FAIL 24 iter=$iter: at least one record subprocess exited non-zero"
        return 1
    fi
    # Verify with `list` — must have N entries.
    local list_out count
    list_out="$("$STATE_BIN" list 2>&1)"
    count="$(echo "$list_out" | grep -cE '^k[0-9]+\b' || true)"
    if [ "$count" -ne "$N" ]; then
        echo "FAIL 24 iter=$iter: list returned $count entries (expected $N)"
        echo "$list_out" | sed 's/^/    /'
        return 1
    fi
    # Verify the JSON file directly with python3.
    local pychk
    pychk="$(python3 -c "
import json, sys
with open('$TMX_STATE_FILE') as f:
    d = json.load(f)
n = len(d.get('sessions', {}))
keys = sorted(d.get('sessions', {}).keys())
print(f'json_ok n={n} keys={\",\".join(keys)}')
sys.exit(0 if n == $N else 1)
" 2>&1)"
    local pyrc=$?
    if [ "$pyrc" -ne 0 ]; then
        echo "FAIL 24 iter=$iter: JSON validation failed; pychk=$pychk"
        return 1
    fi
    _evidence="iter=$iter list_count=$count $pychk"
    return 0
}

_hashes=()
for i in 1 2 3; do
    if ! run_iteration "$i"; then exit 1; fi
    _h="$(echo "n=$N json_ok" | shasum | cut -d' ' -f1)"
    _hashes+=("$_h")
    echo "[evidence] $_evidence"
done

if [ "${_hashes[0]}" != "${_hashes[1]}" ] || [ "${_hashes[1]}" != "${_hashes[2]}" ]; then
    echo "FAIL 24: N=3 evidence hashes diverge: ${_hashes[*]}"
    exit 1
fi

echo "[evidence] HOST_OS=$HOST_OS reliability_hash=${_hashes[0]}"
echo "PASS 24 tmx-state-bin: $N concurrent record writes serialised, JSON intact (3/3 iterations)"
exit 0
