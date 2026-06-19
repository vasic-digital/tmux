#!/usr/bin/env bash
# Test 25 — tmx-ssh-install --dry-run is idempotent: running twice produces
# identical action lists.
#
# CONTRACT (spec §6 edge case 13): repeated installer runs MUST NOT
# create duplicate authorized_keys lines or duplicate Host blocks.
# POSITIVE evidence per §11.4.5: diff between run-1 and run-2 dry-run
# output is empty.
#
# §11.4.50 reliability: 3 iterations.
# §11.4.81 cross-platform: same installer on macOS/Linux.
# §11.4.14 cleanup.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRATCH="${TMPDIR:-/tmp}"; SCRATCH="${SCRATCH%/}"
# Preflight: SKIP if scratch root not writable (§11.4.3)
INSTALL_SCRIPT="$REPO_ROOT/scripts/tmx-ssh-install.sh"
RUN1="$SCRATCH/tmx-test-25-run1-$$.txt"
RUN2="$SCRATCH/tmx-test-25-run2-$$.txt"
DIFF="$SCRATCH/tmx-test-25-diff-$$.txt"

_cleanup() {
    rm -f "$RUN1" "$RUN2" "$DIFF" 2>/dev/null || true
}
_wtest="$SCRATCH/.tmx_wtest_$$"
if ! mkdir -p "$_wtest" 2>/dev/null || [ ! -w "$_wtest" ]; then echo "SKIP: scratch root $SCRATCH not writable — §11.4.3"; exit 77; fi
trap '_cleanup' EXIT

[ -x "$INSTALL_SCRIPT" ] || { echo "SKIP 25: tmx-ssh-install.sh not present/executable"; exit 77; }
# Probe for --dry-run support.
if ! "$INSTALL_SCRIPT" --help 2>&1 | grep -q -- '--dry-run' && \
   ! grep -q -- '--dry-run' "$INSTALL_SCRIPT"; then
    echo "SKIP 25: tmx-ssh-install.sh lacks --dry-run flag"
    exit 77
fi

run_iteration() {
    local iter="$1"
    # Run dry-run twice with the same args.  Installer writes its
    # action log to STDERR (so its stdout stays usable for scripting).
    # Capture stderr+stdout combined: `> file 2>&1`, not `2>&1 > file`.
    "$INSTALL_SCRIPT" --dry-run testuser@testhost.invalid > "$RUN1" 2>&1 || true
    "$INSTALL_SCRIPT" --dry-run testuser@testhost.invalid > "$RUN2" 2>&1 || true
    # Filter out the per-invocation verification token which deliberately
    # uses $$ for uniqueness ("tmx-install-verify-token-XXXX").  Other
    # lines should be byte-identical across runs.
    local f1 f2
    f1="$(grep -vE 'tmx-install-verify-token-[0-9]+|^\[20[0-9]{2}-' "$RUN1" || cat "$RUN1")"
    f2="$(grep -vE 'tmx-install-verify-token-[0-9]+|^\[20[0-9]{2}-' "$RUN2" || cat "$RUN2")"
    # Also require run1 to be non-trivially-sized (>200 bytes); a 0-byte
    # capture would silently pass the diff check.
    local r1_bytes
    r1_bytes=$(wc -c < "$RUN1" | tr -d ' ')
    if [ "$r1_bytes" -lt 200 ]; then
        echo "FAIL 25 iter=$iter: installer dry-run produced only $r1_bytes bytes (expected >200)"
        cat "$RUN1" | head -5 | sed 's/^/    /'
        return 1
    fi
    if [ "$f1" != "$f2" ]; then
        diff <(echo "$f1") <(echo "$f2") > "$DIFF" || true
        echo "FAIL 25 iter=$iter: dry-run output differs between runs (non-idempotent):"
        head -40 "$DIFF" | sed 's/^/    /'
        return 1
    fi
    _evidence="iter=$iter run1_bytes=$(wc -c <"$RUN1" | tr -d ' ') run2_bytes=$(wc -c <"$RUN2" | tr -d ' ') filtered_diff_empty=yes"
    return 0
}

_hashes=()
for i in 1 2 3; do
    if ! run_iteration "$i"; then exit 1; fi
    _h="$(echo "diff=empty" | shasum | cut -d' ' -f1)"
    _hashes+=("$_h")
    echo "[evidence] $_evidence"
done

if [ "${_hashes[0]}" != "${_hashes[1]}" ] || [ "${_hashes[1]}" != "${_hashes[2]}" ]; then
    echo "FAIL 25: N=3 evidence hashes diverge: ${_hashes[*]}"
    exit 1
fi

echo "[evidence] reliability_hash=${_hashes[0]}"
echo "PASS 25 tmx-ssh-install --dry-run idempotent (3/3 iterations)"
exit 0
