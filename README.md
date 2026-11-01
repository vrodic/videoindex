# videoindex

A browsable, rateable index of a video library, kept in a SQLite database.

`videoindex` is a single Go binary that

- **scans** a media directory with `ffprobe` and stores each video's
  duration, codec, resolution, frame count and size in SQLite;
- **serves a web UI** to search, filter (with raw SQL), sort, like/dislike,
  tag actors and get statistics;
- **plays videos in the browser**, serving files over HTTP with range
  requests, or remuxing/transcoding on the fly with `ffmpeg` when the
  browser can't play the original (WMV, AVI, FLV, MKV, …).

It replaces the earlier macOS app (`macos/`, which launched `mpv`) and the
Python tools (`videoindex/`). Both are still in the repo for reference and
use the same database, so you can switch back and forth.

## Requirements

- Go 1.26+ to build. The SQLite driver is pure Go (`modernc.org/sqlite`),
  so no cgo and no system SQLite are needed.
- `ffmpeg` and `ffprobe` on the server's `PATH`. They are used for scanning,
  thumbnails and playback of formats browsers can't handle.
- A recent desktop browser (Chrome, Safari, Firefox, Edge).

## Build

```bash
cd web
go build -o videoindex .
```

Cross-compile for a Linux server from any machine:

```bash
cd web
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o videoindex-linux .
```

The web UI (`web/static/`) is embedded in the binary. There's nothing else
to deploy.

## Run

```bash
videoindex serve -root /Volumes/root/mnt/picko/stuff/x -db xv.db
```

Then open <http://localhost:8080>.

Filenames in the database are **relative to `-root`**. To move the library
to another machine, copy `xv.db` and point `-root` at the new location.
Nothing in the database needs to change. For example, on a Linux server:

```bash
videoindex serve -root /srv/media/x -db /srv/videoindex/xv.db -listen :8080
```

### `serve` flags

| Flag | Env var | Default | |
|---|---|---|---|
| `-root` | `VIDEOINDEX_ROOT` | (required) | media root; DB filenames are relative to it |
| `-db` | `VIDEOINDEX_DB` | (required) | SQLite index file (created if missing) |
| `-listen` | `VIDEOINDEX_LISTEN` | `:8080` | HTTP listen address |
| `-thumbs` | `VIDEOINDEX_THUMBS` | `<root>/Thumbs` | thumbnail cache directory |
| `-auth` | `VIDEOINDEX_AUTH` | (off) | require HTTP basic auth, `user:password` |
| `-allow-delete` | `VIDEOINDEX_ALLOW_DELETE` | `true` | allow the second dislike to delete the file (`=0` disables) |
| `-thumb-workers` | | `2` | concurrent `ffmpeg` thumbnail extractions |
| `-max-transcodes` | | `2` | concurrent `ffmpeg` playback streams |

The default thumbnail directory is the one the macOS app used, with the same
`<id>_<percent>.jpg` naming, so thumbnails it already made are reused. If
the media root is read-only on the server, set `-thumbs` to a writable
directory.

> **Security.** The condition box runs your SQL against the database (see
> below), and the server can delete files. Use `-auth`, or keep the server
> behind a VPN/reverse proxy, before exposing it beyond your LAN. The SQL
> condition runs on a read-only (`query_only`) connection and `;` is
> rejected, so it can filter and sort but not modify data.

### Example systemd unit

```ini
# /etc/systemd/system/videoindex.service
[Unit]
Description=videoindex
After=network-online.target

[Service]
ExecStart=/usr/local/bin/videoindex serve
Environment=VIDEOINDEX_ROOT=/srv/media/x
Environment=VIDEOINDEX_DB=/srv/videoindex/xv.db
Environment=VIDEOINDEX_THUMBS=/srv/videoindex/thumbs
Environment=VIDEOINDEX_LISTEN=:8080
Environment=VIDEOINDEX_AUTH=me:change-me
User=videoindex
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

## Scanning

```bash
videoindex scan -root /srv/media/x -db /srv/videoindex/xv.db [-rescan-skipped] [-workers 8]
```

You can also start a scan from the UI's **Scan** button, which streams its
progress and log into a dialog and reloads the list when it finishes.

The scanner works like the old `scanner.py`:

- It walks the root, following symlinked directories, and skips the
  `Thumbs` directory and files with extensions like `.jpg .png .nfo .srt
  .zip .rar .mp3 .txt`.
- It probes each file that isn't in `media` yet with `ffprobe`, running
  `-workers` in parallel (default 8; use fewer on HDDs or network shares).
- It stores the first stream that has dimensions: codec, width, height,
  `nb_frames` and `creation_time`, plus the container duration and file
  size. Rows are committed in batches of 200.
- Files that fail to probe, or have no width/height/duration, are recorded in
  `skipped_files` with the reason and aren't probed again unless you pass
  `-rescan-skipped`. A file that later probes fine is moved out of that
  table.
- At the end it prints a summary and lists every failure.

## Using the web UI

The layout matches the macOS app:

- **Left:** the media list, the SQL condition box, a status line and the
  Actors panel.
- **Right:** the preview columns. Drag the divider to resize them.

### The list

The columns are ✓, ID, Filename, Views, Likes, Size (MB), Last Viewed,
Width and Density (`file_size / (duration × width)`, a rough bitrate per
pixel).

- **Sorting:** click a header to sort; click it again to reverse. Press `r`
  to reload the query and clear the sort.
- **✓ column:** ticks rows for bulk actor assignment. Click its header to
  tick or untick all.
- **Row tints:** blue rows have been watched before. Green rows were played
  in this session.
- **Likes colours:** red is disliked, then orange, yellow, green, teal and
  purple for 1 to 5+ likes.
- **Red rows:** the file no longer exists on disk.
- **Large lists:** the list is virtualized, so whole-library queries stay
  fast.

### Search and SQL condition

- **Search box:** substring match on the filename (SQL `LIKE '%…%'`).
- **Condition box:** free-form SQL, appended after
  `WHERE filename LIKE ? AND …`. It can be a filter, an ordering or both:

  ```sql
  AND like > 2 ORDER BY viewed_time, random()
  ORDER BY file_size DESC
  AND width >= 1920 AND duration > 600 ORDER BY id DESC
  ```

- **Saved conditions:** the ▾ button lists the built-in conditions and
  conditions you typed that returned results. Typed conditions are saved in
  this browser. ✕ removes one.
- **Errors:** a malformed condition shows the SQLite error in the status
  line.

### Preview

- **Filmstrip:** frames from 15%, 30%, 45%, 60%, 75% and 90% of the selected
  video. Click a frame to start playback there.
- **Up Next:** the selected video (outlined) and the next nine rows. Click
  one to select it.
- **Thumbnail generation:** the server extracts thumbnails with `ffmpeg` on
  first request and caches them on disk. The browser loads them in priority
  order after a short debounce, so arrowing quickly through the list doesn't
  queue work. The next row's filmstrip is prefetched, so it appears
  instantly when you move down.

### Actors

- **Filter by actor:** type one or more names, separated by commas, and
  press Enter, or pick names from **Select Actors…**. This lists media that
  feature *all* of the chosen actors. Remove a choice with ✕ on its pill.
- **Actors for selected media:** shows the selected file's actors. Edit a
  name or alternate names in place and press Enter.
- **Row buttons:**
  - **✓** assigns the actor to every ticked row.
  - **⏚** filters by that actor.
  - **🔍** searches filenames for the actor's names and alternate names,
    with spaces written as `_` or removed.
- **Add / remove:** **Add Actor** tags the selected file, creating the actor
  if needed. **Remove Actor** untags the actor row you selected.

### Word cloud (`w`)

- **All Words:** every filename word, sized by how many files contain it,
  shown 200 per page.
- **Full Names:** adjacent word pairs (`first_last`).
- **Click a word** to search for it.

### Dashboard (`d`)

Totals, a squarified treemap and breakdown tables. The tables show storage
and counts by like tier, actor, resolution, duration and view count. Switch
between the whole library and the current search and condition.

### Rating and deleting

| Key | Action |
|---|---|
| `+` / `=` / `Insert` | like +1, move down |
| `Delete` / `Backspace` | dislike −1, move down |

A dislike that takes a file's rating **below −1** deletes the file from disk
and from the database. An unrated file is therefore deleted on the second
press. A liked file needs enough presses to go negative first. This is the
same two-step guard as the original tool. Start the server with
`-allow-delete=0` to only ever record dislikes.

## Player

Press `Enter` or double-click a row to play the video in a full-window
player. Opening a video increments its view count and sets `viewed_time`,
just as launching `mpv` did. Press `q` or `Esc` to close the player and
return to the list.

### How a video gets to the browser

The server picks a delivery mode from the container and codec:

1. **Direct:** MP4, MOV and WebM files with H.264, HEVC, VP8, VP9 or AV1
   video are served as-is with HTTP range requests, so seeking is native.
2. **Remux:** H.264 or HEVC video in other containers (MKV, FLV, TS, AVI…)
   is copied into fragmented MP4 by `ffmpeg`, with audio re-encoded to AAC.
   This is cheap, with no video re-encode.
3. **Transcode:** anything else (WMV, Xvid/DivX, MPEG-1/2, …) is re-encoded
   to H.264/AAC (`libx264 -preset veryfast`, max 1080p).

If the browser can't decode a mode, for example HEVC in Firefox or 10-bit
H.264, the player falls back to the next mode automatically. The current
mode is shown in the top-right corner.

Remuxed and transcoded streams start at a given offset. Seeking within what
has already been received is instant. Seeking further restarts the stream at
the new position. The seek bar always shows the file's full length. The
`ffmpeg` process stops as soon as the player closes or seeks away.

### Player options (`o`, or the **Player ⚙** button)

These replace the old MPV menu and are saved in the browser:

- **Default volume:** 33% by default.
- **Allow volume above 100%:** up to 1000%, using Web Audio gain. This is
  the equivalent of `--volume-max=1000`.
- **Player size:** 50%, 75% or 100% of the window, or fullscreen.
- **Playback speed.**
- **Start muted.**
- **No audio.**
- **Loop.**
- **Keep the player open when the video ends.**
- **Play the next row when the video ends.**

### Player keys

Mostly the same as mpv:

| Key | Action |
|---|---|
| `Space` `k` `p` | pause / play |
| `←` `→` | seek ∓5 s (with `Shift`: 1 s) |
| `↑` `↓` | seek ±60 s |
| `PgUp` `PgDn` | seek ±10% |
| `9` `0` | volume down / up |
| `m` | mute |
| `[` `]` `{` `}` | speed ÷1.1, ×1.1, ÷2, ×2 |
| `Backspace` | reset speed |
| `l` | loop |
| `f`, double-click | fullscreen |
| `,` `.` | frame step |
| `n` / `Enter`, `N` | play next / previous row |
| `o` | show position |
| `q` `Esc` | close |

## Keyboard shortcuts (list)

| Key | Action |
|---|---|
| `↑` `↓` `PgUp` `PgDn` `Home` `End` | move selection |
| `Enter` | play |
| `+` `=` `Insert` | like |
| `Delete` `Backspace` | dislike, then delete |
| `Space` | tick / untick row |
| `/` or `⌘F` / `Ctrl+F` | focus search |
| `c` or `⌘L` / `Ctrl+L` | focus SQL condition |
| `r` | reload, clear sort |
| `w` or `⌘K` | word cloud |
| `d` | dashboard |
| `o` | player options |
| `?` | shortcut help |
| `Esc` | leave a text field / close a dialog |

## Database

The schema is the one the Python and macOS tools used. It is created if
missing, and an existing database is used as-is:

```sql
media(id, filename, duration, codec_name, width, height, nb_frames,
      creation_time, file_size, sha1, view_count, like, viewed_time)
skipped_files(filename, reason, detail, skipped_time)
actors(id, name UNIQUE, alt_names)
media_actors(media_id, actor_id)
```

`viewed_time` is UTC, as written by SQLite's `datetime('now')`. Every listing
also excludes `.jpg` files, `mjpeg` streams, and names containing
`.unwanted`, `SMP-B9R` or `SAMPLE-B9R`, as before. `queries.sql` has some
handy ad-hoc queries, for example finding duplicates by size.

## Repository layout

```
web/                   Go server + scanner (this is the app)
  main.go              CLI: serve / scan
  store.go             SQLite access
  scanner.go           ffprobe scanner (port of videoindex/scanner.py)
  media.go             file serving, remux/transcode, thumbnails
  api.go               HTTP API, word cloud, scan-from-UI
  dashboard.go         dashboard aggregation
  static/              embedded web UI (plain ES modules, no build step)
macos/                 previous macOS (AppKit + mpv) app
videoindex/            previous Python tools (scanner, PyQt player, backup, delete)
queries.sql            useful ad-hoc queries
```
