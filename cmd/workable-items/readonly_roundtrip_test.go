// readonly_roundtrip_test.go — TMX-103 proof: a pure db-to-md export does not
// mutate the source SQLite SSoT (byte-identical file, no WAL/shm residue).
//
// The needle test deliberately re-applies the OLD two MetaSet stamps and
// asserts the hash DOES change — proving the hash instrument is not blind and
// that this test would fail against the pre-fix artifact (§1.1 paired mutation).

package main

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"
)

func sha256File(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s for sha256: %v", path, err)
	}
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// seedReadOnlyDB builds a private DB from the tracked golden snapshots. The
// seed writes happen BEFORE the baseline hash; the export under test happens
// strictly after it.
func seedReadOnlyDB(t *testing.T) (*DB, string, string) {
	t.Helper()
	tmp := t.TempDir()
	dbPath := filepath.Join(tmp, "readonly.db")
	db, err := OpenDB(dbPath)
	if err != nil {
		t.Fatalf("open private db: %v", err)
	}
	if _, err := SyncMDToDB(db,
		filepath.Join("testdata", "live_issues_snapshot.md"),
		filepath.Join("testdata", "live_fixed_snapshot.md")); err != nil {
		_ = db.Close()
		t.Fatalf("seed private db from snapshots: %v", err)
	}
	return db, dbPath, tmp
}

func assertNoSidecars(t *testing.T, dbPath string) {
	t.Helper()
	for _, suffix := range []string{"-wal", "-shm"} {
		p := dbPath + suffix
		if st, err := os.Stat(p); err == nil && st.Size() > 0 {
			t.Errorf("read-only export left a non-empty sidecar %s (%d bytes)", p, st.Size())
		}
	}
}

// TestDBToMDReadOnly_ByteIdentical is the primary TMX-103 acceptance test:
// OpenDB → SyncDBToMD → DB.Close (the full CLI round-trip) leaves the private
// DB file byte-identical and produces real tracker output.
func TestDBToMDReadOnly_ByteIdentical(t *testing.T) {
	db, dbPath, tmp := seedReadOnlyDB(t)
	if err := db.Close(); err != nil { // quiescent baseline: WAL checkpoint done
		t.Fatalf("close seed db: %v", err)
	}
	before := sha256File(t, dbPath)

	export, err := OpenDB(dbPath)
	if err != nil {
		t.Fatalf("reopen private db: %v", err)
	}
	dirBefore, err := export.MetaGet("last_sync_direction")
	if err != nil {
		t.Fatalf("MetaGet direction: %v", err)
	}
	tsBefore, err := export.MetaGet("last_sync_timestamp")
	if err != nil {
		t.Fatalf("MetaGet timestamp: %v", err)
	}
	outDir := filepath.Join(tmp, "export")
	if err := SyncDBToMD(export, outDir); err != nil {
		t.Fatalf("SyncDBToMD: %v", err)
	}
	dirAfter, _ := export.MetaGet("last_sync_direction")
	tsAfter, _ := export.MetaGet("last_sync_timestamp")
	if dirBefore != dirAfter || tsBefore != tsAfter {
		t.Errorf("export mutated meta stamps: direction %q→%q, timestamp %q→%q",
			dirBefore, dirAfter, tsBefore, tsAfter)
	}
	if err := export.Close(); err != nil {
		t.Fatalf("close export db: %v", err)
	}
	after := sha256File(t, dbPath)
	if before != after {
		t.Errorf("TMX-103 REGRESSION: db-to-md mutated source DB.\n  before=%s\n  after =%s\nsrc=%s",
			before, after, dbPath)
	}
	assertNoSidecars(t, dbPath)
	for _, name := range []string{"Issues.md", "Fixed.md"} {
		p := filepath.Join(outDir, name)
		st, err := os.Stat(p)
		if err != nil {
			t.Fatalf("export did not produce %s: %v", p, err)
		}
		if st.Size() == 0 {
			t.Errorf("export produced an empty %s — byte-identity could be a false pass", p)
		}
	}
	t.Logf("read-only evidence: sha256=%s (unchanged), src=%s, out=%s", after, dbPath, outDir)
}

// TestDBToMDReadOnly_StampNeedle proves the hash instrument detects exactly
// the behaviour removed by the TMX-103 fix. It writes the OLD stamps explicitly
// and requires a different hash; a hash that never changes would be a bluff.
func TestDBToMDReadOnly_StampNeedle(t *testing.T) {
	db, dbPath, _ := seedReadOnlyDB(t)
	if err := db.Close(); err != nil {
		t.Fatalf("close seed db: %v", err)
	}
	before := sha256File(t, dbPath)

	write, err := OpenDB(dbPath)
	if err != nil {
		t.Fatalf("reopen private db: %v", err)
	}
	// This is the pre-fix source behaviour (old sync_db_to_md.go:131-134).
	if err := write.MetaSet("last_sync_direction", "db-to-md"); err != nil {
		t.Fatalf("stamp direction: %v", err)
	}
	if err := write.MetaSet("last_sync_timestamp", "2026-01-02T03:04:05Z"); err != nil {
		t.Fatalf("stamp timestamp: %v", err)
	}
	if err := write.Close(); err != nil {
		t.Fatalf("close stamped db: %v", err)
	}
	after := sha256File(t, dbPath)
	if before == after {
		t.Errorf("needle FAILED: the old MetaSet stamps did not change the DB hash (%s) "+
			"— the byte-identity assertion is BLIND", before)
	}
	t.Logf("needle OK: old stamps changed hash %s → %s", before, after)
}

// TestDBToMDReadOnly_PrivateTrackedCopy is the item's exact repro shape: a
// private copy of the git-tracked SSoT, exported into a throwaway out-dir.
func TestDBToMDReadOnly_PrivateTrackedCopy(t *testing.T) {
	tracked := filepath.Join("..", "..", "docs", "workable_items.db")
	raw, err := os.ReadFile(tracked)
	if err != nil {
		t.Skipf("tracked SSoT %s unavailable: %v (honest SKIP)", tracked, err)
	}
	tmp := t.TempDir()
	private := filepath.Join(tmp, "tracked_copy.db")
	if err := os.WriteFile(private, raw, 0o600); err != nil {
		t.Fatalf("write private copy: %v", err)
	}
	before := sha256File(t, private)

	db, err := OpenDB(private)
	if err != nil {
		t.Fatalf("open private copy: %v", err)
	}
	outDir := filepath.Join(tmp, "throwaway_out")
	if err := SyncDBToMD(db, outDir); err != nil {
		t.Fatalf("SyncDBToMD private copy: %v", err)
	}
	if err := db.Close(); err != nil {
		t.Fatalf("close private copy: %v", err)
	}
	after := sha256File(t, private)
	if before != after {
		t.Errorf("tracked-SSoT copy mutated by verification round-trip: %s → %s", before, after)
	}
	assertNoSidecars(t, private)
	st, err := os.Stat(filepath.Join(outDir, "Issues.md"))
	if err != nil || st.Size() == 0 {
		t.Errorf("verification export produced no Issues.md: err=%v", err)
	}
	t.Logf("private tracked-copy evidence: %s → out=%s, sha256=%s (unchanged), "+
		"original=%s (read-only)",
		private, outDir, after, filepath.Join("..", "..", "docs", "workable_items.db"))
}

// TestDBToMDReadOnly_RealMutationStillWrites guards the opposite false pass:
// an instrument that reports "byte-identical" even for a genuine write.
func TestDBToMDReadOnly_RealMutationStillWrites(t *testing.T) {
	db, dbPath, tmp := seedReadOnlyDB(t)
	if err := db.Close(); err != nil {
		t.Fatalf("close seed db: %v", err)
	}
	before := sha256File(t, dbPath)
	write, err := OpenDB(dbPath)
	if err != nil {
		t.Fatalf("reopen private db: %v", err)
	}
	if _, err := AddItem(write, AddItemParams{
		Type:        TypeTask,
		Severity:    "LOW",
		Title:       "Control: a real mutation must still write",
		Description: "This item exists solely to prove the DB hash instrument detects writes.",
		Category:    "A",
	}); err != nil {
		t.Fatalf("AddItem: %v", err)
	}
	if err := write.Close(); err != nil {
		t.Fatalf("close mutated db: %v", err)
	}
	after := sha256File(t, dbPath)
	if before == after {
		t.Errorf("control FAILED: a real AddItem did not change the hash (%s)", before)
	}
	t.Logf("write control OK: %s → %s (tmp=%s)", before, after, tmp)
}
