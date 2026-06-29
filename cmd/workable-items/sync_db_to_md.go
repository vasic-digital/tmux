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
