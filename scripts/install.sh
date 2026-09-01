#!/usr/bin/env bash
# install.sh — curl-obtainable one-shot installer for the vasic-digital
# optimized + verified hardened tmux build.
#
# ─── §11.4.18 documentation block ────────────────────────────────────────────
#
# Purpose:
#   Modern-CLI-style installer obtainable + triggerable with a single curl
#   command. It clones the whole project (with ALL submodules, fully
#   recursive), runs the build+verify+install pipeline (`scripts/setup.sh`),
#   runs the full validation suite (`scripts/tests/run_all.sh`), and confirms
#   the `tmx` wrapper is wired onto the operator's PATH — so the system is
#   usable ASAP after install. The script is fully SELF-CONTAINED: it makes no
#   assumption that the repository already exists on the host, so it works when
#   piped straight from curl into bash.
#
# Usage (end-user, one-liner):
#   curl -fsSL https://raw.githubusercontent.com/vasic-digital/tmux/main/scripts/install.sh | bash
#
#   With options under the pipe (bash reads the script from stdin, so options
#   go after `-s --`):
#   curl -fsSL <raw-url>/scripts/install.sh | bash -s -- --dir ~/work/tmux
#
#   As a downloaded file:
#   curl -fsSL <raw-url>/scripts/install.sh -o install.sh && bash install.sh
#
# Inputs (all optional; env OR flag — flag wins):
#   TMX_INSTALL_DIR        / --dir DIR    install root (default $HOME/<project>)
#   TMX_REPO_URL           / --repo URL   clone source (default the SSH repo)
#   TMX_INSTALL_BRANCH     / --branch B   branch to clone/track (default main)
#   TMX_INSTALL_NO_SETUP=1 / --clone-only stop after clone+submodules (no build)
#   TMX_INSTALL_DETECT_RC_ONLY=1 / --detect-rc-only  print the shell rc the
#                                         installer would wire PATH into, exit 0
#   TMX_INSTALL_HTTPS_REWRITE=1  / --https-rewrite   OPT IN to the
#                                         git@github→https submodule URL
#                                         rewrite (keyless-clone aid). OFF by
#                                         default since 1.0.44: it breaks the
#                                         PRIVATE nested submodule and hangs
#                                         on a credential prompt (TMX-086).
#   TMX_INSTALL_NO_HTTPS_REWRITE=1 / --no-https-rewrite  legacy explicit
#                                         opt-OUT; still honoured and wins.
#
# Outputs:
#   - The cloned project at $TMX_INSTALL_DIR (with constitution/ + tmux/ +
#     Containers/ submodules populated).
#   - Whatever scripts/setup.sh installs on a GREEN verify: ~/.tmux.conf, the
#     PATH+session snippet appended to the host's shell rc (~/.bashrc and/or
#     ~/.zshrc), and the generated scripts/tmx wrapper on PATH.
#   - Honest phase-by-phase progress on stdout; a non-zero exit on any failure
#     (clone, build, verify, or test) — never a silent green (§11.4).
#
# Side-effects:
#   - Creates / updates $TMX_INSTALL_DIR (git clone or git pull; idempotent).
#   - Delegates host-config writes (~/.tmux.conf + rc snippet) to setup.sh.
#   - Does NOT escalate privilege. Does NOT auto-install build deps under a
#     pipe (§12). If a C toolchain / container engine is missing, setup.sh
#     exits non-zero with guidance and this installer surfaces it.
#   - REFUSES to clobber a non-empty directory that is not our repo (§9.2).
#   - Reads no secrets, prints no secrets, never reads from stdin (§11.4.10,
#     curl|bash safe).
#
# Dependencies: git (required), bash; downstream: scripts/setup.sh's own deps
#   (a container engine OR a C toolchain — see scripts/install_deps.sh, and
#   scripts/obtain_local_deps.sh for the §11.4.77 git-ignored local-dep path).
#
# Cross-references: scripts/setup.sh (build+verify+install), scripts/verify.sh
#   (the gate), scripts/tests/run_all.sh (suite), scripts/obtain_local_deps.sh
#   (§11.4.77 local deps), docs/scripts/install.md (companion guide),
#   scripts/tests/69_install_script.sh (anti-bluff test).
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── never block on an interactive credential prompt (§11.4.1 fail-fast) ──────
# Forensic anchor (2026-09-01): the installer hung forever asking for GitHub
# credentials. Root cause was the SSH->HTTPS rewrite below turning the PRIVATE
# nested submodule git@github.com:HelixDevelopment/helix_perf_cache.git into an
# anonymous HTTPS fetch, which GitHub answers by asking for a Username. With no
# guard, git BLOCKS on that prompt -- and under `curl | bash` there is no sane
# way for the operator to answer it. A missing credential MUST surface as a
# fast, readable error, never as a silent hang: that is the difference between
# an honest FAIL and a §11.4.1 hang-bluff.
#   GIT_TERMINAL_PROMPT=0  -> git errors instead of prompting on the terminal
#   GIT_ASKPASS/SSH_ASKPASS unset -> no GUI/helper prompt substitutes for it
#     (unset, not ="" -- some OpenSSH builds read an EMPTY SSH_ASKPASS as a
#      zero-length program name rather than as "no helper")
# NOTE: this deliberately does NOT set SSH BatchMode -- an ssh KEY PASSPHRASE
# prompt is a legitimate interactive step and is left working (§11.4.122: do
# not remove a capability while fixing something else).
export GIT_TERMINAL_PROMPT=0
unset GIT_ASKPASS SSH_ASKPASS
# SSH is now the default transport, so the SSH path must not hang either.
# A FRESH System has no github.com entry in known_hosts; default ssh then asks
# "Are you sure you want to continue connecting?" and BLOCKS -- which would
# merely trade an HTTPS credential hang for an SSH host-key hang (§11.4.1
# solve-A-create-B). `accept-new` accepts a FIRST-CONTACT key but still REFUSES
# a CHANGED key, so MITM detection on later connects is preserved (plain `no`
# would disable that and is deliberately not used). Deferred to the operator's
# own GIT_SSH_COMMAND when they have set one (§11.4.122).
# A key PASSPHRASE prompt is intentionally still allowed (no BatchMode).
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20}"

# ── canonical project identity ───────────────────────────────────────────────
# Project name per §11.4.29 (lowercase snake_case). The repository directory is
# named `tmux`; the default install root is therefore $HOME/tmux. This is a
# CONSTANT here on purpose: a curl|bash invocation runs standalone (NOT inside
# the repo), so the installer cannot derive the name from its own location.
PROJECT_NAME="tmux"
DEFAULT_REPO_URL="git@github.com:vasic-digital/tmux.git"

# ── configuration (env defaults; flags override below) ───────────────────────
TMX_INSTALL_DIR="${TMX_INSTALL_DIR:-$HOME/$PROJECT_NAME}"
TMX_REPO_URL="${TMX_REPO_URL:-$DEFAULT_REPO_URL}"
TMX_INSTALL_BRANCH="${TMX_INSTALL_BRANCH:-main}"
NO_SETUP="${TMX_INSTALL_NO_SETUP:-}"
DETECT_RC_ONLY="${TMX_INSTALL_DETECT_RC_ONLY:-}"
HTTPS_REWRITE="${TMX_INSTALL_HTTPS_REWRITE:-}"
# Legacy opt-out (pre-1.0.44 default was rewrite-ON). The rewrite is now OFF
# by default, so this variable is accepted and honoured but is a no-op unless
# someone also set TMX_INSTALL_HTTPS_REWRITE=1 -- in which case the explicit
# opt-OUT wins (safest interpretation; never silently enables HTTPS).
NO_HTTPS_REWRITE="${TMX_INSTALL_NO_HTTPS_REWRITE:-}"

# ── arg parsing (NEVER reads stdin — curl|bash keeps the script on stdin) ─────
while [ $# -gt 0 ]; do
    case "$1" in
        --dir)            TMX_INSTALL_DIR="$2"; shift 2 ;;
        --repo)           TMX_REPO_URL="$2"; shift 2 ;;
        --branch)         TMX_INSTALL_BRANCH="$2"; shift 2 ;;
        --clone-only|--no-setup) NO_SETUP=1; shift ;;
        --detect-rc-only) DETECT_RC_ONLY=1; shift ;;
        --no-https-rewrite) NO_HTTPS_REWRITE=1; HTTPS_REWRITE=""; shift ;;
        --https-rewrite)    HTTPS_REWRITE=1;    shift ;;
        --help|-h)
            sed -n '2,/^# ────.*─────$/p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "install.sh: unknown arg '$1' (try --help)" >&2; exit 2 ;;
    esac
done

# ── opt-OUT clamp (applied AFTER arg parsing so it wins in EVERY order) ──────
# The rewrite is OFF by default. An explicit opt-OUT -- env or flag, in any
# position -- always beats an explicit opt-IN. Clamping here rather than before
# the loop makes `--no-https-rewrite --https-rewrite` behave identically to
# `--https-rewrite --no-https-rewrite`: the safe answer, never a silent HTTPS.
[ "$NO_HTTPS_REWRITE" = "1" ] && HTTPS_REWRITE=""

_say()  { printf '%s\n' "[install] $*"; }
_warn() { printf '%s\n' "[install] ⚠ $*" >&2; }
_die()  { printf '%s\n' "[install] ✗ $*" >&2; exit "${2:-1}"; }

# ── shell-rc detection (the file PATH would be wired into) ────────────────────
# Decides which interactive shell rc the host uses, matching how setup.sh wires
# PATH. Priority: the user's $SHELL when its rc exists → else whichever rc file
# actually exists in $HOME → else $SHELL preference, defaulting to bash. This is
# observable (the --detect-rc-only / TMX_INSTALL_DETECT_RC_ONLY seam) so it can
# be unit-tested against a throwaway $HOME without any clone or build.
_detect_login_rc() {
    local sh="${SHELL:-}"
    case "$sh" in
        */zsh)  [ -f "$HOME/.zshrc" ]  && { printf '%s\n' "$HOME/.zshrc";  return 0; } ;;
        */bash) [ -f "$HOME/.bashrc" ] && { printf '%s\n' "$HOME/.bashrc"; return 0; } ;;
    esac
    # $SHELL did not decide (or its rc is absent) — pick by which rc exists.
    if [ -f "$HOME/.zshrc" ]  && [ ! -f "$HOME/.bashrc" ]; then printf '%s\n' "$HOME/.zshrc";  return 0; fi
    if [ -f "$HOME/.bashrc" ] && [ ! -f "$HOME/.zshrc" ];  then printf '%s\n' "$HOME/.bashrc"; return 0; fi
    case "$sh" in
        */zsh) printf '%s\n' "$HOME/.zshrc" ;;
        *)     printf '%s\n' "$HOME/.bashrc" ;;
    esac
}

# ── detect-rc-only seam (no clone, no build) ─────────────────────────────────
if [ "$DETECT_RC_ONLY" = "1" ]; then
    rc="$(_detect_login_rc)"
    case "$rc" in
        *.zshrc)  shell_name="zsh" ;;
        *.bashrc) shell_name="bash" ;;
        *)        shell_name="unknown" ;;
    esac
    _say "shell rc detected: $rc (shell: $shell_name)"
    _say "install root (default): $TMX_INSTALL_DIR"
    exit 0
fi

# ── git config injected into clone + all submodule subprocesses ──────────────
# `-c` flags propagate to submodule git subprocesses via GIT_CONFIG_PARAMETERS,
# so these reach the recursive submodule clones too (verified empirically).
#  • url.https://github.com/.insteadOf=git@github.com:  — lets a keyless user
#    fetch PUBLIC github submodules over HTTPS even though .gitmodules pins SSH.
#    Honest boundary (§11.4.6/§11.4.99): this does NOT grant access to PRIVATE
#    submodules — those still need an SSH key or an HTTPS credential; a private
#    submodule clone failure is surfaced honestly, never faked green.
#  • protocol.file.allow=always — only when TMX_REPO_URL is a file:// mirror
#    (local mirror / the test harness). NOT enabled for network installs.
GITC=()
if [ "$HTTPS_REWRITE" = "1" ]; then
    GITC+=( -c "url.https://github.com/.insteadOf=git@github.com:" )
fi
case "$TMX_REPO_URL" in
    file://*|/*) GITC+=( -c "protocol.file.allow=always" ) ;;
esac

# ── is-this-our-repo fingerprint (project structure, not remote naming) ──────
_is_our_repo() {
    local d="$1"
    [ -e "$d/.git" ] || return 1
    [ -f "$d/scripts/setup.sh" ] || return 1
    [ -f "$d/scripts/tmx.template" ] || return 1
    return 0
}

require_git() {
    command -v git >/dev/null 2>&1 || _die "git not found on PATH. Install git first (Linux: your package manager; macOS: xcode-select --install or brew install git)." 3
}

# ── safe submodule update ─────────────────────────────────────────────────────
# `git submodule update --init --recursive` aborts when a submodule has local
# modifications that the new commit would overwrite. We preserve those changes
# by stashing them, updating, then restoring. This composes with §9.2 (no silent
# data loss) and §11.4.113 (merge-onto-latest-main, no force-push).
_update_submodules_safe() {
    local install_dir="$1"
    if git ${GITC[@]+"${GITC[@]}"} -C "$install_dir" submodule update --init --recursive; then
        return 0
    fi

    _say "submodule update blocked by local changes; stashing, updating, then restoring (§9.2)"
    local stashed=()
    local s
    while IFS= read -r s; do
        [ -n "$s" ] || continue
        local spath="$install_dir/$s"
        if { [ -d "$spath/.git" ] || [ -f "$spath/.git" ]; } \
           && [ -n "$(git -C "$spath" status --porcelain 2>/dev/null)" ]; then
            local stash_msg="[install.sh auto-stash] $s $(date -u +%Y%m%d-%H%M%S)"
            _say "  stashing local changes in $s"
            git -C "$spath" stash push -m "$stash_msg" || _warn "stash failed in $s"
            stashed+=("$s:$stash_msg")
        fi
    done < <(git -C "$install_dir" submodule --quiet foreach 'printf "%s\n" "$sm_path"')

    git ${GITC[@]+"${GITC[@]}"} -C "$install_dir" submodule update --init --recursive \
        || _die "submodule update failed even after stashing local changes"

    # Restore stashes in reverse order (LIFO).
    local i
    for (( i=${#stashed[@]}-1; i>=0; i-- )); do
        local entry="${stashed[$i]}"
        local s="${entry%%:*}"
        local spath="$install_dir/$s"
        _say "  restoring local changes in $s"
        if ! git -C "$spath" stash pop 2>/dev/null; then
            _warn "could not automatically restore stashed changes in $s (stash preserved: ${entry#*:})"
        fi
    done
}

echo "════════════════════════════════════════════════════════════════"
echo "  vasic-digital optimized tmux — curl installer"
echo "════════════════════════════════════════════════════════════════"
_say "install root : $TMX_INSTALL_DIR   (project '$PROJECT_NAME', §11.4.29)"
_say "repo url     : $TMX_REPO_URL"
_say "branch       : $TMX_INSTALL_BRANCH"

# ── PHASE 1 — preflight + clone-target resolution ────────────────────────────
_say "phase 1 — preflight"
require_git
_say "  ✓ git: $(git --version 2>/dev/null)"

MODE="clone"
if [ -e "$TMX_INSTALL_DIR" ]; then
    if _is_our_repo "$TMX_INSTALL_DIR"; then
        MODE="update"
        _say "  ✓ $TMX_INSTALL_DIR is already our repo — will update (git pull), not re-clone (idempotent)"
    elif [ -n "$(ls -A "$TMX_INSTALL_DIR" 2>/dev/null)" ]; then
        # §9.2 — never clobber a non-empty directory that is not ours.
        _die "$TMX_INSTALL_DIR exists, is non-empty, and is NOT a vasic-digital tmux checkout.
        Refusing to clobber it (§9.2 absolute data safety).
        Choose another location with TMX_INSTALL_DIR=… (or --dir …), or remove it yourself." 4
    else
        _say "  ✓ $TMX_INSTALL_DIR exists but is empty — will clone into it"
    fi
else
    _say "  ✓ $TMX_INSTALL_DIR does not exist — will clone"
fi

# ── PHASE 2 — clone (or update) recursively ──────────────────────────────────
_say "phase 2 — obtain sources (recursive submodules)"
if [ "$MODE" = "update" ]; then
    git ${GITC[@]+"${GITC[@]}"} -C "$TMX_INSTALL_DIR" fetch --all --prune --tags
    # Fast-forward only — never rewrite local history (§11.4.113 / §9).
    git ${GITC[@]+"${GITC[@]}"} -C "$TMX_INSTALL_DIR" pull --ff-only origin "$TMX_INSTALL_BRANCH" \
        || git ${GITC[@]+"${GITC[@]}"} -C "$TMX_INSTALL_DIR" pull --ff-only \
        || _warn "git pull --ff-only could not fast-forward (local diverged?) — keeping local state, continuing"
    _update_submodules_safe "$TMX_INSTALL_DIR"
    _say "  ✓ updated + submodules refreshed"
else
    # mkdir -p so a clone into ~/Projects/<deep>/tmux works; git clone needs the
    # leaf to be absent or empty (handled in phase 1).
    mkdir -p "$(dirname "$TMX_INSTALL_DIR")"
    git ${GITC[@]+"${GITC[@]}"} clone --recurse-submodules --branch "$TMX_INSTALL_BRANCH" \
        "$TMX_REPO_URL" "$TMX_INSTALL_DIR" \
        || git ${GITC[@]+"${GITC[@]}"} clone --recurse-submodules \
             "$TMX_REPO_URL" "$TMX_INSTALL_DIR"
    # Belt-and-suspenders recursive init (idempotent after --recurse-submodules).
    _update_submodules_safe "$TMX_INSTALL_DIR"
    _say "  ✓ cloned + submodules initialised"
fi

# Positive evidence the recursive clone landed the governance submodule.
if [ -f "$TMX_INSTALL_DIR/constitution/Constitution.md" ]; then
    _say "  ✓ constitution/ submodule present (Constitution.md)"
else
    _warn "constitution/ submodule NOT populated — a private submodule may need an SSH key or HTTPS credential (§11.4.6: not faking success)"
fi
if ! _is_our_repo "$TMX_INSTALL_DIR"; then
    _die "post-clone fingerprint check failed: $TMX_INSTALL_DIR is missing scripts/setup.sh or scripts/tmx.template" 4
fi

# ── clone-only seam (test + local-mirror; no build, no host-config writes) ───
if [ "$NO_SETUP" = "1" ]; then
    rc="$(_detect_login_rc)"
    _say "phase 2 complete — TMX_INSTALL_NO_SETUP=1: stopping before build/verify/install"
    _say "  sources ready at $TMX_INSTALL_DIR"
    _say "  PATH would be wired into: $rc"
    _say "  Run the full pipeline yourself with:  cd \"$TMX_INSTALL_DIR\" && bash scripts/setup.sh"
    exit 0
fi

# ── PHASE 3 — build + verify + install (setup.sh; gated PATH export) ─────────
_say "phase 3 — build + verify + install (scripts/setup.sh)"
setup_rc=0
( cd "$TMX_INSTALL_DIR" && bash scripts/setup.sh ) || setup_rc=$?
if [ "$setup_rc" -ne 0 ]; then
    _die "scripts/setup.sh exited $setup_rc — build/verify/install did NOT complete.
        Common causes: missing build deps (Linux: run scripts/install_deps.sh as root;
        macOS: brew install podman/jemalloc), or a verification RED (§11.4: we do
        NOT expose unverified binaries). See the setup output above. NOT faking green." "$setup_rc"
fi
_say "  ✓ setup.sh completed (build + verify GREEN + host config installed)"

# ── PHASE 4 — full validation suite ──────────────────────────────────────────
_say "phase 4 — full validation suite (scripts/tests/run_all.sh)"
test_rc=0
( cd "$TMX_INSTALL_DIR" && bash scripts/tests/run_all.sh ) || test_rc=$?
if [ "$test_rc" -ne 0 ]; then
    _warn "run_all.sh reported FAIL(s) (exit $test_rc) — surfacing honestly; see the SUMMARY line above"
else
    _say "  ✓ validation suite GREEN"
fi

# ── PHASE 5 — confirm PATH wiring ─────────────────────────────────────────────
_say "phase 5 — confirm tmx is wired onto PATH"
WIRED_RC=""
for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.profile"; do
    [ -f "$rc" ] || continue
    if grep -q '─── vasic-digital optimized tmux' "$rc" 2>/dev/null; then
        WIRED_RC="$WIRED_RC $rc"
    fi
done
if [ -n "$WIRED_RC" ]; then
    _say "  ✓ PATH+session snippet wired into:$WIRED_RC"
else
    _warn "no shell rc carries the snippet — setup.sh may have skipped PATH export (verify RED?). Check the phase-3 output."
fi
WRAPPER="$TMX_INSTALL_DIR/scripts/tmx"
if command -v tmx >/dev/null 2>&1; then
    _say "  ✓ 'tmx' resolves on this shell's PATH: $(command -v tmx)"
elif [ -x "$WRAPPER" ]; then
    _say "  ✓ wrapper generated at $WRAPPER (not yet on THIS shell's PATH — source your rc / open a new terminal)"
else
    _warn "tmx wrapper not found at $WRAPPER — setup.sh did not generate it (see phase-3 output)"
fi

# ── PHASE 6 — final summary ──────────────────────────────────────────────────
echo "════════════════════════════════════════════════════════════════"
_say "install root: $TMX_INSTALL_DIR"
case "$(_detect_login_rc)" in
    *.zshrc)  _say "next step: source ~/.zshrc   (or open a new terminal)" ;;
    *)        _say "next step: source ~/.bashrc  (or open a new terminal)" ;;
esac
_say "then use:  tmx new -s <name> | tmx attach | tmx ls | tmx kill"
echo "════════════════════════════════════════════════════════════════"

# Honest exit: non-zero if the validation suite failed (§11.4 — never a silent
# green when tests FAIL). Setup-phase failures already exited non-zero above.
exit "$test_rc"
