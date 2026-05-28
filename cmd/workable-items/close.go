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
	ObsoleteSupersedingItem  string
	ObsoleteTripleCheckPath  string
}

// CloseItem applies the terminal state transition.
func CloseItem(db *DB, p CloseItemParams) (*Item, error) {
	if p.ATMID == "" {
		return nil, fmt.Errorf("ATM-NNN argument is required")
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
