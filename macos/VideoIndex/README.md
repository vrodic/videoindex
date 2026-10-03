# VideoIndex (Swift / AppKit port)

A macOS translation of the PyQt6 `videoindex` tool: an `NSTableView` backed
by the same SQLite `media` table, with a search box, a free-form SQL
condition/order box, and keyboard-only browsing.

## Build & run

Requires macOS 13+ and Xcode / Swift 5.9+. `mpv` must be installed
(e.g. `brew install mpv`) since videos are launched through it.

Previews for WMV/AVI (and anything else AVFoundation can't parse) need
`ffmpeg`/`ffprobe` on your `PATH` — see "Preview panel" below. If you
installed `mpv` via Homebrew you almost certainly already have it,
since the `mpv` formula depends on `ffmpeg`; if not, `brew install ffmpeg`.

```bash
swift build -c release
.build/release/VideoIndex /path/to/media/root /path/to/index.db
```

You can also just open the folder in Xcode (File ▸ Open, pick this
directory — Xcode reads `Package.swift` directly) and hit Run; pass the
two arguments via Product ▸ Scheme ▸ Edit Scheme ▸ Arguments.

## Preview panel

The right-hand panel is a scrollable filmstrip of frames grabbed at
**15%, 30%, 45%, 60%, 75%, and 90%** of the selected video's duration,
generated with Apple's native `AVFoundation` (`AVAssetImageGenerator`)
— no ffmpeg, no third-party dependency. Frames are fetched in parallel
off a single generator and fill in as each one finishes; each is
cached in memory per file for the rest of the session, so revisiting a
row is instant. If a file can't be read (corrupt, unsupported codec,
etc.) that row's thumbnails just stay blank — check the console for
the error.

**WMV and AVI:** AVFoundation is tried first for every file, but it
has no Windows Media decoder at all — macOS dropped that support years
ago along with Flip4Mac/Perian — so **every WMV** falls through to a
per-file `ffmpeg`/`ffprobe` fallback. **AVI** is a mixed bag: it's just
a container, so an AVI holding H.264 or Motion JPEG decodes fine via
AVFoundation directly, while one holding Xvid/DivX (common for older
rips) falls through to the same `ffmpeg` fallback. Either way it's
automatic — nothing to configure — but it does mean WMV/uncommon-AVI
previews are a bit slower to appear (each frame is a short-lived
`ffmpeg` subprocess) and require `ffmpeg` to be installed, unlike the
plain-AVFoundation path for MP4/MOV.

Drag the divider between the table and the filmstrip to resize either
side (bounded so the table can't shrink below a usable width and the
preview area can't disappear entirely); each thumbnail scales with the
column, so widening it gives you a bigger picture, not more columns.

**"Up Next" column:** to the left of that filmstrip is a second column.
**The first thumbnail is always the current selection** (it gets a
permanent accent-colored border to mark it as "current" rather than
"next"); the rest are the files that follow it in the list — i.e. what
you'd hit next if you kept pressing Down. The two columns always split
the pane's width equally (an Auto Layout `equalTo` constraint, not a
fixed size), so dragging the main divider resizes both together.
"Up Next" displays up to 10 thumbnails (the current video plus 9 upcoming videos)
in a scrollable column. Hover a thumbnail to see its
filename (cursor turns into a pointing hand) and **click it to jump
the table's selection straight to that file** — clicking the bordered
first one just re-selects the current row, harmlessly. Every thumbnail
here shares a cache bucket with the filmstrip's own 45% row, so a file
generates its thumbnail at most once no matter how many times it shows
up across both — including the bordered slot, which is usually just
showing the same image already visible in the filmstrip's own 45% row.

## Keyboard shortcuts

| Key                | Action                                            |
|--------------------|----------------------------------------------------|
| ↑ / ↓              | Move selection (default `NSTableView` behavior)    |
| Return             | Play the selected file in `mpv`, bump view count    |
| Delete / Backspace | Dislike; a **second** press on the same row deletes |
| Home / End         | Jump to first / last row                            |
| + or =             | Like (increment)                                    |
| Esc                | Quit                                                 |

### Notes on the translation

- **No literal "Insert" key**: standard Mac keyboards don't have one, so
  liking is bound to `+`/`=` instead (and to the Help/Insert key on
  external keyboards that have it, keycode 114).
- **Delete-then-delete guard**: kept exactly as in the Python version —
  pressing the delete shortcut first records a dislike; only a second
  press, once the like value has dropped below -1, actually removes the
  file from disk and the database.
- The original's `elif key == 16777248:` branch (whose Qt key code didn't
  map to a clear, documented key) is reproduced as **Return**, which
  seemed the most natural "play" shortcut for a Mac app — easy to change
  in `ShortcutTableView.keyDown(_:)` if you had something else in mind.
- The condition/order text field works the same way as the Python
  version: whatever you type is spliced directly into the SQL `WHERE`
  clause, so it's exactly as powerful (and exactly as trusting of your
  own input) as the original.
- All 8 columns now have header titles (the original only labeled the
  first 5); "Last Viewed", "Width", and "Density" were added for clarity.
- File deletion and view-count/like updates commit immediately, same as
  before — SQLite auto-commits each statement, so `Database.commit()` is
  a documented no-op kept only for parity with the Python code's
  explicit `connection.commit()` calls.

## Recent improvements

- **"Last Viewed" now updates immediately on Return.** The database always
  wrote a fresh `viewed_time` when you played something; the visible column
  just wasn't refreshed until the next full reload. Fixed.
- **Window size/position and the split-divider position are now remembered**
  across launches (via `NSWindow.setFrameAutosaveName` and
  `NSSplitView.autosaveName` — no extra code to maintain, AppKit handles the
  persistence itself).
- **A status line under the condition field** now shows the result count, or
  the actual SQL error if your condition/order text is malformed — previously
  a bad query and zero real matches looked identical (both just showed an
  empty table; the error only ever went to the console).
- **Likes/dislikes are now color-coded** in the Likes column — green once a
  row is liked, red once it's taken a dislike — as a quick visual cue for how
  close a row is to the two-dislikes-deletes-it threshold.

A couple of ideas I'd suggest but didn't implement (happy to if you want
them): canceling in-flight preview generation when you arrow past a row
quickly (right now a fast scrub can leave a few stray `ffmpeg` processes
finishing in the background — harmless, just not free), and caching
generated thumbnails to disk so they survive an app restart instead of
just the current session.

## Project layout

```
Package.swift
Sources/VideoIndex/
  main.swift                 – entry point, CLI args, NSApplication setup
  AppDelegate.swift          – window creation
  PlayerViewController.swift – table, search/condition fields, all actions
  ShortcutTableView.swift    – keyboard-shortcut handling
  ClickableThumbnailView.swift – click handling + cursor for Up Next thumbnails
  Database.swift             – SQLite wrapper (queries/updates/delete)
  MediaItem.swift            – row model

Preview generation (AVFoundation + ffmpeg fallback) lives directly in
`PlayerViewController.swift`: `buildPreviewPanel()`/`updatePreview(for:)`
for the filmstrip, `buildUpNextColumn()`/`refreshUpNext()` for the
"Up Next" column, and the shared `loadDuration`/
`generateFrame` helpers both use.
```
