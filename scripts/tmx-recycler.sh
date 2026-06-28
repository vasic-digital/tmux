#!/usr/bin/env bash
# tmx-recycler.sh — idle-timeout session recycler watcher for the tmx wrapper.
#
# Purpose (clause 6 — idle recycler):
#   A detached tmx session with NO client attached stays alive for a
#   configurable window (default 900 s = TMX_RECYCLE_IDLE_SECS), then is
#   auto-recycled: its runtime is torn down (tmux session killed + the OS
#   isolation primitive freed — systemd `--user --scope` on Linux; nothing
#   extra on macOS where the rlimit wrapper `exec`s the shell) WITHOUT
#   clearing persisted state. last_pwd / color / password_hash survive in
#   ~/.tmx/state.json so a later `tmx new -s NAME` restores them. Only the
#   explicit `tmx delete -t NAME` verb clears state (via `tmx-state forget`).
#
# Design (per docs research, tmux #1174 / #1843 / mankier command-queue):
#   * EXTERNAL poll-watcher, NOT an in-server `run-shell 'sleep'` — the
#     latter BLOCKS the tmux command queue for the whole window (mankier:
#     run-shell/if-shell stop the queue until the shell command finishes).
#   * SINGLETON per session (§11.4.119 single-resource-owner): exactly ONE
#     watcher owns each session's recycle decision. flock(1) when present
#     (Linux, auto-releases on fd close); portable atomic-mkdir lock with
#     PID-liveness fallback on macOS (which ships no flock binary).
#   * Idle metric = `#{session_attached}==0` held for >= WINDOW, tracked via
#     a "detached-since" epoch marker — NOT `#{session_activity}` (that bumps
#     on pane OUTPUT, measuring process-liveness not human-attention).
#   * REATTACH RACE-GUARD = atomic in-server conditional: the condition AND
#     the kill run in ONE command on tmux's serial command queue:
#       tmux -L SOCK if-shell -F '#{==:#{session_attached},0}' 'kill-session -t NAME'
#     No client `attach` can interleave between the test and the kill. A
#     bounded has-session confirm loop then verifies death before the scope
#     is stopped (so a reattach in the gap never gets its cgroup yanked).
#   * RECORD STATE BEFORE TEARDOWN (tmux #1174 — close/detach hooks do NOT
#     fire on signal death): the watcher itself captures #{pane_current_path}
#     and calls `tmx-state record` while the session is still alive, so
#     last_pwd is correct regardless of HOW the client left.
#
# Subcommands:
#   watch                 run the per-session watcher loop (config via env, below)
#   detached <marker>     write the detach-since epoch marker (client-detached hook)
#   attached <marker>     clear the detach-since marker (client-attached hook)
#   locktest <lock> [sec] singleton self-test aid: print ACQUIRED|BUSY (validation)
#
# `watch` configuration (environment, set by the tmx wrapper at launch):
#   TMX_RC_TMUX_BIN   absolute path to the built tmux binary       (required)
#   TMX_RC_SOCK       per-session socket label (tmx-NAME)          (required)
#   TMX_RC_NAME       sanitised session name                       (required)
#   TMX_RC_SCOPE      systemd scope unit (tmx-NAME.scope)          (Linux teardown)
#   TMX_RC_STATE_BIN  absolute path to tmx-state-bin               (record-before-kill)
#   TMX_RC_MARKER     detach-since marker file path                (required)
#   TMX_RC_WINDOW     idle window in seconds (default 900; 0 = off)
#   TMX_RC_HOST_OS    uname -s of the host (Linux | Darwin)
#   TMX_RC_POLL       poll interval seconds (default min(WINDOW,60), >=1)
#   TMX_RC_LOCK       singleton lock path (default <marker%.detached>.lock)
#
# POSIX-ish / bash-3.2-safe (macOS default shell). Parses under `sh -n` and
# `bash -n` (§11.4.67). No bash-4 constructs (no mapfile / ${x^^} / assoc).
#
# Cross-references: scripts/tmx.template (launches `watch`, sets the
# client-attached/detached marker hooks, and the `delete` verb), scripts/
# tmx-state/main.go (record/forget). Last verified: 2026-06-28.

set -u

# Current epoch seconds (portable: GNU + BSD date both honour +%s).
_now() { date +%s; }

# _mark_detached <marker>  — record the detach-since epoch (overwrite: a new
# detach resets the idle clock). Best-effort + silent (hook context).
_mark_detached() {
    mp="${1:-}"
    [ -n "$mp" ] || return 0
    md=$(dirname "$mp")
    mkdir -p "$md" 2>/dev/null || true
    _now > "$mp" 2>/dev/null || true
    return 0
}

# _mark_attached <marker> — clear the detach-since marker (cancel-on-attach
# race-guard). Best-effort + silent.
_mark_attached() {
    mp="${1:-}"
    [ -n "$mp" ] || return 0
    rm -f "$mp" 2>/dev/null || true
    return 0
}

# _singleton <lock> — acquire the per-session single-owner lock (§11.4.119).
# Returns 0 if THIS process now owns it, 1 if another LIVE owner holds it.
# flock(1) when available (Linux): fd 9 held for the process lifetime,
# auto-released on exit. Portable atomic-mkdir fallback (macOS) uses a PID
# file to detect + steal a stale lock left by a SIGKILL'd watcher.
_singleton() {
    lock="${1:-}"
    [ -n "$lock" ] || return 0
    if command -v flock >/dev/null 2>&1; then
        # Regular-file lock + advisory flock. fd 9 stays open for life.
        exec 9>"$lock" 2>/dev/null || return 1
        if flock -n 9 2>/dev/null; then
            return 0
        fi
        return 1
    fi
    # mkdir fallback: the directory IS the lock (mkdir is atomic).
    while : ; do
        if mkdir "$lock" 2>/dev/null; then
            printf '%s\n' "$$" > "$lock/pid" 2>/dev/null || true
            trap 'rm -rf "$lock" 2>/dev/null || true' EXIT INT TERM
            return 0
        fi
        op=$(cat "$lock/pid" 2>/dev/null || echo "")
        if [ -n "$op" ] && kill -0 "$op" 2>/dev/null; then
            return 1   # another live watcher owns it
        fi
        rm -rf "$lock" 2>/dev/null || true   # stale → retry
    done
}

# _watch — the per-session recycler loop. Config read from TMX_RC_* env.
_watch() {
    TMUX_BIN="${TMX_RC_TMUX_BIN:-}"
    SOCK="${TMX_RC_SOCK:-}"
    NAME="${TMX_RC_NAME:-}"
    SCOPE="${TMX_RC_SCOPE:-}"
    STATE_BIN="${TMX_RC_STATE_BIN:-}"
    WINDOW="${TMX_RC_WINDOW:-900}"
    MARKER="${TMX_RC_MARKER:-}"
    HOST_OS="${TMX_RC_HOST_OS:-$(uname -s)}"

    # Validate WINDOW; non-integer → safe default (§11.4.6 no-guessing).
    case "$WINDOW" in ''|*[!0-9]*) WINDOW=900 ;; esac
    [ "$WINDOW" -eq 0 ] && return 0   # disabled (per-session opt-out knob)

    # Required config present, or there is nothing safe to watch.
    [ -n "$TMUX_BIN" ] && [ -n "$SOCK" ] && [ -n "$NAME" ] && [ -n "$MARKER" ] || return 0

    LOCK="${TMX_RC_LOCK:-${MARKER%.detached}.lock}"
    POLL="${TMX_RC_POLL:-}"
    if [ -z "$POLL" ]; then
        if [ "$WINDOW" -lt 60 ]; then POLL="$WINDOW"; else POLL=60; fi
        [ "$POLL" -lt 1 ] && POLL=1
    fi
    case "$POLL" in ''|*[!0-9]*) POLL=60 ;; esac
    [ "$POLL" -lt 1 ] && POLL=1

    # §11.4.119: exactly one watcher per session. A duplicate exits at once.
    _singleton "$LOCK" || return 0

    while : ; do
        # Session gone (killed by `tmx delete`, kill-session, or a prior
        # recycle) → nothing to watch; exit, releasing the lock.
        if ! "$TMUX_BIN" -L "$SOCK" has-session -t "$NAME" 2>/dev/null; then
            _mark_attached "$MARKER"
            return 0
        fi

        attached=$("$TMUX_BIN" -L "$SOCK" display-message -p -t "$NAME" '#{session_attached}' 2>/dev/null || echo 1)
        case "$attached" in ''|*[!0-9]*) attached=1 ;; esac

        if [ "$attached" -ne 0 ]; then
            # A client is attached → reset the idle clock, keep watching.
            _mark_attached "$MARKER"
            sleep "$POLL"
            continue
        fi

        # Detached. Ensure a detach-since marker exists. The client-detached
        # hook normally writes it, but tmux #1174 means it may NOT fire on
        # signal death (terminal close / SSH drop) — so the watcher seeds it
        # itself on first detached observation.
        if [ ! -f "$MARKER" ]; then
            _mark_detached "$MARKER"
            sleep "$POLL"
            continue
        fi
        mt=$(cat "$MARKER" 2>/dev/null || echo "")
        case "$mt" in ''|*[!0-9]*) _mark_detached "$MARKER"; sleep "$POLL"; continue ;; esac

        now=$(_now)
        idle=$(( now - mt ))
        if [ "$idle" -lt "$WINDOW" ]; then
            sleep "$POLL"
            continue
        fi

        # ── recycle ──────────────────────────────────────────────────────
        # 1. Capture final cwd BEFORE teardown (tmux #1174 mitigation). The
        #    state row's color + password are PRESERVED by `record` (see the
        #    cmdRecord sibling-field fix) — recycle never clears state.
        if [ -n "$STATE_BIN" ] && [ -x "$STATE_BIN" ]; then
            cp=$("$TMUX_BIN" -L "$SOCK" display-message -p -t "$NAME" '#{pane_current_path}' 2>/dev/null || echo "")
            if [ -n "$cp" ]; then
                "$STATE_BIN" record "$NAME" "$cp" >/dev/null 2>&1 || true
            fi
        fi

        # 2. Atomic race-guard: kill ONLY if STILL detached. The condition
        #    and the kill execute together on tmux's serial command queue,
        #    so no `attach` can interleave between them.
        "$TMUX_BIN" -L "$SOCK" if-shell -F '#{==:#{session_attached},0}' "kill-session -t $NAME" 2>/dev/null || true

        # 3. Confirm death (bounded ~3 s). If a client reattached in the
        #    gap, if-shell skipped the kill and the session is still alive —
        #    we must NOT stop its scope (that would yank a live session).
        killed=0
        n=0
        while [ "$n" -lt 15 ]; do
            if ! "$TMUX_BIN" -L "$SOCK" has-session -t "$NAME" 2>/dev/null; then
                killed=1
                break
            fi
            n=$(( n + 1 ))
            sleep 0.2
        done

        if [ "$killed" -eq 1 ]; then
            # 4. Free the OS isolation primitive. Linux: stop the transient
            #    scope (empty-scope auto-GC is version-ambiguous — reuse the
            #    same explicit stop the wrapper's kill-session path uses).
            #    macOS: killing the session SIGHUPs the rlimit-wrapped shell,
            #    nothing extra to reap.
            if [ "$HOST_OS" = "Linux" ] && [ -n "$SCOPE" ]; then
                systemctl --user stop "$SCOPE" 2>/dev/null || true
            fi
            _mark_attached "$MARKER"   # tidy marker; state row PRESERVED
            return 0
        fi

        # Reattached during the confirm window → keep watching.
        _mark_attached "$MARKER"
        sleep "$POLL"
    done
}

# ── dispatch ───────────────────────────────────────────────────────────
cmd="${1:-}"
case "$cmd" in
    watch)
        _watch
        ;;
    detached)
        shift
        _mark_detached "${1:-}"
        ;;
    attached)
        shift
        _mark_attached "${1:-}"
        ;;
    locktest)
        # Singleton self-test aid (§11.4.119 dry-run validation). Acquire the
        # lock; print ACQUIRED + hold for [sec] (default 1) so a concurrent
        # invocation observes BUSY; or print BUSY if already owned.
        shift
        _lk="${1:-}"
        _hold="${2:-1}"
        case "$_hold" in ''|*[!0-9]*) _hold=1 ;; esac
        if _singleton "$_lk"; then
            printf 'ACQUIRED\n'
            sleep "$_hold"
        else
            printf 'BUSY\n'
        fi
        ;;
    *)
        printf 'tmx-recycler: usage: %s {watch|detached <marker>|attached <marker>|locktest <lock> [sec]}\n' "$0" >&2
        exit 2
        ;;
esac
