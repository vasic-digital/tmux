// set_status_identity_test.go — §11.4.115 RED-baseline-on-the-broken-artifact
// guard for the REOPEN-time block-identity collision (TMX-099).
//
// DEFECT (measured on the live corpus 2026-11-20): `SetStatus` mutates exactly
// two fields — `Status` and `CurrentLocation` (set to LocationIssues) — and
// carries the item's `(category, code_ordinal)` across the migration unchanged,
// WITHOUT checking that the destination triple `(Issues, category, code_ordinal)`
// is free. Block codes are CATEGORY-LOCAL and are NOT unique across the two
// trackers: the DB carries e.g. TMX-035 at (Fixed, A, 3) while TMX-076 holds
// (Issues, A, 3). Reopening TMX-076 (or any Fixed item whose category-local code
// is held on the Issues side) re-points its identity onto an occupied block,
// producing the two-items-one-block state ValidateBlockIdentity exists to report.
//
// Polarity switch per §11.4.115 (redMode() is defined once in
// reconcile_identity_test.go and reused here): RED_MODE=1 asserts the DEFECT IS
// PRESENT on the pre-fix artifact; the default RED_MODE=0 is the standing GREEN
// guard asserting the defect is ABSENT.
//
// All DBs are PRIVATE (t.TempDir()); the git-tracked docs/workable_items.db is
// never opened by this file.

package main

import (
	"strings"
	"testing"
)

// TestSetStatusReopenDoesNotStrandIdentityOnAnOccupiedIssuesBlock is the
// polarity test. TMX-911 already holds (Issues, B, 3); TMX-912 is closed at
// (Fixed, B, 3). Reopening TMX-912 moves its identity onto the occupied triple.
func TestSetStatusReopenDoesNotStrandIdentityOnAnOccupiedIssuesBlock(t *testing.T) {
	db, _ := openCloseTestDB(t) // private DB helper (close_identity_test.go)

	seedItem(t, db, "TMX-911", TypeBug, StatusReadyForTest, LocationIssues, "B", 3,
		"The open item that already owns Issues.md block B3")
	victim := seedItem(t, db, "TMX-912", TypeBug, StatusFixed, LocationFixed, "B", 3,
		"The closed item whose Issues-side code B3 is already occupied")

	_, err := SetStatus(db, SetStatusParams{
		ATMID: victim.ATMID, Status: "reopened", By: "User",
		Reason: "operator re-test failed",
	})
	holders := identityHoldersForTest(t, db, LocationIssues, "B", 3)

	if redMode() {
		// RED baseline: the defect IS present on the broken artifact.
		if err != nil {
			t.Fatalf("RED_MODE=1: expected the reopen to succeed (defect present), got error: %v", err)
		}
		if len(holders) < 2 {
			t.Fatalf("RED_MODE=1: expected two items claiming (Issues,B,3), got %v", holders)
		}
		t.Logf("RED_MODE=1: defect reproduced — (Issues,B,3) is now claimed by %v", holders)
		return
	}

	// GREEN guard: the reopen MUST be refused and the row left untouched.
	if err == nil {
		t.Fatalf("reopen onto an occupied Issues block was accepted; (Issues,B,3) is now claimed by %v", holders)
	}
	if !strings.Contains(err.Error(), "TMX-911") {
		t.Errorf("refusal must name the holder of the destination block; got: %v", err)
	}
	if len(holders) != 1 || holders[0] != "TMX-911" {
		t.Errorf("(Issues,B,3) holders after the refusal = %v, want [TMX-911] only", holders)
	}
	// §11.4.252 — a fail-closed refusal must be side-effect free.
	got, _ := db.GetItem("TMX-912")
	if got.Status != StatusFixed || got.CurrentLocation != LocationFixed {
		t.Errorf("refused reopen still mutated the row: status=%q location=%q", got.Status, got.CurrentLocation)
	}
	if n := historyCountForTest(t, db, "TMX-912"); n != 0 {
		t.Errorf("refused reopen wrote %d history event(s); want 0", n)
	}
}

// ---------------------------------------------------------------------------
// §11.4.146 STEP 3 — extend to all cases. The guard must refuse ONLY the
// genuine collision; every other reopen path must be untouched.
// ---------------------------------------------------------------------------

// TestSetStatusReopenOntoAFreeIssuesBlockStillMigrates is the §11.4.201(1)
// false-positive guard — the golden-FALSE fixture. A refusal that fires here
// would be as damaging as the missed defect above.
func TestSetStatusReopenOntoAFreeIssuesBlockStillMigrates(t *testing.T) {
	db, _ := openCloseTestDB(t)

	// An unrelated open item under a DIFFERENT code, so (Issues, H, 2) is free.
	seedItem(t, db, "TMX-911", TypeBug, StatusReadyForTest, LocationIssues, "H", 1,
		"An unrelated open item occupying Issues.md block H1")
	seedItem(t, db, "TMX-912", TypeBug, StatusFixed, LocationFixed, "H", 2,
		"The closed item whose Issues.md destination block H2 is free")

	if _, err := SetStatus(db, SetStatusParams{ATMID: "TMX-912", Status: "reopened"}); err != nil {
		t.Fatalf("reopen onto a FREE Issues block was refused: %v", err)
	}
	got, _ := db.GetItem("TMX-912")
	if got.Status != StatusReopened {
		t.Errorf("status = %q, want %q", got.Status, StatusReopened)
	}
	if got.CurrentLocation != LocationIssues {
		t.Errorf("location = %q, want %q", got.CurrentLocation, LocationIssues)
	}
	// The identity code MUST be carried across verbatim: reconcile.go's
	// blockHeadingIdentifies matches the stored ordinal against the block's own
	// `### H2` heading; a cleared or renumbered ordinal breaks that binding.
	if got.Category != "H" || got.CodeOrdinal != 2 {
		t.Errorf("block identity was altered: %s%d, want H2", got.Category, got.CodeOrdinal)
	}
}

// TestSetStatusReopenWithSentinelOrdinalIsNeverRefused covers every
// `workable-items add` row: CodeOrdinal 0 asserts NO block claim, so it can
// never collide — even when another Issues item shares its category.
func TestSetStatusReopenWithSentinelOrdinalIsNeverRefused(t *testing.T) {
	db, _ := openCloseTestDB(t)

	seedItem(t, db, "TMX-911", TypeBug, StatusReadyForTest, LocationIssues, "Z", 0,
		"An open add-created item carrying the sentinel ordinal in category Z")
	seedItem(t, db, "TMX-912", TypeBug, StatusFixed, LocationFixed, "Z", 0,
		"A closed add-created item carrying the sentinel ordinal in category Z")

	if _, err := SetStatus(db, SetStatusParams{ATMID: "TMX-912", Status: "reopened"}); err != nil {
		t.Fatalf("reopen of a sentinel-ordinal item was refused: %v", err)
	}
}

// TestSetStatusReopenIsIdempotentUnderDoubleReopen — an item's OWN row must
// never be read as the holder of its own destination identity.
func TestSetStatusReopenIsIdempotentUnderDoubleReopen(t *testing.T) {
	db, _ := openCloseTestDB(t)

	seedItem(t, db, "TMX-912", TypeBug, StatusFixed, LocationFixed, "K", 9,
		"An item reopened twice in a row to prove the guard excludes its own row")

	for i := 1; i <= 2; i++ {
		if _, err := SetStatus(db, SetStatusParams{ATMID: "TMX-912", Status: "reopened"}); err != nil {
			t.Fatalf("reopen attempt %d refused: %v", i, err)
		}
	}
	if h := identityHoldersForTest(t, db, LocationIssues, "K", 9); len(h) != 1 {
		t.Errorf("(Issues,K,9) holders after a double reopen = %v, want exactly one", h)
	}
}

// TestSetStatusReopenRecordsIdentityMigrationAsEvidence — §11.4.226: a pointer
// that changed files with no recorded evidence is indistinguishable from one
// that was always that way. Parallels close.go's appendIdentityMigrationNote.
func TestSetStatusReopenRecordsIdentityMigrationAsEvidence(t *testing.T) {
	db, _ := openCloseTestDB(t)

	seedItem(t, db, "TMX-912", TypeBug, StatusFixed, LocationFixed, "N", 4,
		"An item whose reopen must leave an auditable identity-migration record")

	if _, err := SetStatus(db, SetStatusParams{
		ATMID: "TMX-912", Status: "reopened", Reason: "operator note",
	}); err != nil {
		t.Fatal(err)
	}
	var reason string
	if err := db.conn.QueryRow(
		`SELECT reason FROM item_history WHERE atm_id=? ORDER BY id DESC LIMIT 1`,
		"TMX-912").Scan(&reason); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(reason, "operator note") {
		t.Errorf("operator-supplied reason was clobbered: %q", reason)
	}
	if !strings.Contains(reason, "N4") || !strings.Contains(reason, LocationFixed) {
		t.Errorf("identity migration not recorded in history: %q", reason)
	}
}
