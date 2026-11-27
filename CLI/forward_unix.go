//go:build !windows

package main

import (
	"os"
	"syscall"
)

// Replace the launcher so closing the GUI also terminates its pairing session.
func (s *Store) forward(version string) error {
	path := s.buildPath(version)
	return syscall.Exec(path, append([]string{path}, os.Args[1:]...), os.Environ())
}
