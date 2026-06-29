// parser_greedybind_test.go — §11.4.115 RED-baseline + GREEN regression guard
// for the GREEDY-BIND parser defect (TMX-065).
//
// Forensic anchor (this session, forced a §9.2 DB restore): a period-style
// heading (`### A54. …`, which matches headingRE) absorbs the content of any
// FOLLOWING no-period `### ` block that falls inside its 8/24-line structured-
// metadata window. The absorbed block's `**TMX-ID:** TMX-NNN` (and
// **Status:**/**Type:**/**Severity:**) lines are mis-bound to the period item,
// so on `sync md-to-db` the period item tries to claim a TMX id that belongs to
// a different block → INSERT with a duplicate atm_id → UNIQUE-constraint failure
// (or silent clobber of the real owner).
//
// Root cause (§11.4.102): the metadata-extraction loop kept scanning the first
// 24 lines for **TMX-ID:**/**Status:**/etc. WITHOUT noticing that a new `### `
// block had begun in between. A markdown heading of ANY level unambiguously ends
// the current item's structured-metadata prefix region, so the window MUST close
// at the first subsequent heading line.
//
// RED_MODE semantics (§11.4.115): on the PRE-FIX parser these tests FAIL
// (the period item absorbs the follower's TMX-ID / Type, and the end-to-end sync
// raises a UNIQUE-constraint error). On the FIXED parser they PASS and stand as
// the permanent regression guard.

package main

import (
	"os"
	"path/filepath"
	"testing"
)

// TestParse_PeriodHeadingDoesNotAbsorbFollowingBlock is the parser-level RED:
// a period heading must NOT bind a following no-period block's structured
// metadata (TMX-ID / Type).
func TestParse_PeriodHeadingDoesNotAbsorbFollowingBlock(t *testing.T) {
	tmp := t.TempDir()
	path := filepath.Join(tmp, "Issues.md")
	doc := "# Issues\n\n## A\n\n" +
		// Period-style heading (matches headingRE) with NO TMX-ID of its own.
		"### A1. Period heading with no TMX-ID of its own\n\n" +
		"This period item has a sufficiently long description paragraph here.\n\n" +
		// A NO-PERIOD `### ` block follows within the metadata window. It carries
		// its OWN structured metadata that must NOT bleak into the period item.
		"### B2 NO-PERIOD-FOLLOWER-001 — a no-period follower block — `OPEN`\n\n" +
		"**TMX-ID:** TMX-005\n" +
		"**Status:** `OPEN`\n" +
		"**Type:** Bug\n\n" +
		"Follower body text describing the second block in enough words here.\n"
	if err := os.WriteFile(path, []byte(doc), 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	items, err := ParseFile(path, LocationIssues)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	// The no-period block is not a workable item of its own (does not match
	// headingRE) — only the period heading parses.
	if len(items) != 1 {
		t.Fatalf("expected exactly 1 parsed item, got %d", len(items))
	}
	if got := items[0].ExplicitATM; got != "" {
		t.Errorf("period item absorbed a following block's **TMX-ID:**: ExplicitATM=%q, want \"\"", got)
	}
	if got := items[0].Item.Type; got != TypeTask {
		t.Errorf("period item absorbed a following block's **Type:**: got %q, want %q (default)", got, TypeTask)
	}
}

// TestSyncMDToDB_PeriodHeadingDoesNotStealExistingTMXID is the end-to-end RED:
// the greedy absorption must not cause a UNIQUE-constraint failure nor clobber
// the real owner of the absorbed TMX id.
func TestSyncMDToDB_PeriodHeadingDoesNotStealExistingTMXID(t *testing.T) {
	tmp := t.TempDir()
	dbPath := filepath.Join(tmp, "wi.db")
	db, err := OpenDB(dbPath)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer db.Close()

	// Pre-seed an existing item; it allocates the first TMX id (TMX-001).
	victim, err := AddItem(db, AddItemParams{
		Type:        TypeBug,
		Severity:    "LOW",
		Title:       "Pre-existing victim item that must not be clobbered",
		Description: "A pre-existing item whose TMX id must not be stolen by a greedy period heading.",
		Category:    "Z",
	})
	if err != nil {
		t.Fatalf("seed victim: %v", err)
	}

	path := filepath.Join(tmp, "Issues.md")
	doc := "# Issues\n\n## A\n\n" +
		"### A1. Greedy period heading with no own TMX-ID\n\n" +
		"Period item description paragraph that is plenty long for the clarity floor.\n\n" +
		"### B2 NO-PERIOD-001 — follower block — `OPEN`\n\n" +
		"**TMX-ID:** " + victim.ATMID + "\n" +
		"**Type:** Task\n\n" +
		"Follower body describing the second block in sufficiently many words here.\n"
	if err := os.WriteFile(path, []byte(doc), 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}

	// On the PRE-FIX parser this raises a UNIQUE-constraint error because the
	// period item tries to INSERT a row with the victim's atm_id.
	if _, err := SyncMDToDB(db, path, ""); err != nil {
		t.Fatalf("md-to-db raised an error (greedy-bind UNIQUE collision): %v", err)
	}

	got, err := db.GetItem(victim.ATMID)
	if err != nil {
		t.Fatalf("re-read victim: %v", err)
	}
	if got == nil {
		t.Fatalf("victim %s vanished after sync", victim.ATMID)
	}
	if got.Title != victim.Title {
		t.Errorf("victim %s was clobbered: title=%q, want %q", victim.ATMID, got.Title, victim.Title)
	}
}
