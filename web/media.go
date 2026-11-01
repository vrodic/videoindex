package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// MediaService handles everything that touches the video files themselves:
// resolving paths under the root, thumbnail extraction (cached on disk) and
// streaming — either the file as-is or remuxed/transcoded on the fly.
type MediaService struct {
	root      string
	thumbsDir string

	thumbSem     chan struct{}
	transcodeSem chan struct{}

	mu       sync.Mutex
	inflight map[string]*thumbCall
}

type thumbCall struct {
	done chan struct{}
	err  error
}

func NewMediaService(root, thumbsDir string, thumbWorkers, transcodes int) *MediaService {
	if thumbWorkers < 1 {
		thumbWorkers = 1
	}
	if transcodes < 1 {
		transcodes = 1
	}
	return &MediaService{
		root:         root,
		thumbsDir:    thumbsDir,
		thumbSem:     make(chan struct{}, thumbWorkers),
		transcodeSem: make(chan struct{}, transcodes),
		inflight:     map[string]*thumbCall{},
	}
}

var errOutsideRoot = errors.New("path escapes media root")

// Path resolves a DB filename (relative to the root) to an absolute path,
// refusing anything that would land outside the root.
func (m *MediaService) Path(rel string) (string, error) {
	p := filepath.Join(m.root, filepath.FromSlash(rel))
	if p != m.root && !strings.HasPrefix(p, m.root+string(filepath.Separator)) {
		return "", errOutsideRoot
	}
	return p, nil
}

// --- Playback mode ------------------------------------------------------

// Browser-native containers and codecs. Anything else is remuxed (when only
// the container is the problem) or fully transcoded.
var (
	directExts   = map[string]bool{".mp4": true, ".m4v": true, ".mov": true, ".webm": true}
	directCodecs = map[string]bool{"h264": true, "hevc": true, "vp8": true, "vp9": true, "av1": true}
	remuxCodecs  = map[string]bool{"h264": true, "hevc": true}
)

// PlayMode returns the preferred way to deliver a file to a browser:
// "direct" (serve the file with range requests), "remux" (copy the video
// stream into fragmented MP4) or "transcode" (re-encode to H.264/AAC).
func PlayMode(filename, codec string) string {
	ext := strings.ToLower(filepath.Ext(filename))
	codec = strings.ToLower(codec)
	switch {
	case directExts[ext] && directCodecs[codec]:
		return "direct"
	case remuxCodecs[codec]:
		return "remux"
	default:
		return "transcode"
	}
}

// ServeDirect serves the file with Range support (seeking, partial loads).
func (m *MediaService) ServeDirect(w http.ResponseWriter, r *http.Request, rel string) {
	p, err := m.Path(rel)
	if err != nil {
		http.Error(w, err.Error(), http.StatusForbidden)
		return
	}
	f, err := os.Open(p)
	if err != nil {
		http.Error(w, "file not found", http.StatusNotFound)
		return
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil || st.IsDir() {
		http.Error(w, "file not found", http.StatusNotFound)
		return
	}
	if ct := directContentType(p); ct != "" {
		w.Header().Set("Content-Type", ct)
	}
	http.ServeContent(w, r, filepath.Base(p), st.ModTime(), f)
}

func directContentType(p string) string {
	switch strings.ToLower(filepath.Ext(p)) {
	case ".mp4", ".m4v":
		return "video/mp4"
	case ".mov":
		return "video/quicktime"
	case ".webm":
		return "video/webm"
	}
	return ""
}

// ServeStream pipes the file through ffmpeg as fragmented MP4 starting at
// `start` seconds. mode "remux" copies the video stream, anything else
// re-encodes it. Audio is always re-encoded to AAC (cheap, and covers
// WMA/AC3/MP2/... that browsers won't play). The ffmpeg process is killed
// as soon as the client disconnects (e.g. seeks, which restarts the stream).
func (m *MediaService) ServeStream(w http.ResponseWriter, r *http.Request, file *MediaFile, mode string, start float64) {
	p, err := m.Path(file.Filename)
	if err != nil {
		http.Error(w, err.Error(), http.StatusForbidden)
		return
	}
	if _, err := os.Stat(p); err != nil {
		http.Error(w, "file not found", http.StatusNotFound)
		return
	}

	select {
	case m.transcodeSem <- struct{}{}:
		defer func() { <-m.transcodeSem }()
	case <-r.Context().Done():
		return
	case <-time.After(5 * time.Second):
		http.Error(w, "too many concurrent transcodes", http.StatusServiceUnavailable)
		return
	}

	args := []string{"-hide_banner", "-nostdin", "-loglevel", "error"}
	if start > 0 {
		args = append(args, "-ss", strconv.FormatFloat(start, 'f', 3, 64))
	}
	args = append(args, "-i", p, "-map", "0:v:0", "-map", "0:a:0?", "-sn", "-dn")
	if mode == "remux" {
		args = append(args, "-c:v", "copy")
		if strings.EqualFold(file.Codec, "hevc") {
			args = append(args, "-tag:v", "hvc1")
		}
	} else {
		args = append(args,
			"-c:v", "libx264", "-preset", "veryfast", "-crf", "22",
			"-pix_fmt", "yuv420p",
			// cap at 1080p, keep even dimensions
			"-vf", "scale='min(1920,iw)':-2",
			"-g", "60")
	}
	args = append(args,
		"-c:a", "aac", "-b:a", "160k", "-ac", "2",
		"-movflags", "frag_keyframe+empty_moov+default_base_moof",
		"-f", "mp4", "pipe:1")

	cmd := exec.CommandContext(r.Context(), "ffmpeg", args...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if err := cmd.Start(); err != nil {
		http.Error(w, "ffmpeg: "+err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "video/mp4")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Duration", strconv.FormatFloat(file.Duration-start, 'f', 3, 64))
	n, _ := io.Copy(flushWriter{w}, stdout)
	err = cmd.Wait()
	if err != nil && r.Context().Err() == nil {
		log.Printf("stream %d (%s) failed after %d bytes: %v %s", file.ID, mode, n, err, strings.TrimSpace(stderr.String()))
	}
}

// flushWriter flushes after every write so the browser gets the fragmented
// MP4 as it is produced instead of when the buffer fills.
type flushWriter struct{ w http.ResponseWriter }

func (f flushWriter) Write(p []byte) (int, error) {
	n, err := f.w.Write(p)
	if fl, ok := f.w.(http.Flusher); ok {
		fl.Flush()
	}
	return n, err
}

// --- Thumbnails ---------------------------------------------------------

// ThumbPath is the on-disk cache location, <thumbs>/<id>_<percent>.jpg —
// the same layout the macOS app used, so its cache is reused as-is.
func (m *MediaService) ThumbPath(id int64, percent int) string {
	return filepath.Join(m.thumbsDir, fmt.Sprintf("%d_%d.jpg", id, percent))
}

var errMissingFile = errors.New("video file missing")

// Thumbnail returns the path of the cached JPEG for (file, percent),
// extracting it with ffmpeg first if needed. Concurrent requests for the
// same frame share one ffmpeg run; at most thumbWorkers run at once.
func (m *MediaService) Thumbnail(ctx context.Context, file *MediaFile, percent int) (string, error) {
	out := m.ThumbPath(file.ID, percent)
	if _, err := os.Stat(out); err == nil {
		return out, nil
	}

	m.mu.Lock()
	call, ok := m.inflight[out]
	if !ok {
		call = &thumbCall{done: make(chan struct{})}
		m.inflight[out] = call
	}
	m.mu.Unlock()

	if ok {
		select {
		case <-call.done:
			return out, call.err
		case <-ctx.Done():
			return "", ctx.Err()
		}
	}

	finish := func(err error) (string, error) {
		call.err = err
		m.mu.Lock()
		delete(m.inflight, out)
		m.mu.Unlock()
		close(call.done)
		return out, err
	}

	// Wait for a worker slot, but give up if the browser no longer wants
	// the image (selection moved on). Once ffmpeg starts it runs to
	// completion so the result lands in the cache either way.
	select {
	case m.thumbSem <- struct{}{}:
	case <-ctx.Done():
		return finish(ctx.Err())
	}
	defer func() { <-m.thumbSem }()

	src, err := m.Path(file.Filename)
	if err != nil {
		return finish(err)
	}
	if _, err := os.Stat(src); err != nil {
		return finish(errMissingFile)
	}
	dur := file.Duration
	if dur <= 0 {
		dur = probeDuration(src)
	}
	if dur <= 0 {
		return finish(errors.New("unknown duration"))
	}
	if err := os.MkdirAll(m.thumbsDir, 0o755); err != nil {
		return finish(err)
	}
	return finish(extractFrame(src, out, dur*float64(percent)/100))
}

func extractFrame(src, out string, at float64) error {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	tmp := out + ".tmp.jpg"
	cmd := exec.CommandContext(ctx, "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error",
		"-ss", strconv.FormatFloat(at, 'f', 3, 64), "-i", src,
		"-frames:v", "1", "-vf", "scale='min(960,iw)':-2", "-q:v", "4", "-y", tmp)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("ffmpeg: %v %s", err, strings.TrimSpace(stderr.String()))
	}
	if st, err := os.Stat(tmp); err != nil || st.Size() == 0 {
		os.Remove(tmp)
		return errors.New("ffmpeg produced no frame")
	}
	return os.Rename(tmp, out)
}

func probeDuration(path string) float64 {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "ffprobe", "-v", "error", "-show_entries", "format=duration",
		"-of", "default=noprint_wrappers=1:nokey=1", path).Output()
	if err != nil {
		return 0
	}
	d, _ := strconv.ParseFloat(strings.TrimSpace(string(out)), 64)
	return d
}

// RemoveThumbs deletes every cached thumbnail of a media id.
func (m *MediaService) RemoveThumbs(id int64) {
	matches, _ := filepath.Glob(filepath.Join(m.thumbsDir, fmt.Sprintf("%d_*.jpg", id)))
	for _, p := range matches {
		os.Remove(p)
	}
}
