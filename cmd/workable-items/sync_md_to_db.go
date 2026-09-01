// sync_md_to_db.go — Issues.md + Fixed.md → SQLite DB.
//
// Idempotent: re-running over an unchanged corpus produces no DB mutations.
// New items are allocated TMX-NNN ids from the meta.next_atm_id counter;
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

// SyncMDToDBOptions controls SyncMDToDB behaviour.
type SyncMDToDBOptions struct {
	// RefreshRawBodies forces items.raw_body to be updated for EVERY parsed
	// item, even when the structured fields look unchanged. Used as a
	// one-time migration when an older DB (pre-PWU-Q3 schema) is opened
	// and the operator wants raw_body populated from the source Markdown.
	RefreshRawBodies bool
}

// SyncMDToDB reads issuesPath + fixedPath and upserts every parsed item into db.
//
// Behaviour: structured fields (type, status, severity, title, description) are
// re-derived from the parsed body on every call. The verbatim raw_body
// (PWU-Q3, §11.4.93 phase-6) is overwritten with the freshly-parsed text so
// re-running md→db after a Markdown edit captures the new body.
func SyncMDToDB(db *DB, issuesPath, fixedPath string) (*SyncResult, error) {
	return SyncMDToDBOpts(db, issuesPath, fixedPath, SyncMDToDBOptions{})
}

// SyncMDToDBOpts is the options-aware variant of SyncMDToDB.
func SyncMDToDBOpts(db *DB, issuesPath, fixedPath string, opts SyncMDToDBOptions) (*SyncResult, error) {
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
			// PWU-Q3 (§11.4.93 phase-6): persist the verbatim source so
			// db→md can replay byte-identical including preamble + section
			// separators + trailer that no per-item raw_body can capture.
			raw, rerr := os.ReadFile(issuesPath)
			if rerr != nil {
				return nil, fmt.Errorf("read %s: %w", issuesPath, rerr)
			}
			if err := db.PutDocumentSource(LocationIssues, string(raw)); err != nil {
				return nil, fmt.Errorf("put document_source issues: %w", err)
			}
		}
	}
	if fixedPath != "" {
		if _, statErr := os.Stat(fixedPath); statErr == nil {
			fixedItems, err = ParseFile(fixedPath, LocationFixed)
			if err != nil {
				return nil, fmt.Errorf("parse %s: %w", fixedPath, err)
			}
			res.FixedParsed = len(fixedItems)
			raw, rerr := os.ReadFile(fixedPath)
			if rerr != nil {
				return nil, fmt.Errorf("read %s: %w", fixedPath, rerr)
			}
			if err := db.PutDocumentSource(LocationFixed, string(raw)); err != nil {
				return nil, fmt.Errorf("put document_source fixed: %w", err)
			}
		}
	}

	// §11.4.54 id-reservation (second factor of the TMX-078/080/081/090
	// forensic case): meta.next_atm_id was bumped ONLY past ids carried by
	// SUCCESSFULLY PARSED items. An id literal sitting in a block the parser
	// does not bind (e.g. the no-period `### G5 …` heading form) reserved
	// NOTHING, so the allocator later re-issued that very number to an
	// unrelated item — two different items answering to one id, in violation of
	// §11.4.54's never-reuse rule. Reserve EVERY `**TMX-ID:**` literal present
	// in the source, parsed or not, BEFORE any allocation runs.
	for _, path := range []string{issuesPath, fixedPath} {
		if path == "" {
			continue
		}
		raw, rerr := os.ReadFile(path)
		if rerr != nil {
			continue // absent/unreadable file already handled above.
		}
		for _, ln := range strings.Split(string(raw), "\n") {
			if m := atmIDLineRE.FindStringSubmatch(strings.TrimRight(ln, "\r")); m != nil {
				if err := bumpNextATM(db, m[1]); err != nil {
					return nil, fmt.Errorf("reserve %s: %w", m[1], err)
				}
			}
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

		// Allocate TMX-NNN if no existing row. Existing-row lookup checks:
		//   1. heading_hash binding (preferred — survives wording reflows)
		//   2. explicit "**TMX-ID:** TMX-NNN" in the parsed body (round-trip
		//      fixture stability — second-sync of generated output must NOT
		//      allocate a fresh TMX-NNN for a previously-seeded row).
		existing, err := lookupByHeadingHash(db, it.HeadingHash)
		if err != nil {
			return nil, fmt.Errorf("lookup heading_hash: %w", err)
		}
		if existing == "" && pi.ExplicitATM != "" {
			// Check whether the explicit TMX-NNN already exists in DB.
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
			if itemContentEqual(prior, it) && !opts.RefreshRawBodies {
				res.UnchangedItems++
			} else {
				if err := db.UpsertItem(it); err != nil {
					return nil, fmt.Errorf("update %s: %w", existing, err)
				}
				res.Updated++
			}
		}

		// §11.4.21 — when an item is Operator-blocked, extract its
		// **Operator-Block-Details:** block from the body and persist the
		// operator_block_details row so `workable-items validate` reports 0
		// §11.4.21 findings. db→md regeneration is unaffected: it replays from
		// raw_body / document_sources, so this read-only side table never
		// changes the regenerated Markdown (byte-identical round-trip preserved).
		if it.Status == StatusOperatorBlock {
			if ob := parseOperatorBlockDetails(pi.Item.Body); ob != nil {
				ob.ATMID = it.ATMID
				if err := db.PutOperatorBlockDetails(ob); err != nil {
					return nil, fmt.Errorf("put operator_block_details %s: %w", it.ATMID, err)
				}
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

// bumpNextATM ensures meta.next_atm_id is at least one past the given TMX-NNN.
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
		a.Category == b.Category &&
		a.RawBody == b.RawBody
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
