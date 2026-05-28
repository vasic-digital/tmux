// diff.go — drift detector. Runs md-to-db on a TEMP DB, then db-to-md on temp
// outputs, then compares each output against the source MD. Exits 0 on clean,
// 1 with a unified diff dump on drift.
//
// Used as a pre-commit gate by commit_all.sh (wiring done by main context per
// PWU-E).

package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
)

// DiffResult reports the comparison outcome.
type DiffResult struct {
	Clean        bool
	IssuesDiff   string
	FixedDiff    string
	Summary      string
}

// Diff computes the round-trip drift report.
//
// Operation:
//  1. Open a temp DB.
//  2. Run sync md-to-db with issuesPath + fixedPath.
//  3. Run sync db-to-md to a temp dir.
//  4. Diff temp/Issues.md vs issuesPath, temp/Fixed.md vs fixedPath.
//
// NOTE: for the live tmux corpus this WILL report drift because the legacy
// free-form bodies don't round-trip. Drift becomes meaningful AFTER the
// migration cutover (§11.4.93 phase 6). For the golden testdata corpus
// drift MUST be empty.
func Diff(issuesPath, fixedPath string) (*DiffResult, error) {
	tmpDir, err := os.MkdirTemp("", "wi-diff-")
	if err != nil {
		return nil, fmt.Errorf("mktemp: %w", err)
	}
	defer os.RemoveAll(tmpDir)

	tmpDB := filepath.Join(tmpDir, "diff.db")
	db, err := OpenDB(tmpDB)
	if err != nil {
		return nil, err
	}
	defer db.Close()

	if _, err := SyncMDToDB(db, issuesPath, fixedPath); err != nil {
		return nil, fmt.Errorf("md-to-db: %w", err)
	}
	outDir := filepath.Join(tmpDir, "out")
	if err := SyncDBToMD(db, outDir); err != nil {
		return nil, fmt.Errorf("db-to-md: %w", err)
	}

	res := &DiffResult{}

	if issuesPath != "" {
		idiff, err := unifiedDiff(issuesPath, filepath.Join(outDir, "Issues.md"))
		if err != nil {
			return nil, err
		}
		res.IssuesDiff = idiff
	}
	if fixedPath != "" {
		fdiff, err := unifiedDiff(fixedPath, filepath.Join(outDir, "Fixed.md"))
		if err != nil {
			return nil, err
		}
		res.FixedDiff = fdiff
	}
	res.Clean = res.IssuesDiff == "" && res.FixedDiff == ""
	if res.Clean {
		res.Summary = "OK: md ↔ db round-trip is byte-identical"
	} else {
		res.Summary = "DRIFT: md ↔ db round-trip is NOT byte-identical (see diffs)"
	}
	return res, nil
}

// unifiedDiff invokes /usr/bin/diff -u. Empty string = identical.
func unifiedDiff(a, b string) (string, error) {
	cmd := exec.Command("diff", "-u", a, b)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	if err != nil {
		// `diff` exits 1 when files differ — that's not an error.
		if exitErr, ok := err.(*exec.ExitError); ok && exitErr.ExitCode() == 1 {
			return stdout.String(), nil
		}
		// Exit 2+ is a real error.
		return "", fmt.Errorf("diff %s %s: %w (stderr=%s)", a, b, err, stderr.String())
	}
	return stdout.String(), nil
}

// WriteDiffReport emits the diff summary + bodies to w (stdout by default).
func WriteDiffReport(w io.Writer, r *DiffResult) {
	fmt.Fprintln(w, r.Summary)
	if r.IssuesDiff != "" {
		fmt.Fprintln(w, "\n--- Issues.md drift ---")
		fmt.Fprintln(w, r.IssuesDiff)
	}
	if r.FixedDiff != "" {
		fmt.Fprintln(w, "\n--- Fixed.md drift ---")
		fmt.Fprintln(w, r.FixedDiff)
	}
}
