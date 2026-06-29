// db_test.go — schema + DB invariant tests.

package main

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestOpenDB_AppliesSchema(t *testing.T) {
	tmp := t.TempDir()
	dbPath := filepath.Join(tmp, "schema.db")
	db, err := OpenDB(dbPath)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer db.Close()

	// schema_version should be present after schema application.
	v, err := db.MetaGet("schema_version")
	if err != nil {
		t.Fatalf("meta get: %v", err)
	}
	if v != "1" {
		t.Errorf("schema_version: got %q, want %q", v, "1")
	}
}

func TestNextATMID_Monotonic(t *testing.T) {
	tmp := t.TempDir()
	db, err := OpenDB(filepath.Join(tmp, "atm.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	var ids []string
	for i := 0; i < 5; i++ {
		id, err := db.NextATMID()
		if err != nil {
			t.Fatal(err)
		}
		ids = append(ids, id)
	}
	want := []string{"TMX-001", "TMX-002", "TMX-003", "TMX-004", "TMX-005"}
	for i, id := range ids {
		if id != want[i] {
			t.Errorf("ids[%d]: got %q, want %q", i, id, want[i])
		}
	}
}

func TestUpsertItem_Idempotent(t *testing.T) {
	tmp := t.TempDir()
	db, err := OpenDB(filepath.Join(tmp, "up.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	it := &Item{
		ATMID:           "TMX-001",
		Type:            TypeBug,
		Status:          StatusQueued,
		Severity:        "HIGH",
		Title:           "Foo bar baz",
		Description:     "A description that is long enough to satisfy §11.4.91 clarity floor.",
		CurrentLocation: LocationIssues,
		Category:        "A",
		CodeOrdinal:     1,
		HeadingHash:     computeHeadingHash("A", "A1", "Foo bar baz"),
	}
	if err := db.UpsertItem(it); err != nil {
		t.Fatalf("first upsert: %v", err)
	}
	n1, _ := db.CountRows()
	if err := db.UpsertItem(it); err != nil {
		t.Fatalf("second upsert: %v", err)
	}
	n2, _ := db.CountRows()
	if n1 != 1 || n2 != 1 {
		t.Errorf("counts: n1=%d n2=%d, want both 1", n1, n2)
	}
}

func TestValidate_DetectsShortDescription(t *testing.T) {
	tmp := t.TempDir()
	db, err := OpenDB(filepath.Join(tmp, "val.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	it := &Item{
		ATMID: "TMX-001", Type: TypeBug, Status: StatusQueued,
		Title: "x", Description: "short", CurrentLocation: LocationIssues,
		Category: "A", CodeOrdinal: 1,
		HeadingHash: computeHeadingHash("A", "A1", "x"),
	}
	if err := db.UpsertItem(it); err != nil {
		t.Fatal(err)
	}
	findings, err := Validate(db)
	if err != nil {
		t.Fatal(err)
	}
	foundShortDesc := false
	for _, f := range findings {
		if f.Section == "§11.4.91" {
			foundShortDesc = true
		}
	}
	if !foundShortDesc {
		t.Errorf("validate did not flag short description; got findings: %v", findings)
	}
}

func TestValidate_DetectsTypeAwareClosureMismatch(t *testing.T) {
	tmp := t.TempDir()
	db, err := OpenDB(filepath.Join(tmp, "vc.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	// Feature closed with "Fixed" (Bug closure word) → §11.4.33 violation.
	it := &Item{
		ATMID: "TMX-001", Type: TypeFeature, Status: StatusFixed,
		Title: "Some feature", Description: "A description longer than forty characters for §11.4.91.",
		CurrentLocation: LocationFixed,
		Category:        "A", CodeOrdinal: 1,
		HeadingHash: computeHeadingHash("A", "A1", "Some feature"),
	}
	if err := db.UpsertItem(it); err != nil {
		t.Fatal(err)
	}
	findings, err := Validate(db)
	if err != nil {
		t.Fatal(err)
	}
	gotMismatch := false
	for _, f := range findings {
		if f.Section == "§11.4.33" {
			gotMismatch = true
			if !strings.Contains(f.Detail, "Implemented") {
				t.Errorf("§11.4.33 detail does not name expected closure word: %q", f.Detail)
			}
		}
	}
	if !gotMismatch {
		t.Errorf("validate did not flag §11.4.33 mismatch; findings: %v", findings)
	}
}

func TestAddItem_AllocatesATMAndOpensHistory(t *testing.T) {
	tmp := t.TempDir()
	db, err := OpenDB(filepath.Join(tmp, "add.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	it, err := AddItem(db, AddItemParams{
		Type:        TypeBug,
		Severity:    "HIGH",
		Title:       "Test bug",
		Description: "A description that comfortably exceeds the forty-character §11.4.91 floor.",
		Category:    "A",
	})
	if err != nil {
		t.Fatalf("add: %v", err)
	}
	if it.ATMID != "TMX-001" {
		t.Errorf("TMX-ID: got %q want TMX-001", it.ATMID)
	}
	hist, err := db.HistoryFor(it.ATMID)
	if err != nil {
		t.Fatal(err)
	}
	if len(hist) != 1 || hist[0].EventType != "Opened" {
		t.Errorf("history: got %v, want 1 Opened event", hist)
	}
}

// TestOpenDB_MigratesRawBodyColumn (PWU-Q3, §11.4.93 phase-6) — verify that
// opening a DB whose `items` table lacks the raw_body column triggers the
// ALTER TABLE ADD COLUMN auto-migration without losing data.
func TestOpenDB_MigratesRawBodyColumn(t *testing.T) {
	tmp := t.TempDir()
	dbPath := filepath.Join(tmp, "migrate.db")

	// Phase 1: open DB, get past the auto-migrate logic, then DROP the
	// raw_body column to simulate an older DB.  SQLite doesn't have DROP
	// COLUMN until 3.35; instead we recreate the items table without
	// raw_body and then re-open via OpenDB.
	{
		db, err := OpenDB(dbPath)
		if err != nil {
			t.Fatalf("initial open: %v", err)
		}
		// Insert a row.
		it := &Item{
			ATMID:           "TMX-001",
			Type:            TypeTask,
			Status:          StatusQueued,
			Title:           "Migrate row",
			Description:     "A description that comfortably exceeds the forty-character §11.4.91 floor.",
			CurrentLocation: LocationIssues,
			Category:        "A",
			CodeOrdinal:     1,
			HeadingHash:     computeHeadingHash("A", "A1", "Migrate row"),
			RawBody:         "verbatim body content\n",
		}
		if err := db.UpsertItem(it); err != nil {
			t.Fatalf("upsert: %v", err)
		}
		// Simulate older schema by dropping raw_body column. SQLite >=3.35
		// supports ALTER TABLE DROP COLUMN; modernc.org/sqlite ships a new
		// enough version, so this works on the test host.
		if _, err := db.conn.Exec(`ALTER TABLE items DROP COLUMN raw_body`); err != nil {
			t.Skipf("DROP COLUMN not supported on this sqlite build: %v (test is best-effort)", err)
		}
		_ = db.Close()
	}

	// Phase 2: re-open and confirm the column is back + the row is intact.
	db, err := OpenDB(dbPath)
	if err != nil {
		t.Fatalf("re-open: %v", err)
	}
	defer db.Close()

	it, err := db.GetItem("TMX-001")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if it == nil {
		t.Fatalf("row vanished after migration")
	}
	if it.Title != "Migrate row" {
		t.Errorf("title drift after migration: got %q", it.Title)
	}
	// raw_body was dropped + re-added with default '' — so it's empty now.
	if it.RawBody != "" {
		t.Errorf("raw_body after re-add: got %q, want empty (column dropped + recreated)", it.RawBody)
	}
	// Confirm we CAN write to raw_body now.
	it.RawBody = "post-migration body"
	if err := db.UpsertItem(it); err != nil {
		t.Fatalf("write after migration: %v", err)
	}
	got, err := db.GetItem("TMX-001")
	if err != nil {
		t.Fatalf("re-get: %v", err)
	}
	if got.RawBody != "post-migration body" {
		t.Errorf("post-migration raw_body roundtrip: got %q", got.RawBody)
	}
}

// TestPutGetDocumentSource (PWU-Q3, §11.4.93 phase-6) — round-trip a verbatim
// document source through document_sources table.
func TestPutGetDocumentSource(t *testing.T) {
	tmp := t.TempDir()
	db, err := OpenDB(filepath.Join(tmp, "doc.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	got, err := db.GetDocumentSource(LocationIssues)
	if err != nil {
		t.Fatalf("get (empty): %v", err)
	}
	if got != "" {
		t.Errorf("get on empty: got %q, want \"\"", got)
	}
	want := "# Issues\n\n## A\n\n### A1. foo — `OPEN`\n**Status:** `OPEN`\n\nbody\n"
	if err := db.PutDocumentSource(LocationIssues, want); err != nil {
		t.Fatalf("put: %v", err)
	}
	got, err = db.GetDocumentSource(LocationIssues)
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if got != want {
		t.Errorf("get: %q, want %q", got, want)
	}
}

func TestCloseItem_RequiresEvidence(t *testing.T) {
	tmp := t.TempDir()
	db, err := OpenDB(filepath.Join(tmp, "cl.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	it, err := AddItem(db, AddItemParams{
		Type:        TypeBug,
		Title:       "x",
		Description: "A long enough description for the clarity floor §11.4.91 audit.",
		Category:    "A",
	})
	if err != nil {
		t.Fatal(err)
	}
	// Empty evidence path must fail.
	_, err = CloseItem(db, CloseItemParams{
		ATMID:    it.ATMID,
		Status:   "fixed",
		Evidence: "",
	})
	if err == nil {
		t.Errorf("close with empty evidence: expected error, got nil")
	}
	// Non-existent path must fail.
	_, err = CloseItem(db, CloseItemParams{
		ATMID:    it.ATMID,
		Status:   "fixed",
		Evidence: "/nonexistent/path/that/should/not/exist",
	})
	if err == nil {
		t.Errorf("close with non-existent evidence: expected error, got nil")
	}
}
