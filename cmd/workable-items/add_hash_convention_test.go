// add_hash_convention_test.go — §11.4.115 RED-first guard for TMX-093
// (Issues.md §A5, ADD-HASH-CONVENTION-SPLIT-001).
//
// THE DEFECT. `computeHeadingHash(category, code, title)` (model.go:154) hashes
// `lower(category)|lower(code)|normalized(title)`. Its SECOND argument is the
// markdown BLOCK CODE — parser.go:186 builds it as `code := category + ordinal`
// and passes it at parser.go:201, and the upsert fixture at
// upsert_identity_test.go:41 independently uses the same `cat+ordinal` form.
//
// `add.go:52` instead passed the TICKET ID (`TMX-NNN`) in that slot. The two
// conventions never agree, so a row created by `add` carried a heading_hash
// that the parser could not reproduce from the very markdown block the writer
// emits for that same row (sync_db_to_md.go:195-201 renders the heading as
// `### <Category><ordinal>.`, falling back to atmOrdinal(ATMID) when
// CodeOrdinal is the 0 sentinel). The row therefore could not bind to its own
// block by hash; it survived only via the ExplicitATM rebind fallback at
// sync_md_to_db.go:247-256, which REPLACES the row and refreshes the hash —
// masking the split and writing a spurious identity-rebind history event.
//
// THE ORACLE (§11.4.245 — DERIVED, structurally independent of the code under
// test). The test does NOT re-implement the hash convention. It drives the two
// REAL producers end-to-end — `AddItem` writes the row, `SyncDBToMD` renders
// the markdown, `ParseFile` reads it back — and compares the two hashes. A
// tautological "assert add uses cat+ordinal" test would pass on any convention
// both sides happened to share, including a wrong one.
//
// POLARITY SWITCH (§11.4.115). Env RED_MODE, default "1":
//
//	RED_MODE=1 — assert the DEFECT IS PRESENT (hashes diverge). PASSES on the
//	             pre-fix artifact, capturing the divergent hashes as positive
//	             defect evidence. A FAIL here pre-fix means the RED did not
//	             reproduce — a blind test, itself a finding (§11.4.6).
//	RED_MODE=0 — assert the DEFECT IS ABSENT (hashes agree). FAILS (exit != 0)
//	             on the pre-fix artifact — the RED baseline; PASSES post-fix as
//	             the standing regression guard.

package main

import (
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

// addHashConventionProbe runs the real add -> render -> parse chain and returns
// the heading_hash `add` stored and the heading_hash the parser derives from
// the block the writer emits for that same row.
//
// MULTI-FACTOR COVERAGE (§11.4.194(1)). The block code `add` must reproduce is
// a PRODUCT of two factors — the CATEGORY letter and the category-local
// ORDINAL. A probe that only ever adds the FIRST item to a fresh database
// pins the ordinal at 1 for every case, so a mutation replacing
// `atmOrdinal(atm)` with the literal `1` survives: the test verifies the
// category factor and merely ASSUMES the ordinal factor. `nextATMOrdinal`
// therefore seeds meta.next_atm_id, so the caller can drive an ordinal that is
// NOT 1 and the ordinal factor is independently verified. (Seeding the counter
// is also the realistic shape — the live DB's counter stands at 96, never 1.)
func addHashConventionProbe(t *testing.T, category string, nextATMOrdinal int) (stored, parsed, heading string) {
	t.Helper()

	dir := t.TempDir()
	db, err := OpenDB(filepath.Join(dir, "add_hash_convention.db"))
	if err != nil {
		t.Fatalf("OpenDB: %v", err)
	}
	defer db.Close()

	// Drive the id allocator to the requested ordinal. AddItem calls
	// db.NextATMID(), which reads this meta key (db.go:120), so the item it
	// creates is TMX-<nextATMOrdinal> and the block code the writer emits is
	// <category><nextATMOrdinal>.
	if err := db.MetaSet("next_atm_id", strconv.Itoa(nextATMOrdinal)); err != nil {
		t.Fatalf("seed next_atm_id: %v", err)
	}

	it, err := AddItem(db, AddItemParams{
		Type:     TypeBug,
		Severity: "High",
		Title:    "heading hash convention split between add and parser",
		Description: "A fixture item whose description clears the §11.4.91 " +
			"clarity floor so AddItem accepts it.",
		Category: category,
	})
	if err != nil {
		t.Fatalf("AddItem: %v", err)
	}
	// The seed must actually have taken, or the "non-1 ordinal" case silently
	// degenerates back into the ordinal-1 case the mutation survives
	// (§11.4.201(6): an unverified precondition turns a real assertion into a
	// false null).
	if got := atmOrdinal(it.ATMID); got != nextATMOrdinal {
		t.Fatalf("seeded next_atm_id=%d but AddItem allocated %s (ordinal %d) — "+
			"the ordinal factor is not under test", nextATMOrdinal, it.ATMID, got)
	}

	// Render through the REAL writer. document_sources is empty for a fresh
	// DB, so SyncDBToMD takes the structural-generation path.
	outDir := filepath.Join(dir, "out")
	if err := SyncDBToMD(db, outDir); err != nil {
		t.Fatalf("SyncDBToMD: %v", err)
	}

	// Read the block back through the REAL parser.
	items, err := ParseFile(filepath.Join(outDir, "Issues.md"), LocationIssues)
	if err != nil {
		t.Fatalf("ParseFile: %v", err)
	}
	if len(items) != 1 {
		t.Fatalf("want exactly 1 parsed block, got %d — the writer/parser pair "+
			"did not round-trip the added item at all", len(items))
	}
	pi := items[0]
	// Guard against comparing the wrong block (§11.4.201 control): the parsed
	// block must declare the id `add` allocated.
	if pi.ExplicitATM != it.ATMID {
		t.Fatalf("parsed block declares %q, want %q — comparing the wrong block",
			pi.ExplicitATM, it.ATMID)
	}
	return it.HeadingHash, pi.Item.HeadingHash, pi.RawHeading
}

func TestAddHeadingHashUsesParserConvention(t *testing.T) {
	// Default 0 = standing GREEN regression guard, matching this repo's
	// post-fix convention (scripts/tests/71_root_free_zig_build.sh:62,
	// 73_build_native_localdeps_wiring.sh) and this package's existing Go
	// tests (reconcile_identity_test.go:29). §11.4.115's default-1 applies
	// while the defect is LIVE; once the fix lands, leaving the default at 1
	// would make the package suite permanently FAIL — a §11.4.1 FAIL-bluff.
	// RED_MODE=1 stays available to re-reproduce the defect on a broken
	// artifact, which is how the RED evidence in the closure record was taken.
	redMode := os.Getenv("RED_MODE")
	if redMode == "" {
		redMode = "0"
	}

	// One case per FACTOR of the block code (§11.4.194(1)). `ordinal 1` alone
	// cannot distinguish `atmOrdinal(atm)` from the constant 1; the non-1 cases
	// can, and the two categories keep the category factor covered as well.
	cases := []struct {
		name     string
		category string
		nextID   int
	}{
		{"category A, ordinal 1 (first item in a fresh DB)", "A", 1},
		{"category A, ordinal 7 (counter already advanced)", "A", 7},
		{"category G, ordinal 42 (both factors non-default)", "G", 42},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			stored, parsed, heading := addHashConventionProbe(t, tc.category, tc.nextID)
			diverged := stored != parsed

			switch redMode {
			case "1":
				if !diverged {
					t.Fatalf("RED_MODE=1: the defect did NOT reproduce — add and parser "+
						"already agree (hash=%s). A RED that cannot fail on the broken "+
						"artifact is a blind test (§11.4.115 honest boundary).", stored)
				}
				t.Logf("RED_MODE=1 DEFECT REPRODUCED (§11.4.115 defect-present evidence)\n"+
					"  emitted heading : %s\n"+
					"  add.go  stored  : %s\n"+
					"  parser derives  : %s\n"+
					"  => the row cannot bind to its own block by heading_hash.",
					heading, stored, parsed)
			case "0":
				if diverged {
					t.Fatalf("RED_MODE=0: heading_hash convention split is PRESENT — a row "+
						"created by `add` cannot bind to its own markdown block by hash.\n"+
						"  emitted heading : %s\n"+
						"  add.go  stored  : %s\n"+
						"  parser derives  : %s\n"+
						"  add.go MUST hash the BLOCK CODE the writer emits "+
						"(Category + atmOrdinal(ATMID) — BOTH factors, neither assumed), "+
						"not the ticket id and not a constant ordinal.",
						heading, stored, parsed)
				}
			default:
				t.Fatalf("RED_MODE=%q is not a recognised polarity (want \"1\" or \"0\")", redMode)
			}
		})
	}
}
