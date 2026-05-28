// roundtrip_test.go — golden corpus round-trip: MD → DB → MD must be byte-identical.
//
// Per §11.4.93 the bidirectional regeneration guarantee MUST be byte-stable for
// the golden testdata corpus. The corpus is the controlled fixture, not the
// legacy live tmux Issues.md (which carries free-form bodies that don't fit
// the structured schema).

package main

import (
	"bytes"
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

// TestRoundTrip_LiveCorpusByteIdentical (PWU-Q3, §11.4.93 phase-6) verifies
// that md→db then db→md of the LIVE tmux Issues.md + Fixed.md snapshots
// produces byte-identical output. The snapshots under testdata/ are copies
// of the project-root files at the time of PWU-Q3 implementation; they
// exercise free-form bodies (forensic anchors, multi-paragraph captured-
// evidence, blockquotes, code fences) that pre-PWU-Q3 truncated to
// description-only and broke the round-trip.
func TestRoundTrip_LiveCorpusByteIdentical(t *testing.T) {
	tmp := t.TempDir()
	dbPath := filepath.Join(tmp, "live.db")

	db, err := OpenDB(dbPath)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer db.Close()

	issuesSrc := "testdata/live_issues_snapshot.md"
	fixedSrc := "testdata/live_fixed_snapshot.md"

	res, err := SyncMDToDB(db, issuesSrc, fixedSrc)
	if err != nil {
		t.Fatalf("md-to-db: %v", err)
	}
	t.Logf("md-to-db result: issues_parsed=%d fixed_parsed=%d inserted=%d updated=%d unchanged=%d allocated=%d",
		res.IssuesParsed, res.FixedParsed, res.Inserted, res.Updated, res.UnchangedItems, res.ATMIDsAllocated)

	outDir := filepath.Join(tmp, "out")
	if err := SyncDBToMD(db, outDir); err != nil {
		t.Fatalf("db-to-md: %v", err)
	}

	for _, pair := range []struct{ src, name string }{
		{issuesSrc, "Issues.md"},
		{fixedSrc, "Fixed.md"},
	} {
		original, err := os.ReadFile(pair.src)
		if err != nil {
			t.Fatalf("read %s: %v", pair.src, err)
		}
		regen, err := os.ReadFile(filepath.Join(outDir, pair.name))
		if err != nil {
			t.Fatalf("read regen %s: %v", pair.name, err)
		}
		if !bytes.Equal(original, regen) {
			dumpPath := filepath.Join(tmp, pair.name+".regen.dump")
			_ = os.WriteFile(dumpPath, regen, 0o644)
			t.Errorf("live-corpus %s round-trip drift: lengths original=%d regen=%d (see %s)",
				pair.name, len(original), len(regen), dumpPath)
			// Print first diverging offset for quick triage.
			minLen := len(original)
			if len(regen) < minLen {
				minLen = len(regen)
			}
			for i := 0; i < minLen; i++ {
				if original[i] != regen[i] {
					t.Errorf("  first divergence at byte %d: original=%q regen=%q",
						i, snippet(original, i, 60), snippet(regen, i, 60))
					break
				}
			}
		}
	}
}

func snippet(b []byte, offset, n int) string {
	end := offset + n
	if end > len(b) {
		end = len(b)
	}
	return string(b[offset:end])
}

// TestRoundTrip_LiveCorpusIdempotent verifies that running md→db twice on the
// live snapshots does not allocate new ATM-NNN ids (the second sync should be
// a no-op modulo last_sync_timestamp).
func TestRoundTrip_LiveCorpusIdempotent(t *testing.T) {
	tmp := t.TempDir()
	dbPath := filepath.Join(tmp, "liveidem.db")

	db, err := OpenDB(dbPath)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer db.Close()

	issuesSrc := "testdata/live_issues_snapshot.md"
	fixedSrc := "testdata/live_fixed_snapshot.md"

	r1, err := SyncMDToDB(db, issuesSrc, fixedSrc)
	if err != nil {
		t.Fatalf("first sync: %v", err)
	}
	r2, err := SyncMDToDB(db, issuesSrc, fixedSrc)
	if err != nil {
		t.Fatalf("second sync: %v", err)
	}
	if r2.ATMIDsAllocated > 0 {
		t.Errorf("second sync allocated %d new ATM-NNNs (want 0); first allocated %d",
			r2.ATMIDsAllocated, r1.ATMIDsAllocated)
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
