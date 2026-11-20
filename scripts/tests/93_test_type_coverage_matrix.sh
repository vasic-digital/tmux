#!/usr/bin/env bash
# Test 93 — §11.4.169 comprehensive test-type coverage matrix (deterministic).
#
# Encodes the CLOSED 13-type set of §11.4.169 as a coverage matrix: for every
# type it names the concrete test(s) that exercise it and the evidence path.
# Genuinely absent / partially-wired types are marked HONESTLY (§11.4.6) —
# a matrix that claims coverage it does not have is a §11.4 PASS-bluff.
#
# The test is self-validating: every artifact claimed PRESENT must exist on
# disk, else the test FAILs (a coverage claim naming a missing test is a
# bluff). Rows marked PARTIAL/GAP are reported, never silently upgraded.
#
# Evidence: docs/qa/<run-id>/93_coverage_matrix.log (override TMX_QA_DIR).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
RUN_ID="${TMX_RUN_ID:-testtypes-$(date -u +%Y%m%dT%H%M%SZ)}"
QA_DIR="${TMX_QA_DIR:-$REPO_ROOT/docs/qa/$RUN_ID}"
EVID="$QA_DIR/93_coverage_matrix.log"
if ! mkdir -p "$QA_DIR" 2>/dev/null; then echo "SKIP: evidence dir $QA_DIR not writable (§11.4.3)"; exit 0; fi
: > "$EVID"

PASS=0; FAIL=0
log(){ echo "$*" | tee -a "$EVID"; }
_pass(){ log "PASS: $*"; PASS=$((PASS+1)); }
_fail(){ log "FAIL: $*"; FAIL=$((FAIL+1)); }

log "════════════════════════════════════════════════════════════════"
log " §11.4.169 test-type coverage matrix (run-id $RUN_ID)"
log "════════════════════════════════════════════════════════════════"
log "TYPE | TEST(S) | EVIDENCE PATH | STATUS"
log " 1  unit                    | 64_session_color_parse_unit.sh, 10_hostname_color_algorithm.sh, 91_zig_yacc_contract.sh | docs/qa/<run-id>/ | PRESENT"
log " 2  integration             | 11_hostname_color_integration.sh, 40_macos_linux_parity.sh | docs/qa/<run-id>/ | PRESENT"
log " 3  e2e                     | 43_e2e_cwd_persist_real_shell.sh, 42_setup_install_uninstall_e2e.sh, 68_session_lifecycle.sh | docs/qa/<run-id>/ | PRESENT"
log " 4  full-automation         | scripts/tests/run_all.sh (auto-discovers [0-9][0-9]_*.sh, stdin severed §11.4.98) | docs/qa/<run-id>/ | PRESENT"
log " 5  Challenges              | scripts/challenges/tmux.yaml | docs/qa/<run-id>/ | PARTIAL: definitions exist; no automated challenge runner wired into run_all.sh"
log " 6  HelixQA                 | 98_helixqa_content_verification_gate.sh; scripts/testing/* (separate surface) | docs/qa/<run-id>/ | PRESENT: deterministic content oracle; full HelixQA UI-Vision runner is a separate surface"
log " 7  DDoS/load-flood          | 13_tasksmax_stress.sh, 14_concurrent_oom_independence.sh, 06_concurrent_panes.sh | docs/qa/<run-id>/ | PRESENT"
log " 8  security                | 94_security_gate.sh, 90_install_ssh_only_no_credential_prompt.sh, 34_ssh_install_idempotent.sh | docs/qa/<run-id>/ | PRESENT"
log " 9  stress+chaos            | 97_stress_chaos_gate.sh, 12_memory_pressure_under_cap.sh, 39_state_unwritable.sh | docs/qa/<run-id>/ | PRESENT"
log "10  concurrency/atomicity   | 33_state_concurrency.sh, 95_race_deadlock_gate.sh, 14_concurrent_oom_independence.sh | docs/qa/<run-id>/ | PRESENT"
log "11  race/deadlock           | 95_race_deadlock_gate.sh, 33_state_concurrency.sh | docs/qa/<run-id>/ | PRESENT"
log "12  memory                  | 12_memory_pressure_under_cap.sh, 08_oom_score_adj.sh, 03_jemalloc_loaded.sh | docs/qa/<run-id>/ | PRESENT"
log "13  benchmarking/performance| 96_benchmark_performance_gate.sh (p50/p95, derived threshold, no literature SLA) | docs/qa/<run-id>/ | PRESENT"

# Every artifact claimed PRESENT must exist — else the claim is a bluff.
claim_files=(
  64_session_color_parse_unit.sh 10_hostname_color_algorithm.sh 91_zig_yacc_contract.sh
  11_hostname_color_integration.sh 40_macos_linux_parity.sh
  43_e2e_cwd_persist_real_shell.sh 42_setup_install_uninstall_e2e.sh 68_session_lifecycle.sh
  13_tasksmax_stress.sh 14_concurrent_oom_independence.sh 06_concurrent_panes.sh
  94_security_gate.sh 90_install_ssh_only_no_credential_prompt.sh 34_ssh_install_idempotent.sh
  97_stress_chaos_gate.sh 12_memory_pressure_under_cap.sh 39_state_unwritable.sh
  33_state_concurrency.sh 95_race_deadlock_gate.sh
  08_oom_score_adj.sh 03_jemalloc_loaded.sh 96_benchmark_performance_gate.sh
  98_helixqa_content_verification_gate.sh
)
missing=0
for f in "${claim_files[@]}"; do
  if [ -f "$SELF_DIR/$f" ]; then :; else _fail "claimed test missing: $f"; missing=$((missing+1)); fi
done
[ "$missing" -eq 0 ] && _pass "all ${#claim_files[@]} claimed PRESENT test artifacts exist on disk"

[ -f "$REPO_ROOT/scripts/challenges/tmux.yaml" ] && _pass "Challenge definitions present (scripts/challenges/tmux.yaml)" \
  || _fail "scripts/challenges/tmux.yaml missing"
[ -f "$REPO_ROOT/scripts/tests/run_all.sh" ] && _pass "full-automation driver present (run_all.sh)" \
  || _fail "run_all.sh missing"

if [ "$FAIL" -gt 0 ]; then
  log "FAIL: coverage matrix has $FAIL broken claim(s) — §11.4.169/§11.4.6"
  exit 1
fi
log "PASS: 13-type coverage matrix emitted; $PASS structural checks green; gaps marked honestly"
exit 0
