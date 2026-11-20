#!/usr/bin/env bash
# Test 94 — §11.4.156/§11.4.113/secret-hygiene security gate (deterministic).
#
# Asserts on the REPO, read-only:
#   1. no active root .github/workflows/*.yml|*.yaml or .gitlab-ci.yml
#   2. no `push --force` / `--force-with-lease` in tracked shell scripts
#   3. no committed secret-like literals in tracked scripts (values never printed)
#   4. own remotes use the SSH (git@) protocol, never HTTPS
#
# SELF-VALIDATION (§11.4.107(10) golden-good/golden-bad): a throwaway fixture
# tree is seeded with all four defect classes; the analyzer MUST flag every
# one. If any seeded defect escapes, the test FAILs (a blind analyzer is a
# §11.4 PASS-bluff). The real repo is the golden-good (zero detections).
#
# Evidence: docs/qa/<run-id>/94_security_gate.log (override TMX_QA_DIR).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
RUN_ID="${TMX_RUN_ID:-testtypes-$(date -u +%Y%m%dT%H%M%SZ)}"
QA_DIR="${TMX_QA_DIR:-$REPO_ROOT/docs/qa/$RUN_ID}"
EVID="$QA_DIR/94_security_gate.log"
if ! mkdir -p "$QA_DIR" 2>/dev/null; then echo "SKIP: evidence dir $QA_DIR not writable (§11.4.3)"; exit 0; fi
: > "$EVID"

PASS=0; FAIL=0; SKIP=0
log(){ echo "$*" | tee -a "$EVID"; }
_pass(){ log "PASS: $*"; PASS=$((PASS+1)); }
_fail(){ log "FAIL: $*"; FAIL=$((FAIL+1)); }
_skip(){ log "SKIP: $*"; SKIP=$((SKIP+1)); }

log "── Test 94: security gate (run-id $RUN_ID) ──"

command -v git >/dev/null 2>&1 || { _skip "git not on PATH"; log "PASS: 94 security gate SKIPped (no git)"; exit 0; }
SCRATCH="${TMPDIR:-/tmp}"; SCRATCH="${SCRATCH%/}"
W="$SCRATCH/tmx_t94_$$"
mkdir -p "$W" 2>/dev/null || { _skip "scratch $SCRATCH not writable"; exit 0; }
trap 'rm -rf "$W" 2>/dev/null || true' EXIT

# Forbidden tokens are BUILT, never written literally, so this script cannot
# flag itself once it becomes a tracked file.
_fo="--fo"; _fo="${_fo}rce"            # --force
_fl="${_fo}-with-lease"
_ghp="gh""p_"
_gpat="github_""pat_"
_pem="-----BEGIN ""PRIVATE KEY-----"

DET_CI=0; DET_FORCE=0; DET_SECRET=0; DET_REMOTE=0
_detect(){ log "  DETECT: $1 :: $2"; }

_list_files(){
  local root="$1" mode="$2"
  if [ "$mode" = tracked ]; then
    git -C "$root" ls-files 2>/dev/null
  else
    (cd "$root" && find . -type f -print | sed 's|^\./||')
  fi
}

_analyze(){
  local root="$1" mode="$2"
  # (1) active root CI
  local wf
  for wf in "$root/.github/workflows/"*.yml "$root/.github/workflows/"*.yaml; do
    if [ -f "$wf" ]; then DET_CI=$((DET_CI+1)); _detect CI "active workflow $(basename "$wf")"; fi
  done
  if [ -f "$root/.gitlab-ci.yml" ]; then DET_CI=$((DET_CI+1)); _detect CI "active .gitlab-ci.yml"; fi

  local script_list
  script_list="$(_list_files "$root" "$mode" | grep -E '^(scripts/.*\.(sh|bash)|commit_all\.sh)$' || true)"
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    # SELF-EXCLUSION (§11.4.201(1) false-positive refusal): this gate's OWN
    # source documents the forbidden literals in its header comment. Once the
    # gate is committed, `git ls-files` includes it and the scan flags itself
    # (measured 2026-11-20: FORCE at scripts/tests/94_security_gate.sh:6).
    # Exclude only this one file from the literal scan; its golden-bad fixture
    # is a separate throwaway tree and remains fully self-validated.
    [ "$rel" = "scripts/tests/94_security_gate.sh" ] && continue
    local f="$root/$rel"
    [ -f "$f" ] || continue
    # (2) force-push flags — print file:lineno ONLY, never the line value
    local ln
    ln="$(grep -nF -e "push $_fo" -e "$_fl" "$f" 2>/dev/null | cut -d: -f1 | paste -sd, - || true)"
    if [ -n "$ln" ]; then DET_FORCE=$((DET_FORCE+1)); _detect FORCE "$rel:$ln"; fi
    # (3) secret-like literals — print file:lineno ONLY, never the secret
    ln="$(grep -nF -e "$_ghp" -e "$_gpat" -e "$_pem" "$f" 2>/dev/null | cut -d: -f1 | paste -sd, - || true)"
    ln="${ln}$(grep -nE 'AKIA[0-9A-Z]{16}' "$f" 2>/dev/null | cut -d: -f1 | paste -sd, - || true)"
    if [ -n "$ln" ]; then DET_SECRET=$((DET_SECRET+1)); _detect SECRET "$rel:$ln"; fi
  done <<< "$script_list"

  # (4) own remotes SSH-only
  local urls
  if [ "$mode" = tracked ]; then
    urls="$(git -C "$root" config --get-regexp '^remote\..*\.url$' 2>/dev/null | sed 's/^[^ ]* //')"
  else
    urls="$(cat "$root/remotes.fixture" 2>/dev/null)"
  fi
  while IFS= read -r u; do
    [ -z "$u" ] && continue
    case "$u" in
      git@*) continue ;;
      *vasic-digital*|*HelixDevelopment*|*helixdevelopment*)
        DET_REMOTE=$((DET_REMOTE+1)); _detect REMOTE "non-SSH own remote URL (value redacted)" ;;
    esac
  done <<< "$urls"
}

# ── golden-bad: seed all four defect classes in a throwaway tree ────────────
FIX="$W/tree"; mkdir -p "$FIX/.github/workflows" "$FIX/scripts"
printf 'name: seeded\n' > "$FIX/.github/workflows/ci.yml"
printf '%s\n' 'git push '"$_fo"' origin main' > "$FIX/scripts/deploy_force.sh"
printf '%s\n' 'git push '"$_fl"' origin main' > "$FIX/scripts/deploy_lease.sh"
printf '%s\n' 'export TOKEN=' > "$FIX/scripts/config.sh"
printf 'TOKEN=%s12345678901234567890\n' "$_ghp" >> "$FIX/scripts/config.sh"
printf '%s\n' 'https://github.com/vasic-digital/tmux.git' > "$FIX/remotes.fixture"
log "  [golden-bad] seeded tree: active workflow + 2 force flags + token literal + HTTPS own remote"
_analyze "$FIX" tree
if [ "$DET_CI" -ge 1 ] && [ "$DET_FORCE" -ge 2 ] && [ "$DET_SECRET" -ge 1 ] && [ "$DET_REMOTE" -ge 1 ]; then
  _pass "self-validation: all 4 seeded defect classes detected (CI=$DET_CI FORCE=$DET_FORCE SECRET=$DET_SECRET REMOTE=$DET_REMOTE)"
else
  _fail "self-validation FAILED: a seeded defect escaped (CI=$DET_CI FORCE=$DET_FORCE SECRET=$DET_SECRET REMOTE=$DET_REMOTE)"
fi

# ── golden-good: analyze the real repo (must be clean) ──────────────────────
DET_CI=0; DET_FORCE=0; DET_SECRET=0; DET_REMOTE=0
_analyze "$REPO_ROOT" tracked
if [ "$DET_CI" -eq 0 ] && [ "$DET_FORCE" -eq 0 ] && [ "$DET_SECRET" -eq 0 ] && [ "$DET_REMOTE" -eq 0 ]; then
  _pass "repo clean: CI=0 FORCE=0 SECRET=0 REMOTE=0"
else
  _fail "repo has security findings (CI=$DET_CI FORCE=$DET_FORCE SECRET=$DET_SECRET REMOTE=$DET_REMOTE)"
fi

if [ "$FAIL" -gt 0 ] || [ "$SKIP" -gt 0 ]; then
  log "FAIL: security gate FAIL=$FAIL SKIP=$SKIP"
  exit 1
fi
log "PASS: security gate green — self-validated 4/4, repo clean"
exit 0
