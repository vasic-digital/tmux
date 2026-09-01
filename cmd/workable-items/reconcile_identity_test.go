// reconcile_identity_test.go — §11.4.115 RED-baseline-on-the-broken-artifact
// regression guard for the TMX-ID-collision block-teleport defect.
//
// DEFECT (proven 2026-09-01, pre-existing at HEAD a6f3fc4):
// `findMovedBlocks` located the block to move by a bare `**TMX-ID:** TMX-NNN`
// STRING match in the document blob and then moved it based on
// `byID[id].CurrentLocation`, WITHOUT ever verifying that the located block is
// actually the block belonging to that item. On the live corpus four Issues.md
// blocks (TMX-078 / TMX-080 / TMX-081 / TMX-090) carried TMX-IDs that the
// allocator had independently handed to four UNRELATED Fixed.md items, so those
// four operator-authored Issues.md blocks were teleported into Fixed.md and had
// their `**Status:**` rewritten to the foreign item's terminal status
// (`Reopened` → `Implemented (→ Fixed.md)`, `Queued` → `Fixed (→ Fixed.md)`,
// `In progress` → `Completed (→ Fixed.md)`).
//
// Polarity switch per §11.4.115: RED_MODE=1 asserts the DEFECT IS PRESENT (used
// to capture the RED baseline against the pre-fix binary); the default
// RED_MODE=0 is the standing GREEN guard asserting the defect is ABSENT.

package main

import (
	"os"
	"strings"
	"testing"
)

// redMode reports whether the §11.4.115 polarity switch is armed.
func redMode() bool { return os.Getenv("RED_MODE") == "1" }

// TestReconcileDoesNotTeleportForeignIDBlock is the polarity test.
//
// Fixture: the Issues blob carries a block whose heading is `### G5 ...` — a
// heading the parser never bound to an item — but whose body carries
// `**TMX-ID:** TMX-078`. The item index maps TMX-078 to a COMPLETELY DIFFERENT
// item (`A50. Session-name sanitization ...`, current_location = Fixed).
//
// Correct behaviour: the block MUST NOT move — the reconciler cannot establish
// that this block belongs to TMX-078, so moving it would relocate one item's
// operator-authored prose under another item's identity.
func TestReconcileDoesNotTeleportForeignIDBlock(t *testing.T) {
	issuesSrc := strings.Join([]string{
		"# Open Issues",
		"",
		"## G. Wizard work",
		"",
		"### G5 SANITIZE-NAME-001 — session names containing spaces are normalized",
		"",
		"**TMX-ID:** TMX-078",
		"**Type:** Feature",
		"**Status:** Reopened",
		"",
		"Operator-authored prose that MUST stay in Issues.md verbatim.",
		"",
	}, "\n")
	fixedSrc := "# Closed Items\n\n## Items\n\n"

	// TMX-078 in the DB is an UNRELATED Fixed.md item.
	foreign := &Item{
		ATMID:           "TMX-078",
		Type:            TypeFeature,
		Status:          StatusImplemented,
		Title:           "Session-name sanitization for spaces and special characters",
		CurrentLocation: LocationFixed,
		Category:        "A",
		CodeOrdinal:     50,
	}
	foreign.HeadingHash = computeHeadingHash(foreign.Category, "A50", foreign.Title)
	byID := map[string]*Item{"TMX-078": foreign}

	newIssues, newFixed, moved := reconcileLocations(issuesSrc, fixedSrc, byID)

	if redMode() {
		// RED baseline: assert the defect IS present on the broken artifact.
		if moved == 0 {
			t.Fatalf("RED_MODE=1: expected the defect (block teleported) but moved=0")
		}
		t.Logf("RED_MODE=1: defect reproduced — moved=%d, block left Issues.md", moved)
		return
	}

	// GREEN guard: the foreign-ID block must NOT move.
	if moved != 0 {
		t.Errorf("block with a foreign TMX-ID was moved (moved=%d); it must stay put", moved)
	}
	if newIssues != issuesSrc {
		t.Errorf("Issues blob was mutated.\n--- got ---\n%s\n--- want ---\n%s", newIssues, issuesSrc)
	}
	if newFixed != fixedSrc {
		t.Errorf("Fixed blob was mutated.\n--- got ---\n%s\n--- want ---\n%s", newFixed, fixedSrc)
	}
	if strings.Contains(newFixed, "Operator-authored prose") {
		t.Errorf("operator prose from Issues.md leaked into Fixed.md")
	}
}

// TestReconcileStillMovesGenuineClosure is the §11.4.201(1) false-positive
// guard: the identity check must NOT break the legitimate TMX-060 migration
// (an item genuinely closed via `workable-items close`, whose blob block IS its
// own block, must still move Issues → Fixed).
func TestReconcileStillMovesGenuineClosure(t *testing.T) {
	title := "META-TEST-72-73-COVERAGE-001 — tests 72/73 need persistent meta-test mutations"
	issuesSrc := strings.Join([]string{
		"# Open Issues",
		"",
		"## A. Gate work",
		"",
		"### A3. " + title,
		"",
		"**TMX-ID:** TMX-076",
		"**Type:** Task",
		"**Status:** Ready for testing",
		"",
		"Body prose for the genuinely-closed item.",
		"",
	}, "\n")
	fixedSrc := "# Closed Items\n\n## Items\n\n"

	closed := &Item{
		ATMID:           "TMX-076",
		Type:            TypeTask,
		Status:          StatusCompleted,
		Title:           title,
		CurrentLocation: LocationFixed, // closed → belongs in Fixed.md now
		Category:        "A",
		CodeOrdinal:     3,
	}
	closed.HeadingHash = computeHeadingHash(closed.Category, "A3", title)
	byID := map[string]*Item{"TMX-076": closed}

	newIssues, newFixed, moved := reconcileLocations(issuesSrc, fixedSrc, byID)

	if moved != 1 {
		t.Fatalf("genuine closure did not migrate: moved=%d (want 1)", moved)
	}
	if strings.Contains(newIssues, "**TMX-ID:** TMX-076") {
		t.Errorf("closed item still present in Issues.md")
	}
	if !strings.Contains(newFixed, "Body prose for the genuinely-closed item.") {
		t.Errorf("closed item's verbatim body did not reach Fixed.md")
	}
	if !strings.Contains(newFixed, "**Status:** "+StatusCompleted) {
		t.Errorf("closed item's status was not rewritten to the structured value")
	}
}

// TestAllocatorNeverReissuesAnIDPresentInSource is the second-factor guard
// (§11.4.194 multi-factor): auto-allocation must never hand out a TMX-NNN that
// already appears as a `**TMX-ID:**` literal anywhere in the source corpus,
// even inside a block the parser does not bind as an item.
func TestAllocatorNeverReissuesAnIDPresentInSource(t *testing.T) {
	dir := t.TempDir()

	// Issues.md: a NO-PERIOD heading (never parsed as an item) that
	// nonetheless declares TMX-078.
	issues := strings.Join([]string{
		"# Open Issues",
		"",
		"## G. Wizard work",
		"",
		"### G5 SANITIZE-NAME-001 — session names containing spaces are normalized",
		"",
		"**TMX-ID:** TMX-078",
		"**Type:** Feature",
		"**Status:** Reopened",
		"",
		"Operator-authored prose.",
		"",
	}, "\n")
	// Fixed.md: three period-form items with NO explicit TMX-ID — they take
	// auto-allocated ids. Before the fix these started at TMX-001 and would
	// eventually collide with any literal in the corpus.
	fixed := strings.Join([]string{
		"# Closed Items",
		"",
		"## Items",
		"",
		"### A1. First closed item title long enough for the description floor — `RESOLVED`",
		"",
		"**Type:** Task",
		"",
		"First closed item body prose long enough to satisfy the floor.",
		"",
		"### A2. Second closed item title long enough for the description floor — `RESOLVED`",
		"",
		"**Type:** Task",
		"",
		"Second closed item body prose long enough to satisfy the floor.",
		"",
	}, "\n")

	issuesPath := dir + "/Issues.md"
	fixedPath := dir + "/Fixed.md"
	if err := os.WriteFile(issuesPath, []byte(issues), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(fixedPath, []byte(fixed), 0o644); err != nil {
		t.Fatal(err)
	}

	db, err := OpenDB(dir + "/t.db")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	// Drive the allocator to exactly the number the source already declares.
	// On the live corpus the counter reached 78 organically (36 unnumbered
	// Fixed.md items after a counter that unparsed literals never bumped);
	// pinning it here is the faithful minimal reduction of that state — the
	// invariant under test is "a literal present in the source is reserved
	// WHATEVER the counter reads", not the particular route to that value.
	if err := db.MetaSet("next_atm_id", "78"); err != nil {
		t.Fatal(err)
	}

	if _, err := SyncMDToDB(db, issuesPath, fixedPath); err != nil {
		t.Fatal(err)
	}

	// TMX-078 is declared in the source; no auto-allocated item may hold it.
	if it, _ := db.GetItem("TMX-078"); it != nil {
		t.Errorf("TMX-078 was re-issued to an unrelated item %q (cat=%s%d) — the "+
			"literal is present in Issues.md and MUST be reserved",
			it.Title, it.Category, it.CodeOrdinal)
	}
}
