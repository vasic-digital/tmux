// Package main — atomic write + advisory locking.
//
// Atomic write protocol:
//  1. Create lock file at <path>.lock (mode 0600).
//  2. Acquire LOCK_EX (blocking) on lock fd.
//  3. Write payload to <path>.tmp.<pid>.<rand> (mode 0600).
//  4. fsync the temp file.
//  5. rename(temp, path) — atomic on POSIX.
//  6. fsync parent dir (best-effort; macOS doesn't always honor it but it doesn't hurt).
//  7. Release lock (close fd).
//
// Cross-platform: Flock(LOCK_EX) works on both darwin + linux (§11.4.81).
package main

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"syscall"
)

// processLocks serializes lock acquisitions on the SAME path within
// this process. flock(2) is per-fd, so two goroutines in the same
// process opening separate fds on the same lock file would both
// "acquire" LOCK_EX simultaneously and race the load→mutate→save
// sequence. The processLocks mutex pins one-goroutine-at-a-time
// access per path; the on-disk flock then serializes ACROSS processes.
var (
	processLocksMu sync.Mutex
	processLocks   = map[string]*sync.Mutex{}
)

func processMutexFor(path string) *sync.Mutex {
	processLocksMu.Lock()
	defer processLocksMu.Unlock()
	m, ok := processLocks[path]
	if !ok {
		m = &sync.Mutex{}
		processLocks[path] = m
	}
	return m
}

// atomicWriteLocked writes `data` to `path` atomically under an
// exclusive advisory lock. mode applies to BOTH the lock file and
// the final state file. Holds process-mutex + on-disk flock so
// both in-process goroutines AND cross-process writers serialize.
func atomicWriteLocked(path string, data []byte, mode os.FileMode) error {
	pm := processMutexFor(path)
	pm.Lock()
	defer pm.Unlock()

	lockPath := path + ".lock"
	lockFD, err := acquireLock(lockPath, mode)
	if err != nil {
		return fmt.Errorf("acquire lock %s: %w", lockPath, err)
	}
	defer releaseLock(lockFD)

	return atomicWrite(path, data, mode)
}

// withStateLock runs fn under the SAME (process-mutex + flock) pair
// used by atomicWriteLocked, but spanning load+mutate+save so a
// read-modify-write sequence is atomic with respect to concurrent
// writers. fn receives no args and returns an error.
func withStateLock(path string, fn func() error) error {
	pm := processMutexFor(path)
	pm.Lock()
	defer pm.Unlock()

	if err := ensureParentDir(path); err != nil {
		return err
	}
	lockPath := path + ".lock"
	lockFD, err := acquireLock(lockPath, 0o600)
	if err != nil {
		return fmt.Errorf("acquire lock %s: %w", lockPath, err)
	}
	defer releaseLock(lockFD)

	return fn()
}

// atomicWrite writes `data` to `path` via temp + rename. Caller is
// responsible for serialization (lock).
func atomicWrite(path string, data []byte, mode os.FileMode) error {
	dir := filepath.Dir(path)
	// 8 random hex bytes (16 chars) — collision-resistant within a pid.
	var randBuf [8]byte
	if _, err := rand.Read(randBuf[:]); err != nil {
		return fmt.Errorf("rand: %w", err)
	}
	tmpName := fmt.Sprintf("%s.tmp.%d.%s",
		filepath.Base(path), os.Getpid(), hex.EncodeToString(randBuf[:]))
	tmpPath := filepath.Join(dir, tmpName)

	// O_CREATE|O_EXCL|O_WRONLY so we never clobber a sibling tmp.
	f, err := os.OpenFile(tmpPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, mode)
	if err != nil {
		return fmt.Errorf("open tmp %s: %w", tmpPath, err)
	}
	// On any error past this point, remove the tmp so we don't leak.
	cleanup := func() { _ = os.Remove(tmpPath) }

	if _, werr := f.Write(data); werr != nil {
		_ = f.Close()
		cleanup()
		return fmt.Errorf("write tmp: %w", werr)
	}
	if serr := f.Sync(); serr != nil {
		_ = f.Close()
		cleanup()
		return fmt.Errorf("fsync tmp: %w", serr)
	}
	if cerr := f.Close(); cerr != nil {
		cleanup()
		return fmt.Errorf("close tmp: %w", cerr)
	}

	// Belt-and-suspenders: chmod in case umask stripped bits.
	if cerr := os.Chmod(tmpPath, mode); cerr != nil {
		cleanup()
		return fmt.Errorf("chmod tmp: %w", cerr)
	}

	if rerr := os.Rename(tmpPath, path); rerr != nil {
		cleanup()
		return fmt.Errorf("rename tmp -> final: %w", rerr)
	}

	// Best-effort parent fsync (durability after rename).
	if dirFD, derr := os.Open(dir); derr == nil {
		_ = dirFD.Sync()
		_ = dirFD.Close()
	}
	return nil
}

// acquireLock opens (creating if needed) the lock file at `path` and
// takes an exclusive blocking advisory lock on it. Returns the fd
// the caller must close to release.
func acquireLock(path string, mode os.FileMode) (*os.File, error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, mode)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		_ = f.Close()
		return nil, err
	}
	return f, nil
}

// releaseLock drops the advisory lock and closes the fd.
func releaseLock(f *os.File) {
	if f == nil {
		return
	}
	_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	_ = f.Close()
}
