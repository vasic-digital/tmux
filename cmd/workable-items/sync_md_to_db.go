// sync_md_to_db.go — Issues.md + Fixed.md → SQLite DB.
//
// Idempotent: re-running over an unchanged corpus produces no DB mutations.
// New items are allocated TMX-NNN ids from the meta.next_atm_id counter;
// existing items rebind by heading_hash so wording reflows preserve identity.

package main

import (
	"database/sql"
	"errors"
	"fmt"
	"os"
	"strconv"
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

	// IdentityRebinds counts writes that REPLACED an existing row reached by
	// its declared **TMX-ID:** rather than by heading identity. Surfaced so a
	// rebind is visible at the moment it happens, not only in item_history.
	IdentityRebinds int
	RebindDetails   []string
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

	// Held until the duplicate guard has passed (§11.4.252 fail-closed means
	// the refusal must also be side-effect-free — see the persist step below).
	var issuesRaw, fixedRaw string
	var haveIssuesRaw, haveFixedRaw bool

	if issuesPath != "" {
		if _, statErr := os.Stat(issuesPath); statErr == nil {
			issuesItems, err = ParseFile(issuesPath, LocationIssues)
			if err != nil {
				return nil, fmt.Errorf("parse %s: %w", issuesPath, err)
			}
			res.IssuesParsed = len(issuesItems)
			// PWU-Q3 (§11.4.93 phase-6): the verbatim source is what lets
			// db→md replay byte-identical (preamble + section separators +
			// trailer that no per-item raw_body can capture). It is READ here
			// but PERSISTED below, AFTER the duplicate guard — see the
			// persist-after-guard note there.
			raw, rerr := os.ReadFile(issuesPath)
			if rerr != nil {
				return nil, fmt.Errorf("read %s: %w", issuesPath, rerr)
			}
			issuesRaw, haveIssuesRaw = string(raw), true
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
			fixedRaw, haveFixedRaw = string(raw), true
		}
	}

	// §11.4.19 ONE-ITEM-ONE-TRACKER guard (§11.4.252 fail-closed).
	//
	// An item lives in exactly ONE tracker: closing it MOVES its block from
	// Issues.md to Fixed.md. A block present in BOTH files is a stale leftover
	// of a migration that copied but never removed.
	//
	// This MUST refuse rather than pick a winner. computeHeadingHash hashes
	// (category, code, title) and deliberately excludes the file, so both copies
	// yield the SAME heading_hash — which is NOT NULL UNIQUE. The second copy
	// processed therefore binds to the SAME row and UPDATEs it, silently
	// collapsing two distinct blocks into one whose current_location is merely
	// whichever file was read last. The corpus said two things and the SSoT
	// recorded one, with no verdict saying so — the §11.4 data-loss class.
	//
	// Measured live 2026-09-01: TMX-072..075 (blocks G1..G4) sat in both
	// trackers. They were invisible until headingRE accepted the space heading
	// form, because neither copy had ever parsed.
	// The check keys on the UNION of every parsed block from BOTH files, so a
	// duplicate is caught wherever it sits: Issues-vs-Fixed, Fixed-vs-Fixed, or
	// Issues-vs-Issues. A same-file pair is NOT the lesser case — UpsertItem now
	// resolves an explicit TMX-ID to its existing row, so a second block
	// declaring another item's id would UPDATE that row (silently overwriting
	// its title/status/body) where it previously died on the UNIQUE constraint.
	// Two keys, because a duplicate can arrive under either identity:
	//   ExplicitATM  — two blocks declare the same **TMX-ID:** (any block codes)
	//   HeadingHash  — two blocks compute the same identity (same cat+code+title)
	{
		type seen struct{ file, code string }
		byATM := map[string]seen{}
		byHash := map[string]seen{}
		var dup []string
		for _, group := range []struct {
			file  string
			items []*ParsedItem
		}{{"Issues.md", issuesItems}, {"Fixed.md", fixedItems}} {
			for _, pi := range group.items {
				here := seen{group.file, pi.Item.Category + strconv.Itoa(pi.Item.CodeOrdinal)}
				if pi.ExplicitATM != "" {
					if prev, both := byATM[pi.ExplicitATM]; both {
						dup = append(dup, fmt.Sprintf("%s (block %s in %s and block %s in %s)",
							pi.ExplicitATM, prev.code, prev.file, here.code, here.file))
					} else {
						byATM[pi.ExplicitATM] = here
					}
				}
				if pi.Item.HeadingHash != "" {
					if prev, both := byHash[pi.Item.HeadingHash]; both {
						dup = append(dup, fmt.Sprintf("identical heading identity (block %s in %s and block %s in %s)",
							prev.code, prev.file, here.code, here.file))
					} else {
						byHash[pi.Item.HeadingHash] = here
					}
				}
			}
		}
		if len(dup) > 0 {
			return nil, fmt.Errorf(
				"§11.4.19 one-item-one-block violated: %d duplicate identit(ies) across the parsed corpus, "+
					"which would silently collapse into a single row whose surviving content depends on read order — "+
					"remove the stale duplicate before syncing: %s",
				len(dup), strings.Join(dup, "; "))
		}
	}

	// PERSIST-AFTER-GUARD (§11.4.252). document_sources is the blob db→md
	// replays from, so writing it before the guard made a REFUSED sync mutate
	// the git-tracked SSoT: the refused corpus landed in document_sources while
	// the structured rows stayed at their prior state, leaving the DB
	// internally inconsistent by the very refusal that cites fail-closed. A
	// refusal must change nothing.
	if haveIssuesRaw {
		if err := db.PutDocumentSource(LocationIssues, issuesRaw); err != nil {
			return nil, fmt.Errorf("put document_source issues: %w", err)
		}
	}
	if haveFixedRaw {
		if err := db.PutDocumentSource(LocationFixed, fixedRaw); err != nil {
			return nil, fmt.Errorf("put document_source fixed: %w", err)
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
		// IDENTITY REBIND (hash MISS + declared id HIT). The block's heading
		// identity is not in the DB, but the id it declares IS — so this write
		// REPLACES whatever row already holds that id, including its category,
		// ordinal, title and body.
		//
		// Two situations produce exactly this signal and CANNOT be told apart
		// from the corpus alone (§11.4.6 — the distinguishing fact is not
		// present in the data):
		//   (a) legitimate — the same item's heading changed (a renumber such
		//       as A50→A55, or a wording reflow), so rebinding is correct;
		//   (b) a foreign block declaring another item's id (a typo, or a
		//       hand-written id the allocator had already issued elsewhere)
		//       while that item's own block is absent from the corpus.
		//
		// Refusing would break (a) — a rename would need an operator override
		// every time — so the rebind is ALLOWED but never SILENT: the prior
		// identity is captured here and written to item_history after the
		// upsert, and the count is surfaced in the sync result. Before this,
		// a full identity+content rewrite left ZERO machine evidence and
		// `validate` reported 0 findings, because the overwritten row was
		// internally self-consistent (§11.4.226 — a rewrite with no recorded
		// evidence is indistinguishable from a row that was always that way).
		rebindFrom := ""
		if existing == "" && pi.ExplicitATM != "" {
			if priorByATM, _ := db.GetItem(pi.ExplicitATM); priorByATM != nil {
				existing = pi.ExplicitATM
				rebindFrom = fmt.Sprintf("%s%d %q in %s",
					priorByATM.Category, priorByATM.CodeOrdinal,
					priorByATM.Title, priorByATM.CurrentLocation)
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
				if rebindFrom != "" {
					// The audit trail that makes the rewrite findable later.
					if herr := db.InsertItemHistory(&ItemHistoryEvent{
						ATMID:     existing,
						EventType: "Updated",
						By:        "AI",
						OnDate:    time.Now().UTC().Format("2006-01-02"),
						Reason: fmt.Sprintf(
							"identity rebind: row previously held %s; rebound to block %s%d %q in %s "+
								"because that block declares **TMX-ID:** %s and its heading identity was not in the DB",
							rebindFrom, it.Category, it.CodeOrdinal, it.Title, it.CurrentLocation, existing),
					}); herr != nil {
						return nil, fmt.Errorf("record identity rebind for %s: %w", existing, herr)
					}
					res.IdentityRebinds++
					res.RebindDetails = append(res.RebindDetails,
						fmt.Sprintf("%s (was %s -> now %s%d %q in %s)",
							existing, rebindFrom, it.Category, it.CodeOrdinal, it.Title, it.CurrentLocation))
				}
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
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil // genuinely absent
	}
	if err != nil {
		// A real DB error is NOT "absent". Returning ("", nil) here read a
		// failed query as a hash miss, which sends the caller down the
		// allocate-a-new-id path and mints a duplicate row for an item that
		// already exists (§11.4.201(6): the false-null — a broken instrument
		// and a clean result returning the same quiet zero).
		return "", fmt.Errorf("lookup heading_hash %s: %w", hash, err)
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
		// CodeOrdinal and HeadingHash are IDENTITY, and identity is content.
		//
		// Category was compared while the ordinal beside it was not, so an
		// ordinal-only renumber (`### A50.` -> `### A55.`, body byte-identical —
		// the ordinary shape once blocks carry their own **TMX-ID:** line)
		// compared "equal" and took the unchanged path: the upsert was skipped,
		// the row kept the OLD ordinal and the now-stale hash, and the rebind
		// that had already been resolved was discarded without a history row.
		// The desync was PERMANENT — every later sync missed the hash, resolved
		// by id, compared "equal", and reported unchanged again, so the repair
		// could never land (§11.4.108 source-vs-SSoT), while the §11.4.226 audit
		// trail was defeated on precisely this path.
		//
		// Comparing the hash as well makes the row self-heal: a row whose stored
		// hash has drifted from the one its own heading computes is not equal to
		// that heading, whatever else matches.
		a.CodeOrdinal == b.CodeOrdinal &&
		a.HeadingHash == b.HeadingHash &&
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
