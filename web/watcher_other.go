//go:build !linux

package main

import "errors"

func newWatchBackend() (watchBackend, error) {
	return nil, errors.New("only supported on Linux (inotify)")
}

func openForWriting(string) bool { return false }
