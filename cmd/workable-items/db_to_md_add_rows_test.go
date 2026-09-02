// db_to_md_add_rows_test.go — TMX-094 (§A6 ADD-ROWS-NOT-RENDERED-001).
//
// DEFECT (measured): `workable-items add` inserts a structured `items` row but
// writes NOTHING to `document_sources`. `SyncDBToMD` (sync_db_to_md.go:63-99)
// takes the blob-replay branch whenever EITHER blob is non-empty — which is the
// live-corpus state — and hands the whole regeneration to
// `reconcileLocations` (reconcile.go:298). That function only MOVES blocks
// already present in a blob (`findMovedBlocks` scans `srcLines` for
// `**TMX-ID:**` lines) and never APPENDS a block for an item that exists in the
// `items` table but appears in NEITHER blob. So an add-created row is a DB row
// that no tracker document ever shows — a silent loss of visibility at the
// requirements-intake layer (§11.4.202 / §11.4.197).
//
// §11.4.115 polarity switch: RED_MODE=1 asserts the defect is PRESENT on the
// pre-fix artifact; RED_MODE=0 (or unset) is the standing GREEN regression
// guard asserting it is ABSENT. One source, two roles.

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// This file reuses the package's existing §11.4.115 polarity switch
// `redMode()` (reconcile_identity_test.go:29), whose established convention is
// RED_MODE=1 → reproduce-and-assert-defect-present, and RED_MODE=0 or unset →
// the standing GREEN regression guard. Declaring a second, differently-defaulted
// switch here would fork the package's polarity semantics, so the existing one
// is used verbatim.

// addRowsIssuesBlob is a realistic non-empty Issues document_sources blob — the
// live-corpus state that selects the blob-replay branch in SyncDBToMD. It holds
// exactly one pre-existing item so the branch is entered with genuine content
// (an empty blob would take the structural writeIssuesMD path, which does NOT
// exhibit the defect — see TestDBToMD_ControlNeedle_StructuralPathRendersAddRow).
const addRowsIssuesBlob = `# vasic-digital tmux — Open Issues Tracker

## Items

### A1. Pre-existing operator-authored item — ` + "`OPEN`" + `
**TMX-ID:** TMX-900
**Type:** Bug
**Status:** ` + "`Queued`" + `
**Severity:** HIGH

Body text that lives ONLY in the blob.
`

const addRowsFixedBlob = `# vasic-digital tmux — Closed Items Tracker

## Items

_No closed items yet._
`

// seedAddRowsDB opens a TEMPORARY database (never the real
// docs/workable_items.db), seeds both document_sources blobs, and returns it.
func seedAddRowsDB(t *testing.T) (*DB, string) {
	t.Helper()
	tmp := t.TempDir()
	db, err := OpenDB(filepath.Join(tmp, "addrows.db"))
	if err != nil {
		t.Fatalf("open temp db: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	if err := db.PutDocumentSource(LocationIssues, addRowsIssuesBlob); err != nil {
		t.Fatalf("seed Issues blob: %v", err)
	}
	if err := db.PutDocumentSource(LocationFixed, addRowsFixedBlob); err != nil {
		t.Fatalf("seed Fixed blob: %v", err)
	}
	return db, tmp
}

// TestDBToMD_AddCreatedRowIsRendered drives the REAL `add` code path
// (AddItem) into a temp DB whose blobs are non-empty (the live-corpus shape),
// runs db-to-md into a temp dir, and asserts on the rendered Issues.md.
func TestDBToMD_AddCreatedRowIsRendered(t *testing.T) {
	db, tmp := seedAddRowsDB(t)

	it, err := AddItem(db, AddItemParams{
		Type:        "Bug",
		Severity:    "HIGH",
		Title:       "Add-created row must reach the tracker document",
		Description: "An operator files this item via the add verb; db-to-md must render it into Issues.md.",
		Category:    "A",
	})
	if err != nil {
		t.Fatalf("AddItem: %v", err)
	}

	outDir := filepath.Join(tmp, "out")
	if err := SyncDBToMD(db, outDir); err != nil {
		t.Fatalf("SyncDBToMD: %v", err)
	}
	raw, err := os.ReadFile(filepath.Join(outDir, "Issues.md"))
	if err != nil {
		t.Fatalf("read Issues.md: %v", err)
	}
	got := string(raw)

	// The pre-existing blob item MUST always survive — this is the in-test
	// control that the regeneration produced real content, not an empty file.
	if !strings.Contains(got, "TMX-900") {
		t.Fatalf("regenerated Issues.md lost the pre-existing blob item TMX-900; "+
			"the assertion below would be a false null. Content:\n%s", got)
	}

	present := strings.Contains(got, it.ATMID)

	if redMode() {
		if present {
			t.Fatalf("RED_MODE=1 but the add-created row %s IS already rendered — "+
				"this RED test is BLIND on this artifact (§11.4.115 honest boundary). "+
				"Investigate before treating a later GREEN as proof.", it.ATMID)
		}
		t.Logf("RED confirmed: add-created row %s is ABSENT from the regenerated "+
			"Issues.md (%d bytes). Defect reproduced on the pre-fix artifact.",
			it.ATMID, len(got))
		return
	}

	// RED_MODE=0 — the standing GREEN regression guard.
	if !present {
		t.Fatalf("GREEN guard FAILED: add-created row %s is missing from the "+
			"regenerated Issues.md. Content:\n%s", it.ATMID, got)
	}
	for _, want := range []string{
		"**" + TicketLabel + ":** " + it.ATMID,
		"**Type:** Bug",
		"**Status:** `" + StatusQueued + "`",
		"**Severity:** HIGH",
		it.Title,
		"An operator files this item via the add verb",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("GREEN guard: rendered Issues.md is missing %q. Content:\n%s", want, got)
		}
	}
	// The pre-existing verbatim body must still be preserved byte-for-byte.
	if !strings.Contains(got, "Body text that lives ONLY in the blob.") {
		t.Errorf("GREEN guard: the pre-existing verbatim blob body was lost. Content:\n%s", got)
	}
}

// TestDBToMD_ControlNeedle_StructuralPathRendersAddRow is the §11.4.201(7)(b)
// CONTROL NEEDLE for the assertion above: it proves the instrument (a
// strings.Contains scan of the regenerated Issues.md for the item's TMX id) CAN
// see an add-created row when the code path does render it. With BOTH blobs
// empty, SyncDBToMD takes the structural writeIssuesMD branch — the row IS
// emitted. If this needle were absent, the RED assertion's zero could be a
// blind instrument (a §11.4.201(6) FALSE-NULL) rather than a real defect.
//
// It is polarity-independent: it must PASS in both RED_MODE values.
func TestDBToMD_ControlNeedle_StructuralPathRendersAddRow(t *testing.T) {
	tmp := t.TempDir()
	db, err := OpenDB(filepath.Join(tmp, "needle.db"))
	if err != nil {
		t.Fatalf("open temp db: %v", err)
	}
	defer db.Close()
	// Deliberately NO PutDocumentSource — both blobs stay empty.

	it, err := AddItem(db, AddItemParams{
		Type:        "Task",
		Severity:    "LOW",
		Title:       "Control needle item",
		Description: "This item exists to prove the assertion instrument can see a rendered row.",
		Category:    "A",
	})
	if err != nil {
		t.Fatalf("AddItem: %v", err)
	}
	outDir := filepath.Join(tmp, "out")
	if err := SyncDBToMD(db, outDir); err != nil {
		t.Fatalf("SyncDBToMD: %v", err)
	}
	raw, err := os.ReadFile(filepath.Join(outDir, "Issues.md"))
	if err != nil {
		t.Fatalf("read Issues.md: %v", err)
	}
	if !strings.Contains(string(raw), it.ATMID) {
		t.Fatalf("CONTROL NEEDLE FAILED: the instrument cannot see %s even on the "+
			"structural path — every absence result in this file is BLIND. Content:\n%s",
			it.ATMID, string(raw))
	}
	t.Logf("control needle OK: instrument sees %s on the structural path", it.ATMID)
}

// TestDBToMD_AddedRowSurvivesRoundTrip is the §11.4.146 STEP-3 extend case for
// the TMX-094 fix: it exercises the case-space the fix newly reaches rather than
// only the single reported symptom.
//
// The specific risk it interrogates (solve-A-create-B, §11.4.1): an add-created
// row carries the CodeOrdinal 0 sentinel, so writeItemBlock renders its heading
// under the atmOrdinal fallback — `### A1.` for TMX-001. The seeded blob ALREADY
// contains a `### A1.` block (owned by TMX-900), so the fix deliberately emits a
// document with a DUPLICATE heading code. Duplicate codes are a pre-existing
// corpus property (measured on the live corpus: 92 code headings, 84 distinct —
// 8 codes already appear twice), but "pre-existing" is not "harmless", so this
// test drives the produced document back through md→db→md and asserts BOTH
// blocks survive with their own identities intact.
//
// Skipped under RED_MODE=1: pre-fix the row is never emitted, so there is
// nothing to round-trip and the assertion would be vacuous.
func TestDBToMD_AddedRowSurvivesRoundTrip(t *testing.T) {
	if redMode() {
		t.Skip("RED_MODE=1: the add-created row is not emitted pre-fix — nothing to round-trip")
	}
	db, tmp := seedAddRowsDB(t)

	it, err := AddItem(db, AddItemParams{
		Type:        "Bug",
		Severity:    "HIGH",
		Title:       "Round-tripped add-created row",
		Description: "This add-created row must survive a full md-to-db then db-to-md cycle.",
		Category:    "A",
	})
	if err != nil {
		t.Fatalf("AddItem: %v", err)
	}

	first := filepath.Join(tmp, "pass1")
	if err := SyncDBToMD(db, first); err != nil {
		t.Fatalf("SyncDBToMD pass 1: %v", err)
	}
	// Feed the produced documents back in, then regenerate.
	if _, err := SyncMDToDB(db, filepath.Join(first, "Issues.md"), filepath.Join(first, "Fixed.md")); err != nil {
		t.Fatalf("SyncMDToDB: %v", err)
	}
	second := filepath.Join(tmp, "pass2")
	if err := SyncDBToMD(db, second); err != nil {
		t.Fatalf("SyncDBToMD pass 2: %v", err)
	}
	raw, err := os.ReadFile(filepath.Join(second, "Issues.md"))
	if err != nil {
		t.Fatalf("read pass-2 Issues.md: %v", err)
	}
	got := string(raw)

	if !strings.Contains(got, it.ATMID) {
		t.Errorf("the add-created row %s did not survive the round-trip. Content:\n%s", it.ATMID, got)
	}
	if !strings.Contains(got, "TMX-900") {
		t.Errorf("the pre-existing item TMX-900 was lost by the round-trip. Content:\n%s", got)
	}
	if !strings.Contains(got, "Body text that lives ONLY in the blob.") {
		t.Errorf("TMX-900's verbatim operator body was lost by the round-trip. Content:\n%s", got)
	}
	if !strings.Contains(got, it.Title) {
		t.Errorf("the add-created row's title was lost by the round-trip. Content:\n%s", got)
	}
	// The row must not be duplicated by the second regeneration: once it has a
	// block in the blob it is no longer sourceless, so exactly one id line.
	if n := strings.Count(got, "**"+TicketLabel+":** "+it.ATMID); n != 1 {
		t.Errorf("expected exactly 1 `%s` id line after the round-trip, got %d. Content:\n%s",
			TicketLabel, n, got)
	}
}
