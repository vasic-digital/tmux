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
	want := []string{"ATM-001", "ATM-002", "ATM-003", "ATM-004", "ATM-005"}
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
		ATMID:           "ATM-001",
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
		ATMID: "ATM-001", Type: TypeBug, Status: StatusQueued,
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
		ATMID: "ATM-001", Type: TypeFeature, Status: StatusFixed,
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
	if it.ATMID != "ATM-001" {
		t.Errorf("ATM-ID: got %q want ATM-001", it.ATMID)
	}
	hist, err := db.HistoryFor(it.ATMID)
	if err != nil {
		t.Fatal(err)
	}
	if len(hist) != 1 || hist[0].EventType != "Opened" {
		t.Errorf("history: got %v, want 1 Opened event", hist)
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
