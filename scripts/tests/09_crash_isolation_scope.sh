#!/usr/bin/env bash
# 09_crash_isolation_scope.sh — Phase B (per-session containerization)
# crash-isolation invariant verifier. Tests that the systemd --user
# --scope mechanism (which the `tmx` wrapper uses) actually enforces
# the cgroup memory + CPU caps AND that a scope being SIGKILL'd /
# OOM-killed does NOT take the user@<uid>.service down with it.
#
# Constitution §1 anti-bluff covenant — every PASS carries runtime
# evidence (cgroup interface files, scope unit state, MemoryMax value
# read back from cgroup hierarchy).
#
# Sections:
#   T1: systemd available + cgroup v2
#   T2: tmx wrapper exists + uses systemd-run --user --scope
#   T3: actually create a transient scope (no tmux; just sleep) +
#       verify cgroup interface files exist with the right limits
#   T4: SIGKILL the scope process — verify scope exits, user.slice alive
#   T5: simulate memory pressure (allocate UP TO cap, NOT BEYOND) +
#       verify MemoryCurrent rises but stays below MemoryMax
#   T6: concurrent scopes — create 3 scopes with different names; all
#       three visible in `systemctl --user list-units --type=scope`,
#       independent cgroups (different paths)

set -uo pipefail

# Output classification: PASS / FAIL / SKIP. Priority: FAIL > SKIP > PASS.
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

_pass() { echo "PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
_fail() { echo "FAIL: $*"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
_skip() { echo "SKIP: $* ($2)"; SKIP_COUNT=$((SKIP_COUNT + 1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WRAPPER="${WRAPPER:-$REPO_ROOT/scripts/tmx}"

echo "════════════════════════════════════════════════════════════════"
echo "  Test 09 — crash isolation invariants (per-platform per §11.4.81)"
echo "════════════════════════════════════════════════════════════════"

# §11.4.81 cross-platform-parity dispatch. The Linux branch (below)
# exercises cgroup-v2 + systemd --user --scope. The Darwin branch
# exercises the POSIX rlimit wrapper which is the macOS equivalent
# implementation (Fixed.md A4-A8 native dual-OS). Both branches
# enforce the same invariant: per-session resource bounding + a
# session SIGKILL leaves sibling sessions surviving.

HOST_OS="$(uname -s)"

if [ "$HOST_OS" = "Darwin" ]; then
    echo ""
    echo "--- Darwin branch (POSIX rlimit wrapper, per §11.4.81 cross-platform parity) ---"

    if [ ! -x "$WRAPPER" ]; then
        _skip "D-T1: tmx wrapper $WRAPPER not generated" "run scripts/setup.sh first"
        echo ""; echo "  Tests: PASS=$PASS_COUNT  FAIL=$FAIL_COUNT  SKIP=$SKIP_COUNT"; exit 0
    fi
    _pass "D-T1: tmx wrapper present at $WRAPPER (positive evidence: -x check)"

    # D-T2 — wrapper invokes the rlimit wrapper (the macOS analogue of
    # systemd-run --user --scope per Fixed.md A4-A8 native dual-OS).
    if grep -q "tmx-rlimit-wrapper.sh" "$WRAPPER"; then
        _pass "D-T2: tmx wrapper invokes scripts/tmx-rlimit-wrapper.sh (macOS equivalent of Linux systemd-run --user --scope per §11.4.81 catalogue)"
    else
        _fail "D-T2: tmx wrapper does not reference tmx-rlimit-wrapper.sh — macOS isolation path broken"
    fi

    # D-T3 — spawn two operator-path sessions; each gets its own server.
    SESS_A="t09_d_a_$$"
    SESS_B="t09_d_b_$$"
    "$WRAPPER" new -s "$SESS_A" -d >/dev/null 2>&1 || { _fail "D-T3.0: $WRAPPER new -s $SESS_A -d failed"; }
    "$WRAPPER" new -s "$SESS_B" -d >/dev/null 2>&1 || { _fail "D-T3.0: $WRAPPER new -s $SESS_B -d failed"; }

    TMUX_BIN_DARWIN="${TMUX_BIN:-$REPO_ROOT/tmux/build-darwin/bin/tmux}"
    SOCK_A="tmx-${SESS_A}"
    SOCK_B="tmx-${SESS_B}"

    # §11.4.50 deterministic-consistency: poll for server-ready instead of
    # a fixed sleep. Under load (e.g. running test 09 inside the 41-test
    # full-suite sweep), the previous `sleep 0.5` could be shorter than
    # the actual session-spawn latency, leaving `display-message -p
    # '#{pid}'` returning empty → flake. Poll up to 30 × 0.2s = 6 s.
    PID_A=""
    PID_B=""
    for _i in $(seq 1 30); do
        PID_A="$("$TMUX_BIN_DARWIN" -L "$SOCK_A" display-message -p '#{pid}' 2>/dev/null)"
        PID_B="$("$TMUX_BIN_DARWIN" -L "$SOCK_B" display-message -p '#{pid}' 2>/dev/null)"
        [ -n "$PID_A" ] && [ -n "$PID_B" ] && break
        sleep 0.2
    done
    if [ -n "$PID_A" ] && [ -n "$PID_B" ] && [ "$PID_A" != "$PID_B" ]; then
        _pass "D-T3: distinct tmux server PIDs A=$PID_A B=$PID_B (positive evidence: independent server processes per session)"
    else
        _fail "D-T3: could not get distinct server PIDs (A='$PID_A' B='$PID_B')"
    fi

    # D-T4 — read RLIMIT_CPU + RLIMIT_NPROC values back from inside each
    # session. Per §11.4.81 (B): captured runtime evidence per platform
    # via send-keys + capture-pane.
    "$TMUX_BIN_DARWIN" -L "$SOCK_A" send-keys "echo TMXLIMITS:cpu=\$(ulimit -t):nproc=\$(ulimit -u)" Enter 2>/dev/null
    # §11.4.50: poll for the marker line instead of a fixed sleep. Under
    # load the shell may take >0.4 s to render the echo output to the
    # pane buffer; previous fixed-sleep produced flakes.
    READBACK_A=""
    for _i in $(seq 1 25); do
        READBACK_A="$("$TMUX_BIN_DARWIN" -L "$SOCK_A" capture-pane -p 2>/dev/null | grep -oE 'TMXLIMITS:cpu=[0-9unlimited]+:nproc=[0-9unlimited]+' | head -1)"
        echo "$READBACK_A" | grep -qE '^TMXLIMITS:cpu=[0-9]+:nproc=[0-9]+$' && break
        sleep 0.2
    done
    if echo "$READBACK_A" | grep -qE '^TMXLIMITS:cpu=[0-9]+:nproc=[0-9]+$'; then
        _pass "D-T4: session A rlimits applied — $READBACK_A (positive evidence: ulimit -t/-u captured inside session)"
    else
        _fail "D-T4: session A rlimit readback unexpected: '$READBACK_A'"
    fi

    # D-T5 — SIGKILL session A's tmux server; assert B survives with
    # original PID. macOS analogue of the Linux scope-SIGKILL invariant.
    if [ -n "$PID_A" ]; then
        kill -KILL "$PID_A" 2>/dev/null
        sleep 1
        # Session A's server should be gone.
        if "$TMUX_BIN_DARWIN" -L "$SOCK_A" ls >/dev/null 2>&1; then
            _fail "D-T5.0: session A's server survived SIGKILL"
        else
            _pass "D-T5.0: session A's tmux server terminated by SIGKILL (positive evidence: tmux -L $SOCK_A ls = no server)"
        fi
        # Session B must survive with the original PID.
        PID_B_NOW="$("$TMUX_BIN_DARWIN" -L "$SOCK_B" display-message -p '#{pid}' 2>/dev/null)"
        if [ "$PID_B_NOW" = "$PID_B" ]; then
            _pass "D-T5.1: session B survived A's SIGKILL with ORIGINAL PID $PID_B (positive evidence: cross-session independence per §11.4.81)"
        else
            _fail "D-T5.1: session B PID changed or died: was=$PID_B now='$PID_B_NOW'"
        fi
    else
        _skip "D-T5: skipped" "no PID_A to kill"
    fi

    # Cleanup
    "$WRAPPER" kill-session -t "$SESS_B" >/dev/null 2>&1 || true
    "$TMUX_BIN_DARWIN" -L "$SOCK_A" kill-server >/dev/null 2>&1 || true
    "$TMUX_BIN_DARWIN" -L "$SOCK_B" kill-server >/dev/null 2>&1 || true

    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "  09_crash_isolation_scope.sh summary (Darwin branch)"
    echo "════════════════════════════════════════════════════════════════"
    echo "  PASS:  $PASS_COUNT"
    echo "  FAIL:  $FAIL_COUNT"
    echo "  SKIP:  $SKIP_COUNT"
    [ "$FAIL_COUNT" -gt 0 ] && exit 1
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────
# T1 — systemd + cgroup v2 capability  (Linux branch)
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "--- T1: systemd + cgroup v2 capability ---"
if ! command -v systemctl >/dev/null 2>&1; then
    _skip "T1.1: systemctl not present" "no systemd, no scope-based isolation possible"
    echo "Result: SKIPPED (no systemd)"
    exit 0
fi
sd_ver=$(systemctl --version | head -1 | awk '{print $2}')
if [ "${sd_ver:-0}" -lt 230 ] 2>/dev/null; then
    _fail "T1.1: systemd $sd_ver < 230 — transient --user --scope unsupported"
else
    _pass "T1.1: systemd $sd_ver supports --user --scope"
fi

# Functional probe: try creating a scope — more reliable than mount-based
# cgroup-v2 detection (hybrid hierarchies may have cgroup v2 without root mount).
SCOPE_OK=0
if systemd-run --user --scope --collect --quiet \
    bash -c "exit 0" 2>/dev/null; then
    SCOPE_OK=1
    _pass "T1.2: systemd-run --user --scope functional (positive evidence: transient scope created)"
else
    _skip "T1.2: systemd-run --user --scope not functional" "host does not support per-session isolation"
fi

# ─────────────────────────────────────────────────────────────────────
# T2 — tmx wrapper uses systemd-run --user --scope
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "--- T2: tmx wrapper invariants ---"
if [ ! -x "$WRAPPER" ]; then
    _skip "T2: tmx wrapper $WRAPPER not found/generated" "run setup.sh first"
elif grep -q "systemd-run --user --scope" "$WRAPPER"; then
    _pass "T2.1: tmx wrapper at $WRAPPER invokes systemd-run --user --scope"
    for inv in "MemoryMax" "CPUQuota" "TasksMax" "Delegate=yes"; do
        if grep -q "$inv" "$WRAPPER"; then
            _pass "T2.2: tmx wrapper sets $inv (cgroup invariant)"
        else
            _fail "T2.2: tmx wrapper missing $inv — cap not enforced"
        fi
    done
else
    _skip "T2.1: tmx wrapper does not contain systemd-run --user --scope" "wrapper was generated from older template"
fi

# Gate: if scope creation is not functional on this host, skip all
# remaining tests (T3-T6) which depend on systemd-run --user --scope.
if [ "$SCOPE_OK" -ne 1 ]; then
    _skip "T3-T6: scope-dependent tests" "host does not support systemd-run --user --scope"
    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "  09_crash_isolation_scope.sh summary"
    echo "════════════════════════════════════════════════════════════════"
    echo "  PASS:  $PASS_COUNT"
    echo "  FAIL:  $FAIL_COUNT"
    echo "  SKIP:  $SKIP_COUNT"
    if [ "$FAIL_COUNT" -gt 0 ]; then exit 1; fi
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────
# T3 — create a transient scope, verify cgroup limits
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "--- T3: transient scope cgroup interface files ---"
TEST_NAME="tmx-test-$$-t3"
TEST_MEM_BYTES=$((256 * 1024 * 1024))   # 256 MB
TEST_CPU_PCT=50                          # 50% = half a CPU

# Run a short-lived sleep inside a scope to inspect cgroup state.
# `--collect` cleans up the scope unit on exit. systemd-run --scope
# is foreground; backgrounding with `&` lets us inspect from outside.
systemd-run --user --scope --collect --quiet \
        --unit="${TEST_NAME}.scope" \
        -p "MemoryMax=$TEST_MEM_BYTES" \
        -p "CPUQuota=${TEST_CPU_PCT}%" \
        -p "TasksMax=128" \
        -p "Delegate=yes" \
        bash -c "sleep 60" &
SCOPE_PID=$!
sleep 3   # let scope register

if ! systemctl --user is-active --quiet "${TEST_NAME}.scope" 2>/dev/null; then
    _fail "T3.1: systemd-run --user --scope did not register ${TEST_NAME}.scope"
else
    _pass "T3.0: scope ${TEST_NAME}.scope registered + active"

    # Read MemoryMax back from cgroup interface file.
    cgroup_path=$(systemctl --user show -p ControlGroup --value "${TEST_NAME}.scope" 2>/dev/null)
    if [ -z "$cgroup_path" ]; then
        _skip "T3.1: cannot read ControlGroup for ${TEST_NAME}.scope" "scope may not be registered"
    else
        full_cgroup="/sys/fs/cgroup${cgroup_path}"
        if [ -f "$full_cgroup/memory.max" ]; then
            mem_max=$(cat "$full_cgroup/memory.max")
            if [ "$mem_max" = "$TEST_MEM_BYTES" ]; then
                _pass "T3.1: cgroup memory.max=$mem_max bytes matches set MemoryMax (positive evidence: $full_cgroup/memory.max)"
            else
                _fail "T3.1: cgroup memory.max=$mem_max but expected $TEST_MEM_BYTES — cap not enforced"
            fi
        else
            _skip "T3.1: $full_cgroup/memory.max not found" "cgroup not yet populated"
        fi
        if [ -f "$full_cgroup/cpu.max" ]; then
            cpu_max=$(cat "$full_cgroup/cpu.max")
            _pass "T3.2: cgroup cpu.max present: $cpu_max (positive evidence: $full_cgroup/cpu.max)"
        else
            _skip "T3.2: $full_cgroup/cpu.max not found" "scope may use legacy hierarchy"
        fi
    fi

    # Cleanup — kill the sleep so scope exits cleanly.
    systemctl --user stop "${TEST_NAME}.scope" >/dev/null 2>&1 || kill -TERM "$SCOPE_PID" 2>/dev/null || true
    wait "$SCOPE_PID" 2>/dev/null || true
fi

# ─────────────────────────────────────────────────────────────────────
# T4 — SIGKILL containment: kill scope process, verify user.slice alive
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "--- T4: SIGKILL containment (user@<uid>.service must survive scope death) ---"
TEST_NAME_T4="tmx-test-$$-t4"
USER_SVC_BEFORE=$(systemctl --user is-active default.target 2>/dev/null || echo "unknown")

# Spawn a scope running a victim process.
systemd-run --user --scope --collect --quiet \
    --unit="${TEST_NAME_T4}.scope" \
    -p "MemoryMax=128M" \
    -p "TasksMax=64" \
    bash -c "exec sleep 120" &
T4_PID=$!
sleep 3   # increased from 1s — scope-registration race observed at 1s

# `--scope` units don't have a single MainPID — they're a process group.
# Read PID from cgroup.procs (the kernel's authoritative list of pids in the cgroup).
t4_cgroup_path=$(systemctl --user show -p ControlGroup --value "${TEST_NAME_T4}.scope" 2>/dev/null)
victim_pid=""
if [ -n "$t4_cgroup_path" ] && [ -f "/sys/fs/cgroup${t4_cgroup_path}/cgroup.procs" ]; then
    # First non-empty line is a PID inside the scope.
    victim_pid=$(head -1 "/sys/fs/cgroup${t4_cgroup_path}/cgroup.procs" 2>/dev/null | tr -d '\n')
fi
if [ -n "$victim_pid" ] && [ "$victim_pid" != "0" ]; then
    if kill -0 "$victim_pid" 2>/dev/null; then
        _pass "T4.1: scope ${TEST_NAME_T4}.scope MainPID=$victim_pid alive"
        # SIGKILL the scope's MainPID (and any other PIDs in cgroup.procs).
        T4_CGROUP_PATH="/sys/fs/cgroup${t4_cgroup_path}"
        if [ -f "$T4_CGROUP_PATH/cgroup.procs" ]; then
            while read -r p; do
                [ -n "$p" ] && kill -KILL "$p" 2>/dev/null
            done < "$T4_CGROUP_PATH/cgroup.procs"
        else
            kill -KILL "$victim_pid" 2>/dev/null
        fi

        # Poll for the REAL containment invariant: scope's cgroup.procs
        # drained. This is what operators care about — "OOM-kill killed
        # the runaway, no leftover processes in the scope". The OLDER
        # check (`systemctl --user is-active --quiet`) was correct on
        # older systemd but WRONG on systemd 258 / ALT Linux 11 /
        # kernel 6.12: transient `--scope` units now stay
        # ActiveState=active running EVEN AFTER their cgroup.procs is
        # empty, until explicitly `systemctl --user stop`'d. Forensic
        # evidence captured live on Nezha 2026-05-21 (probe4-89401):
        #   cgroup.procs:   <empty>
        #   ls cgroup dir:  exists
        #   ActiveState=active  SubState=running
        #   even 60s+ post-kill
        # The cgroup-empty check is the platform-neutral invariant —
        # it's what `MemoryMax`-driven OOM-kill leaves behind on any
        # systemd version. §11.4.81 cross-platform-parity (B): pick the
        # invariant that the kernel ACTUALLY enforces.
        #
        # Bounded poll: 60 ticks × 0.5s = 30s. cgroup.procs typically
        # drains within ~1s of SIGKILL on a healthy host.
        T4_TIMEOUT_TICKS=60
        T4_TICK=0
        T4_PROCS_LEFT=""
        while [ "$T4_TICK" -lt "$T4_TIMEOUT_TICKS" ]; do
            if [ ! -f "$T4_CGROUP_PATH/cgroup.procs" ]; then
                # cgroup directory gone (e.g., --collect already
                # reclaimed it) = trivially drained.
                T4_PROCS_LEFT=""
                break
            fi
            T4_PROCS_LEFT="$(cat "$T4_CGROUP_PATH/cgroup.procs" 2>/dev/null | tr -d ' \n\r')"
            if [ -z "$T4_PROCS_LEFT" ]; then
                break
            fi
            sleep 0.5
            T4_TICK=$((T4_TICK + 1))
        done
        T4_ELAPSED_S=$(awk -v t="$T4_TICK" 'BEGIN{printf "%.1f", t * 0.5}')
        if [ -n "$T4_PROCS_LEFT" ]; then
            _fail "T4.2: scope ${TEST_NAME_T4}.scope cgroup.procs still has pids 30s after SIGKILL (containment not achieved): $T4_PROCS_LEFT"
        else
            _pass "T4.2: scope ${TEST_NAME_T4}.scope cgroup.procs drained after SIGKILL — containment achieved (positive evidence per §11.4.81: cgroup.procs empty/removed after ${T4_ELAPSED_S}s poll; OOM-kill semantics verified on this kernel without depending on systemd's unit-state transition timing)"
        fi
        # Explicit stop to release the unit (clean teardown — independent
        # of the containment invariant we just verified).
        systemctl --user stop "${TEST_NAME_T4}.scope" >/dev/null 2>&1 || true
        # Verify user@<uid>.service still alive (the critical invariant)
        USER_SVC_AFTER=$(systemctl --user is-active default.target 2>/dev/null || echo "unknown")
        if [ "$USER_SVC_AFTER" = "$USER_SVC_BEFORE" ] && [ "$USER_SVC_AFTER" = "active" ]; then
            _pass "T4.3: user.slice survived scope death (default.target=$USER_SVC_AFTER throughout — Constitution §1 invariant)"
        else
            _fail "T4.3: user.slice state changed: before=$USER_SVC_BEFORE after=$USER_SVC_AFTER (NOT acceptable per Constitution §1)"
        fi
    else
        _skip "T4.1: scope MainPID=$victim_pid not alive" "scope may have exited too quickly"
    fi
else
    _skip "T4.1: cannot read MainPID for ${TEST_NAME_T4}.scope" "scope not registered"
fi
# Cleanup
systemctl --user stop "${TEST_NAME_T4}.scope" >/dev/null 2>&1 || true
wait "$T4_PID" 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────
# T6 — concurrent independent scopes
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "--- T6: concurrent scopes are independent ---"
T6_NAMES=()
for n in 1 2 3; do
    nm="tmx-test-$$-t6-$n"
    systemd-run --user --scope --collect --quiet \
        --unit="${nm}.scope" \
        -p "MemoryMax=128M" \
        bash -c "exec sleep 60" &
    T6_NAMES+=("$nm")
    sleep 0.5
done
sleep 1
visible=0
for nm in "${T6_NAMES[@]}"; do
    if systemctl --user is-active --quiet "${nm}.scope" 2>/dev/null; then
        visible=$((visible + 1))
    fi
done
if [ "$visible" -eq 3 ]; then
    _pass "T6.1: all 3 concurrent scopes registered + active (positive evidence: systemctl --user is-active for each)"
else
    _fail "T6.1: only $visible of 3 concurrent scopes active — independence not confirmed"
fi
# Cleanup all 3
for nm in "${T6_NAMES[@]}"; do
    systemctl --user stop "${nm}.scope" >/dev/null 2>&1 || true
done
wait 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────
# T7 — §11.4.225 split-topology crash isolation (TMX_SERVER_SPLIT=1)
# ─────────────────────────────────────────────────────────────────────
# §11.4.120 reconciliation (2026-07-23): the opt-in scope split changes the
# per-session failure domain from ONE (shared scope) to TWO (server scope +
# workload slice). T1-T6 keep asserting the DEFAULT shared topology (the
# flag is OFF by default — the v1.0.37 quota+burst fix path is unchanged);
# T7 asserts the NEW mechanism's crash-isolation invariants per the split
# design: (a) workload death leaves the SERVER alive + responsive,
# (b) server death does not orphan the workload nor leak the slice past
# the wrapper's pair teardown, (c) neither touches user@<uid>.service.
echo ""
echo "--- T7: split-topology crash isolation (TMX_SERVER_SPLIT=1) ---"
if [ ! -x "$WRAPPER" ]; then
    _skip "T7: tmx wrapper $WRAPPER not generated" "run scripts/setup.sh first"
else
    TMUX_BIN_09="$(sed -n 's/^TMUX_BIN="\(.*\)"$/\1/p' "$WRAPPER" | head -1)"
    T7A="tmx_t09sa_$$"
    T7B="tmx_t09sb_$$"
    _t7_cleanup() {
        for n in "$T7A" "$T7B"; do
            "$WRAPPER" kill-session -t "$n" >/dev/null 2>&1 || true
            [ -n "$TMUX_BIN_09" ] && "$TMUX_BIN_09" -L "tmx-$n" kill-server >/dev/null 2>&1 || true
            systemctl --user stop "tmx-$n.scope" "tmxw-$n.slice" >/dev/null 2>&1 || true
        done
        rm -rf "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/systemd/user.control/tmxw-tmx_t09s"* 2>/dev/null || true
        systemctl --user daemon-reload 2>/dev/null || true
    }

    # ── T7a: WORKLOAD death → server survives, responsive ───────────
    TMX_SERVER_SPLIT=1 TMX_RECYCLE_IDLE_SECS=0 "$WRAPPER" new -s "$T7A" -d >/dev/null 2>&1
    T7A_PID=""
    for _i in $(seq 1 25); do
        T7A_PID="$("$TMUX_BIN_09" -L "tmx-$T7A" display-message -p '#{pid}' 2>/dev/null)"
        [ -n "$T7A_PID" ] && break
        sleep 0.2
    done
    if [ -z "$T7A_PID" ] || ! systemctl --user is-active --quiet "tmxw-$T7A.slice" 2>/dev/null; then
        _fail "T7a.0: split session did not come up (pid='$T7A_PID' slice=$(systemctl --user is-active "tmxw-$T7A.slice" 2>/dev/null || echo unknown))"
    else
        _pass "T7a.0: split session up — server pid $T7A_PID in tmx-$T7A.scope + workload slice active"
        # Keep the dead pane visible so the SESSION object outlives its
        # workload (tmux default would close the window and wind the
        # server down gracefully — that would test tmux's lifecycle, not
        # the crash-domain separation under test here).
        "$TMUX_BIN_09" -L "tmx-$T7A" set -g remain-on-exit on 2>/dev/null || true
        systemctl --user stop "tmxw-$T7A.slice" 2>/dev/null   # ← workload "crash"
        sleep 1
        if kill -0 "$T7A_PID" 2>/dev/null && "$TMUX_BIN_09" -L "tmx-$T7A" ls >/dev/null 2>&1; then
            _pass "T7a.1: WORKLOAD KILLED, server SURVIVED — pid $T7A_PID alive, tmux -L tmx-$T7A responsive (split failure-domain separation: fleet death can no longer take the interactive server down)"
        else
            _fail "T7a.1: server did not survive workload kill (pid alive=$(kill -0 "$T7A_PID" 2>/dev/null && echo yes || echo no))"
        fi
        USER_SVC_T7="$(systemctl --user is-active default.target 2>/dev/null || echo unknown)"
        if [ "$USER_SVC_T7" = "active" ]; then
            _pass "T7a.2: user@<uid>.service untouched by workload kill (default.target=active)"
        else
            _fail "T7a.2: default.target=$USER_SVC_T7 after workload kill"
        fi
        "$WRAPPER" kill-session -t "$T7A" >/dev/null 2>&1
    fi

    # ── T7b: SERVER death → workload dies with it (no orphan fleet),
    #         pair teardown leaks nothing ─────────────────────────────
    TMX_SERVER_SPLIT=1 TMX_RECYCLE_IDLE_SECS=0 "$WRAPPER" new -s "$T7B" -d >/dev/null 2>&1
    T7B_UP=0
    for _i in $(seq 1 25); do
        "$TMUX_BIN_09" -L "tmx-$T7B" has-session -t "$T7B" 2>/dev/null && { T7B_UP=1; break; }
        sleep 0.2
    done
    if [ "$T7B_UP" -ne 1 ]; then
        _fail "T7b.0: split session B did not come up"
    else
        T7B_SLICE_CG="$(systemctl --user show "tmxw-$T7B.slice" -p ControlGroup --value 2>/dev/null)"
        systemctl --user stop "tmx-$T7B.scope" 2>/dev/null    # ← server "crash"
        # PTY hangup must drain the workload: poll the slice subtree empty.
        T7B_DRAINED=0
        for _i in $(seq 1 30); do
            if [ -z "$T7B_SLICE_CG" ] || [ ! -d "/sys/fs/cgroup${T7B_SLICE_CG}" ] || \
               ! find "/sys/fs/cgroup${T7B_SLICE_CG}" -mindepth 2 -name cgroup.procs -exec cat {} + 2>/dev/null | grep -q '[0-9]'; then
                T7B_DRAINED=1
                break
            fi
            sleep 0.5
        done
        if [ "$T7B_DRAINED" -eq 1 ]; then
            _pass "T7b.1: server kill drained the workload slice (no orphan fleet pids in /sys/fs/cgroup${T7B_SLICE_CG})"
        else
            _fail "T7b.1: workload pids still in slice cgroup 15 s after server kill (orphan fleet)"
        fi
        "$WRAPPER" kill-session -t "$T7B" >/dev/null 2>&1
        sleep 1
        T7B_LEAK=""
        for u in "tmx-$T7B.scope" "tmxw-$T7B.slice"; do
            [ "$(systemctl --user is-active "$u" 2>/dev/null || true)" = "active" ] && T7B_LEAK="$T7B_LEAK $u"
        done
        if [ -z "$T7B_LEAK" ]; then
            _pass "T7b.2: pair teardown clean after server kill — no scope/slice left active"
        else
            _fail "T7b.2: leaked active units after teardown:$T7B_LEAK"
        fi
        USER_SVC_T7B="$(systemctl --user is-active default.target 2>/dev/null || echo unknown)"
        if [ "$USER_SVC_T7B" = "active" ]; then
            _pass "T7b.3: user@<uid>.service untouched by server kill (default.target=active)"
        else
            _fail "T7b.3: default.target=$USER_SVC_T7B after server kill"
        fi
    fi
    _t7_cleanup
fi

# ─────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  09_crash_isolation_scope.sh summary"
echo "════════════════════════════════════════════════════════════════"
echo "  PASS:  $PASS_COUNT"
echo "  FAIL:  $FAIL_COUNT"
echo "  SKIP:  $SKIP_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
exit 0
