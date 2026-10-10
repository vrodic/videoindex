# VideoIndex (Linux C++ / Qt6 Port)

A Linux C++/Qt6 translation of the macOS VideoIndex application.

## Requirements

- Qt 6 (Widgets, Sql)
- SQLite3 (`libsqlite3-dev`)
- CMake 3.16+
- C++17 compiler (`g++` / `clang++`)
- `mpv` installed for video playback
- `ffmpeg` / `ffprobe` installed for thumbnail frame extraction

On Ubuntu / Debian:
```bash
sudo apt-get install -y qt6-base-dev libsqlite3-dev cmake build-essential mpv ffmpeg
```

## Build & Run

```bash
cd linux
mkdir build && cd build
cmake ..
make -j$(nproc)

./VideoIndex /path/to/media/root /path/to/index.db
```

## Features

- **8 Table Columns:** ID, Filename, Views, Likes, Size (MB), Last Viewed, Width, Density with column header sorting.
- **Search & Filter:** Substring filename search + free-form SQL WHERE / ORDER BY condition box with preset queries and saved custom queries history.
- **Word Cloud Search:** Paginated window displaying font-scaled, color-coded word frequencies with a toggle between "All Words" and "Full Names (first_last)".
- **Preview & Up Next Panels:**
  - 6-percentage filmstrip (15%, 30%, 45%, 60%, 75%, 90%) generated via `ffmpeg`/`ffprobe`. Clicking a preview thumbnail plays video starting at `--start=X%`.
  - Up Next strip displaying up to 10 upcoming video thumbnails with a permanent border on the current video. Clicking an Up Next thumbnail jumps the table selection to that item.
- **Thumbnail Disk Caching:** Extracted frame thumbnails are cached in `<rootDir>/Thumbs` (JPEG, 80% quality), with an option in the Options menu to toggle disk persistence.
- **Custom Table Styling:**
  - Color-coded Likes column.
  - Dark red highlight for missing files.
  - Green background tint for videos played during the active session.
  - Blue background tint for previously viewed videos.
- **MPV Menu Controls:** Configurable volume presets, max volume 1000, autofit window sizes, playback speed, mute, loop, keep-open, ontop, and hardware decoding.
- **Keyboard Navigation:** Return to play, Delete to dislike/delete, Insert / `+` / `=` to like & advance, Home / End, Escape to quit.
