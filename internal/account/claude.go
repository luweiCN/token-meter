package account

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"time"
	"unicode"

	"golang.org/x/text/unicode/norm"
)

var (
	claudeVersionPattern = regexp.MustCompile(`\b\d+\.\d+\.\d+(?:-[\w.]+)?\b`)
	claudeOrgPattern     = regexp.MustCompile(`(?i)^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$`)
	claudeMoneyPattern   = regexp.MustCompile(`^(-?)([0-9]+)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?$`)
)

type claudeMoney struct {
	Value    json.RawMessage `json:"value"`
	Currency string          `json:"currency"`
}
type claudeExtra struct {
	Enabled      *bool        `json:"enabled,omitempty"`
	Used         *claudeMoney `json:"used,omitempty"`
	MonthlyLimit *claudeMoney `json:"monthlyLimit,omitempty"`
}
type claudeCredits struct {
	Prepaid    *claudeMoney `json:"prepaid,omitempty"`
	ExtraUsage *claudeExtra `json:"extraUsage,omitempty"`
}

func (c claudeCredits) wire() json.RawMessage {
	b, _ := json.Marshal(map[string]claudeCredits{"claude": c})
	return b
}
func claudeAmount(raw json.RawMessage, currency string) *claudeMoney {
	code := strings.ToUpper(currency)
	if len(code) != 3 || strings.IndexFunc(code, func(r rune) bool { return r < 'A' || r > 'Z' }) >= 0 || len(raw) > 128 {
		return nil
	}
	m := claudeMoneyPattern.FindStringSubmatch(string(raw))
	if m == nil {
		return nil
	}
	exp := 0
	if m[4] != "" {
		var err error
		exp, err = strconv.Atoi(m[4])
		if err != nil || exp > 100 || exp < -100 {
			return nil
		}
	}
	if code != "JPY" && code != "KRW" && code != "VND" {
		exp -= 2
	}
	digits := m[2] + m[3]
	point := len(m[2]) + exp
	switch {
	case point <= 0:
		digits = "0." + strings.Repeat("0", -point) + digits
	case point < len(digits):
		digits = digits[:point] + "." + digits[point:]
	default:
		digits += strings.Repeat("0", point-len(digits))
	}
	integer, frac, _ := strings.Cut(digits, ".")
	integer = strings.TrimLeft(integer, "0")
	if integer == "" {
		integer = "0"
	}
	frac = strings.TrimRight(frac, "0")
	if frac != "" {
		integer += "." + frac
	}
	if integer != "0" {
		integer = m[1] + integer
	}
	return &claudeMoney{Value: json.RawMessage(integer), Currency: code}
}

type claudePeriod struct {
	Utilization json.RawMessage
	Resets      string `json:"resets_at"`
}

func claudeMetric(id, label string, duration int, w *claudePeriod, now time.Time) (Metric, bool) {
	if w == nil {
		return Metric{}, false
	}
	number, ok := ccNumber(w.Utilization)
	if !ok {
		return Metric{}, false
	}
	resets, _ := time.Parse(time.RFC3339Nano, w.Resets)
	return billingPercent(id, label, duration, number, resets, now), true
}
func claudeModelID(title string) string {
	words := strings.FieldsFunc(strings.ToLower(title), func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsNumber(r)
	})
	return strings.Join(words, "-")
}
func parseClaude(p Provider, raw []byte, prepaid *claudeMoney, now time.Time) (Snapshot, error) {
	out := NewSnapshot(p)
	c := claudeCredits{Prepaid: prepaid}
	out.AccountCredits = c.wire()
	var dto struct {
		Five      *claudePeriod `json:"five_hour"`
		Seven     *claudePeriod `json:"seven_day"`
		Sonnet    *claudePeriod `json:"seven_day_sonnet"`
		Fable     *claudePeriod `json:"seven_day_fable"`
		Opus      *claudePeriod `json:"seven_day_opus"`
		OAuthApps *claudePeriod `json:"seven_day_oauth_apps"`
		Cowork    *claudePeriod `json:"seven_day_cowork"`
		Omelette  *claudePeriod `json:"seven_day_omelette"`
		Limits    []struct {
			Kind    string
			Percent json.RawMessage
			Resets  string `json:"resets_at"`
			Scope   struct {
				Model struct {
					DisplayName string `json:"display_name"`
				}
			}
		}
		Extra *struct {
			Enabled  *bool `json:"is_enabled"`
			Currency *string
			Used     json.RawMessage `json:"used_credits"`
			Limit    json.RawMessage `json:"monthly_limit"`
		} `json:"extra_usage"`
	}
	if json.Unmarshal(raw, &dto) != nil {
		return out, errors.New("Claude 返回的额度数据格式不正确")
	}
	base := Group{ID: "claude", Title: p.DisplayName}
	if m, ok := claudeMetric("claude-5h", "5h", 300, dto.Five, now); ok {
		base.Items = append(base.Items, m)
	}
	if m, ok := claudeMetric("claude-7d", "7d", 10080, dto.Seven, now); ok {
		base.Items = append(base.Items, m)
	}
	if len(base.Items) > 0 {
		out.Groups = append(out.Groups, base)
	}
	seen := map[string]bool{strings.ToLower(p.DisplayName): len(base.Items) > 0}
	for _, w := range []struct {
		key, title string
		data       *claudePeriod
	}{
		{"seven_day_sonnet", "Sonnet", dto.Sonnet}, {"seven_day_fable", "Fable", dto.Fable}, {"seven_day_opus", "Opus", dto.Opus},
		{"seven_day_oauth_apps", "OAuth Apps", dto.OAuthApps}, {"seven_day_cowork", "Cowork", dto.Cowork}, {"seven_day_omelette", "Omelette", dto.Omelette},
	} {
		if m, ok := claudeMetric("claude-"+w.key, "7d", 10080, w.data, now); ok {
			seen[strings.ToLower(w.title)] = true
			out.Groups = append(out.Groups, Group{ID: w.key, Title: w.title, Items: []Metric{m}})
		}
	}
	for _, l := range dto.Limits {
		title := strings.TrimSpace(l.Scope.Model.DisplayName)
		if l.Kind != "weekly_scoped" || title == "" || seen[strings.ToLower(title)] {
			continue
		}
		id := claudeModelID(title)
		if m, ok := claudeMetric("claude-weekly-"+id, "7d", 10080, &claudePeriod{l.Percent, l.Resets}, now); ok {
			seen[strings.ToLower(title)] = true
			out.Groups = append(out.Groups, Group{ID: "weekly-scoped-" + id, Title: title, Items: []Metric{m}})
		}
	}
	if ex := dto.Extra; ex != nil {
		code := "USD"
		if ex.Currency != nil {
			code = *ex.Currency
		}
		extra := &claudeExtra{ex.Enabled, claudeAmount(ex.Used, code), claudeAmount(ex.Limit, code)}
		if extra.Enabled != nil || extra.Used != nil || extra.MonthlyLimit != nil {
			c.ExtraUsage = extra
		}
	}
	out.AccountCredits = c.wire()
	if len(out.Groups) == 0 && c.Prepaid == nil && c.ExtraUsage == nil {
		return out, errors.New("Claude 响应中没有额度数据")
	}
	out.Summary = ccSummary(out.Groups)
	return out, nil
}

func claudeCommandVersion(ctx context.Context, e Environment) string {
	exe, err := e.LookPath("claude")
	if err == nil {
		if dest, err := filepath.EvalSymlinks(exe); err == nil {
			base := filepath.Base(dest)
			if v := claudeVersionPattern.FindString(base); v != "" {
				return v
			}
		}
		// npm launchers can be Windows batch files. Read the installed package
		// version without evaluating the wrapper in a shell.
		resolved, _ := filepath.EvalSymlinks(exe)
		for _, path := range []string{
			filepath.Join(filepath.Dir(exe), "node_modules", "@anthropic-ai", "claude-code", "package.json"),
			filepath.Join(filepath.Dir(resolved), "package.json"),
		} {
			file, err := os.Open(path)
			if err != nil {
				continue
			}
			var manifest struct{ Name, Version string }
			err = json.NewDecoder(io.LimitReader(file, 1<<20)).Decode(&manifest)
			file.Close()
			if err == nil && manifest.Name == "@anthropic-ai/claude-code" &&
				manifest.Version != "" && claudeVersionPattern.FindString(manifest.Version) == manifest.Version {
				return manifest.Version
			}
		}
		run, cancel := context.WithTimeout(ctx, 2*time.Second)
		defer cancel()
		if raw, err := exec.CommandContext(run, exe, "--version").Output(); err == nil {
			if v := claudeVersionPattern.FindString(string(raw)); v != "" {
				return v
			}
		}
	}
	return "2.1.207"
}
func claudeTokenJSON(data []byte) string {
	var cred struct {
		AccessToken   string
		ClaudeAiOauth *struct{ AccessToken string }
	}
	if json.Unmarshal(data, &cred) != nil {
		return ""
	}
	if cred.ClaudeAiOauth != nil {
		return strings.TrimSpace(cred.ClaudeAiOauth.AccessToken)
	}
	return strings.TrimSpace(cred.AccessToken)
}
func claudeStorage(home string) (directory, service string) {
	custom := os.Getenv("CLAUDE_CONFIG_DIR")
	if dir, present := os.LookupEnv("CLAUDE_SECURESTORAGE_CONFIG_DIR"); present {
		custom = dir
	}
	service = "Claude Code-credentials"
	if custom == "" {
		return filepath.Join(home, ".claude"), service
	}
	directory = norm.NFC.String(custom)
	return directory, service + "-" + accountHash([]byte(directory))[:8]
}

func claudeKeychainAccount() string {
	name := os.Getenv("USER")
	if name == "" {
		if u, err := user.Current(); err == nil {
			name = u.Username
		}
	}
	if name == "" || strings.IndexFunc(name, func(r rune) bool {
		return !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '.' || r == '_' || r == '-')
	}) >= 0 {
		return "claude-code-user"
	}
	return name
}

func claudeToken(ctx context.Context, e Environment, p Provider) (string, error) {
	actualHome, _ := os.UserHomeDir()
	useDesktopSecrets := filepath.Clean(e.Home) == filepath.Clean(actualHome)
	configDir := filepath.Join(e.Home, ".claude")
	service := ""
	if useDesktopSecrets {
		configDir, service = claudeStorage(e.Home)
		if v := strings.TrimSpace(os.Getenv("CLAUDE_CODE_OAUTH_TOKEN")); v != "" {
			return v, nil
		}
	}
	if cred := p.Credential; cred != nil {
		if v := strings.TrimSpace(os.Getenv(cred.EnvironmentVariable)); cred.EnvironmentVariable != "" && v != "" {
			return v, nil
		}
		if cred.FilePath != "" {
			path := e.ExpandPath(cred.FilePath)
			if token := claudeFileToken(path); token != "" {
				return token, nil
			}
			return "", errors.New("配置文件中没有 Claude Code 登录凭据")
		}
	}
	// The upstream CLI uses an account-scoped keychain service per configured profile.
	if runtime.GOOS == "darwin" && useDesktopSecrets {
		run, cancel := context.WithTimeout(ctx, 5*time.Second)
		defer cancel()
		b, err := exec.CommandContext(run, "/usr/bin/security", "find-generic-password", "-s", service, "-a", claudeKeychainAccount(), "-w").Output()
		if err == nil {
			if v := claudeTokenJSON(b); v != "" {
				return v, nil
			}
		}
	}
	if token := claudeFileToken(filepath.Join(configDir, ".credentials.json")); token != "" {
		return token, nil
	}
	return "", errors.New("未找到有效的 Claude Code 登录凭据")
}
func claudeFileToken(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, 1<<20))
	if err != nil {
		return ""
	}
	return claudeTokenJSON(b)
}

type claudeAPI struct {
	client        *http.Client
	base, version string
}

func (a claudeAPI) get(ctx context.Context, path, token, org string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, a.base+path, nil)
	if err != nil {
		return nil, errors.New("Claude 请求地址无效")
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("anthropic-beta", "oauth-2025-04-20")
	req.Header.Set("anthropic-version", "2023-06-01")
	req.Header.Set("User-Agent", "TokenMeter")
	if org != "" {
		req.Header.Set("x-organization-uuid", org)
	}
	if path == "usage" {
		req.Header.Set("anthropic-dangerous-direct-browser-access", "true")
		req.Header.Set("x-app", "cli")
		req.Header.Set("User-Agent", "claude-cli/"+a.version+" (external, cli)")
	}
	resp, err := a.client.Do(req)
	if err != nil {
		return nil, errors.New("Claude 额度查询失败，请检查网络与登录状态")
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, (2<<20)+1))
	if err != nil || len(body) > 2<<20 {
		return nil, errors.New("Claude 额度响应不完整")
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		msg := fmt.Sprintf("Claude 接口返回 %d", resp.StatusCode)
		if resp.StatusCode == 429 {
			msg = "Claude 接口限流"
		}
		var detail struct {
			Message string
			Error   json.RawMessage
		}
		if json.Unmarshal(body, &detail) == nil {
			if detail.Message == "" {
				var nested struct{ Message, Type string }
				if json.Unmarshal(detail.Error, &nested) == nil {
					detail.Message = nested.Message
					if detail.Message == "" {
						detail.Message = nested.Type
					}
				} else {
					_ = json.Unmarshal(detail.Error, &detail.Message)
				}
			}
			text := strings.TrimSpace(strings.ReplaceAll(detail.Message, token, "…"))
			if text != "" {
				rs := []rune(text)
				if len(rs) > 192 {
					rs = rs[:192]
				}
				msg += "：" + string(rs)
			}
		}
		return nil, errors.New(msg)
	}
	return body, nil
}
func (a claudeAPI) prepaid(ctx context.Context, token string) *claudeMoney {
	data, err := a.get(ctx, "profile", token, "")
	if err != nil {
		return nil
	}
	var profile struct{ Organization struct{ UUID string } }
	if json.Unmarshal(data, &profile) != nil || !claudeOrgPattern.MatchString(profile.Organization.UUID) {
		return nil
	}
	org := strings.ToLower(profile.Organization.UUID)
	data, err = a.get(ctx, "organizations/"+org+"/prepaid/credits", token, org)
	if err != nil {
		return nil
	}
	var wallet struct {
		Amount   json.RawMessage
		Currency string
	}
	if json.Unmarshal(data, &wallet) != nil {
		return nil
	}
	return claudeAmount(wallet.Amount, wallet.Currency)
}
func (a claudeAPI) read(ctx context.Context, p Provider, token string) (Snapshot, error) {
	wallet := make(chan *claudeMoney, 1)
	go func() { wallet <- a.prepaid(ctx, token) }()
	usage, err := a.get(ctx, "usage", token, "")
	prepaid := <-wallet
	if err != nil {
		s := NewSnapshot(p)
		s.AccountCredits = claudeCredits{Prepaid: prepaid}.wire()
		return s, err
	}
	return parseClaude(p, usage, prepaid, time.Now())
}
func collectClaude(ctx context.Context, e Environment, p Provider) (Snapshot, error) {
	token, err := claudeToken(ctx, e, p)
	if err != nil {
		s := NewSnapshot(p)
		s.AccountCredits = claudeCredits{}.wire()
		return s, err
	}
	api := claudeAPI{client: &http.Client{Timeout: 8 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}, base: "https://api.anthropic.com/api/oauth/", version: claudeCommandVersion(ctx, e)}
	return api.read(ctx, p, token)
}
