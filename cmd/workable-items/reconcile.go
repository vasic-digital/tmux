// reconcile.go — §11.4.108 structured-items-authoritative db→md reconciliation.
//
// Root cause this file fixes (TMX-060): `workable-items close` updates the
// structured `items` row (status → terminal, current_location → Fixed) but the
// db→md regeneration replayed the VERBATIM `document_sources` whole-file blob
// captured at the last md→db. That blob still carried the closed item's OLD
// block, so a closed item stayed in Issues.md with its old status and NEVER
// migrated to Fixed.md (a §11.4.108 SOURCE→ARTIFACT integrity failure: the
// structured SSoT and the regenerated artifact disagreed).
//
// The fix makes db→md AUTHORITATIVE FROM THE STRUCTURED items while preserving
// the §11.4.93 byte-identical round-trip for UNCHANGED items: a verbatim block
// whose item's structured current_location DISAGREES with the file it sits in
// is MOVED (verbatim body preserved — the rich operator-authored content lives
// only in the blob, NOT in items.raw_body for add-created items — only the
// heading status-hint + the `**Status:**` line are rewritten) to the correct
// file. When no item's location disagrees with its blob (every round-trip test:
// md→db then db→md with no close), zero blocks move and both blobs pass through
// byte-identical.

package main

import "strings"

// buildItemIndex returns a TMX-NNN → *Item map of every structured item.
func buildItemIndex(db *DB) (map[string]*Item, error) {
	all, err := db.AllItems()
	if err != nil {
		return nil, err
	}
	byID := make(map[string]*Item, len(all))
	for _, it := range all {
		byID[it.ATMID] = it
	}
	return byID, nil
}

// itemBlockRange is the half-open [start, end) line range of one item's block
// within a document blob, plus its rewritten form for the destination file.
type itemBlockRange struct {
	start     int    // index of the `### ` heading line
	end       int    // index of the first boundary line AFTER the block (exclusive)
	rewritten string // the block rewritten with the item's CURRENT status
}

// isBlockBoundaryLine reports whether line ends the current item's block — any
// Markdown heading (`# `..`###### `, including a no-period `### ` block) or a
// `---` horizontal rule. A boundary line is scaffolding that belongs to neither
// the preceding nor a moved item, so it is preserved in place.
func isBlockBoundaryLine(line string) bool {
	if anyHeadingRE.MatchString(line) {
		return true
	}
	return strings.TrimSpace(line) == "---"
}

// headingHintForStatus returns the trailing `\`<hint>\“ heading marker for a
// status. Terminal closures use the Fixed.md universal `RESOLVED` marker
// (matching the existing corpus convention — see parser.go commit() note);
// non-terminal statuses (a reopen moving Fixed→Issues) use the §11.4.15 hint.
func headingHintForStatus(status string) string {
	if terminalStatuses[status] {
		return "RESOLVED"
	}
	return mapStatusToHint(status)
}

// rewriteBlockForStatus rewrites a verbatim item block so its visible status
// matches the item's CURRENT structured status: the heading's trailing
// `\`<hint>\“ marker and the body's `**Status:** ...` line. Everything else
// (the rich operator-authored body) is preserved verbatim.
func rewriteBlockForStatus(blockLines []string, it *Item) string {
	out := make([]string, len(blockLines))
	copy(out, blockLines)

	// Heading: replace the trailing status hint, if present.
	if len(out) > 0 && strings.HasPrefix(out[0], "### ") {
		if sm := trailingStatusRE.FindStringSubmatchIndex(out[0]); sm != nil {
			out[0] = out[0][:sm[0]] + " — `" + headingHintForStatus(it.Status) + "`"
		}
	}
	// Body: replace the first `**Status:** ...` line with the structured value
	// (no backticks — matches the Fixed.md `**Status:** Completed (→ Fixed.md)`
	// convention and re-parses correctly via statusLineRE on a future md→db).
	for i := 1; i < len(out); i++ {
		if statusLineRE.MatchString(out[i]) {
			out[i] = "**Status:** " + it.Status
			break
		}
	}
	return strings.Join(out, "\n")
}

// findMovedBlocks scans srcLines for item blocks (keyed on a `**TMX-ID:** TMX-NNN`
// line) whose structured item.current_location != srcLoc — those blocks must
// MOVE out of this file. Returns the ranges (in document order) with their
// rewritten destination form.
func findMovedBlocks(srcLines []string, byID map[string]*Item, srcLoc string) []itemBlockRange {
	var moves []itemBlockRange
	for i := 0; i < len(srcLines); i++ {
		m := atmIDLineRE.FindStringSubmatch(srcLines[i])
		if m == nil {
			continue
		}
		id := m[1]
		it := byID[id]
		if it == nil || it.CurrentLocation == srcLoc {
			continue // unknown id, or it belongs in this file — leave in place.
		}
		// Block start: nearest preceding `### ` heading.
		start := -1
		for h := i; h >= 0; h-- {
			if strings.HasPrefix(srcLines[h], "### ") {
				start = h
				break
			}
		}
		if start < 0 {
			continue // malformed (TMX-ID with no enclosing heading) — leave.
		}
		// Block end: first boundary line after the TMX-ID line.
		end := len(srcLines)
		for b := i + 1; b < len(srcLines); b++ {
			if isBlockBoundaryLine(srcLines[b]) {
				end = b
				break
			}
		}
		moves = append(moves, itemBlockRange{
			start:     start,
			end:       end,
			rewritten: rewriteBlockForStatus(srcLines[start:end], it),
		})
		i = end - 1 // resume scanning after this block
	}
	return moves
}

// appendBlocksToDoc appends moved blocks to a destination document, normalising
// so each block is separated by exactly one blank line and the file ends with a
// single trailing newline.
func appendBlocksToDoc(dst string, blocks []string) string {
	if len(blocks) == 0 {
		return dst
	}
	var sb strings.Builder
	sb.WriteString(strings.TrimRight(dst, "\n"))
	sb.WriteString("\n\n")
	for _, b := range blocks {
		sb.WriteString(strings.TrimRight(b, "\n"))
		sb.WriteString("\n\n")
	}
	return strings.TrimRight(sb.String(), "\n") + "\n"
}

// removeRanges returns srcLines with the given half-open [start,end) ranges
// removed, preserving the order of the kept lines (and the original trailing
// newline, since the final "" element produced by strings.Split is never inside
// a removed interior range).
func removeRanges(srcLines []string, moves []itemBlockRange) []string {
	drop := make([]bool, len(srcLines))
	for _, mv := range moves {
		for k := mv.start; k < mv.end && k < len(srcLines); k++ {
			drop[k] = true
		}
	}
	kept := make([]string, 0, len(srcLines))
	for k, ln := range srcLines {
		if !drop[k] {
			kept = append(kept, ln)
		}
	}
	return kept
}

// reconcileLocations is the structured-authoritative reconciliation of the two
// verbatim document blobs. It moves any block whose structured location
// disagrees with the file it currently sits in (Issues↔Fixed), preserving the
// verbatim body and rewriting only the visible status. When no block needs to
// move (every round-trip test), both blobs are returned UNCHANGED → byte-
// identical regeneration is preserved.
func reconcileLocations(issuesSrc, fixedSrc string, byID map[string]*Item) (newIssues, newFixed string, moved int) {
	issuesLines := strings.Split(issuesSrc, "\n")
	fixedLines := strings.Split(fixedSrc, "\n")

	// Issues blob: blocks whose item is now Fixed move OUT to Fixed.
	toFixedMoves := findMovedBlocks(issuesLines, byID, LocationIssues)
	// Fixed blob: blocks whose item is now non-terminal (reopened) move OUT to Issues.
	toIssuesMoves := findMovedBlocks(fixedLines, byID, LocationFixed)

	moved = len(toFixedMoves) + len(toIssuesMoves)
	if moved == 0 {
		// Fast path — nothing drifted: pass both blobs through byte-identical.
		return issuesSrc, fixedSrc, 0
	}

	issuesKept := removeRanges(issuesLines, toFixedMoves)
	fixedKept := removeRanges(fixedLines, toIssuesMoves)

	var toFixedBlocks, toIssuesBlocks []string
	for _, mv := range toFixedMoves {
		toFixedBlocks = append(toFixedBlocks, mv.rewritten)
	}
	for _, mv := range toIssuesMoves {
		toIssuesBlocks = append(toIssuesBlocks, mv.rewritten)
	}

	newIssues = appendBlocksToDoc(strings.Join(issuesKept, "\n"), toIssuesBlocks)
	newFixed = appendBlocksToDoc(strings.Join(fixedKept, "\n"), toFixedBlocks)
	return newIssues, newFixed, moved
}
