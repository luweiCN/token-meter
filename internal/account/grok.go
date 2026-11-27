package account

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"time"
)

var (
	errGrokLogin   = errors.New("未登录 Grok Build。请在终端运行 grok login，完成后点重试或等待下次自动刷新。")
	errGrokNoQuota = errors.New("Grok 响应中没有可用的额度字段")
	errGrokMethod  = errors.New("当前 Grok CLI 未提供账单方法")
	errGrokLimit   = errors.New("额度用尽")
	errGrokRPC     = errors.New("Grok CLI 暂时无法读取额度")
)

const grokBillingURL = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
const grokCreditsURL = "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig"

type grokLogin struct {
	Key     string `json:"key"`
	UserID  string `json:"user_id"`
	Expiry  string `json:"expires_at"`
	Refresh string `json:"refresh_token"`
}

func grokLoginHost(key string) string {
	issuer, _, _ := strings.Cut(key, "::")
	u, err := url.Parse(issuer)
	if err != nil || u.Scheme != "https" {
		return ""
	}
	return strings.ToLower(u.Hostname())
}

func readGrokLogin(path string, now time.Time) (account grokLogin, canUseCLI bool) {
	file, err := os.Open(path)
	if err != nil {
		return
	}
	defer file.Close()
	raw, err := readLimited(file, 1<<20)
	if err != nil {
		return
	}
	var entries map[string]grokLogin
	if json.Unmarshal(raw, &entries) != nil {
		return
	}
	keys := make([]string, 0, len(entries))
	for key := range entries {
		keys = append(keys, key)
	}
	slices.SortFunc(keys, func(a, b string) int {
		aOfficial, bOfficial := grokLoginHost(a) == "auth.x.ai", grokLoginHost(b) == "auth.x.ai"
		if aOfficial != bOfficial {
			if aOfficial {
				return -1
			}
			return 1
		}
		return strings.Compare(a, b)
	})
	for _, k := range keys {
		entry := entries[k]
		expiry, err := time.Parse(time.RFC3339Nano, entry.Expiry)
		live := strings.TrimSpace(entry.Key) != "" && (err != nil || expiry.After(now))
		canUseCLI = canUseCLI || entry.Refresh != "" || live
		host := grokLoginHost(k)
		// An installation can also hold credentials for custom endpoints. The
		// official CLI can select those accounts, but direct billing only uses xAI tokens.
		firstParty := host == "x.ai" || host == "grok.com" || strings.HasSuffix(host, ".x.ai") || strings.HasSuffix(host, ".grok.com")
		if account.Key == "" && live && firstParty {
			account = entry
		}
	}
	// Renewal, including handling the refresh credential, belongs to Grok itself.
	account.Refresh = ""
	return
}

type grokClient struct {
	billing func(context.Context) ([]byte, error)
	client  *http.Client
}

func collectGrok(ctx context.Context, e Environment, p Provider) (Snapshot, error) {
	home := e.ExpandPath(strings.TrimSpace(os.Getenv("GROK_HOME")))
	if home == "" {
		home = filepath.Join(e.Home, ".grok")
	}
	var exe string
	for _, candidate := range []string{filepath.Join(home, "bin", "grok"), filepath.Join(e.Home, ".grok", "bin", "grok"), "grok"} {
		if path, err := e.LookPath(candidate); err == nil {
			exe = path
			break
		}
	}
	if exe == "" {
		return Snapshot{}, errors.New("未检测到 Grok 命令行")
	}
	c := grokClient{
		billing: func(ctx context.Context) ([]byte, error) {
			childCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
			defer cancel()
			cmd := exec.CommandContext(childCtx, exe, "agent", "--no-leader", "stdio")
			cmd.Env = append(cmd.Environ(), "GROK_HOME="+home, "PATH="+e.SearchPath())
			return grokBillingRPC(childCtx, cmd)
		},
		client: &http.Client{Timeout: 10 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }},
	}
	return c.collect(ctx, p, filepath.Join(home, "auth.json"))
}

func (c grokClient) collect(ctx context.Context, p Provider, authPath string) (Snapshot, error) {
	_, canUseCLI := readGrokLogin(authPath, time.Now())
	if !canUseCLI {
		return Snapshot{}, errGrokLogin
	}
	raw, err := c.billing(ctx)
	if err == nil {
		var snap Snapshot
		snap, err = grokBillingJSON(raw, p)
		if err == nil {
			return snap, nil
		}
	}
	if ctx.Err() != nil {
		return Snapshot{}, ctx.Err()
	}
	if !errors.Is(err, errGrokMethod) && !errors.Is(err, errGrokNoQuota) && !errors.Is(err, context.DeadlineExceeded) {
		return Snapshot{}, err
	}
	// The CLI may just have rotated its bearer token.
	account, canUseCLI := readGrokLogin(authPath, time.Now())
	if account.Key == "" {
		if canUseCLI {
			return Snapshot{}, err
		}
		return Snapshot{}, errGrokLogin
	}
	var snap Snapshot
	raw, err = c.http(ctx, account, false)
	if err == nil {
		snap, err = grokBillingJSON(raw, p)
	}
	if err == nil || errors.Is(err, errGrokLogin) || errors.Is(err, errGrokLimit) {
		return snap, err
	}
	raw, err = c.http(ctx, account, true)
	if err != nil {
		return Snapshot{}, err
	}
	return grokBillingGRPC(raw, p)
}

func (c grokClient) http(ctx context.Context, account grokLogin, grpc bool) ([]byte, error) {
	method, url := http.MethodGet, grokBillingURL
	var body io.Reader
	if grpc {
		method, url, body = http.MethodPost, grokCreditsURL, bytes.NewReader([]byte{0, 0, 0, 0, 0})
	}
	req, err := http.NewRequestWithContext(ctx, method, url, body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+account.Key)
	req.Header.Set("X-XAI-Token-Auth", "xai-grok-cli")
	req.Header.Set("User-Agent", "Grok Build")
	if grpc {
		req.Header.Set("Content-Type", "application/grpc-web+proto")
		req.Header.Set("Accept", "application/grpc-web+proto")
		req.Header.Set("X-Grpc-Web", "1")
	} else {
		req.Header.Set("Accept", "application/json")
		if account.UserID != "" {
			req.Header.Set("x-userid", account.UserID)
		}
	}
	resp, err := c.client.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, errors.New("无法连接 Grok 账单服务")
	}
	defer resp.Body.Close()
	switch {
	case resp.StatusCode == 401 || resp.StatusCode == 403:
		return nil, errGrokLogin
	case resp.StatusCode == 402:
		return nil, errGrokLimit
	case resp.StatusCode/100 != 2:
		return nil, fmt.Errorf("Grok 账单服务返回 HTTP %d", resp.StatusCode)
	}
	if grpc {
		if err = grokGRPCStatus(resp.Header.Get("Grpc-Status")); err != nil {
			return nil, err
		}
	}
	return readLimited(resp.Body, maxBillingOutput)
}

func grokBillingRPC(ctx context.Context, cmd *exec.Cmd) ([]byte, error) {
	var result json.RawMessage
	err := agentControlStream(ctx, cmd, func(in io.WriteCloser, lines *bufio.Scanner) error {
		encoder := json.NewEncoder(in)
		call := func(id int, method string, params any) (json.RawMessage, error) {
			if err := encoder.Encode(map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": params}); err != nil {
				return nil, errGrokNoQuota
			}
			for lines.Scan() {
				var reply struct {
					ID     *int
					Result json.RawMessage
					Error  *struct {
						Code    int
						Message string
					}
				}
				if json.Unmarshal(lines.Bytes(), &reply) != nil || reply.ID == nil || *reply.ID != id {
					continue
				}
				if reply.Error != nil {
					msg := strings.ToLower(reply.Error.Message)
					switch {
					case reply.Error.Code == -32601 || strings.Contains(msg, "method not found"):
						return nil, errGrokMethod
					case strings.Contains(msg, "weekly limit") || strings.Contains(msg, "402"):
						return nil, errGrokLimit
					case strings.Contains(msg, "unauthorized") || strings.Contains(msg, "unauthenticated") || strings.Contains(msg, "401") || strings.Contains(msg, "403"):
						return nil, errGrokLogin
					default:
						return nil, errGrokRPC
					}
				}
				if len(reply.Result) == 0 {
					return nil, errGrokNoQuota
				}
				return reply.Result, nil
			}
			return nil, errGrokNoQuota
		}
		_, err := call(1, "initialize", map[string]any{"protocolVersion": "1", "clientCapabilities": map[string]any{"fs": map[string]bool{"readTextFile": false, "writeTextFile": false}}})
		if err != nil {
			return err
		}
		// Older CLIs advertise cached credentials without an authenticate method.
		_, err = call(2, "authenticate", map[string]string{"methodId": "cached_token"})
		if errors.Is(err, errGrokLogin) {
			return err
		}
		result, err = call(3, "_x.ai/billing", struct{}{})
		if errors.Is(err, errGrokMethod) {
			result, err = call(4, "x.ai/billing", struct{}{})
		}
		return err
	})
	if err != nil && !errors.Is(err, context.Canceled) && !errors.Is(err, context.DeadlineExceeded) &&
		!errors.Is(err, errGrokMethod) && !errors.Is(err, errGrokLogin) && !errors.Is(err, errGrokLimit) && !errors.Is(err, errGrokNoQuota) {
		return nil, errGrokRPC
	}
	return result, err
}
