//go:build linux

package main

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"unsafe"

	"golang.org/x/sys/unix"
)

// inotifyBackend watches individual directories with inotify (which is not
// recursive; Watcher adds every directory of the tree).
type inotifyBackend struct {
	f      *os.File
	events chan fsEvent

	mu    sync.Mutex
	paths map[int]string // watch descriptor -> directory
	wds   map[string]int
}

const inotifyMask = unix.IN_CREATE | unix.IN_CLOSE_WRITE | unix.IN_MODIFY | unix.IN_MOVED_FROM |
	unix.IN_MOVED_TO | unix.IN_DELETE | unix.IN_DELETE_SELF | unix.IN_ONLYDIR

func newWatchBackend() (watchBackend, error) {
	fd, err := unix.InotifyInit1(unix.IN_CLOEXEC | unix.IN_NONBLOCK)
	if err != nil {
		return nil, err
	}
	b := &inotifyBackend{
		// Non-blocking fd wrapped in os.File: reads park on Go's poller and
		// Close unblocks them.
		f:      os.NewFile(uintptr(fd), "inotify"),
		events: make(chan fsEvent, 4096),
		paths:  map[int]string{},
		wds:    map[string]int{},
	}
	go b.readLoop()
	return b, nil
}

func (b *inotifyBackend) Add(dir string) error {
	wd, err := unix.InotifyAddWatch(int(b.f.Fd()), dir, inotifyMask)
	if err != nil {
		if errors.Is(err, unix.ENOSPC) {
			return fmt.Errorf("%w (raise fs.inotify.max_user_watches, e.g. sysctl fs.inotify.max_user_watches=524288)", err)
		}
		return err
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	// The same directory reached via a second (symlinked) path returns the
	// same wd; keep the first path, the one the scanner also saw first.
	if _, ok := b.paths[wd]; !ok {
		b.paths[wd] = dir
		b.wds[dir] = wd
	}
	return nil
}

func (b *inotifyBackend) Rename(oldDir, newDir string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for wd, p := range b.paths {
		if p == oldDir || strings.HasPrefix(p, oldDir+string(filepath.Separator)) {
			np := newDir + p[len(oldDir):]
			delete(b.wds, p)
			b.paths[wd] = np
			b.wds[np] = wd
		}
	}
}

func (b *inotifyBackend) Events() <-chan fsEvent { return b.events }

func (b *inotifyBackend) Close() error { return b.f.Close() }

func (b *inotifyBackend) readLoop() {
	defer close(b.events)
	buf := make([]byte, 64<<10)
	for {
		n, err := b.f.Read(buf)
		if err != nil {
			return
		}
		for off := 0; off+unix.SizeofInotifyEvent <= n; {
			raw := (*unix.InotifyEvent)(unsafe.Pointer(&buf[off]))
			nameBytes := buf[off+unix.SizeofInotifyEvent : off+unix.SizeofInotifyEvent+int(raw.Len)]
			off += unix.SizeofInotifyEvent + int(raw.Len)
			name := string(bytes.TrimRight(nameBytes, "\x00"))
			b.dispatch(int(raw.Wd), raw.Mask, raw.Cookie, name)
		}
	}
}

func (b *inotifyBackend) dispatch(wd int, mask, cookie uint32, name string) {
	if mask&unix.IN_Q_OVERFLOW != 0 {
		b.events <- fsEvent{Op: opOverflow}
		return
	}
	b.mu.Lock()
	dir, ok := b.paths[wd]
	if mask&unix.IN_IGNORED != 0 { // watch removed (directory deleted)
		delete(b.paths, wd)
		delete(b.wds, dir)
	}
	b.mu.Unlock()
	if !ok || name == "" {
		return
	}
	ev := fsEvent{Path: filepath.Join(dir, name), IsDir: mask&unix.IN_ISDIR != 0, Cookie: cookie}
	switch {
	case mask&unix.IN_MOVED_FROM != 0:
		ev.Op = opMovedFrom
	case mask&unix.IN_MOVED_TO != 0:
		ev.Op = opMovedTo
	case mask&unix.IN_CREATE != 0:
		ev.Op = opCreate
	case mask&unix.IN_CLOSE_WRITE != 0:
		ev.Op = opCloseWrite
	case mask&unix.IN_MODIFY != 0:
		ev.Op = opWrite
	case mask&unix.IN_DELETE != 0:
		ev.Op = opDelete
	default:
		return
	}
	b.events <- ev
}

// openForWriting reports whether any process we can inspect has path open
// for writing, by scanning /proc/*/fd. Processes of other users are only
// visible when running as root (or the same user).
func openForWriting(path string) bool {
	real, err := filepath.EvalSymlinks(path)
	if err != nil {
		return false
	}
	procs, err := os.ReadDir("/proc")
	if err != nil {
		return false
	}
	for _, p := range procs {
		if _, err := strconv.Atoi(p.Name()); err != nil {
			continue
		}
		fdDir := "/proc/" + p.Name() + "/fd"
		fds, err := os.ReadDir(fdDir)
		if err != nil {
			continue
		}
		for _, fd := range fds {
			if link, err := os.Readlink(fdDir + "/" + fd.Name()); err != nil || link != real {
				continue
			}
			info, err := os.ReadFile("/proc/" + p.Name() + "/fdinfo/" + fd.Name())
			if err != nil {
				return true // can't tell how it's open: assume writing
			}
			for _, line := range strings.Split(string(info), "\n") {
				if v, ok := strings.CutPrefix(line, "flags:"); ok {
					flags, _ := strconv.ParseUint(strings.TrimSpace(v), 8, 64)
					if flags&(unix.O_WRONLY|unix.O_RDWR) != 0 {
						return true
					}
				}
			}
		}
	}
	return false
}
