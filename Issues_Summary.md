# Issues — Workable-items Summary (generated)

**Revision:** 1
**Content SHA256:** 01de5540730e92a61590060da8618c959d2050412330ffb5e5efcef653d5cb5f

> GENERATED FILE — do not hand-edit. Every figure below is derived from
> `./cmd/workable-items/workable-items report` against the git-tracked
> SQLite SSoT `docs/workable_items.db` (§11.4.93 / §11.4.95).

## Scope

OPEN / non-terminal items — the rows that live in `Issues.md`.

## Counts by status

| Value | Count |
|---|---:|
| Queued | 8 |
| Ready for testing | 3 |
| Reopened | 1 |
| **Total** | **12** |

## Counts by type

| Value | Count |
|---|---:|
| Bug | 7 |
| Task | 5 |
| **Total** | **12** |

## Per-item ledger

| TMX-ID | Type | Status |
|---|---|---|
| TMX-076 | Task | Ready for testing |
| TMX-077 | Bug | Ready for testing |
| TMX-080 | Bug | Reopened |
| TMX-081 | Bug | Queued |
| TMX-093 | Task | Queued |
| TMX-094 | Bug | Queued |
| TMX-095 | Bug | Ready for testing |
| TMX-099 | Bug | Queued |
| TMX-100 | Task | Queued |
| TMX-101 | Task | Queued |
| TMX-102 | Task | Queued |
| TMX-103 | Bug | Queued |

## Provenance

Control needle: the `report` footer reported the same total as the
number of parsed ledger rows; a mismatch aborts generation.
`Reopens` (§11.4.55) is not emitted by the current `report` command;
this summary does not invent it. Honest gap, tracked under TMX-102.
