// db_concurrency_test.go — §11.4.93/95 race guard on the DB open path.
//
// Regression: the DSN previously listed `journal_mode(WAL)` BEFORE
// `busy_timeout(5000)`. modernc.org/sqlite applies DSN pragmas on every new
// connection in query order, so the WAL-mode pragma ran while the busy timeout
// was still the driver default (0). Eight concurrent `sync md-to-db` processes
// then got an immediate SQLITE_BUSY (261) at OpenDB/Ping, before any sync work.
// Measured 2026-11-20 on a COPY of docs/workable_items.db: journal-mode-first
// failed 25/100 runs of 8 concurrent open+Ping; busy-timeout-first failed 0/100.
//
// This test keeps that ordering contract honest: N goroutines each open the
// SAME DB (each OpenDB creates fresh sql.DB connections that must re-apply the
// pragmas) and perform a real write. Any lock error is a FAIL — not a SKIP.
package main

import (
	"fmt"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func TestConcurrentOpenDBBusyTimeout(t *testing.T) {
	path := filepath.Join(t.TempDir(), "concurrent.db")
	seed, err := OpenDB(path)
	if err != nil {
		t.Fatalf("seed OpenDB: %v", err)
	}
	if err := seed.Close(); err != nil {
		t.Fatalf("seed Close: %v", err)
	}

	const writers = 8
	const rounds = 30
	for r := 0; r < rounds; r++ {
		var wg sync.WaitGroup
		errCh := make(chan error, writers)
		for i := 0; i < writers; i++ {
			wg.Add(1)
			go func(w int) {
				defer wg.Done()
				db, oerr := OpenDB(path)
				if oerr != nil {
					errCh <- fmt.Errorf("round %d writer %d OpenDB: %w", r, w, oerr)
					return
				}
				// A real write so the writers contend on the DB file, not just
				// on connection setup.
				if werr := db.MetaSet(fmt.Sprintf("concurrent_%d_%d", r, w), "v"); werr != nil {
					errCh <- fmt.Errorf("round %d writer %d MetaSet: %w", r, w, werr)
				}
				_ = db.Close()
			}(i)
		}
		wg.Wait()
		close(errCh)
		for e := range errCh {
			// A "database is locked" here is the exact regression this guards.
			if strings.Contains(e.Error(), "locked") || strings.Contains(e.Error(), "BUSY") {
				t.Errorf("concurrent open/write lost the busy window: %v", e)
			} else {
				t.Errorf("concurrent open/write error: %v", e)
			}
		}
	}
}
