package main

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestBundledServiceUpgrade(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("macOS service fixture uses a shell command")
	}
	const uid = "6789"
	s := testStore(t)
	src := filepath.Join(s.home, "TokenMeter.app", "Contents", "MacOS", binaryName())
	bootDir := filepath.Join(s.home, "LaunchDaemons")
	userPlist := filepath.Join(s.home, "Library", "LaunchAgents", macServiceLabel+".plist")
	bootPlist := filepath.Join(bootDir, macServiceLabel+"."+uid+".plist")
	launcher := filepath.Join(s.dir, "launcher", binaryName())
	eventFile := filepath.Join(s.home, "launchctl-events")
	binDir := t.TempDir()
	fake := filepath.Join(binDir, "launchctl")
	writeTestFile(t, fake, []byte("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$TEST_EVENTS\"\n[ \"$1\" = kill ] && [ \"$TEST_RESTART_FAIL\" != 1 ]\n"))
	check(t, os.Chmod(fake, 0700))
	t.Setenv("TEST_EVENTS", eventFile)
	t.Setenv("PATH", binDir)
	installs := 0
	ensure := func(build uint64) error {
		return s.ensureMacService(src, build, uid, bootDir, func() error {
			installs++
			writeTestFile(t, userPlist, []byte("user registration"))
			return nil
		})
	}
	expectContent := func(path, want string) {
		t.Helper()
		got, err := os.ReadFile(path)
		check(t, err)
		if string(got) != want {
			t.Fatalf("%s = %q, want %q", filepath.Base(path), got, want)
		}
	}
	writeTestFile(t, src, []byte("bundle one"))
	check(t, ensure(35))
	check(t, ensure(35))
	if installs != 1 {
		t.Fatalf("fresh service registered %d times", installs)
	}
	if _, err := os.Stat(eventFile); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("fresh installation was restarted: %v", err)
	}

	// Old installs have no synchronization receipt. Simulate the actual active
	// version string staying constant during a build 35 -> 36 app upgrade.
	check(t, os.Remove(filepath.Join(s.dir, "bundle-service.json")))
	writeTestFile(t, src, []byte("bundle two"))
	check(t, ensure(36))
	check(t, ensure(36))
	expectContent(launcher, "bundle two")
	expectContent(s.buildPath(version), "bundle two")
	userRestart := "kill SIGTERM gui/" + uid + "/" + macServiceLabel + "\n"
	expectContent(eventFile, userRestart)

	// An older GUI can be opened from another folder.
	writeTestFile(t, src, []byte("older bundle"))
	check(t, ensure(35))
	expectContent(s.buildPath(version), "bundle two")
	expectContent(eventFile, userRestart)

	// A boot service also wins if its installer has not removed the old user
	// plist yet. Neither registration is rewritten by an upgrade.
	writeTestFile(t, bootPlist, []byte("administrator registration"))
	writeTestFile(t, src, []byte("new content with the same build number"))
	check(t, ensure(36))
	check(t, ensure(36))
	systemRestart := "kill SIGTERM system/" + macServiceLabel + "." + uid + "\n"
	expectContent(eventFile, userRestart+systemRestart)
	expectContent(bootPlist, "administrator registration")
	expectContent(userPlist, "user registration")
	if installs != 1 {
		t.Fatalf("upgrade registered %d services", installs)
	}

	// A transient launchd error occurs after the binary has been copied. The
	// following GUI launch still needs to restart the service, exactly once.
	check(t, os.Remove(bootPlist))
	writeTestFile(t, src, []byte("next development build"))
	t.Setenv("TEST_RESTART_FAIL", "1")
	if err := ensure(37); err == nil {
		t.Fatal("lost launchctl failure")
	}
	t.Setenv("TEST_RESTART_FAIL", "")
	check(t, ensure(37))
	check(t, ensure(37))
	expectContent(eventFile, userRestart+systemRestart+userRestart+userRestart)

	// The automatic updater or a manual install can activate a newer CLI.
	check(t, s.activate(activeBuild{Version: "999.0.0", Previous: version}))
	writeTestFile(t, src, []byte("obsolete"))
	check(t, ensure(38))
	expectContent(launcher, "next development build")
	active, err := s.active()
	check(t, err)
	if active.Version != "999.0.0" {
		t.Fatalf("downgraded active CLI to %s", active.Version)
	}

	// Manual uninstall preserves the ledger and runtime; opening the app again
	// must not re-register it, even when the app itself was updated.
	check(t, s.activate(activeBuild{Version: version}))
	check(t, os.Remove(userPlist))
	check(t, ensure(38))
	if installs != 1 {
		t.Fatal("reinstalled a manually removed service")
	}
	expectContent(launcher, "next development build")
}

func TestBundleAdoptsIdenticalInstalledFiles(t *testing.T) {
	s := testStore(t)
	src := filepath.Join(s.home, "TokenMeter.app", "Contents", "MacOS", binaryName())
	userPlist := filepath.Join(s.home, "Library", "LaunchAgents", macServiceLabel+".plist")
	content := []byte("identical bundle, manual install")
	writeTestFile(t, src, content)
	writeTestFile(t, userPlist, []byte("installed"))
	for _, path := range []string{filepath.Join(s.dir, "launcher", binaryName()), s.buildPath(version)} {
		writeTestFile(t, path, content)
	}
	check(t, s.activate(activeBuild{Version: version}))
	t.Setenv("PATH", t.TempDir())
	check(t, s.ensureMacService(src, 36, "6789", t.TempDir(), func() error {
		return errors.New("unexpected registration")
	}))
	var receipt bundleServiceReceipt
	check(t, loadOptional(filepath.Join(s.dir, "bundle-service.json"), &receipt))
	if receipt.Pending != "" || receipt.Build != 36 || strings.Count(receipt.Files, "\n") != 3 {
		t.Fatalf("invalid adopted receipt: %+v", receipt)
	}
}

func TestBundleRetriesInterruptedFirstInstall(t *testing.T) {
	s := testStore(t)
	src := filepath.Join(s.home, "bundle", binaryName())
	userPlist := filepath.Join(s.home, "Library", "LaunchAgents", macServiceLabel+".plist")
	bootDir := t.TempDir()
	writeTestFile(t, src, []byte("bundle"))
	t.Setenv("PATH", t.TempDir())
	start := func() error {
		return errors.New("fixture registration interrupted")
	}
	if err := s.ensureMacService(src, 36, "6789", bootDir, start); err == nil {
		t.Fatal("lost failed install")
	}
	calls := 0
	start = func() error {
		calls++
		writeTestFile(t, userPlist, []byte("registered"))
		return nil
	}
	check(t, s.ensureMacService(src, 36, "6789", bootDir, start))
	check(t, s.ensureMacService(src, 36, "6789", bootDir, start))
	if calls != 1 {
		t.Fatalf("registered %d times after interrupted first install", calls)
	}
}

func TestBundleRestartOfUserOwnedBootJob(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("macOS service fixture uses a POSIX child")
	}
	bin := t.TempDir()
	launcher := filepath.Join(bin, "supervisor")
	writeTestFile(t, launcher, []byte("#!/bin/sh\nexec /bin/sleep 60\n"))
	check(t, os.Chmod(launcher, 0700))
	child := exec.Command(launcher)
	check(t, child.Start())
	finished := make(chan error, 1)
	go func() { finished <- child.Wait(); close(finished) }()
	t.Cleanup(func() { _ = child.Process.Kill(); <-finished })
	fake := filepath.Join(bin, "launchctl")
	writeTestFile(t, fake, []byte("#!/bin/sh\n[ \"$1\" = print ] || exit 1\nprintf '\\tprogram = %s\\n\\tpid = %s\\n' \"$TEST_PROGRAM\" \"$TEST_PID\"\n"))
	check(t, os.Chmod(fake, 0700))
	t.Setenv("PATH", bin)
	t.Setenv("TEST_PID", strconv.Itoa(child.Process.Pid))
	t.Setenv("TEST_PROGRAM", "another-program")
	const target = "system/com.luwei.tokenmeter.node.6789"
	if err := restartMacService(target, launcher); err == nil {
		t.Fatal("signalled a process other than the registered supervisor")
	}
	t.Setenv("TEST_PROGRAM", launcher)
	check(t, restartMacService(target, launcher))
	select {
	case err := <-finished:
		if err == nil {
			t.Fatal("temporary supervisor did not receive signal")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("temporary supervisor still running")
	}
}
