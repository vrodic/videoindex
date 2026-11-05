// Command videoindex is a web front-end for a SQLite index of a video
// library: browse/search/rate files, play them in the browser, and scan
// the library with ffprobe to keep the index up to date.
//
//	videoindex serve -root /srv/videos [-db /srv/xv.db] [-listen :8080]
//	videoindex scan  -root /srv/videos [-db /srv/xv.db] [-rescan-skipped] [-workers 8]
//	videoindex firefox-setup [-profile DIR] [-remove]
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"time"
)

func usage() {
	fmt.Fprintf(os.Stderr, `usage:
  videoindex serve [flags]   run the web UI / video server
  videoindex scan  [flags]   probe new files under the root into the database
  videoindex firefox-setup   hide Firefox's address bar in the player window
  videoindex mpv-setup       register mpv:// URL handler for launching mpv locally

Run "videoindex <command> -h" for the flags of each command.
Every flag can also be set through an environment variable (shown in -h).
`)
	os.Exit(2)
}

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	switch os.Args[1] {
	case "serve":
		serveCmd(os.Args[2:])
	case "scan":
		scanCmd(os.Args[2:])
	case "firefox-setup":
		firefoxSetupCmd(os.Args[2:])
	case "mpv-setup":
		mpvSetupCmd(os.Args[2:])
	case "-h", "--help", "help":
		usage()
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n\n", os.Args[1])
		usage()
	}
}

// envDefault returns $name if set, otherwise def.
func envDefault(name, def string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return def
}

func commonFlags(fs *flag.FlagSet) (root, db *string) {
	root = fs.String("root", envDefault("VIDEOINDEX_ROOT", ""), "media root directory; filenames in the DB are relative to it ($VIDEOINDEX_ROOT)")
	db = fs.String("db", envDefault("VIDEOINDEX_DB", ""), "SQLite index file (default <root>/videoindex.db) ($VIDEOINDEX_DB)")
	return
}

// requireDirs validates -root and fills in the default -db
// (<root>/videoindex.db) when none was given.
func requireDirs(fs *flag.FlagSet, root string, db *string) {
	if root == "" {
		fmt.Fprintln(os.Stderr, "-root is required")
		fs.Usage()
		os.Exit(2)
	}
	if st, err := os.Stat(root); err != nil || !st.IsDir() {
		log.Fatalf("root %q is not a readable directory", root)
	}
	if *db == "" {
		*db = filepath.Join(root, "videoindex.db")
	}
}

func serveCmd(args []string) {
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	root, dbPath := commonFlags(fs)
	listen := fs.String("listen", envDefault("VIDEOINDEX_LISTEN", ":8080"), "HTTP listen address ($VIDEOINDEX_LISTEN)")
	thumbs := fs.String("thumbs", envDefault("VIDEOINDEX_THUMBS", ""), "thumbnail cache directory (default <root>/Thumbs) ($VIDEOINDEX_THUMBS)")
	auth := fs.String("auth", envDefault("VIDEOINDEX_AUTH", ""), "require HTTP basic auth, as user:password ($VIDEOINDEX_AUTH)")
	thumbWorkers := fs.Int("thumb-workers", 2, "max concurrent ffmpeg thumbnail extractions")
	transcodes := fs.Int("max-transcodes", 2, "max concurrent ffmpeg playback transcodes")
	watch := fs.Bool("watch", envDefault("VIDEOINDEX_WATCH", defaultWatch) != "0", "watch the root for new files and index them once complete; Linux only ($VIDEOINDEX_WATCH=0 to disable)")
	settle := fs.Duration("watch-settle", 30*time.Second, "how long a new file must be left untouched before it is probed")
	allowDelete := fs.Bool("allow-delete", envDefault("VIDEOINDEX_ALLOW_DELETE", "1") != "0", "let the second dislike delete the file from disk ($VIDEOINDEX_ALLOW_DELETE=0 to disable)")
	fs.Parse(args)
	requireDirs(fs, *root, dbPath)

	absRoot, err := filepath.Abs(*root)
	if err != nil {
		log.Fatal(err)
	}
	if *thumbs == "" {
		*thumbs = filepath.Join(absRoot, "Thumbs")
	}

	store, err := OpenStore(*dbPath)
	if err != nil {
		log.Fatalf("open db: %v", err)
	}
	defer store.Close()

	app := &App{
		Root:        absRoot,
		Store:       store,
		DBPath:      *dbPath,
		AllowDelete: *allowDelete,
		Media:       NewMediaService(absRoot, *thumbs, *thumbWorkers, *transcodes),
	}

	if store.IsEmpty() {
		log.Printf("database is empty; scanning %s", absRoot)
		if err := app.startScan(false, 8); err != nil {
			log.Printf("initial scan: %v", err)
		}
	}

	if *watch {
		w, err := StartWatcher(context.Background(), store, absRoot, *thumbs, *settle, func() { app.startScan(false, 8) })
		if err != nil {
			log.Printf("watch: %v", err)
		} else {
			app.Watcher = w
		}
	}

	var handler http.Handler = app.Routes()
	if *auth != "" {
		handler = basicAuth(*auth, handler)
	}

	log.Printf("videoindex: root=%s db=%s thumbs=%s listening on %s", absRoot, *dbPath, *thumbs, *listen)
	if err := http.ListenAndServe(*listen, handler); err != nil {
		log.Fatal(err)
	}
}

// The watcher needs inotify, so it is on by default only on Linux.
var defaultWatch = map[bool]string{true: "1", false: "0"}[runtime.GOOS == "linux"]

func scanCmd(args []string) {
	fs := flag.NewFlagSet("scan", flag.ExitOnError)
	root, dbPath := commonFlags(fs)
	rescan := fs.Bool("rescan-skipped", false, "probe files in the skipped_files table again")
	workers := fs.Int("workers", 8, "parallel ffprobe processes (try 4-16; fewer on HDD / network shares)")
	fs.Parse(args)
	requireDirs(fs, *root, dbPath)

	store, err := OpenStore(*dbPath)
	if err != nil {
		log.Fatalf("open db: %v", err)
	}
	defer store.Close()

	s := NewScanner(store, *root, *rescan, *workers, os.Stdout)
	if err := s.Run(); err != nil {
		log.Fatal(err)
	}
}
