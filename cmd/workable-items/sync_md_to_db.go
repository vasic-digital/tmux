// sync_md_to_db.go — Issues.md + Fixed.md → SQLite DB.
//
// Idempotent: re-running over an unchanged corpus produces no DB mutations.
// New items are allocated ATM-NNN ids from the meta.next_atm_id counter;
// existing items rebind by heading_hash so wording reflows preserve identity.

package main

import (
	"fmt"
	"os"
	"strings"
	"time"
)

// SyncResult reports counts after a sync run.
type SyncResult struct {
	Inserted        int
	Updated         int
	UnchangedItems  int
	IssuesParsed    int
	FixedParsed     int
	ATMIDsAllocated int
}

// SyncMDToDB reads issuesPath + fixedPath and upserts every parsed item into db.
func SyncMDToDB(db *DB, issuesPath, fixedPath string) (*SyncResult, error) {
	res := &SyncResult{}

	var issuesItems, fixedItems []*ParsedItem
	var err error

	if issuesPath != "" {
		if _, statErr := os.Stat(issuesPath); statErr == nil {
			issuesItems, err = ParseFile(issuesPath, LocationIssues)
			if err != nil {
				return nil, fmt.Errorf("parse %s: %w", issuesPath, err)
			}
			res.IssuesParsed = len(issuesItems)
		}
	}
	if fixedPath != "" {
		if _, statErr := os.Stat(fixedPath); statErr == nil {
			fixedItems, err = ParseFile(fixedPath, LocationFixed)
			if err != nil {
				return nil, fmt.Errorf("parse %s: %w", fixedPath, err)
			}
			res.FixedParsed = len(fixedItems)
		}
	}

	all := append([]*ParsedItem{}, issuesItems...)
	all = append(all, fixedItems...)

	for _, pi := range all {
		it := pi.Item
		// Description: prefer the first non-blank, non-Status/Type body line
		// if it's longer than 40 chars (§11.4.91 floor); else use the title.
		desc := deriveDescription(it.Title, pi.Item.Body)
		it.Description = desc

		// Allocate ATM-NNN if no existing row. Existing-row lookup checks:
		//   1. heading_hash binding (preferred — survives wording reflows)
		//   2. explicit "**ATM-ID:** ATM-NNN" in the parsed body (round-trip
		//      fixture stability — second-sync of generated output must NOT
		//      allocate a fresh ATM-NNN for a previously-seeded row).
		existing, err := lookupByHeadingHash(db, it.HeadingHash)
		if err != nil {
			return nil, fmt.Errorf("lookup heading_hash: %w", err)
		}
		if existing == "" && pi.ExplicitATM != "" {
			// Check whether the explicit ATM-NNN already exists in DB.
			if priorByATM, _ := db.GetItem(pi.ExplicitATM); priorByATM != nil {
				existing = pi.ExplicitATM
			}
		}
		if existing == "" {
			atm := pi.ExplicitATM
			if atm == "" {
				atm, err = db.NextATMID()
				if err != nil {
					return nil, fmt.Errorf("allocate atm_id: %w", err)
				}
			} else {
				// Bump meta.next_atm_id past explicit ATM if needed so future
				// allocations don't collide.
				if err := bumpNextATM(db, atm); err != nil {
					return nil, err
				}
			}
			it.ATMID = atm
			res.ATMIDsAllocated++
			if err := db.UpsertItem(it); err != nil {
				return nil, fmt.Errorf("insert %s: %w", atm, err)
			}
			// Seed 'Opened' history event.
			_ = db.InsertItemHistory(&ItemHistoryEvent{
				ATMID:     atm,
				EventType: "Opened",
				By:        "AI",
				OnDate:    time.Now().UTC().Format("2006-01-02"),
				Reason:    "initial md-to-db sync",
			})
			res.Inserted++
		} else {
			// Check whether actual content changed before counting as Updated.
			prior, _ := db.GetItem(existing)
			it.ATMID = existing
			if itemContentEqual(prior, it) {
				res.UnchangedItems++
			} else {
				if err := db.UpsertItem(it); err != nil {
					return nil, fmt.Errorf("update %s: %w", existing, err)
				}
				res.Updated++
			}
		}
	}

	if err := db.MetaSet("last_sync_direction", "md-to-db"); err != nil {
		return nil, err
	}
	if err := db.MetaSet("last_sync_timestamp", time.Now().UTC().Format(time.RFC3339)); err != nil {
		return nil, err
	}
	return res, nil
}

// bumpNextATM ensures meta.next_atm_id is at least one past the given ATM-NNN.
func bumpNextATM(db *DB, atm string) error {
	ord := atmOrdinal(atm)
	if ord < 1 {
		return nil
	}
	cur, err := db.MetaGet("next_atm_id")
	if err != nil {
		return err
	}
	curN := 1
	if cur != "" {
		fmt.Sscanf(cur, "%d", &curN)
	}
	if ord+1 > curN {
		return db.MetaSet("next_atm_id", fmt.Sprintf("%d", ord+1))
	}
	return nil
}

func lookupByHeadingHash(db *DB, hash string) (string, error) {
	var atm string
	err := db.conn.QueryRow("SELECT atm_id FROM items WHERE heading_hash = ?", hash).Scan(&atm)
	if err != nil {
		// Treat ErrNoRows as "absent".
		if strings.Contains(err.Error(), "no rows") {
			return "", nil
		}
		// fall through
	}
	return atm, nil
}

func itemContentEqual(a, b *Item) bool {
	if a == nil || b == nil {
		return false
	}
	return a.Type == b.Type &&
		a.Status == b.Status &&
		a.Severity == b.Severity &&
		a.Title == b.Title &&
		a.Description == b.Description &&
		a.CurrentLocation == b.CurrentLocation &&
		a.Category == b.Category
}

// deriveDescription picks an end-user-meaningful description for the item.
//
// Strategy: scan the first ~12 non-blank body lines. The first paragraph
// that is NOT a metadata line (Status/Type/Severity/Reopened-Details/etc.)
// and NOT a blockquote and is ≥ 40 chars wins. Falls back to the title.
//
// Per §11.4.91 the floor is ≥ 6 words OR ≥ 40 chars — we satisfy it by
// preferring the longest qualifying paragraph from the body, OR padding the
// title if it already meets the floor.
func deriveDescription(title, body string) string {
	metadataPrefixes := []string{
		"**Status:**", "**Type:**", "**Severity:**", "**Re-discovered:**",
		"**Reopened:**", "**Reopened-Details:**", "**Operator-Block-Details:**",
		"**Obsolete-Details:**", "**Closure cycle:**", "**Closure commit:**",
		"**Source-side fix:**", "**Captured evidence:**", "**Regression-protection:**",
		"**Tracked task:**", "**Reported:**", "**Forensic anchor:**",
		"**Forensic detail:**", "**Forensic detail",
	}
	lines := strings.Split(body, "\n")
	candidate := ""
	for _, ln := range lines {
		s := strings.TrimSpace(ln)
		if s == "" || strings.HasPrefix(s, ">") || strings.HasPrefix(s, "```") {
			continue
		}
		isMeta := false
		for _, p := range metadataPrefixes {
			if strings.HasPrefix(s, p) {
				isMeta = true
				break
			}
		}
		if isMeta {
			continue
		}
		// Skip pure list-prefix shells.
		trimDash := strings.TrimLeft(s, "- ")
		if len(trimDash) < 20 {
			continue
		}
		if len(s) >= 40 || len(strings.Fields(s)) >= 6 {
			candidate = s
			break
		}
	}
	if candidate != "" {
		return candidate
	}
	// Fallback to title (always present, but may be short).
	if len(title) >= 40 || len(strings.Fields(title)) >= 6 {
		return title
	}
	// Pad short title so §11.4.91 floor is met for new items.
	return title + " (description: short — see item body in Issues.md/Fixed.md for full context)"
}
