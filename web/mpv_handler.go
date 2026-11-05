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
// On macOS, it builds a native Cocoa app bundle ~/Applications/mpv-handler.app
// with CFBundleURLTypes registered for the "mpv" scheme and TCC usage descriptions
// for network and disk volumes.
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

const darwinSwiftSource = `import Cocoa

func logMsg(_ msg: String) {
    let path = ("~/Library/Logs/videoindex-mpv-handler.log" as NSString).expandingTildeInPath
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
    if let data = line.data(using: .utf8) {
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

func findMpv() -> String {
    for cand in ["/opt/homebrew/bin/mpv", "/usr/local/bin/mpv", "/usr/bin/mpv"] {
        if FileManager.default.isExecutableFile(atPath: cand) {
            return cand
        }
    }
    return "mpv"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleURL(url.absoluteString)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            NSApp.terminate(nil)
        }
    }

    func handleURL(_ raw: String) {
        var target = ""
        var args: [String] = []

        if raw.hasPrefix("mpv://play/?") {
            let qs = String(raw.dropFirst("mpv://play/?".count))
            let comps = URLComponents(string: "http://dummy/?" + qs)
            let items = comps?.queryItems ?? []
            for item in items {
                switch item.name {
                case "url":
                    let rawVal = item.value ?? ""
                    target = rawVal.replacingOccurrences(of: "+", with: " ")
                case "start":
                    if let v = item.value { args.append("--start=\(v)") }
                case "volume":
                    if let v = item.value { args.append("--volume=\(v)") }
                case "volume-max":
                    if let v = item.value { args.append("--volume-max=\(v)") }
                case "autofit":
                    if let v = item.value { args.append("--autofit=\(v)") }
                default:
                    break
                }
            }
        } else if raw.hasPrefix("mpv://") {
            let encoded = String(raw.dropFirst("mpv://".count))
            let unquoted = encoded.removingPercentEncoding ?? encoded
            target = unquoted.replacingOccurrences(of: "+", with: " ")
        }

        guard !target.isEmpty else {
            logMsg("Error: Target URL is empty (raw URL: \(raw))")
            return
        }

        let exists = FileManager.default.fileExists(atPath: target)
        if !exists {
            logMsg("Error: File not found at path: \(target)")
            return
        }

        let mpvBin = findMpv()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: mpvBin)
        proc.arguments = args + ["--", target]
        proc.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus != 0 {
                let outData = pipe.fileHandleForReading.readDataToEndOfFile()
                let outStr = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                logMsg("mpv exited with error code \(proc.terminationStatus) for file \(target)\nCommand: \(mpvBin) \(args.joined(separator: " ")) -- \(target)\nOutput:\n\(outStr)")
            }
        } catch {
            logMsg("Failed to launch mpv: \(error) (binary: \(mpvBin), target: \(target))")
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
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

	// Write Swift source and compile native Cocoa application binary
	tmpSwift := filepath.Join(os.TempDir(), "mpv_handler_main.swift")
	if err := os.WriteFile(tmpSwift, []byte(darwinSwiftSource), 0o644); err != nil {
		log.Fatal(err)
	}
	defer os.Remove(tmpSwift)

	binPath := filepath.Join(macos, "mpv-handler")
	cmd := exec.Command("swiftc", "-O", "-o", binPath, tmpSwift)
	if out, err := cmd.CombinedOutput(); err != nil {
		log.Fatalf("swiftc failed: %v\n%s", err, string(out))
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
    <key>LSUIElement</key>
    <true/>
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
    <key>NSNetworkVolumesUsageDescription</key>
    <string>videoindex needs access to network volumes to play media in mpv</string>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>videoindex needs access to removable volumes to play media in mpv</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>videoindex needs access to documents to play media in mpv</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>videoindex needs access to downloads to play media in mpv</string>
</dict>
</plist>
`
	if err := os.WriteFile(filepath.Join(contents, "Info.plist"), []byte(plist), 0o644); err != nil {
		log.Fatal(err)
	}

	// Register with macOS Launch Services
	exec.Command("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", "-f", appDir).Run()

	fmt.Printf("Installed native mpv URL handler at %s\nRegistered mpv:// protocol handler.\n", appDir)
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

	linuxPythonScript := `#!/usr/bin/env python3
import datetime
import os
import shutil
import subprocess
import sys
import urllib.parse

LOG_PATH = "/tmp/videoindex-mpv-handler.log"

def log(msg):
    try:
        with open(LOG_PATH, "a") as f:
            f.write(f"[{datetime.datetime.now().isoformat()}] {msg}\n")
    except Exception:
        pass

def find_mpv():
    path = shutil.which("mpv")
    if path and os.path.isfile(path) and os.access(path, os.X_OK):
        return path
    for cand in ["/usr/bin/mpv", "/usr/local/bin/mpv"]:
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
        if not os.path.exists(target):
            log(f"Error: File not found at path: {target}")
            return
        mpv_bin = find_mpv()
        cmd = [mpv_bin] + args + ["--", target]
        try:
            proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            stdout, _ = proc.communicate()
            if proc.returncode != 0:
                log(f"mpv exited with error code {proc.returncode} for file {target}\nCommand: {cmd}\nOutput:\n{stdout.strip()}")
        except Exception as e:
            log(f"Failed to launch mpv: {e} (cmd: {cmd})")

if __name__ == "__main__":
    main()
`

	if err := os.WriteFile(binPath, []byte(linuxPythonScript), 0o755); err != nil {
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
