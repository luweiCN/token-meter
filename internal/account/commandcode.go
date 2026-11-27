package account

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Credentials are scoped to the origin the user configured. Billing requests never follow redirects.
var billingClient = &http.Client{
	Timeout:       12 * time.Second,
	CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
}

func billingURL(endpoint string) (*url.URL, error) {
	u, err := url.Parse(endpoint)
	if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil {
		return nil, errors.New("额度接口需要有效的 HTTPS 地址")
	}
	return u, nil
}

func billingGET(ctx context.Context, client *http.Client, u *url.URL, headers http.Header, provider string) ([]byte, int, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, 0, fmt.Errorf("%s 额度接口地址无效", provider)
	}
	req.Header = headers.Clone()
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "TokenMeter")
	resp, err := client.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return nil, 0, ctx.Err()
		}
		return nil, 0, fmt.Errorf("%s 额度接口无法连接", provider)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, resp.StatusCode, fmt.Errorf("%s 额度接口返回 HTTP %d", provider, resp.StatusCode)
	}
	data, err := readLimited(resp.Body, 2<<20)
	if err != nil {
		return nil, resp.StatusCode, fmt.Errorf("%s 额度响应读取失败", provider)
	}
	return data, resp.StatusCode, nil
}

func billingNumber(v float64) string { return strconv.FormatFloat(math.Round(v*10)/10, 'f', -1, 64) }

func billingSummary(items []Metric) string {
	parts := make([]string, 0, len(items))
	for _, m := range items {
		if m.RemainingPercent != nil {
			parts = append(parts, m.Label+" "+billingNumber(*m.RemainingPercent)+"%")
		}
	}
	return strings.Join(parts, " · ")
}

func collectCommandCode(ctx context.Context, e Environment, p Provider) (Snapshot, error) {
	u, err := billingURL(p.Endpoint)
	if err != nil {
		return Snapshot{}, err
	}
	key := commandCodeKey(ctx, e, p)
	if key == "" {
		return Snapshot{}, errors.New("缺少 Command Code API Key，请在设置页填写，或配置 COMMAND_CODE_API_KEY")
	}
	return fetchCommandCode(ctx, billingClient, p, u, key)
}

// API key selection is final for the request. An authentication failure must not silently select another account.
func selectedBillingKey(ctx context.Context, e Environment, p Provider) string {
	if p.Credential != nil {
		p.Credential = &Credential{EnvironmentVariable: p.Credential.EnvironmentVariable}
	}
	if keys := e.CredentialTokens(ctx, p); len(keys) > 0 {
		return keys[0]
	}
	return ""
}

func commandCodeKey(ctx context.Context, e Environment, p Provider) string {
	if key := selectedBillingKey(ctx, e, p); key != "" {
		return key
	}
	f, err := os.Open(filepath.Join(e.Home, ".commandcode", "auth.json"))
	if err != nil {
		return ""
	}
	defer f.Close()
	data, err := readLimited(f, 1<<16)
	var auth struct{ APIKey string }
	if err != nil || json.Unmarshal(data, &auth) != nil {
		return ""
	}
	return normalizeCredential(auth.APIKey)
}

func fetchCommandCode(ctx context.Context, client *http.Client, p Provider, base *url.URL, key string) (Snapshot, error) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	var who struct{ Org struct{ ID string } }
	get := func(path string, scope bool) ([]byte, error) {
		u := base.JoinPath("alpha", path)
		if scope && who.Org.ID != "" {
			q := u.Query()
			q.Set("orgId", who.Org.ID)
			u.RawQuery = q.Encode()
		}
		raw, status, err := billingGET(ctx, client, u, http.Header{"Authorization": {"Bearer " + key}}, p.DisplayName)
		if status == 401 || status == 403 {
			return nil, errors.New("Command Code API Key 无效或已过期")
		}
		return raw, err
	}
	if raw, err := get("whoami", false); err == nil {
		_ = json.Unmarshal(raw, &who)
	}
	sub := make(chan []byte, 1)
	go func() {
		raw, _ := get("billing/subscriptions", true)
		sub <- raw
	}()
	data, err := get("billing/credits", true)
	if err != nil {
		return Snapshot{}, err
	}
	return parseCommandCode(p, data, <-sub, time.Now())
}

type commandCodeWindow struct {
	Used     json.Number
	Cap      json.Number
	Exceeded bool
	ResetAt  float64
}
type commandCodePlan struct{ PlanID, Status, CurrentPeriodEnd string }

func parseCommandCode(p Provider, raw, subscription []byte, now time.Time) (Snapshot, error) {
	var payload struct {
		Credits struct {
			MonthlyCredits                json.Number
			PurchasedCredits, FreeCredits float64
		}
		WindowLimits struct{ FiveHour, Weekly *commandCodeWindow }
	}
	if json.Unmarshal(raw, &payload) != nil {
		return Snapshot{}, errors.New("Command Code 额度响应格式错误")
	}
	var items []Metric
	window := func(w *commandCodeWindow, id, label string, minutes int) {
		if w == nil {
			return
		}
		used, usedErr := w.Used.Float64()
		cap, capErr := w.Cap.Float64()
		if usedErr != nil || capErr != nil || used < 0 || cap <= 0 {
			return
		}
		var reset time.Time
		if w.ResetAt > 0 {
			reset = time.UnixMilli(int64(w.ResetAt))
		}
		m := billingPercent(p.ID+"-"+id, label, minutes, used/cap*100, reset, now)
		m.UsedAmount, m.TotalAmount, m.Unit = DecimalAmount(w.Used.String()), DecimalAmount(w.Cap.String()), "credits"
		if w.Exceeded {
			m.Status = "error"
		}
		m.Detail = fmt.Sprintf("%.2f / %.2f 积分", used, cap)
		items = append(items, m)
	}
	window(payload.WindowLimits.FiveHour, "5h", "5h", 300)
	window(payload.WindowLimits.Weekly, "weekly", "7d", 10080)
	var result struct{ Data commandCodePlan }
	_ = json.Unmarshal(subscription, &result)
	credits := payload.Credits
	left, leftErr := credits.MonthlyCredits.Float64()
	if cap := commandCodeLimit(result.Data.PlanID); cap > 0 && result.Data.Status == "active" && leftErr == nil {
		reset, _ := time.Parse(time.RFC3339Nano, result.Data.CurrentPeriodEnd)
		m := billingPercent(p.ID+"-monthly", "30d", 43200, (cap-left)/cap*100, reset, now)
		m.RemainingAmount, m.Unit = DecimalAmount(credits.MonthlyCredits.String()), "credits"
		m.Detail = fmt.Sprintf("套餐余额 %.2f / %.2f 积分", left, cap)
		if credits.PurchasedCredits > 0 {
			m.Detail += fmt.Sprintf(" · 充值 %.2f 积分", credits.PurchasedCredits)
		}
		if credits.FreeCredits > 0 {
			m.Detail += fmt.Sprintf(" · 赠送 %.2f 积分", credits.FreeCredits)
		}
		items = append(items, m)
	}
	if len(items) == 0 {
		return Snapshot{}, errors.New("Command Code 响应中没有可显示的额度")
	}
	s := NewSnapshot(p)
	s.Groups = []Group{{ID: p.ID, Title: p.DisplayName, Items: items}}
	s.Summary = billingSummary(items)
	s.Message = s.Summary
	return s, nil
}

func commandCodeLimit(id string) float64 {
	id = strings.ReplaceAll(strings.ToLower(id), "_", "-")
	// Billing attaches version suffixes to plan IDs. Check the most specific known prefix first.
	for _, plan := range []struct {
		prefix string
		cap    float64
	}{
		{"individual-pro-v1", 80}, {"individual-provider", 15}, {"individual-goat", 70},
		{"individual-go", 10}, {"individual-pro", 30}, {"individual-max", 150}, {"individual-ultra", 300}, {"teams-pro", 40},
	} {
		if strings.HasPrefix(id, plan.prefix) {
			return plan.cap
		}
	}
	return 0
}
