//go:build windows

package account

import (
	"golang.org/x/sys/windows"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"unsafe"
)

func agyWithLock(home string, use func() error) error {
	dir := agyCache(home)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	f, err := os.OpenFile(filepath.Join(dir, "antigravity.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	defer f.Close()
	var overlapped windows.Overlapped
	h := windows.Handle(f.Fd())
	if err = windows.LockFileEx(h, windows.LOCKFILE_EXCLUSIVE_LOCK, 0, 1, 0, &overlapped); err != nil {
		return err
	}
	defer windows.UnlockFileEx(h, 0, 1, 0, &overlapped)
	return use()
}

func agyShell(command string) *exec.Cmd {
	interpreter := filepath.Join(os.Getenv("SystemRoot"), "System32", "cmd.exe")
	cmd := exec.Command(interpreter)
	cmd.SysProcAttr = &syscall.SysProcAttr{CmdLine: `cmd.exe /d /s /c "` + command + `"`, HideWindow: true}
	return cmd
}

func agyControlProcess(p *os.Process) (func(bool), error) {
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return nil, err
	}
	info := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{}
	info.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	_, err = windows.SetInformationJobObject(job, windows.JobObjectExtendedLimitInformation, uintptr(unsafe.Pointer(&info)), uint32(unsafe.Sizeof(info)))
	if err == nil {
		var proc windows.Handle
		proc, err = windows.OpenProcess(windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE, false, uint32(p.Pid))
		if err == nil {
			err = windows.AssignProcessToJobObject(job, proc)
			windows.CloseHandle(proc)
		}
	}
	if err != nil {
		windows.CloseHandle(job)
		return nil, err
	}
	return func(bool) { windows.CloseHandle(job) }, nil
}
