# Workable-items SQLite-SSoT — Status Summary

**Revision:** 1
**Last modified:** 2026-05-28T15:30:00Z

## Page 1 — For the operator (non-developer)

**What works.** A new local command-line tool (`workable-items`) lets
us treat the project's Issues + Fixed trackers as one SQLite database
instead of two free-form Markdown files. The database file lives at
`docs/workable_items.db` and IS checked into git (it is the source of
truth, not a temporary artefact). Forty-five existing items
(1 open + 44 closed) were imported on first run with zero data loss
and stable, never-changing `ATM-NNN` identifiers.

**What's still pending.** Two operator-visible follow-ups remain:
(1) the existing closed items are tagged `Type=Task` by default and
need a one-time review to mark the actual `Bug` / `Feature` ones;
(2) the project's commit script (`commit_all.sh`) isn't yet wired to
auto-sync the DB before each commit. Both are tracked as separate
work units.

**What you can do today.** Add a new item with
`./cmd/workable-items/workable-items add --type Bug --title "..."
--description "..." --severity HIGH`. Close one with
`./cmd/workable-items/workable-items close ATM-007 --status fixed
--evidence /path/to/proof.log`. Audit the whole tracker with
`./cmd/workable-items/workable-items validate`.

## Page 2 — For software engineers

**Binary location.** `cmd/workable-items/main.go` (Go 1.21+,
`modernc.org/sqlite` pure-Go driver — no CGO so it cross-compiles to
Mistborn `arm64` and nezha `x86_64` without C toolchains).

**Schema.** `cmd/workable-items/schema.sql` is `go:embed`-baked into
the binary; header line 1 carries `DRIFT-CHECK: ... constitution
6828ff2`. Re-run `workable-items validate --schema-only` after any
constitution submodule pull. Adds two project-local fields beyond the
constitution scaffold: `category` (A..E heading-prefix letter) and
`code_ordinal` (category-local ordinal) — preserved verbatim across
round-trip so generator emits `### B3. ...` for a category=B
code_ordinal=3 row.

**Test coverage.** 10 unit + invariant tests, all PASS at `-count=3`:

| Test | Section enforced |
|---|---|
| `TestOpenDB_AppliesSchema` | schema bootstrap |
| `TestNextATMID_Monotonic` | §11.4.54 monotonic ATM-NNN |
| `TestUpsertItem_Idempotent` | DB-layer idempotency |
| `TestValidate_DetectsShortDescription` | §11.4.91 clarity floor |
| `TestValidate_DetectsTypeAwareClosureMismatch` | §11.4.33 closure vocab |
| `TestAddItem_AllocatesATMAndOpensHistory` | §11.4.54 + item_history Opened event |
| `TestCloseItem_RequiresEvidence` | §11.4.5 + §11.4.69 evidence-required |
| `TestRoundTrip_Issues_GoldenCorpus` | §11.4.93 byte-identical round-trip (Issues) |
| `TestRoundTrip_Fixed_GoldenCorpus` | §11.4.93 byte-identical round-trip (Fixed) |
| `TestRoundTrip_Idempotent` | second-sync allocates 0 new ATM-NNN |

**Initial real-corpus stats.** `45` items in `items` table; 1 row at
`current_location='Issues'` (ATM-001 = B3 in Issues.md), 44 rows at
`current_location='Fixed'` (ATM-002..ATM-045 = A1..A36 Fixed.md). On
seed the binary allocated ATM-NNN sequentially in source-order and
wrote 45 `item_history.event_type='Opened'` rows with
`by='AI', reason='initial md-to-db sync'`.

**Honest §11.4.6 gaps.** (a) 45 legacy items default to `Type=Task` —
tmux corpus has no `**Type:**` lines anywhere. Validate reports §11.4.33
mismatches as a result; these are honest data-import limitations, not
binary defects. (b) Live-corpus round-trip is NOT byte-identical — the
free-form bodies (forensic anchors, multi-paragraph "Source-side fix"
sections, blockquotes, code fences) cannot be losslessly reconstructed
from the flat `description` column. Round-trip byte-identical
equivalence is met for the **golden testdata corpus only** (per
§11.4.93 phase-6 migration plan).

**Composes with.** §11.4.93 (SSoT mandate) · §11.4.95 (tracked DB) ·
§11.4.54 (ATM-NNN) · §11.4.33 (closure vocab) · §11.4.91 (clarity) ·
§11.4.50 (`-count=3`) · §11.4.69 (evidence-required) · §11.4.74
(project-local extension per no-modify-constitution rule).

**Out-of-scope (deferred to PWU-E + future cycles).**
`scripts/commit_all.sh` pre-commit `diff` gate; `scripts/verify.sh`
schema-validate hook; `scripts/testing/sync_issues_docs.sh` Markdown
regen invocation; upstream PR to HelixDevelopment/HelixConstitution
landing the Phase-3+ Go code in the constitution submodule.
