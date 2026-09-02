// close.go — terminal-state transition for a workable item.
//
// Requires --evidence path per §11.4.5/§11.4.69; appends closure history;
// migrates current_location to Fixed.

package main

import (
	"fmt"
	"os"
	"strings"
	"time"
)

// CloseItemParams holds the CLI-provided parameters for `workable-items close`.
type CloseItemParams struct {
	ATMID    string
	Status   string // "fixed" | "implemented" | "completed" | "obsolete"
	Evidence string
	By       string // AI|User
	OnDate   string // YYYY-MM-DD, defaults to today
	Reason   string // optional; for obsolete it's a §11.4.90 reason code
	// §11.4.90 — when --status=obsolete, these are mandatory:
	ObsoleteSupersedingItem string
	ObsoleteTripleCheckPath string
}

// CloseItem applies the terminal state transition.
func CloseItem(db *DB, p CloseItemParams) (*Item, error) {
	if p.ATMID == "" {
		return nil, fmt.Errorf("TMX-NNN argument is required")
	}
	if p.Evidence == "" {
		return nil, fmt.Errorf("--evidence path is required (§11.4.5 + §11.4.69)")
	}
	// Verify evidence path exists + non-empty (§11.4.69 ab_pass_with_evidence semantics).
	st, err := os.Stat(p.Evidence)
	if err != nil {
		return nil, fmt.Errorf("--evidence %s: %w", p.Evidence, err)
	}
	if st.Size() == 0 {
		return nil, fmt.Errorf("--evidence %s exists but is empty (§11.4.69 forbids fail-open-skip)", p.Evidence)
	}
	if p.OnDate == "" {
		p.OnDate = time.Now().UTC().Format("2006-01-02")
	}
	if p.By == "" {
		p.By = "AI"
	}

	statusValue, eventType, err := closeStatusMapping(p.Status)
	if err != nil {
		return nil, err
	}

	it, err := db.GetItem(p.ATMID)
	if err != nil {
		return nil, err
	}
	if it == nil {
		return nil, fmt.Errorf("item %s not found", p.ATMID)
	}
	// §11.4.33 — closure status MUST match Type-derived expectation, EXCEPT
	// when --status=obsolete (always Obsolete regardless of Type).
	if statusValue != StatusObsolete {
		want := closureStatusForType(it.Type)
		if statusValue != want {
			return nil, fmt.Errorf("§11.4.33: type %q requires closure status %q, got %q",
				it.Type, want, statusValue)
		}
	}
	// §11.4.54 + §11.4.19 — the block-identity destination must be FREE.
	//
	// A close is a BLOCK-IDENTITY MIGRATION, not only a status change: the
	// identity triple (current_location, category, code_ordinal) is a pointer to
	// one markdown block, and flipping current_location re-points it from
	// (Issues, cat, ord) to (Fixed, cat, ord). Block codes are CATEGORY-LOCAL and
	// are NOT unique across the two trackers, so that destination can already be
	// occupied — and this function used to write it regardless, producing the
	// two-items-one-block state ValidateBlockIdentity exists to report.
	//
	// Checked BEFORE any write so the refusal is side-effect free
	// (§11.4.252 fail-closed) and the row is left exactly as it was.
	if err := checkDestinationBlockIdentityFree(db, it, statusValue); err != nil {
		return nil, err
	}

	fromLocation := it.CurrentLocation
	it.Status = statusValue
	it.CurrentLocation = LocationFixed
	if err := db.UpsertItem(it); err != nil {
		return nil, fmt.Errorf("update: %w", err)
	}
	ev := &ItemHistoryEvent{
		ATMID:        p.ATMID,
		EventType:    eventType,
		By:           p.By,
		OnDate:       p.OnDate,
		Reason:       p.Reason,
		EvidencePath: p.Evidence,
	}
	// §11.4.226 — a rewrite with no recorded evidence is indistinguishable from
	// a row that was always that way. The block identity moved files here; say
	// so on the closure event, alongside any operator-supplied reason.
	if fromLocation != LocationFixed {
		ev.Reason = appendIdentityMigrationNote(ev.Reason, it, fromLocation)
	}
	if err := db.InsertItemHistory(ev); err != nil {
		return nil, fmt.Errorf("insert history: %w", err)
	}

	// §11.4.90 — for Obsolete, write the details row with triple-check evidence.
	if statusValue == StatusObsolete {
		if p.ObsoleteSupersedingItem == "" {
			return nil, fmt.Errorf("--status=obsolete requires --superseding-item")
		}
		if p.ObsoleteTripleCheckPath == "" {
			return nil, fmt.Errorf("--status=obsolete requires --triple-check-evidence")
		}
		reasonValue := p.Reason
		if reasonValue == "" {
			reasonValue = "superseded-by-design-change"
		}
		if !isObsoleteReason(reasonValue) {
			return nil, fmt.Errorf("--reason %q not in §11.4.90 closed-set", reasonValue)
		}
		_, err := db.conn.Exec(`
			INSERT OR REPLACE INTO obsolete_details(atm_id, since, reason, superseding_item, triple_check_evidence)
			VALUES(?, ?, ?, ?, ?)`,
			p.ATMID, p.OnDate, reasonValue, p.ObsoleteSupersedingItem, p.ObsoleteTripleCheckPath)
		if err != nil {
			return nil, fmt.Errorf("insert obsolete_details: %w", err)
		}
	}
	return it, nil
}

// checkDestinationBlockIdentityFree refuses a closure that would move the item's
// block identity onto a (Fixed, category, code_ordinal) triple ALREADY held by a
// DIFFERENT item.
//
// FALSE-POSITIVE GUARDS (§11.4.201(1) — a wrong refusal is as bad as a missed
// defect). Each mirrors a guard ValidateBlockIdentity already applies, so the
// two components agree on what "claims a block" means:
//
//   - code_ordinal <= 0 is the "unknown ordinal" sentinel, not a block claim
//     (every `workable-items add` row carries it), so it can never collide.
//   - an Obsolete closure legitimately SHARES the block of the item that
//     superseded it (§11.4.90). Measured live: (Fixed, B, 3) is held by both
//     TMX-001 (Obsolete) and TMX-054, and validate_identity.go skips exactly
//     this case for exactly this reason. Refusing it would break a correct
//     supersession.
//   - the item itself is excluded, so re-closing an already-closed item (an
//     idempotent double-close) is never refused by its own row.
//
// Only a DIFFERENT, non-Obsolete-destination holder is a genuine collision.
func checkDestinationBlockIdentityFree(db *DB, it *Item, statusValue string) error {
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
		LocationFixed, it.Category, it.CodeOrdinal, it.ATMID)
	if err != nil {
		return fmt.Errorf("check destination block identity: %w", err)
	}
	defer rows.Close()
	var holders []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return fmt.Errorf("check destination block identity: %w", err)
		}
		holders = append(holders, id)
	}
	if err := rows.Err(); err != nil {
		return fmt.Errorf("check destination block identity: %w", err)
	}
	if len(holders) == 0 {
		return nil
	}
	code := fmt.Sprintf("%s%d", it.Category, it.CodeOrdinal)
	return fmt.Errorf(
		"§11.4.54: closing %s would move its block identity to %s in Fixed.md, "+
			"but that block is already held by %s — two items would claim one block. "+
			"Renumber %s's block to a free %s-category code in Issues.md, re-run "+
			"`workable-items sync md-to-db`, then close again",
		it.ATMID, code, strings.Join(holders, ", "), it.ATMID, it.Category)
}

// appendIdentityMigrationNote records the block-identity file transition on the
// closure history event, preserving any operator-supplied reason verbatim.
func appendIdentityMigrationNote(reason string, it *Item, from string) string {
	note := fmt.Sprintf("block identity %s%d migrated %s -> %s",
		it.Category, it.CodeOrdinal, from, LocationFixed)
	if reason == "" {
		return note
	}
	return reason + "; " + note
}

func closeStatusMapping(rawStatus string) (statusValue, eventType string, err error) {
	switch strings.ToLower(rawStatus) {
	case "fixed":
		return StatusFixed, "Fixed", nil
	case "implemented":
		return StatusImplemented, "Implemented", nil
	case "completed":
		return StatusCompleted, "Completed", nil
	case "obsolete":
		return StatusObsolete, "Obsolete", nil
	}
	return "", "", fmt.Errorf("invalid --status %q (want fixed|implemented|completed|obsolete)", rawStatus)
}

func isObsoleteReason(r string) bool {
	switch r {
	case "superseded-by-design-change", "superseded-by-later-mandate",
		"feature-removed", "duplicate-of", "unsupported-topology":
		return true
	}
	return false
}
