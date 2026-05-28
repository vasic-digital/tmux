// workable-items — §11.4.93 SQLite-SSoT for workable items (Phase 3+).
//
// This binary is project-local for the tmux repo. The constitution submodule
// ships a Phase-2 scaffold at constitution/scripts/workable-items/ (stubs +
// schema). This implementation lives at cmd/workable-items/ per the
// feedback_no_modify_constitution memory rule. The schema.sql here is a
// drift-checked copy of the constitution's; rerun `workable-items validate
// --schema-only` if constitution updates.
//
// Subcommands:
//
//	workable-items sync md-to-db    [--db PATH] [--issues PATH] [--fixed PATH]
//	workable-items sync db-to-md    [--db PATH] [--out-dir PATH]
//	workable-items diff             [--db PATH] [--issues PATH] [--fixed PATH]
//	workable-items validate         [--db PATH] [--schema-only]
//	workable-items add              --type Bug|Feature|Task --severity ... --title ... --description ... [--category A..E]
//	workable-items close            ATM-NNN --status fixed|implemented|completed|obsolete --evidence PATH
//	                                [--by AI|User] [--on YYYY-MM-DD] [--reason ...]
//	                                [--superseding-item ...] [--triple-check-evidence PATH]
//	workable-items report           [--type ...] [--status ...] [--obsolete-audit]
//	workable-items --version
//	workable-items --help

package main

import (
	"flag"
	"fmt"
	"os"
	"strings"
)

// Version is set at build time via -ldflags or defaults here.
var Version = "0.1.0-pwu-c"

func main() {
	if len(os.Args) < 2 {
		printUsage(os.Stderr)
		os.Exit(2)
	}

	// Top-level flags handled before subcommand dispatch.
	switch os.Args[1] {
	case "--version", "-v", "version":
		fmt.Printf("workable-items %s (§11.4.93 PWU-C tmux-project)\n", Version)
		return
	case "--help", "-h", "help":
		printUsage(os.Stdout)
		return
	}

	switch os.Args[1] {
	case "sync":
		runSync(os.Args[2:])
	case "diff":
		runDiff(os.Args[2:])
	case "validate":
		runValidate(os.Args[2:])
	case "add":
		runAdd(os.Args[2:])
	case "close":
		runClose(os.Args[2:])
	case "report":
		runReport(os.Args[2:])
	default:
		fmt.Fprintf(os.Stderr, "unknown subcommand %q\n", os.Args[1])
		printUsage(os.Stderr)
		os.Exit(2)
	}
}

func printUsage(w *os.File) {
	fmt.Fprint(w, `workable-items — §11.4.93 SQLite-SSoT for workable items

Usage:
  workable-items sync md-to-db    [--db PATH] [--issues PATH] [--fixed PATH]
  workable-items sync db-to-md    [--db PATH] [--out-dir PATH]
  workable-items diff             [--db PATH] [--issues PATH] [--fixed PATH]
  workable-items validate         [--db PATH] [--schema-only]
  workable-items add              --type Bug|Feature|Task --severity HIGH|MEDIUM|LOW
                                  --title "..." --description "..." [--category A..E]
  workable-items close            ATM-NNN --status fixed|implemented|completed|obsolete
                                  --evidence PATH [--by AI|User] [--on YYYY-MM-DD]
                                  [--reason ...] [--superseding-item ...]
                                  [--triple-check-evidence PATH]
  workable-items report           [--type ...] [--status ...] [--obsolete-audit]
  workable-items --version

Composes with §11.4.93 / §11.4.95 (DB tracked in git) / §11.4.54 (ATM-NNN).
`)
}

func runSync(args []string) {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: workable-items sync md-to-db|db-to-md ...")
		os.Exit(2)
	}
	direction := args[0]
	rest := args[1:]
	fs := flag.NewFlagSet("sync "+direction, flag.ExitOnError)
	dbPath := fs.String("db", "docs/workable_items.db", "path to SQLite DB")
	issuesPath := fs.String("issues", "Issues.md", "path to Issues.md")
	fixedPath := fs.String("fixed", "Fixed.md", "path to Fixed.md")
	outDir := fs.String("out-dir", "docs/workable-items/regen", "output directory for db-to-md")
	_ = fs.Parse(rest)

	db, err := OpenDB(*dbPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "open db: %v\n", err)
		os.Exit(1)
	}
	defer func() {
		if cerr := db.Close(); cerr != nil {
			fmt.Fprintf(os.Stderr, "close db: %v\n", cerr)
		}
	}()

	switch direction {
	case "md-to-db":
		res, err := SyncMDToDB(db, *issuesPath, *fixedPath)
		if err != nil {
			fmt.Fprintf(os.Stderr, "sync md-to-db: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("sync md-to-db OK: issues_parsed=%d fixed_parsed=%d inserted=%d updated=%d unchanged=%d allocated=%d\n",
			res.IssuesParsed, res.FixedParsed, res.Inserted, res.Updated, res.UnchangedItems, res.ATMIDsAllocated)
	case "db-to-md":
		if err := SyncDBToMD(db, *outDir); err != nil {
			fmt.Fprintf(os.Stderr, "sync db-to-md: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("sync db-to-md OK: out=%s\n", *outDir)
	default:
		fmt.Fprintf(os.Stderr, "unknown sync direction %q (want md-to-db|db-to-md)\n", direction)
		os.Exit(2)
	}
}

func runDiff(args []string) {
	fs := flag.NewFlagSet("diff", flag.ExitOnError)
	dbPath := fs.String("db", "docs/workable_items.db", "path to SQLite DB (unused; diff opens its own temp DB)")
	issuesPath := fs.String("issues", "Issues.md", "path to Issues.md")
	fixedPath := fs.String("fixed", "Fixed.md", "path to Fixed.md")
	allowDrift := fs.Bool("allow-drift", false, "exit 0 even on drift (informational only)")
	_ = fs.Parse(args)
	_ = dbPath

	res, err := Diff(*issuesPath, *fixedPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "diff: %v\n", err)
		os.Exit(1)
	}
	WriteDiffReport(os.Stdout, res)
	if !res.Clean && !*allowDrift {
		os.Exit(1)
	}
}

func runValidate(args []string) {
	fs := flag.NewFlagSet("validate", flag.ExitOnError)
	dbPath := fs.String("db", "docs/workable_items.db", "path to SQLite DB")
	schemaOnly := fs.Bool("schema-only", false, "only check that the embedded schema applies cleanly")
	_ = fs.Parse(args)

	db, err := OpenDB(*dbPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "open db: %v\n", err)
		os.Exit(1)
	}
	defer db.Close()

	if *schemaOnly {
		fmt.Println("schema OK: embedded schema applied cleanly")
		return
	}
	findings, err := Validate(db)
	if err != nil {
		fmt.Fprintf(os.Stderr, "validate: %v\n", err)
		os.Exit(1)
	}
	if len(findings) == 0 {
		fmt.Println("validate OK: 0 findings")
		return
	}
	for _, f := range findings {
		fmt.Println(f.String())
	}
	fmt.Printf("validate FAIL: %d findings\n", len(findings))
	os.Exit(1)
}

func runAdd(args []string) {
	fs := flag.NewFlagSet("add", flag.ExitOnError)
	dbPath := fs.String("db", "docs/workable_items.db", "path to SQLite DB")
	itemType := fs.String("type", "", "Bug|Feature|Task")
	severity := fs.String("severity", "", "HIGH|MEDIUM|LOW")
	title := fs.String("title", "", "item title (single line)")
	description := fs.String("description", "", "item description (≥40 chars or ≥6 words per §11.4.91)")
	category := fs.String("category", "Z", "project-specific category letter (A..E)")
	_ = fs.Parse(args)

	db, err := OpenDB(*dbPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "open db: %v\n", err)
		os.Exit(1)
	}
	defer db.Close()

	it, err := AddItem(db, AddItemParams{
		Type:        *itemType,
		Severity:    *severity,
		Title:       *title,
		Description: *description,
		Category:    *category,
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "add: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("added %s (%s/%s): %s\n", it.ATMID, it.Type, it.Status, it.Title)
}

func runClose(args []string) {
	if len(args) < 1 || strings.HasPrefix(args[0], "--") {
		fmt.Fprintln(os.Stderr, "usage: workable-items close ATM-NNN --status ... --evidence ...")
		os.Exit(2)
	}
	atmID := args[0]
	rest := args[1:]
	fs := flag.NewFlagSet("close", flag.ExitOnError)
	dbPath := fs.String("db", "docs/workable_items.db", "path to SQLite DB")
	status := fs.String("status", "", "fixed|implemented|completed|obsolete")
	evidence := fs.String("evidence", "", "path to captured-evidence artefact (§11.4.5 + §11.4.69)")
	by := fs.String("by", "AI", "AI|User (§11.4.34 attribution)")
	onDate := fs.String("on", "", "YYYY-MM-DD (defaults to today)")
	reason := fs.String("reason", "", "closure reason (closed-set value for obsolete)")
	supersedingItem := fs.String("superseding-item", "", "§11.4.90 superseding §-letter or ATM-NNN")
	tripleCheck := fs.String("triple-check-evidence", "", "§11.4.90 triple-check evidence path")
	_ = fs.Parse(rest)

	db, err := OpenDB(*dbPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "open db: %v\n", err)
		os.Exit(1)
	}
	defer db.Close()

	it, err := CloseItem(db, CloseItemParams{
		ATMID:                   atmID,
		Status:                  *status,
		Evidence:                *evidence,
		By:                      *by,
		OnDate:                  *onDate,
		Reason:                  *reason,
		ObsoleteSupersedingItem: *supersedingItem,
		ObsoleteTripleCheckPath: *tripleCheck,
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "close: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("closed %s → %s (location: %s)\n", it.ATMID, it.Status, it.CurrentLocation)
}

func runReport(args []string) {
	fs := flag.NewFlagSet("report", flag.ExitOnError)
	dbPath := fs.String("db", "docs/workable_items.db", "path to SQLite DB")
	filterType := fs.String("type", "", "filter by type (Bug|Feature|Task)")
	filterStatus := fs.String("status", "", "filter by status (closed-set value)")
	obsoleteAudit := fs.Bool("obsolete-audit", false, "list Obsolete items + their details")
	_ = fs.Parse(args)

	db, err := OpenDB(*dbPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "open db: %v\n", err)
		os.Exit(1)
	}
	defer db.Close()

	all, err := db.AllItems()
	if err != nil {
		fmt.Fprintf(os.Stderr, "report: %v\n", err)
		os.Exit(1)
	}
	count := 0
	for _, it := range all {
		if *filterType != "" && it.Type != *filterType {
			continue
		}
		if *filterStatus != "" && it.Status != *filterStatus {
			continue
		}
		if *obsoleteAudit && it.Status != StatusObsolete {
			continue
		}
		fmt.Printf("%s [%s/%s] %s\n", it.ATMID, it.Type, it.Status, it.Title)
		if *obsoleteAudit {
			od, _ := db.ObsoleteDetailsFor(it.ATMID)
			if od != nil {
				fmt.Printf("    Obsolete-Details: since=%s reason=%s superseded-by=%s evidence=%s\n",
					od.Since, od.Reason, od.SupersedingItem, od.TripleCheckEvidence)
			}
		}
		count++
	}
	fmt.Printf("\n%d row(s) reported (total in DB: %d)\n", count, len(all))
}
