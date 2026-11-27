//go:build darwin || linux

package account

import (
	"golang.org/x/sys/unix"
	"os"
	"os/exec"
)

func agyWithLock(home string, use func() error) error {
	dir := agyCache(home)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	f, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer f.Close()
	for {
		err = unix.Flock(int(f.Fd()), unix.LOCK_EX)
		if err != unix.EINTR {
			break
		}
	}
	if err != nil {
		return err
	}
	defer unix.Flock(int(f.Fd()), unix.LOCK_UN)
	return use()
}

func agyShell(command string) *exec.Cmd { return exec.Command("/bin/sh", "-c", command) }

func agyControlProcess(p *os.Process) (func(bool), error) {
	// PTY starts its child in a new session. End outstanding status-line helpers too.
	return func(exited bool) {
		if !exited {
			_ = unix.Kill(-p.Pid, unix.SIGKILL)
		}
	}, nil
}
