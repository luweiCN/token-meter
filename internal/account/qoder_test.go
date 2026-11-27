package account

import (
	"context"
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

var qoderProviderFixture = Provider{ID: "qoder", DisplayName: "Qoder"}

func TestQoderQuotaDetails(t *testing.T) {
	const raw = `{"userQuota":{"total":300,"used":12.5,"remaining":287.5,"percentage":0.1,"unit":"credits"},"addOnQuota":{"total":100,"used":25,"remaining":75},"orgResourcePackage":{"used":40,"cap":200,"remaining":160,"percentage":20,"available":false},"expiresAt":1790812800000}`
	var usage qoderUsage
	if err := json.Unmarshal([]byte(raw), &usage); err != nil {
		t.Fatal(err)
	}
	s, err := qoderSnapshot(qoderProviderFixture, &usage)
	if err != nil || len(s.Groups) != 1 || len(s.Groups[0].Items) != 3 {
		t.Fatal(s, err)
	}
	m := s.Groups[0].Items
	if s.Summary != "套餐剩余 287.5 / 300 Credits · 加购剩余 75 / 100 Credits · 组织包剩余 160 / 200 Credits" || s.Groups[0].Subtitle != "Credits" {
		t.Fatal(s)
	}
	if m[0].Label != "套餐" || math.Abs(*m[0].RemainingPercent-287.5/300*100) > 1e-9 || m[0].Detail != "12.5 / 300 Credits" || m[0].ResetAt != "" || m[0].ResetText != "" {
		t.Fatal(m[0])
	}
	if m[1].Label != "加购" || *m[1].RemainingPercent != 75 || m[1].Detail != "25 / 100 Credits" {
		t.Fatal(m[1])
	}
	if m[2].Label != "组织包" || m[2].Status != "warning" || *m[2].UsedPercent != 20 || m[2].Detail != "已用 40 · 剩余 160 · 总额 200 Credits · 当前不可用" {
		t.Fatal(m[2])
	}
}
func TestQoderMissingAndExceededAreDistinct(t *testing.T) {
	for _, tc := range []struct {
		raw       string
		status    string
		remaining *float64
		detail    string
	}{
		{`{}`, "", nil, ""}, {`{"userQuota":{}}`, "", nil, ""},
		{`{"isQuotaExceeded":true,"userQuota":{"used":300,"total":300,"remaining":0}}`, "warning", new(float64(0)), "300 / 300 Credits"},
		{`{"userQuota":{"remaining":276,"total":300}}`, "ok", new(float64(92)), "24 / 300 Credits"},
		{`{"userQuota":{"percentage":5}}`, "ok", new(float64(95)), ""},
		{`{"userQuota":{"total":100,"unit":"points"}}`, "ok", nil, "总额 100 points"},
	} {
		var u qoderUsage
		if err := json.Unmarshal([]byte(tc.raw), &u); err != nil {
			t.Fatal(err)
		}
		s, err := qoderSnapshot(qoderProviderFixture, &u)
		if tc.status == "" {
			if err == nil {
				t.Fatal(s)
			}
			continue
		}
		if err != nil || s.Status != tc.status {
			t.Fatal(s, err)
		}
		m := s.Groups[0].Items[0]
		if (m.RemainingPercent == nil) != (tc.remaining == nil) || tc.remaining != nil && *m.RemainingPercent != *tc.remaining || m.Detail != tc.detail {
			t.Fatal(m)
		}
	}
}

func TestQoderControlReplies(t *testing.T) {
	for _, mode := range []string{"qoder-models", "qoder-usage", "qoder-noquota", "qoder-error"} {
		ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
		reply, err := qoderExchange(ctx, billingFixtureProcess(ctx, mode), mode != "qoder-models")
		cancel()
		switch mode {
		case "qoder-error":
			if err == nil || strings.Contains(err.Error(), "secret") {
				t.Fatal(err)
			}
		case "qoder-noquota":
			if err != nil {
				t.Fatal(err)
			}
			if _, err := qoderSnapshot(qoderProviderFixture, reply.Usage); err == nil {
				t.Fatal("missing quota accepted")
			}
		case "qoder-models":
			if err != nil || len(reply.Models) != 2 || reply.Models[0].ModelID != "id1" || reply.Models[0].IsEnabled == nil || !*reply.Models[0].IsEnabled {
				t.Fatal(reply, err)
			}
		default:
			s, parseErr := qoderSnapshot(qoderProviderFixture, reply.Usage)
			if err != nil || parseErr != nil || *s.Groups[0].Items[0].RemainingPercent != 88 {
				t.Fatal(reply, err, parseErr)
			}
		}
	}
}

func TestQoderResolvesSelectedExecutable(t *testing.T) {
	e := Environment{Home: t.TempDir()}
	dir := filepath.Join(e.Home, ".qoder-cn", "bin", "qoderclicn")
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	ext := ""
	if runtime.GOOS == "windows" {
		ext = ".exe"
	}
	for _, v := range []string{"1.1.9", "1.1.58"} {
		if err := os.WriteFile(filepath.Join(dir, "qoderclicn-"+v+ext), []byte("test"), 0700); err != nil {
			t.Fatal(err)
		}
	}
	for _, tc := range []struct{ text, want string }{{"1.1.9\n", "1.1.9"}, {"../../bin/other", "1.1.58"}, {"", "1.1.58"}} {
		if err := os.WriteFile(filepath.Join(dir, "version.txt"), []byte(tc.text), 0600); err != nil {
			t.Fatal(err)
		}
		exe, err := qoderExecutable(e)
		if err != nil || exe != filepath.Join(dir, "qoderclicn-"+tc.want+ext) {
			t.Fatal(exe, err)
		}
	}
}

func TestQoderOfficialNPMShimMetadata(t *testing.T) {
	dir := t.TempDir()
	pkg := filepath.Join(dir, "node_modules", "@qoder-ai", "qodercli")
	if err := os.MkdirAll(filepath.Join(pkg, "bundle"), 0700); err != nil {
		t.Fatal(err)
	}
	script := filepath.Join(pkg, "bundle", "qoder.js")
	if err := os.WriteFile(script, []byte("fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	manifest := filepath.Join(pkg, "package.json")
	if err := os.WriteFile(manifest, []byte(`{"bin":{"qoder":"./bundle/qoder.js"}}`), 0600); err != nil {
		t.Fatal(err)
	}
	shim := filepath.Join(dir, "qoder.cmd")
	if got := qoderNPMEntry(shim); got != script {
		t.Fatal(got)
	}
	if err := os.WriteFile(manifest, []byte(`{"bin":{"qoder":"../outside.js"}}`), 0600); err != nil {
		t.Fatal(err)
	}
	if got := qoderNPMEntry(shim); got != "" {
		t.Fatal("out-of-package entry accepted")
	}
}

func TestVendorCommandsThroughCollector(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("POSIX fixture launchers; protocol exchanges also run on Windows")
	}
	home := t.TempDir()
	env := Environment{Home: home}
	t.Setenv("QODERCLI_PATH", "")
	t.Setenv("GROK_HOME", filepath.Join(home, ".grok"))
	t.Setenv("TOKENMETER_TEST_BILLING_CHILD", "1")
	t.Setenv("TOKENMETER_BILLING_TEST_BINARY", os.Args[0])
	for _, f := range []struct{ path, source string }{
		{".grok/auth.json", `{"https://auth.x.ai::fixture":{"key":"fixture"}}`},
		{".grok/bin/grok", "#!/bin/sh\n[ \"$#\" -eq 3 ] && [ \"$*\" = 'agent --no-leader stdio' ] || exit 2\nexec \"$TOKENMETER_BILLING_TEST_BINARY\" -test.run=^TestAgentBillingChildProcess$ -- new\n"},
		{".qoder-cn/bin/qoderclicn/qoderclicn-1.3", "#!/bin/sh\n[ \"$#\" -eq 8 ] && [ \"$7\" = '--tools' ] && [ -z \"$8\" ] && [ \"$6\" = '--no-session-persistence' ] || exit 2\nexec \"$TOKENMETER_BILLING_TEST_BINARY\" -test.run=^TestAgentBillingChildProcess$ -- qoder-usage\n"},
	} {
		path := filepath.Join(home, filepath.FromSlash(f.path))
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(f.source), 0700); err != nil {
			t.Fatal(err)
		}
	}
	if s, err := collectGrok(t.Context(), env, grokProviderFixture); err != nil || *s.Groups[0].Items[0].RemainingPercent != 88 {
		t.Fatal(s, err)
	}
	if s, err := collectQoder(t.Context(), env, qoderProviderFixture); err != nil || *s.Groups[0].Items[0].RemainingPercent != 88 {
		t.Fatal(s, err)
	}
	if models, err := QoderModels(t.Context(), env); err != nil || len(models) != 1 || models[0].Value != "qmodel" {
		t.Fatal(models, err)
	}
}

func TestQoderReportsExactAmountsAndUnitPerGroup(t *testing.T) {
	var u qoderUsage
	const raw = `{"userQuota":{"total":9007199254740993.123456789,"used":0.000000001,"remaining":"9007199254740993.123456788","unit":"credits"},"addOnQuota":{"percentage":0},"orgResourcePackage":{"used":0,"cap":201.123456789,"unit":"points"}}`
	if err := json.Unmarshal([]byte(raw), &u); err != nil {
		t.Fatal(err)
	}
	s, err := qoderSnapshot(qoderProviderFixture, &u)
	if err != nil {
		t.Fatal(err)
	}
	m := s.Groups[0].Items
	if m[0].UsedAmount != "0.000000001" || m[0].RemainingAmount != "9007199254740993.123456788" || m[0].TotalAmount != "9007199254740993.123456789" || m[0].Unit != "Credits" {
		t.Fatal(m[0])
	}
	if m[1].RemainingAmount != "" || m[1].UsedAmount != "" || m[1].TotalAmount != "" || m[1].Unit != "" || *m[1].RemainingPercent != 100 {
		t.Fatal(m[1])
	}
	if m[2].UsedAmount != "0" || m[2].TotalAmount != "201.123456789" || m[2].RemainingAmount != "" || m[2].Unit != "points" {
		t.Fatal(m[2])
	}
}
