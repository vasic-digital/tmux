#!/usr/bin/env bash
# Test 86 — Host-adaptive default CPUQuota (§11.4.115 RED/GREEN polarity).
#
# Defect (forensic anchor 2026-07-22, operator report "sessions become more
# and more sluggish / typing stalls / timer updates every 5-10 s"):
#   scripts/tmx hardcoded `TMX_CPU_EFFECTIVE="${TMX_CPU:-200}"` — a FIXED
#   CPUQuota=200% (2 cores) for ANY host. On the 64-core production host the
#   whole session tree (tmux server + Claude agent + all subagents; measured
#   945 threads / 126 processes in tmx-atmosphere-0993.scope) shared 2 cores:
#   cgroup cpu.stat nr_throttled 2680/14279 periods (18.8%), 1757 s cumulative
#   forced-idle in ~25 min. Because the tmux SERVER lives inside the same
#   throttled scope, quota exhaustion froze typing echo + timer redraws for
#   the remainder of every 100 ms CFS period — the progressive sluggishness.
#
# Fix under test: `_default_cpu_pct()` (cores*15%, floor 200%, cap cores*100)
#   + `TMX_CPU_EFFECTIVE="${TMX_CPU:-auto}"` auto-expansion.
#
# Polarity (§11.4.115 — ONE source, TWO roles):
#   RED_MODE=1  reproduce-and-assert-DEFECT-PRESENT on the pre-fix artifact
#               (exit 0 iff the fixed-200 default is still there).
#   RED_MODE=0  (default) regression GUARD: assert the host-adaptive default
#               is present, functionally correct, and (Linux) actually lands
#               on a freshly-spawned session's cgroup (§11.4.108 layer 3).
#
# Env:
#   T86_TARGET  wrapper source to statically/functionally test
#               (default $REPO_ROOT/scripts/tmx.template)
#   T86_LIVE    1 (default) run the Linux live-scope spawn subtest; 0 skip
#   WRAPPER     executable wrapper for the live subtest (default scripts/tmx)

set -uo pipefail

RED_MODE="${RED_MODE:-0}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET="${T86_TARGET:-$REPO_ROOT/scripts/tmx.template}"
WRAPPER="${WRAPPER:-$REPO_ROOT/scripts/tmx}"
T86_LIVE="${T86_LIVE:-1}"

PASS=0; FAIL=0; SKIP=0
_pass() { echo "PASS: $*"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
_skip() { echo "SKIP: $*"; SKIP=$((SKIP+1)); }

echo "── Test 86: host-adaptive CPUQuota default (RED_MODE=$RED_MODE) ──"
echo "  target: $TARGET"

[ -r "$TARGET" ] || { echo "FAIL: target $TARGET not readable"; exit 1; }

_has_fn=0
grep -q '^_default_cpu_pct()' "$TARGET" && _has_fn=1
_has_auto=0
grep -q 'TMX_CPU_EFFECTIVE="\${TMX_CPU:-auto}"' "$TARGET" && _has_auto=1
_has_fixed=0
grep -q 'TMX_CPU_EFFECTIVE="\${TMX_CPU:-200}"' "$TARGET" && _has_fixed=1
# 2026-08-10 reconciliation (§11.4.120 — a correct fix broke this gate's
# stale "CPUQuota is host-adaptive BY DEFAULT" assumption; RECONCILED, never
# fake-passed/reverted/deleted): CPU is now unlimited by default (no
# CPUQuota property at all) and TMX_CPU=auto opts IN to this same
# _default_cpu_pct() value. Both patterns below MUST hold post-fix.
_has_empty_default=0
grep -q 'TMX_CPU_EFFECTIVE="\${TMX_CPU:-}"' "$TARGET" && _has_empty_default=1
_has_auto_optin=0
grep -q '\[ "\$TMX_CPU_EFFECTIVE" = auto \] && TMX_CPU_EFFECTIVE="\$(_default_cpu_pct)"' "$TARGET" && _has_auto_optin=1

if [ "$RED_MODE" = "1" ]; then
    # Reproduce the defect: fixed-200 default present AND no adaptive path.
    if [ "$_has_fixed" -eq 1 ] && [ "$_has_fn" -eq 0 ]; then
        _pass "RED: defect reproduced — fixed \${TMX_CPU:-200} default, no _default_cpu_pct (any-core host capped at 2 cores)"
    else
        _fail "RED: defect NOT present (has_fixed=$_has_fixed has_fn=$_has_fn) — artifact already carries the host-adaptive default"
    fi
    echo "  Tests: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
    [ "$FAIL" -gt 0 ] && exit 1 || exit 0
fi

# ── GREEN guard mode ────────────────────────────────────────────────────
# G1: wrapper parses (§11.4.67; bash — the wrapper uses arrays).
if bash -n "$TARGET" 2>/dev/null; then
    _pass "G1: bash -n parse clean"
else
    _fail "G1: bash -n reports syntax errors"
fi

# G2: adaptive function present; CPU is UNLIMITED by default (2026-08-10 —
# no unconditional CPUQuota, §11.4.120 reconciliation); `auto` remains an
# explicit OPT-IN to the host-adaptive value; the pre-v1.0.37 fixed-200
# default never reappears.
if [ "$_has_fn" -eq 1 ] && [ "$_has_empty_default" -eq 1 ] && [ "$_has_auto_optin" -eq 1 ] && \
   [ "$_has_auto" -eq 0 ] && [ "$_has_fixed" -eq 0 ]; then
    _pass "G2: _default_cpu_pct present, CPU unlimited by default, TMX_CPU=auto opt-in wired, no unconditional/fixed-200 default"
else
    _fail "G2: wiring wrong (has_fn=$_has_fn has_empty_default=$_has_empty_default has_auto_optin=$_has_auto_optin has_auto=$_has_auto has_fixed=$_has_fixed)"
fi

# G3: FUNCTIONAL truth-table — extract the real function from the artifact
# and RUN it (never grep-only, §11.4.201/§11.4.108) with `nproc` shadowed.
_fn_src="$(sed -n '/^_default_cpu_pct()/,/^}/p' "$TARGET")"
_run_pct() {  # _run_pct <cores> → computed default pct
    bash -c "
        HOST_OS=Linux
        nproc() { echo $1; }
        getconf() { echo 0; }
        $_fn_src
        _default_cpu_pct
    " 2>/dev/null
}
if [ -n "$_fn_src" ]; then
    r64="$(_run_pct 64)"; r4="$(_run_pct 4)"; r256="$(_run_pct 256)"; r0="$(_run_pct 0)"
    if [ "$r64" = "960" ] && [ "$r4" = "200" ] && [ "$r256" = "3840" ] && [ "$r0" = "200" ]; then
        _pass "G3: truth-table 64→960, 4→200(floor), 256→3840, unknown→200(fallback)"
    else
        _fail "G3: truth-table wrong: 64→'$r64' (want 960) 4→'$r4' (want 200) 256→'$r256' (want 3840) 0→'$r0' (want 200)"
    fi
else
    _fail "G3: could not extract _default_cpu_pct from $TARGET"
fi

# G4: FUNCTIONAL default-expansion — run the real assignment pair.
_asn="$(grep -E 'TMX_CPU_EFFECTIVE=|_default_cpu_pct\)"' "$TARGET" | grep -E '^\s*(TMX_CPU_EFFECTIVE=|\[ "\$TMX_CPU_EFFECTIVE" = auto \])' | sed 's/^[[:space:]]*//')"
_expand() {  # _expand <TMX_CPU value or UNSET> → effective value
    # unset FIRST (§11.4.201 independent-review finding, 2026-08-10): the
    # inner `bash -c` otherwise INHERITS any TMX_CPU the operator's own
    # shell rc has exported (e.g. per this fix's own documented opt-in
    # `TMX_CPU=auto`) — the UNSET case would then spuriously read the
    # ambient value instead of genuinely-unset, producing a false FAIL on
    # exactly the opt-in configuration this fix is meant to keep working.
    bash -c "
        unset TMX_CPU
        _default_cpu_pct() { echo 777; }
        if [ '$1' != UNSET ]; then TMX_CPU='$1'; fi
        $_asn
        printf '%s' \"\$TMX_CPU_EFFECTIVE\"
    " 2>/dev/null
}
e_unset="$(_expand UNSET)"; e_auto="$(_expand auto)"; e_num="$(_expand 400)"
if [ "$e_unset" = "" ] && [ "$e_auto" = "777" ] && [ "$e_num" = "400" ]; then
    _pass "G4: default expansion — unset→'' (unlimited by default), auto→adaptive(opt-in), explicit 400 preserved"
else
    _fail "G4: expansion wrong: unset→'$e_unset' auto→'$e_auto' 400→'$e_num' (want ''/777/400)"
fi

# G5 (Linux, live): a session spawned with TMX_CPU=auto (the explicit
# OPT-IN, since 2026-08-10 CPU is unlimited by default — see test 88 for the
# default-is-unlimited coverage) really carries the host-adaptive quota on
# its cgroup — §11.4.108 RUNTIME layer, read back from the cgroup.
if [ "$T86_LIVE" != "1" ]; then
    _skip "G5: live spawn disabled (T86_LIVE=$T86_LIVE)"
elif [ "$(uname -s)" != "Linux" ]; then
    _skip "G5: Linux-only (cgroup CPUQuota); Darwin uses RLIMIT_CPU (test 24)"
elif [ ! -x "$WRAPPER" ]; then
    _skip "G5: wrapper $WRAPPER not executable"
elif ! systemd-run --user --scope --collect --quiet bash -c "exit 0" 2>/dev/null; then
    _skip "G5: systemd-run --user --scope not functional on this host"
else
    SESS="t86_$$"
    SOCK="tmx-${SESS}"
    SCOPE_UNIT="tmx-${SESS}.scope"
    TMUX_BIN_T86="$(sed -n 's/^TMUX_BIN="\(.*\)"$/\1/p' "$WRAPPER" | head -1)"
    trap '
        systemctl --user stop "$SCOPE_UNIT" >/dev/null 2>&1 || true
        [ -n "${TMUX_BIN_T86:-}" ] && "$TMUX_BIN_T86" -L "$SOCK" kill-server >/dev/null 2>&1 || true
    ' EXIT
    TMX_CPU=auto "$WRAPPER" new -s "$SESS" -d >/dev/null 2>&1
    sleep 1
    CG="$(systemctl --user show "$SCOPE_UNIT" -p ControlGroup --value 2>/dev/null)"
    QUOTA=""
    [ -n "$CG" ] && QUOTA="$(cut -d' ' -f1 "/sys/fs/cgroup${CG}/cpu.max" 2>/dev/null)"
    # Expected = the artifact's own function on the REAL host (µs per 100ms
    # period = pct × 1000), never a re-derived constant (§11.4.6).
    EXP_PCT="$(bash -c "HOST_OS=Linux; $_fn_src; _default_cpu_pct" 2>/dev/null)"
    EXP_QUOTA=$(( EXP_PCT * 1000 ))
    if [ -z "$QUOTA" ]; then
        _fail "G5: could not read cpu.max for $SCOPE_UNIT (cg='$CG')"
    elif [ "$QUOTA" = "$EXP_QUOTA" ]; then
        _pass "G5: live scope cpu.max=$QUOTA µs/100ms == host-adaptive ${EXP_PCT}% (positive cgroup readback)"
    elif [ "$QUOTA" = "200000" ] && [ "$EXP_QUOTA" != "200000" ]; then
        _fail "G5: live scope still at the DEFECT value 200000 (200%) — expected ${EXP_QUOTA} (${EXP_PCT}%)"
    else
        _fail "G5: live scope cpu.max=$QUOTA != expected $EXP_QUOTA (${EXP_PCT}%)"
    fi
    # G6: CFS burst bank (§12.11; live forensics 2026-07-22 — 16.9% of CFS
    # periods throttled at 960% quota during fleet bursts while AVERAGE
    # demand was only 4.35 CPUs; spikes inside one 100 ms period froze the
    # tmux server for the period remainder). Default burst == quota; the
    # kernel caps burst <= quota so containment holds. Read back from the
    # same cgroup — the §11.4.201 authoritative source. Honest SKIP when
    # the kernel exposes no cpu.max.burst (pre-5.14 / cgroup-v1).
    BURST_FILE="/sys/fs/cgroup${CG}/cpu.max.burst"
    if [ ! -f "$BURST_FILE" ]; then
        _skip "G6: kernel exposes no cpu.max.burst — burst not applicable on this host"
    else
        BURST="$(cat "$BURST_FILE" 2>/dev/null)"
        if [ "$BURST" = "$EXP_QUOTA" ]; then
            _pass "G6: live scope cpu.max.burst=$BURST µs == quota (burst bank absorbs intra-period spikes; long-term rate still quota-bounded)"
        elif [ "$BURST" = "0" ]; then
            _fail "G6: cpu.max.burst=0 — burst bank NOT applied (fleet bursts throttle the tmux server mid-period)"
        else
            _fail "G6: cpu.max.burst=$BURST != expected $EXP_QUOTA"
        fi
    fi
    systemctl --user stop "$SCOPE_UNIT" >/dev/null 2>&1 || true
    [ -n "${TMUX_BIN_T86:-}" ] && "$TMUX_BIN_T86" -L "$SOCK" kill-server >/dev/null 2>&1 || true
    trap - EXIT
fi

echo ""
echo "  Tests: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
