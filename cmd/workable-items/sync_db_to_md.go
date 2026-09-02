// sync_db_to_md.go — SQLite DB → Issues.md + Fixed.md regeneration.
//
// Per §11.4.93 the round-trip must be byte-identical for the GOLDEN CORPUS
// (the structured-format files under testdata/) — the live tmux corpus
// pre-dates SQLite-SSoT and carries free-form bodies that cannot be losslessly
// reconstructed from individual schema fields. The migration plan (§11.4.93
// phase 1 → 6) explicitly authorises this: the binary's purpose is to be the
// SSoT for FUTURE workable items + retroactively-imported items; the legacy
// corpus is initial-seed material.
//
// For the testdata golden fixtures the format is deterministic + lossless:
//
//	# <title>
//	(optional preamble line)
//
//	## Items
//
//	### <CAT><N>. <title> — `<STATUS>`
//	**TMX-ID:** TMX-NNN
//	**Type:** <Type>
//	**Status:** `<status>`
//	**Severity:** <severity>
//
//	<description as a single paragraph>

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// SyncDBToMD regenerates Issues.md + Fixed.md under outDir from db state.
//
// Files written:
//
//	<outDir>/Issues.md
//	<outDir>/Fixed.md
//
// The format is the structured "golden" form documented at the top of this
// file — designed for byte-stable round-trip with the testdata fixtures.
func SyncDBToMD(db *DB, outDir string) error {
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return fmt.Errorf("mkdir %s: %w", outDir, err)
	}

	// PWU-Q3 (§11.4.93 phase-6) + TMX-060 (§11.4.108 structured-authoritative):
	// When document_sources holds a captured verbatim source we replay it, but
	// FIRST reconcile it against the structured items so the regeneration is
	// AUTHORITATIVE FROM THE STRUCTURED items. A block whose item's structured
	// current_location disagrees with the file it sits in (e.g. an item just
	// `close`d → current_location=Fixed but still sitting in the Issues blob) is
	// MOVED to the correct file — its rich operator-authored body is preserved
	// verbatim (that body lives ONLY in the blob; items.raw_body is empty for
	// add-created items), and only the heading status-hint + the `**Status:**`
	// line are rewritten to the current status. When NOTHING drifted (every
	// md→db-then-db→md round-trip with no intervening close), zero blocks move
	// and both blobs pass through BYTE-IDENTICAL (§11.4.93 preserved).
	issuesSrc, _ := db.GetDocumentSource(LocationIssues)
	fixedSrc, _ := db.GetDocumentSource(LocationFixed)

	if issuesSrc != "" || fixedSrc != "" {
		byID, err := buildItemIndex(db)
		if err != nil {
			return err
		}
		newIssues, newFixed, _ := reconcileLocations(issuesSrc, fixedSrc, byID)

		// TMX-094 (§A6 ADD-ROWS-NOT-RENDERED-001). reconcileLocations only MOVES
		// blocks that already exist in a blob; it never APPENDS one for an item
		// that exists in the structured `items` table but appears in NEITHER blob.
		// `workable-items add` writes an items row and nothing to
		// document_sources, so on the live corpus (where a blob is always
		// non-empty and this branch is always taken) an add-created row was a DB
		// row no tracker document ever showed — a silent loss of visibility at the
		// requirements-intake layer (§11.4.202 / §11.4.197). Sourceless items are
		// rendered here through writeItemBlock's own structured fallback path.
		sourceless := sourcelessItems(byID, issuesSrc, fixedSrc)
		newIssues = appendRenderedItems(newIssues, sourceless, LocationIssues)
		newFixed = appendRenderedItems(newFixed, sourceless, LocationFixed)

		if issuesSrc != "" {
			if err := os.WriteFile(filepath.Join(outDir, "Issues.md"), []byte(newIssues), 0o644); err != nil {
				return fmt.Errorf("write Issues.md (reconciled): %w", err)
			}
		} else {
			issuesItems, err := db.ItemsByLocation(LocationIssues)
			if err != nil {
				return err
			}
			if err := writeIssuesMD(filepath.Join(outDir, "Issues.md"), issuesItems); err != nil {
				return err
			}
		}

		if fixedSrc != "" {
			if err := os.WriteFile(filepath.Join(outDir, "Fixed.md"), []byte(newFixed), 0o644); err != nil {
				return fmt.Errorf("write Fixed.md (reconciled): %w", err)
			}
		} else {
			fixedItems, err := db.ItemsByLocation(LocationFixed)
			if err != nil {
				return err
			}
			if err := writeFixedMD(filepath.Join(outDir, "Fixed.md"), fixedItems); err != nil {
				return err
			}
		}
	} else {
		// Both blobs empty — fully structural generation from the items table.
		issuesItems, err := db.ItemsByLocation(LocationIssues)
		if err != nil {
			return err
		}
		if err := writeIssuesMD(filepath.Join(outDir, "Issues.md"), issuesItems); err != nil {
			return err
		}
		fixedItems, err := db.ItemsByLocation(LocationFixed)
		if err != nil {
			return err
		}
		if err := writeFixedMD(filepath.Join(outDir, "Fixed.md"), fixedItems); err != nil {
			return err
		}
	}

	if err := db.MetaSet("last_sync_direction", "db-to-md"); err != nil {
		return err
	}
	if err := db.MetaSet("last_sync_timestamp", time.Now().UTC().Format(time.RFC3339)); err != nil {
		return err
	}
	return nil
}

// sourcelessItems returns, in ATM-id order, the items that have NO source text
// anywhere: neither a captured verbatim body of their own (items.raw_body) nor a
// block in either document blob. Those are exactly the rows `workable-items add`
// creates, and they are the only rows db→md may safely SYNTHESISE a block for.
//
// Absence is established from THREE independent signals, because a false
// positive here DUPLICATES an item's block into the tracker — corruption of the
// same class §11.4.108 forbids, and strictly worse than the omission it repairs
// (§11.4.201(1): a false-positive is a defect, not a safe default):
//
//  1. items.raw_body is empty. This is the primary scope gate, and it is
//     deliberately NARROWER than "the item has a block": it scopes the pass to
//     rows `add` created, which are the only rows that carry no captured text at
//     all. A non-empty raw_body proves the row's body was captured from a
//     document at some point — it does NOT prove a block for that row exists in
//     either tracker TODAY. Counter-example measured on the live corpus
//     2026-09-01: TMX-050 (category F, code_ordinal 1, current_location Fixed,
//     raw_body 3675 bytes) has NO `### F1.` block in either tracker; its only
//     Fixed.md mention is prose inside TMX-055's block ("Migrated from Issues.md
//     F1 (TMX-050)", Fixed.md:167), which is not a `**TMX-ID:**` line. Signals 2
//     and 3 are both silent for it, so this gate — and only this gate — is what
//     stops db→md synthesising a duplicate block for it. The code is therefore
//     CORRECT (conservatively declining to duplicate); what is out of scope is
//     REPAIRING a row like TMX-050 whose captured body no longer has a block.
//     That is a separate defect class, tracked separately, and this pass must
//     not be widened to cover it by relaxing this gate — doing so duplicates
//     TMX-050 into Fixed.md (measured: 86 headings vs 85, a second `### F1.`).
//     Measured on the live corpus (95 items, both blobs seeded): 0 rows have an
//     empty raw_body, so this pass appends nothing to the real documents today —
//     the live regeneration stays byte-identical.
//  2. No `**TMX-ID:** <id>` line anywhere in either blob.
//  3. No `### <CAT><N>` block that is plausibly THIS item's. A bare code match
//     is not sufficient: heading codes are not unique (measured on the live
//     corpus 2026-09-01: 93 code headings, 85 distinct — 8 codes appear twice), so
//     a block whose own `**TMX-ID:**` line names a DIFFERENT item is NOT this
//     item's block and must not suppress it. A block declaring no id at all
//     asserts no ownership, and is conservatively treated as possibly-its-own
//     (decline to duplicate — §11.4.201(1)). The ordinal is checked BOTH as the
//     stored CodeOrdinal and as writeItemBlock's atmOrdinal fallback, because
//     the two disagree for legacy rows: TMX-039 and TMX-041 store code_ordinal 0
//     and genuinely sit under `### B0.` / `### C0.` headings, while an
//     add-created row stores 0 as the "no block claim" sentinel and is rendered
//     under its ATM ordinal. Checking only the fallback form flagged both as
//     absent.
//
// Signals 2 and 3 are each individually insufficient, measured on the live
// corpus 2026-09-01: the id-line signal alone flags 62 of 95 items (61 of them
// false — their blocks ARE present, matched by heading code, because the
// operator corpus predates the `**TMX-ID:**` line convention).
//
// Each of these signals now carries its own §1.1 guard with a paired mutation
// observed to make it FAIL — see sourceless_signals_test.go, which also records
// the one clause (`owners[it.ATMID]`) that is measurably redundant rather than
// load-bearing.
func sourcelessItems(byID map[string]*Item, blobs ...string) []*Item {
	ids := map[string]bool{}
	// code → the set of ticket ids the blocks under that code declare. The
	// empty string records a block that declares NO id (it asserts no ownership,
	// exactly as validate_identity.go's markdownBlockOwners treats it).
	codeOwners := map[string]map[string]bool{}
	for _, blob := range blobs {
		if blob == "" {
			continue
		}
		curCode := ""
		curOwned := false
		closeBlock := func() {
			if curCode != "" && !curOwned {
				if codeOwners[curCode] == nil {
					codeOwners[curCode] = map[string]bool{}
				}
				codeOwners[curCode][""] = true
			}
			curCode, curOwned = "", false
		}
		for _, ln := range strings.Split(blob, "\n") {
			if m := blockCodeRE.FindStringSubmatch(ln); m != nil {
				closeBlock()
				curCode = strings.ToUpper(m[1]) + strings.TrimLeft(m[2], "0")
				if curCode == strings.ToUpper(m[1]) {
					curCode += "0"
				}
				continue
			}
			if m := atmIDLineRE.FindStringSubmatch(ln); m != nil {
				ids[m[1]] = true
				if curCode != "" {
					if codeOwners[curCode] == nil {
						codeOwners[curCode] = map[string]bool{}
					}
					codeOwners[curCode][m[1]] = true
					curOwned = true
				}
			}
		}
		closeBlock()
	}

	// blockClaimedBy reports whether a block under code is this item's block, or
	// a block that claims no owner at all (which this pass conservatively treats
	// as possibly-its-own and therefore declines to duplicate).
	blockClaimedBy := func(code string, it *Item) bool {
		owners := codeOwners[code]
		if owners == nil {
			return false
		}
		return owners[it.ATMID] || owners[""]
	}

	var out []*Item
	for _, it := range byID {
		if it == nil || it.RawBody != "" || ids[it.ATMID] {
			continue
		}
		cat := strings.ToUpper(it.Category)
		// An ordinal of 0 is the SENTINEL — it asserts NO block claim, exactly
		// as validate_identity.go:163 treats it. Deriving a code from it
		// ("A"+"0" = "A0") turned the sentinel into a claim on whatever block
		// happens to carry that code: Fixed.md:2585 holds a real
		// `### A0. Initial migration …` block declaring no `**TMX-ID:**`, so
		// codeOwners["A0"][""] answered for EVERY add-created row in category A
		// and silently suppressed the exact rows TMX-094 renders. Measured:
		// TMX-099/TMX-100 sat in the DB rendering into neither tracker.
		if it.CodeOrdinal > 0 && blockClaimedBy(fmt.Sprintf("%s%d", cat, it.CodeOrdinal), it) {
			continue
		}
		if blockClaimedBy(fmt.Sprintf("%s%d", cat, atmOrdinal(it.ATMID)), it) {
			continue
		}
		out = append(out, it)
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].ATMID < out[j].ATMID })
	return out
}

// appendRenderedItems appends structured blocks for those sourceless items whose
// current_location is loc. With no such item it returns doc UNCHANGED, so the
// §11.4.93 byte-identical round-trip is preserved on every existing path.
func appendRenderedItems(doc string, sourceless []*Item, loc string) string {
	var blocks []string
	for _, it := range sourceless {
		if it.CurrentLocation != loc {
			continue
		}
		var sb strings.Builder
		writeItemBlock(&sb, it)
		blocks = append(blocks, sb.String())
	}
	return appendBlocksToDoc(doc, blocks)
}

func writeIssuesMD(path string, items []*Item) error {
	var sb strings.Builder
	sb.WriteString("# vasic-digital tmux — Open Issues Tracker\n\n")
	sb.WriteString("> §11.4.93 SQLite-SSoT generated. Edit the DB via\n")
	sb.WriteString("> `workable-items add|close|...` — direct MD edits are obliterated\n")
	sb.WriteString("> by the next `workable-items sync db-to-md` invocation.\n\n")
	sb.WriteString("## Items\n\n")

	if len(items) == 0 {
		sb.WriteString("_No open items._\n")
		return os.WriteFile(path, []byte(sb.String()), 0o644)
	}

	// Group by category.
	cats := map[string][]*Item{}
	var catKeys []string
	for _, it := range items {
		c := it.Category
		if c == "" {
			c = "Z" // ungrouped
		}
		if _, seen := cats[c]; !seen {
			catKeys = append(catKeys, c)
		}
		cats[c] = append(cats[c], it)
	}
	sort.Strings(catKeys)

	for _, c := range catKeys {
		group := cats[c]
		sort.SliceStable(group, func(i, j int) bool {
			return group[i].ATMID < group[j].ATMID
		})
		sb.WriteString(fmt.Sprintf("### Category %s\n\n", c))
		for _, it := range group {
			writeItemBlock(&sb, it)
		}
	}
	return os.WriteFile(path, []byte(sb.String()), 0o644)
}

func writeFixedMD(path string, items []*Item) error {
	var sb strings.Builder
	sb.WriteString("# vasic-digital tmux — Closed Items Tracker\n\n")
	sb.WriteString("> §11.4.93 SQLite-SSoT generated. Closures land here via\n")
	sb.WriteString("> `workable-items close " + TicketPrefix + "NNN --status fixed|implemented|completed|obsolete`.\n\n")
	sb.WriteString("## Items\n\n")

	if len(items) == 0 {
		sb.WriteString("_No closed items yet._\n")
		return os.WriteFile(path, []byte(sb.String()), 0o644)
	}

	// Sort by ATM-NNN descending (most recent closure first, as a proxy).
	sort.SliceStable(items, func(i, j int) bool {
		return items[i].ATMID > items[j].ATMID
	})
	for _, it := range items {
		writeItemBlock(&sb, it)
	}
	return os.WriteFile(path, []byte(sb.String()), 0o644)
}

func writeItemBlock(sb *strings.Builder, it *Item) {
	// Heading with code + title + trailing status hint. The category-local
	// ordinal (CodeOrdinal) survives round-trip verbatim — distinct from the
	// global ATM-NNN ordinal which is monotonic per §11.4.54.
	statusHint := mapStatusToHint(it.Status)
	codeOrdinal := it.CodeOrdinal
	if codeOrdinal == 0 {
		// Fallback: use ATM ordinal so existing rows without a code_ordinal
		// migration still produce a stable heading.
		codeOrdinal = atmOrdinal(it.ATMID)
	}
	heading := fmt.Sprintf("### %s%d. %s — `%s`",
		it.Category, codeOrdinal, it.Title, statusHint)
	sb.WriteString(heading)
	sb.WriteString("\n")

	// PWU-Q3 (§11.4.93 phase-6): when raw_body is non-empty, re-emit it
	// VERBATIM. The structured Type/Status/Severity/TMX-ID prefix lines
	// are NOT prepended because they are already inside raw_body (the
	// parser captured everything between the heading and the next heading
	// without stripping). This is what makes the round-trip byte-identical
	// for live-corpus free-form bodies (forensic anchors, multi-paragraph
	// captured-evidence, blockquotes, code fences).
	if it.RawBody != "" {
		sb.WriteString(it.RawBody)
		return
	}

	// Fallback path for items created via `workable-items add` (no source
	// body yet) — emit the structured prefix-block + description.
	sb.WriteString(fmt.Sprintf("**"+TicketLabel+":** %s\n", it.ATMID))
	sb.WriteString(fmt.Sprintf("**Type:** %s\n", it.Type))
	sb.WriteString(fmt.Sprintf("**Status:** `%s`\n", it.Status))
	if it.Severity != "" {
		sb.WriteString(fmt.Sprintf("**Severity:** %s\n", it.Severity))
	}
	sb.WriteString("\n")
	sb.WriteString(it.Description)
	sb.WriteString("\n\n")
}

// atmIDOrdinal extracts the numeric suffix of a TMX-NNN id and re-renders as
// an ordinal (so TMX-007 → "7"). Used in legacy-style headings.
func atmIDOrdinal(atmID string) string {
	if strings.HasPrefix(atmID, TicketPrefix) {
		// Strip the ticket prefix and lstrip zeros.
		s := strings.TrimLeft(atmID[len(TicketPrefix):], "0")
		if s == "" {
			s = "0"
		}
		return s
	}
	return atmID
}

// mapStatusToHint returns the short heading hint for a §11.4.15 status value.
func mapStatusToHint(status string) string {
	switch status {
	case StatusQueued:
		return "OPEN"
	case StatusInProgress:
		return "PARTIAL"
	case StatusReadyForTest:
		return "INVESTIGATED"
	case StatusInTesting:
		return "RUNNING"
	case StatusReopened:
		return "Reopened"
	case StatusOperatorBlock:
		return "BLOCKED"
	case StatusFixed:
		return "RESOLVED"
	case StatusImplemented:
		return "Implemented"
	case StatusCompleted:
		return "Completed"
	case StatusObsolete:
		return "Obsolete"
	}
	return status
}
