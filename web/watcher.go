package main

import (
	"context"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Watcher keeps the index up to date as files appear under the media root.
// The OS layer (inotify on Linux, see watcher_linux.go) delivers raw events;
// this file decides when a new file is complete and adds it.
//
// A file counts as complete only when all of these hold:
//   - nothing has written to it for the settle period (every write, close
//     or rename event restarts the clock), and its size and mtime stay the
//     same across two checks;
//   - it isn't a download-in-progress name (.part, .crdownload, .!qB, …)
//     and has no download sidecar next to it (foo.mp4.aria2, foo.mp4.part);
//   - no process has it open for writing (Linux: /proc/*/fd), which catches
//     torrent clients that preallocate and keep files open;
//   - ffprobe can read it. A probe failure is retried a few times (a
//     download may still be being finalised) before the file is recorded in
//     skipped_files, like the scanner does.
//
// Renames inside the library (files or whole directories) update the
// existing rows instead of adding new ones, so likes, views and actors stay.
type Watcher struct {
	store     *Store
	root      string
	thumbsDir string
	settle    time.Duration
	backend   watchBackend
	logger    *log.Logger
	Log       *ringLog

	// Overridable in tests.
	probe       func(scanJob) scanResult
	openForWrit func(path string) bool
	now         func() time.Time
	tickEvery   time.Duration
	maxAttempts int
	onOverflow  func()

	sc *Scanner // reused for its batch insert (flush)

	mu       sync.Mutex
	pending  map[string]*pendingFile
	moves    map[uint32]movedFrom
	dirs     int
	probeSem chan struct{}
}

type pendingFile struct {
	lastEvent time.Time
	size      int64
	mtime     time.Time
	checked   bool // size/mtime recorded at least once after settling
	attempts  int
	nextTry   time.Time
	probing   bool
}

type movedFrom struct {
	path  string
	isDir bool
	at    time.Time
}

type fsOp int

const (
	opCreate fsOp = iota
	opWrite
	opCloseWrite
	opMovedFrom
	opMovedTo
	opDelete
	opOverflow
)

type fsEvent struct {
	Path   string
	IsDir  bool
	Op     fsOp
	Cookie uint32 // pairs MovedFrom with MovedTo
}

// watchBackend is the OS-specific part: watch single directories and
// deliver events for their direct children.
type watchBackend interface {
	Add(dir string) error
	Rename(oldDir, newDir string) // a watched directory tree moved
	Events() <-chan fsEvent
	Close() error
}

// Names download tools use while a file is incomplete.
var partialSuffixes = []string{
	".part", ".partial", ".crdownload", ".download", ".tmp", ".temp", ".!qb", ".!ut",
	".aria2", ".bc!", ".opdownload", ".filepart", ".downloading", ".unfinished", "~",
}

// Sidecar files that exist next to a file while it is still downloading.
var sidecarSuffixes = []string{".aria2", ".part", ".!qB", ".crdownload"}

func NewWatcher(store *Store, root, thumbsDir string, settle time.Duration, backend watchBackend, out io.Writer) *Watcher {
	logBuf := &ringLog{max: 128 << 10}
	w := &Watcher{
		store: store, root: root, thumbsDir: thumbsDir, settle: settle, backend: backend,
		Log:         logBuf,
		logger:      log.New(io.MultiWriter(out, logBuf), "watch: ", log.LstdFlags),
		probe:       extract,
		openForWrit: openForWriting,
		now:         time.Now,
		tickEvery:   2 * time.Second,
		maxAttempts: 3,
		pending:     map[string]*pendingFile{},
		moves:       map[uint32]movedFrom{},
		probeSem:    make(chan struct{}, 2),
	}
	w.sc = NewScanner(store, root, false, 1, io.Discard)
	return w
}

// Start begins watching: the directory tree is registered in the
// background (it can take a while on a big library), events are handled as
// they arrive.
func (w *Watcher) Start(ctx context.Context) {
	go func() {
		start := w.now()
		w.addTree(w.root, false)
		w.mu.Lock()
		n := w.dirs
		w.mu.Unlock()
		w.logger.Printf("watching %d directories under %s (took %s, settle %s)", n, w.root, w.now().Sub(start).Round(time.Millisecond), w.settle)
	}()
	go w.loop(ctx)
}

func (w *Watcher) Status() map[string]any {
	w.mu.Lock()
	defer w.mu.Unlock()
	return map[string]any{"dirs": w.dirs, "pending": len(w.pending), "log": w.Log.String()}
}

func (w *Watcher) loop(ctx context.Context) {
	t := time.NewTicker(w.tickEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			w.backend.Close()
			return
		case ev, ok := <-w.backend.Events():
			if !ok {
				return
			}
			w.handle(ev)
		case <-t.C:
			w.tick()
		}
	}
}

func (w *Watcher) inThumbs(p string) bool {
	return p == w.thumbsDir || strings.HasPrefix(p, w.thumbsDir+string(filepath.Separator))
}

func (w *Watcher) rel(p string) (string, bool) {
	r, err := filepath.Rel(w.root, p)
	if err != nil || r == "." || strings.HasPrefix(r, "..") {
		return "", false
	}
	return filepath.ToSlash(r), true
}

// addTree registers watches for dir and everything below it. With
// enqueue, files already inside are queued too (a directory that was just
// created or moved in may have been filled before its watch existed).
func (w *Watcher) addTree(dir string, enqueue bool) {
	walkFollow(dir, func(d string) bool {
		if w.inThumbs(d) {
			return false
		}
		if err := w.backend.Add(d); err != nil {
			w.logger.Printf("cannot watch %s: %v", d, err)
			return true
		}
		w.mu.Lock()
		w.dirs++
		w.mu.Unlock()
		return true
	}, func(f string) {
		if enqueue {
			w.mu.Lock()
			w.touch(f)
			w.mu.Unlock()
		}
	})
}

func ignoredName(p string) bool {
	lower := strings.ToLower(p)
	if skipExt[strings.ToLower(filepath.Ext(p))] {
		return true
	}
	for _, s := range partialSuffixes {
		if strings.HasSuffix(lower, s) {
			return true
		}
	}
	return false
}

// touch (re)starts the settle clock for a file. Caller holds mu.
func (w *Watcher) touch(p string) {
	if w.inThumbs(p) || ignoredName(p) {
		return
	}
	pf := w.pending[p]
	if pf == nil {
		pf = &pendingFile{}
		w.pending[p] = pf
	}
	pf.lastEvent = w.now()
	pf.checked = false
	pf.nextTry = time.Time{}
}

func (w *Watcher) handle(ev fsEvent) {
	if ev.Op == opOverflow {
		w.logger.Printf("event queue overflowed; some changes were missed — running a full scan")
		if w.onOverflow != nil {
			w.onOverflow()
		}
		return
	}
	if w.inThumbs(ev.Path) {
		return
	}
	w.mu.Lock()
	defer w.mu.Unlock()

	switch ev.Op {
	case opMovedFrom:
		w.moves[ev.Cookie] = movedFrom{path: ev.Path, isDir: ev.IsDir, at: w.now()}
		if !ev.IsDir {
			delete(w.pending, ev.Path)
		}
		return
	case opMovedTo:
		if from, ok := w.moves[ev.Cookie]; ok {
			delete(w.moves, ev.Cookie)
			if w.renamed(from, ev) {
				return
			}
		}
		if ev.IsDir {
			w.mu.Unlock()
			w.addTree(ev.Path, true)
			w.mu.Lock()
			return
		}
		w.touch(ev.Path)
	case opCreate:
		if ev.IsDir {
			w.mu.Unlock()
			w.addTree(ev.Path, true)
			w.mu.Lock()
			return
		}
		w.touch(ev.Path)
	case opWrite, opCloseWrite:
		if !ev.IsDir {
			w.touch(ev.Path)
		}
	case opDelete:
		delete(w.pending, ev.Path)
	}
}

// renamed applies a move inside the library to the database. It returns
// false when the source wasn't indexed (e.g. "x.mp4.part" -> "x.mp4"), in
// which case the destination is treated as a new file. Caller holds mu.
func (w *Watcher) renamed(from movedFrom, to fsEvent) bool {
	oldRel, ok1 := w.rel(from.path)
	newRel, ok2 := w.rel(to.Path)
	if !ok1 || !ok2 {
		return false
	}
	if to.IsDir {
		w.backend.Rename(from.path, to.Path)
		for p, pf := range w.pending { // queued files move along
			if strings.HasPrefix(p, from.path+string(filepath.Separator)) {
				delete(w.pending, p)
				w.pending[to.Path+p[len(from.path):]] = pf
			}
		}
	}
	n, err := w.store.RenamePath(context.Background(), oldRel, newRel, to.IsDir)
	if err != nil {
		w.logger.Printf("rename %s -> %s: %v", oldRel, newRel, err)
		return to.IsDir
	}
	if n > 0 {
		w.logger.Printf("renamed %s -> %s (%d row(s) updated)", oldRel, newRel, n)
	}
	// A moved directory may also hold files that were never indexed.
	if to.IsDir {
		walkFollow(to.Path, nil, func(f string) {
			if r, ok := w.rel(f); ok && !w.store.HasMedia(r) {
				w.touch(f)
			}
		})
		return true
	}
	return n > 0
}

// hasSidecar reports download-manager control files next to p.
func hasSidecar(p string) bool {
	for _, s := range sidecarSuffixes {
		if _, err := os.Stat(p + s); err == nil {
			return true
		}
	}
	return false
}

func (w *Watcher) tick() {
	now := w.now()
	w.mu.Lock()
	defer w.mu.Unlock()
	for c, m := range w.moves { // unmatched MovedFrom: moved out of the library
		if now.Sub(m.at) > 5*time.Second {
			delete(w.moves, c)
		}
	}
	for p, pf := range w.pending {
		if pf.probing || now.Sub(pf.lastEvent) < w.settle || now.Before(pf.nextTry) {
			continue
		}
		st, err := os.Stat(p)
		if err != nil || !st.Mode().IsRegular() {
			delete(w.pending, p)
			continue
		}
		if !pf.checked || st.Size() != pf.size || !st.ModTime().Equal(pf.mtime) {
			// Record and look again next tick: must be unchanged in between.
			pf.size, pf.mtime, pf.checked = st.Size(), st.ModTime(), true
			if st.Size() == 0 {
				pf.lastEvent = now
			}
			continue
		}
		if hasSidecar(p) || w.openForWrit(p) {
			pf.lastEvent = now
			pf.checked = false
			continue
		}
		rel, ok := w.rel(p)
		if !ok || w.store.HasMedia(rel) {
			delete(w.pending, p)
			continue
		}
		pf.probing = true
		go w.ingest(p, rel, pf)
	}
}

func (w *Watcher) ingest(path, rel string, pf *pendingFile) {
	w.probeSem <- struct{}{}
	res := w.probe(scanJob{rel: rel, path: path})
	<-w.probeSem

	w.mu.Lock()
	defer w.mu.Unlock()
	pf.probing = false
	if w.pending[path] != pf {
		return // renamed or deleted meanwhile
	}
	if pf.lastEvent.After(w.now().Add(-w.settle)) {
		return // written to while probing: wait for it to settle again
	}
	if res.row != nil {
		if err := w.sc.flush([]mediaRow{*res.row}, nil, map[string]bool{}); err != nil {
			w.logger.Printf("add %s: %v", rel, err)
			pf.nextTry = w.now().Add(w.settle)
			return
		}
		delete(w.pending, path)
		r := res.row
		w.logger.Printf("added %s (%dx%d, %s, %.0fs)", rel, r.width, r.height, deref(r.codec), r.duration)
		return
	}
	pf.attempts++
	if pf.attempts < w.maxAttempts {
		wait := time.Duration(pf.attempts) * 2 * w.settle
		w.logger.Printf("probe of %s failed (%s), retrying in %s", rel, res.detail, wait)
		pf.nextTry = w.now().Add(wait)
		pf.checked = false
		return
	}
	delete(w.pending, path)
	if err := w.sc.flush(nil, [][3]string{{rel, res.status, res.detail}}, nil); err != nil {
		w.logger.Printf("record skipped %s: %v", rel, err)
		return
	}
	w.logger.Printf("skipped %s after %d attempts: %s (%s)", rel, pf.attempts, res.status, res.detail)
}

func deref(s *string) string {
	if s == nil {
		return "?"
	}
	return *s
}

// StartWatcher creates the OS backend and starts watching root.
func StartWatcher(ctx context.Context, store *Store, root, thumbsDir string, settle time.Duration, onOverflow func()) (*Watcher, error) {
	b, err := newWatchBackend()
	if err != nil {
		return nil, fmt.Errorf("file watching unavailable: %w", err)
	}
	w := NewWatcher(store, root, thumbsDir, settle, b, os.Stderr)
	w.onOverflow = onOverflow
	w.Start(ctx)
	return w, nil
}
