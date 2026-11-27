package account

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const commandQuotaFixture = `{"credits":{"monthlyCredits":56,"purchasedCredits":5,"freeCredits":2},"windowLimits":{"fiveHour":{"used":3.5,"cap":14,"resetAt":1788189584628},"weekly":{"used":7,"cap":35,"resetAt":1788876384628}}}`
const commandSubscriptionFixture = `{"data":{"planId":"individual-goat","status":"active","currentPeriodEnd":"2026-09-30T10:15:17.000Z"}}`

func TestCommandCodeOrgQuotaAndSubscription(t *testing.T) {
	var called atomic.Int32
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "GET" || r.Header.Get("Authorization") != "Bearer test-key" {
			t.Error("unexpected credentials or method")
			w.WriteHeader(401)
			return
		}
		switch r.URL.Path {
		case "/alpha/whoami":
			fmt.Fprint(w, `{"org":{"id":"org-1"}}`)
		case "/alpha/billing/credits", "/alpha/billing/subscriptions":
			if r.URL.Query().Get("orgId") != "org-1" {
				t.Error("missing explicit billing organization")
			}
			if strings.HasSuffix(r.URL.Path, "credits") {
				fmt.Fprint(w, commandQuotaFixture)
			} else {
				fmt.Fprint(w, commandSubscriptionFixture)
			}
		default:
			t.Error("unexpected endpoint")
			w.WriteHeader(404)
		}
		called.Add(1)
	}))
	defer server.Close()
	u, err := billingURL(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	p := Provider{ID: "command-code", DisplayName: "Command Code"}
	s, err := fetchCommandCode(context.Background(), server.Client(), p, u, "test-key")
	if err != nil {
		t.Fatal(err)
	}
	if called.Load() != 3 || s.Summary != "5h 75% · 7d 80% · 30d 80%" {
		t.Fatalf("wrong summary %#v", s.Summary)
	}
	items := s.Groups[0].Items
	if len(items) != 3 || items[0].ResetAt != time.UnixMilli(1788189584628).UTC().Format(time.RFC3339) {
		t.Fatalf("bad first window %+v", items)
	}
	if items[0].Detail != "3.50 / 14.00 积分" || items[2].Detail != "套餐余额 56.00 / 70.00 积分 · 充值 5.00 积分 · 赠送 2.00 积分" || items[2].ResetAt != "2026-09-30T10:15:17Z" || *items[1].WindowDurationMinutes != 10080 {
		t.Errorf("bad details %+v", items)
	}
	if m := items[0]; m.UsedAmount != "3.5" || m.TotalAmount != "14" || m.RemainingAmount != "" || m.Unit != "credits" {
		t.Fatal(m)
	}
	if m := items[2]; m.RemainingAmount != "56" || m.Unit != "credits" || m.UsedAmount != "" || m.TotalAmount != "" {
		t.Fatalf("estimated plan cap or spend became a reported amount: %+v", m)
	}
}

func TestCommandCodeCreditPrecision(t *testing.T) {
	body := []byte(`{"credits":{"monthlyCredits":0.00000000000000087654},"windowLimits":{"fiveHour":{"used":0,"cap":14.00000000000000001234},"weekly":{"used":"6.20e-12","cap":35}}}`)
	s, err := parseCommandCode(Provider{ID: "command-code"}, body, []byte(commandSubscriptionFixture), time.Now())
	if err != nil {
		t.Fatal(err)
	}
	items := s.Groups[0].Items
	if items[0].UsedAmount != "0" || items[0].TotalAmount != "14.00000000000000001234" || items[1].UsedAmount != "0.00000000000620" || items[2].RemainingAmount != "0.00000000000000087654" {
		t.Fatal(items)
	}
}
func TestCommandCodeIndependentWindows(t *testing.T) {
	p := Provider{ID: "command-code", DisplayName: "Command Code"}
	for _, subscription := range []string{"", `{"data":{"status":"active","planId":"individual-future"}}`, `{"data":{"status":"cancelled","planId":"individual-max"}}`} {
		s, err := parseCommandCode(p, []byte(commandQuotaFixture), []byte(subscription), time.Now())
		if err != nil || len(s.Groups[0].Items) != 2 {
			t.Fatalf("sub %q: %+v %v", subscription, s, err)
		}
	}
	s, err := parseCommandCode(p, []byte(`{"windowLimits":{"fiveHour":{"used":12,"cap":10,"exceeded":true},"weekly":{"used":0,"cap":0}}}`), nil, time.Now())
	if err != nil || len(s.Groups[0].Items) != 1 || *s.Groups[0].Items[0].RemainingPercent != 0 || s.Groups[0].Items[0].Status != "error" {
		t.Fatalf("bad exhausted window %+v %v", s, err)
	}
	if _, err = parseCommandCode(p, []byte("{}"), nil, time.Now()); err == nil {
		t.Fatal("no metrics must be diagnosed")
	}
}

type billingTestTransport func(*http.Request) (*http.Response, error)

func (f billingTestTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func billingTestResponse(code int, body string) *http.Response {
	return &http.Response{StatusCode: code, Header: http.Header{}, Body: io.NopCloser(strings.NewReader(body))}
}

func TestCommandCodeMissingKeyAndRejectedIdentity(t *testing.T) {
	t.Setenv("TOKENMETER_TEST_NO_KEY", "")
	p := Provider{ID: "command-code", DisplayName: "Command Code", Endpoint: "https://example.invalid", Credential: &Credential{EnvironmentVariable: "TOKENMETER_TEST_NO_KEY"}}
	if _, err := collectCommandCode(context.Background(), Environment{Home: t.TempDir()}, p); err == nil || !strings.Contains(err.Error(), "设置页") {
		t.Fatalf("missing key: %v", err)
	}
	u, _ := url.Parse("https://example.invalid")
	c := &http.Client{Transport: billingTestTransport(func(r *http.Request) (*http.Response, error) {
		return billingTestResponse(401, "do not expose response body"), nil
	})}
	if _, err := fetchCommandCode(context.Background(), c, p, u, "fixture"); err == nil || err.Error() != "Command Code API Key 无效或已过期" {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestCommandCodeKeyPrecedence(t *testing.T) {
	home := t.TempDir()
	dir := filepath.Join(home, ".commandcode")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "auth.json"), []byte(`{"apiKey":"from_file"}`), 0600); err != nil {
		t.Fatal(err)
	}
	p := Provider{ID: "command-code", Credential: &Credential{EnvironmentVariable: "TM_TEST_COMMAND_KEY"}}
	t.Setenv("TM_TEST_COMMAND_KEY", "")
	if got := commandCodeKey(t.Context(), Environment{Home: home}, p); got != "from_file" {
		t.Fatal("did not find the agent login")
	}
	t.Setenv("TM_TEST_COMMAND_KEY", `  "from_env"  `)
	if got := commandCodeKey(t.Context(), Environment{Home: home}, p); got != "from_env" {
		t.Fatal("did not prefer the exported credential")
	}
}
