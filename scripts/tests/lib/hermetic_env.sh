#!/usr/bin/env bash
# hermetic_env.sh — neutralise ambient TMX_* operator knobs for tests.
#
# Purpose:    A test that asserts DEFAULT wrapper behaviour (or that reads a
#             session's cgroup back) MUST NOT inherit the operator's personal
#             TMX_* settings from their shell rc. Otherwise the verdict depends
#             on whose machine it runs on — a §11.4.50 determinism break and,
#             when it FAILs on healthy code, a §11.4.1 FAIL-bluff.
#
# Forensic anchor (FACT, 2026-08-12): the operator exports
#   TMX_SERVER_SPLIT=1        (~/.bashrc:96, ~/.zshrc:126)
# so EVERY `tmx new` attempted the split topology. Consequences observed on a
# fresh, correct v1.0.40 artifact:
#   - test 86 G5/G6 read the SERVER scope's cgroup (cpu.max=100000) instead of
#     the whole-session quota (960000) -> FAIL on healthy code.
#   - test 88 G6a read the server scope's TasksMax=256 instead of the operator's
#     opt-in 4096 (which correctly landed on the WORKLOAD SLICE) -> FAIL.
#   - test 77 matched the plaintext needle "ab" inside the wrapper's own
#     "...is not splittable..." warning (a §11.4.201(7)(a) carrier) -> FAIL.
# Proof: with TMX_SERVER_SPLIT unset and NOTHING else changed, 77/86/88 all
# went GREEN (77 PASS=2/0, 86 PASS=6/0, 88 PASS=9/0).
#
# Usage:      . "$SELF_DIR/lib/hermetic_env.sh"      # at test entry, before any
#                                                    # session is created
#             A test that WANTS a knob still sets it explicitly per-invocation
#             (e.g. `TMX_CPU=100 "$WRAPPER" new -s x`), exactly as tests 86/87/88
#             already do for their opt-in sub-tests. This helper only removes the
#             AMBIENT value; it never prevents an explicit one.
#
# Inputs:     none. Outputs: none. Side-effects: unsets TMX_* knobs in the
#             CURRENT shell (the test process) only — never touches the
#             operator's rc files or their interactive shells.
#
# Cross-refs: §11.4.3 (per-environment-topology dispatch), §11.4.50
#             (deterministic consistency), §11.4.1 (FAIL-bluffs forbidden),
#             §11.4.98 (re-runnable without manual intervention),
#             §11.4.201 (a measurement must assert the REAL condition).
#             scripts/tmx.template (the knobs' definitions).
# Last verified: 2026-08-12

# The closed set of operator-facing knobs the wrapper reads, enumerated FROM
# scripts/tmx.template (never guessed — §11.4.6). TMX_SPLIT_EFFECTIVE and
# TMX_SRV_CPU are wrapper-INTERNAL derivations, cleared too so a stray export
# cannot preload them.
tmx_hermetic_env() {
    unset TMX_CPU \
          TMX_CPU_BURST \
          TMX_CPU_HARD_SEC \
          TMX_MEM \
          TMX_PROC_MAX \
          TMX_RECYCLE_IDLE_SECS \
          TMX_SERVER_SPLIT \
          TMX_SPLIT_EFFECTIVE \
          TMX_SRV_CPU \
          TMX_TASKS
}

# Report what was neutralised so a run's log carries positive evidence of the
# starting state (§11.4.5) rather than a silent assumption.
tmx_hermetic_env_report() {
    local v found=""
    for v in TMX_CPU TMX_CPU_BURST TMX_CPU_HARD_SEC TMX_MEM TMX_PROC_MAX \
             TMX_RECYCLE_IDLE_SECS TMX_SERVER_SPLIT TMX_SPLIT_EFFECTIVE \
             TMX_SRV_CPU TMX_TASKS; do
        if [ -n "${!v:-}" ]; then found="$found $v=${!v}"; fi
    done
    if [ -n "$found" ]; then
        echo "  hermetic-env: neutralising ambient operator knobs:$found (§11.4.3/§11.4.50)"
    else
        echo "  hermetic-env: no ambient TMX_* knobs set (clean baseline)"
    fi
}

tmx_hermetic_env_report
tmx_hermetic_env
