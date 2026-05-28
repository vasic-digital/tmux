# workable-items — §11.4.93 SQLite-SSoT CLI

**Revision:** 1
**Last modified:** 2026-05-28T11:55:00Z
**Authority:** constitution/Constitution.md §11.4.93 (SQLite SSoT) + §11.4.95 (DB tracked in git) + §11.4.99 (regeneration mechanism cited sources)
**Scope:** project tmux — `cmd/workable-items/`
**Maintainer:** vasic-digital tmux

## Purpose

`workable-items` is the project's per-§11.4.93 single-source-of-truth CLI
for workable-item tracking. It bridges the Markdown trackers
(`Issues.md` + `Fixed.md` at repo root) and the SQLite database at
`docs/workable_items.db` (tracked in git per §11.4.95) so neither side
can silently drift from the other. Both representations remain
authoritative for human reading; the database is authoritative for
mechanical queries, drift-detection gates, and metadata that doesn't
fit naturally in Markdown (timestamps, evidence pointers, supersedence
chains).

The CLI is consumed by:

- `commit_all.sh` — pre-`git add -A` drift gate (this doc + §11.4.93/95).
- `scripts/sync_all_markdown_exports.sh` via the optional
  `--also-sync-workable-items-db` flag — runs `sync md-to-db` before the
  Markdown export sweep.
- Future challenge gates (CME-WORKABLE-ITEMS-001 per Q6) + paired §1.1
  mutations.

Graceful-degrade is intentional: callers SKIP silently when the binary
or DB is absent so historical branches without workable-items still
build + commit normally.

## Usage

```text
workable-items sync md-to-db [--db PATH] [--issues PATH] [--fixed PATH]
workable-items sync db-to-md [--db PATH] [--out-dir PATH]
workable-items diff          [--db PATH] [--issues PATH] [--fixed PATH]
workable-items validate      [--db PATH] [--schema-only]
workable-items add           --type Bug|Feature|Task --severity HIGH|MEDIUM|LOW
                             --title "..." --description "..." [--category A..E]
workable-items close         ATM-NNN --status fixed|implemented|completed|obsolete
                             --evidence PATH [--by AI|User] [--on YYYY-MM-DD]
                             [--reason ...] [--superseding-item ...]
                             [--triple-check-evidence PATH]
workable-items report        [--type ...] [--status ...] [--obsolete-audit]
workable-items --version
```

### Defaults (when the flag is omitted)

| Flag | Default | Rationale |
|---|---|---|
| `--db` | `docs/workable_items.db` | §11.4.95 canonical location |
| `--issues` | `Issues.md` | repo-root canonical tracker |
| `--fixed` | `Fixed.md` | repo-root canonical closure log |
| `--out-dir` | repo root | `db-to-md` writes alongside the originals |

### Exit codes

| Code | Meaning |
|---|---|
| 0 | success — round-trip byte-identical OR sync completed cleanly |
| 1 | drift detected (for `diff`) OR validation failure |
| 2 | usage error / missing required flag |

## Inputs

- `Issues.md` (UTF-8 Markdown, §11.4.15 + §11.4.16 + §11.4.54 conformant).
- `Fixed.md` (UTF-8 Markdown, §11.4.19 + §11.4.33 + §11.4.54 conformant).
- `docs/workable_items.db` (SQLite ≥ 3.40, schema per
  `cmd/workable-items/schema.sql`).

## Outputs

- `sync md-to-db` — writes rows into `workable_items` table; idempotent.
- `sync db-to-md` — writes regenerated `Issues.md` + `Fixed.md` into
  `--out-dir`. Round-trip MUST be byte-identical per Q3 acceptance
  criteria.
- `diff` — unified-diff output on stdout, exit 1 on drift.
- `validate` — schema + invariant report on stdout (exit 0 GREEN, 1
  FAIL).
- `report` — markdown / text report for operator review.

## Side-effects

- Writes to `docs/workable_items.db` for `sync md-to-db`, `add`, `close`.
- Temporary directories under `$TMPDIR/wi-*` for `diff`. Cleaned on exit.
- No network calls. No external process spawns. No filesystem mutation
  outside the paths named above.

## Dependencies

- Go 1.22+ at build time.
- `modernc.org/sqlite` — pure-Go SQLite driver (no CGO, no system
  `libsqlite3` required). Confirmed pure-Go per sources verification
  below.
- No runtime dependencies on the host other than the produced binary
  at `cmd/workable-items/workable-items`.

## Cross-references

- `Constitution.md` §11.4.93 — SQLite SSoT mandate.
- `Constitution.md` §11.4.95 — DB tracked in git with regeneration path.
- `Constitution.md` §11.4.99 — sources verification mandate (this doc).
- `Constitution.md` §11.4.54 — ATM-NNN identifier discipline.
- `Constitution.md` §11.4.18 — script documentation mandate (this doc).
- `Constitution.md` §11.4.44 — revision header (above).
- `commit_all.sh` — pre-commit drift gate caller.
- `scripts/sync_all_markdown_exports.sh` — `--also-sync-workable-items-db`
  flag caller.
- `cmd/workable-items/schema.sql` — DB schema (owned by PWU-Q3).
- `cmd/workable-items/*.go` — implementation (owned by PWU-Q3).

## Edge cases

- **Empty Issues.md or Fixed.md.** Both files MUST exist; an empty body
  is permitted (the parser handles zero-item trackers).
- **Binary built for wrong arch.** `commit_all.sh` checks `-x` only; an
  ARM-binary on x86_64 will fail loudly at first invocation.
- **DB locked by another process.** SQLite WAL keeps reads concurrent;
  writers serialize. `commit_all.sh`'s flock covers the parent.
- **Stale binary vs source.** `scripts/setup.sh` rebuilds when sources
  are newer; the gate trusts whatever binary is present.
- **No `docs/workable_items.db`.** Both callers SKIP silently — fresh
  clones / historical branches keep working.

## Sources verified 2026-05-28

- Project-local `cmd/workable-items/` source — read in-tree as of
  `2026-05-28T11:53Z` (this PWU-Q4 session).
- `constitution/Constitution.md` §11.4.93, §11.4.95, §11.4.99 — verified
  in `constitution/` submodule at the project's current pinned commit
  (per §11.4.78 CodeGraph index + §11.4.37 fetch-before-edit).
- `modernc.org/sqlite` package docs — fetched
  `https://pkg.go.dev/modernc.org/sqlite` `2026-05-28T11:54Z`. Confirmed
  pure-Go (CGo-free) port of SQLite 3.53.1; current displayed version
  v1.51.0 (BSD-3-Clause). Import path `modernc.org/sqlite` unchanged.

## Last verified

2026-05-28
