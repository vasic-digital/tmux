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
//
// The value is captured greedily up to a *real* separator: an em-dash (` — `),
// a double-dash (`--`), a period, or end-of-line. A bare single hyphen is NOT a
// separator — it is part of hyphenated closed-set values such as
// `Operator-blocked` (§11.4.21). The earlier alternation listed a lone `-`,
// which (with the non-greedy `+?`) truncated `Operator-blocked` at its first
// hyphen, yielding the unrecognised token `Operator` that defaulted to
// `Queued` (Issues.md F1 / TMX-050 forensic case). Requiring whitespace around
// the single-hyphen separator preserves the "value — trailing note" form while
// keeping intra-word hyphens intact.
var statusLineRE = regexp.MustCompile(`^\*\*Status:\*\*\s*` + "`?" + `([^` + "`" + `\n]+?)` + "`?" + `\s*(?:—|--|\s-\s|\.|$)`)

// typeLineRE matches "**Type:** `value`".
var typeLineRE = regexp.MustCompile(`^\*\*Type:\*\*\s*` + "`?" + `(Bug|Feature|Task)` + "`?" + `\s*$`)

// severityLineRE matches "**Severity:** HIGH" or similar.
var severityLineRE = regexp.MustCompile(`^\*\*Severity:\*\*\s*` + "`?" + `([A-Za-z0-9\-_]+)` + "`?")

// atmIDLineRE matches "**TMX-ID:** TMX-NNN" when present in regenerated output;
// during md-to-db we re-bind to the persisted ID rather than allocating a new one.
// Built from the §11.4.54 TicketLabel/TicketPrefix consts (§11.4.1 fix-at-source).
var atmIDLineRE = regexp.MustCompile(`^\*\*` + regexp.QuoteMeta(TicketLabel) + `:\*\*\s*(` + regexp.QuoteMeta(TicketPrefix) + `\d+)\s*$`)

// anyHeadingRE matches a Markdown heading of ANY level (`# ` … `###### `). It is
// the §11.4.6 GREEDY-BIND guard (TMX-065): the structured-metadata prefix region
// of an item ALWAYS sits immediately below the item's own heading and before any
// subsequent heading. So the moment the parser sees ANOTHER heading inside a
// current item's body — including a NO-PERIOD `### ` block that does not match
// headingRE and is therefore not committed as its own item — the current item's
// **TMX-ID:**/**Status:**/**Type:**/**Severity:** window MUST close. Without this
// guard a period heading (`### A54. …`) absorbed a following no-period block's
// `**TMX-ID:**`, mis-bound it, and produced a UNIQUE-constraint failure on
// `sync md-to-db` (forced a §9.2 DB restore this session).
var anyHeadingRE = regexp.MustCompile(`^#{1,6}\s`)

// ParsedItem is the in-memory form before persistence.
type ParsedItem struct {
	Item        *Item
	RawHeading  string // the original "### A36. ..." line, preserved for round-trip.
	ExplicitATM string // if the body carried "**TMX-ID:** TMX-NNN", store it here.
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
		current     *ParsedItem
		bodyBuilder strings.Builder
		lineIdx     int  // count lines after heading; only inspect first 8 for Status/Type
		metaClosed  bool // §11.4.6 GREEDY-BIND guard: set once a subsequent heading is seen
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
			state.metaClosed = false
			continue
		}

		if state.current != nil {
			// §11.4.6 GREEDY-BIND guard (TMX-065): a subsequent Markdown heading
			// of ANY level — most importantly a NO-PERIOD `### ` block that does
			// not match headingRE and so is not committed as its own item — ends
			// the current item's structured-metadata prefix region. Close the
			// window so the following block's **TMX-ID:**/**Status:**/**Type:**/
			// **Severity:** can never be mis-bound to the current (preceding)
			// item. The line is still appended to the body verbatim for
			// byte-identical round-trip (document_sources/raw_body unaffected).
			if anyHeadingRE.MatchString(line) {
				state.metaClosed = true
			}

			state.bodyBuilder.WriteString(line)
			state.bodyBuilder.WriteByte('\n')
			state.lineIdx++

			// Within the first 8 non-blank lines, look for Status / Type / Severity.
			if !state.metaClosed && state.lineIdx <= 24 && strings.TrimSpace(line) != "" {
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

// obProseRE matches a `**LABEL:**` lead-in for an Operator-Block-Details
// sub-fact. The label is matched case-insensitively against the four canonical
// sub-facts (WHAT / WHY / UNBLOCK CONDITION / WHO). The WHY label often carries
// a parenthetical (e.g. `**WHY (self-resolution exhausted):**`), so the matcher
// keys on a leading keyword rather than the literal full label.
var obDetailsHeaderRE = regexp.MustCompile(`(?i)^\*\*Operator-Block-Details:\*\*\s*$`)

// obSubFactRE captures a sub-fact bullet of the form
//
//   - **WHAT:** <text...>
//   - **WHY (self-resolution exhausted):** <text...>
//   - **UNBLOCK CONDITION:** <text...>
//   - **WHO:** <text...>
//
// Group 1 = the bolded label (without the leading `- ` and surrounding `**`),
// group 2 = the inline text on the same line. Continuation lines (indented,
// not a new bullet, not a new heading) are appended by the caller.
var obSubFactRE = regexp.MustCompile(`^\s*[-*]\s+\*\*([^*]+?):\*\*\s*(.*)$`)

// parseOperatorBlockDetails extracts the §11.4.21 **Operator-Block-Details:**
// block from an item body and returns the structured sub-facts. Returns nil
// when the body carries no such block (e.g. a malformed Operator-blocked item —
// validate.go still flags the missing row, which is the correct §11.4.21
// behaviour).
//
// The block is a sequence of `- **LABEL:** text` bullets. A bullet's text may
// continue across indented continuation lines until the next bullet, a blank
// line that precedes a non-bullet, or the end of the block (`---` separator,
// a new `**Field:**` metadata line, or another heading-level marker). Labels
// are matched case-insensitively on a leading keyword so parenthetical
// annotations (`**WHY (self-resolution exhausted):**`) still bind.
func parseOperatorBlockDetails(body string) *OperatorBlockDetails {
	lines := strings.Split(body, "\n")
	inBlock := false
	var curLabel string
	var curText strings.Builder
	ob := &OperatorBlockDetails{}
	found := false

	flush := func() {
		if curLabel == "" {
			return
		}
		text := strings.TrimSpace(curText.String())
		switch obSubFactKey(curLabel) {
		case "what":
			ob.What = text
			found = true
		case "why":
			ob.WhyExhaustedAlternatives = text
			found = true
		case "unblock":
			ob.UnblockCondition = text
			found = true
		case "who":
			ob.Who = text
			found = true
		}
		curLabel = ""
		curText.Reset()
	}

	for _, ln := range lines {
		if !inBlock {
			if obDetailsHeaderRE.MatchString(strings.TrimSpace(ln)) {
				inBlock = true
			}
			continue
		}
		// Inside the block.
		if sm := obSubFactRE.FindStringSubmatch(ln); sm != nil {
			flush()
			curLabel = sm[1]
			curText.WriteString(strings.TrimSpace(sm[2]))
			continue
		}
		trimmed := strings.TrimSpace(ln)
		// Terminators: blank line, `---` separator, a new `**Field:**` metadata
		// line, or a heading marker all end the block.
		if trimmed == "" || trimmed == "---" ||
			strings.HasPrefix(trimmed, "#") ||
			(strings.HasPrefix(trimmed, "**") && curLabel == "") {
			flush()
			if trimmed == "---" || strings.HasPrefix(trimmed, "#") {
				break
			}
			// A blank line inside a bullet's continuation ends the block too —
			// the canonical format separates the block from the trailer with a
			// blank line. Stop scanning to avoid pulling trailer prose in.
			if trimmed == "" {
				break
			}
			continue
		}
		// Continuation line for the current sub-fact.
		if curLabel != "" {
			curText.WriteString(" ")
			curText.WriteString(trimmed)
		}
	}
	flush()

	if !found {
		return nil
	}
	return ob
}

// obSubFactKey maps a raw sub-fact label to its canonical key. The match keys
// on the leading keyword so `WHY (self-resolution exhausted)` → "why".
func obSubFactKey(label string) string {
	u := strings.ToUpper(strings.TrimSpace(label))
	switch {
	case strings.HasPrefix(u, "WHAT"):
		return "what"
	case strings.HasPrefix(u, "WHY"):
		return "why"
	case strings.HasPrefix(u, "UNBLOCK"):
		return "unblock"
	case strings.HasPrefix(u, "WHO"):
		return "who"
	}
	return ""
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
