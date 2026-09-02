// validate_identity.go — §11.4.54 cross-surface block-identity audit.
//
// THE DEFECT THIS EXISTS FOR (measured 2026-09-01):
//   DB row TMX-078 stored identity {category:A, code_ordinal:50, location:Fixed}
//   — i.e. "I am block `### A50` in Fixed.md". But Fixed.md's `### A50` block
//   carries `**TMX-ID:** TMX-057`, and TMX-078's real block is Issues.md's
//   `### G5 SANITIZE-NAME-001`. Two items, one block identity.
//
//   `validate` reported 0 findings throughout, because no check compared the
//   STORED identity against the MARKDOWN block it names. The collision was not
//   subtle — it was simply unobserved (§11.4.201: an absent check and a clean
//   artifact produce the same quiet zero).
//
// WHY THIS IS NOT A DB-INTERNAL CHECK: a duplicate (location,category,ordinal)
// scan does NOT catch it. TMX-078's triple is unique in the DB, because the item
// it collides with (TMX-057) carries the ordinal-0 sentinel that the narrow
// heading parser leaves behind. Only the markdown can settle who owns a block.
//
// FALSE-POSITIVE GUARDS (§11.4.201(1) — a wrong refusal is as bad as a missed
// defect; each of these was measured against the live corpus):
//   * ordinal 0 is the "unknown ordinal" sentinel, not a claim — skipped.
//   * a block the parser cannot find is the known heading-form gap, not an
//     identity collision — skipped, and counted separately so it stays visible.
//   * a block carrying no `**TMX-ID:**` line asserts no ownership — skipped.
//   * Obsolete rows legitimately share a block with the live row that superseded
//     them (measured: TMX-001 Obsolete and TMX-054 both correctly name Fixed B3,
//     recorded at Issues.md:162 as "migrated to Fixed.md §B3 as TMX-054") —
//     skipped, or a correct §11.4.90 supersession would be reported as a defect.

package main

import (
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
)

// blockOwnerRE matches a block heading in either heading form the corpus uses:
// `### G5 NAME-001 — ...` and `### A52. NAME-001 — ...`. Both are accepted by
// the item parser too (parser.go's headingRE); this audit deliberately stays
// LOOSER than that parser — it must be able to see a block the parser cannot,
// because "the parser did not reach this block" is one of the states it counts
// (the `unlocated` return) rather than a state it should be blind to.
var blockOwnerRE = regexp.MustCompile(`^###\s+([A-Z])(\d+)\.?\s`)

// idFieldRE matches the ticket-id field line inside a block body.
var idFieldRE = regexp.MustCompile(`\*\*` + "TMX" + `-ID:\*\*\s*(` + "TMX" + `-\d+)`)

// markdownBlockOwners returns, for one tracker file, the ticket id that each
// `<CAT><ORD>` block declares, PLUS every same-file block code declared by more
// than one block.
//
// TWO DEFECTS THIS CLOSES (both measured on the live corpus 2026-09-01):
//
//  1. First-declarer-wins used to DISCARD a second ownership assertion in
//     silence. Fixed.md carried 25 blocks declaring a `**TMX-ID:**` while the
//     map held 24 keys: `### A52.` heads two blocks (TMX-062 and the TMX-071
//     tombstone) and TMX-071's assertion vanished, so the audit could not
//     report a collision it had already thrown away. Duplicates are now
//     RETURNED so the caller can raise a finding.
//
//  2. The cursor was not reset by a `###` heading that carries no block code.
//     The corpus holds three such item-level headings written with a name
//     instead of a code; `cur` kept pointing at the PRECEDING block, so an id
//     line under one of them would be credited to the wrong block. Measured
//     impact was zero only because those headings declare no id — a live trap
//     the moment the missing id lines are backfilled.
//
// Blocks with no id field are omitted (they assert no ownership). Cross-FILE
// reuse of a code is NOT a duplicate: identity is (location, category,
// ordinal), and the live corpus legitimately reuses 8 codes across the two
// trackers (§11.4.201(1) — flagging those would refuse the real corpus).
func markdownBlockOwners(path string) (map[string]string, map[string][]string, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, nil, err
	}
	owners := map[string]string{}
	dups := map[string][]string{}
	cur := ""
	for _, line := range strings.Split(string(raw), "\n") {
		if m := blockOwnerRE.FindStringSubmatch(line); m != nil {
			ord, _ := strconv.Atoi(m[2])
			cur = fmt.Sprintf("%s%d", m[1], ord)
			continue
		}
		// ANY heading that is NOT a block code ends the current block's id-scan
		// window, so it cannot donate an id to the block above it.
		//
		// The level test is deliberately ANY heading (`anyHeadingRE`,
		// parser.go:102), not the literal `### ` prefix. The item parser closes
		// its own **TMX-ID:** window on any heading level (parser.go's
		// §11.4.6 GREEDY-BIND guard), so a reset keyed to `### ` left the two
		// components disagreeing about what closes an id-scan window: an id line
		// under an intervening `##` / `####` heading still bound to the PRECEDING
		// coded block here while the parser had already released it. Measured on
		// the live corpus 2026-09-01 (awk walk of Issues.md + Fixed.md comparing
		// the two reset rules): ZERO id lines change attribution, so this
		// alignment is behaviour-preserving on the real trackers today — it
		// closes a divergence, it does not repair a live mis-attribution.
		if anyHeadingRE.MatchString(line) {
			cur = ""
			continue
		}
		if cur == "" {
			continue
		}
		if m := idFieldRE.FindStringSubmatch(line); m != nil {
			if prev, seen := owners[cur]; !seen {
				owners[cur] = m[1]
			} else if len(dups[cur]) == 0 {
				dups[cur] = []string{prev, m[1]}
			} else {
				dups[cur] = append(dups[cur], m[1])
			}
			cur = ""
		}
	}
	return owners, dups, nil
}

// ValidateBlockIdentity reports every item whose stored (location, category,
// code_ordinal) names a markdown block that a DIFFERENT ticket id declares.
// The second return value is the count of items skipped because the parser
// could not locate their block — an honest gap, reported, never silently zeroed.
func ValidateBlockIdentity(db *DB, issuesPath, fixedPath string) ([]Finding, int, error) {
	items, err := db.AllItems()
	if err != nil {
		return nil, 0, err
	}
	issuesOwners, issuesDups, err := markdownBlockOwners(issuesPath)
	if err != nil {
		return nil, 0, err
	}
	fixedOwners, fixedDups, err := markdownBlockOwners(fixedPath)
	if err != nil {
		return nil, 0, err
	}

	var findings []Finding

	// A SAME-FILE duplicate block code whose blocks both declare an id is a
	// genuine §11.4.19 one-item-one-block violation: two blocks assert
	// ownership of one identity and the audit can only carry one of them.
	for _, d := range []struct {
		file string
		dups map[string][]string
	}{{"Issues.md", issuesDups}, {"Fixed.md", fixedDups}} {
		for code, ids := range d.dups {
			findings = append(findings, Finding{
				Section: "§11.4.54", ATMID: ids[0],
				Detail: fmt.Sprintf(
					"block %s in %s is declared by %d blocks (%s) — one block code, "+
						"several owners; only the first is carried by the audit",
					code, d.file, len(ids), strings.Join(ids, ", ")),
			})
		}
	}
	unlocated := 0
	for _, it := range items {
		if it.CodeOrdinal <= 0 {
			continue // ordinal sentinel — asserts no block claim
		}
		if strings.HasPrefix(it.Status, "Obsolete") {
			continue // a superseded record may share its successor's block
		}
		owners := issuesOwners
		file := "Issues.md"
		if it.CurrentLocation == "Fixed" {
			owners, file = fixedOwners, "Fixed.md"
		}
		code := fmt.Sprintf("%s%d", it.Category, it.CodeOrdinal)
		owner, found := owners[code]
		if !found {
			unlocated++
			continue // known heading-form gap, not an identity collision
		}
		if owner != it.ATMID {
			findings = append(findings, Finding{
				Section: "§11.4.54", ATMID: it.ATMID,
				Detail: fmt.Sprintf(
					"stored identity names block %s in %s, but that block declares %s — two items claim one block",
					code, file, owner),
			})
		}
	}
	return findings, unlocated, nil
}
