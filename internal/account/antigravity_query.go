package account

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/aymanbagabas/go-pty"
)

// Without an identified terminal (e.g. under launchd), AGY waits for a DEC
// secondary device-attributes reply before reading the keyring or publishing
// quota. Answer only DA2, never input at an interactive prompt.
func agyDrainTerminal(terminal io.ReadWriter) {
	var block [4096]byte
	state := 0
	for {
		n, err := terminal.Read(block[:])
		for _, b := range block[:n] {
			switch {
			case b == '\x1b':
				state = 1
			case state == 1 && b == '[':
				state = 2
			case state == 2 && b == '>':
				state = 3
			case state == 3 && b == '0':
				state = 4
			case (state == 3 || state == 4) && b == 'c':
				state = 0
				if _, writeErr := io.WriteString(terminal, "\x1b[>0;0;0c"); writeErr != nil {
					return
				}
			default:
				state = 0
			}
		}
		if err != nil {
			return
		}
	}
}

// AGY publishes quota through a controlling terminal. No prompt is sent. The
// temporary callback extracts only quota and the account keyring stays with AGY.
func agyBackground(ctx context.Context, e Environment, executable, helper string, timeout time.Duration) (*agyObservation, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	dir, err := os.MkdirTemp("", "tokenmeter-agy-*")
	if err != nil {
		return nil, agyUnavailable
	}
	defer os.RemoveAll(dir)
	output := filepath.Join(dir, "quota.json")
	logPath := filepath.Join(dir, "agy.log")
	command, err := agyCommand(helper, "antigravity-capture", "--observe")
	if err != nil {
		return nil, err
	}
	settings, _ := json.Marshal(map[string]any{"statusLine": map[string]any{"type": "command", "command": command, "enabled": true, "stack_with_default": false}})
	args := []string{"--log-file", logPath, "--settings", string(settings)}
	if runtime.GOOS == "darwin" {
		// Also prevents launching the browser through LaunchServices during failed renewal.
		args = append([]string{"-p", `(version 1)(allow default)(deny lsopen)(deny process-exec (literal "/usr/bin/open"))`, executable}, args...)
		executable = "/usr/bin/sandbox-exec"
	}
	terminal, err := pty.New()
	if err != nil {
		return nil, agyUnavailable
	}
	defer terminal.Close()
	if err = terminal.Resize(80, 24); err != nil {
		return nil, agyUnavailable
	}
	proc := terminal.Command(executable, args...)
	proc.Dir = e.Home
	env := map[string]string{
		"HOME": e.Home, "PATH": e.SearchPath(), "TERM": "xterm-256color", agyObservationEnv: output,
		// The official remote OAuth mode prints a URL and waits for operator input
		// if credentials expire. Background queries never provide that input.
		"SSH_CONNECTION": "127.0.0.1 1 127.0.0.1 22", "SSH_CLIENT": "127.0.0.1 1 22",
		"ANTIGRAVITY_REMOTE_OOB_AUTH": "true", "DISPLAY": "", "WAYLAND_DISPLAY": "",
	}
	if runtime.GOOS == "windows" {
		env["USERPROFILE"] = e.Home
		env["BROWSER"] = filepath.Join(os.Getenv("SystemRoot"), "System32", "where.exe")
	} else {
		env["BROWSER"] = "/bin/false"
	}
	// ConPTY accepts the first (case-insensitive) spelling of each environment
	// key. Replace inherited entries rather than relying on duplicate ordering.
	for _, v := range os.Environ() {
		name, _, _ := strings.Cut(v, "=")
		if _, ok := env[strings.ToUpper(name)]; !ok {
			proc.Env = append(proc.Env, v)
		}
	}
	for key, val := range env {
		proc.Env = append(proc.Env, key+"="+val)
	}
	if err = proc.Start(); err != nil {
		return nil, agyUnavailable
	}
	// Keeping a parent-side slave descriptor open prevents EOF on the master
	// after the CLI exits. ConPTY supplies separate pipes and closes them itself.
	if unixTTY, ok := terminal.(pty.UnixPty); ok {
		_ = unixTTY.Slave().Close()
	}
	stop, err := agyControlProcess(proc.Process)
	if err != nil {
		_ = proc.Process.Kill()
		_ = proc.Wait()
		return nil, agyUnavailable
	}
	done := make(chan struct{})
	go func() { _ = proc.Wait(); close(done) }()
	go agyDrainTerminal(terminal)
	defer func() {
		select {
		case <-done:
			stop(true)
		default:
			stop(false)
			<-done
		}
	}()
	query, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	tick := time.NewTicker(75 * time.Millisecond)
	defer tick.Stop()
	read := func() *agyObservation {
		var observed agyObservation
		if agyReadJSON(output, &observed, agyStoredLimit) == nil && !observed.ObservedAt.IsZero() && len(observed.Buckets) > 0 {
			return &observed
		}
		return nil
	}
	for {
		select {
		case <-query.Done():
			if err := ctx.Err(); err != nil {
				return nil, err
			}
			if result := read(); result != nil {
				return result, nil
			}
			return nil, agyDiagnostic(logPath, errors.Is(query.Err(), context.DeadlineExceeded))
		case <-done:
			if result := read(); result != nil {
				return result, nil
			}
			return nil, agyDiagnostic(logPath, false)
		case <-tick.C:
			if result := read(); result != nil {
				return result, nil
			}
		}
	}
}
