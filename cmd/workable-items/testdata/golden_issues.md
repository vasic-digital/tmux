# vasic-digital tmux — Open Issues Tracker

> §11.4.93 SQLite-SSoT generated. Edit the DB via
> `workable-items add|close|...` — direct MD edits are obliterated
> by the next `workable-items sync db-to-md` invocation.

## Items

### Category A

### A1. Tooling harness for round-trip testing needs golden corpus — `OPEN`
**TMX-ID:** TMX-001
**Type:** Task
**Status:** `Queued`
**Severity:** MEDIUM

Establish a deterministic golden fixture corpus that exercises the md-to-db and db-to-md round-trip with byte-identical equivalence per §11.4.93.

### Category B

### B1. Parser must handle backticks inside titles without confusion — `OPEN`
**TMX-ID:** TMX-002
**Type:** Bug
**Status:** `Queued`
**Severity:** HIGH

Titles containing backticked code references (e.g. `scripts/test_e2e.sh`) must parse intact and not be truncated by the heading status-hint extractor.

