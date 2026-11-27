package account

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestZhipuAPILimits(t *testing.T) {
	p := Provider{ID: "zhipu", DisplayName: "智谱"}
	s, err := parseZhipu(p, []byte(`{"data":{"limits":[{"type":"TIME_LIMIT","unit":5,"percentage":"3","usage":4000,"currentValue":140,"remaining":3860},{"type":"TOKENS_LIMIT","unit":"3","percentage":26,"nextResetTime":1784359374998},{"type":"TOKENS_LIMIT","unit":6,"percentage":86},{"type":"OTHER","unit":0,"percentage":50}]},"success":true}`), time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if s.Summary != "5h 74% · 7d 14% · MCP 97%" {
		t.Errorf("wrong summary %v", s)
	}
	m := s.Groups[0].Items
	if m[0].ResetAt != time.UnixMilli(1784359374998).UTC().Format(time.RFC3339) || *m[0].WindowDurationMinutes != 300 || m[2].Detail != "140/4000 次" || m[2].WindowDurationMinutes != nil {
		t.Errorf("wrong details %+v", m)
	}
	if m[2].UsedAmount != "140" || m[2].RemainingAmount != "3860" || m[2].TotalAmount != "4000" || m[2].Unit != "次" {
		t.Fatal(m[2])
	}
	if m[0].UsedAmount != "" || m[0].TotalAmount != "" || m[0].RemainingAmount != "" || m[0].Unit != "" {
		t.Fatal(m[0])
	}
}

func TestZhipuBalanceAndUnknown(t *testing.T) {
	p := Provider{ID: "zhipu", DisplayName: "智谱"}
	for _, v := range []struct {
		body    string
		percent float64
		detail  string
	}{
		{`{"data":{"currency":"CNY","used_quota":2000,"remain_quota":"3000","total_quota":5000}}`, 60, "剩余 3000 CNY"},
		{`{"data":{"percentage":17}}`, 83, ""},
		{`{"data":{"remaining":18}}`, -1, "剩余 18"},
	} {
		s, err := parseZhipu(p, []byte(v.body), time.Now())
		if err != nil {
			t.Fatal(err)
		}
		m := s.Groups[0].Items[0]
		if m.Kind != "balance" || !strings.Contains(m.Detail, v.detail) || (v.percent < 0) != (m.RemainingPercent == nil) || (m.RemainingPercent != nil && *m.RemainingPercent != v.percent) {
			t.Errorf("bad balance %+v", m)
		}
	}
	for _, body := range []string{`{"success":false,"code":1000,"msg":"test-secret"}`, `{"data":{"limits":[{"type":"UNKNOWN","unit":1,"percentage":5}]}}`, `{}`, `null`, `!`, `{"data":{"remaining":10}}{}`} {
		_, err := parseZhipu(p, []byte(body), time.Now())
		if err == nil || strings.Contains(err.Error(), "test-secret") {
			t.Fatalf("error exposed raw response or missing: %v", err)
		}
	}
}

func TestZhipuAmountsDoNotAssumeCurrency(t *testing.T) {
	p := Provider{ID: "zhipu"}
	for _, tc := range []struct{ body, used, left, total, unit string }{
		{`{"data":{"currency":"CNY","used_quota":0,"remain_quota":26.000000000000000009,"total_quota":"40.00"}}`, "0", "26.000000000000000009", "40.00", "CNY"},
		{`{"currency":"USD","data":{"available":"0.000001"}}`, "", "0.000001", "", "USD"},
		{`{"data":[{"available":25},{"currency":"CNY","total":30}]}`, "", "25", "", ""},
		{`{"data":{"currency":"CNY","percentage":17}}`, "", "", "", ""},
		{`{"data":{"limits":[{"type":"TIME_LIMIT","unit":5,"percentage":50,"remaining":9007199254740993}]}}`, "", "9007199254740993", "", "次"},
		{`{"data":{"limits":[{"type":"TIME_LIMIT","unit":5,"remaining":0}]}}`, "", "0", "", "次"},
	} {
		s, err := parseZhipu(p, []byte(tc.body), time.Now())
		if err != nil {
			t.Fatal(err)
		}
		m := s.Groups[0].Items[0]
		if m.UsedAmount != tc.used || m.RemainingAmount != tc.left || m.TotalAmount != tc.total || m.Unit != tc.unit || (tc.unit == "" && strings.Contains(m.Detail, "CNY")) {
			t.Fatal(m)
		}
		if m.RemainingAmount == "0" && (m.RemainingPercent != nil || s.Summary != "MCP 剩余 0 次") {
			t.Fatal(s)
		}
	}
}

func TestZhipuRejectsUnselectedCredentials(t *testing.T) {
	home := t.TempDir()
	file := filepath.Join(home, "other-provider.key")
	if err := os.WriteFile(file, []byte("another-account"), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TEST_ZHIPU_UNSET", "")
	p := Provider{ID: "zhipu", DisplayName: "智谱", Endpoint: "https://example.invalid", Credential: &Credential{EnvironmentVariable: "TEST_ZHIPU_UNSET", FilePath: file}}
	_, err := collectZhipu(context.Background(), Environment{Home: home}, p)
	if err == nil || !strings.Contains(err.Error(), "缺少") {
		t.Fatalf("unrelated key was considered: %v", err)
	}
}
