// db_to_md_render_test.go — TMX-094 golden proof: an add-created DB row is
// rendered into the correct tracker block with its own identity.
//
// These tests are INDEPENDENT of the pre-existing db_to_md_add_rows_test.go
// polarity test: they assert an exact multi-line GOLDEN block, and repeat the
// assertion on a PRIVATE copy of the real tracked SSoT (never the original).
// Both paths use the real AddItem producer and the real SyncDBToMD exporter.

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const renderGoldenIssuesBlob = "# vasic-digital tmux — Open Issues Tracker\n\n" +
	"## Items\n\n" +
	"### A1. Golden pre-existing blob item — `OPEN`\n" +
	"**TMX-ID:** TMX-950\n" +
	"**Type:** Task\n" +
	"**Status:** `Queued`\n\n" +
	"Body that exists ONLY in the verbatim blob.\n"

const renderGoldenFixedBlob = "# vasic-digital tmux — Closed Items Tracker\n\n" +
	"## Items\n\n" +
	"_No closed items yet._\n"

func seedGoldenRenderDB(t *testing.T) (*DB, string) {
	t.Helper()
	tmp := t.TempDir()
	db, err := OpenDB(filepath.Join(tmp, "golden_render.db"))
	if err != nil {
		t.Fatalf("open private db: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	if err := db.PutDocumentSource(LocationIssues, renderGoldenIssuesBlob); err != nil {
		t.Fatalf("seed Issues blob: %v", err)
	}
	if err := db.PutDocumentSource(LocationFixed, renderGoldenFixedBlob); err != nil {
		t.Fatalf("seed Fixed blob: %v", err)
	}
	return db, tmp
}

// TestDBToMDRender_AddCreatedRowGoldenBlock is the golden test for TMX-094.
// The blob-replay branch is active (both document_sources are non-empty), which
// is exactly the live-corpus shape where a sourceless add row was invisible.
func TestDBToMDRender_AddCreatedRowGoldenBlock(t *testing.T) {
	db, tmp := seedGoldenRenderDB(t)

	const title = "Golden add-created item reaches the tracker"
	const desc = "This description is long enough to satisfy the structured item description floor."
	it, err := AddItem(db, AddItemParams{
		Type:        TypeBug,
		Severity:    "HIGH",
		Title:       title,
		Description: desc,
		Category:    "A",
	})
	if err != nil {
		t.Fatalf("AddItem: %v", err)
	}
	if it.RawBody != "" {
		t.Fatalf("test setup: add-created row unexpectedly has raw_body=%q", it.RawBody)
	}

	outDir := filepath.Join(tmp, "out")
	if err := SyncDBToMD(db, outDir); err != nil {
		t.Fatalf("SyncDBToMD: %v", err)
	}
	issues, err := os.ReadFile(filepath.Join(outDir, "Issues.md"))
	if err != nil {
		t.Fatalf("read rendered Issues.md: %v", err)
	}
	fixed, err := os.ReadFile(filepath.Join(outDir, "Fixed.md"))
	if err != nil {
		t.Fatalf("read rendered Fixed.md: %v", err)
	}
	gotIssues, gotFixed := string(issues), string(fixed)

	// Control needle: the pre-existing verbatim blob MUST survive. Without it a
	// zero-result for the new row could come from a blank/corrupt export.
	if !strings.Contains(gotIssues, "TMX-950") ||
		!strings.Contains(gotIssues, "Body that exists ONLY in the verbatim blob.") {
		t.Fatalf("control failed: pre-existing blob item lost. Issues.md:\n%s", gotIssues)
	}

	// GOLDEN: exact block the exporter must synthesise for a sourceless row.
	want := fmt.Sprintf("### %s%d. %s — `OPEN`\n"+
		"**%s:** %s\n"+
		"**Type:** Bug\n"+
		"**Status:** `%s`\n"+
		"**Severity:** HIGH\n\n"+
		"%s",
		"A", atmOrdinal(it.ATMID), title,
		TicketLabel, it.ATMID,
		StatusQueued,
		desc)
	if !strings.Contains(gotIssues, want) {
		t.Errorf("golden block for %s not found in Issues.md.\n--- want ---\n%s\n--- got ---\n%s",
			it.ATMID, want, gotIssues)
	}
	idLine := "**" + TicketLabel + ":** " + it.ATMID
	if n := strings.Count(gotIssues, idLine); n != 1 {
		t.Errorf("%s: want exactly 1 id line in Issues.md, got %d", it.ATMID, n)
	}
	if strings.Contains(gotFixed, idLine) {
		t.Errorf("%s: add-created Queued row was rendered into Fixed.md (wrong tracker)", it.ATMID)
	}
	t.Logf("golden evidence: out=%s id=%s heading=A%d", outDir, it.ATMID, atmOrdinal(it.ATMID))
}

// TestDBToMDRender_AddCreatedRowOnPrivateCorpusCopy repeats the proof on a
// byte-for-byte PRIVATE copy of the real tracked SSoT. The original file is
// read only; AddItem and SyncDBToMD operate on the copy under t.TempDir().
func TestDBToMDRender_AddCreatedRowOnPrivateCorpusCopy(t *testing.T) {
	tracked := filepath.Join("..", "..", "docs", "workable_items.db")
	if _, err := os.Stat(tracked); err != nil {
		t.Skipf("tracked SSoT %s unavailable: %v (honest SKIP, no fixture substituted)", tracked, err)
	}
	raw, err := os.ReadFile(tracked)
	if err != nil {
		t.Fatalf("read tracked SSoT for private copy: %v", err)
	}
	tmp := t.TempDir()
	private := filepath.Join(tmp, "private_copy.db")
	if err := os.WriteFile(private, raw, 0o600); err != nil {
		t.Fatalf("write private copy: %v", err)
	}
	db, err := OpenDB(private)
	if err != nil {
		t.Fatalf("open private copy: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })

	// Control needle: seed an independent add-created row on the PRIVATE copy.
	// A pre-existing live corpus id is NOT a stable control — the tracker is a
	// living SSoT and the former control (TMX-076) legitimately closed and
	// moved to Fixed.md, making this test fail for the wrong reason.
	control, err := AddItem(db, AddItemParams{
		Type:        TypeTask,
		Severity:    "LOW",
		Title:       "Private corpus control row",
		Description: "Independent row proving regeneration preserves prior additions.",
		Category:    "B",
	})
	if err != nil {
		t.Fatalf("AddItem control on private copy: %v", err)
	}
	controlID := control.ATMID

	it, err := AddItem(db, AddItemParams{
		Type:        TypeTask,
		Severity:    "MEDIUM",
		Title:       "Private corpus copy renders add-created row",
		Description: "Proves the real SSoT shape renders a row created by the add verb.",
		Category:    "A",
	})
	if err != nil {
		t.Fatalf("AddItem on private copy: %v", err)
	}
	outDir := filepath.Join(tmp, "private_out")
	if err := SyncDBToMD(db, outDir); err != nil {
		t.Fatalf("SyncDBToMD private copy: %v", err)
	}
	gotBytes, err := os.ReadFile(filepath.Join(outDir, "Issues.md"))
	if err != nil {
		t.Fatalf("read private output: %v", err)
	}
	got := string(gotBytes)
	if !strings.Contains(got, controlID) {
		t.Errorf("control item %s lost from private-corpus regeneration", controlID)
	}
	idLine := "**" + TicketLabel + ":** " + it.ATMID
	if n := strings.Count(got, idLine); n != 1 {
		t.Errorf("%s: want exactly 1 id line in private-corpus Issues.md, got %d", it.ATMID, n)
	}
	if !strings.Contains(got, it.Title) {
		t.Errorf("%s: rendered private-corpus Issues.md lacks the added row's title", it.ATMID)
	}
	t.Logf("private-corpus evidence: src=%s (read-only), copy=%s, out=%s, id=%s",
		tracked, private, outDir, it.ATMID)
}
