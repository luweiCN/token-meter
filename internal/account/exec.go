package account

import (
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"
)

func (e Environment) ExpandPath(path string) string {
	if path == "~" {
		return e.Home
	}
	if strings.HasPrefix(path, "~/") || (runtime.GOOS == "windows" && strings.HasPrefix(path, "~\\")) {
		return filepath.Join(e.Home, path[2:])
	}
	return path
}

// SearchPath includes common per-user installs even when launchd or systemd sets a minimal PATH.
func (e Environment) SearchPath() string {
	dirs := filepath.SplitList(os.Getenv("PATH"))
	for _, p := range []string{".local/bin", ".codex/packages/standalone/current/bin", ".volta/bin", ".bun/bin", ".cargo/bin", ".npm-global/bin", ".local/share/pnpm"} {
		dirs = append(dirs, filepath.Join(e.Home, filepath.FromSlash(p)))
	}
	if runtime.GOOS == "windows" {
		dirs = append(dirs, filepath.Join(e.Home, "AppData", "Roaming", "npm"), filepath.Join(e.Home, "scoop", "shims"))
	} else {
		dirs = append(dirs, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin")
	}
	seen := map[string]bool{}
	out := make([]string, 0, len(dirs))
	for _, dir := range dirs {
		if filepath.IsAbs(dir) && !seen[dir] {
			seen[dir] = true
			out = append(out, dir)
		}
	}
	return strings.Join(out, string(os.PathListSeparator))
}

func (e Environment) LookPath(name string) (string, error) {
	if filepath.IsAbs(name) {
		return exec.LookPath(name)
	}
	if filepath.Base(name) != name || name == "" {
		return "", exec.ErrNotFound
	}
	for _, dir := range filepath.SplitList(e.SearchPath()) {
		if p, err := exec.LookPath(filepath.Join(dir, name)); err == nil {
			return p, nil
		}
	}
	return "", exec.ErrNotFound
}

var envName = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

func normalizeCredential(value string) string {
	s := strings.TrimSpace(value)
	if len(s) > 1 && (s[0] == '"' || s[0] == '\'') && s[0] == s[len(s)-1] {
		s = strings.TrimSpace(s[1 : len(s)-1])
	}
	return s
}

// CredentialTokens uses the same precedence as credentials saved in the desktop settings.
// The shell command receives only a validated variable name. No secret is passed in argv.
func (e Environment) CredentialTokens(ctx context.Context, p Provider) []string {
	var tokens []string
	add := func(value string) {
		value = normalizeCredential(value)
		if value == "" || strings.ContainsAny(value, "\r\n\x00") {
			return
		}
		for _, t := range tokens {
			if t == value {
				return
			}
		}
		tokens = append(tokens, value)
	}
	actual, err := os.UserHomeDir()
	userHome := err == nil && filepath.Clean(actual) == filepath.Clean(e.Home)
	if runtime.GOOS == "darwin" && userHome {
		reader, cancel := context.WithTimeout(ctx, 5*time.Second)
		cmd := exec.CommandContext(reader, "/usr/bin/security", "find-generic-password", "-s", "com.luwei.tokenmeter.provider-key", "-a", p.ID, "-w")
		cmd.WaitDelay = time.Second
		raw, err := cmd.Output()
		cancel()
		if err == nil {
			add(string(raw))
		}
	}
	if c := p.Credential; c != nil {
		if envName.MatchString(c.EnvironmentVariable) {
			value := os.Getenv(c.EnvironmentVariable)
			add(value)
			if value == "" && len(tokens) == 0 && userHome && runtime.GOOS != "windows" {
				shell := os.Getenv("SHELL")
				if filepath.IsAbs(shell) {
					reader, cancel := context.WithTimeout(ctx, 5*time.Second)
					cmd := exec.CommandContext(reader, shell, "-lc", "/usr/bin/printenv "+c.EnvironmentVariable)
					cmd.WaitDelay = time.Second
					raw, err := cmd.Output()
					cancel()
					if err == nil {
						add(string(raw))
					}
				}
			}
		}
		if c.FilePath != "" {
			file, err := os.Open(e.ExpandPath(c.FilePath))
			if err == nil {
				raw, err := readLimited(file, 64<<10)
				file.Close()
				if err == nil {
					add(string(raw))
				}
			}
		}
	}
	return tokens
}

var errResponseSize = errors.New("额度文件超过大小限制")

func readLimited(reader io.Reader, limit int64) ([]byte, error) {
	data, err := io.ReadAll(io.LimitReader(reader, limit+1))
	if err == nil && int64(len(data)) > limit {
		return nil, errResponseSize
	}
	return data, err
}
