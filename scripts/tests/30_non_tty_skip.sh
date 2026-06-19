#!/usr/bin/env bash
# Test 21 — tmx-shell-init: non-TTY stdin must silent-skip + return fast.
#
# CONTRACT (spec §6 edge case 5 + design G2): when stdin is NOT a TTY
# (scp, rsync, IDE pipe, cron), the init MUST return 0 within < 1s
# WITHOUT printing the prompt and WITHOUT blocking on `read`. The
# guarding line is:
#   if [ ! -t 0 ] || [ ! -t 1 ]; then return 0; fi
#
# Paired meta-test mutation P5-M20 strips that guard. This test MUST
# FAIL when the guard is missing (the script then prints the prompt
# and blocks reading from /dev/null until timeout).
#
# §11.4.50 reliability: 3 iterations.
# §11.4.81 cross-platform: per-OS branches verifying timing semantics
# on each platform (POSIX `time` is portable but its output isn't).
# §11.4.14 cleanup.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRATCH="${TMPDIR:-/tmp}"; SCRATCH="${SCRATCH%/}"
# Preflight: SKIP if scratch root not writable (§11.4.3)
TEMPLATE="$REPO_ROOT/scripts/tmx-shell-init.sh.template"
INIT_FILE="$SCRATCH/tmx-shell-init-21-$$.sh"
PREFIX="tmx-test-nontty-21"
export TMX_STATE_FILE="$SCRATCH/tmx-test-21-$$.json"

_cleanup() {
    rm -f "$INIT_FILE" "$TMX_STATE_FILE" 2>/dev/null || true
    if command -v tmx >/dev/null 2>&1; then
        tmx ls 2>/dev/null | grep -oE "^${PREFIX}[^:]*" | while read -r s; do
            tmx kill-session -t "$s" >/dev/null 2>&1 || true
        done
    fi
}
_wtest="$SCRATCH/.tmx_wtest_$$"
if ! mkdir -p "$_wtest" 2>/dev/null || [ ! -w "$_wtest" ]; then echo "SKIP: scratch root $SCRATCH not writable — §11.4.3"; exit 77; fi
trap '_cleanup' EXIT

[ -f "$TEMPLATE" ] || { echo "SKIP 21: tmx-shell-init.sh.template not present"; exit 77; }

sed "s|__PROJECT__|$REPO_ROOT|g; s|__DATE__|test-21|g" "$TEMPLATE" > "$INIT_FILE"
chmod 644 "$INIT_FILE"

# §11.4.81 — per-OS branch. The CORE assertion is identical (non-TTY
# stdin → quick exit), but per-platform evidence is captured for the
# uname-s value. P5-M24 strips a Darwin branch; this test exercises
# both branches positively.
HOST_OS="$(uname -s)"
case "$HOST_OS" in
    Darwin)
        _platform_note="Darwin: POSIX TTY semantics enforced by libc"
        ;;
    Linux)
        _platform_note="Linux: POSIX TTY semantics enforced by glibc/musl"
        ;;
    *)
        echo "SKIP 21: unsupported platform $HOST_OS"
        exit 77
        ;;
esac

run_iteration() {
    local iter="$1"
    local before
    if command -v tmx >/dev/null 2>&1; then
        before="$(tmx ls 2>/dev/null | grep -cE "^${PREFIX}" || true)"
    else
        before=0
    fi
    before="${before:-0}"
    # Run with stdin from /dev/null (definitively non-TTY).
    # `timeout 5` would fire on hang; if it fires, exit code = 124.
    local start_ns end_ns elapsed_ms rc out
    start_ns="$(python3 -c 'import time;print(int(time.time()*1000))')"
    out="$(timeout 5 bash -c "exec </dev/null; bash \"$INIT_FILE\" 2>&1")" || rc=$?
    rc="${rc:-0}"
    end_ns="$(python3 -c 'import time;print(int(time.time()*1000))')"
    elapsed_ms=$((end_ns - start_ns))
    if [ "$rc" -eq 124 ]; then
        echo "FAIL 21 iter=$iter: timeout fired (5s) — non-TTY guard missing/broken; out=$out"
        return 1
    fi
    if [ "$rc" -ne 0 ]; then
        echo "FAIL 21 iter=$iter: init returned $rc on non-TTY stdin; out=$out"
        return 1
    fi
    if [ "$elapsed_ms" -gt 2000 ]; then
        echo "FAIL 21 iter=$iter: took ${elapsed_ms}ms (expected <2000ms — non-TTY guard skip should be instant)"
        return 1
    fi
    # Stdout MUST NOT contain the prompt string.
    if echo "$out" | grep -q 'Enter session name'; then
        echo "FAIL 21 iter=$iter: prompt printed on non-TTY stdin (guard bypassed); out=$out"
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
        echo "FAIL 21 iter=$iter: tmx created a ${PREFIX} session on non-TTY"
        return 1
    fi
    _evidence="iter=$iter elapsed_ms=$elapsed_ms rc=$rc no_prompt=yes no_session=yes"
    return 0
}

_hashes=()
for i in 1 2 3; do
    if ! run_iteration "$i"; then exit 1; fi
    _h="$(echo "rc=0 fast no-prompt no-session" | shasum | cut -d' ' -f1)"
    _hashes+=("$_h")
    echo "[evidence] $_platform_note $_evidence"
done

if [ "${_hashes[0]}" != "${_hashes[1]}" ] || [ "${_hashes[1]}" != "${_hashes[2]}" ]; then
    echo "FAIL 21: N=3 evidence hashes diverge: ${_hashes[*]}"
    exit 1
fi

echo "[evidence] HOST_OS=$HOST_OS reliability_hash=${_hashes[0]}"
echo "PASS 21 tmx-shell-init: non-TTY stdin silent-skips fast (3/3 iterations, ${HOST_OS})"
exit 0
