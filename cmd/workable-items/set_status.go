// set_status.go — non-terminal status transition for a workable item (TMX-066).
//
// `workable-items add` only ever creates a Queued item and `workable-items
// close` only ever moves an item to a TERMINAL status (Fixed/Implemented/
// Completed/Obsolete). There was no first-class way to move an item to an
// intermediate, NON-TERMINAL §11.4.15/§11.4.21 status (In progress / Ready for
// testing / In testing / Reopened / Operator-blocked / back to Queued) — so the
// only recourse was a hand-written `sqlite3 UPDATE`, which (a) bypasses the
// §11.4.34 audit trail and (b) is exactly the kind of out-of-band DB edit the
// §11.4.93 SSoT discipline forbids. This command closes that gap.
//
// It writes the new status + last_modified AND appends an audited "Updated"
// item_history row (§11.4.34 By/On/Reason) so every status change is traceable.

package main

import (
	"fmt"
	"strings"
	"time"
)

// nonTerminalStatuses is the closed-set of statuses `set-status` may assign —
// every §11.4.15/§11.4.21 status that is NOT a §11.4.33/§11.4.90 terminal
// closure value (those go through `close`).
var nonTerminalStatuses = []string{
	StatusQueued,
	StatusInProgress,
	StatusReadyForTest,
	StatusInTesting,
	StatusReopened,
	StatusOperatorBlock,
}

// SetStatusParams holds the CLI-provided parameters for `workable-items set-status`.
type SetStatusParams struct {
	ATMID  string
	Status string // raw CLI token (canonical value OR a short alias)
	By     string // AI|User (§11.4.34 attribution); defaults AI
	OnDate string // YYYY-MM-DD; defaults today
	Reason string // optional; defaults to a "<from> → <to>" note
}

// SetStatus applies a NON-TERMINAL status transition + audited history row.
func SetStatus(db *DB, p SetStatusParams) (*Item, error) {
	if strings.TrimSpace(p.ATMID) == "" {
		return nil, fmt.Errorf("TMX-NNN argument is required")
	}
	statusValue, err := mapSetStatusToken(p.Status)
	if err != nil {
		return nil, err
	}
	by := p.By
	if by == "" {
		by = "AI"
	}
	if by != "AI" && by != "User" {
		return nil, fmt.Errorf("--by must be AI or User (got %q)", by)
	}
	onDate := p.OnDate
	if onDate == "" {
		onDate = time.Now().UTC().Format("2006-01-02")
	}

	it, err := db.GetItem(p.ATMID)
	if err != nil {
		return nil, err
	}
	if it == nil {
		return nil, fmt.Errorf("item %s not found", p.ATMID)
	}

	// §11.4.54 + §11.4.19 — a reopen is a BLOCK-IDENTITY MIGRATION back to
	// Issues: the identity triple (current_location, category, code_ordinal) is
	// re-pointed from (Fixed, cat, ord) to (Issues, cat, ord). Block codes are
	// CATEGORY-LOCAL and are NOT unique across the two trackers, so that
	// destination can already be held by a different open item. Check BEFORE any
	// write so a refusal is side-effect free (§11.4.252) — the exact mirror of
	// close.go's checkDestinationBlockIdentityFree guard (TMX-099).
	if err := checkReopenDestinationBlockIdentityFree(db, it, statusValue); err != nil {
		return nil, err
	}

	from := it.Status
	fromLocation := it.CurrentLocation
	it.Status = statusValue
	// Every non-terminal status is an OPEN state, so the item belongs in the
	// Issues tracker. Moving from a terminal/Fixed status back to a non-terminal
	// one (e.g. Reopened) therefore migrates the item back to Issues.
	it.CurrentLocation = LocationIssues
	if err := db.UpsertItem(it); err != nil {
		return nil, fmt.Errorf("update: %w", err)
	}

	reason := p.Reason
	if reason == "" {
		reason = fmt.Sprintf("set-status %s → %s", from, statusValue)
	}
	// §11.4.226 — a block identity that changed files with no recorded evidence
	// is indistinguishable from one that was always there. Mirror close.go's
	// migration note when the identity actually crossed trackers.
	if fromLocation != LocationIssues {
		reason = appendReopenIdentityMigrationNote(reason, it, fromLocation)
	}
	ev := &ItemHistoryEvent{
		ATMID:     p.ATMID,
		EventType: "Updated",
		By:        by,
		OnDate:    onDate,
		Reason:    reason,
	}
	if err := db.InsertItemHistory(ev); err != nil {
		return nil, fmt.Errorf("insert history: %w", err)
	}
	return it, nil
}

// mapSetStatusToken normalises a CLI status token to a canonical NON-terminal
// status value, or returns an error. Terminal values are rejected with a pointer
// to `close`; unknown values list the accepted set (§11.4.6 no-guessing — a
// silent default would mask a typo).
func mapSetStatusToken(raw string) (string, error) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return "", fmt.Errorf("--status is required (one of: %s)", nonTerminalStatusList())
	}
	// Exact canonical non-terminal match wins first.
	for _, s := range nonTerminalStatuses {
		if trimmed == s {
			return s, nil
		}
	}
	// Exact canonical TERMINAL match → reject (use `close`).
	if terminalStatuses[trimmed] {
		return "", terminalStatusError(trimmed)
	}
	switch normaliseStatusToken(trimmed) {
	case "queued":
		return StatusQueued, nil
	case "in progress", "inprogress", "progress", "wip":
		return StatusInProgress, nil
	case "ready for testing", "ready", "readyfortesting":
		return StatusReadyForTest, nil
	case "in testing", "intesting", "testing":
		return StatusInTesting, nil
	case "reopened", "reopen":
		return StatusReopened, nil
	case "operator blocked", "operatorblocked", "blocked":
		return StatusOperatorBlock, nil
	case "fixed", "implemented", "completed", "obsolete":
		return "", terminalStatusError(trimmed)
	}
	return "", fmt.Errorf("invalid --status %q (want a non-terminal status: %s)", raw, nonTerminalStatusList())
}

func terminalStatusError(raw string) error {
	return fmt.Errorf("status %q is a TERMINAL closure value — use "+
		"`workable-items close TMX-NNN --status fixed|implemented|completed|obsolete --evidence ...` instead", raw)
}

// normaliseStatusToken lowercases and collapses `_`/`-`/whitespace runs to a
// single space so "In-progress", "in_progress", and "in   progress" all match.
func normaliseStatusToken(s string) string {
	s = strings.ToLower(s)
	s = strings.ReplaceAll(s, "_", " ")
	s = strings.ReplaceAll(s, "-", " ")
	return strings.Join(strings.Fields(s), " ")
}

// nonTerminalStatusList renders the accepted set for error messages.
func nonTerminalStatusList() string {
	return strings.Join(nonTerminalStatuses, " | ")
}

// checkReopenDestinationBlockIdentityFree refuses a set-status transition that
// would move the item's block identity onto an (Issues, category, code_ordinal)
// triple ALREADY held by a DIFFERENT item (TMX-099) — the mirror image of
// close.go's checkDestinationBlockIdentityFree.
//
// FALSE-POSITIVE GUARDS (§11.4.201(1) — a wrong refusal is as bad as a missed
// defect). Each mirrors the close-side guard so both agree on what "claims a
// block" means:
//
//   - code_ordinal <= 0 is the "unknown ordinal" sentinel, not a block claim
//     (every `workable-items add` row carries it), so it can never collide.
//   - an Obsolete destination may legitimately SHARE its superseder's block
//     (§11.4.90). mapSetStatusToken rejects Obsolete as a terminal value, so
//     this branch is unreachable for current callers; it is kept as the exact
//     structural mirror of the close-side guard and cannot mask a real
//     collision (no non-terminal caller can reach it).
//   - the item itself is excluded, so a repeated set-status on an item already
//     in Issues is never refused by its own row (§11.4.115 idempotent reopen).
//
// Only a DIFFERENT, non-Obsolete-destination holder is a genuine collision.
func checkReopenDestinationBlockIdentityFree(db *DB, it *Item, statusValue string) error {
	if it.CodeOrdinal <= 0 {
		return nil // sentinel ordinal — asserts no block claim.
	}
	if statusValue == StatusObsolete {
		return nil // §11.4.90 supersession may share its successor's block.
	}
	rows, err := db.conn.Query(
		`SELECT atm_id FROM items
		  WHERE current_location = ? AND category = ? AND code_ordinal = ? AND atm_id <> ?
		  ORDER BY atm_id`,
		LocationIssues, it.Category, it.CodeOrdinal, it.ATMID)
	if err != nil {
		return fmt.Errorf("check reopen destination block identity: %w", err)
	}
	defer rows.Close()
	var holders []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return fmt.Errorf("check reopen destination block identity: %w", err)
		}
		holders = append(holders, id)
	}
	if err := rows.Err(); err != nil {
		return fmt.Errorf("check reopen destination block identity: %w", err)
	}
	if len(holders) == 0 {
		return nil
	}
	code := fmt.Sprintf("%s%d", it.Category, it.CodeOrdinal)
	return fmt.Errorf(
		"§11.4.54: reopening %s would move its block identity to %s in Issues.md, "+
			"but that block is already held by %s — two items would claim one block. "+
			"Renumber %s's block to a free %s-category code in Fixed.md, re-run "+
			"`workable-items sync md-to-db`, then reopen again",
		it.ATMID, code, strings.Join(holders, ", "), it.ATMID, it.Category)
}

// appendReopenIdentityMigrationNote records the block-identity file transition
// on the reopen "Updated" history event, preserving any operator reason.
func appendReopenIdentityMigrationNote(reason string, it *Item, from string) string {
	note := fmt.Sprintf("block identity %s%d migrated %s -> %s",
		it.Category, it.CodeOrdinal, from, LocationIssues)
	if reason == "" {
		return note
	}
	return reason + "; " + note
}
