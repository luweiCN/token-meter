package account

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

var ClientVersion = "development"

var (
	errCodexRead       = errors.New("Codex 请求未能确认，请检查网络与登录状态")
	errCodexTimeout    = errors.New("Codex 请求超时")
	errCodexSchema     = errors.New("请更新 Codex CLI，当前版本不支持指定重置卡")
	errCodexChanged    = errors.New("Codex 登录账户已变化，已停止本次自动使用")
	errCodexIneligible = errors.New("目标卡片已不在可使用的时间范围内")
)

type codexProgram struct {
	binary     string
	prefix     []string
	home       string
	searchPath string
}

func findCodex(e Environment) (codexProgram, error) {
	exe, err := e.LookPath("codex")
	if err != nil {
		return codexProgram{}, errors.New("未检测到 Codex 命令行，额度读取需要安装 Codex CLI")
	}
	actualHome, _ := os.UserHomeDir()
	home := ""
	if filepath.Clean(actualHome) == filepath.Clean(e.Home) {
		home = os.Getenv("CODEX_HOME")
	}
	if home == "" {
		home = filepath.Join(e.Home, ".codex")
	}
	p := codexProgram{binary: exe, home: home, searchPath: e.SearchPath()}
	// npm's Windows wrapper is a batch script; use its JS entry directly
	// without a shell so directories and arguments never need interpolation.
	if runtime.GOOS == "windows" && strings.EqualFold(filepath.Ext(exe), ".cmd") {
		js := filepath.Join(filepath.Dir(exe), "node_modules", "@openai", "codex", "bin", "codex.js")
		node, err := e.LookPath("node")
		st, statErr := os.Stat(js)
		if err != nil || statErr != nil || !st.Mode().IsRegular() {
			return p, errors.New("无法启动 Codex CLI，请检查本机 Codex 安装")
		}
		p.binary = node
		p.prefix = []string{js}
	}
	return p, nil
}

func (p codexProgram) command(ctx context.Context, args ...string) *exec.Cmd {
	params := append(append([]string(nil), p.prefix...), args...)
	cmd := exec.CommandContext(ctx, p.binary, params...)
	cmd.Env = append(cmd.Environ(), "CODEX_HOME="+p.home)
	if p.searchPath != "" {
		cmd.Env = append(cmd.Env, "PATH="+p.searchPath)
	}
	cmd.WaitDelay = time.Second
	return cmd
}

func accountHash(value []byte) string {
	h := sha256.Sum256(value)
	return hex.EncodeToString(h[:])
}

// Read the same login identity before and after the server query. No raw
// account, subject, token or credit ID is written to TokenMeter storage.
func codexIdentity(home string) string {
	f, err := os.Open(filepath.Join(home, "auth.json"))
	if err != nil {
		return ""
	}
	defer f.Close()
	var auth struct {
		Tokens struct {
			AccountID string `json:"account_id"`
			IDToken   string `json:"id_token"`
		}
	}
	if json.NewDecoder(io.LimitReader(f, 2<<20)).Decode(&auth) != nil || auth.Tokens.AccountID == "" {
		return ""
	}
	parts := strings.Split(auth.Tokens.IDToken, ".")
	if len(parts) < 2 {
		return ""
	}
	data, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(parts[1], "="))
	if err != nil {
		return ""
	}
	var claim struct{ Sub string }
	if json.Unmarshal(data, &claim) != nil || claim.Sub == "" {
		return ""
	}
	return accountHash([]byte(auth.Tokens.AccountID + "\x00" + claim.Sub))
}

type codexSession struct {
	writer *json.Encoder
	reader *bufio.Scanner
	id     int
}

func (s *codexSession) request(method string, params, result any) error {
	s.id++
	if err := s.writer.Encode(map[string]any{"id": s.id, "method": method, "params": params}); err != nil {
		return errCodexRead
	}
	for s.reader.Scan() {
		var m struct {
			ID     json.RawMessage
			Method string
			Result json.RawMessage
			Error  json.RawMessage
		}
		if json.Unmarshal(s.reader.Bytes(), &m) != nil {
			return errCodexRead
		}
		if m.Method != "" {
			if len(m.ID) > 0 && string(m.ID) != "null" {
				// External auth refresh requests require an interactive client. The
				// collector supplies no credentials to the app-server.
				if err := s.writer.Encode(map[string]any{"id": m.ID, "error": map[string]any{"code": -32601, "message": "Unsupported client method"}}); err != nil {
					return errCodexRead
				}
			}
			continue
		}
		var replyID int
		if json.Unmarshal(m.ID, &replyID) != nil || replyID != s.id {
			continue
		}
		if len(m.Error) > 0 && string(m.Error) != "null" {
			return errCodexRead
		}
		if result != nil && (len(m.Result) == 0 || json.Unmarshal(m.Result, result) != nil) {
			return errCodexRead
		}
		return nil
	}
	return errCodexRead
}

func (p codexProgram) session(ctx context.Context, fn func(*codexSession) error) (retErr error) {
	scoped, cancel := context.WithTimeout(ctx, 25*time.Second)
	defer cancel()
	cmd := p.command(scoped, "app-server", "--listen", "stdio://")
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return errCodexRead
	}
	defer stdin.Close()
	out, err := cmd.StdoutPipe()
	if err != nil {
		return errCodexRead
	}
	if err = cmd.Start(); err != nil {
		return errCodexRead
	}
	defer func() {
		stdin.Close()
		out.Close()
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		if ctx.Err() != nil {
			retErr = ctx.Err()
		} else if scoped.Err() != nil {
			retErr = errCodexTimeout
		}
	}()
	reader := bufio.NewScanner(out)
	reader.Buffer(make([]byte, 32<<10), 8<<20)
	s := codexSession{writer: json.NewEncoder(stdin), reader: reader}
	info := map[string]string{"name": "token_meter", "title": "TokenMeter", "version": ClientVersion}
	if err = s.request("initialize", map[string]any{"clientInfo": info, "capabilities": map[string]bool{"experimentalApi": true}}, nil); err != nil {
		return err
	}
	if err = s.writer.Encode(map[string]any{"method": "initialized", "params": struct{}{}}); err != nil {
		return errCodexRead
	}
	return fn(&s)
}

func (p codexProgram) readInSession(s *codexSession) (codexState, error) {
	before := codexIdentity(p.home)
	var reply struct{ Account *struct{ Type string } }
	if err := s.request("account/read", map[string]bool{"refreshToken": false}, &reply); err != nil {
		return codexState{}, err
	}
	var state codexState
	if err := s.request("account/rateLimits/read", nil, &state.limits); err != nil {
		return state, err
	}
	if reply.Account != nil && reply.Account.Type == "chatgpt" && before == codexIdentity(p.home) {
		state.identity = before
	}
	state.fetched = time.Now()
	return state, nil
}

func (p codexProgram) read(ctx context.Context) (state codexState, err error) {
	err = p.session(ctx, func(s *codexSession) error {
		var err error
		state, err = p.readInSession(s)
		return err
	})
	return
}

func (p codexProgram) verifyCreditSelection(ctx context.Context) error {
	dir, err := os.MkdirTemp("", "tokenmeter-codex-schema-")
	if err != nil {
		return errCodexSchema
	}
	defer os.RemoveAll(dir)
	scoped, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err = p.command(scoped, "app-server", "generate-json-schema", "--out", dir).Run(); err != nil {
		return errCodexSchema
	}
	f, err := os.Open(filepath.Join(dir, "v2", "ConsumeAccountRateLimitResetCreditParams.json"))
	if err != nil {
		return errCodexSchema
	}
	defer f.Close()
	var schema struct{ Properties map[string]json.RawMessage }
	if json.NewDecoder(io.LimitReader(f, 1<<20)).Decode(&schema) != nil || len(schema.Properties["creditId"]) == 0 || len(schema.Properties["idempotencyKey"]) == 0 {
		return errCodexSchema
	}
	return nil
}

func (p codexProgram) consume(ctx context.Context, identity, credit, key string, enabled func() bool) (string, error) {
	if identity == "" || credit == "" || key == "" {
		return "", errCodexIneligible
	}
	if err := p.verifyCreditSelection(ctx); err != nil {
		return "", err
	}
	var outcome struct{ Outcome string }
	err := p.session(ctx, func(s *codexSession) error {
		state, err := p.readInSession(s)
		if err != nil {
			return err
		}
		if state.identity != identity || codexIdentity(p.home) != identity {
			return errCodexChanged
		}
		if !enabled() || ctx.Err() != nil {
			return context.Canceled
		}
		if cs := state.limits.ResetCredits; cs != nil {
			for _, c := range cs.Credits {
				if c.ID != credit || c.Status != "available" {
					continue
				}
				if !c.eligible(time.Now()) {
					return errCodexIneligible
				}
				return s.request("account/rateLimitResetCredit/consume", map[string]string{"creditId": credit, "idempotencyKey": key}, &outcome)
			}
		}
		outcome.Outcome = "noCredit"
		return nil
	})
	switch outcome.Outcome {
	case "reset", "alreadyRedeemed", "nothingToReset", "noCredit":
	default:
		if err == nil {
			err = errCodexRead
		}
	}
	return outcome.Outcome, err
}
