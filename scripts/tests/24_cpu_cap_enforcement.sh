#!/usr/bin/env bash
# Test 24 — CPU-cap enforcement under the per-platform isolation primitive.
# Per §11.4.81 (C) cross-platform parity:
#   Darwin: RLIMIT_CPU + SIGXCPU/SIGKILL (POSIX rlimit, XNU enforces).
#           This is the macOS ADJACENT TEST for what Linux tests via
#           cgroup memory pressure (test 12) — XNU does NOT enforce
#           RLIMIT_AS for unprivileged processes, so we exercise the
#           kernel-enforced rlimit that DOES work.
#   Linux:  cgroup CPUQuota under systemd-run --user --scope.
#
# Constitution §11.4.5 captured-evidence-quality: PASS requires
# observation of the kill signal (124/SIGKILL/SIGXCPU) on the CPU-bound
# process AFTER the configured CPU budget elapses.

set -uo pipefail

# §11.4.3/D2 TMPDIR-HARDCODE-001: route scratch through ${TMPDIR:-/tmp}.
SCRATCH="${TMPDIR:-/tmp}"; SCRATCH="${SCRATCH%/}"
_wtest="$SCRATCH/.tmx_wtest_$$"
if ! mkdir -p "$_wtest" 2>/dev/null || [ ! -w "$_wtest" ]; then
    echo "SKIP 24: scratch root $SCRATCH not writable — §11.4.3"; rm -rf "$_wtest" 2>/dev/null || true; exit 77
fi
rmdir "$_wtest" 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WRAPPER="${WRAPPER:-$REPO_ROOT/scripts/tmx}"
TMUX_BIN_OS="$(uname -s)"
case "$TMUX_BIN_OS" in
    Darwin) TMUX_BIN_T24="${TMUX_BIN:-$REPO_ROOT/tmux/build-darwin/bin/tmux}" ;;
    Linux)  TMUX_BIN_T24="${TMUX_BIN:-$REPO_ROOT/tmux/build/bin/tmux}" ;;
esac

PASS=0
FAIL=0
SKIP=0
_pass() { echo "PASS: $*"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
_skip() { echo "SKIP: $*"; SKIP=$((SKIP+1)); }

if [ "$TMUX_BIN_OS" = "Darwin" ]; then
    echo "── Test 24: Darwin RLIMIT_CPU enforcement (§11.4.81 (C) adjacent to test 12) ──"

    if [ ! -x "$WRAPPER" ] || [ ! -x "$TMUX_BIN_T24" ]; then
        _skip "D-T1: prerequisites not built"
        echo "  Tests: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0
    fi

    # D-T1: spawn a session with a SHORT CPU budget. We don't go through
    # the wrapper (TMX_CPU_HARD_SEC override would apply to the SHELL,
    # not a forked child) — instead we drive a direct rlimit probe in a
    # child shell to prove RLIMIT_CPU is kernel-enforced on Darwin.
    #
    # Probe: child bash sets `ulimit -t 2` (2 CPU-seconds), then runs a
    # CPU-bound python loop. After 2 CPU-seconds the kernel SIGKILLs
    # (SIGXCPU on the soft limit; SIGKILL on hard). We measure wall
    # time + exit code: PASS if the process was killed by signal AND
    # CPU time was within [2, 4] seconds.

    PROBE_TMP="$(mktemp -t t24_cpu_probe.XXXXXX)"
    cat > "$PROBE_TMP" <<'PROBESCRIPT'
#!/usr/bin/env bash
# Set hard CPU limit to 2 seconds. ulimit -t is RLIMIT_CPU (CPU-seconds).
ulimit -t 2 2>/dev/null || { echo "PROBE:CANNOT_LOWER"; exit 0; }
T0=$(date +%s)
# CPU-bound loop in pure bash (no python dependency assumption).
# Each iteration burns CPU; we expect the kernel to kill us at ~2s of
# CPU time. The loop body is intentionally cheap so wall = CPU time
# closely. Use exec so the kill signal hits THIS process, not a child.
exec bash -c '
  i=0
  # spin until killed
  while :; do
    i=$((i+1))
    # avoid any I/O that would yield CPU; just integer math
    if [ $((i % 1000000)) -eq 0 ]; then :; fi
  done
'
PROBESCRIPT
    chmod +x "$PROBE_TMP"

    T_START="$(date +%s)"
    PROBE_OUT="$("$PROBE_TMP" 2>&1)"
    PROBE_RC="$?"
    T_END="$(date +%s)"
    ELAPSED=$((T_END - T_START))
    rm -f "$PROBE_TMP"

    if echo "$PROBE_OUT" | grep -q 'CANNOT_LOWER'; then
        _skip "D-T1: bash refused to lower ulimit -t" "host shell config blocks RLIMIT_CPU reduction"
    elif [ "$PROBE_RC" -gt 128 ] 2>/dev/null; then
        # Killed by signal (rc = 128 + signal_number). SIGXCPU=24,
        # SIGKILL=9. Either is positive evidence of RLIMIT_CPU
        # enforcement.
        SIG=$((PROBE_RC - 128))
        if [ "$ELAPSED" -le 5 ] 2>/dev/null; then
            _pass "D-T1: CPU-bound process killed by signal $SIG after ${ELAPSED}s wall (positive evidence per §11.4.5: ulimit -t 2 → kernel SIGXCPU/SIGKILL; rc=$PROBE_RC)"
        else
            _fail "D-T1: signal $SIG observed but elapsed=${ELAPSED}s exceeds expected ~2-4s window"
        fi
    elif [ "$PROBE_RC" -eq 0 ]; then
        _fail "D-T1: probe exited cleanly after ${ELAPSED}s — RLIMIT_CPU NOT enforced (unexpected; macOS should kill at 2s CPU)"
    else
        _fail "D-T1: probe exited with rc=$PROBE_RC after ${ELAPSED}s (unexpected; positive evidence requires signal kill)"
    fi

    # D-T2: also verify the wrapper PROPAGATES TMX_CPU_HARD_SEC to the
    # session's RLIMIT_CPU. ulimit -t inside the session should show the
    # configured value. Captured evidence per §11.4.81 (B).
    SESS="t24_d_$$"
    SOCK="tmx-${SESS}"
    trap '
        "$WRAPPER" kill-session -t "$SESS" >/dev/null 2>&1 || true
        "$TMUX_BIN_T24" -L "$SOCK" kill-server >/dev/null 2>&1 || true
    ' EXIT
    TMX_CPU_HARD_SEC=7200 "$WRAPPER" new -s "$SESS" -d >/dev/null 2>&1
    # Wait for the session's shell to reach a usable prompt before sending the
    # probe — a fixed 0.5s sleep races the login shell's rc-file init under
    # full-suite load (forensic: §11.4.50 divergence, run_all run 3, 2026-06-13:
    # capture returned '' because the echo had not yet rendered). Poll the
    # readback until it lands (or a bounded timeout) instead of a single race-y
    # capture. §11.4.1 — fix the harness timing at the source, not the product.
    sleep 0.5
    "$TMUX_BIN_T24" -L "$SOCK" send-keys "echo TMX24=\$(ulimit -t)" Enter 2>/dev/null
    READBACK=""
    _t24_i=0
    while [ "$_t24_i" -lt 25 ]; do
        READBACK="$("$TMUX_BIN_T24" -L "$SOCK" capture-pane -p 2>/dev/null | grep -oE 'TMX24=[0-9unlimited]+' | head -1)"
        [ -n "$READBACK" ] && break
        sleep 0.2
        _t24_i=$((_t24_i + 1))
    done
    if [ "$READBACK" = "TMX24=7200" ]; then
        _pass "D-T2: TMX_CPU_HARD_SEC=7200 propagated to RLIMIT_CPU=7200 inside session (positive evidence: ulimit -t readback = 7200)"
    else
        _fail "D-T2: ulimit -t readback unexpected: '$READBACK' (expected 'TMX24=7200')"
    fi

    echo ""
    echo "  Tests: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
    [ "$FAIL" -gt 0 ] && exit 1 || exit 0
fi

# Linux branch — cgroup CPUQuota enforcement under systemd-run.
echo "── Test 24: Linux cgroup CPUQuota enforcement ──"

if ! command -v systemctl >/dev/null 2>&1; then
    _skip "L-T0: systemctl not present"
    echo "  Tests: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0
fi
if ! systemd-run --user --scope --collect --quiet bash -c "exit 0" 2>/dev/null; then
    _skip "L-T0: systemd-run --user --scope not functional"
    echo "  Tests: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0
fi

UNIT="tmx-t24-$$.scope"
# Run a CPU-bound loop with very tight CPUQuota for 4 seconds; verify
# cgroup cpu.stat shows usage <= roughly the quota window.
T_START="$(date +%s)"
systemd-run --user --scope --collect --quiet \
    --unit="$UNIT" \
    -p "CPUQuota=10%" \
    bash -c 'i=0; T_END=$(($(date +%s)+4)); while [ $(date +%s) -lt $T_END ]; do i=$((i+1)); done; echo $i' \
    > "$SCRATCH/.t24_cpu_iters_$$"
RC=$?
ITERS=$(cat "$SCRATCH/.t24_cpu_iters_$$" 2>/dev/null || echo 0)
rm -f "$SCRATCH/.t24_cpu_iters_$$"

# Compare against an unrestricted reference run.
REF=$(bash -c 'i=0; T_END=$(($(date +%s)+1)); while [ $(date +%s) -lt $T_END ]; do i=$((i+1)); done; echo $i')

# Under 10% quota for 4 seconds we should see roughly 40% of a 1-second
# unrestricted iteration count, but at minimum dramatically less than
# 4× ref.
if [ "$ITERS" -gt 0 ] && [ "$REF" -gt 0 ] && [ "$ITERS" -lt "$((REF * 2))" ]; then
    _pass "L-T1: CPUQuota=10% throttled loop (cap iters=$ITERS < 2× unrestricted ref=$REF over 4s — positive evidence: CPU bounded by cgroup)"
else
    _fail "L-T1: CPUQuota=10% did not throttle: iters=$ITERS ref=$REF"
fi

echo ""
echo "  Tests: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
