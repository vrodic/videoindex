package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
)

// "videoindex mpv-setup" configures an mpv:// URL handler on macOS or Linux
// so clicking an item or thumbnail in the web viewer can launch mpv locally.
//
// On macOS, it creates a lightweight application bundle ~/Applications/mpv-handler.app
// with CFBundleURLTypes registered for the "mpv" scheme, invoking mpv with the
// requested filepath, start percentage, volume, etc.
// On Linux, it installs an ~/.local/share/applications/mpv-handler.desktop file
// and registers x-scheme-handler/mpv with xdg-mime.

func mpvSetupCmd(args []string) {
	fs := flag.NewFlagSet("mpv-setup", flag.ExitOnError)
	remove := fs.Bool("remove", false, "uninstall the mpv URL handler")
	fs.Usage = func() {
		fmt.Fprintf(os.Stderr, `usage: videoindex mpv-setup [-remove]

Registers a system-wide "mpv://" URL handler to launch mpv directly from the
web viewer with local or SMB mounts.

`)
		fs.PrintDefaults()
	}
	fs.Parse(args)

	switch runtime.GOOS {
	case "darwin":
		setupDarwin(*remove)
	case "linux":
		setupLinux(*remove)
	default:
		log.Fatalf("mpv-setup is not supported on %s", runtime.GOOS)
	}
}

const handlerPythonScript = `#!/usr/bin/env python3
import os
import shutil
import subprocess
import sys
import urllib.parse

def find_mpv():
    path = shutil.which("mpv")
    if path and os.path.isfile(path) and os.access(path, os.X_OK):
        return path
    for cand in ["/opt/homebrew/bin/mpv", "/usr/local/bin/mpv", "/usr/bin/mpv"]:
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    return "mpv"

def main():
    if len(sys.argv) < 2:
        return
    raw = sys.argv[1]
    target = ""
    args = []

    if raw.startswith("mpv://play/?"):
        query = raw[len("mpv://play/?"):]
        qs = urllib.parse.parse_qs(query)
        target = qs.get("url", [""])[0]
        if "start" in qs:
            args.append(f"--start={qs['start'][0]}")
        if "volume" in qs:
            args.append(f"--volume={qs['volume'][0]}")
        if "volume-max" in qs:
            args.append(f"--volume-max={qs['volume-max'][0]}")
        if "autofit" in qs:
            args.append(f"--autofit={qs['autofit'][0]}")
    elif raw.startswith("mpv://"):
        target = urllib.parse.unquote(raw[len("mpv://"):])

    if target:
        mpv_bin = find_mpv()
        cmd = [mpv_bin] + args + ["--", target]
        subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

if __name__ == "__main__":
    main()
`

func setupDarwin(remove bool) {
	home, err := os.UserHomeDir()
	if err != nil {
		log.Fatal(err)
	}
	appDir := filepath.Join(home, "Applications", "mpv-handler.app")
	if remove {
		if err := os.RemoveAll(appDir); err != nil {
			log.Fatalf("remove %s: %v", appDir, err)
		}
		fmt.Println("Removed mpv URL handler from", appDir)
		return
	}

	contents := filepath.Join(appDir, "Contents")
	macos := filepath.Join(contents, "MacOS")
	if err := os.MkdirAll(macos, 0o755); err != nil {
		log.Fatal(err)
	}

	plist := `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>org.videoindex.mpv-handler</string>
    <key>CFBundleName</key>
    <string>mpv-handler</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>mpv-handler</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>mpv URL</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>mpv</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
`
	if err := os.WriteFile(filepath.Join(contents, "Info.plist"), []byte(plist), 0o644); err != nil {
		log.Fatal(err)
	}

	binPath := filepath.Join(macos, "mpv-handler")
	if err := os.WriteFile(binPath, []byte(handlerPythonScript), 0o755); err != nil {
		log.Fatal(err)
	}

	// Register with macOS Launch Services
	exec.Command("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", "-f", appDir).Run()

	fmt.Printf("Installed mpv URL handler at %s\nRegistered mpv:// protocol handler.\n", appDir)
}

func setupLinux(remove bool) {
	home, err := os.UserHomeDir()
	if err != nil {
		log.Fatal(err)
	}
	appsDir := filepath.Join(home, ".local", "share", "applications")
	binDir := filepath.Join(home, ".local", "bin")
	desktopPath := filepath.Join(appsDir, "mpv-handler.desktop")
	binPath := filepath.Join(binDir, "videoindex-mpv-handler")

	if remove {
		os.Remove(desktopPath)
		os.Remove(binPath)
		exec.Command("update-desktop-database", appsDir).Run()
		fmt.Println("Removed mpv URL handler.")
		return
	}

	if err := os.MkdirAll(appsDir, 0o755); err != nil {
		log.Fatal(err)
	}
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		log.Fatal(err)
	}

	if err := os.WriteFile(binPath, []byte(handlerPythonScript), 0o755); err != nil {
		log.Fatal(err)
	}

	desktop := fmt.Sprintf(`[Desktop Entry]
Type=Application
Name=mpv-handler
Exec=%s %%u
Terminal=false
MimeType=x-scheme-handler/mpv;
`, binPath)

	if err := os.WriteFile(desktopPath, []byte(desktop), 0o644); err != nil {
		log.Fatal(err)
	}

	exec.Command("update-desktop-database", appsDir).Run()
	exec.Command("xdg-mime", "default", "mpv-handler.desktop", "x-scheme-handler/mpv").Run()
	fmt.Printf("Installed and registered mpv URL handler (%s)\n", desktopPath)
}
