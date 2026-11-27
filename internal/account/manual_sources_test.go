package account

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestManualUsesDeclaredUnits(t *testing.T) {
	used, remaining, total := json.Number("1200"), json.Number("8800"), json.Number("10000")
	cfg := Provider{ID: "custom", DisplayName: "测试", ManualUsage: &ManualUsage{
		Label: "今日", Status: "ok", Unit: "tokens", Used: &used, Remaining: &remaining, Total: &total,
	}}
	s, err := collectManual(t.Context(), Environment{}, cfg)
	if err != nil {
		t.Fatal(err)
	}
	m := s.Groups[0].Items[0]
	if m.Kind != "quota" || *m.UsedPercent != 12 || *m.RemainingPercent != 88 || !strings.Contains(m.Detail, "8800 tokens") ||
		m.Unit != "tokens" || m.UsedAmount != "1200" || m.RemainingAmount != "8800" || m.TotalAmount != "10000" {
		t.Fatalf("手填 Token 的单位或占比不符: %+v", m)
	}
	cfg.ManualUsage.Total = nil
	s, err = collectManual(t.Context(), Environment{}, cfg)
	if err != nil || s.Groups[0].Items[0].RemainingPercent != nil || s.Groups[0].Items[0].Kind != "quota" ||
		s.Groups[0].Items[0].RemainingAmount != "8800" || s.Groups[0].Items[0].TotalAmount != "" {
		t.Fatalf("缺少总额时仍产生了百分比: %+v, %v", s, err)
	}
	cfg.ManualUsage.Remaining = nil
	s, err = collectManual(t.Context(), Environment{}, cfg)
	if err != nil || s.Groups[0].Items[0].Kind != "tokens" || s.Groups[0].Items[0].UsedAmount != "1200" || s.Groups[0].Items[0].RemainingAmount != "" {
		t.Fatalf("仅上报已用 Token 时应保留累计值: %+v, %v", s, err)
	}
	cfg.ManualUsage = &ManualUsage{Status: "ok", Label: "今日", Remaining: &remaining, Unit: "tokens", Total: &total}
	s, err = collectManual(t.Context(), Environment{}, cfg)
	if err != nil || *s.Groups[0].Items[0].UsedPercent != 12 {
		t.Fatalf("只提供剩余量时的百分比: %+v, %v", s, err)
	}
	cfg.ManualUsage = nil
	s, err = collectManual(t.Context(), Environment{}, cfg)
	if err != nil || s.Status != "unknown" || s.Groups[0].Items[0].Label != "用量" {
		t.Fatalf("未配置的手工额度: %+v, %v", s, err)
	}
}

func TestManualKeepsOriginalDecimalsAndDoesNotInferAbsoluteBalances(t *testing.T) {
	var config Provider
	err := json.Unmarshal([]byte(`{"id":"custom","displayName":"手填","manualUsage":{"status":"ok","label":"账户余额","unit":"CNY","remaining":9007199254740993.1234567890123,"used":0}}`), &config)
	if err != nil {
		t.Fatal(err)
	}
	s, err := collectManual(t.Context(), Environment{}, config)
	if err != nil {
		t.Fatal(err)
	}
	m := s.Groups[0].Items[0]
	if m.Unit != "CNY" || m.RemainingAmount != "9007199254740993.1234567890123" || m.UsedAmount != "0" ||
		m.TotalAmount != "" || m.RemainingPercent != nil {
		t.Fatalf("原始十进制余额、零或未知总额有误: %+v", m)
	}
	pct := json.Number("57.5")
	config.ManualUsage = &ManualUsage{Status: "ok", Label: "窗口", Unit: "%", Remaining: &pct}
	s, err = collectManual(t.Context(), Environment{}, config)
	if err != nil {
		t.Fatal(err)
	}
	m = s.Groups[0].Items[0]
	if *m.RemainingPercent != 57.5 || m.Unit != "" || m.RemainingAmount != "" || m.UsedAmount != "" || m.TotalAmount != "" {
		t.Fatalf("百分比被当成了实际金额或余额: %+v", m)
	}
}

func TestManualUnitlessBudgetZeroAndPercent(t *testing.T) {
	zero, used, total := json.Number("0"), json.Number("253"), json.Number("253")
	p := Provider{ID: "budget", DisplayName: "手填", ManualUsage: &ManualUsage{Status: "ok", Label: "用量", Used: &used, Remaining: &zero, Total: &total}}
	s, err := collectManual(t.Context(), Environment{}, p)
	if err != nil {
		t.Fatal(err)
	}
	s.normalize(p)
	m := s.Groups[0].Items[0]
	if m.UsedAmount != "253" || m.RemainingAmount != "0" || m.TotalAmount != "253" || m.Unit != "" ||
		m.RemainingPercent == nil || *m.RemainingPercent != 0 {
		t.Fatalf("未标注单位时须保留源预算与零余量: %+v", m)
	}
	p.ManualUsage.Used, p.ManualUsage.Total = nil, nil
	s, err = collectManual(t.Context(), Environment{}, p)
	if err != nil {
		t.Fatal(err)
	}
	s.normalize(p)
	m = s.Groups[0].Items[0]
	if m.RemainingPercent == nil || *m.RemainingPercent != 0 || m.Unit != "" || m.RemainingAmount != "" || m.TotalAmount != "" {
		t.Fatalf("未提供总数和单位时仅报告给定比例: %+v", m)
	}
}

func TestQuotaCacheSelectsSourceAndPreservesWindows(t *testing.T) {
	home := t.TempDir()
	e := Environment{Home: home}
	cfg := Provider{ID: "quota", DisplayName: "测试", QuotaCache: &QuotaCache{Directory: "~", ProviderID: "zhipu"}}
	at := time.Date(2026, 6, 20, 5, 0, 14, 0, time.UTC)
	doc := `{"result":{"entries":[{"label":"5h:","percentRemaining":83,"resetTimeIso":"2026-06-27T15:05:14.968Z"},{"label":"Weekly：","percentRemaining":"93.5"},{"name":"MCP","percentRemaining":0}]},"data":{"percentRemaining":1}}`
	for _, f := range []struct {
		name string
		data string
		time time.Time
	}{
		{"zhipu-old", `{"percentRemaining":2}`, at.Add(-time.Hour)},
		{"zhipu-active", doc, at},
		{"another-file", `{"percentRemaining":50}`, at.Add(time.Hour)},
	} {
		p := filepath.Join(home, f.name)
		if err := os.WriteFile(p, []byte(f.data), 0600); err != nil {
			t.Fatal(err)
		}
		if err := os.Chtimes(p, f.time, f.time); err != nil {
			t.Fatal(err)
		}
	}
	s, err := collectQuotaCache(t.Context(), e, cfg)
	if err != nil {
		t.Fatal(err)
	}
	m := s.Groups[0].Items
	if len(m) != 3 || *m[0].RemainingPercent != 83 || *m[2].RemainingPercent != 0 || s.Summary != "5h 83% · Weekly 93.5% · MCP 0%" ||
		m[0].ResetAt != "2026-06-27T15:05:14Z" || s.FetchedAt != at.Format(time.RFC3339) {
		t.Fatalf("缓存额度/原采集时间不符: %+v", s)
	}
	cfg.QuotaCache.ProviderID = "unknown"
	_, err = collectQuotaCache(t.Context(), e, cfg)
	if err == nil || !strings.Contains(err.Error(), "unknown") {
		t.Fatalf("缺少缓存错误: %v", err)
	}
}

func TestShellSourceSubprocess(t *testing.T) {
	mode := os.Getenv("TOKENMETER_TEST_QUOTA_CHILD")
	if mode == "" {
		return
	}
	switch mode {
	case "quota":
		fmt.Print("#[fg=colour5,bold]codex #[default]5h #[fg=colour2]69% 2h47m · 7d 70% 5d7h")
	case "error":
		fmt.Fprint(os.Stderr, "secret-stderr")
		os.Exit(7)
	case "timeout":
		time.Sleep(time.Minute)
	case "large":
		fmt.Print(strings.Repeat("x", (1<<20)+1))
	}
	os.Exit(0)
}

func TestShellCommandQuotaIsCancellableAndLiteral(t *testing.T) {
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	e := Environment{Home: t.TempDir()}
	cmd := &Command{Executable: exe, Arguments: []string{"-test.run=^TestShellSourceSubprocess$"}, Environment: map[string]string{"TOKENMETER_TEST_QUOTA_CHILD": "quota"}}
	p := Provider{ID: "shell", DisplayName: "Shell", Command: cmd}
	s, err := collectShellCommand(t.Context(), e, p)
	if err != nil {
		t.Fatal(err)
	}
	m := s.Groups[0].Items[0]
	if *m.UsedPercent != 31 || *m.RemainingPercent != 69 || s.Message != "codex 5h 69% 2h47m · 7d 70% 5d7h" {
		t.Fatalf("tmux 输出: %+v", s)
	}
	for _, mode := range []string{"error", "large", "timeout"} {
		t.Run(mode, func(t *testing.T) {
			ctx := t.Context()
			if mode == "timeout" {
				var cancel context.CancelFunc
				ctx, cancel = context.WithTimeout(ctx, 200*time.Millisecond)
				defer cancel()
			}
			cmd.Environment["TOKENMETER_TEST_QUOTA_CHILD"] = mode
			_, err := collectShellCommand(ctx, e, p)
			if err == nil || strings.Contains(err.Error(), "secret-stderr") {
				t.Fatalf("失败命令的错误: %v", err)
			}
			if mode == "error" && err.Error() != "命令退出 7" {
				t.Fatalf("退出码: %v", err)
			}
			if mode == "timeout" && !errors.Is(err, context.DeadlineExceeded) {
				t.Fatalf("被取消的查询须返回超时原因: %v", err)
			}
		})
	}
}

func TestOpenCodeSQLiteReadsOnlyAggregates(t *testing.T) {
	home := t.TempDir()
	env := Environment{Home: home}
	path := filepath.Join(home, "quota # 1.db")
	cfg := Provider{ID: "oc", DisplayName: "OpenCode", DatabasePath: "~/quota # 1.db"}
	if _, err := collectOpenCodeSQLite(t.Context(), env, cfg); err == nil {
		t.Fatal("缺少 SQLite 数据库时应返回错误")
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("只读查询创建了源库: %v", err)
	}
	db, err := sql.Open("sqlite", sqliteFile(path))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec(`CREATE TABLE session(tokens_input INTEGER,tokens_output INTEGER,tokens_cache_read INTEGER,tokens_cache_write INTEGER,tokens_reasoning INTEGER);
		INSERT INTO session VALUES(1000,150,300,50,15),(0,NULL,NULL,NULL,2)`); err != nil {
		t.Fatal(err)
	}
	s, err := collectOpenCodeSQLite(t.Context(), env, cfg)
	if err != nil {
		t.Fatal(err)
	}
	m := s.Groups[0].Items[0]
	if m.Detail != "2 sessions · 1517 tokens" || s.Summary != "2 sessions · 1.5K tokens" || m.Kind != "tokens" || m.RemainingPercent != nil || m.UsedPercent != nil ||
		m.Unit != "tokens" || m.UsedAmount != "1517" || m.RemainingAmount != "" || m.TotalAmount != "" {
		t.Fatalf("OpenCode 总数或单位不符: %+v", s)
	}
}
