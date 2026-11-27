package account

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestClaudeWeeklyScopesAndWallet(t *testing.T) {
	p := Provider{ID: "claude-code", DisplayName: "Claude Code"}
	raw := `{"five_hour":{"utilization":12.5,"resets_at":"2026-07-02T08:10:00.500Z"},"seven_day":{"utilization":87},"seven_day_fable":{"utilization":30},"seven_day_opus":null,"limits":[{"kind":"weekly_scoped","scope":{"model":{"display_name":"FABLE"}},"percent":10},{"kind":"weekly_scoped","scope":{"model":{"display_name":"Claude ++ 新 型"}},"percent":"45"}],"extra_usage":{"is_enabled":false,"used_credits":305,"monthly_limit":null}}`
	s, err := parseClaude(p, []byte(raw), nil, time.Now())
	if err != nil || len(s.Groups) != 3 || s.Groups[0].Title != "Claude Code" || *s.Groups[0].Items[0].RemainingPercent != 87.5 || s.Groups[0].Items[0].ResetAt != "2026-07-02T08:10:00Z" || *s.Groups[0].Items[1].WindowDurationMinutes != 10080 || s.Groups[2].ID != "weekly-scoped-claude-新-型" || *s.Groups[2].Items[0].RemainingPercent != 55 {
		t.Fatal(s, err)
	}
	var credits struct{ Claude claudeCredits }
	if err = json.Unmarshal(s.AccountCredits, &credits); err != nil {
		t.Fatal(err)
	}
	if credits.Claude.ExtraUsage == nil || credits.Claude.ExtraUsage.Enabled == nil || *credits.Claude.ExtraUsage.Enabled || string(credits.Claude.ExtraUsage.Used.Value) != "3.05" || credits.Claude.ExtraUsage.Used.Currency != "USD" || credits.Claude.ExtraUsage.MonthlyLimit != nil {
		t.Fatal(string(s.AccountCredits))
	}
	for _, v := range []struct{ amount, unit, want string }{{"0", "usd", "0"}, {"750", "JPY", "750"}, {"-0.00001234", "USD", "-0.0000001234"}, {"1.50e3", "usd", "15"}, {"1e-3", "EUR", "0.00001"}, {"30000", "KRW", "30000"}, {"1e110", "USD", ""}, {"true", "CNY", ""}, {`"4"`, "USD", ""}, {"750", "", ""}} {
		m := claudeAmount(json.RawMessage(v.amount), v.unit)
		if v.want == "" {
			if m != nil {
				t.Fatal(v, m)
			}
			continue
		}
		if m == nil || string(m.Value) != v.want {
			t.Fatal(v, m)
		}
	}
}
func TestClaudeUsesAuthenticatedOrganizationAndKeepsIndependentResponses(t *testing.T) {
	const org = "a1111111-b222-c333-d444-e55555555555"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if r.Method != "GET" || token == "" || r.Header.Get("anthropic-beta") != "oauth-2025-04-20" {
			t.Error("bad authentication or method")
		}
		switch r.URL.Path {
		case "/api/oauth/usage":
			if r.Header.Get("User-Agent") != "claude-cli/9.9.9 (external, cli)" || r.Header.Get("x-app") != "cli" {
				t.Error("wrong client version or headers")
			}
			if token == "no-usage" {
				http.Error(w, `{"error":{"message":"wait"}}`, 429)
				return
			}
			fmt.Fprint(w, `{"five_hour":{"utilization":30},"extra_usage":{"is_enabled":true,"used_credits":600,"monthly_limit":2500,"currency":"usd"}}`)
		case "/api/oauth/profile":
			if token == "no-profile" {
				fmt.Fprint(w, "{}")
				return
			}
			fmt.Fprint(w, `{"organization":{"uuid":"`+strings.ToUpper(org)+`"}}`)
		case "/api/oauth/organizations/" + org + "/prepaid/credits":
			if token == "no-profile" || r.Header.Get("x-organization-uuid") != org {
				t.Error("wrong organization")
			}
			if token == "no-wallet" {
				w.WriteHeader(403)
				return
			}
			fmt.Fprint(w, `{"amount":1850,"currency":"usd"}`)
		default:
			t.Errorf("unexpected route %s", r.URL.Path)
			w.WriteHeader(404)
		}
	}))
	defer srv.Close()
	api := claudeAPI{srv.Client(), srv.URL + "/api/oauth/", "9.9.9"}
	for _, token := range []string{"both", "no-usage", "no-profile", "no-wallet"} {
		s, err := api.read(t.Context(), Provider{ID: "claude-code", DisplayName: "Claude Code"}, token)
		if (err != nil) != (token == "no-usage") {
			t.Fatalf("%s: %v", token, err)
		}
		if token == "no-usage" && err.Error() != "Claude 接口限流：wait" {
			t.Fatal(err)
		}
		var c struct{ Claude claudeCredits }
		json.Unmarshal(s.AccountCredits, &c)
		if token == "both" || token == "no-usage" {
			if c.Claude.Prepaid == nil || string(c.Claude.Prepaid.Value) != "18.5" {
				t.Fatal(c)
			}
		} else if c.Claude.Prepaid != nil {
			t.Fatal(c)
		}
		if token == "no-usage" {
			if len(s.Groups) > 0 || c.Claude.ExtraUsage != nil {
				t.Fatal(s)
			}
		} else if len(s.Groups) != 1 || *s.Groups[0].Items[0].RemainingPercent != 70 || string(c.Claude.ExtraUsage.MonthlyLimit.Value) != "25" {
			t.Fatal(s)
		}
	}
}
func TestClaudeFileCredentialsScopedToHome(t *testing.T) {
	h := t.TempDir()
	e := Environment{Home: h}
	p := Provider{ID: "claude-code"}
	dir := filepath.Join(h, ".claude")
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CLAUDE_CODE_OAUTH_TOKEN", "inherited-login")
	file := filepath.Join(dir, ".credentials.json")
	for _, tc := range []struct{ raw, token string }{{`{"claudeAiOauth":{"accessToken":"scoped"}}`, "scoped"}, {`{"accessToken":"old"}`, "old"}, {`{"claudeAiOauth":{"refreshToken":"never"}}`, ""}} {
		if err := os.WriteFile(file, []byte(tc.raw), 0600); err != nil {
			t.Fatal(err)
		}
		v, err := claudeToken(context.Background(), e, p)
		if v != tc.token || (tc.token == "") != (err != nil) {
			t.Fatalf("Unexpected credential selection or handling")
		}
	}
}

func TestClaudeKeychainProfileMatchesUpstream(t *testing.T) {
	t.Setenv("CLAUDE_SECURESTORAGE_CONFIG_DIR", "")
	if err := os.Unsetenv("CLAUDE_SECURESTORAGE_CONFIG_DIR"); err != nil {
		t.Fatal(err)
	}
	home := t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", filepath.Join(home, "Ame\u0301lie"))
	wantDir := filepath.Join(home, "Amélie")
	dir, service := claudeStorage(home)
	if dir != wantDir || service != "Claude Code-credentials-"+accountHash([]byte(wantDir))[:8] {
		t.Fatal(dir, service)
	}
	t.Setenv("CLAUDE_SECURESTORAGE_CONFIG_DIR", "")
	dir, service = claudeStorage(home)
	if dir != filepath.Join(home, ".claude") || service != "Claude Code-credentials" {
		t.Fatal(dir, service)
	}
	t.Setenv("USER", "invalid user")
	if claudeKeychainAccount() != "claude-code-user" {
		t.Fatal("wrong account fallback")
	}
}
