package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"sort"
	"strings"

	_ "modernc.org/sqlite"
)

// extraConditions is the fixed filtering every listing applies (carried
// over unchanged from the Python/macOS versions).
const extraConditions = ` AND filename NOT LIKE '%.jpg' AND codec_name <> 'mjpeg' ` +
	` AND filename NOT LIKE '%.unwanted%' AND filename NOT LIKE '%SMP-B9R%' ` +
	` AND filename NOT LIKE '%SAMPLE-B9R%'`

// Store wraps the SQLite index. Writes go through a single connection;
// the user-supplied SQL condition fragment only ever runs on a separate
// query_only connection pool, so it can filter and sort but not modify.
type Store struct {
	rw *sql.DB
	ro *sql.DB
}

func OpenStore(path string) (*Store, error) {
	rw, err := sql.Open("sqlite", "file:"+path+"?_pragma=busy_timeout(10000)")
	if err != nil {
		return nil, err
	}
	rw.SetMaxOpenConns(1)
	if err := rw.Ping(); err != nil {
		rw.Close()
		return nil, err
	}
	s := &Store{rw: rw}
	if err := s.migrate(); err != nil {
		rw.Close()
		return nil, err
	}
	ro, err := sql.Open("sqlite", "file:"+path+"?_pragma=busy_timeout(10000)&_pragma=query_only(1)")
	if err != nil {
		rw.Close()
		return nil, err
	}
	ro.SetMaxOpenConns(4)
	s.ro = ro
	return s, nil
}

func (s *Store) Close() {
	s.rw.Close()
	if s.ro != nil {
		s.ro.Close()
	}
}

func (s *Store) migrate() error {
	stmts := []string{
		`CREATE TABLE IF NOT EXISTS media
			(id INTEGER PRIMARY KEY AUTOINCREMENT,
			filename text,
			duration real,
			codec_name text,
			width integer,
			height integer,
			nb_frames integer,
			creation_time datetime,
			file_size integer,
			sha1 text,
			view_count integer,
			like integer,
			viewed_time datetime)`,
		`CREATE INDEX IF NOT EXISTS idx_media_filename ON media(filename)`,
		`CREATE TABLE IF NOT EXISTS skipped_files
			(filename text PRIMARY KEY,
			reason text,
			detail text,
			skipped_time datetime)`,
		`CREATE TABLE IF NOT EXISTS actors (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			name TEXT UNIQUE NOT NULL,
			alt_names TEXT)`,
		`CREATE TABLE IF NOT EXISTS media_actors (
			media_id INTEGER,
			actor_id INTEGER,
			PRIMARY KEY (media_id, actor_id))`,
	}
	for _, q := range stmts {
		if _, err := s.rw.Exec(q); err != nil {
			return fmt.Errorf("%s: %w", strings.Fields(q)[0:3], err)
		}
	}
	return nil
}

// MediaItem is one row of the main listing.
type MediaItem struct {
	ID         int64    `json:"id"`
	Filename   string   `json:"filename"`
	ViewCount  *int64   `json:"views"`
	Like       *int64   `json:"like"`
	SizeMB     int64    `json:"sizeMB"`
	ViewedTime *string  `json:"viewed"`
	Width      *int64   `json:"width"`
	Height     *int64   `json:"height"`
	Density    *int64   `json:"density"`
	Duration   *float64 `json:"duration"`
	Codec      *string  `json:"codec"`
}

// ErrBadCondition is returned for condition fragments we refuse to run.
var ErrBadCondition = errors.New("condition must not contain ';'")

func checkCondition(cond string) error {
	if strings.Contains(cond, ";") {
		return ErrBadCondition
	}
	return nil
}

// LoadItems returns rows whose filename contains search, further filtered
// and ordered by the free-form SQL fragment cond (e.g.
// "AND like > 2 ORDER BY viewed_time, random()").
func (s *Store) LoadItems(ctx context.Context, search, cond string) ([]MediaItem, error) {
	if err := checkCondition(cond); err != nil {
		return nil, err
	}
	q := `SELECT id, filename, view_count, like, file_size, CAST(viewed_time AS TEXT), width, height,
	             file_size / (duration * width), duration, codec_name
	      FROM media
	      WHERE filename LIKE ? ` + extraConditions + " " + cond + "\n"
	rows, err := s.ro.QueryContext(ctx, q, "%"+search+"%")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []MediaItem{}
	for rows.Next() {
		var it MediaItem
		var size sql.NullInt64
		var density sql.NullFloat64
		if err := rows.Scan(&it.ID, &it.Filename, &it.ViewCount, &it.Like, &size, &it.ViewedTime,
			&it.Width, &it.Height, &density, &it.Duration, &it.Codec); err != nil {
			return nil, err
		}
		it.SizeMB = size.Int64 / (1024 * 1024)
		if density.Valid {
			d := int64(density.Float64)
			it.Density = &d
		}
		items = append(items, it)
	}
	return items, rows.Err()
}

// MediaFile is what playback / thumbnailing need to know about one row.
type MediaFile struct {
	ID       int64
	Filename string
	Duration float64
	Codec    string
	Width    int64
}

func (s *Store) GetMedia(ctx context.Context, id int64) (*MediaFile, error) {
	var m MediaFile
	var dur sql.NullFloat64
	var codec sql.NullString
	var width sql.NullInt64
	err := s.rw.QueryRowContext(ctx,
		`SELECT id, filename, duration, codec_name, width FROM media WHERE id = ?`, id).
		Scan(&m.ID, &m.Filename, &dur, &codec, &width)
	if err != nil {
		return nil, err
	}
	m.Duration, m.Codec, m.Width = dur.Float64, codec.String, width.Int64
	return &m, nil
}

// MarkViewed increments view_count, stamps viewed_time and returns both.
func (s *Store) MarkViewed(ctx context.Context, id int64) (views int64, viewed string, err error) {
	_, err = s.rw.ExecContext(ctx,
		`UPDATE media SET view_count = COALESCE(view_count, 0) + 1, viewed_time = datetime('now') WHERE id = ?`, id)
	if err != nil {
		return
	}
	err = s.rw.QueryRowContext(ctx, `SELECT view_count, CAST(viewed_time AS TEXT) FROM media WHERE id = ?`, id).Scan(&views, &viewed)
	return
}

// AdjustLike adds delta to like (NULL counts as 0) and returns the new value.
func (s *Store) AdjustLike(ctx context.Context, id, delta int64) (int64, error) {
	if _, err := s.rw.ExecContext(ctx, `UPDATE media SET like = COALESCE(like, 0) + ? WHERE id = ?`, delta, id); err != nil {
		return 0, err
	}
	var like int64
	err := s.rw.QueryRowContext(ctx, `SELECT like FROM media WHERE id = ?`, id).Scan(&like)
	return like, err
}

func (s *Store) DeleteMedia(ctx context.Context, id int64) error {
	tx, err := s.rw.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`DELETE FROM media WHERE id = ?`, id); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM media_actors WHERE media_id = ?`, id); err != nil {
		return err
	}
	return tx.Commit()
}

// --- Actors -----------------------------------------------------------

type Actor struct {
	ID         int64  `json:"id"`
	Name       string `json:"name"`
	AltNames   string `json:"altNames"`
	MediaCount int64  `json:"mediaCount"`
}

func scanActors(rows *sql.Rows) ([]Actor, error) {
	defer rows.Close()
	out := []Actor{}
	for rows.Next() {
		var a Actor
		var alt sql.NullString
		if err := rows.Scan(&a.ID, &a.Name, &alt, &a.MediaCount); err != nil {
			return nil, err
		}
		a.AltNames = alt.String
		out = append(out, a)
	}
	return out, rows.Err()
}

func (s *Store) AllActors(ctx context.Context) ([]Actor, error) {
	rows, err := s.rw.QueryContext(ctx, `
		SELECT a.id, a.name, a.alt_names, COUNT(ma.media_id)
		FROM actors a LEFT JOIN media_actors ma ON a.id = ma.actor_id
		GROUP BY a.id, a.name, a.alt_names
		ORDER BY a.name ASC`)
	if err != nil {
		return nil, err
	}
	return scanActors(rows)
}

func (s *Store) ActorsForMedia(ctx context.Context, mediaID int64) ([]Actor, error) {
	rows, err := s.rw.QueryContext(ctx, `
		SELECT a.id, a.name, a.alt_names,
		       (SELECT COUNT(*) FROM media_actors WHERE actor_id = a.id)
		FROM actors a JOIN media_actors ma ON a.id = ma.actor_id
		WHERE ma.media_id = ?
		ORDER BY a.name ASC`, mediaID)
	if err != nil {
		return nil, err
	}
	return scanActors(rows)
}

// AddOrGetActor finds an actor by case-insensitive name, creating it if needed.
func (s *Store) AddOrGetActor(ctx context.Context, name string) (*Actor, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return nil, errors.New("empty actor name")
	}
	rows, err := s.rw.QueryContext(ctx, `
		SELECT a.id, a.name, a.alt_names,
		       (SELECT COUNT(*) FROM media_actors WHERE actor_id = a.id)
		FROM actors a WHERE lower(a.name) = lower(?)`, name)
	if err != nil {
		return nil, err
	}
	found, err := scanActors(rows)
	if err != nil {
		return nil, err
	}
	if len(found) > 0 {
		return &found[0], nil
	}
	res, err := s.rw.ExecContext(ctx, `INSERT INTO actors (name, alt_names) VALUES (?, '')`, name)
	if err != nil {
		return nil, err
	}
	id, _ := res.LastInsertId()
	return &Actor{ID: id, Name: name}, nil
}

func (s *Store) AssignActor(ctx context.Context, actorID int64, mediaIDs []int64) error {
	tx, err := s.rw.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, mid := range mediaIDs {
		if _, err := tx.Exec(`INSERT OR IGNORE INTO media_actors (media_id, actor_id) VALUES (?, ?)`, mid, actorID); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (s *Store) RemoveActorFromMedia(ctx context.Context, actorID, mediaID int64) error {
	_, err := s.rw.ExecContext(ctx, `DELETE FROM media_actors WHERE media_id = ? AND actor_id = ?`, mediaID, actorID)
	return err
}

func (s *Store) UpdateActor(ctx context.Context, id int64, name, altNames *string) error {
	if name != nil {
		n := strings.TrimSpace(*name)
		if n == "" {
			return errors.New("empty actor name")
		}
		if _, err := s.rw.ExecContext(ctx, `UPDATE actors SET name = ? WHERE id = ?`, n, id); err != nil {
			return err
		}
	}
	if altNames != nil {
		if _, err := s.rw.ExecContext(ctx, `UPDATE actors SET alt_names = ? WHERE id = ?`, strings.TrimSpace(*altNames), id); err != nil {
			return err
		}
	}
	return nil
}

// --- Word cloud ---------------------------------------------------------

type WordCount struct {
	Word  string `json:"word"`
	Count int    `json:"count"`
}

func (s *Store) AllFilenames(ctx context.Context) ([]string, error) {
	rows, err := s.rw.QueryContext(ctx, `SELECT filename FROM media WHERE 1=1 `+extraConditions)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var f sql.NullString
		if err := rows.Scan(&f); err != nil {
			return nil, err
		}
		if f.Valid {
			out = append(out, f.String)
		}
	}
	return out, rows.Err()
}

func sortWordCounts(m map[string]int) []WordCount {
	out := make([]WordCount, 0, len(m))
	for w, c := range m {
		out = append(out, WordCount{w, c})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Count != out[j].Count {
			return out[i].Count > out[j].Count
		}
		return out[i].Word < out[j].Word
	})
	return out
}

// --- Dashboard ----------------------------------------------------------

type DashboardRecord struct {
	ID        int64
	FileSize  int64
	Like      *int64
	Width     *int64
	Duration  *float64
	ViewCount *int64
}

func (s *Store) DashboardRecords(ctx context.Context, filtered bool, search, cond string) ([]DashboardRecord, error) {
	var rows *sql.Rows
	var err error
	if filtered {
		if err := checkCondition(cond); err != nil {
			return nil, err
		}
		rows, err = s.ro.QueryContext(ctx, `SELECT id, file_size, like, width, duration, view_count
			FROM media WHERE filename LIKE ? `+extraConditions+" "+cond+"\n", "%"+search+"%")
	} else {
		rows, err = s.ro.QueryContext(ctx, `SELECT id, file_size, like, width, duration, view_count
			FROM media WHERE 1=1 `+extraConditions)
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []DashboardRecord
	for rows.Next() {
		var r DashboardRecord
		var size sql.NullInt64
		if err := rows.Scan(&r.ID, &size, &r.Like, &r.Width, &r.Duration, &r.ViewCount); err != nil {
			return nil, err
		}
		r.FileSize = size.Int64
		out = append(out, r)
	}
	return out, rows.Err()
}

func (s *Store) MediaActorNames(ctx context.Context) (map[int64][]string, error) {
	rows, err := s.rw.QueryContext(ctx, `
		SELECT ma.media_id, a.name FROM media_actors ma
		JOIN actors a ON ma.actor_id = a.id ORDER BY a.name ASC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[int64][]string{}
	for rows.Next() {
		var id int64
		var name string
		if err := rows.Scan(&id, &name); err != nil {
			return nil, err
		}
		out[id] = append(out[id], name)
	}
	return out, rows.Err()
}
