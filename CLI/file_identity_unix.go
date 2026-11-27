//go:build !windows

package main

import (
	"fmt"
	"os"
	"syscall"
)

func fileIdentity(f *os.File) (string, error) {
	st, e := f.Stat()
	if e != nil {
		return "", e
	}
	s, ok := st.Sys().(*syscall.Stat_t)
	if !ok {
		return "", fmt.Errorf("file identity is unavailable")
	}
	return fmt.Sprintf("%d:%d", s.Dev, s.Ino), nil
}
