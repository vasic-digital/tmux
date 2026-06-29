# Workable-items SQLite-SSoT — Status

**Revision:** 1
**Last modified:** 2026-05-28T15:30:00Z

## Scope

Project-local Go binary at `cmd/workable-items/` implementing the
§11.4.93 SQLite-SSoT for workable items in the tmux project. The
constitution submodule (`constitution/scripts/workable-items/`) ships a
Phase-2 scaffold (stubs + canonical `schema.sql`); per the
`feedback_no_modify_constitution` memory rule this project cannot push
Phase-3+ code into the submodule and instead carries a drift-checked
local implementation. Upstream PR to HelixDevelopment/HelixConstitution
is tracked as a follow-up cycle.

## Current state — PWU-C cycle (2026-05-28)

| Item | Status | Evidence |
|---|---|---|
| `go.mod` + `go.sum` (modernc.org/sqlite, pure-Go, no CGO) | PASS | `go build ./cmd/workable-items` succeeds on darwin/arm64 |
| Embedded `schema.sql` (drift-checked vs constitution `6828ff2`) | PASS | `cmd/workable-items/schema.sql` header line 1 |
| `OpenDB` + WAL mode + `PRAGMA wal_checkpoint(TRUNCATE)` on Close | PASS | `TestOpenDB_AppliesSchema` |
| Subcommand router (`sync md-to-db`, `sync db-to-md`, `diff`, `validate`, `add`, `close`, `report`) | PASS | `workable-items --help` lists every subcommand |
| Markdown parser — recognises `### <CAT><N>. <title> — \`<STATUS>\`` headings | PASS | `TestRoundTrip_Issues_GoldenCorpus` |
| `**Status:**` / `**Type:**` / `**Severity:**` / `**TMX-ID:**` body-field extraction | PASS | `TestRoundTrip_Idempotent` (second sync allocates 0 new TMX-NNN) |
| Generator — re-emits `### <CAT><N>. <title> — \`<HINT>\`` byte-stable for golden corpus | PASS | `TestRoundTrip_Issues_GoldenCorpus`, `TestRoundTrip_Fixed_GoldenCorpus` |
| Idempotent re-sync (second `md-to-db` allocates 0 new IDs) | PASS | `TestRoundTrip_Idempotent` |
| §11.4.91 description clarity floor enforced | PASS | `TestValidate_DetectsShortDescription` |
| §11.4.33 type-aware closure vocabulary enforced | PASS | `TestValidate_DetectsTypeAwareClosureMismatch` |
| §11.4.5 + §11.4.69 evidence-required for `close` | PASS | `TestCloseItem_RequiresEvidence` |
| Initial real-corpus population | PASS | `docs/workable_items.db` (45 items: 1 from Issues.md, 44 from Fixed.md) |
| `-count=3` deterministic re-run | PASS | `go test ./cmd/workable-items/... -count=3` |

## Known §11.4.6 honest gaps

- **45 legacy items default to `Type=Task`** because the tmux corpus
  predates §11.4.16 — no `**Type:**` lines exist in Issues.md / Fixed.md.
  Result: `workable-items validate` reports §11.4.33 violations for
  every closed item that used the `RESOLVED` heading hint (mapped to
  `Fixed (→ Fixed.md)`, the Bug closure word) while the row's `type`
  is `Task` (which would expect `Completed (→ Fixed.md)`). This is
  expected initial state, not a bug in the binary. Closure migration
  per §11.4.33 is a separate one-time data-cleanup PWU.
- **Live corpus round-trip is NOT byte-identical.** The tmux
  Issues.md / Fixed.md carries free-form bodies (forensic anchors,
  multi-paragraph "Source-side fix" + "Captured evidence" sections,
  blockquotes, code fences) that cannot be losslessly reconstructed
  from the structured `items` schema's flat `description` field.
  Round-trip byte-identical equivalence is met for the GOLDEN
  TESTDATA corpus only; live-corpus drift is expected and
  authorised by the §11.4.93 phase-6 migration plan.
- **`commit_all.sh` / `verify.sh` / `sync_issues_docs.sh` integration is
  deferred** to PWU-E (main context owns scripts/* edits).

## Composition

§11.4.93 (SQLite-SSoT mandate) · §11.4.95 (DB tracked in git) ·
§11.4.54 (TMX-NNN identifier) · §11.4.33 (type-aware closure) ·
§11.4.91 (clarity floor) · §11.4.50 (`-count=3` deterministic
re-run) · §11.4.69 (`ab_pass_with_evidence` semantics applied to
`close` evidence-path) · §11.4.74 (project-local extension because
no-modify-constitution memory rule blocks upstream PR this cycle).
