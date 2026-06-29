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
#   TMX_REPO_URL           / --repo URL   clone source (default the HTTPS repo)
#   TMX_INSTALL_BRANCH     / --branch B   branch to clone/track (default main)
#   TMX_INSTALL_NO_SETUP=1 / --clone-only stop after clone+submodules (no build)
#   TMX_INSTALL_DETECT_RC_ONLY=1 / --detect-rc-only  print the shell rc the
#                                         installer would wire PATH into, exit 0
#   TMX_INSTALL_NO_HTTPS_REWRITE=1        disable git@github→https submodule
#                                         URL rewrite (keyless-clone aid)
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
#   - Does NOT sudo. Does NOT auto-install build deps under a pipe (§12). If a
#     C toolchain / container engine is missing, setup.sh exits non-zero with
#     guidance and this installer surfaces it.
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

# ── canonical project identity ───────────────────────────────────────────────
# Project name per §11.4.29 (lowercase snake_case). The repository directory is
# named `tmux`; the default install root is therefore $HOME/tmux. This is a
# CONSTANT here on purpose: a curl|bash invocation runs standalone (NOT inside
# the repo), so the installer cannot derive the name from its own location.
PROJECT_NAME="tmux"
DEFAULT_REPO_URL="https://github.com/vasic-digital/tmux.git"

# ── configuration (env defaults; flags override below) ───────────────────────
TMX_INSTALL_DIR="${TMX_INSTALL_DIR:-$HOME/$PROJECT_NAME}"
TMX_REPO_URL="${TMX_REPO_URL:-$DEFAULT_REPO_URL}"
TMX_INSTALL_BRANCH="${TMX_INSTALL_BRANCH:-main}"
NO_SETUP="${TMX_INSTALL_NO_SETUP:-}"
DETECT_RC_ONLY="${TMX_INSTALL_DETECT_RC_ONLY:-}"
NO_HTTPS_REWRITE="${TMX_INSTALL_NO_HTTPS_REWRITE:-}"

# ── arg parsing (NEVER reads stdin — curl|bash keeps the script on stdin) ─────
while [ $# -gt 0 ]; do
    case "$1" in
        --dir)            TMX_INSTALL_DIR="$2"; shift 2 ;;
        --repo)           TMX_REPO_URL="$2"; shift 2 ;;
        --branch)         TMX_INSTALL_BRANCH="$2"; shift 2 ;;
        --clone-only|--no-setup) NO_SETUP=1; shift ;;
        --detect-rc-only) DETECT_RC_ONLY=1; shift ;;
        --no-https-rewrite) NO_HTTPS_REWRITE=1; shift ;;
        --help|-h)
            sed -n '2,/^# ────.*─────$/p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "install.sh: unknown arg '$1' (try --help)" >&2; exit 2 ;;
    esac
done

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
if [ "$NO_HTTPS_REWRITE" != "1" ]; then
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
    git ${GITC[@]+"${GITC[@]}"} -C "$TMX_INSTALL_DIR" submodule update --init --recursive
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
    git ${GITC[@]+"${GITC[@]}"} -C "$TMX_INSTALL_DIR" submodule update --init --recursive
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
        Common causes: missing build deps (Linux: sudo bash scripts/install_deps.sh;
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
