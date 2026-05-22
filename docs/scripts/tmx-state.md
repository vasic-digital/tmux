# tmx-state

**Revision:** 1
**Last modified:** 2026-05-22T12:20:00Z
**Authority:** vasic-digital tmux project
**Maintainer:** milosvasic
**Scope:** §11.4.18 script companion doc for the `tmx-state` Go binary
(source: `scripts/tmx-state/`, built artefact: `scripts/tmx-state-bin`)

## Purpose

Per-session cwd persistence daemon for the `tmx` wrapper. Records the
last-known working directory each tmux session was in when its client
detached or the session closed, so the next `tmx new -s NAME` can spawn
the session back in that directory. Atomic state writes (temp + rename
+ fsync) under an `fcntl F_SETLKW` advisory lock survive N concurrent
panes recording simultaneously without data loss. Design authority:
`docs/superpowers/specs/2026-05-22-tmx-shell-session-resume-design.md`
§4.B + §5.1 + §5.3.

## Usage

```sh
scripts/tmx-state-bin record  <session> <abs-path>
scripts/tmx-state-bin recall  <session>
scripts/tmx-state-bin list
scripts/tmx-state-bin forget  <session>
scripts/tmx-state-bin version
```

Concrete examples:

```sh
# Record that session 'demo' was last in /tmp.
scripts/tmx-state-bin record demo /tmp

# Recall it (prints "/tmp" to stdout, no trailing newline).
scripts/tmx-state-bin recall demo

# Use inside a subshell expansion (the canonical wrapper pattern):
LAST_PWD="$(scripts/tmx-state-bin recall demo 2>/dev/null || true)"
START_DIR="${LAST_PWD:-$HOME}"

# Tab-separated listing.
scripts/tmx-state-bin list
# →  demo<TAB>/tmp<TAB>1748000000

# Drop a session's record (idempotent — exit 0 whether present or not).
scripts/tmx-state-bin forget demo

# Version probe.
scripts/tmx-state-bin version    # → tmx-state v1.0.9
```

## Inputs

- **Positional args** as above.
- **`$TMX_STATE_FILE`** (optional) — overrides the default state file
  path. Default: `$HOME/.tmx/state.json`. Used by tests to point at a
  temp file rather than the operator's real state.
- **`$HOME`** — used to derive the default state file path.

## Outputs

- **stdout** — `recall` prints `last_pwd` (no trailing newline) on hit;
  `list` prints tab-separated rows; `version` / `help` print their
  banner. Other subcommands are silent on success.
- **stderr** — error messages on failure; one-line notice when a
  corrupt state file is auto-rebuilt during `record`.
- **state file** at `$TMX_STATE_FILE` (or `~/.tmx/state.json`) — JSON
  document, schema below. Parent directory is created with mode 0700;
  file is created with mode 0600.

## State file JSON schema (from spec §5.3, verbatim)

```json
{
  "schema_version": 1,
  "sessions": {
    "work": {
      "last_pwd": "/Users/milosvasic/Projects/tmux",
      "last_seen_unix": 1748000000,
      "created_unix": 1747000000,
      "host": "nezha.local"
    }
  }
}
```

Single-file design (not jsonl) — fits in memory trivially (kilobytes
for hundreds of sessions), allows atomic write+rename, and is easy to
inspect by hand. `created_unix` is preserved across `record` upserts;
`last_seen_unix` and `last_pwd` are overwritten each call.

## Exit codes

| Code | Subcommand | Meaning |
|---|---|---|
| 0 | any | success |
| 1 | record / list / forget | usage error, IO error, permission denied |
| 1 | recall | session not present in state |
| 2 | recall | state file unreadable (corrupt / IO error) — distinguishes "no record" from "cannot read" so callers can fall back deliberately rather than treat both as "no record" |

## Side-effects

- Creates `~/.tmx/` mode 0700 if missing.
- Creates/overwrites `~/.tmx/state.json` mode 0600 atomically
  (temp + fsync + rename).
- Holds an advisory `fcntl F_SETLKW` lock on the state file for the
  duration of every mutating call. Concurrent `record` invocations
  serialise; latest-wins per spec §6 edge case 8.
- On corrupt state file: rebuilds to `{schema_version: 1, sessions: {}}`,
  emits a one-line stderr notice during `record`; for `recall` returns
  exit 2 so callers can choose to fall back rather than silently treat
  the empty rebuild as "no record".

## Dependencies

- Go ≥ 1.21 toolchain (build-time only; produced binary is static).
- POSIX filesystem semantics (`rename(2)` atomicity, `fcntl(2)`
  advisory locking).
- No network. No external services. No third-party Go modules.

## Cross-references

- Design spec: `docs/superpowers/specs/2026-05-22-tmx-shell-session-resume-design.md`
- Operator user guide: `docs/guides/tmx-state.md` (P8 deliverable)
- Wrapper integration: `scripts/tmx.template` (P4 — calls `recall` on
  `tmx new` and installs `record`-firing tmux hooks on detach/close)
- Shell init: `scripts/tmx-shell-init.sh` (P2 — operator-facing
  prompt that ultimately calls the wrapper)
- SSH dispatch: `scripts/tmx-ssh-dispatch.sh` (P3 — `ssh host-tmx X`
  path also queries `recall`)
- Constitution: §11.4.18 (script docs), §11.4.5 (captured evidence),
  §11.4.50 (deterministic consistency — concurrent `record` test),
  §11.4.65 (universal Markdown export — this doc gets `.html` + `.pdf`
  siblings via `scripts/testing/sync_all_markdown_exports.sh`)

## Last verified

2026-05-22 — anti-bluff dry-trace of the wrapper integration captured
in `scripts/tmx.template` PWU P4 evidence; full on-device run gated on
PWU P6 test `18_state_persistence.sh`.
