// sourceless_signals_test.go — §1.1 per-signal guards for sourcelessItems
// (sync_db_to_md.go).
//
// WHY THIS FILE EXISTS. `sourcelessItems` decides which DB rows db→md may
// SYNTHESISE a markdown block for. A false positive here does not omit an item
// — it DUPLICATES one into a tracker document, which is corruption of the class
// §11.4.108 forbids and strictly worse than the omission the pass repairs. The
// function guards against that with several independent suppression signals,
// but db_to_md_add_rows_test.go only exercises the function end-to-end through
// SyncDBToMD on a fixture where NO suppression signal fires — so none of the
// signals was under test. An independent reviewer measured the consequence:
// deleting the `owners[""]` clause left the suite GREEN, and deleting the
// `it.RawBody != ""` gate ALSO left the suite GREEN while the live-corpus
// regeneration silently DUPLICATED a real block. Independently re-measured here
// before codifying (§11.4.6): regenerating the live DB with that gate removed
// takes Fixed.md from 85 `### ` headings to 86, the extra one a synthesised
// `### F1.` block for TMX-050. Only the raw_body gate was holding the line,
// and nothing was watching it.
//
// Each test below isolates ONE signal: the fixture is built so that signal is
// the ONLY thing suppressing the item, so deleting that signal flips the
// verdict and the test FAILs. Every case is paired with the positive control
// (TestSourcelessItems_GenuinelySourcelessRowIsReturned) proving the instrument
// can see a row it SHOULD return — without it, every "not returned" result
// could be a blind instrument rather than a working signal (§11.4.201(6)).
//
// HONEST BOUNDARY (§11.4.6). One clause is deliberately NOT covered: the
// `owners[it.ATMID]` half of blockClaimedBy. It is unreachable in isolation by
// construction — `codeOwners[code][id]` is only ever populated from the same
// `**TMX-ID:**` line that populates `ids[id]`, so the id-line signal always
// fires first and the clause is defensive redundancy, not a load-bearing
// signal. Measured: deleting `owners[it.ATMID] ||` alone leaves the whole
// package suite GREEN. Claiming a test for it would be a false coverage claim;
// it is recorded here instead.

package main

import "testing"

// sourcelessIDs runs sourcelessItems over the given items + blobs and returns
// the set of ids it selected for synthesis.
func sourcelessIDs(items []*Item, blobs ...string) map[string]bool {
	byID := map[string]*Item{}
	for _, it := range items {
		byID[it.ATMID] = it
	}
	got := map[string]bool{}
	for _, it := range sourcelessItems(byID, blobs...) {
		got[it.ATMID] = true
	}
	return got
}

func mkItem(id, cat string, codeOrdinal int, rawBody string) *Item {
	return &Item{
		ATMID:           id,
		Type:            TypeBug,
		Status:          StatusQueued,
		Title:           "a fixture item for the sourceless-signal guards",
		Description:     "A fixture item long enough to clear the description floor.",
		CurrentLocation: LocationIssues,
		Category:        cat,
		CodeOrdinal:     codeOrdinal,
		RawBody:         rawBody,
	}
}

// TestSourcelessItems_GenuinelySourcelessRowIsReturned is the CONTROL NEEDLE
// (§11.4.201(7)(b)) for every negative assertion in this file: an item with no
// raw_body, no id line and no matching block code MUST be returned. If this
// fails, every "was not returned" result below is blind and proves nothing.
func TestSourcelessItems_GenuinelySourcelessRowIsReturned(t *testing.T) {
	blob := "# Issues\n\n### A1. someone else's block\n\n**TMX-ID:** TMX-900\n\nbody.\n"
	got := sourcelessIDs([]*Item{mkItem("TMX-901", "F", 1, "")}, blob)
	if !got["TMX-901"] {
		t.Fatalf("CONTROL NEEDLE FAILED: a row with no raw_body, no id line and no "+
			"matching block was NOT selected for synthesis (selected=%v) — the "+
			"instrument cannot see a genuinely sourceless row, so every negative "+
			"assertion in this file is a false null.", got)
	}
}

// SIGNAL 1 — items.raw_body.
//
// TMX-050 IS THIS CASE ON THE LIVE CORPUS (measured 2026-09-01): category F,
// code_ordinal 1, current_location Fixed, raw_body 3675 bytes, and NO `### F1.`
// block in either tracker — its only Fixed.md mention is prose inside another
// item's block ("Migrated from Issues.md F1 (TMX-050)", Fixed.md:167), which is
// not a `**TMX-ID:**` line and so does not set the id signal. Signals 2 and 3
// are both silent for it; the raw_body gate is the ONLY thing standing between
// that row and a duplicated block. The fixture mirrors it exactly.
func TestSourcelessItems_RawBodyGateSuppressesAnItemWithCapturedText(t *testing.T) {
	blob := "# Fixed\n\n### A1. an unrelated block\n\n**TMX-ID:** TMX-900\n\n" +
		"Migrated from Issues.md F1 (TMX-050).\n"
	it := mkItem("TMX-050", "F", 1, "the item's own captured verbatim body text")

	got := sourcelessIDs([]*Item{it}, blob)
	if got[it.ATMID] {
		t.Fatalf("%s was selected for synthesis despite carrying a non-empty "+
			"raw_body — db→md would APPEND a second block for a row that already "+
			"has captured source text, duplicating it into the tracker.", it.ATMID)
	}
}

// SIGNAL 2 — a `**TMX-ID:** <id>` line anywhere in either blob.
//
// Isolated by putting the item's id line under a block whose CODE is not one
// this item would ever claim (`### A1.` vs the item's Z0 / Z902 forms), so
// blockClaimedBy is false for both ordinal forms and only the id-line signal
// can suppress the row.
func TestSourcelessItems_IDLineSignalSuppressesAnItemWithABlockElsewhere(t *testing.T) {
	blob := "# Issues\n\n### A1. a block under a code this item never claims\n\n" +
		"**TMX-ID:** TMX-902\n\nbody.\n"
	it := mkItem("TMX-902", "Z", 0, "")

	got := sourcelessIDs([]*Item{it}, blob)
	if got[it.ATMID] {
		t.Fatalf("%s was selected for synthesis even though a `**%s:** %s` line "+
			"already exists in a blob — the row IS present in the document and "+
			"synthesising it again duplicates it.", it.ATMID, TicketLabel, it.ATMID)
	}
}

// SIGNAL 3a — a block under a matching code that declares NO id (`owners[""]`).
//
// A block asserting no ownership is conservatively treated as possibly-this-
// item's, so the pass declines to duplicate (§11.4.201(1)). This is the shape
// the operator corpus is FULL of: it predates the `**TMX-ID:**` line
// convention, so most real blocks declare no id at all. Deleting the
// `owners[""]` clause was measured to leave the suite GREEN before this test.
func TestSourcelessItems_UnownedBlockUnderMatchingCodeSuppresses(t *testing.T) {
	blob := "# Issues\n\n### B3. a block that declares no ticket id\n\n" +
		"**Type:** Bug\n\nbody with no id line.\n"
	it := mkItem("TMX-903", "B", 3, "")

	got := sourcelessIDs([]*Item{it}, blob)
	if got[it.ATMID] {
		t.Fatalf("%s was selected for synthesis even though `### B3.` — the block "+
			"its stored (category, code_ordinal) names — already exists. That "+
			"block declares no owner, so it may well BE this item's block; "+
			"synthesising a second one duplicates it.", it.ATMID)
	}
}

// SIGNAL 3b — the STORED CodeOrdinal form of the code.
//
// The pass checks the code BOTH as `<cat><CodeOrdinal>` and as writeItemBlock's
// `<cat><atmOrdinal(ATMID)>` fallback, because the two disagree for legacy rows.
// Here only the STORED form matches (B3 exists, B904 does not), so dropping the
// stored-form check flips the verdict.
func TestSourcelessItems_StoredOrdinalFormOfTheCodeIsChecked(t *testing.T) {
	blob := "# Issues\n\n### B3. block at the item's STORED code_ordinal\n\n" +
		"body with no id line.\n"
	it := mkItem("TMX-904", "B", 3, "")

	got := sourcelessIDs([]*Item{it}, blob)
	if got[it.ATMID] {
		t.Fatalf("%s was selected for synthesis: its STORED code_ordinal names "+
			"`### B3.`, which exists. Only the stored form matches here "+
			"(atmOrdinal would be B904), so the stored-form check is the one "+
			"signal holding this case.", it.ATMID)
	}
}

// SIGNAL 3c — the atmOrdinal FALLBACK form of the code.
//
// The mirror of 3b: only the fallback form matches (C905 exists, C0 does not),
// which is exactly the shape an `add`-created row takes — CodeOrdinal is the 0
// sentinel and writeItemBlock renders the heading under the ATM ordinal.
func TestSourcelessItems_ATMOrdinalFallbackFormOfTheCodeIsChecked(t *testing.T) {
	blob := "# Issues\n\n### C905. block at the item's atmOrdinal FALLBACK code\n\n" +
		"body with no id line.\n"
	it := mkItem("TMX-905", "C", 0, "")

	got := sourcelessIDs([]*Item{it}, blob)
	if got[it.ATMID] {
		t.Fatalf("%s was selected for synthesis: it carries the code_ordinal 0 "+
			"sentinel, so writeItemBlock renders it under `### C905.` — which "+
			"already exists. Only the atmOrdinal fallback form matches here.",
			it.ATMID)
	}
}

// TestSourcelessItems_ForeignlyOwnedBlockDoesNotSuppress is the §11.4.201(1)
// false-positive guard for signal 3: a block under a matching code whose OWN
// `**TMX-ID:**` line names a DIFFERENT item is NOT this item's block, so it
// must NOT suppress. Heading codes are not unique (measured on the live corpus
// 2026-09-01: 93 code headings, 85 distinct), so a bare code match would wrongly hide a
// genuinely absent item behind someone else's block.
func TestSourcelessItems_ForeignlyOwnedBlockDoesNotSuppress(t *testing.T) {
	blob := "# Issues\n\n### D4. a block owned by a DIFFERENT item\n\n" +
		"**TMX-ID:** TMX-900\n\nbody.\n"
	it := mkItem("TMX-906", "D", 4, "")

	got := sourcelessIDs([]*Item{it}, blob)
	if !got[it.ATMID] {
		t.Fatalf("%s was NOT selected for synthesis, but the only `### D4.` block "+
			"declares TMX-900 — a foreign owner. Suppressing on a bare code match "+
			"hides a genuinely absent item behind someone else's block.", it.ATMID)
	}
}
