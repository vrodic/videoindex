package main

import (
	"compress/gzip"
	"crypto/subtle"
	"embed"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"unicode"
	"unicode/utf8"
)

//go:embed static
var staticFS embed.FS

type App struct {
	Root        string
	DBPath      string
	Store       *Store
	Media       *MediaService
	AllowDelete bool
	Watcher     *Watcher

	scanMu  sync.Mutex
	scan    *Scanner
	scanLog *ringLog
	scanErr string
	scanRun bool
}

func (a *App) Routes() http.Handler {
	mux := http.NewServeMux()
	static, _ := fs.Sub(staticFS, "static")
	mux.Handle("GET /", http.FileServerFS(static))

	mux.HandleFunc("GET /api/config", a.handleConfig)
	mux.HandleFunc("GET /api/items", a.handleItems)
	mux.HandleFunc("GET /api/media/{id}", a.handleItem)
	mux.HandleFunc("POST /api/media/{id}/viewed", a.handleViewed)
	mux.HandleFunc("POST /api/media/{id}/like", a.handleLike)
	mux.HandleFunc("POST /api/media/{id}/dislike", a.handleDislike)
	mux.HandleFunc("GET /api/media/{id}/thumb/{pct}", a.handleThumb)
	mux.HandleFunc("GET /api/media/{id}/file", a.handleFile)
	mux.HandleFunc("GET /api/media/{id}/stream", a.handleStream)
	mux.HandleFunc("GET /api/media/{id}/keyframe", a.handleKeyframe)
	mux.HandleFunc("GET /api/media/{id}/actors", a.handleMediaActors)
	mux.HandleFunc("POST /api/media/{id}/actors", a.handleAddMediaActor)
	mux.HandleFunc("DELETE /api/media/{id}/actors/{actor}", a.handleRemoveMediaActor)
	mux.HandleFunc("GET /api/actors", a.handleActors)
	mux.HandleFunc("POST /api/actors", a.handleCreateActor)
	mux.HandleFunc("PATCH /api/actors/{id}", a.handleUpdateActor)
	mux.HandleFunc("POST /api/actors/{id}/assign", a.handleAssignActor)
	mux.HandleFunc("GET /api/words", a.handleWords)
	mux.HandleFunc("GET /api/dashboard", a.handleDashboard)
	mux.HandleFunc("GET /api/scan", a.handleScanStatus)
	mux.HandleFunc("POST /api/scan", a.handleScanStart)
	return gzipMiddleware(mux)
}

// --- helpers --------------------------------------------------------------

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, status int, err error) {
	writeJSON(w, status, map[string]string{"error": err.Error()})
}

func pathID(r *http.Request, name string) (int64, error) {
	return strconv.ParseInt(r.PathValue(name), 10, 64)
}

func (a *App) mediaFromPath(w http.ResponseWriter, r *http.Request) *MediaFile {
	id, err := pathID(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return nil
	}
	m, err := a.Store.GetMedia(r.Context(), id)
	if err != nil {
		writeErr(w, http.StatusNotFound, errors.New("no such media"))
		return nil
	}
	return m
}

func decodeBody(r *http.Request, v any) error {
	return json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(v)
}

// --- handlers -------------------------------------------------------------

func (a *App) handleConfig(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"allowDelete": a.AllowDelete,
		"rootDir":     a.Root,
	})
}

type itemOut struct {
	MediaItem
	Play string `json:"play"`
}

func newItemOut(it MediaItem) itemOut {
	codec := ""
	if it.Codec != nil {
		codec = *it.Codec
	}
	return itemOut{it, PlayMode(it.Filename, codec)}
}

func (a *App) handleItem(w http.ResponseWriter, r *http.Request) {
	id, err := pathID(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	it, err := a.Store.GetItem(r.Context(), id)
	if err != nil {
		writeErr(w, http.StatusNotFound, errors.New("no such media"))
		return
	}
	writeJSON(w, http.StatusOK, newItemOut(*it))
}

func (a *App) handleItems(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	items, err := a.Store.LoadItems(r.Context(), q.Get("search"), q.Get("cond"))
	if err != nil {
		// Shown in the status line, like the macOS app did.
		writeJSON(w, http.StatusOK, map[string]any{"items": []any{}, "error": err.Error()})
		return
	}
	out := make([]itemOut, len(items))
	for i, it := range items {
		out[i] = newItemOut(it)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": out})
}

func (a *App) handleViewed(w http.ResponseWriter, r *http.Request) {
	id, err := pathID(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	views, viewed, err := a.Store.MarkViewed(r.Context(), id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"views": views, "viewed": viewed})
}

func (a *App) handleLike(w http.ResponseWriter, r *http.Request) {
	id, err := pathID(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	like, err := a.Store.AdjustLike(r.Context(), id, 1)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"like": like})
}

// handleDislike records a dislike and, once the like value has dropped
// below -1 (i.e. on the second press for an unrated file), deletes the
// file from disk and the database — same guard as the original tool.
func (a *App) handleDislike(w http.ResponseWriter, r *http.Request) {
	m := a.mediaFromPath(w, r)
	if m == nil {
		return
	}
	like, err := a.Store.AdjustLike(r.Context(), m.ID, -1)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	resp := map[string]any{"like": like, "deleted": false}
	if like < -1 && a.AllowDelete {
		if p, err := a.Media.Path(m.Filename); err == nil {
			if err := os.Remove(p); err != nil && !errors.Is(err, os.ErrNotExist) {
				writeErr(w, http.StatusInternalServerError, err)
				return
			}
		}
		if err := a.Store.DeleteMedia(r.Context(), m.ID); err != nil {
			writeErr(w, http.StatusInternalServerError, err)
			return
		}
		a.Media.RemoveThumbs(m.ID)
		log.Printf("deleted %d %s", m.ID, m.Filename)
		resp["deleted"] = true
	}
	writeJSON(w, http.StatusOK, resp)
}

func (a *App) handleThumb(w http.ResponseWriter, r *http.Request) {
	pct, err := strconv.Atoi(strings.TrimSuffix(r.PathValue("pct"), ".jpg"))
	if err != nil || pct < 0 || pct > 100 {
		http.Error(w, "bad percent", http.StatusBadRequest)
		return
	}
	m := a.mediaFromPath(w, r)
	if m == nil {
		return
	}
	p, err := a.Media.Thumbnail(r.Context(), m, pct)
	if err != nil {
		if errors.Is(err, errMissingFile) {
			w.Header().Set("X-Missing", "1")
			http.Error(w, err.Error(), http.StatusNotFound)
			return
		}
		if r.Context().Err() == nil {
			log.Printf("thumb %d@%d%%: %v", m.ID, pct, err)
		}
		http.Error(w, err.Error(), http.StatusUnprocessableEntity)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	http.ServeFile(w, r, p)
}

func (a *App) handleFile(w http.ResponseWriter, r *http.Request) {
	m := a.mediaFromPath(w, r)
	if m == nil {
		return
	}
	a.Media.ServeDirect(w, r, m.Filename)
}

func (a *App) handleStream(w http.ResponseWriter, r *http.Request) {
	m := a.mediaFromPath(w, r)
	if m == nil {
		return
	}
	start, _ := strconv.ParseFloat(r.URL.Query().Get("start"), 64)
	if start < 0 {
		start = 0
	}
	a.Media.ServeStream(w, r, m, r.URL.Query().Get("mode"), start)
}

func (a *App) handleKeyframe(w http.ResponseWriter, r *http.Request) {
	m := a.mediaFromPath(w, r)
	if m == nil {
		return
	}
	t, _ := strconv.ParseFloat(r.URL.Query().Get("t"), 64)
	writeJSON(w, http.StatusOK, map[string]float64{"t": a.Media.KeyframeBefore(r.Context(), m, t)})
}

func (a *App) handleMediaActors(w http.ResponseWriter, r *http.Request) {
	id, err := pathID(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	actors, err := a.Store.ActorsForMedia(r.Context(), id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, actors)
}

func (a *App) handleAddMediaActor(w http.ResponseWriter, r *http.Request) {
	id, err := pathID(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	var body struct{ Name string }
	if err := decodeBody(r, &body); err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	actor, err := a.Store.AddOrGetActor(r.Context(), body.Name)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	if err := a.Store.AssignActor(r.Context(), actor.ID, []int64{id}); err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, actor)
}

func (a *App) handleRemoveMediaActor(w http.ResponseWriter, r *http.Request) {
	id, err1 := pathID(r, "id")
	actor, err2 := pathID(r, "actor")
	if err := errors.Join(err1, err2); err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	if err := a.Store.RemoveActorFromMedia(r.Context(), actor, id); err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (a *App) handleActors(w http.ResponseWriter, r *http.Request) {
	actors, err := a.Store.AllActors(r.Context())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, actors)
}

func (a *App) handleCreateActor(w http.ResponseWriter, r *http.Request) {
	var body struct{ Name string }
	if err := decodeBody(r, &body); err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	actor, err := a.Store.AddOrGetActor(r.Context(), body.Name)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	writeJSON(w, http.StatusOK, actor)
}

func (a *App) handleUpdateActor(w http.ResponseWriter, r *http.Request) {
	id, err := pathID(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	var body struct {
		Name     *string `json:"name"`
		AltNames *string `json:"altNames"`
	}
	if err := decodeBody(r, &body); err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	if err := a.Store.UpdateActor(r.Context(), id, body.Name, body.AltNames); err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (a *App) handleAssignActor(w http.ResponseWriter, r *http.Request) {
	id, err := pathID(r, "id")
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	var body struct {
		MediaIDs []int64 `json:"mediaIds"`
	}
	if err := decodeBody(r, &body); err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	if err := a.Store.AssignActor(r.Context(), id, body.MediaIDs); err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// --- word cloud -----------------------------------------------------------

var stopWords = func() map[string]bool {
	m := map[string]bool{}
	for _, w := range strings.Fields(`mp4 mkv avi wmv mov flv webm mpg mpeg m4v ts 3gp vob divx xvid zip rar jpg jpeg png
		the and web videos 1080p 720p com with source video art aac siterip xxx clips pack 1080 h265 x264 rip
		split all 1280 720 avc collection apr vip sep aug jul 264 6000 full partial 30fps 60fps like net dvdrip
		x265 vid 265 you jun 2160p 3x7z0p 2600 jan combined first hevc fullcomplete has one this more 720hd
		aac2 part h264 vol from img dvd get b9r your mixed mvi`) {
		m[w] = true
	}
	return m
}()

func filenameWords(name string) []string {
	return strings.FieldsFunc(name, func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsDigit(r) && !unicode.IsMark(r) })
}

func (a *App) handleWords(w http.ResponseWriter, r *http.Request) {
	names, err := a.Store.AllFilenames(r.Context())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	words, pairs := map[string]int{}, map[string]int{}
	for _, fn := range names {
		uniq := map[string]bool{}
		var valid []string
		for _, raw := range filenameWords(fn) {
			word := strings.ToLower(raw)
			if utf8.RuneCountInString(word) <= 2 || stopWords[word] {
				continue
			}
			uniq[word] = true
			if _, err := strconv.ParseFloat(word, 64); err != nil { // pure numbers don't make names
				valid = append(valid, word)
			}
		}
		for word := range uniq {
			words[word]++
		}
		uniqPairs := map[string]bool{}
		for i := 0; i+1 < len(valid); i++ {
			uniqPairs[valid[i]+"_"+valid[i+1]] = true
		}
		for p := range uniqPairs {
			pairs[p]++
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"words": sortWordCounts(words), "names": sortWordCounts(pairs)})
}

// --- scanning from the UI -------------------------------------------------

// ringLog keeps the tail of the scanner's output for the UI.
type ringLog struct {
	mu  sync.Mutex
	buf []byte
	max int
}

func (l *ringLog) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.buf = append(l.buf, p...)
	if len(l.buf) > l.max {
		l.buf = l.buf[len(l.buf)-l.max:]
	}
	return len(p), nil
}

func (l *ringLog) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return string(l.buf)
}

func (a *App) handleScanStart(w http.ResponseWriter, r *http.Request) {
	var body struct {
		RescanSkipped bool `json:"rescanSkipped"`
		Workers       int  `json:"workers"`
	}
	decodeBody(r, &body)
	if body.Workers <= 0 {
		body.Workers = 8
	}
	if err := a.startScan(body.RescanSkipped, body.Workers); err != nil {
		writeErr(w, http.StatusConflict, err)
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]bool{"ok": true})
}

// startScan runs a full scan in the background (from the UI, or when the
// watcher missed events).
func (a *App) startScan(rescanSkipped bool, workers int) error {
	a.scanMu.Lock()
	defer a.scanMu.Unlock()
	if a.scanRun {
		return errors.New("a scan is already running")
	}
	a.scanLog = &ringLog{max: 256 << 10}
	a.scan = NewScanner(a.Store, a.Root, rescanSkipped, workers, a.scanLog)
	a.scanRun, a.scanErr = true, ""
	go func(s *Scanner) {
		err := s.Run()
		a.scanMu.Lock()
		defer a.scanMu.Unlock()
		a.scanRun = false
		if err != nil {
			a.scanErr = err.Error()
			log.Printf("scan failed: %v", err)
		}
	}(a.scan)
	return nil
}

func (a *App) handleScanStatus(w http.ResponseWriter, r *http.Request) {
	a.scanMu.Lock()
	defer a.scanMu.Unlock()
	resp := map[string]any{"running": a.scanRun, "error": a.scanErr}
	if a.scan != nil {
		done, total := a.scan.Progress()
		resp["done"], resp["total"] = done, total
		resp["log"] = a.scanLog.String()
	}
	if a.Watcher != nil {
		resp["watch"] = a.Watcher.Status()
	}
	writeJSON(w, http.StatusOK, resp)
}

// --- middleware -----------------------------------------------------------

type gzipResponseWriter struct {
	http.ResponseWriter
	gz *gzip.Writer
}

func (g gzipResponseWriter) Write(p []byte) (int, error) { return g.gz.Write(p) }

func (g gzipResponseWriter) WriteHeader(status int) {
	g.Header().Del("Content-Length")
	g.ResponseWriter.WriteHeader(status)
}

// gzipMiddleware compresses JSON/HTML/JS/CSS responses (the item list for
// a large library is a few MB of JSON); video and images pass through.
func gzipMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		compressible := !strings.Contains(r.URL.Path, "/thumb/") &&
			!strings.HasSuffix(r.URL.Path, "/file") && !strings.HasSuffix(r.URL.Path, "/stream")
		if !compressible || !strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") {
			next.ServeHTTP(w, r)
			return
		}
		w.Header().Set("Content-Encoding", "gzip")
		w.Header().Add("Vary", "Accept-Encoding")
		gz := gzip.NewWriter(w)
		defer gz.Close()
		next.ServeHTTP(gzipResponseWriter{w, gz}, r)
	})
}

func basicAuth(cred string, next http.Handler) http.Handler {
	user, pass, _ := strings.Cut(cred, ":")
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		u, p, ok := r.BasicAuth()
		if !ok || subtle.ConstantTimeCompare([]byte(u), []byte(user)) != 1 ||
			subtle.ConstantTimeCompare([]byte(p), []byte(pass)) != 1 {
			w.Header().Set("WWW-Authenticate", `Basic realm="videoindex"`)
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	})
}
