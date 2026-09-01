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
	// §11.4.120 RECONCILED 2026-09-01: headingRE now accepts the SPACE heading
	// form too, so the follower `### B2 …` parses as its OWN item — 2 items, not
	// 1. That count was never the invariant; it was an artifact of the narrow
	// regex. THE invariant is the two absorption assertions below: the period
	// item must not swallow the follower's **TMX-ID:** or **Type:**. Those are
	// unchanged and remain the load-bearing checks.
	if len(items) != 2 {
		t.Fatalf("expected the period item AND the now-parseable follower (2), got %d", len(items))
	}
	// The follower must own the metadata written inside its own block — the
	// positive half of the same invariant, which the old count-based assertion
	// could not express at all.
	if got := items[1].ExplicitATM; got != "TMX-005" {
		t.Errorf("the follower block must own its own **TMX-ID:**, got %q want %q", got, "TMX-005")
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

	// §11.4.120 RECONCILED 2026-09-01 when headingRE was widened to accept the
	// space heading form.
	//
	// The invariant is unchanged: the PERIOD item must not take an id that
	// belongs to a different block. What changed is the correct OBSERVABLE.
	//
	// Previously the follower `### B2 …` could never parse, so nothing could
	// legitimately rewrite the victim row, and "victim title unchanged" was a
	// sound PROXY for "the period item did not steal the id". With the widened
	// parser the follower is a real item that literally declares
	// `**TMX-ID:** <victim>` inside its own block, so binding to that row and
	// refreshing its fields is the CORRECT repair (it is exactly how the live
	// TMX-072..075 sentinel rows regain their identity) — the old proxy now
	// reports that correct behaviour as theft.
	//
	// So assert the invariant DIRECTLY instead of through the stale proxy:
	// the period item must hold a FRESH id, and the victim id must be held by
	// the block that declares it. This is strictly stronger than the proxy —
	// it names the thief rather than inferring one from a side effect.
	items, err := db.AllItems()
	if err != nil {
		t.Fatalf("read back items: %v", err)
	}
	var periodItem, victimRow *Item
	for _, it := range items {
		switch {
		case it.Category == "A" && it.CodeOrdinal == 1:
			periodItem = it
		case it.ATMID == victim.ATMID:
			victimRow = it
		}
	}
	if periodItem == nil {
		t.Fatalf("the period item (A1) was not persisted; rows=%d", len(items))
	}
	// THE invariant: the greedy period heading did not take the victim's id.
	if periodItem.ATMID == victim.ATMID {
		t.Errorf("greedy bind: the period item A1 STOLE %s (title=%q)",
			victim.ATMID, periodItem.Title)
	}
	if victimRow == nil {
		t.Fatalf("victim %s vanished after sync", victim.ATMID)
	}
	// And the id is held by the block that actually declares it — the follower.
	if victimRow.Category != "B" || victimRow.CodeOrdinal != 2 {
		t.Errorf("%s should be held by the follower block B2 that declares it, got %s%d (title=%q)",
			victim.ATMID, victimRow.Category, victimRow.CodeOrdinal, victimRow.Title)
	}
}

// TestParse_NonItemHeadingStillClosesMetadataWindow keeps the TMX-065
// greedy-bind guard under a LIVE §1.1 mutation pair.
//
// WHY THIS TEST EXISTS (measured 2026-09-01). When headingRE was widened to
// accept the space heading form, the two tests above stopped exercising the
// guard: a follower like `### B2 …` now matches headingRE itself, so the
// heading-match branch ends the preceding block before the metadata window is
// ever consulted. Mutating the guard away (`anyHeadingRE` → `false`) left both
// of them GREEN — i.e. the widening silently orphaned the guard's mutation
// pair, and the guard was one refactor away from being deleted as dead code
// (§11.4.124).
//
// The guard is still load-bearing for every heading that is NOT an item: a
// `####` sub-heading, and CAT+N-less `### ` headings which the live corpus
// really does contain (Issues.md `### M24-ESCAPE-001 …`, Fixed.md
// `### TMX-051 …`, `### NEZHA-INSTALL-v1.0.26-001 …`). This test drives that
// class, so the guard keeps a mutation that genuinely FAILs without it.
func TestParse_NonItemHeadingStillClosesMetadataWindow(t *testing.T) {
	tmp := t.TempDir()
	path := filepath.Join(tmp, "Issues.md")
	doc := "# Issues\n\n## A\n\n" +
		"### A1. Period heading with no TMX-ID of its own\n\n" +
		"This period item has a sufficiently long description paragraph here.\n\n" +
		// NOT a workable item: no <CAT><N> code, so headingRE does not match and
		// the heading-match branch never fires. Only the guard can close the
		// window before these structured lines are read.
		"### M24-ESCAPE-001 — a non-item heading that carries metadata\n\n" +
		"**TMX-ID:** TMX-005\n" +
		"**Type:** Bug\n\n" +
		"Body text for the non-item block, long enough to read as a paragraph.\n"
	if err := os.WriteFile(path, []byte(doc), 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	items, err := ParseFile(path, LocationIssues)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(items) != 1 {
		t.Fatalf("the non-item heading must NOT become an item: got %d items", len(items))
	}
	if got := items[0].ExplicitATM; got != "" {
		t.Errorf("period item absorbed a non-item block's **TMX-ID:**: got %q, want \"\" "+
			"(the greedy-bind guard did not close the metadata window)", got)
	}
	if got := items[0].Item.Type; got != TypeTask {
		t.Errorf("period item absorbed a non-item block's **Type:**: got %q, want %q", got, TypeTask)
	}
}
