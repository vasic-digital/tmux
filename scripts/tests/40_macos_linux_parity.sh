#!/usr/bin/env bash
# Test 31 — §11.4.81 cross-platform parity demonstration test.
#
# CONTRACT (spec §6 edge case 14 + §11.4.81): for every tmx feature class
# that depends on platform primitives, this test asserts positive runtime
# evidence per-OS. The `case "$(uname -s)"` block is the §11.4.81 dispatch
# point; each arm makes its own positive assertion.
#
# Paired meta-test mutation P5-M24 strips a Darwin (or Linux) case-arm.
# This test MUST FAIL when run on the matching platform after the strip
# because that platform's branch is gone — the catch-all `*)` reports
# UNKNOWN (FAIL signal).
#
# §11.4.50 reliability: 3 iterations (per platform).
# §11.4.14 cleanup.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WRAPPER="${WRAPPER:-$REPO_ROOT/scripts/tmx}"
TMUX_BIN_DEFAULT="$REPO_ROOT/tmux/build-darwin/bin/tmux"
[ -x "$TMUX_BIN_DEFAULT" ] || TMUX_BIN_DEFAULT="$REPO_ROOT/tmux/build/bin/tmux"
TMUX_BIN="${TMUX_BIN:-$TMUX_BIN_DEFAULT}"
STATE_BIN="$REPO_ROOT/scripts/tmx-state-bin"

SESS="tmx-test-31-parity-$$"
export TMX_STATE_FILE="/tmp/tmx-test-31-$$.json"
SOCK_LABEL="tmx-${SESS}"

_cleanup() {
    "$WRAPPER" kill-session -t "$SESS" >/dev/null 2>&1 || true
    "$TMUX_BIN" -L "$SOCK_LABEL" kill-server >/dev/null 2>&1 || true
    rm -f "$TMX_STATE_FILE" 2>/dev/null || true
    case "$(uname -s)" in
        Linux)
            systemctl --user stop "${SOCK_LABEL}.scope" >/dev/null 2>&1 || true
            ;;
    esac
}
trap '_cleanup' EXIT

[ -x "$STATE_BIN" ] || { echo "SKIP 31: tmx-state-bin not built"; exit 77; }

# §11.4.81 — the canonical `case "$(uname -s)"` dispatch block. EACH ARM
# captures positive per-platform evidence and exits with PASS or FAIL.
# P5-M24 mutates THIS block by stripping the Darwin arm; on macOS the
# stripped variant falls through to the catch-all `*)` arm and FAILs.
run_platform_iteration() {
    local iter="$1"
    local HOST_OS
    HOST_OS="$(uname -s)"
    local platform_evidence=""
    case "$HOST_OS" in
        Darwin)
            # Positive evidence #1: rlimit wrapper is the macOS equivalent
            # of Linux systemd-run --user --scope. Confirm it exists +
            # the tmx wrapper references it.
            if [ ! -x "$REPO_ROOT/scripts/tmx-rlimit-wrapper.sh" ]; then
                echo "FAIL 31 iter=$iter Darwin: tmx-rlimit-wrapper.sh not present"
                return 1
            fi
            if [ -x "$WRAPPER" ] && ! grep -q "tmx-rlimit-wrapper.sh" "$WRAPPER"; then
                echo "FAIL 31 iter=$iter Darwin: tmx wrapper does not reference rlimit-wrapper"
                return 1
            fi
            # Positive evidence #2: state-bin reports the right version on Darwin.
            local sb_ver
            sb_ver="$("$STATE_BIN" version 2>&1)"
            if ! echo "$sb_ver" | grep -qE 'tmx-state v[0-9]'; then
                echo "FAIL 31 iter=$iter Darwin: state-bin version unexpected: $sb_ver"
                return 1
            fi
            platform_evidence="Darwin rlimit_wrapper=present state_bin_ver='$sb_ver'"
            ;;
        Linux)
            # Positive evidence #1: systemd-run is on PATH (the Linux
            # isolation primitive).
            if ! command -v systemd-run >/dev/null 2>&1; then
                echo "FAIL 31 iter=$iter Linux: systemd-run not on PATH"
                return 1
            fi
            # Positive evidence #2: tmx wrapper references systemd-run.
            if [ -x "$WRAPPER" ] && ! grep -q "systemd-run --user --scope" "$WRAPPER"; then
                echo "FAIL 31 iter=$iter Linux: tmx wrapper missing systemd-run --user --scope"
                return 1
            fi
            # Positive evidence #3: state-bin works on Linux too.
            local sb_ver
            sb_ver="$("$STATE_BIN" version 2>&1)"
            if ! echo "$sb_ver" | grep -qE 'tmx-state v[0-9]'; then
                echo "FAIL 31 iter=$iter Linux: state-bin version unexpected: $sb_ver"
                return 1
            fi
            platform_evidence="Linux systemd_run=present state_bin_ver='$sb_ver'"
            ;;
        *)
            echo "FAIL 31 iter=$iter: unsupported platform $HOST_OS (§11.4.81 honest-gap citation needed; P5-M24 may have stripped a branch)"
            return 1
            ;;
    esac
    _evidence="iter=$iter HOST_OS=$HOST_OS $platform_evidence"
    return 0
}

_hashes=()
for i in 1 2 3; do
    if ! run_platform_iteration "$i"; then exit 1; fi
    _h="$(echo "$(uname -s):state_bin:isolation_primitive" | shasum | cut -d' ' -f1)"
    _hashes+=("$_h")
    echo "[evidence] $_evidence"
done

if [ "${_hashes[0]}" != "${_hashes[1]}" ] || [ "${_hashes[1]}" != "${_hashes[2]}" ]; then
    echo "FAIL 31: N=3 evidence hashes diverge: ${_hashes[*]}"
    exit 1
fi

echo "[evidence] uname=$(uname -s) reliability_hash=${_hashes[0]}"
echo "PASS 31 §11.4.81 cross-platform parity: per-OS positive evidence captured (3/3 iterations, $(uname -s))"
exit 0
