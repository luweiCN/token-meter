package account

import (
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"time"
	"unicode/utf16"
)

const agyHookMarker = "--tokenmeter-antigravity"
const agyPreviousMarker = " # tokenmeter-antigravity"
const agyObservationEnv = "TOKENMETER_AGY_OBSERVATION"

type agySettings map[string]json.RawMessage

func (line agySettings) text(key string) string {
	var text string
	_ = json.Unmarshal(line[key], &text)
	return text
}

func (line agySettings) put(key string, value any) {
	line[key], _ = json.Marshal(value)
}

func (line agySettings) hasCustom() bool {
	return line.text("command") != "" && !bytes.Equal(bytes.TrimSpace(line["enabled"]), []byte("false"))
}

type agyConnection struct {
	Original json.RawMessage `json:"original"`
}

func agySameJSON(a, b []byte) bool {
	var left, right bytes.Buffer
	if json.Compact(&left, a) != nil || json.Compact(&right, b) != nil {
		return false
	}
	return bytes.Equal(left.Bytes(), right.Bytes())
}

func agyCommand(executable string, arguments ...string) (string, error) {
	if !filepath.IsAbs(executable) {
		return "", errors.New("AGY 状态栏需要 TokenMeter 可执行文件的绝对路径")
	}
	if runtime.GOOS == "windows" {
		if strings.Contains(executable, "%") {
			// cmd.exe expands percent variables even in quoted filenames. Encoded
			// PowerShell is needed only for this unusual installation path.
			script := "& '" + strings.ReplaceAll(executable, "'", "''") + "' " + strings.Join(arguments, " ") + "; exit $LASTEXITCODE"
			units := utf16.Encode([]rune(script))
			data := make([]byte, len(units)*2)
			for i, c := range units {
				binary.LittleEndian.PutUint16(data[2*i:], c)
			}
			cmd := `@"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -EncodedCommand ` + base64.StdEncoding.EncodeToString(data)
			if slices.Contains(arguments, agyHookMarker) {
				cmd += " & rem " + agyHookMarker
			}
			return cmd, nil
		}
		return "@\"" + executable + "\" " + strings.Join(arguments, " "), nil
	}
	return "'" + strings.ReplaceAll(executable, "'", "'\"'\"'") + "' " + strings.Join(arguments, " "), nil
}

func agySettingsPath(home string) (string, error) {
	path := filepath.Join(home, ".gemini", "antigravity-cli", "settings.json")
	if real, err := filepath.EvalSymlinks(path); err == nil {
		return real, nil
	} else if !os.IsNotExist(err) {
		return "", err
	}
	// Preserve a user's dangling symlink too, e.g. a new dotfiles checkout.
	for i := 0; i < 32; i++ {
		dest, err := os.Readlink(path)
		if err != nil {
			if os.IsNotExist(err) {
				return path, nil
			}
			return "", err
		}
		if !filepath.IsAbs(dest) {
			dest = filepath.Join(filepath.Dir(path), dest)
		}
		path = filepath.Clean(dest)
		if real, err := filepath.EvalSymlinks(path); err == nil {
			return real, nil
		} else if !os.IsNotExist(err) {
			return "", err
		}
	}
	return "", errors.New("AGY 设置文件符号链接过多")
}

// AntigravityHook installs or removes the status-line integration. Its backup is
// shared with the existing installations, so a changed executable never nests a wrapper.
func AntigravityHook(home, executable string, enabled bool) error {
	connection := agyConnectionPath(home)
	if _, err := os.Stat(connection); !enabled && os.IsNotExist(err) {
		return nil
	}
	return agyWithLock(home, func() error {
		path, err := agySettingsPath(home)
		if err != nil {
			return err
		}
		before, err := os.ReadFile(path)
		if err != nil && !os.IsNotExist(err) {
			return err
		}
		doc := agySettings{}
		if len(before) > 0 {
			if err := json.Unmarshal(before, &doc); err != nil {
				return err
			}
			if doc == nil {
				return errors.New("无效的 AGY 设置")
			}
		} else if err == nil {
			return errors.New("AGY 设置文件为空")
		}
		currentRaw := doc["statusLine"]
		if currentRaw == nil {
			currentRaw = json.RawMessage("null")
		}
		current := agySettings{}
		_ = json.Unmarshal(currentRaw, &current)
		if current == nil {
			current = agySettings{}
		}
		command := current.text("command")
		owned := strings.HasSuffix(command, " "+agyHookMarker) || strings.HasSuffix(command, agyPreviousMarker)
		var backup agyConnection
		err = agyReadJSON(connection, &backup, 4<<20)
		switch {
		case err == nil && len(backup.Original) == 0, os.IsNotExist(err) && owned:
			return errors.New("缺少 AGY 原状态栏命令的备份")
		case err != nil && !os.IsNotExist(err):
			return err
		}
		if enabled && !owned && backup.Original != nil && !agySameJSON(backup.Original, currentRaw) {
			// The user installed a different status line while capture was enabled.
			return nil
		}
		if enabled || owned {
			if !owned {
				backup.Original = currentRaw
			}
			var original agySettings
			_ = json.Unmarshal(backup.Original, &original)
			switch {
			case enabled:
				args := []string{"antigravity-capture"}
				if original.hasCustom() {
					args = append(args, "--forward")
				} else {
					current.put("stack_with_default", true)
				}
				args = append(args, agyHookMarker)
				cmd, err := agyCommand(executable, args...)
				if err != nil {
					return err
				}
				if owned && cmd == command && current.text("type") == "command" && bytes.Equal(current["enabled"], []byte("true")) {
					return nil
				}
				current.put("command", cmd)
				current.put("enabled", true)
				current.put("type", "command")
				doc.put("statusLine", current)
				if err = agyWritePrivate(connection, backup); err != nil {
					return err
				}
			default:
				keys := []string{"command", "enabled", "type"}
				if !original.hasCustom() {
					keys = append(keys, "stack_with_default")
				}
				for _, key := range keys {
					if value, ok := original[key]; ok {
						current[key] = value
					} else {
						delete(current, key)
					}
				}
				if len(current) > 0 || original != nil {
					doc.put("statusLine", current)
				} else if string(backup.Original) == "null" {
					delete(doc, "statusLine")
				} else {
					doc["statusLine"] = backup.Original
				}
			}
			if err = os.MkdirAll(filepath.Dir(path), 0700); err != nil {
				return err
			}
			latest, err := os.ReadFile(path)
			if err != nil && !os.IsNotExist(err) {
				return err
			}
			if !bytes.Equal(before, latest) {
				return errors.New("AGY 设置同时被更改，请重试")
			}
			if err = agyWritePrivate(path, doc); err != nil {
				return err
			}
		}
		if !enabled {
			for _, p := range []string{connection, agyReadingPath(home)} {
				if err := os.Remove(p); err != nil && !os.IsNotExist(err) {
					return err
				}
			}
		}
		return nil
	})
}

// AntigravityCapture is the fast path invoked by AGY without opening the device
// database. A personal status line receives the complete original byte stream.
func AntigravityCapture(home string, args []string, in io.Reader, out io.Writer) error {
	for _, arg := range args {
		if !slices.Contains([]string{"--forward", "--observe", agyHookMarker}, arg) {
			return errors.New("无效的 AGY 状态栏参数")
		}
	}
	started := time.Now()
	prefix, err := io.ReadAll(io.LimitReader(in, agyPayloadLimit+1))
	if err != nil {
		return err
	}
	if len(prefix) <= agyPayloadLimit {
		obs, err := agyParse(prefix, started)
		if err == nil && obs != nil {
			if slices.Contains(args, "--observe") {
				if len(obs.Buckets) > 0 {
					if path := os.Getenv(agyObservationEnv); filepath.IsAbs(path) {
						return agyWritePrivate(path, obs)
					}
				}
				return nil
			}
			// A malformed or unavailable cache should not interrupt the original prompt.
			_ = agySave(home, obs, started, true)
		}
	}
	if !slices.Contains(args, "--forward") {
		if len(prefix) > agyPayloadLimit {
			_, err = io.Copy(io.Discard, in)
		}
		return err
	}
	var backup agyConnection
	if err := agyReadJSON(agyConnectionPath(home), &backup, 4<<20); err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	var original agySettings
	if err := json.Unmarshal(backup.Original, &original); err != nil {
		return err
	}
	if !original.hasCustom() {
		return nil
	}
	cmd := agyShell(original.text("command"))
	cmd.Stdin = io.MultiReader(bytes.NewReader(prefix), in)
	cmd.Stdout, cmd.Stderr = out, os.Stderr
	err = cmd.Run()
	// A custom formatter can finish without reading any more input.
	if len(prefix) > agyPayloadLimit {
		_, _ = io.Copy(io.Discard, in)
	}
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		return errors.New("AGY 原状态栏命令执行失败")
	}
	return err
}
