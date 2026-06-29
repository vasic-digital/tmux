#!/usr/bin/env bash
# setup.sh — ONE-COMMAND orchestrator for the vasic-digital optimized tmux
# build & install.
#
# Pipeline (each step gated on the previous):
#   1. Verify container engine (podman or docker) + host libjemalloc.so visible
#      (libjemalloc-dev recommended — install via `bash scripts/install_deps.sh` as root)
#   2. Containerized build (podman/docker, isolated cgroup, mem_limit=2g)
#   3. Generate tmx wrapper (LD_PRELOAD=jemalloc + oom_score_adj=-500)
#   4. Run verification gate (verify.sh — full 14-test suite)
#   5. ONLY IF GREEN: install ~/.tmux.conf + .bashrc snippet + PATH export
#
# §11.4 invariant: step 5 is GATED by step 4. Failing tests means no PATH export.
# §12.9 invariant: step 2 runs in an isolated container cgroup (host insulated).
#
# Usage: bash scripts/setup.sh             — full pipeline
#        bash scripts/setup.sh --uninstall — remove .bashrc snippet + ~/.tmux.conf
#        bash scripts/setup.sh --rebuild   — force re-run of containerized build
#        bash scripts/setup.sh --build-only — stop after step 2 (no install)
#        bash scripts/setup.sh --verify-only — stop after step 4 (no install)

set -euo pipefail

# ${BASH_SOURCE[0]} resolves correctly whether setup.sh is EXECUTED
# (`bash scripts/setup.sh`) or SOURCED in library mode (TMX_SETUP_LIB_ONLY=1,
# used by scripts/tests/70_native_fallback_cc_link.sh) — `$0` would be the
# sourcing shell's name when sourced, mis-resolving REPO_ROOT.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
cd "$REPO_ROOT"

# Consent for the native-build auto-install of a missing C toolchain (below).
#   1     → auto-install WHEN ALREADY ROOT (explicit opt-in); never escalates
#   0     → never auto-install (always the honest "re-run as root" message)
#   auto  → auto-install when ALREADY root, else honest "re-run as root" message
#           (NON-interactive, NEVER escalates privilege itself; operator mandate
#           2026-06-29; no surprise mutation in CI / non-root shells;
#           §11.4.101/§11.4.66)
# The --install-deps flag (parsed below) forces 1.
AUTO_INSTALL_DEPS="${TMX_AUTO_INSTALL_DEPS:-auto}"

# ── native-build C-toolchain preflight (§11.4.6 honest + §11.4.81 + auto-install)
# A host can have gcc/cc present yet be UNABLE to LINK an executable when the
# C-runtime dev objects are missing (crt*.o / libc dev — no glibc-devel /
# libc6-dev on Linux, no Xcode CLT on macOS). `./configure` would then die with
# the CRYPTIC "C compiler cannot create executables", naming neither cause nor
# fix. cc_can_link compiles+links a trivial program FIRST, and the native-build
# entry (_native_build_preflight) fronts build_native.sh with it — so the
# operator gets an HONEST, actionable outcome and, consent-gated, an AUTOMATIC
# install of the missing toolchain via scripts/install_deps.sh instead of the
# bare autoconf death. Forensic anchor: base ALT host, rootless-podman
# /etc/subuid+subgid exhaustion → native fallback on a gcc-but-no-glibc-devel
# host, 2026-06-29 (§11.4.6 / §11.4.123 / §11.4.138 operator-escape).
CC_LINK_LOG=""

_resolve_cc() {
    if [ -n "${CC:-}" ]; then printf '%s' "$CC"; return 0; fi
    for _c in cc gcc clang; do
        command -v "$_c" >/dev/null 2>&1 && { printf '%s' "$_c"; return 0; }
    done
    return 1
}

# Returns 0 iff the resolved C compiler can compile AND LINK a trivial exe.
# Honest boundary (§11.4.6): if the probe itself cannot run (no writable temp
# dir under $TMPDIR) we say so EXPLICITLY and do NOT silently claim "can link".
# We then proceed (return 0) — a host with no writable temp dir has bigger
# problems the build will surface — but the printed note means it is never a
# SILENT fail-open (code-review warning, 2026-06-29).
cc_can_link() {
    _cc="$(_resolve_cc)" || return 1
    _td="$(mktemp -d "${TMPDIR:-/tmp}/tmx_ccprobe.XXXXXX" 2>/dev/null)" || {
        echo "[setup] cc_can_link: no writable temp dir under ${TMPDIR:-/tmp} — link probe SKIPPED (NOT verified)." >&2
        return 0
    }
    printf 'int main(void){return 0;}\n' > "$_td/t.c"
    if "$_cc" "$_td/t.c" -o "$_td/t" >"$_td/log" 2>&1 && [ -x "$_td/t" ]; then
        rm -rf "$_td"; return 0
    fi
    CC_LINK_LOG="$(cat "$_td/log" 2>/dev/null)"
    rm -rf "$_td"; return 1
}

# The exact manual install command for this host (honest fallback, §11.4.6).
_toolchain_manual_cmd() {
    case "$(uname -s)" in
        Darwin) echo "xcode-select --install   # Xcode Command Line Tools (clang + SDK libc/linker)" ;;
        Linux)
            _id=""
            [ -r /etc/os-release ] && _id="$(. /etc/os-release 2>/dev/null; echo "${ID:-}")"
            case "$_id" in
                altlinux|alt) echo "bash scripts/install_deps.sh   (as root)   # ALT — installs gcc glibc-devel make libevent-devel libncursesw-devel autoconf automake pkg-config bison flex" ;;
                debian|ubuntu|linuxmint|raspbian|pop|neon) echo "bash scripts/install_deps.sh   (as root)   # build-essential libevent-dev libncurses-dev autoconf automake pkg-config bison flex" ;;
                fedora|rhel|centos|rocky|almalinux|amzn) echo "bash scripts/install_deps.sh   (as root)   # gcc glibc-devel make libevent-devel ncurses-devel autoconf automake pkgconf-pkg-config bison flex" ;;
                *) echo "bash scripts/install_deps.sh   (as root)   # your distro's C compiler + libc dev + make + libevent/ncurses headers + autoconf/automake/pkg-config/bison/flex" ;;
            esac
            ;;
        *) echo "install your platform's C toolchain (compiler + libc dev + linker) + build deps" ;;
    esac
}

# Emit the honest, actionable diagnosis (§11.4.6) — replaces the cryptic death.
_emit_toolchain_help() {
    echo "" >&2
    echo "[setup] ✗ NATIVE BUILD PREREQUISITE MISSING — the C compiler is present" >&2
    echo "        but cannot LINK an executable (missing C-runtime dev objects:" >&2
    echo "        crt*.o / libc dev — e.g. glibc-devel / libc6-dev, or no Xcode CLT)." >&2
    echo "        Autoconf would otherwise abort with the cryptic:" >&2
    echo "            configure: error: C compiler cannot create executables" >&2
    if [ -n "${CC_LINK_LOG:-}" ]; then
        echo "        compiler said:" >&2
        printf '          %s\n' "$CC_LINK_LOG" | head -4 >&2
    fi
    echo "" >&2
    echo "  Fix — install the build toolchain:" >&2
    echo "      $(_toolchain_manual_cmd)" >&2
    echo "  Then re-run: bash scripts/setup.sh" >&2
    echo "  (or re-run with TMX_AUTO_INSTALL_DEPS=1 / --install-deps to auto-install)" >&2
    echo "" >&2
}

# Privileged install possible? ONLY when ALREADY running as root. We NEVER
# escalate privilege ourselves (operator mandate 2026-06-29: no privilege
# escalation in automation scripts/tests). Non-root → no privileged install;
# the honest "re-run as root" message is emitted instead.
_can_elevate() {
    [ "$(id -u)" = "0" ]
}

# Run install_deps.sh --toolchain-only — ONLY when ALREADY root. This NEVER
# escalates privilege itself (operator mandate 2026-06-29). When not root it
# returns 1 and the caller emits the honest "re-run as root" message via
# _emit_toolchain_help — no escalation, no prompt, no human wait.
_run_install_deps() {
    _ids="$REPO_ROOT/scripts/install_deps.sh"
    [ -f "$_ids" ] || { echo "[setup] ⚠ scripts/install_deps.sh missing — cannot auto-install" >&2; return 1; }
    if [ "$(id -u)" = "0" ]; then
        bash "$_ids" --toolchain-only
    else
        return 1
    fi
}

# ROOT-FREE C toolchain readiness (TMX-063). Returns 0 iff an OBTAINED zig
# toolchain (CC_KIND=zig in resolved.env) is present AND its flag-filter `cc`
# wrapper can LINK a trivial exe. This is the no-privilege path: a host with no
# working host compiler builds via the obtained zig instead of needing root.
# §11.4.6: link-probe the real wrapper — never assume "obtained ⇒ works".
_rootfree_toolchain_ready() {
    _renv="${LOCAL_DEPS_ROOT:-$REPO_ROOT/.local-deps}/$(uname -s)_$(uname -m)/resolved.env"
    [ -f "$_renv" ] || return 1
    _ck="$(sed -n 's/^CC_KIND=//p' "$_renv" 2>/dev/null | head -1)"
    _cw="$(sed -n 's/^CC_WRAPPER_DIR=//p' "$_renv" 2>/dev/null | head -1)"
    [ "$_ck" = "zig" ] || return 1
    [ -n "$_cw" ] && [ -x "$_cw/cc" ] || return 1
    _td="$(mktemp -d "${TMPDIR:-/tmp}/tmxzig.XXXXXX" 2>/dev/null)" || return 1
    printf 'int main(void){return 0;}\n' > "$_td/t.c"
    if "$_cw/cc" "$_td/t.c" -o "$_td/t" >/dev/null 2>&1 && [ -x "$_td/t" ]; then
        rm -rf "$_td"; return 0
    fi
    rm -rf "$_td"; return 1
}

# The native-build entry gate. Returns 0 when the toolchain can link (proceed);
# non-zero (after emitting honest help) when it cannot and was not auto-fixed.
# Composes §11.4.101 (safe reversible auto-decision) + §11.4.66 (interactive
# consent) + §11.4.122-spirit (no surprise privileged mutation without consent).
_native_build_preflight() {
    if cc_can_link; then return 0; fi

    # ── ROOT-FREE path FIRST (TMX-063) ───────────────────────────────────────
    # Before any privileged-install advice, try the obtained zig toolchain. If a
    # working obtained zig is already present (Step 1b obtains `cc`), proceed with
    # NO root. If not yet obtained, OBTAIN it now (root-free, non-interactive) and
    # re-check. Only if THAT fails do we fall through to the honest "re-run as
    # root" message — so the install-as-root path is the LAST resort, not the
    # first. §11.4.101 safe/reversible autonomous decision; §11.4.123 link-proven.
    # Skipped under TMX_SETUP_LIB_ONLY (the §11.4.115 lib-mode harness, test 70):
    # the root-free path is covered by the REAL test 71, so lib-mode keeps testing
    # the install/honest path in isolation, independent of any .local-deps state.
    if [ "${TMX_SETUP_LIB_ONLY:-}" != "1" ]; then
        if _rootfree_toolchain_ready; then
            echo "[setup] ✓ host C compiler cannot link — using OBTAINED root-free toolchain (zig). No root needed." >&2
            return 0
        fi
        echo "[setup] host C compiler cannot link — obtaining a ROOT-FREE toolchain (zig) before any root advice…" >&2
        DEPS=cc bash "$REPO_ROOT/scripts/obtain_local_deps.sh" 1>&2 || true
        if _rootfree_toolchain_ready; then
            echo "[setup] ✓ obtained root-free C toolchain (zig) that links — proceeding without root." >&2
            return 0
        fi
    fi

    echo "[setup] native build preflight: C compiler cannot link an executable." >&2

    _consent="${AUTO_INSTALL_DEPS:-auto}"; _do_install=0
    case "$_consent" in
        1) _do_install=1 ;;
        0) _do_install=0 ;;
        *)
            # DEFAULT (auto) — operator mandate 2026-06-29: setup solves deps
            # automatically for all users, NON-INTERACTIVELY, with NO privilege
            # escalation and NO prompt. When already root we auto-install;
            # otherwise we emit the honest message (re-run as root) — we NEVER
            # escalate privilege ourselves. install_deps.sh is install-only
            # (§11.4.122) + idempotent
            # + honest-on-failure; §11.4.101 reversible; §12 host-safety (a CI run
            # never blocks on a password/consent prompt).
            if [ "$(id -u)" = "0" ]; then
                echo "[setup] auto-installing the missing build toolchain (set TMX_AUTO_INSTALL_DEPS=0 to opt out)…" >&2
                _do_install=1
            else
                _do_install=0
            fi
            ;;
    esac

    if [ "$_do_install" = "1" ] && _can_elevate; then
        echo "[setup] auto-installing build toolchain (scripts/install_deps.sh --toolchain-only)…" >&2
        if _run_install_deps; then
            if cc_can_link; then
                echo "[setup] ✓ toolchain installed — C compiler can now link. Proceeding." >&2
                return 0
            fi
            echo "[setup] ✗ toolchain install ran but the compiler STILL cannot link." >&2
        else
            echo "[setup] ✗ auto-install could not run (privilege / package-manager / script absent)." >&2
        fi
        _emit_toolchain_help
        return 1
    fi

    [ "$_do_install" = "1" ] && echo "[setup] auto-install requested but not running as root — re-run as root to install." >&2
    _emit_toolchain_help
    return 1
}

# Library mode: the regression test (scripts/tests/70_native_fallback_cc_link.sh)
# sources this file with TMX_SETUP_LIB_ONLY=1 to exercise cc_can_link /
# _native_build_preflight in isolation, WITHOUT running the install pipeline.
if [ "${TMX_SETUP_LIB_ONLY:-}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

# Augment PATH from npm's reported prefix so tests + codegraph_reindex.sh
# resolve `codegraph` even when setup.sh is invoked from a non-interactive
# shell (SSH-batch, cron, CI) that didn't source .bashrc / .zshrc and
# therefore lacks the user's npm-global/bin entry. Nezha fix 2026-05-21.
# Idempotent: if codegraph is already on PATH, the npm probe is a no-op.
if ! command -v codegraph >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    NPM_PREFIX="$(npm config get prefix 2>/dev/null | tr -d '\r\n' || true)"
    if [ -n "$NPM_PREFIX" ] && [ -x "${NPM_PREFIX}/bin/codegraph" ]; then
        export PATH="${NPM_PREFIX}/bin:$PATH"
        echo "[setup] PATH augmented with ${NPM_PREFIX}/bin (codegraph resolved)"
    fi
fi

# ── arg parsing ─────────────────────────────────────────────────────────────
MODE="install"
while [ $# -gt 0 ]; do
    case "$1" in
        --uninstall)   MODE="uninstall" ;;
        --rebuild)     MODE="rebuild" ;;
        --build-only)  MODE="build-only" ;;
        --verify-only) MODE="verify-only" ;;
        --install-deps) AUTO_INSTALL_DEPS=1 ;;
        --help|-h)
            sed -n '1,/^# Usage/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown arg: $1"; exit 2 ;;
    esac
    shift
done

# Portable in-place range delete between two marker lines.
# `sed -i` works differently on GNU (Linux) and BSD (macOS) — the BSD form
# requires `-i ''`. Using perl avoids the divergence; flip-flop `..` matches
# lines between the start and end markers inclusive, and `print unless` keeps
# everything outside that range. This is the only operation that touches
# the operator's ~/.bashrc directly.
_strip_bashrc_snippet() {
    local file="$1"
    [ -f "$file" ] || return 0
    # Strip the FENCED block (the standard install).
    perl -i -ne 'print unless /^# ─── vasic-digital optimized tmux/ .. /^# ─── end vasic-digital optimized tmux/' "$file"
    # §11.4 anti-bluff cleanup (User mandate 2026-05-22): also strip the
    # LEGACY UNFENCED pre-v1.0.9 inline snippet. Operators who hand-pasted
    # the original snippet into their rc files keep it OUTSIDE our fenced
    # block; a subsequent setup.sh install would leave BOTH in place,
    # causing tmx to fire TWICE on every interactive login (one from the
    # legacy snippet, one from `tmx-shell-init.sh` sourced by the new
    # snippet). The block's well-known shape: an `if command -v tmx ...
    # [ -z "$TMUX" ]` open, an `Enter session name` prompt + read, and a
    # `tmx attach ... || tmx new ...` close. We match the entire block
    # as a multi-line literal to avoid stripping unrelated `tmx`
    # references operators may have written for their own reasons.
    python3 - "$file" <<'PYEOF'
import re, sys
p = sys.argv[1]
src = open(p).read()
# Pattern: opening if-line through `fi` closing after `tmx attach ...
# || tmx new ...`. DOTALL to span newlines; non-greedy to stop at the
# FIRST matching `fi`. Allows blank-line padding around the block.
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
}

# ── uninstall logic (callable from both --uninstall mode AND from install
# mode as a pre-clean-slate step) ───────────────────────────────────────────
#
# Honours `quiet=$1` first arg: when non-empty, suppress per-step echo
# (used by install path so the "cleaning previous install" pre-step
# doesn't add noise unless something was actually removed).
#
# Per User mandate (2026-05-22, post-v1.0.10): "create uninstall script
# which will be removing installation from the path and added link to
# tmx bash script(s) for session(s) init work. It MUST create state
# clean! Maybe we can call this uninstall bas script from install
# script to create clean slate before updating anything!"
_do_uninstall() {
    local quiet="${1:-}"
    local removed=0
    # NOTE: must always return 0 to play well with `set -e` even when quiet
    # short-circuits the `[ -z ]` test.
    _echo() { if [ -z "$quiet" ]; then echo "$@"; fi; return 0; }

    # 1. Strip the FENCED v1.0.9+ block + any LEGACY pre-v1.0.9 inline
    #    snippet from .bashrc / .zshrc (whichever exist).
    # v1.0.13 — also clean .bash_profile / .profile in case prior install
    # added the snippet there (bash login shells read those, not .bashrc).
    for rc in ~/.bashrc ~/.bash_profile ~/.profile ~/.zshrc; do
        if [ -f "$rc" ] && grep -q '─── vasic-digital optimized tmux\|if command -v tmx' "$rc" 2>/dev/null; then
            _strip_bashrc_snippet "$rc"
            _echo "  ✓ removed snippet from $rc"
            removed=$((removed+1))
        fi
    done

    # 2. Remove our generated ~/.tmux.conf.
    if [ -f ~/.tmux.conf ] && grep -q 'vasic-digital optimized tmux configuration' ~/.tmux.conf 2>/dev/null; then
        rm -f ~/.tmux.conf
        _echo "  ✓ removed ~/.tmux.conf (was generated by setup.sh)"
        removed=$((removed+1))
    fi

    # 3. Remove generated scripts (NEVER tracked in git per §11.4.30):
    #    scripts/tmx (wrapper), scripts/tmx-shell-init.sh (shell init —
    #    v1.0.9+), scripts/tmx-state-bin (Go binary — v1.0.9+).
    for gen in scripts/tmx scripts/tmx-shell-init.sh scripts/tmx-state-bin; do
        if [ -e "$gen" ]; then
            rm -f "$gen"
            _echo "  ✓ removed $gen"
            removed=$((removed+1))
        fi
    done

    # 4. ~/.tmx/ state directory: contains last-pwd records. This is
    #    USER DATA per §9 zero-risk-data-safety — DO NOT remove unless
    #    --purge-state was passed. The presence-not-removal default
    #    preserves operator workflow continuity across re-installs.
    if [ -n "${PURGE_STATE:-}" ] && [ -d ~/.tmx ]; then
        rm -rf ~/.tmx
        _echo "  ✓ removed ~/.tmx/ (per-session last-pwd state — PURGE_STATE=1)"
        removed=$((removed+1))
    elif [ -d ~/.tmx ]; then
        _echo "  ⓘ ~/.tmx/ preserved (operator data per §9 zero-risk; PURGE_STATE=1 to remove)"
    fi

    # 5. tmux/build/ — kept by default (large; rebuild costs time).
    _echo "  ⓘ tmux/build*/ kept; remove with 'rm -rf tmux/build*' if desired"

    if [ -z "$quiet" ] && [ "$removed" -gt 0 ]; then
        echo "[setup] uninstall removed $removed artefact(s)"
    fi
    return 0
}

# ── uninstall path (--uninstall) ────────────────────────────────────────────
if [ "$MODE" = "uninstall" ]; then
    echo "[setup] uninstalling…"
    _do_uninstall
    exit 0
fi

# ── installation pipeline (NATIVE dual-OS per docs/plans/native-dual-os.md) ──

# Step 0 — clean slate. Per User mandate (2026-05-22): "Maybe we can call
# this uninstall bas script from install script to create clean slate
# before updating anything!" — call uninstall logic FIRST so stale
# generated artefacts (old wrapper, missing init.sh, half-installed
# bashrc block) do not poison this run. Run silently (quiet=1) and only
# report when removed > 0 to avoid noise on a truly first-time install.
# Operator data under ~/.tmx is preserved (see PURGE_STATE in _do_uninstall).
echo "[setup] step 0 — clean slate (remove any prior generated artefacts before reinstall)"
_do_uninstall quiet
echo "  ✓ pre-install cleanup pass complete"
echo ""

HOST_OS="$(uname -s)"

# Step 1 — host capability check
echo "[setup] step 1 — host capability check ($HOST_OS)"
case "$HOST_OS" in
    Darwin)
        # Resolve brew by ABSOLUTE path (§11.4.111) — `command -v brew` FAILS
        # under a non-interactive SSH PATH that lacks /opt/homebrew/bin, which
        # made this Step-1 gate hard-`exit 3` BEFORE Step-1b's resolver ever ran
        # (forensic: mistborn.local clean-target validation, 2026-06-28; TMX-064
        # follow-up). Check the canonical Homebrew install locations first, then
        # PATH as a last resort; then prepend brew's bin to PATH so brew + its
        # installed tools resolve for the rest of this run (non-interactive
        # shells don't get `brew shellenv`). §11.4.108: source-green ≠
        # runtime-works — this is the runtime wiring the host run exposed.
        BREW=""
        for _b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
            [ -x "$_b" ] && { BREW="$_b"; break; }
        done
        [ -z "$BREW" ] && BREW="$(command -v brew 2>/dev/null || true)"
        if [ -z "$BREW" ]; then
            echo "  ✗ Homebrew not installed. Install via:"
            echo "    /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
            exit 3
        fi
        export PATH="$(dirname "$BREW"):$PATH"
        echo "  ✓ Homebrew @ $("$BREW" --prefix)"
        JEMALLOC_DYLIB="$("$BREW" --prefix jemalloc 2>/dev/null)/lib/libjemalloc.dylib"
        if [ -f "$JEMALLOC_DYLIB" ]; then
            JEMALLOC="$JEMALLOC_DYLIB"
            echo "  ✓ jemalloc @ $JEMALLOC"
        else
            JEMALLOC=""
            echo "  ⓘ jemalloc not yet installed — build_native.sh will install it"
        fi
        ;;
    Linux)
        ENGINE=""
        if command -v podman >/dev/null 2>&1; then
            ENGINE="podman"
        elif command -v docker >/dev/null 2>&1; then
            ENGINE="docker"
        fi
        if [ -z "$ENGINE" ] && [ ! -x "$REPO_ROOT/tmux/build/bin/tmux" ]; then
            echo "  ✗ neither podman nor docker installed AND no native build present."
            echo "    Either install a container engine, or install libevent-dev + libjemalloc-dev + build-essential and use build_native.sh."
            exit 3
        fi
        [ -n "$ENGINE" ] && echo "  ✓ container engine: $ENGINE"
        JEMALLOC=""
        for _C in ldconfig /sbin/ldconfig /usr/sbin/ldconfig; do
            command -v "$_C" >/dev/null 2>&1 || continue
            JEMALLOC=$("$_C" -p 2>/dev/null | awk '/libjemalloc\.so\.[0-9]/ {print $NF; exit}' || true)
            [ -n "$JEMALLOC" ] && break
        done
        if [ -z "$JEMALLOC" ]; then
            echo "  ⚠ host libjemalloc.so not visible — wrapper LD_PRELOAD will be inert"
        else
            echo "  ✓ host libjemalloc: $JEMALLOC"
        fi
        ;;
    *)
        echo "  ✗ unsupported OS '$HOST_OS'. Supported: Darwin, Linux."
        exit 3
        ;;
esac

# Step 1b — obtain/resolve LOCAL dependencies (jemalloc) out-of-the-box.
# §11.4.77 regen mechanism + §11.4.111 resolve-by-absolute-path. The
# obtain script (scripts/obtain_local_deps.sh) RESOLVES an already-present
# jemalloc by absolute path, or OBTAINS it git-ignored into .local-deps/
# when genuinely missing, then writes a sourceable resolved.env exporting
# JEMALLOC_SO (ABSOLUTE), JEMALLOC_LIBDIR, JEMALLOC_SOURCE. We consume
# those downstream for: Step 2b patchelf rpath (DT_NEEDED resolution at
# runtime) + Step 3 wrapper LD_PRELOAD/LD_LIBRARY_PATH (LD_PRELOAD ignores
# rpath → MUST be the absolute path; docs/research/local_deps_20260628).
echo ""
echo "[setup] step 1b — obtain/resolve local dependencies (cc + jemalloc + libevent + ncurses + go)"
JEMALLOC_SO=""
JEMALLOC_LIBDIR=""
JEMALLOC_SOURCE=""
LOCAL_DEPS_PREFIX=""
RESOLVED_ENV="$REPO_ROOT/.local-deps/$(uname -s)_$(uname -m)/resolved.env"
obtain_rc=0
# Obtain ALL THREE: jemalloc (runtime, preloaded) + libevent + ncurses (the
# tmux BUILD deps the NATIVE-build fallback needs on a minimal host without
# libevent-dev / libncurses-dev). obtain_local_deps.sh RESOLVES each by
# absolute path when the host already has it (cheap, no build) and only
# OBTAINS (source build) the genuinely-missing ones — so passing all three is
# safe + cheap on a full host and load-bearing on a minimal one. build_native.sh
# (Linux branch) sources resolved.env to add -I/-L + PKG_CONFIG_PATH for the
# local libevent/ncurses; the container build needs none of this (the image
# carries them) so the extra resolves are harmless there.
#
# `cc` LEADS the list (TMX-063): the ROOT-FREE C toolchain (zig) is resolved
# (host cc that LINKS) or obtained (prebuilt zig) FIRST, so on a host with no
# working host compiler the obtained zig feeds the libevent/ncurses/jemalloc
# source builds that follow. On a normal host `cc` resolves to the host
# compiler (CC_KIND=host) and nothing changes (no zig obtained, no regression).
#
# `go` (TMX-057, kind=toolchain) is requested too: scripts/tmx-state-bin (Step
# 3d) + the CM-TMX-STATE-GO-PRESENT verify gate (Step 4) need a Go >= 1.21.
# obtain_local_deps.sh RESOLVES a suitable host go by absolute path (cheap, no
# download) or OBTAINS the official prebuilt tarball ROOT-FREE into .local-deps
# and writes GO_BIN/GOROOT to resolved.env — so a host that shipped no go (e.g.
# amber 2026-06-29: CM-TMX-STATE-GO-PRESENT FAIL → setup EXIT 4) is auto-solved
# with no sudo. On a host that already has go, it resolves in place (no obtain).
DEPS="cc jemalloc libevent ncurses go" bash scripts/obtain_local_deps.sh || obtain_rc=$?
if [ "$obtain_rc" -ne 0 ]; then
    echo "  ⚠ obtain_local_deps.sh exited $obtain_rc (typed error 10-14, see output above) — NOT faking success (§11.4)"
fi
if [ -f "$RESOLVED_ENV" ]; then
    # shellcheck disable=SC1090
    . "$RESOLVED_ENV"
fi
# Surface the build-dep resolution (consumed by build_native.sh, not setup).
if [ -n "${LIBEVENT_SOURCE:-}" ]; then
    echo "  ✓ libevent: ${LIBEVENT_LIBDIR:-?} (inc: ${LIBEVENT_INCDIR:-?}, source: ${LIBEVENT_SOURCE:-?})"
fi
if [ -n "${NCURSES_SOURCE:-}" ]; then
    echo "  ✓ ncurses: ${NCURSES_LIBDIR:-?} (inc: ${NCURSES_INCDIR:-?}, source: ${NCURSES_SOURCE:-?})"
fi
# Canonicalise: prefer the resolved ABSOLUTE path; fall back to the Step 1
# host probe ($JEMALLOC) so the wrapper still preloads on hosts where the
# obtain step found nothing new (honest degradation, never a fake resolution).
if [ -z "${JEMALLOC_SO:-}" ] && [ -n "${JEMALLOC:-}" ]; then
    JEMALLOC_SO="$JEMALLOC"
    JEMALLOC_LIBDIR="$(dirname "$JEMALLOC")"
    JEMALLOC_SOURCE="host-probe-fallback"
fi
if [ -n "${JEMALLOC_SO:-}" ]; then
    echo "  ✓ resolved jemalloc: $JEMALLOC_SO (libdir: ${JEMALLOC_LIBDIR:-?}, source: ${JEMALLOC_SOURCE:-?})"
else
    echo "  ⚠ no jemalloc resolved — wrapper LD_PRELOAD will be inert (tmux still runs; hardening allocator absent)"
fi

# Step 1b (go) — put the resolved/obtained Go toolchain on PATH so Step 3d
# (tmx-state-bin build) AND Step 4's CM-TMX-STATE-GO-PRESENT gate (verify.sh
# uses `command -v go`) resolve `go` even on a host that shipped none (TMX-057).
# obtain_local_deps.sh (DEPS now includes `go`) wrote GO_BIN/GOROOT into
# resolved.env, sourced above. We only touch PATH when `go` is not already
# resolvable → a host that already has a suitable go is unchanged (idempotent).
# §11.4.6: probe the real binary (`go version`) — never claim a go that does not
# run; on genuine non-obtain (no network etc.) we say so honestly, no fake.
if ! command -v go >/dev/null 2>&1; then
    GO_BINDIR=""
    if [ -n "${GO_BIN:-}" ] && [ -x "${GO_BIN}" ]; then
        GO_BINDIR="$(dirname "${GO_BIN}")"
    elif [ -n "${GOROOT:-}" ] && [ -x "${GOROOT}/bin/go" ]; then
        GO_BINDIR="${GOROOT}/bin"
    fi
    if [ -n "$GO_BINDIR" ] && "$GO_BINDIR/go" version >/dev/null 2>&1; then
        export PATH="${GO_BINDIR}:$PATH"
        echo "  ✓ go on PATH via ${GO_BINDIR} ($("$GO_BINDIR/go" version 2>/dev/null))"
    else
        echo "  ⚠ go not resolved/obtained (GO_BIN/GOROOT absent in resolved.env) — Step 3d + CM-TMX-STATE-GO-PRESENT will be RED (honest, §11.4.6)"
    fi
fi

# Step 1b (LD path) — assemble LD_LIBRARY_PATH for HOST runs of the built binary
# (TMX-FIX-b). build_containerized.sh ends by RUNNING the container-built binary
# on the HOST (`tmux -V`) as its success-check; that binary dynamically loads
# libjemalloc.so.2 (+ a source-built libevent/ncursesw). When those resolved
# into .local-deps (NOT on the default ld.so path) the host run-check dies with
#   error while loading shared libraries: libjemalloc.so.2
# → build_containerized exits non-zero → setup needlessly falls back to a native
# build even though the CONTAINER build SUCCEEDED (forensic:
# qa-results/loop-20260629/host-install-amber/06_setup_rebuild_full.log). Step 2
# passes this LD_LIBRARY_PATH into the build_containerized.sh invocation so the
# host run-check can load the libs. Same source-gating as build_native.sh; EMPTY
# when every dep is host-system-resolved (default path) ⇒ no behaviour change.
LOCAL_DEPS_LDPATH=""
_setup_add_run_libdir() {
    [ -n "${1:-}" ] || return 0
    case ":${LOCAL_DEPS_LDPATH}:" in *":$1:"*) return 0 ;; esac
    LOCAL_DEPS_LDPATH="${LOCAL_DEPS_LDPATH:+${LOCAL_DEPS_LDPATH}:}$1"
}
case "${JEMALLOC_SOURCE:-}" in host-system|host-brew|host-probe-fallback|"") : ;; *) _setup_add_run_libdir "${JEMALLOC_LIBDIR:-}" ;; esac
case "${LIBEVENT_SOURCE:-}" in host-system|host-brew|host-probe-fallback|"") : ;; *) _setup_add_run_libdir "${LIBEVENT_LIBDIR:-}" ;; esac
case "${NCURSES_SOURCE:-}" in host-system|host-brew|host-probe-fallback|"") : ;; *) _setup_add_run_libdir "${NCURSES_LIBDIR:-}" ;; esac

# Build-flag wiring for a local-prefix jemalloc is done DIRECTLY by
# build_native.sh (§11.4.6/§11.4.124): it sources .local-deps/<plat>/resolved.env
# itself and adds `-I$LOCAL_DEPS_PREFIX/include -L$JEMALLOC_LIBDIR` (appending,
# not discarding, inherited flags) — the load-bearing link wiring for the
# {compiler, no-engine, no-system-jemalloc} host. A previous setup-side
# `export CPPFLAGS/CFLAGS/LDFLAGS` block lived here but was DEAD: build_native.sh
# AND build_containerized.sh both plain-ASSIGNED their own flags (and the
# containerized build runs `--network none` linking libjemalloc-dev INSIDE the
# image), so nothing consumed the exports. Removed as redundant now that
# build_native.sh consumes resolved.env directly. The local-prefix RUNTIME
# resolution remains Step 2b patchelf rpath (belt-and-suspenders) + the
# wrapper's absolute LD_PRELOAD + LD_LIBRARY_PATH=$JEMALLOC_LIBDIR.

# Step 2 — build the tmux binary natively for this OS
echo ""
echo "[setup] step 2 — native build"
case "$HOST_OS" in
    Darwin)
        TMUX_BIN_ABS="$REPO_ROOT/tmux/build-darwin/bin/tmux"
        if [ "$MODE" = "rebuild" ] || [ ! -x "$TMUX_BIN_ABS" ]; then
            # §11.4.6/§11.4.81: refuse with an honest, actionable message (and
            # consent-gated auto-install) if the C toolchain cannot LINK, instead
            # of letting ./configure die with the cryptic "C compiler cannot
            # create executables". On macOS the fix is Xcode CLT.
            _native_build_preflight || exit 5
            bash scripts/build_native.sh
        else
            echo "  binary already present at $TMUX_BIN_ABS — use --rebuild to force"
        fi
        # Refresh jemalloc path now that brew install ran inside build_native.sh.
        JEMALLOC_DYLIB="$(brew --prefix jemalloc 2>/dev/null)/lib/libjemalloc.dylib"
        if [ -f "$JEMALLOC_DYLIB" ]; then
            JEMALLOC="$JEMALLOC_DYLIB"
        fi
        ;;
    Linux)
        TMUX_BIN_ABS="$REPO_ROOT/tmux/build/bin/tmux"
        if [ "$MODE" = "rebuild" ] || [ ! -x "$TMUX_BIN_ABS" ]; then
            if [ -n "${ENGINE:-}" ]; then
                # Prefer the hermetic containerized build, but FALL BACK to a
                # native build when the container build fails for a reason
                # unrelated to our code — e.g. rootless Podman with exhausted
                # /etc/subuid+/etc/subgid ranges cannot unpack the base image
                # ("lchown /etc/gshadow: invalid argument"; fixing the ID ranges
                # needs root + `podman system migrate`), or no network to pull
                # the base image. The native path produces the SAME binary
                # directly on the host (forensic anchor: base ALT host, rootless
                # podman subgid exhaustion, 2026-06-29; §11.4.101 reversible
                # decision — native is the safe fallback when the host already
                # has the build prerequisites). If BOTH fail, surface both and
                # exit non-zero (never a silent green).
                # TMX-FIX-b: pass the local-deps LD_LIBRARY_PATH into the child so
                # build_containerized.sh's host-side `tmux -V` success-check can
                # load libjemalloc.so.2 (+ local libevent/ncursesw). The VAR=value
                # prefix scopes it to this child ONLY (never leaks into Step 2b/3/4
                # which manage their own). EMPTY ⇒ plain invocation (byte-identical).
                _cb_ok=1
                if [ -n "$LOCAL_DEPS_LDPATH" ]; then
                    LD_LIBRARY_PATH="${LOCAL_DEPS_LDPATH}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" bash scripts/build_containerized.sh || _cb_ok=0
                else
                    bash scripts/build_containerized.sh || _cb_ok=0
                fi
                if [ "$_cb_ok" = "0" ]; then
                    echo ""
                    echo "[setup] ⚠ containerized build failed (see output above) —"
                    echo "        falling back to a NATIVE host build (§11.4.101)."
                    echo "        Common cause: rootless podman /etc/subuid+/etc/subgid"
                    echo "        exhaustion — fix with (as root):"
                    echo "          usermod --add-subuids 100000-165535 --add-subgids 100000-165535 \$USER"
                    echo "          podman system migrate"
                    echo "        Native build needs a working C toolchain — the"
                    echo "        preflight below verifies it can LINK (and can"
                    echo "        auto-install it via scripts/install_deps.sh)."
                    echo ""
                    # §11.4.6/§11.4.123/§11.4.138: front the native build with the
                    # C-link preflight so a gcc-but-no-glibc-devel host gets an
                    # honest, actionable message (+ consent-gated auto-install of
                    # gcc/glibc-devel/make/libevent/ncursesw/… via install_deps.sh)
                    # instead of the cryptic "C compiler cannot create executables".
                    _native_build_preflight || exit 5
                    bash scripts/build_native.sh
                fi
            else
                _native_build_preflight || exit 5
                bash scripts/build_native.sh
            fi
        else
            echo "  binary already present at $TMUX_BIN_ABS — use --rebuild to force"
        fi
        ;;
esac

# Step 2b — set the built binary's rpath to the resolved jemalloc libdir so
# DT_NEEDED libjemalloc.so.2 resolves at RUNTIME with no system install
# (§11.4.111). `patchelf --set-rpath <dir> --force-rpath` writes RPATH (not
# RUNPATH) — honoured for the binary's own DT_NEEDED deps. jemalloc STAYS
# DYNAMIC: patchelf touches only the rpath entry, NEVER DT_NEEDED, so test 61
# T3 (objdump -p | grep NEEDED.*libjemalloc) stays GREEN. make/autoconf
# mangle a literal $ORIGIN in LDFLAGS, so the rpath is set with patchelf
# AFTER the build (docs/research/local_deps_20260628 Angle 1).
# patchelf is OPTIONAL belt-and-suspenders, NOT required: it makes the binary
# self-contained when present. When patchelf is ABSENT (e.g. amber: unprivileged),
# jemalloc is resolved by LD_LIBRARY_PATH=$JEMALLOC_LIBDIR (sourced from
# .local-deps/<plat>/resolved.env) — exported by verify.sh + run_all.sh for the
# RAW $TMUX_BIN gate/tests AND by the tmx wrapper (Step 3) for interactive use,
# so the raw-binary verification gate passes with NO patchelf. Linux/ELF only;
# macOS resolves via the wrapper's DYLD_* env (Mach-O has no patchelf in this
# toolchain — verify.sh/run_all.sh export DYLD_LIBRARY_PATH there).
echo ""
echo "[setup] step 2b — set rpath to resolved jemalloc libdir (Linux/ELF)"
if [ "$HOST_OS" = "Linux" ]; then
    PATCHELF_BIN=""
    for _P in patchelf "$HOME/.local/bin/patchelf" /usr/bin/patchelf /usr/local/bin/patchelf; do
        if [ "${_P#/}" != "$_P" ]; then
            [ -x "$_P" ] && { PATCHELF_BIN="$_P"; break; }
        else
            command -v "$_P" >/dev/null 2>&1 && { PATCHELF_BIN="$_P"; break; }
        fi
    done
    if [ -n "$PATCHELF_BIN" ] && [ -n "${JEMALLOC_LIBDIR:-}" ] && [ -x "$TMUX_BIN_ABS" ]; then
        if "$PATCHELF_BIN" --set-rpath "$JEMALLOC_LIBDIR" --force-rpath "$TMUX_BIN_ABS" 2>/dev/null; then
            echo "  ✓ rpath = $("$PATCHELF_BIN" --print-rpath "$TMUX_BIN_ABS" 2>/dev/null) (jemalloc DT_NEEDED preserved; belt-and-suspenders — binary self-contained)"
        else
            echo "  ⚠ patchelf --set-rpath failed — jemalloc still resolves via LD_LIBRARY_PATH=${JEMALLOC_LIBDIR:-?} (resolved.env; exported by verify.sh/run_all.sh + the tmx wrapper)"
        fi
    elif [ -z "$PATCHELF_BIN" ]; then
        echo "  ⓘ patchelf absent (optional belt-and-suspenders) — jemalloc resolves via LD_LIBRARY_PATH=${JEMALLOC_LIBDIR:-?} from resolved.env: exported by verify.sh + run_all.sh for the raw-binary gate/tests AND by the tmx wrapper for interactive use (no patchelf required)"
    else
        echo "  ⓘ no resolved JEMALLOC_LIBDIR or binary absent — skip rpath (wrapper LD_PRELOAD still set)"
    fi
elif [ "$HOST_OS" = "Darwin" ]; then
    echo "  ⓘ Darwin: jemalloc resolved via wrapper DYLD_INSERT_LIBRARIES + DYLD_LIBRARY_PATH (Mach-O; no patchelf in toolchain)"
fi

if [ "$MODE" = "build-only" ]; then
    echo "[setup] --build-only: stopping after step 2"
    exit 0
fi

# Step 3 — generate the tmx wrapper from tmx.template
echo ""
echo "[setup] step 3 — generating tmx wrapper"
RLIMIT_WRAPPER_ABS="$REPO_ROOT/scripts/tmx-rlimit-wrapper.sh"
# __JEMALLOC_SO__ / __JEMALLOC_LIBDIR__ come from the resolved.env consumed
# in Step 1b (the ABSOLUTE path + its libdir) — LD_PRELOAD ignores rpath, so
# the wrapper needs the absolute path (§11.4.111 + research.md Angle 2). The
# `:-` guards keep the substitution safe under `set -u` even if obtain found
# nothing (empty → wrapper's `[ -n "$JEMALLOC_SO" ]` guard skips preload).
sed \
    -e "s|__TMUX_BIN__|$TMUX_BIN_ABS|g" \
    -e "s|__JEMALLOC_SO__|${JEMALLOC_SO:-}|g" \
    -e "s|__JEMALLOC_LIBDIR__|${JEMALLOC_LIBDIR:-}|g" \
    -e "s|__RLIMIT_WRAPPER__|$RLIMIT_WRAPPER_ABS|g" \
    scripts/tmx.template > scripts/tmx
chmod +x scripts/tmx
echo "  ✓ wrote scripts/tmx ($HOST_OS native wrapper, host-process isolation: $(if [ "$HOST_OS" = "Darwin" ]; then echo "POSIX rlimit"; else echo "cgroup-v2 transient scope"; fi))"

# clause 6: the idle-timeout session recycler (scripts/tmx-recycler.sh) is a
# STATIC script (no __PLACEHOLDER__ substitution — the generated wrapper
# passes all config via env at launch, and the marker hooks bake the marker
# path inline). It lives beside the generated scripts/tmx and is resolved at
# "$TMX_DIR/tmx-recycler.sh". Ensure it is executable so a direct invocation
# works (the wrapper also calls it via `bash …` defensively). No generation.
if [ -f scripts/tmx-recycler.sh ]; then
    chmod +x scripts/tmx-recycler.sh 2>/dev/null || true
    echo "  ✓ scripts/tmx-recycler.sh present + executable (idle-session recycler, TMX_RECYCLE_IDLE_SECS=${TMX_RECYCLE_IDLE_SECS:-900}; 0 disables)"
else
    echo "  ⓘ scripts/tmx-recycler.sh not present (pre-recycler tree); idle recycle disabled"
fi

# Step 3a — generate the tmx-shell-init.sh from its template (v1.0.9+).
# CRITICAL: the bashrc snippet sources scripts/tmx-shell-init.sh; without
# this step, the snippet's `[ -r ... ] && . ...` guard silently skips
# the source and no operator prompt ever fires. The 2026-05-22 forensic
# anchor (User mandate, post-v1.0.10): "we have not been asked anything
# regarding the naming the session". Root cause: setup.sh wrote the rc
# snippet but never generated the file it sources.
echo "[setup] step 3a — generating tmx-shell-init.sh from template"
if [ -f scripts/tmx-shell-init.sh.template ]; then
    # __TMUX_BIN__ → the built binary's absolute path (same value injected into
    # scripts/tmx at step 3) so the cwd-persist hook resolves the project's own
    # 3.6a server, never a mismatched system tmux on PATH (§11.4.111/§11.4.108;
    # forensic anchor: thinker system tmux 3.4 vs 3.6a server, 2026-06-28).
    sed \
        -e "s|__PROJECT__|$REPO_ROOT|g" \
        -e "s|__TMUX_BIN__|$TMUX_BIN_ABS|g" \
        -e "s|__DATE__|$(date '+%Y-%m-%d')|" \
        scripts/tmx-shell-init.sh.template > scripts/tmx-shell-init.sh
    chmod +x scripts/tmx-shell-init.sh
    echo "  ✓ wrote scripts/tmx-shell-init.sh (sourced from .bashrc/.zshrc on interactive login)"
else
    echo "  ⓘ scripts/tmx-shell-init.sh.template not present (pre-v1.0.9 tree); skip"
fi

# Clean up any legacy files from the previous VM-based architecture so the
# operator doesn't get confused by their presence (no longer used in
# native dual-OS install path).
rm -f scripts/tmx-vm
rm -f scripts/tmx-mac.template.bak 2>/dev/null || true

# Step 3b — build oom_set helper binary (no privilege escalation). Operator can
# later install with `bash scripts/build_oom_set.sh --install` (as root) to get
# full OOM protection without the wrapper needing elevated privilege per launch.
# See §8 of guide.
echo ""
echo "[setup] step 3b — building oom_set helper (Linux only; SKIP on Darwin)"
if [ "$HOST_OS" = "Linux" ] && [ -f scripts/oom_set.c ] && [ -x scripts/build_oom_set.sh ]; then
    bash scripts/build_oom_set.sh 2>&1 | grep -E "wrote|complete" | sed 's/^/  /'
    if [ -x /usr/local/bin/tmx-oom-set ]; then
        echo "  ✓ /usr/local/bin/tmx-oom-set installed (cap_sys_resource+ep) — Test 08 will PASS"
    else
        echo "  ⓘ helper compiled but not installed system-wide. To enable Test 08 PASS:"
        echo "       bash scripts/build_oom_set.sh --install   (as root)"
    fi
fi

# Step 3d — build tmx-state Go binary for the HOST OS (v1.0.9+).
# §11.4.30: build artefacts MUST NOT be versioned. The Go binary is a
# per-OS native artifact (Mach-O on Darwin, ELF on Linux) — committing
# one OS's binary breaks the other. Build at setup time on the host.
# §11.4.77 (regeneration mechanism): scripts/tmx-state/ source is
# tracked; this step IS the regeneration mechanism.
echo ""
echo "[setup] step 3d — building tmx-state Go binary (v1.0.9 cwd persistence)"
if [ -f scripts/tmx-state/go.mod ]; then
    if command -v go >/dev/null 2>&1; then
        ( cd scripts/tmx-state && go build -o "$REPO_ROOT/scripts/tmx-state-bin" . ) && \
            echo "  ✓ scripts/tmx-state-bin built for $HOST_OS ($(scripts/tmx-state-bin version 2>/dev/null || echo 'no version'))" || \
            echo "  ⚠ scripts/tmx-state-bin build FAILED — v1.0.9 cwd persistence will not work"
    else
        echo "  ⚠ 'go' not on PATH — install Go ≥ 1.21 to build scripts/tmx-state-bin"
        echo "       macOS: brew install go    Linux: distro package or https://go.dev/dl/"
    fi
else
    echo "  ⓘ scripts/tmx-state/ not present (pre-v1.0.9 tree); skip"
fi

# Step 3c — CodeGraph auto-update + index bootstrap (per §11.4.77/.78/.80).
#
# Two cooperating steps:
#   (3c.i)  Auto-update codegraph to npm-latest via the constitution-
#           provided update script per §11.4.80 (User mandate 2026-05-21:
#           "use ALWAYS the latest possible codegraph version"). Inherited
#           by reference — never copy the script into the project.
#   (3c.ii) Regenerate the .codegraph/codegraph.db artefact per §11.4.77
#           via scripts/codegraph_reindex.sh (declared in
#           .gitignore-meta/codegraph-db.yaml). Pre-Nezha-fix (2026-05-21)
#           setup.sh did NOT invoke that script, so fresh clones had no
#           DB and test 21 FAILed — the §11.4 PASS-bluff pattern §11.4.77
#           was written to prevent.
echo ""
echo "[setup] step 3c — CodeGraph auto-update + index bootstrap (§11.4.77 + §11.4.80)"

# 3c.i — auto-update to npm-latest.
CG_UPDATE_SCRIPT="$REPO_ROOT/constitution/scripts/codegraph_update.sh"
if [ -x "$CG_UPDATE_SCRIPT" ]; then
    echo "  invoking constitution-provided update script (§11.4.80)..."
    bash "$CG_UPDATE_SCRIPT" 2>&1 | grep -E "already at|updated to|RED|version" | sed 's/^/    /' || true
    # PATH may need a re-probe after a global npm install.
    if ! command -v codegraph >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
        NPM_PREFIX="$(npm config get prefix 2>/dev/null | tr -d '\r\n' || true)"
        [ -n "$NPM_PREFIX" ] && [ -x "${NPM_PREFIX}/bin/codegraph" ] && export PATH="${NPM_PREFIX}/bin:$PATH"
    fi
elif command -v npm >/dev/null 2>&1; then
    # Fallback if constitution script absent: best-effort direct npm update.
    echo "  ⓘ constitution/scripts/codegraph_update.sh not present — direct npm update"
    npm install -g @colbymchenry/codegraph@latest 2>&1 | tail -3 | sed 's/^/    /' || true
else
    echo "  ⓘ npm not present — cannot update codegraph"
fi

# 3c.ii — regenerate index.
if command -v codegraph >/dev/null 2>&1; then
    if [ -x scripts/codegraph_reindex.sh ]; then
        bash scripts/codegraph_reindex.sh 2>&1 | grep -E "regenerated|node|RED|merged|applied|index|sync" | sed 's/^/  /'
    else
        echo "  ⓘ scripts/codegraph_reindex.sh not executable — skip §11.4.77 bootstrap"
    fi
else
    echo "  ⓘ codegraph CLI still not on PATH after update attempt — install per §11.4.78"
    echo "       Test 21 will FAIL until installed; setup.sh continues so the operator can install + retry."
fi

# Step 4 — verification gate (THE GUARD)
echo ""
echo "[setup] step 4 — verification gate"
# Native dual-OS: the binary is built FOR THIS HOST and verified ON THIS
# HOST. No more VM bridge in the default install flow. verify.sh respects
# $TMUX_BIN env override.
export TMUX_BIN="$TMUX_BIN_ABS"
export WRAPPER="$REPO_ROOT/scripts/tmx"
if ! bash scripts/verify.sh; then
    echo ""
    echo "[setup] ✗ verification RED. Aborting before PATH-export."
    echo "  Per §11.4 anti-bluff covenant, we DO NOT expose unverified binaries."
    exit 4
fi
echo ""
echo "[setup] ✓ verification GREEN — safe to proceed with installation"

if [ "$MODE" = "verify-only" ]; then
    echo "[setup] --verify-only: stopping after step 4. PATH NOT exported."
    exit 0
fi

# Step 5 — install ~/.tmux.conf + .bashrc snippet (gated)
echo ""
echo "[setup] step 5 — installing user config"

if [ -f ~/.tmux.conf ] && ! grep -q 'vasic-digital optimized tmux configuration' ~/.tmux.conf; then
    echo "  ⚠ ~/.tmux.conf exists and is NOT ours — backing up to ~/.tmux.conf.pre-vasic-digital"
    cp -n ~/.tmux.conf ~/.tmux.conf.pre-vasic-digital
fi
cp scripts/tmux.conf.template ~/.tmux.conf
echo "  ✓ ~/.tmux.conf installed"

SNIPPET=$(sed \
    -e "s|__DATE__|$(date '+%Y-%m-%d')|" \
    -e "s|__PROJECT__|$REPO_ROOT|g" \
    scripts/bashrc_snippet.template)

# Append the snippet to whichever shell rc files actually exist. On
# macOS, the default user shell is zsh, so an install that only writes
# to ~/.bashrc would silently fail to put `tmx` on the operator's PATH
# (§1 bluff: install claims tmx is reachable, but in the user's actual
# shell it isn't). Handle both shells; the snippet is bash/zsh-portable.
# v1.0.13 — also append to .bash_profile. The wrapper invokes the shell
# with `-l` (login) on both OSes; bash login shells read .bash_profile
# but NOT .bashrc unless .bash_profile sources .bashrc explicitly (the
# common idiom but not guaranteed). Without the snippet in .bash_profile,
# tmux panes spawned by our wrapper never see PROMPT_COMMAND, so cwd
# never gets recorded on the prompt-hook path → exit+reopen loses the
# cwd. Adding .bash_profile + .profile to the install list closes that
# gap. .zprofile NOT touched because zsh always sources .zshrc regardless
# of login/non-login (per the zsh startup-file table).
for rc in ~/.bashrc ~/.bash_profile ~/.profile ~/.zshrc; do
    # Append to .bashrc + .zshrc unconditionally (creating if missing on
    # Darwin where .zshrc may not exist). For .bash_profile and .profile,
    # only touch if they already exist OR if the user's default shell is
    # bash (the conventional case to install in).
    case "$rc" in
        ~/.bashrc|~/.zshrc) ;;
        ~/.bash_profile|~/.profile)
            # Only touch these if they already exist OR if $SHELL is bash.
            [ -e "$rc" ] || case "${SHELL:-}" in *bash) ;; *) continue ;; esac
            ;;
    esac
    if [ -e "$rc" ] && grep -q '─── vasic-digital optimized tmux' "$rc" 2>/dev/null; then
        _strip_bashrc_snippet "$rc"
    fi
    printf '%s\n' "$SNIPPET" >> "$rc"
    echo "  ✓ snippet appended to $rc"
done

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  vasic-digital optimized tmux installed."
echo "  Open a NEW shell, or source the rc for your shell:"
echo "    bash: source ~/.bashrc"
echo "    zsh:  source ~/.zshrc"
echo ""
echo "  Use 'tmx new|attach|ls|kill' to invoke the verified build."
echo "  The system 'tmux' command stays unchanged and reachable — both"
echo "  coexist side-by-side. PATH gets scripts/ prepended so 'tmx'"
echo "  resolves to this project's wrapper; 'tmux' resolves to whatever"
echo "  was on your PATH before."
if [ "$HOST_OS" = "Darwin" ]; then
    echo ""
    echo "  macOS isolation: each session runs in the macOS host process"
    echo "  tree with kernel-enforced POSIX rlimits applied per session:"
    echo "    • RLIMIT_CPU  (CPU-time cap, ${TMX_CPU_HARD_SEC:-86400} s default)"
    echo "    • RLIMIT_NPROC (per-user process count cap)"
    echo "  ⓘ HONEST GAP: RLIMIT_AS (virtual memory) is NOT enforced by"
    echo "    the XNU kernel for unprivileged processes (returns EINVAL)."
    echo "    Memory containment on macOS requires launchd jobs with"
    echo "    HardResourceLimits plist (root). See docs/guide/README.md §5.6."
    echo "  Full host access: Homebrew, /usr/bin, all system tools reachable."
elif [ "$HOST_OS" = "Linux" ]; then
    echo ""
    echo "  Linux isolation: each session in its own cgroup-v2 transient"
    echo "  scope (tmx-NAME.scope) with MemoryMax / CPUQuota / TasksMax /"
    echo "  Delegate=yes. OOM in one session contained to that scope only."
fi
echo "════════════════════════════════════════════════════════════════"
