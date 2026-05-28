// add.go — allocate a new ATM-NNN, insert a new item, write 'Opened' history.

package main

import (
	"fmt"
	"strings"
	"time"
)

// AddItemParams holds the CLI-provided parameters for `workable-items add`.
type AddItemParams struct {
	Type        string
	Severity    string
	Title       string
	Description string
	Category    string
}

// AddItem creates a new item + 'Opened' history event.
func AddItem(db *DB, p AddItemParams) (*Item, error) {
	if !isClosedSetType(p.Type) {
		return nil, fmt.Errorf("invalid --type %q (want Bug|Feature|Task)", p.Type)
	}
	if strings.TrimSpace(p.Title) == "" {
		return nil, fmt.Errorf("--title is required")
	}
	if strings.TrimSpace(p.Description) == "" {
		return nil, fmt.Errorf("--description is required")
	}
	if !descriptionMeetsFloor(p.Description) {
		return nil, fmt.Errorf("--description fails §11.4.91 clarity floor (need ≥40 chars OR ≥6 words)")
	}
	if p.Category == "" {
		p.Category = "Z"
	}

	atm, err := db.NextATMID()
	if err != nil {
		return nil, err
	}

	it := &Item{
		ATMID:           atm,
		Type:            p.Type,
		Status:          StatusQueued,
		Severity:        p.Severity,
		Title:           strings.TrimSpace(p.Title),
		Description:     strings.TrimSpace(p.Description),
		CurrentLocation: LocationIssues,
		Category:        strings.ToUpper(p.Category),
		HeadingHash:     computeHeadingHash(p.Category, atm, p.Title),
	}
	if err := db.UpsertItem(it); err != nil {
		return nil, fmt.Errorf("insert: %w", err)
	}
	ev := &ItemHistoryEvent{
		ATMID:     atm,
		EventType: "Opened",
		By:        "User",
		OnDate:    time.Now().UTC().Format("2006-01-02"),
		Reason:    "workable-items add",
	}
	if err := db.InsertItemHistory(ev); err != nil {
		return nil, fmt.Errorf("insert history: %w", err)
	}
	return it, nil
}
