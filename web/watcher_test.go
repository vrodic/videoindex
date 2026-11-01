package main

import (
	"context"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// fakeBackend lets tests inject the events inotify would deliver.
type fakeBackend struct {
	ch      chan fsEvent
	mu      sync.Mutex
	added   []string
	renamed [][2]string
}

func (f *fakeBackend) Add(dir string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.added = append(f.added, dir)
	return nil
}
func (f *fakeBackend) Rename(o, n string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.renamed = append(f.renamed, [2]string{o, n})
}
func (f *fakeBackend) Events() <-chan fsEvent { return f.ch }
func (f *fakeBackend) Close() error           { return nil }

type watchEnv struct {
	t     *testing.T
	root  string
	store *Store
	fb    *fakeBackend
	w     *Watcher
	clip  []byte
}

const testSettle = 300 * time.Millisecond

func newWatchEnv(t *testing.T) *watchEnv {
	if _, err := exec.LookPath("ffmpeg"); err != nil {
		t.Skip("ffmpeg not installed")
	}
	dir := t.TempDir()
	root := filepath.Join(dir, "root")
	os.MkdirAll(root, 0o755)
	clipPath := filepath.Join(dir, "clip.mp4")
	if out, err := exec.Command("ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc=size=160x120:rate=25",
		"-t", "2", "-c:v", "libx264", clipPath).CombinedOutput(); err != nil {
		t.Fatalf("ffmpeg: %v %s", err, out)
	}
	clip, _ := os.ReadFile(clipPath)
	store, err := OpenStore(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(store.Close)
	fb := &fakeBackend{ch: make(chan fsEvent, 100)}
	w := NewWatcher(store, root, filepath.Join(root, "Thumbs"), testSettle, fb, io.Discard)
	w.tickEvery = 50 * time.Millisecond
	w.maxAttempts = 2
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	w.Start(ctx)
	return &watchEnv{t: t, root: root, store: store, fb: fb, w: w, clip: clip}
}

func (e *watchEnv) path(rel string) string { return filepath.Join(e.root, filepath.FromSlash(rel)) }

func (e *watchEnv) send(op fsOp, rel string, isDir bool, cookie uint32) {
	e.fb.ch <- fsEvent{Path: e.path(rel), Op: op, IsDir: isDir, Cookie: cookie}
}

func (e *watchEnv) writeClip(rel string) {
	os.MkdirAll(filepath.Dir(e.path(rel)), 0o755)
	if err := os.WriteFile(e.path(rel), e.clip, 0o644); err != nil {
		e.t.Fatal(err)
	}
}

func (e *watchEnv) waitFor(what string, timeout time.Duration, cond func() bool) {
	e.t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	e.t.Fatalf("timed out waiting for %s\nwatcher log:\n%s", what, e.w.Log.String())
}

func (e *watchEnv) never(what string, d time.Duration, cond func() bool) {
	e.t.Helper()
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if cond() {
			e.t.Fatalf("unexpectedly %s\nwatcher log:\n%s", what, e.w.Log.String())
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func (e *watchEnv) count(q string, args ...any) int {
	var n int
	if err := e.store.rw.QueryRow(q, args...).Scan(&n); err != nil {
		e.t.Fatal(err)
	}
	return n
}

func TestWatcherPartialDownloadRenamedWhenDone(t *testing.T) {
	e := newWatchEnv(t)
	// A browser-style download: written as .part, renamed when complete.
	e.writeClip("dl/movie.mp4.part")
	e.send(opCreate, "dl/movie.mp4.part", false, 0)
	e.send(opCloseWrite, "dl/movie.mp4.part", false, 0)
	e.never("indexed the .part file", 2*testSettle, func() bool { return e.count(`SELECT COUNT(*) FROM media`) > 0 })

	os.Rename(e.path("dl/movie.mp4.part"), e.path("dl/movie.mp4"))
	e.send(opMovedFrom, "dl/movie.mp4.part", false, 7)
	e.send(opMovedTo, "dl/movie.mp4", false, 7)
	// Not before the settle period has passed...
	e.never("indexed before settling", testSettle/2, func() bool { return e.w.store.HasMedia("dl/movie.mp4") })
	// ...but soon after.
	e.waitFor("movie.mp4 indexed", 5*time.Second, func() bool { return e.w.store.HasMedia("dl/movie.mp4") })
	if n := e.count(`SELECT COUNT(*) FROM media`); n != 1 {
		t.Fatalf("want 1 row, got %d", n)
	}
	if n := e.count(`SELECT COUNT(*) FROM media WHERE filename='dl/movie.mp4' AND width=160 AND height=120 AND codec_name='h264'`); n != 1 {
		t.Fatal("probe metadata not stored")
	}
}

func TestWatcherWaitsWhileFileKeepsGrowing(t *testing.T) {
	e := newWatchEnv(t)
	p := e.path("slow.mp4")
	f, _ := os.Create(p)
	e.send(opCreate, "slow.mp4", false, 0)
	// Trickle the file in over ~1.5s (5 settle periods), with write events.
	chunk := len(e.clip)/15 + 1
	for off := 0; off < len(e.clip); off += chunk {
		end := min(off+chunk, len(e.clip))
		f.Write(e.clip[off:end])
		e.send(opWrite, "slow.mp4", false, 0)
		if e.w.store.HasMedia("slow.mp4") {
			t.Fatal("indexed while still being written")
		}
		time.Sleep(100 * time.Millisecond)
	}
	f.Close()
	e.send(opCloseWrite, "slow.mp4", false, 0)
	e.waitFor("slow.mp4 indexed", 5*time.Second, func() bool { return e.w.store.HasMedia("slow.mp4") })
}

func TestWatcherWaitsForWriterToClose(t *testing.T) {
	e := newWatchEnv(t)
	var held atomic.Bool
	held.Store(true)
	e.w.mu.Lock()
	e.w.openForWrit = func(string) bool { return held.Load() }
	e.w.mu.Unlock()
	// A torrent client: full size on disk, but still open for writing.
	e.writeClip("held.mp4")
	e.send(opCloseWrite, "held.mp4", false, 0)
	e.never("indexed a file still open for writing", 4*testSettle, func() bool { return e.w.store.HasMedia("held.mp4") })
	held.Store(false)
	e.waitFor("held.mp4 indexed", 5*time.Second, func() bool { return e.w.store.HasMedia("held.mp4") })
}

func TestWatcherWaitsForDownloadSidecar(t *testing.T) {
	e := newWatchEnv(t)
	e.writeClip("aria.mp4")
	os.WriteFile(e.path("aria.mp4.aria2"), []byte("x"), 0o644)
	e.send(opCloseWrite, "aria.mp4", false, 0)
	e.never("indexed while aria2 control file exists", 4*testSettle, func() bool { return e.w.store.HasMedia("aria.mp4") })
	os.Remove(e.path("aria.mp4.aria2"))
	e.waitFor("aria.mp4 indexed", 5*time.Second, func() bool { return e.w.store.HasMedia("aria.mp4") })
}

func TestWatcherRenamesKeepRows(t *testing.T) {
	e := newWatchEnv(t)
	e.writeClip("in/a.mp4")
	e.send(opCreate, "in", true, 0) // new directory, file already inside
	e.waitFor("in/a.mp4 indexed", 5*time.Second, func() bool { return e.w.store.HasMedia("in/a.mp4") })
	e.store.rw.Exec(`UPDATE media SET like = 5 WHERE filename = 'in/a.mp4'`)

	// File rename inside the library keeps the row (and its like).
	os.Rename(e.path("in/a.mp4"), e.path("in/b.mp4"))
	e.send(opMovedFrom, "in/a.mp4", false, 1)
	e.send(opMovedTo, "in/b.mp4", false, 1)
	e.waitFor("row renamed", 2*time.Second, func() bool { return e.w.store.HasMedia("in/b.mp4") })

	// Directory rename rewrites the prefix of every row below it.
	os.Rename(e.path("in"), e.path("out dir"))
	e.send(opMovedFrom, "in", true, 2)
	e.send(opMovedTo, "out dir", true, 2)
	e.waitFor("dir renamed", 2*time.Second, func() bool { return e.w.store.HasMedia("out dir/b.mp4") })
	time.Sleep(3 * testSettle)
	if n := e.count(`SELECT COUNT(*) FROM media`); n != 1 {
		t.Fatalf("want 1 row after renames, got %d\n%s", n, e.w.Log.String())
	}
	if n := e.count(`SELECT like FROM media WHERE filename = 'out dir/b.mp4'`); n != 5 {
		t.Fatalf("like lost in rename: %d", n)
	}
	e.fb.mu.Lock()
	defer e.fb.mu.Unlock()
	if len(e.fb.renamed) != 1 || len(e.fb.added) < 2 {
		t.Fatalf("backend not updated: added=%v renamed=%v", e.fb.added, e.fb.renamed)
	}
}

func TestWatcherBrokenFileRetriedThenSkipped(t *testing.T) {
	e := newWatchEnv(t)
	os.WriteFile(e.path("bad.mkv"), []byte("not a video"), 0o644)
	e.send(opCloseWrite, "bad.mkv", false, 0)
	e.waitFor("bad.mkv in skipped_files", 10*time.Second, func() bool {
		return e.count(`SELECT COUNT(*) FROM skipped_files WHERE filename = 'bad.mkv' AND reason = 'probe_error'`) == 1
	})
	if e.w.store.HasMedia("bad.mkv") {
		t.Fatal("broken file indexed")
	}
}

func TestWatcherIgnoresThumbsAndNonVideo(t *testing.T) {
	e := newWatchEnv(t)
	e.writeClip("Thumbs/1_45.mp4")
	os.WriteFile(e.path("cover.jpg"), []byte("x"), 0o644)
	e.send(opCloseWrite, "Thumbs/1_45.mp4", false, 0)
	e.send(opCloseWrite, "cover.jpg", false, 0)
	e.never("indexed an ignored file", 4*testSettle, func() bool { return e.count(`SELECT COUNT(*) FROM media`) > 0 })
}
