package main

import (
	"net/http"
	"sort"
	"strings"
)

// GroupStat is one row of a dashboard breakdown table / treemap tile.
type GroupStat struct {
	Key      string  `json:"key"`
	Title    string  `json:"title"`
	Count    int     `json:"count"`
	Bytes    int64   `json:"bytes"`
	Duration float64 `json:"duration"`
	Color    string  `json:"color"`
}

type group struct {
	keys   []string
	titles map[string]string
	colors map[string]string
	stats  map[string]*GroupStat
}

func newGroup(defs [][3]string) *group {
	g := &group{titles: map[string]string{}, colors: map[string]string{}, stats: map[string]*GroupStat{}}
	for _, d := range defs {
		g.keys = append(g.keys, d[0])
		g.titles[d[0]], g.colors[d[0]] = d[1], d[2]
		g.stats[d[0]] = &GroupStat{Key: d[0], Title: d[1], Color: d[2]}
	}
	return g
}

func (g *group) add(key string, r DashboardRecord) {
	s := g.stats[key]
	s.Count++
	s.Bytes += r.FileSize
	if r.Duration != nil {
		s.Duration += *r.Duration
	}
}

func (g *group) list() []GroupStat {
	out := make([]GroupStat, 0, len(g.keys))
	for _, k := range g.keys {
		out = append(out, *g.stats[k])
	}
	return out
}

// Colors are CSS custom properties defined in app.css.
func (a *App) handleDashboard(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	ctx := r.Context()
	all, err := a.Store.DashboardRecords(ctx, false, "", "")
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	filtered, ferr := a.Store.DashboardRecords(ctx, true, q.Get("search"), q.Get("cond"))
	records := all
	if q.Get("scope") == "filter" {
		records = filtered
	}
	actorMap, err := a.Store.MediaActorNames(ctx)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}

	likes := newGroup([][3]string{
		{"disliked", "Disliked (< 0)", "red"},
		{"unrated", "Unrated (0 / NULL)", "gray"},
		{"1", "1 Like", "orange"},
		{"2", "2 Likes", "yellow"},
		{"3", "3 Likes", "green"},
		{"4", "4 Likes", "teal"},
		{"5+", "5+ Likes", "purple"},
	})
	res := newGroup([][3]string{
		{"4k", "4K / 2160p+", "purple"},
		{"1080p", "1080p Full HD", "blue"},
		{"720p", "720p HD", "teal"},
		{"sd", "480p / SD", "green"},
		{"unknown", "Unknown / Missing", "gray"},
	})
	durs := newGroup([][3]string{
		{"short", "Short (< 5 min)", "teal"},
		{"medium", "Medium (5 - 15 min)", "green"},
		{"long", "Long (15 - 30 min)", "yellow"},
		{"extended", "Extended (30 - 60 min)", "orange"},
		{"feature", "Feature (> 1 hour)", "red"},
		{"unknown", "Unknown Duration", "gray"},
	})
	views := newGroup([][3]string{
		{"unwatched", "Unwatched (0 views)", "gray"},
		{"1-2", "1 - 2 Views", "blue"},
		{"3-5", "3 - 5 Views", "orange"},
		{"6+", "6+ Views", "purple"},
	})
	actorStats := map[string]*GroupStat{}
	unassigned := &GroupStat{Key: "__unassigned__", Title: "Unassigned / No Actor", Color: "gray"}

	var totalBytes int64
	var totalDur float64
	for _, rec := range records {
		totalBytes += rec.FileSize
		if rec.Duration != nil {
			totalDur += *rec.Duration
		}

		switch l := rec.Like; {
		case l != nil && *l < 0:
			likes.add("disliked", rec)
		case l != nil && *l >= 5:
			likes.add("5+", rec)
		case l != nil && *l >= 1:
			likes.add(map[int64]string{1: "1", 2: "2", 3: "3", 4: "4"}[*l], rec)
		default:
			likes.add("unrated", rec)
		}

		switch wd := rec.Width; {
		case wd == nil || *wd <= 0:
			res.add("unknown", rec)
		case *wd >= 3840:
			res.add("4k", rec)
		case *wd >= 1920:
			res.add("1080p", rec)
		case *wd >= 1280:
			res.add("720p", rec)
		default:
			res.add("sd", rec)
		}

		switch d := rec.Duration; {
		case d == nil || *d <= 0:
			durs.add("unknown", rec)
		case *d < 300:
			durs.add("short", rec)
		case *d < 900:
			durs.add("medium", rec)
		case *d < 1800:
			durs.add("long", rec)
		case *d < 3600:
			durs.add("extended", rec)
		default:
			durs.add("feature", rec)
		}

		switch v := rec.ViewCount; {
		case v == nil || *v <= 0:
			views.add("unwatched", rec)
		case *v <= 2:
			views.add("1-2", rec)
		case *v <= 5:
			views.add("3-5", rec)
		default:
			views.add("6+", rec)
		}

		names := actorMap[rec.ID]
		if len(names) == 0 {
			unassigned.Count++
			unassigned.Bytes += rec.FileSize
			if rec.Duration != nil {
				unassigned.Duration += *rec.Duration
			}
		}
		for _, n := range names {
			s := actorStats[n]
			if s == nil {
				s = &GroupStat{Key: n, Title: n}
				actorStats[n] = s
			}
			s.Count++
			s.Bytes += rec.FileSize
			if rec.Duration != nil {
				s.Duration += *rec.Duration
			}
		}
	}

	actors := make([]GroupStat, 0, len(actorStats)+1)
	for _, s := range actorStats {
		actors = append(actors, *s)
	}
	sort.Slice(actors, func(i, j int) bool {
		if actors[i].Bytes != actors[j].Bytes {
			return actors[i].Bytes > actors[j].Bytes
		}
		return strings.ToLower(actors[i].Title) < strings.ToLower(actors[j].Title)
	})
	palette := []string{"blue", "purple", "orange", "teal", "green", "pink", "indigo"}
	for i := range actors {
		actors[i].Color = palette[i%len(palette)]
	}
	if unassigned.Count > 0 || len(actors) == 0 {
		actors = append(actors, *unassigned)
	}

	resp := map[string]any{
		"allCount":      len(all),
		"filteredCount": len(filtered),
		"count":         len(records),
		"bytes":         totalBytes,
		"duration":      totalDur,
		"likes":         likes.list(),
		"resolutions":   res.list(),
		"durations":     durs.list(),
		"views":         views.list(),
		"actors":        actors,
	}
	if ferr != nil {
		resp["filterError"] = ferr.Error()
	}
	writeJSON(w, http.StatusOK, resp)
}
