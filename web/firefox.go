package main

// "videoindex firefox-setup" makes Firefox open the player window with no
// browser chrome: no address bar, no toolbars, just the window manager's
// title bar around the video.
//
// A page can't do this itself. Firefox always shows a read-only address bar in
// pop-up windows, and the old dom.disable_window_open_feature.* prefs that
// could turn it off are gone. What still works is a userChrome.css rule. This
// command writes one into the Firefox profiles, scoped to pop-up windows whose
// page title ends in "videoindex player" (player.js sets that), so other
// pop-ups (sign-in windows and so on) keep their address bar.

import (
	"bufio"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

const (
	ffBegin = "/* videoindex:begin (managed by \"videoindex firefox-setup\") */"
	ffEnd   = "/* videoindex:end */"

	// Pop-up windows have "toolbar" in chromehidden; the tab label is the page
	// title. Hide the address bar row and anything else that might show.
	ffCSS = `:root[chromehidden~="toolbar"]:has(.tabbrowser-tab[selected][label$="videoindex player"]) :is(#nav-bar, #PersonalToolbar, #TabsToolbar, #sidebar-main, #sidebar-box, #sidebar-splitter) {
  visibility: collapse !important;
}
:root[chromehidden~="toolbar"]:has(.tabbrowser-tab[selected][label$="videoindex player"]) #navigator-toolbox {
  border-bottom: 0 !important;
}`

	ffPref     = `user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);`
	ffPrefMark = "// videoindex: let userChrome.css hide the player window's address bar"
)

func firefoxSetupCmd(args []string) {
	fs := flag.NewFlagSet("firefox-setup", flag.ExitOnError)
	profile := fs.String("profile", "", "Firefox profile directory (default: the default profile of each Firefox installation)")
	remove := fs.Bool("remove", false, "remove the videoindex rules again")
	fs.Usage = func() {
		fmt.Fprintf(os.Stderr, `usage: videoindex firefox-setup [-profile DIR] [-remove]

Hides the address bar and toolbars of the player window in Firefox by adding
a rule to the profile's chrome/userChrome.css (and enabling userChrome.css in
user.js). Only the videoindex player pop-up is affected. Restart Firefox after
running it.

`)
		fs.PrintDefaults()
	}
	fs.Parse(args)

	var profiles []string
	if *profile != "" {
		profiles = []string{*profile}
	} else {
		var err error
		if profiles, err = firefoxProfiles(); err != nil {
			log.Fatal(err)
		}
		if len(profiles) == 0 {
			log.Fatal("no Firefox profile found; pass -profile DIR (see about:support → Profile Directory)")
		}
	}
	for _, p := range profiles {
		if st, err := os.Stat(p); err != nil || !st.IsDir() {
			log.Fatalf("%s is not a profile directory", p)
		}
		css := filepath.Join(p, "chrome", "userChrome.css")
		userJS := filepath.Join(p, "user.js")
		var err error
		if *remove {
			err = rewriteManaged(css, "")
			// The pref stays: the user may rely on userChrome.css for other things.
		} else {
			if err = os.MkdirAll(filepath.Dir(css), 0o755); err == nil {
				err = rewriteManaged(css, ffCSS)
			}
			if err == nil {
				err = ensurePref(userJS)
			}
		}
		if err != nil {
			log.Fatalf("%s: %v", p, err)
		}
		if *remove {
			fmt.Println("removed from", p)
		} else {
			fmt.Println("updated", p)
		}
	}
	fmt.Println("Restart Firefox for the change to take effect.")
}

// firefoxProfiles returns the profiles Firefox installations start with: the
// Default= of each [Install…] section, or the Default=1 profile when there
// are none.
func firefoxProfiles() ([]string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	cfg := os.Getenv("XDG_CONFIG_HOME")
	if cfg == "" {
		cfg = filepath.Join(home, ".config")
	}
	var out []string
	seen := map[string]bool{}
	for _, base := range []string{
		filepath.Join(home, ".mozilla", "firefox"),
		filepath.Join(cfg, "mozilla", "firefox"),
		filepath.Join(home, ".var", "app", "org.mozilla.firefox", ".mozilla", "firefox"), // flatpak
		filepath.Join(home, "snap", "firefox", "common", ".mozilla", "firefox"),
	} {
		sections, err := readINI(filepath.Join(base, "profiles.ini"))
		if os.IsNotExist(err) {
			continue
		} else if err != nil {
			return nil, err
		}
		var picks []string
		for name, kv := range sections {
			if strings.HasPrefix(name, "Install") && kv["Default"] != "" {
				picks = append(picks, kv["Default"])
			}
		}
		if len(picks) == 0 {
			for name, kv := range sections {
				if strings.HasPrefix(name, "Profile") && kv["Default"] == "1" {
					picks = append(picks, kv["Path"])
				}
			}
		}
		for _, p := range picks {
			if !filepath.IsAbs(p) {
				p = filepath.Join(base, p)
			}
			if !seen[p] {
				seen[p] = true
				out = append(out, p)
			}
		}
	}
	return out, nil
}

func readINI(path string) (map[string]map[string]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	out := map[string]map[string]string{}
	var cur map[string]string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		switch {
		case line == "" || line[0] == ';' || line[0] == '#':
		case line[0] == '[' && strings.HasSuffix(line, "]"):
			cur = map[string]string{}
			out[line[1:len(line)-1]] = cur
		case cur != nil:
			if k, v, ok := strings.Cut(line, "="); ok {
				cur[strings.TrimSpace(k)] = strings.TrimSpace(v)
			}
		}
	}
	return out, sc.Err()
}

var managedRE = regexp.MustCompile(`(?s)\n?` + regexp.QuoteMeta(ffBegin) + `.*?` + regexp.QuoteMeta(ffEnd) + `\n?`)

// rewriteManaged replaces the videoindex block in path with body (or removes
// it when body is empty), leaving the rest of the file alone.
func rewriteManaged(path, body string) error {
	old, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	if os.IsNotExist(err) && body == "" {
		return nil
	}
	s := managedRE.ReplaceAllString(string(old), "\n")
	s = strings.TrimRight(s, "\n")
	if body != "" {
		if s != "" {
			s += "\n\n"
		}
		s += ffBegin + "\n" + body + "\n" + ffEnd
	}
	if s != "" {
		s += "\n"
	}
	return os.WriteFile(path, []byte(s), 0o644)
}

// ensurePref turns on userChrome.css support in user.js unless it already is.
func ensurePref(path string) error {
	old, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	if strings.Contains(string(old), `"toolkit.legacyUserProfileCustomizations.stylesheets", true`) {
		return nil
	}
	s := strings.TrimRight(string(old), "\n")
	if s != "" {
		s += "\n"
	}
	s += ffPrefMark + "\n" + ffPref + "\n"
	return os.WriteFile(path, []byte(s), 0o644)
}
