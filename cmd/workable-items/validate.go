// validate.go — schema + invariant auditor for the workable-items DB.
//
// Audits:
//   §11.4.15 — every status from closed-set (DB CHECK enforces; we re-verify).
//   §11.4.16 — every type from closed-set.
//   §11.4.21 — Operator-blocked items have operator_block_details row.
//   §11.4.33 — type-aware closure vocabulary alignment.
//   §11.4.54 — TMX-NNN sequence monotonic with no gaps, unique.
//   §11.4.90 — Obsolete items have obsolete_details row.
//   §11.4.91 — description ≥ 40 chars OR ≥ 6 words.
//
// Returns a slice of findings; len(findings) == 0 means valid.

package main

import (
	"fmt"
	"sort"
	"strconv"
	"strings"
)

// Finding describes a single validation violation.
type Finding struct {
	Section string // e.g. "§11.4.15"
	ATMID   string
	Detail  string
}

// String formats a Finding for human-readable output.
func (f Finding) String() string {
	if f.ATMID != "" {
		return fmt.Sprintf("[%s] %s: %s", f.Section, f.ATMID, f.Detail)
	}
	return fmt.Sprintf("[%s] %s", f.Section, f.Detail)
}

// Validate runs the full audit and returns all findings.
func Validate(db *DB) ([]Finding, error) {
	var findings []Finding
	items, err := db.AllItems()
	if err != nil {
		return nil, err
	}

	// §11.4.54 — collect TMX-NNN ordinals + check monotonic/unique.
	seenATM := map[int]string{}
	ordinals := []int{}
	for _, it := range items {
		ord := atmOrdinal(it.ATMID)
		if ord <= 0 {
			findings = append(findings, Finding{
				Section: "§11.4.54", ATMID: it.ATMID,
				Detail: TicketPrefix + "NNN id does not parse as positive integer ordinal",
			})
			continue
		}
		if prev, dup := seenATM[ord]; dup {
			findings = append(findings, Finding{
				Section: "§11.4.54", ATMID: it.ATMID,
				Detail: fmt.Sprintf(TicketPrefix+"%d duplicates id of %s", ord, prev),
			})
		}
		seenATM[ord] = it.ATMID
		ordinals = append(ordinals, ord)
	}
	sort.Ints(ordinals)
	// Allow starts at 1; no gaps once started.
	if len(ordinals) > 0 {
		expected := ordinals[0]
		for _, o := range ordinals {
			if o != expected {
				findings = append(findings, Finding{
					Section: "§11.4.54",
					Detail:  fmt.Sprintf("ticket sequence gap: expected "+TicketPrefix+"%03d, found "+TicketPrefix+"%03d", expected, o),
				})
				expected = o
			}
			expected++
		}
	}

	for _, it := range items {
		// §11.4.15
		if !isClosedSetStatus(it.Status) {
			findings = append(findings, Finding{
				Section: "§11.4.15", ATMID: it.ATMID,
				Detail: fmt.Sprintf("status %q is not in §11.4.15 closed-set", it.Status),
			})
		}
		// §11.4.16
		if !isClosedSetType(it.Type) {
			findings = append(findings, Finding{
				Section: "§11.4.16", ATMID: it.ATMID,
				Detail: fmt.Sprintf("type %q is not in §11.4.16 closed-set", it.Type),
			})
		}
		// §11.4.91 description floor.
		if !descriptionMeetsFloor(it.Description) {
			findings = append(findings, Finding{
				Section: "§11.4.91", ATMID: it.ATMID,
				Detail: fmt.Sprintf("description fails clarity floor (≥40 chars OR ≥6 words): %q",
					truncate(it.Description, 64)),
			})
		}
		// §11.4.33 closure vocabulary.
		if isClosureStatus(it.Status) {
			want := closureStatusForType(it.Type)
			if it.Status != want {
				findings = append(findings, Finding{
					Section: "§11.4.33", ATMID: it.ATMID,
					Detail: fmt.Sprintf("type %q expects closure status %q, got %q",
						it.Type, want, it.Status),
				})
			}
		}
		// §11.4.21 — Operator-blocked must have details row.
		if it.Status == StatusOperatorBlock {
			ob, err := db.OperatorBlockDetailsFor(it.ATMID)
			if err != nil {
				return findings, err
			}
			if ob == nil {
				findings = append(findings, Finding{
					Section: "§11.4.21", ATMID: it.ATMID,
					Detail: "Operator-blocked status requires operator_block_details row",
				})
			}
		}
		// §11.4.90 — Obsolete must have details row.
		if it.Status == StatusObsolete {
			od, err := db.ObsoleteDetailsFor(it.ATMID)
			if err != nil {
				return findings, err
			}
			if od == nil {
				findings = append(findings, Finding{
					Section: "§11.4.90", ATMID: it.ATMID,
					Detail: "Obsolete status requires obsolete_details row",
				})
			}
		}
	}

	return findings, nil
}

// atmOrdinal extracts the integer ordinal from a TMX-NNN id.
func atmOrdinal(atmID string) int {
	if !strings.HasPrefix(atmID, TicketPrefix) {
		return -1
	}
	n, err := strconv.Atoi(strings.TrimLeft(atmID[len(TicketPrefix):], "0"))
	if err != nil {
		// Handle the degenerate "TMX-000" case which trims to "".
		if strings.TrimLeft(atmID[len(TicketPrefix):], "0") == "" {
			return 0
		}
		return -1
	}
	return n
}

func descriptionMeetsFloor(d string) bool {
	if len(d) >= 40 {
		return true
	}
	if len(strings.Fields(d)) >= 6 {
		return true
	}
	return false
}

func isClosureStatus(s string) bool {
	switch s {
	case StatusFixed, StatusImplemented, StatusCompleted, StatusObsolete:
		return true
	}
	return false
}

// closureStatusForType returns the §11.4.33 type-aware closure value.
func closureStatusForType(t string) string {
	switch t {
	case TypeBug:
		return StatusFixed
	case TypeFeature:
		return StatusImplemented
	case TypeTask:
		return StatusCompleted
	}
	return StatusCompleted
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
