#!/usr/bin/env python3
"""
Scan a directory tree with ffprobe and store video metadata in SQLite.

Files that could not be probed (or have no width/height/duration) are
remembered in a separate `skipped_files` table and are not probed again
unless --rescan-skipped is given.

Usage:
    media_scanner.py <root_dir> <db_file> [--rescan-skipped] [--workers N]
"""
import os
import sys
import json
import sqlite3
import argparse
import subprocess
from concurrent.futures import ThreadPoolExecutor

SKIP_EXT = {
    '.jpg', '.gif', '.jpeg', '.nfo', '.png', '.srt', '.zip', '.rar', '.vtx',
    '.parts', '.mp3', '.txt', '.wma', '.ogg', '.mp2', '.ini', '.webp'
}
DEFAULT_WORKERS = 8  # tune: try 4-16; use fewer on HDD / network shares
BATCH_SIZE = 200     # rows per commit
PROBE_TIMEOUT = 60   # seconds per file


def probe(path):
    """Run ffprobe asking only for the fields we store.

    Returns (metadata_dict, None) on success or (None, error_message) on failure.
    """
    cmd = [
        'ffprobe', '-v', 'error', '-print_format', 'json',
        '-show_entries',
        'format=duration:stream=codec_type,codec_name,width,height,nb_frames'
        ':stream_tags=creation_time',
        path,
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, timeout=PROBE_TIMEOUT)
    except subprocess.TimeoutExpired:
        return None, f'timeout after {PROBE_TIMEOUT}s'
    except FileNotFoundError:
        return None, 'ffprobe not found in PATH'
    except Exception as ex:
        return None, str(ex)

    if result.returncode != 0:
        err = result.stderr.decode('utf-8', errors='replace').strip()
        # keep only the last line, which is usually the actual reason
        err = err.splitlines()[-1] if err else f'ffprobe exit code {result.returncode}'
        return None, err

    try:
        return json.loads(result.stdout), None
    except Exception as ex:
        return None, f'invalid ffprobe output: {ex}'


def extract(relative_name, path):
    """Runs in a worker thread.

    Returns (row_tuple | None, status, detail) where status is one of:
    'ok', 'probe_error', 'no_width_or_duration', 'metadata_error'.
    """
    meta, err = probe(path)
    if meta is None:
        return None, 'probe_error', err

    try:
        streams = meta.get('streams', [])
        # first stream that actually has dimensions (i.e. a real video stream)
        s = next((x for x in streams if x.get('width')), None)
        duration = meta.get('format', {}).get('duration')

        if s is None or not s.get('height') or not duration:
            missing = []
            if s is None or not s.get('width'):
                missing.append('width')
            if s is None or not s.get('height'):
                missing.append('height')
            if not duration:
                missing.append('duration')
            return None, 'no_width_or_duration', 'missing ' + '/'.join(missing)

        row = (
            relative_name,
            float(duration),
            s.get('codec_name'),
            s['width'],
            s['height'],
            s.get('nb_frames'),
            s.get('tags', {}).get('creation_time'),
            os.path.getsize(path),
        )
        return row, 'ok', None
    except Exception as ex:
        return None, 'metadata_error', str(ex)


class Scanner:
    def __init__(self, root_dir, db_file, rescan_skipped=False, workers=DEFAULT_WORKERS):
        self.root_dir = root_dir
        self.rescan_skipped = rescan_skipped
        self.workers = workers
        self.connection = sqlite3.connect(db_file)
        self.cursor = self.connection.cursor()
        self.cursor.execute('''CREATE TABLE IF NOT EXISTS media
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
                             viewed_time datetime
                             )''')
        self.cursor.execute(
            'CREATE INDEX IF NOT EXISTS idx_media_filename ON media(filename)')
        self.cursor.execute('''CREATE TABLE IF NOT EXISTS skipped_files
                             (filename text PRIMARY KEY,
                             reason text,
                             detail text,
                             skipped_time datetime
                             )''')
        self.connection.commit()

        self.skipped_ext = 0
        self.already_scanned = 0
        self.already_skipped = 0
        self.added = 0
        self.recovered = 0   # previously skipped files that now probe fine
        self.probe_errors = 0
        self.no_dims = 0
        self.metadata_errors = 0

    def collect(self):
        """Cheap pass: walk the tree and decide what actually needs probing."""
        known = {r[0] for r in self.cursor.execute('SELECT filename FROM media')}
        skipped_db = {r[0] for r in self.cursor.execute('SELECT filename FROM skipped_files')}
        self.previously_skipped = skipped_db

        todo = []
        for folder, _, files in os.walk(self.root_dir, followlinks=True):
            for name in files:
                if os.path.splitext(name)[1].lower() in SKIP_EXT:
                    self.skipped_ext += 1
                    continue
                path = os.path.join(folder, name)
                rel = os.path.relpath(path, self.root_dir)
                if rel in known:
                    self.already_scanned += 1
                    continue
                if rel in skipped_db and not self.rescan_skipped:
                    self.already_skipped += 1
                    continue
                todo.append((rel, path))
        return todo

    def flush(self, rows, skipped_rows):
        """Write one batch (successes + failures) in a single transaction."""
        if rows:
            self.cursor.executemany(
                "INSERT INTO media "
                "(filename,duration,codec_name,width,height,nb_frames,"
                "creation_time,file_size) VALUES(?,?,?,?,?,?,?,?)", rows)
            # a file that now probes fine must leave the skipped table
            self.cursor.executemany(
                "DELETE FROM skipped_files WHERE filename=?",
                [(r[0],) for r in rows])
            self.added += len(rows)
            self.recovered += sum(1 for r in rows if r[0] in self.previously_skipped)
        if skipped_rows:
            self.cursor.executemany(
                "INSERT OR REPLACE INTO skipped_files "
                "(filename,reason,detail,skipped_time) "
                "VALUES(?,?,?,datetime('now'))", skipped_rows)
        if rows or skipped_rows:
            self.connection.commit()

    def scan(self):
        todo = self.collect()
        mode = " (rescanning previously skipped files)" if self.rescan_skipped else ""
        print(f"{len(todo)} files to probe{mode}")

        batch = []          # rows for the media table
        skipped_batch = []  # rows for the skipped_files table
        failed_probe = []
        no_dims = []
        meta_errors = []

        def flush_if_full():
            nonlocal batch, skipped_batch
            if len(batch) + len(skipped_batch) >= BATCH_SIZE:
                self.flush(batch, skipped_batch)
                batch, skipped_batch = [], []
                print('.', end='', flush=True)

        with ThreadPoolExecutor(max_workers=self.workers) as pool:
            results = pool.map(lambda t: extract(*t), todo)
            for (rel, _), (row, status, detail) in zip(todo, results):
                if row:
                    batch.append(row)
                    flush_if_full()
                    continue

                skipped_batch.append((rel, status, detail))
                if status == 'probe_error':
                    self.probe_errors += 1
                    failed_probe.append((rel, detail))
                    print(f"\nProbe failed: {rel}  [{detail}]", flush=True)
                elif status == 'no_width_or_duration':
                    self.no_dims += 1
                    no_dims.append((rel, detail))
                    print(f"\nSkipped ({detail}): {rel}", flush=True)
                else:
                    self.metadata_errors += 1
                    meta_errors.append((rel, detail))
                    print(f"\nMetadata error: {rel}  [{detail}]", flush=True)
                flush_if_full()

        self.flush(batch, skipped_batch)

        print("\n")
        print("Files already scanned:", self.already_scanned)
        print("Skipped (extension):", self.skipped_ext)
        print("Skipped (failed in an earlier run):", self.already_skipped)
        if self.already_skipped:
            print("  -> use --rescan-skipped to probe them again")
        print("Skipped now (no width/duration):", self.no_dims)
        print("Probe failures now:", self.probe_errors)
        print("Metadata errors now:", self.metadata_errors)
        print("Added:", self.added)
        if self.rescan_skipped:
            print("Recovered from skipped list:", self.recovered)

        if failed_probe:
            print("\n--- Files that failed the probe ---")
            for rel, detail in failed_probe:
                print(f"{rel}  [{detail}]")

        if no_dims:
            print("\n--- Files skipped: no width/duration ---")
            for rel, detail in no_dims:
                print(f"{rel}  [{detail}]")

        if meta_errors:
            print("\n--- Files with metadata errors ---")
            for rel, detail in meta_errors:
                print(f"{rel}  [{detail}]")


def main():
    parser = argparse.ArgumentParser(description="Scan media files with ffprobe into SQLite.")
    parser.add_argument('root_dir', help="directory to scan")
    parser.add_argument('db_file', help="SQLite database file")
    parser.add_argument('--rescan-skipped', action='store_true',
                        help="probe files in the skipped_files table again")
    parser.add_argument('--workers', type=int, default=DEFAULT_WORKERS,
                        help=f"parallel ffprobe processes (default {DEFAULT_WORKERS})")
    args = parser.parse_args()

    Scanner(args.root_dir, args.db_file,
            rescan_skipped=args.rescan_skipped, workers=args.workers).scan()


if __name__ == '__main__':
    main()
    