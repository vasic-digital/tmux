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
// `### G5 NAME-001 — ...` and `### A52. NAME-001 — ...` (the period form is the
// only one the item parser accepts; both appear in the tracked markdown).
var blockOwnerRE = regexp.MustCompile(`^###\s+([A-Z])(\d+)\.?\s`)

// idFieldRE matches the ticket-id field line inside a block body.
var idFieldRE = regexp.MustCompile(`\*\*` + "TMX" + `-ID:\*\*\s*(` + "TMX" + `-\d+)`)

// markdownBlockOwners returns, for one tracker file, the ticket id that each
// `<CAT><ORD>` block declares. Blocks with no id field are omitted (they assert
// no ownership).
func markdownBlockOwners(path string) (map[string]string, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	owners := map[string]string{}
	cur := ""
	for _, line := range strings.Split(string(raw), "\n") {
		if m := blockOwnerRE.FindStringSubmatch(line); m != nil {
			ord, _ := strconv.Atoi(m[2])
			cur = fmt.Sprintf("%s%d", m[1], ord)
			continue
		}
		if cur == "" {
			continue
		}
		if m := idFieldRE.FindStringSubmatch(line); m != nil {
			if _, seen := owners[cur]; !seen {
				owners[cur] = m[1]
			}
			cur = ""
		}
	}
	return owners, nil
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
	issuesOwners, err := markdownBlockOwners(issuesPath)
	if err != nil {
		return nil, 0, err
	}
	fixedOwners, err := markdownBlockOwners(fixedPath)
	if err != nil {
		return nil, 0, err
	}

	var findings []Finding
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
