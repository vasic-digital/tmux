#!/usr/bin/env bash
# list_key.sh — read ONE key's live binding out of a running tmux server.
#
# ─── §11.4.18 documentation block ────────────────────────────────────────────
# Purpose:
#   Return the `bind-key` line for exactly one key in one key-table, from a
#   live server, in a way that is stable across tmux versions.
#
# WHY THIS EXISTS (TMX-090, measured 2026-09-01):
#   Tests previously queried `tmux list-keys -T <table> <key>`. Under the tmux
#   3.6a pin that returned the binding. Under the adopted tag 3.7b it returns
#   EMPTY with rc=0 while the binding is demonstrably present:
#       list-keys -T root WheelUpPane  -> (empty), rc=0
#       list-keys -T root | grep       -> bind-key -T root WheelUpPane if-shell ...
#   An empty result was then read as "the binding is missing", so SIX tests
#   reported the product broken when it was correct -- a §11.4.201(6) FALSE
#   NULL (a blind instrument and a genuinely-absent binding return the same
#   quiet nothing). §11.4.120: the user-visible behaviour was verified correct,
#   so the GATE is reconciled to a version-stable mechanism rather than the
#   product being changed to satisfy a broken query.
#
# Usage:   . "$SELF_DIR/lib/list_key.sh"
#          bind="$(tmx_list_key "$TMUX_BIN" "$S_SOCK" root WheelUpPane)"
# Inputs:  $1 tmux binary, $2 -L socket name, $3 key-table, $4 key
# Outputs: the matching `bind-key` line on stdout, or nothing if truly unbound
# Deps:    tmux, grep
# Cross-refs: scripts/tests/{17,44,46,47,48}_*.sh, mutation M-LIST-KEY-VERSION-STABLE
# Last verified: 2026-09-01 against tmux 3.7b
# ─────────────────────────────────────────────────────────────────────────────
tmx_list_key() {
    local bin="$1" sock="$2" table="$3" key="$4"
    # (1) REFUSE a dead/wrong socket. `list-keys` carries CMD_STARTSERVER, so an
    #     unknown socket does NOT error -- it starts a FRESH default-config
    #     server and returns tmux's DEFAULT binding. Any assertion whose expected
    #     substring also appears in the default would then false-PASS against a
    #     server that was never the one under test (§11.4.201(6)).
    "$bin" -L "$sock" has-session >/dev/null 2>&1 || {
        echo "TMX_LIST_KEY_ERROR: no live server on socket '$sock'" >&2
        return 2
    }
    # (2) List the WHOLE table. Under tmux 3.7b, cmd-list-keys.c's print branch
    #     `if ((single && tc != NULL) || n == 1)` lacks a tc!=NULL guard on the
    #     `n == 1` arm, so ANY listing matching exactly ONE row is routed to a
    #     nonexistent client's status line and DISCARDED when run from a script.
    #     Filtering here (not in tmux) keeps the row count > 1 and avoids that.
    #     NOTE: the trap is single-RESULT, not the key argument -- do NOT
    #     "optimise" this back to a tmux-side filter that happens to match
    #     several rows; it would appear to work and silently re-arm the defect.
    # (3) Match the key as a LITERAL FIELD via awk, never interpolated into a
    #     regex: keys like `.`, `*`, `(`, `?` are regex metacharacters and would
    #     false-match, crash the matcher, or false-miss.
    "$bin" -L "$sock" list-keys -T "$table" 2>/dev/null \
        | awk -v t="$table" -v k="$key" '
            $1 == "bind-key" {
                for (i = 2; i < NF; i++) {
                    if ($i == "-T" && $(i+1) == t && $(i+2) == k) { print; exit }
                }
            }'
}
