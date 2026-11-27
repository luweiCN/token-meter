package account

import (
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
	"strings"
	"time"
)

const (
	openCodeGoAPI     = "https://opencode.ai/inference/go/v1/usage"
	openCodeGoConsole = "https://opencode.ai/console/api/go/status"
)

type openCodeSession struct{ WorkspaceID, AuthCookie, ConsoleSession string }

func openCodeSessionFor(home string) (openCodeSession, bool) {
	s := openCodeSession{strings.TrimSpace(os.Getenv("OPENCODE_GO_WORKSPACE_ID")), strings.TrimSpace(os.Getenv("OPENCODE_GO_AUTH_COOKIE")), strings.TrimSpace(os.Getenv("OPENCODE_GO_CONSOLE_SESSION"))}
	valid := func(s openCodeSession) bool {
		return s.WorkspaceID != "" && (s.AuthCookie != "" || s.ConsoleSession != "")
	}
	if valid(s) {
		return s, true
	}
	f, err := os.Open(filepath.Join(home, ".config", "opencode", "opencode-quota", "opencode-go.json"))
	if err != nil {
		return openCodeSession{}, false
	}
	defer f.Close()
	data, err := readLimited(f, 64<<10)
	var saved openCodeSession
	if err != nil || json.Unmarshal(data, &saved) != nil {
		return openCodeSession{}, false
	}
	saved.WorkspaceID = strings.TrimSpace(saved.WorkspaceID)
	saved.AuthCookie = strings.TrimSpace(saved.AuthCookie)
	saved.ConsoleSession = strings.TrimSpace(saved.ConsoleSession)
	return saved, valid(saved)
}

func openCodeAPIKey(home string) string {
	for _, name := range []string{"OPENCODE_GO_API_KEY", "OPENCODE_API_KEY"} {
		if k := normalizeCredential(os.Getenv(name)); k != "" {
			return k
		}
	}
	dataHome := os.Getenv("XDG_DATA_HOME")
	currentHome, _ := os.UserHomeDir()
	relative, err := filepath.Rel(home, dataHome)
	authorizedDir := filepath.Clean(home) == filepath.Clean(currentHome) || (err == nil && filepath.IsLocal(relative))
	if !filepath.IsAbs(dataHome) || !authorizedDir {
		dataHome = filepath.Join(home, ".local", "share")
	}
	f, err := os.Open(filepath.Join(dataHome, "opencode", "auth.json"))
	if err != nil {
		return ""
	}
	defer f.Close()
	raw, err := readLimited(f, 1<<20)
	var auth map[string]struct{ Type, Key string }
	if err == nil && json.Unmarshal(raw, &auth) == nil {
		// OpenCode v1 keeps the Go and Zen keys under different provider IDs.
		if row, ok := auth["opencode-go"]; ok && row.Type == "api" {
			return normalizeCredential(row.Key)
		}
	}
	return ""
}

func collectOpenCodeGo(ctx context.Context, e Environment, p Provider) (Snapshot, error) {
	if p.Credential != nil {
		if keys := e.CredentialTokens(ctx, p); len(keys) > 0 {
			return fetchOpenCodeAPI(ctx, billingClient, p, keys[0])
		}
	}
	if s, ok := openCodeSessionFor(e.Home); ok {
		// An explicit workspace signs in to a specific account and takes precedence over implicit CLI keys.
		return fetchOpenCodeSession(ctx, billingClient, p, s)
	}
	if k := openCodeAPIKey(e.Home); k != "" {
		return fetchOpenCodeAPI(ctx, billingClient, p, k)
	}
	// OpenCode v2 manages its own account refresh. Ask its read-only usage command, which uses the
	// active workspace without copying an OAuth token out of the CLI.
	executable, err := e.LookPath("opencode")
	if err != nil {
		return Snapshot{}, errors.New("请在设置页登录 OpenCode Go，或配置 OPENCODE_GO_API_KEY")
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, executable, "api", "get", "/api/experimental/usage/limits")
	cmd.Dir = e.Home
	cmd.Env = append(cmd.Environ(), "HOME="+e.Home, "USERPROFILE="+e.Home)
	if home, err := os.UserHomeDir(); err == nil && filepath.Clean(e.Home) != filepath.Clean(home) {
		cmd.Env = append(cmd.Env,
			"XDG_CONFIG_HOME="+filepath.Join(e.Home, ".config"),
			"XDG_DATA_HOME="+filepath.Join(e.Home, ".local", "share"),
			"XDG_STATE_HOME="+filepath.Join(e.Home, ".local", "state"),
			"XDG_CACHE_HOME="+filepath.Join(e.Home, ".cache"),
			"APPDATA="+filepath.Join(e.Home, "AppData", "Roaming"),
			"LOCALAPPDATA="+filepath.Join(e.Home, "AppData", "Local"))
	}
	cmd.Stderr = io.Discard
	cmd.WaitDelay = time.Second
	pipe, err := cmd.StdoutPipe()
	if err != nil {
		return Snapshot{}, errors.New("OpenCode CLI 额度查询失败")
	}
	if err = cmd.Start(); err != nil {
		return Snapshot{}, errors.New("OpenCode CLI 额度查询失败")
	}
	raw, readErr := readLimited(pipe, 1<<20)
	if readErr != nil {
		_ = cmd.Process.Kill()
	}
	if err = cmd.Wait(); err != nil || readErr != nil {
		if ctx.Err() != nil {
			return Snapshot{}, ctx.Err()
		}
		return Snapshot{}, errors.New("请在设置页登录 OpenCode Go，或配置 OPENCODE_GO_API_KEY")
	}
	var response struct{ Go map[string]openCodeMeter }
	if json.Unmarshal(raw, &response) != nil {
		return Snapshot{}, errors.New("OpenCode CLI 用量响应格式错误")
	}
	if len(response.Go) == 0 {
		return Snapshot{}, errors.New("当前 OpenCode 工作区没有返回 Go 额度")
	}
	return openCodeSnapshot(p, response.Go, false, time.Now())
}

func fetchOpenCodeAPI(ctx context.Context, client *http.Client, p Provider, key string) (Snapshot, error) {
	u, _ := url.Parse(openCodeGoAPI)
	data, status, err := billingGET(ctx, client, u, http.Header{"Authorization": {"Bearer " + key}}, p.DisplayName)
	if err != nil {
		return Snapshot{}, openCodeHTTPError(status, err)
	}
	var response struct{ Usage map[string]openCodeMeter }
	if json.Unmarshal(data, &response) != nil {
		return Snapshot{}, errors.New("OpenCode Go 用量响应格式错误")
	}
	return openCodeSnapshot(p, response.Usage, false, time.Now())
}

func fetchOpenCodeSession(ctx context.Context, client *http.Client, p Provider, s openCodeSession) (Snapshot, error) {
	u, _ := url.Parse(openCodeGoConsole)
	h := http.Header{"X-Org-Id": {s.WorkspaceID}}
	var cookies []string
	for _, c := range []http.Cookie{{Name: "auth", Value: s.AuthCookie}, {Name: "__Host-console_session", Value: s.ConsoleSession}} {
		if c.Value == "" {
			continue
		}
		if c.Valid() != nil {
			return Snapshot{}, errors.New("OpenCode Go 登录态无效，请在设置页重新登录")
		}
		cookies = append(cookies, c.Name+"="+c.Value)
	}
	h.Set("Cookie", strings.Join(cookies, "; "))
	raw, status, err := billingGET(ctx, client, u, h, p.DisplayName)
	if err != nil {
		return Snapshot{}, openCodeHTTPError(status, err)
	}
	var response struct {
		Access struct {
			Meters map[string]openCodeMeter
		}
	}
	if json.Unmarshal(raw, &response) != nil {
		return Snapshot{}, errors.New("OpenCode Go 控制台响应格式错误")
	}
	return openCodeSnapshot(p, response.Access.Meters, true, time.Now())
}

func openCodeHTTPError(status int, err error) error {
	switch status {
	case 401:
		return errors.New("OpenCode Go 登录态或 API Key 已失效，请重新连接")
	case 403:
		return errors.New("当前账户无权查询此工作区的 OpenCode Go 订阅额度")
	default:
		return err
	}
}

type openCodeMeter struct {
	Status                          string
	Percent                         *float64
	Limited                         bool
	ResetsAt                        any
	UsedMicroCents, LimitMicroCents json.Number
}

func openCodeAllowanceUSD(microcents json.Number) string {
	units := DecimalAmount(microcents.String())
	if units == "" || strings.ContainsAny(units, ".-") {
		return ""
	}
	// Go window meters count dollars of plan allowance in millionths of a cent.
	dollars := DecimalAmount(units + "e-8")
	return strings.TrimRight(strings.TrimRight(dollars, "0"), ".")
}

func openCodeSnapshot(p Provider, rows map[string]openCodeMeter, console bool, now time.Time) (Snapshot, error) {
	var items []Metric
	for _, w := range []struct {
		key, console, id, label string
		minutes                 int
	}{
		{"rolling", "fiveHour", "5h", "5h", 300}, {"weekly", "week", "weekly", "7d", 10080}, {"monthly", "month", "monthly", "Monthly", 43200},
	} {
		key := w.key
		if console {
			key = w.console
		}
		row, ok := rows[key]
		if !ok {
			continue
		}
		percent := row.Percent
		var usedAmount, totalAmount string
		if console {
			usedAmount = openCodeAllowanceUSD(row.UsedMicroCents)
			totalAmount = openCodeAllowanceUSD(row.LimitMicroCents)
		}
		if percent == nil && console {
			used, usedErr := json.Number(usedAmount).Float64()
			limit, limitErr := json.Number(totalAmount).Float64()
			if usedErr != nil || limitErr != nil || limit <= 0 {
				continue
			}
			v := used / limit * 100
			percent = &v
		}
		if percent == nil {
			continue
		}
		var resets time.Time
		switch value := row.ResetsAt.(type) {
		case string:
			resets, _ = time.Parse(time.RFC3339Nano, value)
		case float64:
			if value > 0 {
				resets = time.UnixMilli(int64(value))
			}
		}
		m := billingPercent(p.ID+"-"+w.id, w.label, w.minutes, *percent, resets, now)
		if usedAmount != "" || totalAmount != "" {
			m.UsedAmount, m.TotalAmount, m.Unit = usedAmount, totalAmount, "USD"
		}
		if row.Status == "rate-limited" || row.Limited {
			m.Detail = "已达到此窗口的使用上限"
		}
		items = append(items, m)
	}
	if len(items) == 0 {
		return Snapshot{}, errors.New("当前工作区没有可读取的 OpenCode Go 额度窗口")
	}
	s := NewSnapshot(p)
	s.Groups = []Group{{ID: p.ID, Title: p.DisplayName, Items: items}}
	var parts []string
	for _, m := range items {
		label := m.Label
		if label == "7d" {
			label = "Weekly"
		}
		parts = append(parts, fmt.Sprintf("%s %s%%", label, billingNumber(*m.RemainingPercent)))
	}
	s.Summary = strings.Join(parts, " · ")
	s.Message = s.Summary
	return s, nil
}
