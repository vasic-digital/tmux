// roundtrip_test.go — golden corpus round-trip: MD → DB → MD must be byte-identical.
//
// Per §11.4.93 the bidirectional regeneration guarantee MUST be byte-stable for
// the golden testdata corpus. The corpus is the controlled fixture, not the
// legacy live tmux Issues.md (which carries free-form bodies that don't fit
// the structured schema).

package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRoundTrip_Issues_GoldenCorpus(t *testing.T) {
	tmp := t.TempDir()
	dbPath := filepath.Join(tmp, "rt.db")

	db, err := OpenDB(dbPath)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer db.Close()

	src := "testdata/golden_issues.md"
	res, err := SyncMDToDB(db, src, "")
	if err != nil {
		t.Fatalf("md-to-db: %v", err)
	}
	if res.IssuesParsed == 0 {
		t.Fatalf("expected ≥1 issues parsed, got 0")
	}
	outDir := filepath.Join(tmp, "out")
	if err := SyncDBToMD(db, outDir); err != nil {
		t.Fatalf("db-to-md: %v", err)
	}

	regen, err := os.ReadFile(filepath.Join(outDir, "Issues.md"))
	if err != nil {
		t.Fatalf("read regen: %v", err)
	}
	original, err := os.ReadFile(src)
	if err != nil {
		t.Fatalf("read original: %v", err)
	}
	if string(regen) != string(original) {
		// Write the regen to a tempfile + dump unified diff for forensic record.
		dumpPath := filepath.Join(tmp, "regen.dump")
		_ = os.WriteFile(dumpPath, regen, 0o644)
		t.Errorf("round-trip drift: %s vs %s\n--- regen ---\n%s\n--- original ---\n%s\n(see %s)",
			src, filepath.Join(outDir, "Issues.md"), string(regen), string(original), dumpPath)
	}
}

func TestRoundTrip_Fixed_GoldenCorpus(t *testing.T) {
	tmp := t.TempDir()
	dbPath := filepath.Join(tmp, "rtf.db")

	db, err := OpenDB(dbPath)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer db.Close()

	src := "testdata/golden_fixed.md"
	res, err := SyncMDToDB(db, "", src)
	if err != nil {
		t.Fatalf("md-to-db: %v", err)
	}
	if res.FixedParsed == 0 {
		t.Fatalf("expected ≥1 fixed parsed, got 0")
	}
	outDir := filepath.Join(tmp, "out")
	if err := SyncDBToMD(db, outDir); err != nil {
		t.Fatalf("db-to-md: %v", err)
	}

	regen, err := os.ReadFile(filepath.Join(outDir, "Fixed.md"))
	if err != nil {
		t.Fatalf("read regen: %v", err)
	}
	original, err := os.ReadFile(src)
	if err != nil {
		t.Fatalf("read original: %v", err)
	}
	if string(regen) != string(original) {
		t.Errorf("round-trip drift\n--- regen ---\n%s\n--- original ---\n%s",
			string(regen), string(original))
	}
}

func TestRoundTrip_Idempotent(t *testing.T) {
	// After md→db→md, applying md→db a SECOND time should not allocate new
	// ATM-NNN ids (the ExplicitATM rebind preserves them).
	tmp := t.TempDir()
	dbPath := filepath.Join(tmp, "idem.db")

	db, err := OpenDB(dbPath)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer db.Close()

	src := "testdata/golden_issues.md"
	r1, err := SyncMDToDB(db, src, "")
	if err != nil {
		t.Fatalf("first sync: %v", err)
	}
	r2, err := SyncMDToDB(db, src, "")
	if err != nil {
		t.Fatalf("second sync: %v", err)
	}
	if r2.ATMIDsAllocated > 0 {
		t.Errorf("second sync allocated %d new ATM-NNNs (want 0); first allocated %d",
			r2.ATMIDsAllocated, r1.ATMIDsAllocated)
	}
	if r2.Inserted > 0 {
		t.Errorf("second sync inserted %d new rows (want 0)", r2.Inserted)
	}
}
