#!/usr/bin/env bash
# Test 18 — HelixConstitution submodule inheritance gate.
#
# Forensic anchor: this project's governance was refactored (Fixed.md
# A17) so the universal rules — the anti-bluff covenant, data safety,
# the memory budget, the continuation-document invariant — live in the
# HelixConstitution submodule at `constitution/`, and the project's own
# Constitution.md / CLAUDE.md / AGENTS.md / QWEN.md INHERIT from it.
#
# Inheritance that is merely *claimed* is a §101 bluff. This gate proves
# it mechanically:
#   - the submodule is present and populated;
#   - .gitmodules records it with an SSH URL;
#   - the §11.4 End-user Quality Guarantee anchor physically exists in
#     constitution/Constitution.md (the exact sentinel line the
#     constitution's own meta_test_inheritance.sh mutates);
#   - the verbatim anti-bluff user mandate is present in the submodule;
#   - every project governance doc carries its inheritance pointer.
#
# §102 note: there is no operator "entry point" for a governance file —
# the operator-equivalent here is "an agent opens the repo and the
# governance is actually wired". This test reads real file CONTENT and
# real git state; no check passes on file existence alone.
#
# CONSTITUTION_DIR override: T1–T4 read $CONSTITUTION_DIR (default
# constitution/). The paired mutation (meta-test CM-CONSTITUTION-
# INHERITANCE) points this at a TEMP COPY with the §11.4 anchor deleted
# — so the real, decoupled `constitution/` submodule is never modified.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONSTITUTION_DIR="${CONSTITUTION_DIR:-$REPO_ROOT/constitution}"

echo "── Test 18: HelixConstitution inheritance gate ──"
echo "  constitution dir: $CONSTITUTION_DIR"

PASS=0; FAIL=0; SKIP=0
_pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
_fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }
_skip() { echo "SKIP: $*"; SKIP=$((SKIP + 1)); }

# The exact sentinel line. constitution/meta_test_inheritance.sh greps
# this verbatim; this gate MUST grep the identical string so that a
# deletion of the anchor makes BOTH the constitution-side meta-test and
# this gate FAIL in lockstep.
SENTINEL='### §11.4 End-user quality guarantee — forensic anchor (User mandate, 2026-04-28)'

# ── T1: submodule directory present and populated ─────────────────────
if [ -f "$CONSTITUTION_DIR/Constitution.md" ] && \
   [ -f "$CONSTITUTION_DIR/CLAUDE.md" ] && \
   [ -f "$CONSTITUTION_DIR/AGENTS.md" ]; then
    _pass "T1: constitution submodule populated (Constitution.md + CLAUDE.md + AGENTS.md present)"
else
    _fail "T1: constitution submodule not populated at $CONSTITUTION_DIR — run 'git submodule update --init'"
    echo ""
    echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"; exit 1
fi

# ── T2: .gitmodules records the submodule with an SSH URL ─────────────
GM="$REPO_ROOT/.gitmodules"
if [ -f "$GM" ] && grep -q 'path = constitution' "$GM" && \
   grep -Eq 'url = git@[^ ]*HelixConstitution' "$GM"; then
    _pass "T2: .gitmodules records constitution submodule with an SSH URL (no-HTTPS rule honored)"
else
    _fail "T2: .gitmodules missing the constitution entry or not using an SSH URL"
    grep -A2 'constitution' "$GM" 2>/dev/null | sed 's/^/  /' || true
fi

# ── T2b: submodule is initialized (gitlink resolved, not the '-' state) ─
SM_STATUS="$(git -C "$REPO_ROOT" submodule status constitution 2>/dev/null || true)"
case "$SM_STATUS" in
    -*) _fail "T2b: constitution submodule not initialized (git submodule status: '$SM_STATUS')" ;;
    "") _skip "T2b: 'git submodule status constitution' produced no output (git unavailable?)" ;;
    *)  _pass "T2b: constitution submodule initialized at $(printf '%s' "$SM_STATUS" | awk '{print $1}')" ;;
esac

# ── T3: the §11.4 End-user Quality Guarantee anchor physically exists ─
#       in constitution/Constitution.md. THIS is the load-bearing
#       anti-bluff anchor. Its deletion is what the paired mutation
#       simulates — this assertion MUST then FAIL.
if grep -qF "$SENTINEL" "$CONSTITUTION_DIR/Constitution.md"; then
    _pass "T3: §11.4 End-user Quality Guarantee anchor present in constitution/Constitution.md"
else
    _fail "T3: §11.4 anchor MISSING from constitution/Constitution.md — the inherited anti-bluff covenant has been weakened"
fi

# ── T4: the verbatim anti-bluff user mandate is in the submodule ──────
if grep -q 'all tests do execute with success' "$CONSTITUTION_DIR/Constitution.md"; then
    _pass "T4: verbatim anti-bluff user mandate present in constitution/Constitution.md"
else
    _fail "T4: verbatim anti-bluff user mandate MISSING from constitution/Constitution.md"
fi

# ── T5: project Constitution.md extends the submodule ────────────────
PCON="$REPO_ROOT/Constitution.md"
if grep -q 'constitution/Constitution.md' "$PCON" && grep -qi 'extends' "$PCON"; then
    _pass "T5: project Constitution.md declares it extends constitution/Constitution.md"
else
    _fail "T5: project Constitution.md does not wire inheritance to constitution/Constitution.md"
fi

# ── T6: project CLAUDE.md carries the INHERITED-FROM pointer + @import ─
PCLAUDE="$REPO_ROOT/CLAUDE.md"
if grep -q 'INHERITED FROM constitution/CLAUDE.md' "$PCLAUDE" && \
   grep -qF '@constitution/CLAUDE.md' "$PCLAUDE"; then
    _pass "T6: project CLAUDE.md carries the INHERITED-FROM block and @constitution/CLAUDE.md import"
else
    _fail "T6: project CLAUDE.md missing the inheritance pointer / @constitution import"
fi

# ── T7: project AGENTS.md references the submodule's AGENTS.md ────────
PAGENTS="$REPO_ROOT/AGENTS.md"
if grep -q 'constitution/AGENTS.md' "$PAGENTS"; then
    _pass "T7: project AGENTS.md references constitution/AGENTS.md"
else
    _fail "T7: project AGENTS.md does not reference constitution/AGENTS.md"
fi

# ── T8: project QWEN.md exists and references the submodule's QWEN.md ─
PQWEN="$REPO_ROOT/QWEN.md"
if [ -f "$PQWEN" ] && grep -q 'constitution/QWEN.md' "$PQWEN"; then
    _pass "T8: project QWEN.md present and references constitution/QWEN.md"
else
    _fail "T8: project QWEN.md missing or does not reference constitution/QWEN.md"
fi

# ── T9: project Constitution.md keeps the §101 anti-bluff binding ─────
#       The full refactor defers universal clauses to the submodule, but
#       the project-origin anti-bluff binding (§101) MUST remain in the
#       project Constitution per the operator mandate.
if grep -q '§101' "$PCON" && grep -q 'all tests do execute with success' "$PCON"; then
    _pass "T9: project Constitution.md §101 anti-bluff covenant binding intact"
else
    _fail "T9: project Constitution.md §101 anti-bluff binding missing"
fi

echo ""
echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
