// guard_coverage_test.go — closes the gaps an independent reviewer's own
// mutations found in the duplicate guard and the identity-rebind seam.
//
// Each test here exists because a mutation SURVIVED the suite, or a probe
// demonstrated a live data-loss path that no test asserted against. A guard no
// test can make fail is unvalidated instrumentation (§11.4.115(F)) — it mints
// no verdicts, however correct its code happens to be.

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// N1 — the byHash half of the duplicate guard was unpinned.
//
// Every prior duplicate fixture declared a `**TMX-ID:**`, so only the byATM key
// was exercised: disabling the byHash key left the whole suite green. That is
// the untested half guarding the COMMON case — 63 of 93 live corpus blocks
// carry no TMX-ID line, so an id-less duplicate is the likelier shape, and
// under the surviving mutant it syncs to ONE row whose content is decided by
// read order while the other block's body is discarded.
func TestSyncMDToDB_RefusesIdLessDuplicateAcrossTrackers(t *testing.T) {
	tmp := t.TempDir()
	iss := filepath.Join(tmp, "Issues.md")
	fix := filepath.Join(tmp, "Fixed.md")

	// Same category, ordinal and title in both files => same heading identity.
	// DIVERGENT bodies, so a silent collapse provably loses text.
	mustWrite(t, iss, `# Issues

### G9 NO-ID-001 — a block that declares no ticket id

**Type:** Feature
**Status:** Queued

The OPEN body. This sentence exists only in the Issues.md copy of the block.
`)
	mustWrite(t, fix, `# Fixed

### G9 NO-ID-001 — a block that declares no ticket id

**Status:** Implemented (→ Fixed.md)
**Type:** Feature

The CLOSED body. This sentence exists only in the Fixed.md copy of the block.
`)
	db, err := OpenDB(filepath.Join(tmp, "noid.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	if _, err := SyncMDToDB(db, iss, fix); err == nil {
		items, _ := db.AllItems()
		body := ""
		if len(items) == 1 {
			body = items[0].RawBody
		}
		lostOpen := !strings.Contains(body, "OPEN body")
		lostClosed := !strings.Contains(body, "CLOSED body")
		t.Fatalf("RED: an id-less block duplicated across both trackers was accepted — "+
			"%d row(s) survived; open-body lost=%v closed-body lost=%v. "+
			"With no TMX-ID the byATM key cannot see this pair; only the "+
			"heading-identity key can", len(items), lostOpen, lostClosed)
	} else if !strings.Contains(err.Error(), "identical heading identity") {
		t.Fatalf("the refusal must name the heading-identity collision so it is "+
			"actionable without a ticket id to quote, got: %v", err)
	}
}

// N3 — a refusal that has already written is not fail-closed.
//
// document_sources is the blob db→md replays from. Persisting it BEFORE the
// guard meant a refused sync mutated the git-tracked SSoT: the refused corpus
// landed in document_sources while the structured rows stayed at their prior
// state, so the DB was left internally inconsistent by the very refusal that
// cites §11.4.252. A refusal must change nothing.
func TestSyncMDToDB_RefusalLeavesDocumentSourcesUntouched(t *testing.T) {
	tmp := t.TempDir()
	iss := filepath.Join(tmp, "Issues.md")
	fix := filepath.Join(tmp, "Fixed.md")
	db, err := OpenDB(filepath.Join(tmp, "refuse.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	// A known-good prior state the refusal must not disturb.
	const sentinel = "PRIOR-GOOD-BLOB-DO-NOT-OVERWRITE"
	if err := db.PutDocumentSource(LocationIssues, sentinel); err != nil {
		t.Fatal(err)
	}
	if err := db.PutDocumentSource(LocationFixed, sentinel); err != nil {
		t.Fatal(err)
	}

	// A corpus the guard must refuse.
	iss2, fix2 := writeDupFixtures(t)
	dupIss, _ := os.ReadFile(iss2)
	dupFix, _ := os.ReadFile(fix2)
	mustWrite(t, iss, string(dupIss))
	mustWrite(t, fix, string(dupFix))

	if _, err := SyncMDToDB(db, iss, fix); err == nil {
		t.Fatal("precondition: this corpus must be refused")
	}

	for _, loc := range []string{LocationIssues, LocationFixed} {
		got, gerr := db.GetDocumentSource(loc)
		if gerr != nil {
			t.Fatalf("read document_source %s: %v", loc, gerr)
		}
		if got != sentinel {
			t.Errorf("RED: the REFUSED sync overwrote document_sources[%s] — "+
				"the refused corpus is now the blob db→md would replay from, "+
				"while the structured rows never moved. A fail-closed refusal "+
				"must be side-effect-free.\n  want: %q\n  got:  %.80q",
				loc, sentinel, got)
		}
	}
	if items, _ := db.AllItems(); len(items) != 0 {
		t.Errorf("RED: the refused sync also wrote %d item row(s)", len(items))
	}
}

// N2 — a rebind that replaces a row must leave machine evidence.
//
// The atm_id fallback binds a block to an existing row by its declared
// **TMX-ID:** when the block's heading identity is not in the DB. That is
// correct for a renumber (A50 -> A55), and it is ALSO what a foreign block
// typo-declaring another item's id does. The two are indistinguishable from the
// corpus alone, so the rebind is allowed — but it must not be SILENT: before
// this, the row's category, ordinal, title and body were replaced wholesale,
// `validate` reported 0 findings (the result is self-consistent), and
// item_history recorded nothing at all.
func TestSyncMDToDB_IdentityRebindIsRecordedInHistory(t *testing.T) {
	tmp := t.TempDir()
	iss := filepath.Join(tmp, "Issues.md")
	fix := filepath.Join(tmp, "Fixed.md")
	db, err := OpenDB(filepath.Join(tmp, "rebind.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	// Sync 1: the victim block establishes the row.
	mustWrite(t, iss, `# Issues

### A1 VICTIM-001 — the original owner of this ticket id

**TMX-ID:** TMX-001
**Type:** Bug
**Status:** Queued

The victim body. Long enough to serve as this item's description.
`)
	mustWrite(t, fix, "# Fixed\n")
	if _, err := SyncMDToDB(db, iss, fix); err != nil {
		t.Fatalf("seed sync: %v", err)
	}
	before, _ := db.GetItem("TMX-001")
	if before == nil || !strings.Contains(before.Title, "VICTIM") {
		t.Fatalf("precondition: TMX-001 must hold the victim item, got %+v", before)
	}
	histBefore, _ := db.HistoryFor("TMX-001")

	// Sync 2: the victim's block is gone; an unrelated block declares its id.
	mustWrite(t, iss, `# Issues

### B7 NEWWORK-001 — unrelated work that typo-declares the victim's id

**TMX-ID:** TMX-001
**Type:** Task
**Status:** Queued

Entirely different body. Long enough to serve as this item's description.
`)
	res, err := SyncMDToDB(db, iss, fix)
	if err != nil {
		t.Fatalf("second sync: %v", err)
	}

	after, _ := db.GetItem("TMX-001")
	if after == nil {
		t.Fatal("TMX-001 vanished")
	}
	// The overwrite is deterministic here, so assert it UNCONDITIONALLY. An
	// earlier draft guarded these checks behind `strings.Contains(title,
	// "VICTIM")` — true only when the rebind had NOT happened — so the whole
	// block was skipped on every run and the test passed vacuously even with
	// the recording removed. A conditional assertion is not an assertion.
	if strings.Contains(after.Title, "VICTIM") {
		t.Fatalf("precondition: the rebind did not occur (row still holds %q); "+
			"this test asserts how a rebind is RECORDED, so it needs one to happen",
			after.Title)
	}
	{
		if res.IdentityRebinds == 0 {
			t.Errorf("RED: row TMX-001 was rebound from %q to %q but the sync "+
				"result reported 0 identity rebinds — the rewrite is invisible "+
				"at the moment it happens", before.Title, after.Title)
		}
		histAfter, herr := db.HistoryFor("TMX-001")
		if herr != nil {
			t.Fatal(herr)
		}
		if len(histAfter) <= len(histBefore) {
			t.Fatalf("RED: row TMX-001 was rebound from %q to %q with NO new "+
				"item_history row (%d before, %d after) — a full identity+content "+
				"rewrite left zero machine evidence, so `validate` cannot tell it "+
				"from a row that was always this way (§11.4.226)",
				before.Title, after.Title, len(histBefore), len(histAfter))
		}
		newest := histAfter[len(histAfter)-1]
		for _, want := range []string{"identity rebind", "VICTIM"} {
			if !strings.Contains(newest.Reason, want) {
				t.Errorf("the recorded reason must name what was replaced "+
					"(missing %q), got: %q", want, newest.Reason)
			}
		}
		// RebindDetails is what the CLI prints, so it is the operator's only
		// live view of the rewrite — pin its content, not just the counter.
		if len(res.RebindDetails) != 1 {
			t.Fatalf("expected 1 rebind detail line, got %v", res.RebindDetails)
		}
		for _, want := range []string{"TMX-001", "VICTIM", "NEWWORK"} {
			if !strings.Contains(res.RebindDetails[0], want) {
				t.Errorf("the printed rebind line must name the id and BOTH the "+
					"replaced and replacing block (missing %q), got: %q",
					want, res.RebindDetails[0])
			}
		}
	}
}

// N4 — the two identity signals can disagree; pin BOTH what wins and what is
// recorded.
//
// MEASURED (probe, 2026-09-01): swapping the sync-layer resolution order does
// NOT change any persisted row, because UpsertItem re-resolves by heading_hash
// itself and that lookup is the real enforcement point. What the swap DOES
// change is the audit trail: it records an identity rebind for a block that was
// never rebound. A fabricated evidence row is its own defect (§11.4.6) — it
// makes a clean sync look like a row-replacing rewrite — so the invariant this
// test pins is "a rebind is recorded ONLY when one occurred", which is the part
// the order genuinely controls. An earlier draft asserted only the row outcome,
// which is identical under both orders, and therefore proved nothing.
func TestSyncMDToDB_HeadingHashWinsAndNoSpuriousRebindIsRecorded(t *testing.T) {
	tmp := t.TempDir()
	iss := filepath.Join(tmp, "Issues.md")
	fix := filepath.Join(tmp, "Fixed.md")
	db, err := OpenDB(filepath.Join(tmp, "prec.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	// Seed two distinct rows: TMX-001 (block A1) and TMX-002 (block C3).
	mustWrite(t, iss, `# Issues

### A1 FIRST-001 — the row reached by declared id

**TMX-ID:** TMX-001
**Type:** Bug
**Status:** Queued

First body. Long enough to serve as this item's description.

### C3 SECOND-001 — the row reached by heading identity

**TMX-ID:** TMX-002
**Type:** Bug
**Status:** Queued

Second body. Long enough to serve as this item's description.
`)
	mustWrite(t, fix, "# Fixed\n")
	if _, err := SyncMDToDB(db, iss, fix); err != nil {
		t.Fatalf("seed sync: %v", err)
	}

	// Block C3 keeps its heading (still bound to TMX-002) but now declares
	// TMX-001. The two signals point at different rows.
	mustWrite(t, iss, `# Issues

### C3 SECOND-001 — the row reached by heading identity

**TMX-ID:** TMX-001
**Type:** Bug
**Status:** In progress

Second body, now edited. Long enough to serve as this item's description.
`)
	res, err := SyncMDToDB(db, iss, fix)
	if err != nil {
		t.Fatalf("conflict sync: %v", err)
	}

	// The block's OWN heading identity wins: its edit lands on TMX-002 and the
	// row it merely names by id is untouched.
	one, _ := db.GetItem("TMX-001")
	two, _ := db.GetItem("TMX-002")
	if one == nil || !strings.Contains(one.Title, "FIRST") {
		t.Errorf("heading identity must win: TMX-001 (named only by the declared "+
			"id) must be untouched, got %+v", one)
	}
	if two == nil || !strings.Contains(two.Status, "In progress") {
		t.Errorf("heading identity must win: TMX-002 (the block's own identity) "+
			"must receive the edit, got %+v", two)
	}

	// And nothing was rebound, so nothing may be RECORDED as rebound.
	if res.IdentityRebinds != 0 {
		t.Errorf("RED: %d identity rebind(s) recorded for a sync that rebound "+
			"nothing (%v) — a fabricated audit row makes a clean sync read as a "+
			"row-replacing rewrite", res.IdentityRebinds, res.RebindDetails)
	}
	for _, h := range mustHistory(t, db, "TMX-001") {
		if strings.Contains(h.Reason, "identity rebind") {
			t.Errorf("RED: TMX-001 carries an identity-rebind history row but was "+
				"never rebound: %q", h.Reason)
		}
	}
}

func mustHistory(t *testing.T, db *DB, atm string) []*ItemHistoryEvent {
	t.Helper()
	h, err := db.HistoryFor(atm)
	if err != nil {
		t.Fatal(err)
	}
	return h
}

// N5 — a failed lookup is not an absent row.
//
// lookupByHeadingHash matched on the error TEXT ("no rows") and fell through to
// `("", nil)` for everything else, so a real DB error was reported to the caller
// as a clean hash MISS. The caller then takes the allocate-a-new-id path and
// mints a duplicate row for an item that already exists — the §11.4.201(6)
// false-null, where a broken instrument and a genuinely-empty result return the
// same quiet zero.
func TestLookupByHeadingHash_ReportsRealErrorsInsteadOfReportingAbsent(t *testing.T) {
	db, err := OpenDB(filepath.Join(t.TempDir(), "err.db"))
	if err != nil {
		t.Fatal(err)
	}
	// Control: a genuinely-absent hash on a live DB is "" with no error.
	if got, err := lookupByHeadingHash(db, "hash-that-does-not-exist"); err != nil || got != "" {
		t.Fatalf("absent hash must be (\"\", nil), got (%q, %v)", got, err)
	}
	defer db.Close()
	// Force a REAL query error (not ErrNoRows) by removing the table the lookup
	// reads. Closing the DB instead would panic on a nil handle rather than
	// exercise the error path this test is about.
	if _, derr := db.conn.Exec("DROP TABLE items"); derr != nil {
		t.Fatal(derr)
	}
	got, err := lookupByHeadingHash(db, "any-hash")
	if err == nil {
		t.Fatalf("RED: a failed query returned (%q, nil) — indistinguishable from "+
			"a genuinely absent row, so the caller allocates a fresh id and mints "+
			"a duplicate for an item that already exists", got)
	}
}

// R3-1 — an ordinal-only renumber must not be eaten by the "unchanged" gate.
//
// itemContentEqual compared Category but NOT CodeOrdinal, and not HeadingHash.
// So renumbering a block's ordinal while leaving its body byte-identical — the
// standard shape of a renumber now that blocks carry their own **TMX-ID:** line
// — resolved to the right row by declared id, then compared "equal" and took
// the UnchangedItems path: the upsert was SKIPPED, so the row kept the OLD
// ordinal and the OLD (now stale) heading hash, and `rebindFrom` was discarded
// with no history row and no counter.
//
// Two failures at once. The identity desync is PERMANENT (§11.4.108): every
// later sync misses the hash again, resolves by id again, compares "equal"
// again, and reports "unchanged" forever, so the repair can never land. And the
// audit trail this round exists to guarantee (§11.4.226) is defeated on exactly
// this path — a rebind happened at the resolution layer and left no evidence.
func TestSyncMDToDB_OrdinalOnlyRenumberIsAppliedAndRecorded(t *testing.T) {
	tmp := t.TempDir()
	iss := filepath.Join(tmp, "Issues.md")
	fix := filepath.Join(tmp, "Fixed.md")
	db, err := OpenDB(filepath.Join(tmp, "renum.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	const body = `

**TMX-ID:** TMX-010
**Type:** Bug
**Status:** Queued

A body that stays byte-identical across the renumber, so the only difference
between the two syncs is the block ordinal itself.
`
	mustWrite(t, iss, "# Issues\n\n### A50. Stable title"+body)
	mustWrite(t, fix, "# Fixed\n")
	if _, err := SyncMDToDB(db, iss, fix); err != nil {
		t.Fatalf("seed sync: %v", err)
	}
	before, _ := db.GetItem("TMX-010")
	if before == nil || before.CodeOrdinal != 50 {
		t.Fatalf("precondition: TMX-010 must be seeded at ordinal 50, got %+v", before)
	}

	// Renumber the heading ONLY. Body byte-identical.
	mustWrite(t, iss, "# Issues\n\n### A55. Stable title"+body)
	res, err := SyncMDToDB(db, iss, fix)
	if err != nil {
		t.Fatalf("renumber sync: %v", err)
	}

	after, _ := db.GetItem("TMX-010")
	if after == nil {
		t.Fatal("TMX-010 vanished")
	}
	if after.CodeOrdinal != 55 {
		t.Errorf("RED: the row still claims ordinal %d after the block was "+
			"renumbered to A55 — the rebind was resolved and then discarded by "+
			"the unchanged gate, so SOURCE and SSoT disagree permanently "+
			"(unchanged=%d updated=%d)", after.CodeOrdinal, res.UnchangedItems, res.Updated)
	}
	if after.HeadingHash == before.HeadingHash {
		t.Errorf("RED: the row kept its stale heading_hash, so every future sync " +
			"re-misses the hash, re-resolves by id, and re-reports \"unchanged\" — " +
			"the desync can never repair itself")
	}
	if res.IdentityRebinds == 0 {
		t.Errorf("RED: the renumber rebound the row but reported 0 identity " +
			"rebinds — the §11.4.226 audit trail is defeated on this path")
	}
	found := false
	for _, h := range mustHistory(t, db, "TMX-010") {
		if strings.Contains(h.Reason, "identity rebind") {
			found = true
		}
	}
	if !found {
		t.Errorf("RED: no identity-rebind history row was written for the renumber")
	}
}

// R3-1, second half — isolates the HeadingHash clause.
//
// The renumber fixture above is over-determined: the ordinal is an INPUT to the
// hash, so comparing either field alone catches it and neither clause is pinned
// on its own. This case isolates the hash — the block is completely unchanged,
// but the row's stored hash has drifted from the one its own heading computes
// (a row written before a parser change, or by an earlier buggy sync). Only the
// HeadingHash comparison can see that, and seeing it is what lets the row
// self-heal instead of missing the hash on every future sync forever.
func TestSyncMDToDB_StaleStoredHashSelfHeals(t *testing.T) {
	tmp := t.TempDir()
	iss := filepath.Join(tmp, "Issues.md")
	fix := filepath.Join(tmp, "Fixed.md")
	db, err := OpenDB(filepath.Join(tmp, "heal.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	const corpus = `# Issues

### A50. Stable title

**TMX-ID:** TMX-010
**Type:** Bug
**Status:** Queued

An unchanging body: this sync differs from the last only in the stored hash.
`
	mustWrite(t, iss, corpus)
	mustWrite(t, fix, "# Fixed\n")
	if _, err := SyncMDToDB(db, iss, fix); err != nil {
		t.Fatalf("seed sync: %v", err)
	}
	good, _ := db.GetItem("TMX-010")
	if good == nil || good.HeadingHash == "" {
		t.Fatalf("precondition: TMX-010 must carry a heading hash, got %+v", good)
	}

	// Drift the stored hash, leaving ordinal, title and body untouched.
	const stale = "stale-hash-from-an-earlier-parser"
	if _, err := db.conn.Exec("UPDATE items SET heading_hash = ? WHERE atm_id = ?", stale, "TMX-010"); err != nil {
		t.Fatal(err)
	}

	if _, err := SyncMDToDB(db, iss, fix); err != nil {
		t.Fatalf("resync: %v", err)
	}
	healed, _ := db.GetItem("TMX-010")
	if healed == nil {
		t.Fatal("TMX-010 vanished")
	}
	if healed.HeadingHash == stale {
		t.Errorf("RED: the row kept its drifted heading_hash %q instead of the "+
			"hash its own heading computes (%q) — the ordinal and body are equal, "+
			"so only the HeadingHash comparison can notice, and without it the "+
			"row misses the hash on every future sync forever",
			healed.HeadingHash, good.HeadingHash)
	}
}

// R3-1, third half — isolates the CodeOrdinal clause.
//
// The ordinal is an INPUT to computeHeadingHash, so on any HEADING change the
// hash comparison already catches it and this clause can never be the deciding
// one. It becomes load-bearing on DB-level drift: a row whose stored hash is
// correct but whose stored ordinal is not (a partial write, a hand-edit, a
// migration that touched one column). Without this clause that row compares
// "equal" forever and the wrong ordinal is what `validate` and the identity
// audit keep reading.
func TestSyncMDToDB_DriftedStoredOrdinalSelfHeals(t *testing.T) {
	tmp := t.TempDir()
	iss := filepath.Join(tmp, "Issues.md")
	fix := filepath.Join(tmp, "Fixed.md")
	db, err := OpenDB(filepath.Join(tmp, "ord.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	const corpus = `# Issues

### A50. Stable title

**TMX-ID:** TMX-010
**Type:** Bug
**Status:** Queued

An unchanging body: this sync differs from the last only in the stored ordinal.
`
	mustWrite(t, iss, corpus)
	mustWrite(t, fix, "# Fixed\n")
	if _, err := SyncMDToDB(db, iss, fix); err != nil {
		t.Fatalf("seed sync: %v", err)
	}

	// Drift ONLY the stored ordinal; the stored hash stays correct, so the hash
	// lookup still hits and the hash comparison sees nothing wrong.
	if _, err := db.conn.Exec("UPDATE items SET code_ordinal = 99 WHERE atm_id = ?", "TMX-010"); err != nil {
		t.Fatal(err)
	}

	if _, err := SyncMDToDB(db, iss, fix); err != nil {
		t.Fatalf("resync: %v", err)
	}
	healed, _ := db.GetItem("TMX-010")
	if healed == nil {
		t.Fatal("TMX-010 vanished")
	}
	if healed.CodeOrdinal != 50 {
		t.Errorf("RED: the row kept its drifted ordinal %d instead of the 50 its "+
			"own block declares — the stored hash still matches, so only the "+
			"CodeOrdinal comparison can notice this class of drift",
			healed.CodeOrdinal)
	}
}
