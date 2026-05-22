// tmx-state — per-session cwd persistence daemon for the tmx wrapper.
//
// Subcommands:
//
//	record <session> <abs-path>   atomically upsert a session's last_pwd
//	recall <session>              print last_pwd to stdout (no newline)
//	list                          print TSV: SESSION<TAB>LAST_PWD<TAB>LAST_SEEN_UNIX
//	forget <session>              remove a session key (idempotent)
//	version                       print "tmx-state v1.0.9"
//
// Exit codes:
//
//	0  success
//	1  failure / not-found-for-recall / IO error / permission denied
//	2  state file unreadable (recall only) — distinguishes from "not present"
package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"time"
)

// Version is reported by the `version` subcommand. Bumped per VERSION
// file in the parent project — kept in sync via setup.sh.
const Version = "tmx-state v1.0.9"

// usage prints a top-level help message to `w`.
func usage(w io.Writer) {
	fmt.Fprintf(w, `tmx-state — per-session cwd persistence daemon

Usage:
  tmx-state record  <session> <abs-path>
  tmx-state recall  <session>
  tmx-state list
  tmx-state forget  <session>
  tmx-state version

Env:
  TMX_STATE_FILE   override state file path (default: ~/.tmx/state.json)
`)
}

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

// run is main()'s testable core. Returns an exit code.
func run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		usage(stderr)
		return 1
	}
	sub := args[0]
	rest := args[1:]

	switch sub {
	case "record":
		return cmdRecord(rest, stderr)
	case "recall":
		return cmdRecall(rest, stdout, stderr)
	case "list":
		return cmdList(rest, stdout, stderr)
	case "forget":
		return cmdForget(rest, stderr)
	case "version", "--version", "-v":
		fmt.Fprintln(stdout, Version)
		return 0
	case "help", "--help", "-h":
		usage(stdout)
		return 0
	default:
		fmt.Fprintf(stderr, "tmx-state: unknown subcommand %q\n", sub)
		usage(stderr)
		return 1
	}
}

// cmdRecord: tmx-state record <session> <abs-path>
//
// Creates ~/.tmx/ mode 0700 if missing, writes state.json mode 0600.
// Silent on success, errors to stderr.
func cmdRecord(args []string, stderr io.Writer) int {
	fs := flag.NewFlagSet("record", flag.ContinueOnError)
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 1
	}
	if fs.NArg() != 2 {
		fmt.Fprintln(stderr, "tmx-state record: expected <session> <abs-path>")
		return 1
	}
	session := fs.Arg(0)
	pwd := fs.Arg(1)

	if session == "" {
		fmt.Fprintln(stderr, "tmx-state record: empty session name")
		return 1
	}
	if !filepath.IsAbs(pwd) {
		fmt.Fprintf(stderr, "tmx-state record: pwd must be absolute, got %q\n", pwd)
		return 1
	}

	path, err := statePath()
	if err != nil {
		fmt.Fprintf(stderr, "tmx-state record: %v\n", err)
		return 1
	}

	var rc int
	werr := withStateLock(path, func() error {
		st, lerr := loadState(path)
		if lerr != nil && !errors.Is(lerr, errStateRebuilt) {
			fmt.Fprintf(stderr, "tmx-state record: load: %v\n", lerr)
			rc = 1
			return nil
		}
		if errors.Is(lerr, errStateRebuilt) {
			fmt.Fprintln(stderr, "tmx-state: notice: state file was corrupt, rebuilt")
		}
		now := time.Now().Unix()
		host, _ := os.Hostname()
		existing, had := st.Sessions[session]
		created := now
		if had && existing.CreatedUnix > 0 {
			created = existing.CreatedUnix
		}
		st.Sessions[session] = Session{
			LastPwd:      pwd,
			LastSeenUnix: now,
			CreatedUnix:  created,
			Host:         host,
		}
		if err := saveStateUnlocked(path, st); err != nil {
			fmt.Fprintf(stderr, "tmx-state record: save: %v\n", err)
			rc = 1
			return nil
		}
		return nil
	})
	if werr != nil {
		fmt.Fprintf(stderr, "tmx-state record: %v\n", werr)
		return 1
	}
	return rc
}

// cmdRecall: tmx-state recall <session>
//
// Prints last_pwd to stdout (no trailing newline) + exit 0 if found.
// Nothing + exit 1 if not found.
// "" + exit 2 if state file unreadable.
func cmdRecall(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("recall", flag.ContinueOnError)
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 1
	}
	if fs.NArg() != 1 {
		fmt.Fprintln(stderr, "tmx-state recall: expected <session>")
		return 1
	}
	session := fs.Arg(0)

	path, err := statePath()
	if err != nil {
		fmt.Fprintf(stderr, "tmx-state recall: %v\n", err)
		return 2
	}

	st, lerr := loadState(path)
	// loadState returns errStateRebuilt on corrupt — for recall that's
	// "unreadable" (exit 2) because we can't trust the rebuilt empty.
	if errors.Is(lerr, errStateRebuilt) {
		return 2
	}
	if lerr != nil {
		fmt.Fprintf(stderr, "tmx-state recall: %v\n", lerr)
		return 2
	}
	sess, ok := st.Sessions[session]
	if !ok {
		return 1
	}
	// No trailing newline so `$(tmx-state recall X)` works cleanly.
	fmt.Fprint(stdout, sess.LastPwd)
	return 0
}

// cmdList: tmx-state list
//
// Prints SESSION\tLAST_PWD\tLAST_SEEN_UNIX lines, sorted by session name.
func cmdList(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("list", flag.ContinueOnError)
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 1
	}
	if fs.NArg() != 0 {
		fmt.Fprintln(stderr, "tmx-state list: takes no arguments")
		return 1
	}

	path, err := statePath()
	if err != nil {
		fmt.Fprintf(stderr, "tmx-state list: %v\n", err)
		return 1
	}
	st, lerr := loadState(path)
	if lerr != nil && !errors.Is(lerr, errStateRebuilt) {
		fmt.Fprintf(stderr, "tmx-state list: %v\n", lerr)
		return 1
	}
	// Stable ordering for deterministic test assertions.
	names := make([]string, 0, len(st.Sessions))
	for n := range st.Sessions {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		s := st.Sessions[n]
		fmt.Fprintf(stdout, "%s\t%s\t%d\n", n, s.LastPwd, s.LastSeenUnix)
	}
	return 0
}

// cmdForget: tmx-state forget <session>
//
// Idempotent — exit 0 whether session was present or not.
func cmdForget(args []string, stderr io.Writer) int {
	fs := flag.NewFlagSet("forget", flag.ContinueOnError)
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 1
	}
	if fs.NArg() != 1 {
		fmt.Fprintln(stderr, "tmx-state forget: expected <session>")
		return 1
	}
	session := fs.Arg(0)

	path, err := statePath()
	if err != nil {
		fmt.Fprintf(stderr, "tmx-state forget: %v\n", err)
		return 1
	}
	var rc int
	werr := withStateLock(path, func() error {
		st, lerr := loadState(path)
		if lerr != nil && !errors.Is(lerr, errStateRebuilt) {
			fmt.Fprintf(stderr, "tmx-state forget: %v\n", lerr)
			rc = 1
			return nil
		}
		if _, ok := st.Sessions[session]; !ok {
			// Idempotent: nothing to do.
			return nil
		}
		delete(st.Sessions, session)
		if err := saveStateUnlocked(path, st); err != nil {
			fmt.Fprintf(stderr, "tmx-state forget: save: %v\n", err)
			rc = 1
			return nil
		}
		return nil
	})
	if werr != nil {
		fmt.Fprintf(stderr, "tmx-state forget: %v\n", werr)
		return 1
	}
	return rc
}
