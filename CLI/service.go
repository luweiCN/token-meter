package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"
)

func esc(s string) string { var b bytes.Buffer; xml.EscapeText(&b, []byte(s)); return b.String() }
func systemdArg(s string) string {
	r := strings.NewReplacer("\\", "\\\\", "\"", "\\\"", "%", "%%", "$", "$$")
	return "\"" + r.Replace(s) + "\""
}
func run(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}
func writeService(path, body string) error {
	if e := os.MkdirAll(filepath.Dir(path), 0755); e != nil {
		return e
	}
	return os.WriteFile(path, []byte(body), 0644)
}
func (s *Store) installRuntime(src string) error {
	launcher := filepath.Join(s.dir, "launcher", binaryName())
	if _, e := os.Stat(launcher); os.IsNotExist(e) || (e == nil && runtime.GOOS != "windows") {
		if e = copyBinary(src, launcher); e != nil {
			return e
		}
	} else if e != nil {
		return e
	}
	a, e := s.active()
	if e != nil {
		return e
	}
	if a.Version == "" || newer(version, a.Version) || version == a.Version {
		dest := s.buildPath(version)
		if _, err := os.Stat(dest); os.IsNotExist(err) || runtime.GOOS != "windows" {
			if e = copyBinary(src, dest); e != nil {
				return e
			}
		}
		if a.Version != version {
			if e = s.activate(activeBuild{version, a.Version}); e != nil {
				return e
			}
		}
	}
	return nil
}

const macServiceLabel = "com.luwei.tokenmeter.node"

type bundleServiceReceipt struct {
	Version string `json:"version"`
	Build   uint64 `json:"build"`
	Files   string `json:"files,omitempty"`
	Pending string `json:"pending,omitempty"`
}

// All three files are replaced by rename. Their identities let an ordinary app
// launch avoid hashing executables, writing state, or contacting launchd.
func bundleFileStamp(paths []string) (string, error) {
	var stamp strings.Builder
	for _, path := range paths {
		f, err := os.Open(path)
		if errors.Is(err, os.ErrNotExist) {
			stamp.WriteString("-\n")
			continue
		}
		if err != nil {
			return "", err
		}
		info, err := f.Stat()
		if err == nil {
			var id string
			id, err = fileIdentity(f)
			if err == nil {
				fmt.Fprintf(&stamp, "%s:%d:%d\n", id, info.ModTime().UnixNano(), info.Size())
			}
		}
		f.Close()
		if err != nil {
			return "", err
		}
	}
	return stamp.String(), nil
}

func binaryDigest(path string) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	h := sha256.New()
	_, err = io.Copy(h, f)
	return h.Sum(nil), err
}

func (s *Store) ensureMacService(src string, appBuild uint64, uid, bootDir string, install func() error) error {
	bootLabel := macServiceLabel + "." + uid
	bootPath := filepath.Join(bootDir, bootLabel+".plist")
	userPath := filepath.Join(s.home, "Library", "LaunchAgents", macServiceLabel+".plist")
	target := ""
	for _, item := range []struct{ path, target string }{
		{bootPath, "system/" + bootLabel}, {userPath, "gui/" + uid + "/" + macServiceLabel},
	} {
		if _, err := os.Stat(item.path); err == nil {
			target = item.target
			break
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	active, err := s.active()
	if err != nil || newer(active.Version, version) {
		return err
	}
	receiptPath := filepath.Join(s.dir, "bundle-service.json")
	var receipt bundleServiceReceipt
	if err = loadOptional(receiptPath, &receipt); err != nil {
		return err
	}
	if receipt.Version == version && receipt.Build > appBuild {
		return nil
	}
	if target == "" && active.Version != "" && receipt.Pending != "install" {
		// Uninstall retains the ledger and active runtime but removes its plist.
		return nil
	}
	launcher := filepath.Join(s.dir, "launcher", binaryName())
	paths := []string{src, launcher, s.buildPath(version)}
	files, err := bundleFileStamp(paths)
	if err != nil {
		return err
	}
	if receipt == (bundleServiceReceipt{Version: version, Build: appBuild, Files: files}) && active.Version == version && target != "" {
		return nil
	}
	digest, err := binaryDigest(src)
	if err != nil {
		return err
	}
	var replace []string
	for _, path := range paths[1:] {
		installed, err := binaryDigest(path)
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		if !bytes.Equal(installed, digest) {
			replace = append(replace, path)
		}
	}
	action := receipt.Pending
	if target == "" {
		action = "install"
	} else if action == "install" && strings.HasPrefix(target, "system/") {
		action = "restart"
	} else if action == "" && (len(replace) != 0 || active.Version != version) {
		action = "restart"
	}
	if action != "" {
		receipt = bundleServiceReceipt{Version: version, Build: appBuild, Pending: action}
		if err = atomicJSON(receiptPath, receipt); err != nil {
			return err
		}
	}
	for _, path := range replace {
		if err = copyBinary(src, path); err != nil {
			return err
		}
	}
	if active.Version != version {
		if err = s.activate(activeBuild{version, active.Version}); err != nil {
			return err
		}
	}
	switch action {
	case "install":
		err = install()
	case "restart":
		err = restartMacService(target, launcher)
	}
	if err != nil {
		return err
	}
	files, err = bundleFileStamp(paths)
	if err != nil {
		return err
	}
	return atomicJSON(receiptPath, bundleServiceReceipt{Version: version, Build: appBuild, Files: files})
}

func restartMacService(target, launcher string) error {
	// KeepAlive relaunches the supervisor, which also stops its daemon child.
	out, err := exec.Command("launchctl", "kill", "SIGTERM", target).CombinedOutput()
	if err == nil {
		return nil
	}
	failure := fmt.Errorf("launchctl kill %s: %w: %s", target, err, strings.TrimSpace(string(out)))
	if !strings.HasPrefix(target, "system/") {
		return failure
	}
	// A pre-login job is registered by root, but its supervisor runs as this
	// user. launchd can deny control of the domain while ordinary signals work.
	job, err := exec.Command("launchctl", "print", target).Output()
	if err != nil {
		return failure
	}
	pid := 0
	program := ""
	for line := range strings.SplitSeq(string(job), "\n") {
		if value, ok := strings.CutPrefix(line, "\tprogram = "); ok {
			program = value
		}
		if value, ok := strings.CutPrefix(line, "\tpid = "); ok {
			pid, _ = strconv.Atoi(value)
		}
	}
	if program != launcher || pid <= 1 {
		return failure
	}
	process, err := os.FindProcess(pid)
	if err != nil {
		return err
	}
	defer process.Release()
	return process.Signal(syscall.SIGTERM)
}

func (s *Store) service(action, bootUser string) error {
	if strings.ContainsAny(s.dir+s.home, "\r\n\x00") {
		return errors.New("invalid service path")
	}
	assoc, e := user.Current()
	if e != nil {
		return e
	}
	if action == "ensure" && runtime.GOOS == "darwin" {
		src, err := os.Executable()
		if err != nil {
			return err
		}
		build, _ := strconv.ParseUint(os.Getenv("TOKEN_METER_APP_BUILD"), 10, 64)
		return s.withRuntimeLock(func() error {
			return s.ensureMacService(src, build, assoc.Uid, "/Library/LaunchDaemons", func() error {
				return s.configureService("install", "", assoc)
			})
		})
	}
	if action == "install" {
		src, err := os.Executable()
		if err != nil {
			return err
		}
		return s.withRuntimeLock(func() error {
			if err := s.installRuntime(src); err != nil {
				return err
			}
			return s.configureService(action, bootUser, assoc)
		})
	}
	return s.configureService(action, bootUser, assoc)
}

func (s *Store) configureService(action, bootUser string, assoc *user.User) error {
	var e error
	launcher := filepath.Join(s.dir, "launcher", binaryName())
	args := []string{"--state", s.dir, "--home", s.home, "supervise"}
	switch runtime.GOOS {
	case "linux":
		system := os.Getuid() == 0
		dir := filepath.Join(s.home, ".config", "systemd", "user")
		ctl := []string{"--user"}
		target := "default.target"
		if system {
			dir = "/etc/systemd/system"
			ctl = nil
			target = "multi-user.target"
		}
		unit := "token-meter.service"
		path := filepath.Join(dir, unit)
		systemctl := func(a ...string) error { return run("systemctl", append(append([]string{}, ctl...), a...)...) }
		switch action {
		case "install":
			argv := []string{systemdArg(launcher)}
			for _, a := range args {
				argv = append(argv, systemdArg(a))
			}
			unitText := "[Unit]\nDescription=TokenMeter device\nAfter=network.target\n\n[Service]\nType=simple\nEnvironment=" + systemdArg("HOME="+s.home) + "\nExecStart=" + strings.Join(argv, " ") + "\nRestart=always\nRestartSec=5\nUMask=0077\nNoNewPrivileges=true\n\n[Install]\nWantedBy=" + target + "\n"
			if e = writeService(path, unitText); e != nil {
				return e
			}
			if e = systemctl("daemon-reload"); e != nil {
				return e
			}
			if e = systemctl("enable", unit); e != nil {
				return e
			}
			if e = systemctl("restart", unit); e != nil {
				return e
			}
			if !system {
				return run("loginctl", "enable-linger", assoc.Username)
			}
			return nil
		case "status":
			return systemctl("status", unit, "--no-pager")
		case "uninstall":
			if e = systemctl("disable", "--now", unit); e != nil {
				return e
			}
			if e = os.Remove(path); e != nil {
				return e
			}
			return systemctl("daemon-reload")
		}
	case "darwin":
		domain := "gui/" + assoc.Uid
		label := macServiceLabel
		path := filepath.Join(s.home, "Library", "LaunchAgents", label+".plist")
		userKey := ""
		if bootUser != "" {
			if os.Getuid() != 0 && action != "status-boot" {
				return errors.New("boot service installation requires sudo; run service install first as the target user")
			}
			u, err := user.Lookup(bootUser)
			if err != nil {
				return err
			}
			domain = "system"
			label += "." + u.Uid
			path = filepath.Join("/Library/LaunchDaemons", label+".plist")
			userKey = "<key>UserName</key><string>" + esc(u.Username) + "</string>"
		}
		switch action {
		case "install", "install-boot":
			if _, err := os.Stat(launcher); err != nil {
				return err
			}
			parts := ""
			for _, a := range append([]string{launcher}, args...) {
				parts += "<string>" + esc(a) + "</string>"
			}
			body := `<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>Label</key><string>` + label + "</string>" + userKey + "<key>ProgramArguments</key><array>" + parts + "</array><key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>5</integer><key>StandardErrorPath</key><string>" + esc(filepath.Join(s.dir, "service.log")) + "</string></dict></plist>\n"
			if e = writeService(path, body); e != nil {
				return e
			}

			if exec.Command("launchctl", "print", domain+"/"+label).Run() == nil {
				if err := run("launchctl", "bootout", domain+"/"+label); err != nil {
					return err
				}
			}
			if err := run("launchctl", "enable", domain+"/"+label); err != nil {
				return err
			}
			var startErr error
			for attempt := 0; attempt < 12; attempt++ {
				out, err := exec.Command("launchctl", "bootstrap", domain, path).CombinedOutput()
				if err == nil || exec.Command("launchctl", "print", domain+"/"+label).Run() == nil {
					if bootUser != "" {
						u, _ := user.Lookup(bootUser)
						exec.Command("launchctl", "bootout", "gui/"+u.Uid+"/"+macServiceLabel).Run()
						userPlist := filepath.Join(s.home, "Library", "LaunchAgents", macServiceLabel+".plist")
						if err := os.Remove(userPlist); err != nil && !os.IsNotExist(err) {
							return err
						}
					}
					return nil
				}
				startErr = fmt.Errorf("launchctl bootstrap: %w: %s", err, strings.TrimSpace(string(out)))
				time.Sleep(250 * time.Millisecond)
			}
			return startErr
		case "status", "status-boot":
			return run("launchctl", "print", domain+"/"+label)
		case "uninstall", "uninstall-boot":
			if e = run("launchctl", "bootout", domain+"/"+label); e != nil {
				return e
			}
			if e = os.Remove(path); e != nil {
				return e
			}
			if e = os.Remove(filepath.Join(s.dir, "bundle-service.json")); !errors.Is(e, os.ErrNotExist) {
				return e
			}
			return nil
		}
	case "windows":
		task := "TokenMeter-" + assoc.Uid
		switch action {
		case "install":
			// S4U schedules under the same user at boot without storing a password.
			// Windows path components cannot contain a double quote.
			quoted := make([]string, 0, len(args))
			for _, a := range args {
				quoted = append(quoted, "\""+strings.TrimRight(a, "\\")+"\"")
			}
			body := `<?xml version="1.0" encoding="UTF-8"?><Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Triggers><BootTrigger><Enabled>true</Enabled></BootTrigger></Triggers><Principals><Principal id="owner"><UserId>` + esc(assoc.Uid) + `</UserId><LogonType>S4U</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals><Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><StartWhenAvailable>true</StartWhenAvailable><ExecutionTimeLimit>PT0S</ExecutionTimeLimit><RestartOnFailure><Interval>PT1M</Interval><Count>999</Count></RestartOnFailure></Settings><Actions Context="owner"><Exec><Command>` + esc(launcher) + "</Command><Arguments>" + esc(strings.Join(quoted, " ")) + "</Arguments></Exec></Actions></Task>"
			f, err := os.CreateTemp(s.dir, "task-*.xml")
			if err != nil {
				return err
			}
			defer os.Remove(f.Name())
			_, err = f.WriteString(body)
			ce := f.Close()
			if err != nil {
				return err
			}
			if ce != nil {
				return ce
			}
			if e = run("schtasks.exe", "/Create", "/TN", task, "/XML", f.Name(), "/F"); e != nil {
				return e
			}
			return run("schtasks.exe", "/Run", "/TN", task)
		case "status":
			return run("schtasks.exe", "/Query", "/TN", task, "/V", "/FO", "LIST")
		case "uninstall":
			exec.Command("schtasks.exe", "/End", "/TN", task).Run()
			return run("schtasks.exe", "/Delete", "/TN", task, "/F")
		}
	}
	return fmt.Errorf("unsupported service action %q on %s", action, runtime.GOOS)
}
