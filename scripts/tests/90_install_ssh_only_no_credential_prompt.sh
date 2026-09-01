#!/usr/bin/env bash
# 90_install_ssh_only_no_credential_prompt.sh — install.sh MUST use the SSH
# (git) protocol for our own repos and MUST NEVER block on an interactive
# GitHub credential prompt.
#
# ─── §11.4.18 documentation block ────────────────────────────────────────────
#
# Purpose:
#   Operator report (2026-09-01): "We cannot install / setup tmx (tmux) on the
#   System! Running our bash script gets stuck asking for GitHub credentials,
#   which MUST NEVER happen! We shall rely only on ssh key (git protocol)."
#
# Root cause (PROVEN, TMX-086):
#   scripts/install.sh injected `-c url.https://github.com/.insteadOf=
#   git@github.com:` BY DEFAULT. Git propagates `-c` to submodule subprocesses
#   via GIT_CONFIG_PARAMETERS, so the rewrite reached every RECURSIVE submodule
#   clone. The constitution submodule nests
#   `submodules/helix_perf_cache -> git@github.com:HelixDevelopment/helix_perf_cache.git`,
#   the ONLY non-anonymously-readable repo of the nine in the tree. Rewritten to
#   HTTPS it cannot be fetched without credentials, so GitHub asks for a
#   Username -- and with no GIT_TERMINAL_PROMPT=0 guard git BLOCKS on that
#   prompt forever. Controlled A/B on the same repo, same host, same minute:
#     SSH as declared ............ exit=0   6adcfb2 refs/heads/main
#     + installer rewrite ........ exit=128 could not read Username
#
# ─── RED_MODE POLARITY (Constitution §11.4.115) ──────────────────────────────
# RED_MODE=1  reproduce-and-assert-DEFECT-PRESENT: build a temp copy of
#             install.sh with the fix REVERTED (rewrite back ON by default) and
#             assert the SSH->HTTPS rewrite IS injected into the real git argv.
#             Demonstrates the defect is real and this test catches it.
# RED_MODE=0  (default) regression GUARD: assert the CURRENT installer injects
#             NO rewrite by default, exports GIT_TERMINAL_PROMPT=0, and defaults
#             TMX_REPO_URL to the SSH form.
#
# Method (offline, deterministic, no network):
#   A `git` shim is placed FIRST on PATH. It records the full argv + the
#   inherited GIT_TERMINAL_PROMPT for every invocation, then execs the real git
#   for everything except `clone` (recorded, then exit 1 so the run stops fast).
#   Asserting on the RECORDED ARGV is runtime evidence that git was actually
#   invoked without the rewrite -- not a grep of the source (§11.4/§11.4.1: a
#   grep-without-runtime PASS is a bluff).
#
# Usage:   bash scripts/tests/90_install_ssh_only_no_credential_prompt.sh
#          RED_MODE=1 bash scripts/tests/90_install_ssh_only_no_credential_prompt.sh
# Inputs:  RED_MODE (0|1, default 0), TMPDIR
# Outputs: PASS:/FAIL:/SKIP: verdict lines at column 0; exit 0 iff FAIL=0
# Deps:    bash, git, sed, grep
# Cross-refs: scripts/install.sh, scripts/tests/69_install_script.sh,
#             docs/scripts/install.md, meta mutation M-INSTALL-SSH-ONLY
# Last verified: 2026-09-01
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
INSTALL="$REPO_ROOT/scripts/install.sh"
RED_MODE="${RED_MODE:-0}"

PASS=0; FAIL=0; SKIP=0
_pass() { echo "PASS: $*"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
_skip() { echo "SKIP: $*"; SKIP=$((SKIP+1)); }
_summary() { echo "  -- Test 90 result: PASS=$PASS FAIL=$FAIL SKIP=$SKIP --"; }

echo "-- Test 90: install.sh SSH-only + never-prompt-for-credentials (RED_MODE=$RED_MODE) --"

SCRATCH="${TMPDIR:-/tmp}"
WORK="$SCRATCH/tmx_t90_$$"
if ! mkdir -p "$WORK" 2>/dev/null; then
    _skip "scratch dir not writable under $SCRATCH (§11.4.3)"
    _summary; exit 0
fi
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT

REAL_GIT="$(command -v git 2>/dev/null)"
if [ -z "$REAL_GIT" ]; then
    _skip "git not on PATH — cannot exercise the installer's git path (§11.4.3)"
    _summary; exit 0
fi
[ -f "$INSTALL" ] || { _fail "scripts/install.sh missing"; _summary; exit 1; }

# ── build the recording git shim ─────────────────────────────────────────────
mkdir -p "$WORK/bin"
cat > "$WORK/bin/git" <<SHIM
#!/usr/bin/env bash
# recording shim: capture argv + EVERY guard export git inherited, then delegate.
printf 'PROMPT=[%s] GITASK=[%s] SSHASK=[%s] SSHCMD=[%s] ARGV=%s\n' \
    "\${GIT_TERMINAL_PROMPT-<unset>}" "\${GIT_ASKPASS-<unset>}" \
    "\${SSH_ASKPASS-<unset>}" "\${GIT_SSH_COMMAND-<unset>}" "\$*" >> "$WORK/git_calls.log"
for a in "\$@"; do
    if [ "\$a" = "clone" ]; then exit 1; fi
done
exec "$REAL_GIT" "\$@"
SHIM
chmod +x "$WORK/bin/git"

# ── drive an installer copy and return its recorded clone argv ───────────────
# NOTE (§11.4.201(7)(c) instrument footgun, caught 2026-09-01): the extractor
# below MUST NOT key on ' clone' with a leading space. When NO -c flags are
# injected the recorded line begins 'ARGV=clone ...' with no preceding space,
# so a ' clone' pattern matches ONLY when the defect is present -- a false
# FAIL on correct code (a §11.4.1 FAIL-bluff). Match the word boundary.
# $1 = installer path to run; echoes the recorded clone line (may be empty).
drive_installer() {
    local inst="$1" tag="$2"; shift 2
    : > "$WORK/git_calls.log"
    # HOSTILE AMBIENT ENV (§11.4.201(6) attributability): every guard is seeded
    # with the WRONG value before the installer runs. A recorded PROMPT=[0] /
    # GITASK=[<unset>] therefore PROVES install.sh actively overrode the ambient
    # value -- it can no longer be satisfied by merely INHERITING a good one.
    # Without this, deleting the guard from install.sh left this test GREEN
    # whenever GIT_TERMINAL_PROMPT=0 happened to be in the environment.
    env GIT_TERMINAL_PROMPT=1 GIT_ASKPASS=/bin/true SSH_ASKPASS=/bin/true \
      "$@" \
      PATH="$WORK/bin:$PATH" \
      TMX_INSTALL_DIR="$WORK/dst_$tag" \
      TMX_INSTALL_NO_SETUP=1 \
      bash "$inst" >"$WORK/out_$tag.txt" 2>&1
    grep -E '(ARGV=|[[:space:]])clone([[:space:]]|$)' "$WORK/git_calls.log" 2>/dev/null | head -1
}

if [ "$RED_MODE" = "1" ]; then
    # ── RED: reconstruct the PRE-FIX installer and prove the defect ──────────
    PREFIX_INST="$WORK/install_prefix.sh"
    sed -e 's|if \[ "\$HTTPS_REWRITE" = "1" \]; then|if [ "$NO_HTTPS_REWRITE" != "1" ]; then|' \
        -e 's|^export GIT_TERMINAL_PROMPT=0$|export GIT_TERMINAL_PROMPT=0  # (kept; rewrite is the defect)|' \
        "$INSTALL" > "$PREFIX_INST"
    if ! grep -q 'NO_HTTPS_REWRITE" != "1"' "$PREFIX_INST"; then
        _fail "R1 could not reconstruct the pre-fix installer — the fix's shape changed; update this test"
    else
        line="$(drive_installer "$PREFIX_INST" red)"
        if [ -z "$line" ]; then
            _fail "R2 pre-fix installer never reached a git clone — cannot reproduce the defect"
        elif echo "$line" | grep -q 'insteadOf=git@github.com:'; then
            _pass "R2 RED: pre-fix installer injected the SSH->HTTPS rewrite into the real git argv — defect reproduced"
        else
            _fail "R2 RED — pre-fix installer did NOT inject the rewrite; defect NOT reproduced (test stale)"
        fi
    fi
else
    line="$(drive_installer "$INSTALL" green)"

    # ── A: the URL git was ACTUALLY given uses the SSH (git) protocol ────────
    # Runtime evidence, not a grep of the source (§11.4.226 evidence-class).
    if [ -z "$line" ]; then
        _fail "A installer never reached a git clone — cannot prove the URL (see $WORK/out_green.txt)"
    elif echo "$line" | grep -q 'git@github\.com:vasic-digital/tmux\.git'; then
        _pass "A git was invoked with the SSH (git protocol) clone URL"
    elif echo "$line" | grep -q 'https://github\.com/'; then
        _fail "A git was invoked with an HTTPS clone URL — operator mandate is ssh-key/git-protocol only"
    else
        _fail "A could not identify the clone URL in the recorded argv: $line"
    fi

    # ── B: no SSH->HTTPS rewrite in the REAL git argv by default ─────────────
    if [ -z "$line" ]; then
        _fail "B installer never reached a git clone — cannot prove the argv (see $WORK/out_green.txt)"
    elif echo "$line" | grep -q 'insteadOf=git@github.com:'; then
        _fail "B TMX-086 regression — installer injected url.https://github.com/.insteadOf into git argv by default; a private nested submodule will hang on a credential prompt"
    else
        _pass "B no SSH->HTTPS rewrite injected into the real git argv by default"
    fi

    # ── C: git can never block on a credential prompt ───────────────────────
    # The installer was driven with GIT_TERMINAL_PROMPT=1 in its environment,
    # so PROMPT=[0] here can ONLY mean install.sh overrode it.
    if [ -z "$line" ]; then
        _skip "C no recorded git invocation to inspect for GIT_TERMINAL_PROMPT (§11.4.3)"
    elif echo "$line" | grep -q 'PROMPT=\[0\]'; then
        _pass "C install.sh overrode ambient GIT_TERMINAL_PROMPT=1 with 0 — a missing credential fails fast, never hangs"
    else
        _fail "C git did NOT inherit GIT_TERMINAL_PROMPT=0 — an HTTPS credential need would BLOCK the installer"
    fi

    # ── E: no askpass helper can substitute for the disabled prompt ──────────
    if [ -z "$line" ]; then
        _skip "E no recorded git invocation to inspect for GIT_ASKPASS (§11.4.3)"
    elif echo "$line" | grep -q 'GITASK=\[<unset>\]'; then
        _pass "E install.sh unset the ambient GIT_ASKPASS helper"
    else
        _fail "E GIT_ASKPASS survived as $(echo "$line" | sed -n 's/.*\(GITASK=\[[^]]*\]\).*/\1/p') — a helper could answer the credential prompt"
    fi

    # ── F: same for the ssh-side askpass helper ──────────────────────────────
    if [ -z "$line" ]; then
        _skip "F no recorded git invocation to inspect for SSH_ASKPASS (§11.4.3)"
    elif echo "$line" | grep -q 'SSHASK=\[<unset>\]'; then
        _pass "F install.sh unset the ambient SSH_ASKPASS helper"
    else
        _fail "F SSH_ASKPASS survived as $(echo "$line" | sed -n 's/.*\(SSHASK=\[[^]]*\]\).*/\1/p') — a GUI helper could hijack the ssh prompt"
    fi

    # ── G: the SSH path cannot hang on a first-contact host key ──────────────
    if [ -z "$line" ]; then
        _skip "G no recorded git invocation to inspect for GIT_SSH_COMMAND (§11.4.3)"
    elif echo "$line" | grep -q 'StrictHostKeyChecking=accept-new'; then
        _pass "G git inherited GIT_SSH_COMMAND with StrictHostKeyChecking=accept-new — a fresh host key cannot block"
    else
        _fail "G GIT_SSH_COMMAND lacks StrictHostKeyChecking=accept-new — a first-contact github host key would BLOCK the installer"
    fi

    # ── H: an operator-set GIT_SSH_COMMAND is never overridden (§11.4.122) ───
    hline="$(drive_installer "$INSTALL" ownssh GIT_SSH_COMMAND='ssh -i /dev/null')"
    if [ -z "$hline" ]; then
        _skip "H opt-in run never reached a git clone (§11.4.3)"
    elif echo "$hline" | grep -q "SSHCMD=\[ssh -i /dev/null\]"; then
        _pass "H operator-set GIT_SSH_COMMAND preserved — installer does not override it"
    else
        _fail "H installer clobbered an operator-set GIT_SSH_COMMAND"
    fi

    # ── D: the keyless opt-in still works (§11.4.122 capability preserved) ───
    optin="$(drive_installer "$INSTALL" optin TMX_INSTALL_HTTPS_REWRITE=1)"
    if [ -z "$optin" ]; then
        _skip "D opt-in run never reached a git clone (§11.4.3)"
    elif echo "$optin" | grep -q 'insteadOf=git@github.com:'; then
        _pass "D TMX_INSTALL_HTTPS_REWRITE=1 still enables the keyless HTTPS rewrite — capability preserved"
    else
        _fail "D TMX_INSTALL_HTTPS_REWRITE=1 did not enable the rewrite — the keyless-user capability was silently removed (§11.4.122)"
    fi
fi

_summary
[ "$FAIL" -eq 0 ]
