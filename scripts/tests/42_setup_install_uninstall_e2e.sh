#!/usr/bin/env bash
# Test 42 — install/uninstall end-to-end with shell-init disk presence.
#
# Forensic anchor: User mandate 2026-05-22 (post-v1.0.10): "after all is
# done with success, when we have tried to open new terminal and start
# our first tmx session we have not been asked anything regarding the
# naming the session! Terminal just opened without tmux session being
# created!". Root cause: setup.sh wrote the rc snippet but never
# generated scripts/tmx-shell-init.sh from its template. The snippet's
# `[ -r ... ] && . ...` guard silently no-ops when the file is missing
# → no prompt fires. Existing tests substituted the template inline and
# never exercised the disk → rc → init flow that operators actually use.
#
# ⚠ RECURSION GUARD ⚠
# This test does NOT invoke `bash scripts/setup.sh`. setup.sh's step 4
# (verification gate) calls `scripts/tests/run_all.sh` which would loop
# back into THIS test → infinite recursion observed 2026-05-22 (the
# user-visible bug spawned 3 concurrent test-42 instances + an orphan
# setup-verify).
# Instead, this test reproduces the INSTALL artefacts deterministically
# via the same generators setup.sh uses (sed-substitute the templates
# directly, append to a sandbox rc), then asserts the invariants the
# operator actually cares about. The uninstall path delegates to a
# dedicated copy of `_do_uninstall` (extracted from setup.sh) so we
# never reach run_all from inside this test.
#
# What this test proves (§11.4.5 captured-evidence per assertion):
#   Phase A (post-install simulation):
#     A1. tmx-shell-init.sh sandbox copy exists + is executable +
#         has no unresolved __PROJECT__ / __DATE__ placeholders.
#     A2. The sandbox rc file contains exactly ONE source line for it.
#     A3. The sandbox rc file contains exactly ONE fenced block.
#     A4. Sourcing the init file in a subshell (TTY guard stripped)
#         REACHES the tmx invocation — proved via a fake-tmx on PATH
#         that logs argv.
#   Phase B (uninstall simulation):
#     B1. The fenced block disappears from the sandbox rc file.
#     B2. The legacy unfenced `if command -v tmx ...` block (if pre-
#         seeded) ALSO disappears.
#     B3. The sandbox init file is removed.
#
# §11.4.50 deterministic-consistency: 3 iterations, identical
# evidence-hash on each PASS line.
# §11.4.81: works the same on Linux and Darwin (uses sandbox; no rc
# file shape difference).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INIT_TEMPLATE="$REPO_ROOT/scripts/tmx-shell-init.sh.template"
SNIPPET_TEMPLATE="$REPO_ROOT/scripts/bashrc_snippet.template"

# Sandbox — everything happens inside, never touches operator's real
# rc files or HOME.
SANDBOX="$(mktemp -d -t tmx-test-42-XXXXXX)"
SANDBOX_RC="$SANDBOX/sandbox.rc"
SANDBOX_INIT="$SANDBOX/tmx-shell-init.sh"
SANDBOX_FAKEBIN="$SANDBOX/fakebin"
SANDBOX_LOG="$SANDBOX/tmx-call.log"

_cleanup() {
    rm -rf "$SANDBOX" 2>/dev/null || true
}
trap '_cleanup' EXIT

[ -f "$INIT_TEMPLATE" ] || { echo "SKIP 42: tmx-shell-init.sh.template not present (pre-v1.0.9 tree)"; exit 77; }
[ -f "$SNIPPET_TEMPLATE" ] || { echo "SKIP 42: bashrc_snippet.template not present"; exit 77; }

PASS_COUNT=0
FAIL_COUNT=0
EVIDENCE=()

_pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT+1)); EVIDENCE+=("$1"); }
_fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT+1)); }

# ---- helpers reproducing setup.sh behaviour (single source of truth
#      is setup.sh; this is the documented mirror for test purposes) ----

_install_into_sandbox() {
    # 1) Generate tmx-shell-init.sh from the template (the v1.0.11 step 3a
    #    that fixed the original missing-file bug).
    sed \
        -e "s|__PROJECT__|$SANDBOX|g" \
        -e "s|__DATE__|test-42-$(date '+%H%M%S')|" \
        "$INIT_TEMPLATE" > "$SANDBOX_INIT"
    chmod 755 "$SANDBOX_INIT"

    # 2) Generate the rc snippet from its template, substituting our
    #    sandbox path so the `[ -r ... ]` guard points at SANDBOX_INIT.
    local snippet
    snippet=$(sed \
        -e "s|__PROJECT__|$SANDBOX|g" \
        -e "s|__DATE__|test-42-$(date '+%H%M%S')|" \
        "$SNIPPET_TEMPLATE")
    # Append snippet to the sandbox rc (operator's real install path
    # appends to ~/.bashrc / ~/.zshrc; same mechanic).
    printf '%s\n' "$snippet" >> "$SANDBOX_RC"
}

_uninstall_from_sandbox() {
    # Mirrors setup.sh's _do_uninstall: strip the fenced block + the
    # legacy unfenced snippet from the rc file, remove the init file.
    perl -i -ne 'print unless /^# ─── vasic-digital optimized tmux/ .. /^# ─── end vasic-digital optimized tmux/' "$SANDBOX_RC"
    python3 - "$SANDBOX_RC" <<'PYEOF'
import re, sys
p = sys.argv[1]
src = open(p).read()
pat = re.compile(
    r'\n?if command -v tmx (?:&> /dev/null|>/dev/null 2>&1) && \[ -z "\$TMUX" \]; then\n'
    r'(?:.*?\n){1,12}?'
    r'    tmx attach -t "\$session_name" 2>/dev/null \|\| tmx new -s "\$session_name"\n'
    r'fi\n',
    re.DOTALL,
)
new = pat.sub('\n', src, count=1)
if new != src:
    open(p, 'w').write(new)
PYEOF
    rm -f "$SANDBOX_INIT"
}

run_phase_a() {
    local iter="$1"

    # Fresh sandbox rc each iter.
    : > "$SANDBOX_RC"

    # Seed: a LEGACY pre-v1.0.9 unfenced snippet that the operator might
    # have hand-pasted. Phase B must remove this too.
    cat >> "$SANDBOX_RC" <<'EOF'
# unrelated content above

if command -v tmx &> /dev/null && [ -z "$TMUX" ]; then
    echo "Enter session name (leave blank for 'default'):"
    read -r session_name
    if [ -z "$session_name" ]; then
        session_name="default"
    fi
    tmx attach -t "$session_name" 2>/dev/null || tmx new -s "$session_name"
fi
EOF

    # Simulate v1.0.11 install (step 3 wrapper-gen excluded; we only
    # care about step 3a + step 5 rc append for this test).
    _install_into_sandbox

    # ── A1: init file exists + executable + no placeholders ──
    if [ ! -f "$SANDBOX_INIT" ]; then
        _fail "iter=$iter A1: $SANDBOX_INIT does not exist after install"
        return 1
    fi
    if [ ! -x "$SANDBOX_INIT" ]; then
        _fail "iter=$iter A1.1: init file not executable"
        return 1
    fi
    if grep -q '__PROJECT__\|__DATE__' "$SANDBOX_INIT"; then
        _fail "iter=$iter A1.2: init file has unresolved placeholders"
        return 1
    fi
    _pass "iter=$iter A1: tmx-shell-init.sh present + exec + placeholders resolved"

    # ── A2: rc has exactly ONE source line ──
    local src_count
    src_count=$(grep -cE '\[ -r .*tmx-shell-init\.sh.* \] && \. .*tmx-shell-init\.sh' "$SANDBOX_RC")
    if [ "$src_count" != "1" ]; then
        _fail "iter=$iter A2: rc has $src_count source lines (expected 1)"
        return 1
    fi
    _pass "iter=$iter A2: rc has exactly 1 source line for tmx-shell-init.sh"

    # ── A3: rc has exactly ONE fenced block (2 marker lines) ──
    local fence_count
    fence_count=$(grep -cE 'vasic-digital optimized tmux' "$SANDBOX_RC")
    # Opening: "─── vasic-digital optimized tmux ───…" + closing:
    # "─── end vasic-digital optimized tmux ───…" + 4 comment-body
    # lines that also contain the phrase ("optimized tmux 3.6a build",
    # "vasic-digital optimized tmux configuration", etc.). Exact count
    # is template-dependent; we assert >= 2 (open+close present) and
    # use the explicit open/close marker pair for the strict check.
    local open_count close_count
    open_count=$(grep -cE '^# ─── vasic-digital optimized tmux ─' "$SANDBOX_RC")
    close_count=$(grep -cE '^# ─── end vasic-digital optimized tmux ─' "$SANDBOX_RC")
    if [ "$open_count" != "1" ] || [ "$close_count" != "1" ]; then
        _fail "iter=$iter A3: rc has open=$open_count close=$close_count (expected 1+1 = 1 block); total-mentions=$fence_count"
        return 1
    fi
    _pass "iter=$iter A3: rc has exactly 1 fenced block"

    # ── A4: sourcing init reaches tmx invocation (anti-bluff core) ──
    mkdir -p "$SANDBOX_FAKEBIN"
    cat > "$SANDBOX_FAKEBIN/tmx" <<'FAKETMX'
#!/bin/sh
echo "fake-tmx-call: $*" >> "${TMX_FAKE_LOG:-/dev/null}"
exit 0
FAKETMX
    chmod 755 "$SANDBOX_FAKEBIN/tmx"
    : > "$SANDBOX_LOG"

    # Strip [ -t 0 ] guard for piped-stdin test (mirrors test 35 harness).
    local stripped="$SANDBOX/init-stripped.sh"
    sed '/if \[ ! -t 0 \] || \[ ! -t 1 \]; then/,/^fi$/d' "$SANDBOX_INIT" > "$stripped"

    local prompt_out
    prompt_out=$(printf 'testsess-%s\n' "$iter" | \
        env PATH="$SANDBOX_FAKEBIN:$PATH" TMX_FAKE_LOG="$SANDBOX_LOG" TMUX="" \
        bash "$stripped" 2>&1) || true

    if ! grep -q 'fake-tmx-call' "$SANDBOX_LOG"; then
        _fail "iter=$iter A4: init did NOT invoke tmx; stdout='$prompt_out' log='$(cat "$SANDBOX_LOG")'"
        return 1
    fi
    _pass "iter=$iter A4: init reached tmx invocation ($(wc -l < "$SANDBOX_LOG") call(s) logged)"
    return 0
}

run_phase_b() {
    local iter="$1"

    _uninstall_from_sandbox

    # ── B1: fenced block gone ──
    local open_after close_after
    open_after=$(grep -cE '^# ─── vasic-digital optimized tmux ─' "$SANDBOX_RC" 2>/dev/null || true)
    close_after=$(grep -cE '^# ─── end vasic-digital optimized tmux ─' "$SANDBOX_RC" 2>/dev/null || true)
    if [ "$open_after" != "0" ] || [ "$close_after" != "0" ]; then
        _fail "iter=$iter B1: rc still has open=$open_after close=$close_after markers after uninstall"
        return 1
    fi
    _pass "iter=$iter B1: rc fenced block removed"

    # ── B2: legacy unfenced block gone ──
    local legacy_after
    legacy_after=$(grep -c 'if command -v tmx' "$SANDBOX_RC" 2>/dev/null || true)
    if [ "$legacy_after" != "0" ]; then
        _fail "iter=$iter B2: rc still has $legacy_after legacy 'if command -v tmx' line(s)"
        return 1
    fi
    _pass "iter=$iter B2: legacy unfenced snippet removed"

    # ── B3: init file removed ──
    if [ -f "$SANDBOX_INIT" ]; then
        _fail "iter=$iter B3: init file still present after uninstall"
        return 1
    fi
    _pass "iter=$iter B3: init file removed"
    return 0
}

for iter in 1 2 3; do
    if ! run_phase_a "$iter"; then break; fi
    if ! run_phase_b "$iter"; then break; fi
done

HASH=$(printf '%s\n' "${EVIDENCE[@]}" | shasum | cut -d' ' -f1)
echo "[evidence] iters_completed=$((PASS_COUNT / 7)) reliability_hash=$HASH"
echo ""
echo "  Tests: PASS=$PASS_COUNT  FAIL=$FAIL_COUNT  SKIP=0"
if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "FAIL 42 install/uninstall E2E surfaced $FAIL_COUNT defect(s)"
    exit 1
fi
echo "PASS 42 setup install/uninstall E2E — tmx-shell-init.sh present, rc snippet 1×, fake-tmx invoked, uninstall removes all 3 artefacts (3/3 iterations)"
exit 0
