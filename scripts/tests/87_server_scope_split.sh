#!/usr/bin/env bash
# Test 87 — Interactive tmux-server scope split (§11.4.115 RED/GREEN polarity,
# §11.4.225 throttle telemetry).
#
# Defect class (forensic anchors HEL-006 + HEL-003, 2026-07-22/23): in the
# shared-scope topology the tmux SERVER lives in the SAME cgroup as the whole
# workload fleet it renders. When the fleet exhausts the CFS quota inside a
# 100 ms period, EVERY task in the cgroup — including the server's
# keystroke/echo/timer handling — freezes for the period remainder. Live
# measurements: 16.9% of periods throttled at avg demand 4.35 CPU vs 9.6
# quota (pre-burst); RED repro 22.9-27.6 s exit-to-prompt stretch at 48-worker
# scale. The v1.0.37 quota+burst fix removes the SYMPTOM at tested scale; the
# TMX_SERVER_SPLIT=1 topology removes the MECHANISM for the server-side
# component: the server gets its OWN scope + quota, the fleet runs in per-pane
# scopes under a dedicated workload slice (tmxw-<name>.slice), so fleet
# throttling can never suspend the server.
#
# Polarity (§11.4.115 — ONE source, TWO roles):
#   RED_MODE=1  reproduce-and-assert-DEFECT-PRESENT on the SHARED topology
#               (TMX_SERVER_SPLIT unset/0): under a deterministic fleet load
#               the SERVER's own cgroup accumulates throttled periods
#               (nr_throttled delta > 0 read from cpu.stat — §11.4.201
#               authoritative source). Exit 0 iff the co-throttling is there.
#   RED_MODE=0  (default) regression GUARD on the SPLIT topology
#               (TMX_SERVER_SPLIT=1): server scope + workload slice both live
#               with the artifact-derived quota split; under the SAME fleet
#               load the SLICE throttles (>0 — the load-was-real control
#               needle, §11.4.201(7)(b)) while the SERVER scope stays at
#               EXACTLY 0 throttled periods; quiet-phase control precedes the
#               load window (§11.4.225 — deltas under load + quiet control,
#               never averages); burst banks + pair teardown verified.
#
# Env:
#   T87_TARGET  wrapper source for function extraction
#               (default $REPO_ROOT/scripts/tmx.template)
#   WRAPPER     executable wrapper for live subtests (default scripts/tmx)
#   RED_MODE    see above.

set -uo pipefail

RED_MODE="${RED_MODE:-0}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET="${T87_TARGET:-$REPO_ROOT/scripts/tmx.template}"
WRAPPER="${WRAPPER:-$REPO_ROOT/scripts/tmx}"

PASS=0; FAIL=0; SKIP=0
_pass() { echo "PASS: $*"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
_skip() { echo "SKIP: $*"; SKIP=$((SKIP+1)); }

echo "── Test 87: interactive-server scope split (RED_MODE=$RED_MODE) ──"
echo "  target: $TARGET"

# ── topology gates (honest SKIPs, §11.4.3) ─────────────────────────────
if [ "$(uname -s)" != "Linux" ]; then
    _skip "Linux-only (cgroup-v2 scope/slice split; Darwin isolation is rlimit-based — tests 09/15/24)"
    echo "  Tests: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0
fi
if [ ! -x "$WRAPPER" ]; then
    _skip "wrapper $WRAPPER not generated — run scripts/setup.sh first"
    echo "  Tests: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0
fi
if ! systemd-run --user --scope --collect --quiet bash -c "exit 0" 2>/dev/null; then
    _skip "systemd-run --user --scope not functional on this host"
    echo "  Tests: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0
fi
[ -r "$TARGET" ] || { echo "FAIL: target $TARGET not readable"; exit 1; }

TMUX_BIN_T87="$(sed -n 's/^TMUX_BIN="\(.*\)"$/\1/p' "$WRAPPER" | head -1)"

# ── helpers ────────────────────────────────────────────────────────────
_cg_of_pid()  { sed -n 's/^0:://p' "/proc/$1/cgroup" 2>/dev/null; }
_throttled()  { awk '/^nr_throttled/ {print $2}' "/sys/fs/cgroup$1/cpu.stat" 2>/dev/null || echo ""; }
_cg_of_unit() { systemctl --user show "$1" -p ControlGroup --value 2>/dev/null; }
# Any live pid in a unit's cgroup SUBTREE (slice members live in child scopes).
_subtree_has_pid() {
    find "/sys/fs/cgroup$1" -mindepth 2 -name cgroup.procs -exec cat {} + 2>/dev/null | grep -q '[0-9]'
}
# Deterministic fleet: 8 spinners x ~8 s inside the given session's pane 1 —
# demand ~8 CPUs against a <=1-CPU budget => guaranteed CFS throttling.
_start_fleet() {
    "$TMUX_BIN_T87" -L "tmx-$1" send-keys -t "$1" \
        'for i in 1 2 3 4 5 6 7 8; do ( _e=$((SECONDS+8)); while [ $SECONDS -lt $_e ]; do :; done ) & done' Enter 2>/dev/null
}
# Quiet-phase settle (§11.4.225 quiet control without racing shell startup):
# the pane's login shell may still be sourcing rc files right after create
# and can itself throttle against the small test quota. Sample 1 s
# nr_throttled deltas on the given cgroups until ONE window is 0 on ALL of
# them (bounded, <=12 s). Prints the settled verdict: "settled" or the last
# non-zero deltas.
_quiet_settle() {
    local tries=0 all_zero cg d0 d1 out=""
    while [ "$tries" -lt 12 ]; do
        all_zero=1; out=""
        declare -A _q0=()
        for cg in "$@"; do _q0["$cg"]="$(_throttled "$cg")"; done
        sleep 1
        for cg in "$@"; do
            d0="${_q0["$cg"]}"; d1="$(_throttled "$cg")"
            if [ -z "$d0" ] || [ -z "$d1" ] || [ "$((d1 - d0))" -ne 0 ]; then
                all_zero=0; out="$out $cg:delta=$(( ${d1:-0} - ${d0:-0} ))"
            fi
        done
        if [ "$all_zero" -eq 1 ]; then printf 'settled'; return 0; fi
        tries=$((tries + 1))
    done
    printf 'never-settled:%s' "$out"
    return 1
}

SESS="t87_$$"
SESS2="t87b_$$"
SESS3="t87-x-$$"          # dash case: proves the \x2d slice-name escaping live
SLICE_ESC3="tmxw-t87\\x2dx\\x2d$$.slice"

_cleanup() {
    for s in "$SESS" "$SESS2" "$SESS3"; do
        "$WRAPPER" kill-session -t "$s" >/dev/null 2>&1 || true
        [ -n "${TMUX_BIN_T87:-}" ] && "$TMUX_BIN_T87" -L "tmx-$s" kill-server >/dev/null 2>&1 || true
        systemctl --user stop "tmx-$s.scope" >/dev/null 2>&1 || true
        systemctl --user stop "tmxw-$s.slice" >/dev/null 2>&1 || true
    done
    systemctl --user stop "$SLICE_ESC3" >/dev/null 2>&1 || true
    rm -rf "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/systemd/user.control/tmxw-t87"* 2>/dev/null || true
    systemctl --user daemon-reload 2>/dev/null || true
}
trap _cleanup EXIT

# ── artifact-derived expectations (§11.4.6 — run the artifact's own
# functions, never re-derive constants) ────────────────────────────────
_fn_srv="$(sed -n '/^_srv_cpu_pct()/,/^}/p' "$TARGET")"
_fn_split="$(sed -n '/^_split_cpu_pcts()/,/^}/p' "$TARGET")"
_fn_total="$(sed -n '/^_default_cpu_pct()/,/^}/p' "$TARGET")"
_split_for() {  # _split_for <total_pct> → "<srv> <workload>" per the artifact
    bash -c "HOST_OS=Linux; $_fn_srv
$_fn_split
_split_cpu_pcts $1" 2>/dev/null
}

if [ "$RED_MODE" = "1" ]; then
    # ═════ RED: defect-present on the SHARED topology ═════
    # TMX_CPU=100 (1 CPU total) + burst disabled => throttling deterministic.
    TMX_SERVER_SPLIT=0 TMX_CPU=100 TMX_CPU_BURST=0 TMX_RECYCLE_IDLE_SECS=0 \
        "$WRAPPER" new -s "$SESS" -d >/dev/null 2>&1
    sleep 1
    SRV_PID="$("$TMUX_BIN_T87" -L "tmx-$SESS" display-message -p '#{pid}' 2>/dev/null)"
    if [ -z "$SRV_PID" ]; then
        _fail "RED: session did not come up (no server pid)"
    else
        SRV_CG="$(_cg_of_pid "$SRV_PID")"
        case "$SRV_CG" in
            */tmx-"$SESS".scope*)
                _pass "RED-R1: shared topology confirmed — server pid $SRV_PID cgroup $SRV_CG is the session scope (server co-resident with workload)" ;;
            *)  _fail "RED-R1: server cgroup '$SRV_CG' is not the shared session scope" ;;
        esac
        # quiet-phase control (§11.4.225): a zero-throttle idle window exists
        # before the load (settle past shell-startup noise, bounded).
        QV="$(_quiet_settle "$SRV_CG")"
        if [ "$QV" = "settled" ]; then
            _pass "RED-R2: quiet-phase control clean (a 1 s idle window with nr_throttled delta 0 observed)"
        else
            _fail "RED-R2: quiet-phase never settled ($QV)"
        fi
        _start_fleet "$SESS"
        sleep 1
        t0="$(_throttled "$SRV_CG")"; sleep 3; t1="$(_throttled "$SRV_CG")"
        if [ -n "$t0" ] && [ -n "$t1" ] && [ "$((t1 - t0))" -gt 0 ]; then
            _pass "RED-R3: defect reproduced — SERVER's cgroup co-throttled with the fleet: nr_throttled delta=$((t1 - t0)) periods in 3 s (server frozen for each throttled period's remainder)"
        else
            _fail "RED-R3: defect NOT present — server cgroup nr_throttled delta=$(( ${t1:-0} - ${t0:-0} )) under fleet load (t0='$t0' t1='$t1')"
        fi
    fi
    echo "  Tests: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
    [ "$FAIL" -gt 0 ] && exit 1 || exit 0
fi

# ═════ GUARD: split topology delivers server isolation ═════
SCOPE_UNIT="tmx-$SESS.scope"
SLICE_UNIT="tmxw-$SESS.slice"

# G0: artifact carries the split functions (cheap structural gate first).
if [ -n "$_fn_srv" ] && [ -n "$_fn_split" ]; then
    _pass "G0: _srv_cpu_pct + _split_cpu_pcts present in $TARGET"
else
    _fail "G0: split functions missing from $TARGET (srv=${_fn_srv:+yes}${_fn_srv:-no} split=${_fn_split:+yes}${_fn_split:-no})"
fi

TMX_SERVER_SPLIT=1 TMX_CPU=100 TMX_CPU_BURST=0 TMX_RECYCLE_IDLE_SECS=0 \
    "$WRAPPER" new -s "$SESS" -d >/dev/null 2>&1
sleep 1

# G1: both units live; server pid's cgroup (kernel-authoritative, /proc) is
# the srv scope and NOT the slice.
SRV_PID="$("$TMUX_BIN_T87" -L "tmx-$SESS" display-message -p '#{pid}' 2>/dev/null)"
SRV_CG="${SRV_PID:+$(_cg_of_pid "$SRV_PID")}"
SCOPE_ACTIVE="$(systemctl --user is-active "$SCOPE_UNIT" 2>/dev/null || true)"
SLICE_ACTIVE="$(systemctl --user is-active "$SLICE_UNIT" 2>/dev/null || true)"
if [ "$SCOPE_ACTIVE" = "active" ] && [ "$SLICE_ACTIVE" = "active" ] && \
   [ -n "$SRV_CG" ] && case "$SRV_CG" in */"$SCOPE_UNIT"*) true ;; *) false ;; esac && \
   case "$SRV_CG" in */tmxw-*) false ;; *) true ;; esac; then
    _pass "G1: srv scope + workload slice both active; server pid $SRV_PID cgroup $SRV_CG is the srv scope (not the slice)"
else
    _fail "G1: split topology absent (scope=$SCOPE_ACTIVE slice=$SLICE_ACTIVE srv_cg='$SRV_CG')"
fi

# G2: the pane shell landed INSIDE the slice subtree (fail-closed placement).
SLICE_CG="$(_cg_of_unit "$SLICE_UNIT")"
if [ -n "$SLICE_CG" ] && _subtree_has_pid "$SLICE_CG"; then
    _pass "G2: workload slice subtree holds a live pane pid (positive evidence: cgroup.procs under /sys/fs/cgroup$SLICE_CG)"
else
    _fail "G2: no live pid under slice cgroup '$SLICE_CG' — pane not placed in the workload slice"
fi

# G3: quota split read-backs equal the artifact's own split of 100%.
EXP_SPLIT="$(_split_for 100)"
EXP_SRV="${EXP_SPLIT%% *}"; EXP_WORK="${EXP_SPLIT##* }"
SCOPE_CG="$(_cg_of_unit "$SCOPE_UNIT")"
SRV_QUOTA="$(cut -d' ' -f1 "/sys/fs/cgroup${SCOPE_CG}/cpu.max" 2>/dev/null || true)"
WORK_QUOTA="$(cut -d' ' -f1 "/sys/fs/cgroup${SLICE_CG}/cpu.max" 2>/dev/null || true)"
if [ -n "$EXP_SRV" ] && [ "$SRV_QUOTA" = "$(( EXP_SRV * 1000 ))" ] && [ "$WORK_QUOTA" = "$(( EXP_WORK * 1000 ))" ]; then
    _pass "G3: live quota split — srv cpu.max=$SRV_QUOTA slice cpu.max=$WORK_QUOTA == artifact split ${EXP_SRV}%/${EXP_WORK}% of TMX_CPU=100 (srv+workload == total, §12.6 budget preserved)"
else
    _fail "G3: quota split wrong — srv='$SRV_QUOTA' slice='$WORK_QUOTA' expected $(( ${EXP_SRV:-0} * 1000 ))/$(( ${EXP_WORK:-0} * 1000 )) (artifact split '$EXP_SPLIT')"
fi

# G4: quiet-phase control — a zero-throttle idle window on BOTH units
# before load (settle past shell-startup noise, bounded).
QV="$(_quiet_settle "$SCOPE_CG" "$SLICE_CG")"
if [ "$QV" = "settled" ]; then
    _pass "G4: quiet-phase control clean (a 1 s idle window with delta 0 on srv scope AND slice)"
else
    _fail "G4: quiet-phase never settled ($QV)"
fi

# G5: THE isolation invariant (§11.4.225): under fleet load the slice
# throttles (load-was-real needle) while the srv scope stays at exactly 0.
_start_fleet "$SESS"
sleep 1
st0="$(_throttled "$SCOPE_CG")"; wt0="$(_throttled "$SLICE_CG")"
sleep 3
st1="$(_throttled "$SCOPE_CG")"; wt1="$(_throttled "$SLICE_CG")"
W_DELTA=$(( ${wt1:-0} - ${wt0:-0} ))
S_DELTA=$(( ${st1:-0} - ${st0:-0} ))
if [ "$W_DELTA" -gt 0 ] && [ "$S_DELTA" -eq 0 ]; then
    _pass "G5: isolation proven — slice nr_throttled delta=$W_DELTA (fleet really throttled against its own quota) while srv scope delta=0 (server NEVER co-throttled; §11.4.225 deltas-under-load + control needle)"
elif [ "$W_DELTA" -le 0 ]; then
    _fail "G5: load needle dead — slice nr_throttled delta=$W_DELTA (fleet did not throttle; measurement proves nothing)"
else
    _fail "G5: server co-throttled DESPITE split — srv scope delta=$S_DELTA (slice delta=$W_DELTA)"
fi

# teardown of the load session; G7 asserts the PAIR is gone.
"$WRAPPER" kill-session -t "$SESS" >/dev/null 2>&1

# G6: burst banks on BOTH units under default env (auto burst == own quota).
TMX_SERVER_SPLIT=1 TMX_RECYCLE_IDLE_SECS=0 "$WRAPPER" new -s "$SESS2" -d >/dev/null 2>&1
sleep 1
SCOPE_CG2="$(_cg_of_unit "tmx-$SESS2.scope")"
SLICE_CG2="$(_cg_of_unit "tmxw-$SESS2.slice")"
TOTAL_DEF="$(bash -c "HOST_OS=Linux; $_fn_total; _default_cpu_pct" 2>/dev/null)"
EXP_SPLIT2="$(_split_for "$TOTAL_DEF")"
EXP_SRV2="${EXP_SPLIT2%% *}"; EXP_WORK2="${EXP_SPLIT2##* }"
if [ ! -f "/sys/fs/cgroup${SCOPE_CG2}/cpu.max.burst" ]; then
    _skip "G6: kernel exposes no cpu.max.burst — burst not applicable on this host"
else
    SRV_BURST="$(cat "/sys/fs/cgroup${SCOPE_CG2}/cpu.max.burst" 2>/dev/null || true)"
    WORK_BURST="$(cat "/sys/fs/cgroup${SLICE_CG2}/cpu.max.burst" 2>/dev/null || true)"
    if [ "$SRV_BURST" = "$(( EXP_SRV2 * 1000 ))" ] && [ "$WORK_BURST" = "$(( EXP_WORK2 * 1000 ))" ]; then
        _pass "G6: burst banks live — srv cpu.max.burst=$SRV_BURST slice cpu.max.burst=$WORK_BURST == own quotas (${EXP_SRV2}%/${EXP_WORK2}% of adaptive ${TOTAL_DEF}%)"
    else
        _fail "G6: burst wrong — srv='$SRV_BURST' (want $(( ${EXP_SRV2:-0} * 1000 ))) slice='$WORK_BURST' (want $(( ${EXP_WORK2:-0} * 1000 )))"
    fi
fi
"$WRAPPER" kill-session -t "$SESS2" >/dev/null 2>&1
sleep 1

# G7: pair teardown — kill-session left NEITHER unit active (no leak).
LEAK=""
for u in "tmx-$SESS.scope" "tmxw-$SESS.slice" "tmx-$SESS2.scope" "tmxw-$SESS2.slice"; do
    [ "$(systemctl --user is-active "$u" 2>/dev/null || true)" = "active" ] && LEAK="$LEAK $u"
done
if [ -z "$LEAK" ]; then
    _pass "G7: pair teardown clean — no scope/slice unit left active after kill-session"
else
    _fail "G7: leaked active units after kill-session:$LEAK"
fi

# G8: dashed session name → escaped flat slice (no unintended cgroup
# hierarchy: 'foo' quota must never bound 'foo-bar'). Live \x2d path.
TMX_SERVER_SPLIT=1 TMX_RECYCLE_IDLE_SECS=0 "$WRAPPER" new -s "$SESS3" -d >/dev/null 2>&1
sleep 1
ESC_ACTIVE="$(systemctl --user is-active "$SLICE_ESC3" 2>/dev/null || true)"
ESC_CG="$(_cg_of_unit "$SLICE_ESC3")"
if [ "$ESC_ACTIVE" = "active" ] && [ -n "$ESC_CG" ] && _subtree_has_pid "$ESC_CG"; then
    _pass "G8: dashed name '$SESS3' → flat escaped slice $SLICE_ESC3 active with a live pane pid (no nested-slice quota coupling)"
else
    _fail "G8: escaped slice for dashed name wrong (unit=$SLICE_ESC3 active='$ESC_ACTIVE' cg='$ESC_CG')"
fi
"$WRAPPER" kill-session -t "$SESS3" >/dev/null 2>&1
sleep 1
if [ "$(systemctl --user is-active "$SLICE_ESC3" 2>/dev/null || true)" != "active" ]; then
    _pass "G8b: escaped slice torn down by kill-session"
else
    _fail "G8b: escaped slice $SLICE_ESC3 still active after kill-session"
fi

echo ""
echo "  Tests: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
