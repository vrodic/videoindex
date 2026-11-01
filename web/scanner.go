package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Scanner walks the media root, probes files it hasn't seen with ffprobe
// and stores their metadata in the media table. Files that can't be probed
// (or have no width/height/duration) go into skipped_files and are not
// probed again unless rescanSkipped is set.
type Scanner struct {
	store         *Store
	root          string
	rescanSkipped bool
	workers       int
	out           io.Writer

	// Counters, reported at the end.
	SkippedExt, AlreadyScanned, AlreadySkipped int
	Added, Recovered                           int
	ProbeErrors, NoDims, MetadataErrors        int
	ToProbe, Done                              int

	mu sync.Mutex // guards Done/ToProbe for concurrent progress readers
}

var skipExt = map[string]bool{
	".jpg": true, ".gif": true, ".jpeg": true, ".nfo": true, ".png": true, ".srt": true,
	".zip": true, ".rar": true, ".vtx": true, ".parts": true, ".mp3": true, ".txt": true,
	".wma": true, ".ogg": true, ".mp2": true, ".ini": true, ".webp": true,
}

const (
	scanBatchSize = 200              // rows per commit
	probeTimeout  = 60 * time.Second // per file
)

func NewScanner(store *Store, root string, rescanSkipped bool, workers int, out io.Writer) *Scanner {
	if workers < 1 {
		workers = 1
	}
	return &Scanner{store: store, root: root, rescanSkipped: rescanSkipped, workers: workers, out: out}
}

func (s *Scanner) Progress() (done, total int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.Done, s.ToProbe
}

type scanJob struct{ rel, path string }

type scanResult struct {
	job    scanJob
	row    *mediaRow
	status string // ok, probe_error, no_width_or_duration, metadata_error
	detail string
}

type mediaRow struct {
	filename     string
	duration     float64
	codec        *string
	width        int64
	height       int64
	nbFrames     *int64
	creationTime *string
	fileSize     int64
}

// collect is the cheap pass: walk the tree and decide what needs probing.
func (s *Scanner) collect(known, skipped map[string]bool) ([]scanJob, error) {
	var todo []scanJob
	thumbsDir := filepath.Join(s.root, "Thumbs")
	err := walkFollow(s.root, nil, func(path string) {
		if path == thumbsDir || strings.HasPrefix(path, thumbsDir+string(filepath.Separator)) {
			return
		}
		if skipExt[strings.ToLower(filepath.Ext(path))] {
			s.SkippedExt++
			return
		}
		rel, err := filepath.Rel(s.root, path)
		if err != nil {
			return
		}
		rel = filepath.ToSlash(rel)
		if known[rel] {
			s.AlreadyScanned++
			return
		}
		if skipped[rel] && !s.rescanSkipped {
			s.AlreadySkipped++
			return
		}
		todo = append(todo, scanJob{rel, path})
	})
	return todo, err
}

// walkFollow calls fn for every regular file under root, following
// symlinked directories like os.walk(followlinks=True) — so a directory
// reachable through two paths is visited under both, exactly as the Python
// scanner did and as existing rows expect. Only a directory that is its own
// ancestor (a symlink loop) is skipped. onDir, if set, is called for each
// directory before it is read; returning false skips it.
func walkFollow(root string, onDir func(dir string) bool, fn func(path string)) error {
	if _, err := os.Stat(root); err != nil {
		return err
	}
	var walk func(dir string, ancestors map[string]bool)
	walk = func(dir string, ancestors map[string]bool) {
		real, err := filepath.EvalSymlinks(dir)
		if err != nil || ancestors[real] {
			return
		}
		if onDir != nil && !onDir(dir) {
			return
		}
		ancestors[real] = true
		defer delete(ancestors, real)
		entries, err := os.ReadDir(dir)
		if err != nil {
			return
		}
		for _, e := range entries {
			p := filepath.Join(dir, e.Name())
			mode := e.Type()
			if mode&os.ModeSymlink != 0 {
				st, err := os.Stat(p)
				if err != nil {
					continue
				}
				mode = st.Mode().Type()
			}
			switch {
			case mode.IsDir():
				walk(p, ancestors)
			case mode.IsRegular():
				fn(p)
			}
		}
	}
	walk(root, map[string]bool{})
	return nil
}

func (s *Scanner) loadSets() (known, skipped map[string]bool, err error) {
	known, skipped = map[string]bool{}, map[string]bool{}
	for q, m := range map[string]map[string]bool{
		`SELECT filename FROM media`:         known,
		`SELECT filename FROM skipped_files`: skipped,
	} {
		rows, err := s.store.rw.Query(q)
		if err != nil {
			return nil, nil, err
		}
		for rows.Next() {
			var f *string
			if err := rows.Scan(&f); err != nil {
				rows.Close()
				return nil, nil, err
			}
			if f != nil {
				m[*f] = true
			}
		}
		rows.Close()
	}
	return known, skipped, nil
}

func (s *Scanner) printf(format string, args ...any) {
	fmt.Fprintf(s.out, format, args...)
}

func (s *Scanner) Run() error {
	known, skipped, err := s.loadSets()
	if err != nil {
		return err
	}
	todo, err := s.collect(known, skipped)
	if err != nil {
		return err
	}
	s.mu.Lock()
	s.ToProbe = len(todo)
	s.mu.Unlock()
	mode := ""
	if s.rescanSkipped {
		mode = " (rescanning previously skipped files)"
	}
	s.printf("%d files to probe%s\n", len(todo), mode)

	jobs := make(chan scanJob)
	results := make(chan scanResult)
	var wg sync.WaitGroup
	for range s.workers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := range jobs {
				results <- extract(j)
			}
		}()
	}
	go func() {
		for _, j := range todo {
			jobs <- j
		}
		close(jobs)
		wg.Wait()
		close(results)
	}()

	var batch []mediaRow
	var skippedBatch [][3]string
	var failedProbe, noDims, metaErrors [][2]string

	flush := func() error {
		if err := s.flush(batch, skippedBatch, skipped); err != nil {
			return err
		}
		batch, skippedBatch = nil, nil
		return nil
	}

	for r := range results {
		s.mu.Lock()
		s.Done++
		s.mu.Unlock()
		if r.row != nil {
			batch = append(batch, *r.row)
		} else {
			skippedBatch = append(skippedBatch, [3]string{r.job.rel, r.status, r.detail})
			switch r.status {
			case "probe_error":
				s.ProbeErrors++
				failedProbe = append(failedProbe, [2]string{r.job.rel, r.detail})
				s.printf("\nProbe failed: %s  [%s]\n", r.job.rel, r.detail)
			case "no_width_or_duration":
				s.NoDims++
				noDims = append(noDims, [2]string{r.job.rel, r.detail})
				s.printf("\nSkipped (%s): %s\n", r.detail, r.job.rel)
			default:
				s.MetadataErrors++
				metaErrors = append(metaErrors, [2]string{r.job.rel, r.detail})
				s.printf("\nMetadata error: %s  [%s]\n", r.job.rel, r.detail)
			}
		}
		if len(batch)+len(skippedBatch) >= scanBatchSize {
			if err := flush(); err != nil {
				return err
			}
			s.printf(".")
		}
	}
	if err := flush(); err != nil {
		return err
	}

	s.printf("\n\n")
	s.printf("Files already scanned: %d\n", s.AlreadyScanned)
	s.printf("Skipped (extension): %d\n", s.SkippedExt)
	s.printf("Skipped (failed in an earlier run): %d\n", s.AlreadySkipped)
	if s.AlreadySkipped > 0 {
		s.printf("  -> use --rescan-skipped to probe them again\n")
	}
	s.printf("Skipped now (no width/duration): %d\n", s.NoDims)
	s.printf("Probe failures now: %d\n", s.ProbeErrors)
	s.printf("Metadata errors now: %d\n", s.MetadataErrors)
	s.printf("Added: %d\n", s.Added)
	if s.rescanSkipped {
		s.printf("Recovered from skipped list: %d\n", s.Recovered)
	}
	for _, sec := range []struct {
		title string
		list  [][2]string
	}{
		{"Files that failed the probe", failedProbe},
		{"Files skipped: no width/duration", noDims},
		{"Files with metadata errors", metaErrors},
	} {
		if len(sec.list) == 0 {
			continue
		}
		s.printf("\n--- %s ---\n", sec.title)
		for _, e := range sec.list {
			s.printf("%s  [%s]\n", e[0], e[1])
		}
	}
	return nil
}

// flush writes one batch (successes + failures) in a single transaction.
func (s *Scanner) flush(rows []mediaRow, skippedRows [][3]string, previouslySkipped map[string]bool) error {
	if len(rows) == 0 && len(skippedRows) == 0 {
		return nil
	}
	tx, err := s.store.rw.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var inserted []string
	for _, r := range rows {
		// NOT EXISTS: the file watcher and a scan may both pick up a new file.
		res, err := tx.Exec(`INSERT INTO media
			(filename,duration,codec_name,width,height,nb_frames,creation_time,file_size)
			SELECT ?,?,?,?,?,?,?,? WHERE NOT EXISTS (SELECT 1 FROM media WHERE filename = ?)`,
			r.filename, r.duration, r.codec, r.width, r.height, r.nbFrames, r.creationTime, r.fileSize, r.filename)
		if err != nil {
			return err
		}
		if n, _ := res.RowsAffected(); n > 0 {
			inserted = append(inserted, r.filename)
		}
		// a file that now probes fine must leave the skipped table
		if _, err := tx.Exec(`DELETE FROM skipped_files WHERE filename=?`, r.filename); err != nil {
			return err
		}
	}
	for _, r := range skippedRows {
		if _, err := tx.Exec(`INSERT OR REPLACE INTO skipped_files
			(filename,reason,detail,skipped_time) VALUES(?,?,?,datetime('now'))`, r[0], r[1], r[2]); err != nil {
			return err
		}
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	s.Added += len(inserted)
	for _, f := range inserted {
		if previouslySkipped[f] {
			s.Recovered++
		}
	}
	return nil
}

// probeOutput mirrors the subset of ffprobe's JSON we ask for.
type probeOutput struct {
	Streams []struct {
		CodecType string          `json:"codec_type"`
		CodecName *string         `json:"codec_name"`
		Width     int64           `json:"width"`
		Height    int64           `json:"height"`
		NbFrames  json.RawMessage `json:"nb_frames"`
		Tags      struct {
			CreationTime *string `json:"creation_time"`
		} `json:"tags"`
	} `json:"streams"`
	Format struct {
		Duration string `json:"duration"`
	} `json:"format"`
}

// probe runs ffprobe asking only for the fields we store.
func probe(path string) (*probeOutput, string) {
	ctx, cancel := context.WithTimeout(context.Background(), probeTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "ffprobe", "-v", "error", "-print_format", "json",
		"-show_entries",
		"format=duration:stream=codec_type,codec_name,width,height,nb_frames:stream_tags=creation_time",
		path)
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err := cmd.Run()
	if ctx.Err() == context.DeadlineExceeded {
		return nil, fmt.Sprintf("timeout after %ds", int(probeTimeout.Seconds()))
	}
	if err != nil {
		if _, ok := err.(*exec.ExitError); !ok {
			if errorsIsNotFound(err) {
				return nil, "ffprobe not found in PATH"
			}
			return nil, err.Error()
		}
		// keep only the last line, which is usually the actual reason
		lines := strings.Split(strings.TrimSpace(stderr.String()), "\n")
		if last := strings.TrimSpace(lines[len(lines)-1]); last != "" {
			return nil, last
		}
		return nil, fmt.Sprintf("ffprobe exit code %d", cmd.ProcessState.ExitCode())
	}
	var out probeOutput
	if err := json.Unmarshal(stdout.Bytes(), &out); err != nil {
		return nil, "invalid ffprobe output: " + err.Error()
	}
	return &out, ""
}

func errorsIsNotFound(err error) bool {
	return strings.Contains(err.Error(), exec.ErrNotFound.Error())
}

func extract(j scanJob) scanResult {
	meta, errMsg := probe(j.path)
	if meta == nil {
		return scanResult{job: j, status: "probe_error", detail: errMsg}
	}
	// first stream that actually has dimensions (i.e. a real video stream)
	idx := -1
	for i, st := range meta.Streams {
		if st.Width != 0 {
			idx = i
			break
		}
	}
	duration, _ := strconv.ParseFloat(meta.Format.Duration, 64)
	if idx < 0 || meta.Streams[idx].Height == 0 || duration == 0 {
		var missing []string
		if idx < 0 {
			missing = append(missing, "width", "height")
		} else if meta.Streams[idx].Height == 0 {
			missing = append(missing, "height")
		}
		if duration == 0 {
			missing = append(missing, "duration")
		}
		return scanResult{job: j, status: "no_width_or_duration", detail: "missing " + strings.Join(missing, "/")}
	}
	st := meta.Streams[idx]
	fi, err := os.Stat(j.path)
	if err != nil {
		return scanResult{job: j, status: "metadata_error", detail: err.Error()}
	}
	row := &mediaRow{
		filename:     j.rel,
		duration:     duration,
		codec:        st.CodecName,
		width:        st.Width,
		height:       st.Height,
		creationTime: st.Tags.CreationTime,
		fileSize:     fi.Size(),
	}
	// ffprobe reports nb_frames as a string ("1234") or omits it.
	if len(st.NbFrames) > 0 {
		var sv string
		if json.Unmarshal(st.NbFrames, &sv) == nil {
			if n, err := strconv.ParseInt(sv, 10, 64); err == nil {
				row.nbFrames = &n
			}
		} else {
			var n int64
			if json.Unmarshal(st.NbFrames, &n) == nil {
				row.nbFrames = &n
			}
		}
	}
	return scanResult{job: j, row: row, status: "ok"}
}
