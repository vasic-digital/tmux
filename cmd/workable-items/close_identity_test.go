// close_identity_test.go — §11.4.115 RED-baseline-on-the-broken-artifact guard
// for the close-time block-identity collision.
//
// DEFECT (measured on the live corpus 2026-09-01, HEAD 5191e82):
// `CloseItem` mutates exactly two fields — `Status` and `CurrentLocation` —
// and carries the item's Issues-side `(category, code_ordinal)` across the
// migration unchanged, WITHOUT checking that the resulting destination triple
// `(Fixed, category, code_ordinal)` is free. Block codes are category-local and
// are NOT unique across the two trackers: measured on the live corpus, 9 of the
// 10 distinct block codes in Issues.md already exist in Fixed.md, and querying
// the SSoT the same way shows 8 of the 10 open items would, on close, land on a
// `(Fixed, category, code_ordinal)` triple ALREADY held by a different item
// (TMX-076 A3 -> TMX-035, TMX-077 A4 -> TMX-034, TMX-093 A5 -> TMX-033,
// TMX-094 A6 -> TMX-032, TMX-095 A7 -> TMX-031, TMX-091 A2 -> TMX-036,
// TMX-080 H1 -> TMX-079, TMX-090 I1 -> TMX-082). The DB already carries one
// realised instance: (Fixed, B, 3) is held by BOTH TMX-001 and TMX-054.
//
// The resulting state is exactly the §11.4.54 defect `validate_identity.go`
// exists to report — "stored identity names block A3 in Fixed.md, but that
// block declares TMX-035 — two items claim one block" — and it leaves one of
// the two rows permanently naming a block it does not occupy.
//
// Polarity switch per §11.4.115 (`redMode()` is defined once in
// reconcile_identity_test.go and reused here): RED_MODE=1 asserts the DEFECT IS
// PRESENT on the pre-fix artifact; the default RED_MODE=0 is the standing GREEN
// guard asserting the defect is ABSENT.

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// closeTestEvidence writes a non-empty evidence file and returns its path
// (CloseItem refuses an absent or empty path per §11.4.5 + §11.4.69).
func closeTestEvidence(t *testing.T, dir string) string {
	t.Helper()
	p := filepath.Join(dir, "evidence.log")
	if err := os.WriteFile(p, []byte("captured evidence for the closure\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

// seedItem inserts an item with an EXPLICIT block identity. AddItem cannot be
// used here: it leaves CodeOrdinal at the 0 sentinel, and the ordinal is the
// field under test.
func seedItem(t *testing.T, db *DB, id, typ, status, loc, cat string, ord int, title string) *Item {
	t.Helper()
	it := &Item{
		ATMID:           id,
		Type:            typ,
		Status:          status,
		Title:           title,
		Description:     "A description long enough to clear the §11.4.91 clarity floor for tests.",
		CurrentLocation: loc,
		Category:        cat,
		CodeOrdinal:     ord,
	}
	it.HeadingHash = computeHeadingHash(cat, fmt.Sprintf("%s%d", cat, ord), title)
	if err := db.UpsertItem(it); err != nil {
		t.Fatalf("seed %s: %v", id, err)
	}
	return it
}

func openCloseTestDB(t *testing.T) (*DB, string) {
	t.Helper()
	dir := t.TempDir()
	db, err := OpenDB(filepath.Join(dir, "close.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	return db, dir
}

// TestCloseDoesNotStrandIdentityOnAnOccupiedDestinationBlock is the polarity
// test. TMX-901 already occupies (Fixed, A, 3); TMX-902 sits in Issues under
// the same category-local code A3. Closing TMX-902 moves its identity onto the
// occupied destination triple.
func TestCloseDoesNotStrandIdentityOnAnOccupiedDestinationBlock(t *testing.T) {
	db, dir := openCloseTestDB(t)
	ev := closeTestEvidence(t, dir)

	seedItem(t, db, "TMX-901", TypeTask, StatusCompleted, LocationFixed, "A", 3,
		"The already-closed item that owns Fixed.md block A3")
	victim := seedItem(t, db, "TMX-902", TypeTask, StatusReadyForTest, LocationIssues, "A", 3,
		"The open item whose Issues.md block also carries the code A3")

	_, err := CloseItem(db, CloseItemParams{
		ATMID: victim.ATMID, Status: "completed", Evidence: ev,
	})

	holders := identityHoldersForTest(t, db, LocationFixed, "A", 3)

	if redMode() {
		// RED baseline: the defect IS present on the broken artifact.
		if err != nil {
			t.Fatalf("RED_MODE=1: expected the close to succeed (defect present), got error: %v", err)
		}
		if len(holders) < 2 {
			t.Fatalf("RED_MODE=1: expected two items claiming (Fixed,A,3), got %v", holders)
		}
		t.Logf("RED_MODE=1: defect reproduced — (Fixed,A,3) is now claimed by %v", holders)
		return
	}

	// GREEN guard: the close MUST be refused and the row left untouched.
	if err == nil {
		t.Fatalf("close onto an occupied destination block identity was accepted; "+
			"(Fixed,A,3) is now claimed by %v", holders)
	}
	if !strings.Contains(err.Error(), "TMX-901") {
		t.Errorf("refusal must name the holder of the destination block; got: %v", err)
	}
	if len(holders) != 1 || holders[0] != "TMX-901" {
		t.Errorf("(Fixed,A,3) holders after the refusal = %v, want [TMX-901] only", holders)
	}
	// §11.4.252 — a fail-closed refusal must be side-effect free.
	got, _ := db.GetItem("TMX-902")
	if got.Status != StatusReadyForTest || got.CurrentLocation != LocationIssues {
		t.Errorf("refused close still mutated the row: status=%q location=%q",
			got.Status, got.CurrentLocation)
	}
	if n := historyCountForTest(t, db, "TMX-902"); n != 0 {
		t.Errorf("refused close wrote %d history event(s); want 0", n)
	}
}

// identityHoldersForTest returns every atm_id holding the given identity triple.
func identityHoldersForTest(t *testing.T, db *DB, loc, cat string, ord int) []string {
	t.Helper()
	rows, err := db.conn.Query(
		`SELECT atm_id FROM items WHERE current_location=? AND category=? AND code_ordinal=? ORDER BY atm_id`,
		loc, cat, ord)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			t.Fatal(err)
		}
		out = append(out, id)
	}
	return out
}

func historyCountForTest(t *testing.T, db *DB, id string) int {
	t.Helper()
	var n int
	if err := db.conn.QueryRow(`SELECT COUNT(*) FROM item_history WHERE atm_id=?`, id).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

// ---------------------------------------------------------------------------
// §11.4.146 STEP 3 — extend to all cases. The guard must refuse ONLY the
// genuine collision; every other closure path must be untouched.
// ---------------------------------------------------------------------------

// TestCloseOntoAFreeDestinationBlockStillMigrates is the §11.4.201(1)
// false-positive guard — the golden-FALSE fixture. A refusal that fires here
// would be as damaging as the missed defect above.
func TestCloseOntoAFreeDestinationBlockStillMigrates(t *testing.T) {
	db, dir := openCloseTestDB(t)
	ev := closeTestEvidence(t, dir)

	// A Fixed item under a DIFFERENT code, so H2 is genuinely free.
	seedItem(t, db, "TMX-901", TypeTask, StatusCompleted, LocationFixed, "H", 1,
		"An unrelated closed item occupying Fixed.md block H1")
	seedItem(t, db, "TMX-902", TypeTask, StatusReadyForTest, LocationIssues, "H", 2,
		"The open item whose destination block code H2 is free in Fixed.md")

	if _, err := CloseItem(db, CloseItemParams{
		ATMID: "TMX-902", Status: "completed", Evidence: ev,
	}); err != nil {
		t.Fatalf("close onto a FREE destination block was refused: %v", err)
	}
	got, _ := db.GetItem("TMX-902")
	if got.Status != StatusCompleted {
		t.Errorf("status = %q, want %q", got.Status, StatusCompleted)
	}
	if got.CurrentLocation != LocationFixed {
		t.Errorf("location = %q, want %q", got.CurrentLocation, LocationFixed)
	}
	// The identity code MUST be carried across verbatim: reconcile.go's
	// blockHeadingIdentifies matches the stored ordinal against the block's own
	// `### H2` heading, and a cleared or renumbered ordinal refuses the move
	// (measured: clearing it to the 0 sentinel reintroduces the TMX-060
	// "closed item still in Issues.md" defect).
	if got.Category != "H" || got.CodeOrdinal != 2 {
		t.Errorf("block identity was altered: %s%d, want H2", got.Category, got.CodeOrdinal)
	}
}

// TestCloseWithSentinelOrdinalIsNeverRefused covers every `workable-items add`
// row: CodeOrdinal 0 asserts NO block claim, so it can never collide — even
// when another Fixed item shares its category.
func TestCloseWithSentinelOrdinalIsNeverRefused(t *testing.T) {
	db, dir := openCloseTestDB(t)
	ev := closeTestEvidence(t, dir)

	seedItem(t, db, "TMX-901", TypeTask, StatusCompleted, LocationFixed, "Z", 0,
		"A closed add-created item carrying the sentinel ordinal in category Z")
	added, err := AddItem(db, AddItemParams{
		Type:        TypeTask,
		Title:       "An add-created item that never carried a category-local ordinal",
		Description: "A description long enough to clear the §11.4.91 clarity floor for tests.",
		Category:    "Z",
	})
	if err != nil {
		t.Fatal(err)
	}
	if added.CodeOrdinal != 0 {
		t.Fatalf("precondition: AddItem must leave the sentinel ordinal, got %d", added.CodeOrdinal)
	}
	if _, err := CloseItem(db, CloseItemParams{
		ATMID: added.ATMID, Status: "completed", Evidence: ev,
	}); err != nil {
		t.Fatalf("close of a sentinel-ordinal item was refused: %v", err)
	}
}

// TestCloseObsoleteMayShareSupersedingItemsBlock covers §11.4.90: a superseded
// record legitimately shares the block of the item that replaced it. Measured
// live: (Fixed, B, 3) is held by BOTH TMX-001 (Obsolete) and TMX-054, and
// validate_identity.go skips Obsolete rows for exactly this reason. Refusing it
// would turn a correct supersession into a blocked closure.
func TestCloseObsoleteMayShareSupersedingItemsBlock(t *testing.T) {
	db, dir := openCloseTestDB(t)
	ev := closeTestEvidence(t, dir)

	seedItem(t, db, "TMX-901", TypeTask, StatusCompleted, LocationFixed, "B", 3,
		"The superseding item that owns Fixed.md block B3")
	seedItem(t, db, "TMX-902", TypeBug, StatusReopened, LocationIssues, "B", 3,
		"The superseded item that will be marked Obsolete against block B3")

	if _, err := CloseItem(db, CloseItemParams{
		ATMID:                   "TMX-902",
		Status:                  "obsolete",
		Evidence:                ev,
		Reason:                  "superseded-by-design-change",
		ObsoleteSupersedingItem: "TMX-901",
		ObsoleteTripleCheckPath: ev,
	}); err != nil {
		t.Fatalf("§11.4.90 obsolete closure sharing its superseding item's block was refused: %v", err)
	}
	got, _ := db.GetItem("TMX-902")
	if got.Status != StatusObsolete {
		t.Errorf("status = %q, want %q", got.Status, StatusObsolete)
	}
}

// TestCloseIsIdempotentUnderDoubleClose — an item's OWN row must never be read
// as the holder of its own destination identity.
func TestCloseIsIdempotentUnderDoubleClose(t *testing.T) {
	db, dir := openCloseTestDB(t)
	ev := closeTestEvidence(t, dir)

	seedItem(t, db, "TMX-902", TypeTask, StatusReadyForTest, LocationIssues, "K", 9,
		"An item closed twice in a row to prove the guard excludes its own row")

	for i := 1; i <= 2; i++ {
		if _, err := CloseItem(db, CloseItemParams{
			ATMID: "TMX-902", Status: "completed", Evidence: ev,
		}); err != nil {
			t.Fatalf("close attempt %d refused: %v", i, err)
		}
	}
	if h := identityHoldersForTest(t, db, LocationFixed, "K", 9); len(h) != 1 {
		t.Errorf("(Fixed,K,9) holders after a double close = %v, want exactly one", h)
	}
}

// TestCloseVocabularyPerTypeIsUnaffectedByTheGuard walks the §11.4.33 closed set
// (Bug->Fixed, Feature->Implemented, Task->Completed) through the guard on a
// free destination, and confirms a MISMATCHED vocabulary is still refused by
// §11.4.33 rather than being masked by the new identity check.
func TestCloseVocabularyPerTypeIsUnaffectedByTheGuard(t *testing.T) {
	cases := []struct {
		typ, token, want, wrongToken string
		ord                          int
	}{
		{TypeBug, "fixed", StatusFixed, "completed", 11},
		{TypeFeature, "implemented", StatusImplemented, "fixed", 12},
		{TypeTask, "completed", StatusCompleted, "implemented", 13},
	}
	for _, c := range cases {
		t.Run(c.typ, func(t *testing.T) {
			db, dir := openCloseTestDB(t)
			ev := closeTestEvidence(t, dir)
			seedItem(t, db, "TMX-902", c.typ, StatusReadyForTest, LocationIssues, "M", c.ord,
				"A "+c.typ+" item closed through its type-appropriate vocabulary")

			// Wrong vocabulary is still a §11.4.33 refusal, side-effect free.
			if _, err := CloseItem(db, CloseItemParams{
				ATMID: "TMX-902", Status: c.wrongToken, Evidence: ev,
			}); err == nil {
				t.Fatalf("§11.4.33 mismatch (%s as %s) was accepted", c.typ, c.wrongToken)
			}
			if got, _ := db.GetItem("TMX-902"); got.CurrentLocation != LocationIssues {
				t.Errorf("refused §11.4.33 close still migrated the row")
			}

			// Correct vocabulary closes cleanly through the guard.
			if _, err := CloseItem(db, CloseItemParams{
				ATMID: "TMX-902", Status: c.token, Evidence: ev,
			}); err != nil {
				t.Fatalf("close %s as %s refused: %v", c.typ, c.token, err)
			}
			got, _ := db.GetItem("TMX-902")
			if got.Status != c.want {
				t.Errorf("status = %q, want %q", got.Status, c.want)
			}
			if got.Category != "M" || got.CodeOrdinal != c.ord {
				t.Errorf("block identity altered: %s%d", got.Category, got.CodeOrdinal)
			}
		})
	}
}

// TestCloseRecordsTheIdentityMigrationAsEvidence — §11.4.226: a pointer that
// changed files with no recorded evidence is indistinguishable from one that
// was always that way.
func TestCloseRecordsTheIdentityMigrationAsEvidence(t *testing.T) {
	db, dir := openCloseTestDB(t)
	ev := closeTestEvidence(t, dir)

	seedItem(t, db, "TMX-902", TypeTask, StatusReadyForTest, LocationIssues, "N", 4,
		"An item whose closure must leave an auditable identity-migration record")

	if _, err := CloseItem(db, CloseItemParams{
		ATMID: "TMX-902", Status: "completed", Evidence: ev, Reason: "operator note",
	}); err != nil {
		t.Fatal(err)
	}
	var reason string
	if err := db.conn.QueryRow(
		`SELECT reason FROM item_history WHERE atm_id=? ORDER BY id DESC LIMIT 1`,
		"TMX-902").Scan(&reason); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(reason, "operator note") {
		t.Errorf("operator-supplied reason was clobbered: %q", reason)
	}
	if !strings.Contains(reason, "N4") || !strings.Contains(reason, LocationIssues) {
		t.Errorf("identity migration not recorded in history: %q", reason)
	}
}
