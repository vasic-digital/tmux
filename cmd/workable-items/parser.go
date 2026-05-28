// parser.go — Markdown → in-memory Item parser for tmux Issues.md/Fixed.md.
//
// The tmux corpus uses headings like:
//
//   ### B3. P5-M20 + P5-M21 paired-mutation ESCAPES — pre-existing v1.0.9 layer-4 gaps — `OPEN`
//   ### A36. `scripts/test_e2e.sh` T1.2 stale podman-machine prerequisite — `RESOLVED`
//   ### A23. §11.4.80 wiring — CodeGraph regular-update + sync (DEFERRED, honest tracking) — `Fixed — pending follow-up`
//
// Format breakdown:
//
//   - `### ` H3 marker
//   - `<CAT><N>.` category letter + ordinal (e.g. A36, B3)
//   - title (free text, may include backticks and em-dashes)
//   - trailing ` — \`<STATUS_HINT>\`` (sometimes; OPEN/RESOLVED/Fixed/etc.)
//
// Lines below the heading sometimes carry `**Status:** \`<value>\``. When
// present, that overrides the heading hint. Type is not currently tracked
// in the tmux corpus (project pre-dates §11.4.16) — parser defaults to Task.

package main

import (
	"bufio"
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
)

// headingRE matches H3 lines that introduce a workable item.
//
//	### <CAT><N>. <title>
//
// Captures: 1=category letter (A..Z), 2=numeric, 3=remainder (title + trailing
// status hint).
var headingRE = regexp.MustCompile(`^###\s+([A-Z])(\d+)\.\s+(.*)$`)

// trailingStatusRE captures the optional " — `STATUS`" suffix at the end of
// the heading remainder.
var trailingStatusRE = regexp.MustCompile(`\s+(?:—|--|-)\s*` + "`" + `([^` + "`" + `]+)` + "`" + `\s*$`)

// statusLineRE matches "**Status:** `value`" or "**Status:** value" within the
// 8-line window below the heading per §11.4.15.
var statusLineRE = regexp.MustCompile(`^\*\*Status:\*\*\s*` + "`?" + `([^` + "`" + `\n]+?)` + "`?" + `\s*(?:—|--|-|\.|$)`)

// typeLineRE matches "**Type:** `value`".
var typeLineRE = regexp.MustCompile(`^\*\*Type:\*\*\s*` + "`?" + `(Bug|Feature|Task)` + "`?" + `\s*$`)

// severityLineRE matches "**Severity:** HIGH" or similar.
var severityLineRE = regexp.MustCompile(`^\*\*Severity:\*\*\s*` + "`?" + `([A-Za-z0-9\-_]+)` + "`?")

// atmIDLineRE matches "**ATM-ID:** ATM-NNN" when present in regenerated output;
// during md-to-db we re-bind to the persisted ID rather than allocating a new one.
var atmIDLineRE = regexp.MustCompile(`^\*\*ATM-ID:\*\*\s*(ATM-\d+)\s*$`)

// ParsedItem is the in-memory form before persistence.
type ParsedItem struct {
	Item        *Item
	RawHeading  string // the original "### A36. ..." line, preserved for round-trip.
	ExplicitATM string // if the body carried "**ATM-ID:** ATM-NNN", store it here.
}

// ParseFile parses an Issues.md or Fixed.md and returns the slice of items.
// location MUST be LocationIssues or LocationFixed; it sets the item's
// current_location field and informs status defaulting.
func ParseFile(path, location string) ([]*ParsedItem, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", path, err)
	}
	defer f.Close()

	var items []*ParsedItem
	scanner := bufio.NewScanner(f)
	// Allow long lines for forensic-anchor blockquote bodies.
	scanner.Buffer(make([]byte, 64*1024), 4*1024*1024)

	type parseState struct {
		current      *ParsedItem
		bodyBuilder  strings.Builder
		lineIdx      int // count lines after heading; only inspect first 8 for Status/Type
	}
	state := &parseState{}

	commit := func() {
		if state.current != nil {
			// Body is the trimmed view used for description derivation.
			state.current.Item.Body = strings.TrimRight(state.bodyBuilder.String(), "\n")
			// RawBody (PWU-Q3, §11.4.93 phase-6) is the VERBATIM text between
			// the heading and the next heading, preserved EXACTLY so db→md
			// re-emits it byte-identical. Includes leading blank lines + the
			// trailing newline that separates from the next item's heading.
			state.current.Item.RawBody = state.bodyBuilder.String()
			// §11.4.33 type-aware closure refinement (post-PWU-Q5).
			// The tmux project's Fixed.md uses `RESOLVED` as a universal
			// closure marker across all Types — preserving operator-readability
			// at the cost of a parser-side mapping ambiguity. We resolve it
			// here: once we know the Type (parsed from the body's `**Type:**`
			// line above), we refine an already-set `StatusFixed` to the
			// type-aware closure word so `workable-items validate` reports
			// 0 §11.4.33 findings on the live corpus.
			if state.current.Item.Status == StatusFixed {
				switch state.current.Item.Type {
				case TypeFeature:
					state.current.Item.Status = StatusImplemented
				case TypeTask:
					state.current.Item.Status = StatusCompleted
				}
			}
			items = append(items, state.current)
			state.current = nil
			state.bodyBuilder.Reset()
			state.lineIdx = 0
		}
	}

	for scanner.Scan() {
		line := scanner.Text()
		m := headingRE.FindStringSubmatch(line)
		if m != nil {
			// Heading at H3 only matters if it looks like a workable item.
			// We filter the convention-section H3 ("### ", "Convention table",
			// etc.) by requiring the CAT+N pattern, which already excludes those.
			commit()
			category := m[1]
			ordinal := m[2]
			remainder := m[3]
			code := category + ordinal

			// Strip trailing status hint from heading.
			headingStatus := ""
			cleanTitle := remainder
			if sm := trailingStatusRE.FindStringSubmatchIndex(remainder); sm != nil {
				headingStatus = remainder[sm[2]:sm[3]]
				cleanTitle = strings.TrimSpace(remainder[:sm[0]])
			}
			cleanTitle = strings.TrimSpace(cleanTitle)

			// Derive Status from heading hint or default by location.
			status := mapHeadingHintToStatus(headingStatus, location)

			ordN, _ := strconv.Atoi(ordinal)
			it := &Item{
				Type:            TypeTask, // default per §11.4.16 lowest-stakes
				Status:          status,
				Severity:        "",
				Title:           cleanTitle,
				Description:     cleanTitle, // overridden if a longer body is captured
				CurrentLocation: location,
				Category:        category,
				CodeOrdinal:     ordN,
				HeadingHash:     computeHeadingHash(category, code, cleanTitle),
			}
			state.current = &ParsedItem{Item: it, RawHeading: line}
			state.lineIdx = 0
			continue
		}

		if state.current != nil {
			state.bodyBuilder.WriteString(line)
			state.bodyBuilder.WriteByte('\n')
			state.lineIdx++

			// Within the first 8 non-blank lines, look for Status / Type / Severity.
			if state.lineIdx <= 24 && strings.TrimSpace(line) != "" {
				if sm := statusLineRE.FindStringSubmatch(line); sm != nil {
					if s := mapHeadingHintToStatus(sm[1], location); s != "" {
						state.current.Item.Status = s
					}
				}
				if tm := typeLineRE.FindStringSubmatch(line); tm != nil {
					state.current.Item.Type = tm[1]
				}
				if vm := severityLineRE.FindStringSubmatch(line); vm != nil {
					state.current.Item.Severity = vm[1]
				}
				if am := atmIDLineRE.FindStringSubmatch(line); am != nil {
					state.current.ExplicitATM = am[1]
				}
			}
		}
	}
	commit()
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("scan %s: %w", path, err)
	}
	return items, nil
}

// mapHeadingHintToStatus normalises a raw status hint (OPEN, RESOLVED, PARTIAL,
// "Fixed — pending follow-up", etc.) to the §11.4.15 closed-set vocabulary.
//
// Tmux project uses an older hint vocabulary (OPEN/PARTIAL/BLOCKED/RUNNING/
// INVESTIGATED in Issues.md, RESOLVED/various in Fixed.md). We map them to
// the §11.4.15 closed-set values while preserving the parsed item's
// location for downstream regeneration.
func mapHeadingHintToStatus(hint, location string) string {
	h := strings.ToLower(strings.TrimSpace(hint))
	switch {
	case h == "open":
		return StatusQueued
	case h == "partial" || h == "in progress" || h == "in-progress":
		return StatusInProgress
	case h == "blocked" || h == "operator-blocked":
		return StatusOperatorBlock
	case h == "running" || h == "in testing":
		return StatusInTesting
	case h == "investigated" || h == "ready for testing":
		return StatusReadyForTest
	case h == "reopened":
		return StatusReopened
	case h == "resolved", h == "fixed", strings.HasPrefix(h, "fixed"):
		// Default closure vocabulary; type-aware closure (§11.4.33) refines
		// later in db_to_md when Type is non-Task.
		return StatusFixed
	case h == "implemented", strings.HasPrefix(h, "implemented"):
		return StatusImplemented
	case h == "completed", strings.HasPrefix(h, "completed"):
		return StatusCompleted
	case h == "obsolete", strings.HasPrefix(h, "obsolete"):
		return StatusObsolete
	}
	// Empty / unrecognised hint → default by location.
	switch location {
	case LocationFixed:
		return StatusFixed
	default:
		return StatusQueued
	}
}
