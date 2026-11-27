package account

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

func engineHome(t *testing.T) string {
	t.Helper()
	t.Setenv("TOKENMETER_CONFIG", "")
	home := t.TempDir()
	if err := os.Mkdir(filepath.Join(home, ".token-meter"), 0700); err != nil {
		t.Fatal(err)
	}
	return home
}
func putProviders(t *testing.T, home string, providers ...Provider) {
	t.Helper()
	data, err := json.Marshal(config{providers})
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(home, ".token-meter", "config.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
}
func engineProvider(id string) Provider {
	return Provider{ID: id, DisplayName: id, Type: "test", Enabled: true}
}
func engineSnapshot(t *testing.T, home string) map[string]Snapshot {
	t.Helper()
	records, err := loadSnapshots(filepath.Join(home, ".token-meter", "cache", "provider-snapshots.json"))
	if err != nil {
		t.Fatal(err)
	}
	result := map[string]Snapshot{}
	for _, s := range records {
		result[s.ProviderID] = s
	}
	return result
}

func TestProviderSettingsOverrideConfig(t *testing.T) {
	home := engineHome(t)
	on, off := engineProvider("on"), engineProvider("off")
	off.Enabled = false
	putProviders(t, home, on, off)
	db, err := sql.Open("sqlite", sqliteFile(filepath.Join(home, ".token-meter", "tokenmeter.sqlite")))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err = db.Exec(`CREATE TABLE provider_config_overrides(provider_id TEXT,enabled INTEGER); INSERT INTO provider_config_overrides VALUES ('on',0),('off',1); CREATE TABLE settings(key TEXT,value_json TEXT); INSERT INTO settings VALUES ('scan.autoRefreshSeconds','900');`); err != nil {
		t.Fatal(err)
	}
	conf, err := readPreferences(context.Background(), home)
	if err != nil {
		t.Fatal(err)
	}
	if conf.interval != 15*time.Minute || len(conf.providers) != 3 || conf.providers[0].Enabled || !conf.providers[1].Enabled || conf.providers[2].Type != "antigravity" || conf.providers[2].Enabled {
		t.Fatalf("unexpected effective settings %+v", conf)
	}
}

func TestAccountRefreshSingleAndFailure(t *testing.T) {
	home := engineHome(t)
	a, b := engineProvider("a"), engineProvider("b")
	putProviders(t, home, a, b)
	var fail atomic.Bool
	var count atomic.Int32
	plugins := map[string]collector{"test": func(ctx context.Context, e Environment, p Provider) (Snapshot, error) {
		count.Add(1)
		s := NewSnapshot(p)
		if fail.Load() {
			return s, errors.New("该账号额度查询受限")
		}
		value := float64(0)
		s.Groups = []Group{{ID: p.ID, Title: p.DisplayName, Items: []Metric{{ID: "weekly", Kind: "quota", Status: "warning", RemainingPercent: &value}}}}
		s.AccountCredits = json.RawMessage(`{"codex":{"_0":{"amount":{"_0":23.12}}}}`)
		return s, nil
	}}
	if err := refresh(context.Background(), home, "", false, plugins); err != nil {
		t.Fatal(err)
	}
	if err := refresh(context.Background(), home, "", false, plugins); err != nil {
		t.Fatal(err)
	}
	if count.Load() != 2 {
		t.Fatalf("重复请求了已刷新供应商 %d", count.Load())
	}
	first := engineSnapshot(t, home)
	fail.Store(true)
	if err := refresh(context.Background(), home, "a", true, plugins); err != nil {
		t.Fatal(err)
	}
	got := engineSnapshot(t, home)
	if count.Load() != 3 || len(got) != 2 || got["a"].Status != "warning" || got["a"].Message != "该账号额度查询受限" || !usableQuota(got["a"]) || len(got["a"].AccountCredits) != 0 || got["a"].FetchedAt != first["a"].FetchedAt || len(got["b"].AccountCredits) == 0 {
		t.Fatalf("bad refresh %+v", got)
	}

	b.Enabled = false
	putProviders(t, home, a, b)
	if err := refresh(context.Background(), home, "", false, plugins); err != nil {
		t.Fatal(err)
	}
	if _, ok := engineSnapshot(t, home)["b"]; ok {
		t.Fatal("disabled account published")
	}
	if err := refresh(context.Background(), home, "b", true, plugins); err == nil {
		t.Fatal("explicitly disabled collection permitted")
	}
}

func TestOverlappingRequestsShareObservation(t *testing.T) {
	home := engineHome(t)
	putProviders(t, home, engineProvider("one"))
	var n atomic.Int32
	entered := make(chan struct{})
	release := make(chan struct{})
	plugins := map[string]collector{"test": func(ctx context.Context, e Environment, p Provider) (Snapshot, error) {
		if n.Add(1) == 1 {
			close(entered)
			<-release
		}
		return NewSnapshot(p), nil
	}}
	done := make(chan error, 2)
	go func() { done <- refresh(context.Background(), home, "", false, plugins) }()
	<-entered
	go func() { done <- refresh(context.Background(), home, "one", true, plugins) }()
	// Keep the first vendor call in flight past acquisition of the second SQLite connection.
	time.Sleep(150 * time.Millisecond)
	close(release)
	for range 2 {
		if err := <-done; err != nil {
			t.Fatal(err)
		}
	}
	if n.Load() != 1 {
		t.Fatalf("overlap made %d vendor requests", n.Load())
	}
}

func TestIncompleteSuccessfulWindows(t *testing.T) {
	now := time.Date(2026, 1, 2, 3, 0, 0, 0, time.UTC)
	p := engineProvider("account")
	prev, cur := NewSnapshot(p), NewSnapshot(p)
	week, hour := 10080, 60
	remaining := float64(12)
	prev.Groups = []Group{{ID: "main", Title: p.DisplayName, Items: []Metric{
		{ID: "future", Kind: "quota", RemainingPercent: &remaining, WindowDurationMinutes: &hour, ResetAt: now.Add(time.Hour).Format(time.RFC3339)},
		{ID: "expired", Kind: "quota", RemainingPercent: &remaining, WindowDurationMinutes: &hour, ResetAt: now.Add(-time.Minute).Format(time.RFC3339)},
	}}}
	cur.Groups = []Group{{ID: "main", Title: p.DisplayName, Items: []Metric{{ID: "week", Kind: "quota", RemainingPercent: &remaining, WindowDurationMinutes: &week}}}}
	cur.Status = "warning" // A real exhausted quota can be returned with warning.
	got := mergeSnapshot(now, prev, cur)
	if len(got.Groups[0].Items) != 2 || got.Groups[0].Items[0].ID != "future" || got.Groups[0].Items[1].ID != "week" {
		t.Fatalf("wrong retained windows %+v", got.Groups)
	}
}

func TestFixturesDoNotReadOtherUserKeychain(t *testing.T) {
	home := engineHome(t)
	env := Environment{Home: home}
	p := Provider{ID: "test", Credential: &Credential{EnvironmentVariable: "TEST_QUOTA_TOKEN", FilePath: "~/token"}}
	t.Setenv("TEST_QUOTA_TOKEN", "configured")
	if err := os.WriteFile(filepath.Join(home, "token"), []byte(" 'from-file' "), 0600); err != nil {
		t.Fatal(err)
	}
	tokens := env.CredentialTokens(context.Background(), p)
	if len(tokens) != 2 || tokens[0] != "configured" || tokens[1] != "from-file" {
		t.Fatal("unexpected credential precedence")
	}
}

func TestStatusLineObservationAdvancesScheduledRefresh(t *testing.T) {
	home := engineHome(t)
	p := engineProvider("test-agy")
	p.Type = "antigravity"
	putProviders(t, home, p)
	var calls atomic.Int32
	plugins := map[string]collector{p.Type: func(ctx context.Context, e Environment, p Provider) (Snapshot, error) {
		calls.Add(1)
		return NewSnapshot(p), nil
	}}
	poll := func() {
		t.Helper()
		if err := refresh(context.Background(), home, "", false, plugins); err != nil {
			t.Fatal(err)
		}
	}
	poll()
	poll()
	if err := os.WriteFile(agyReadingPath(home), []byte(`{"observedAt":"2026-11-25T01:00:00Z","buckets":{}}`), 0600); err != nil {
		t.Fatal(err)
	}
	poll()
	poll()
	if calls.Load() != 2 {
		t.Fatalf("got %d checks for 2 observations", calls.Load())
	}
}

func TestDisablingAnAccountDuringItsRequestDropsTheResult(t *testing.T) {
	home := engineHome(t)
	p := engineProvider("one")
	putProviders(t, home, p)
	entered := make(chan struct{})
	release := make(chan struct{})
	plugins := map[string]collector{p.Type: func(ctx context.Context, e Environment, p Provider) (Snapshot, error) {
		close(entered)
		<-release
		return NewSnapshot(p), nil
	}}
	done := make(chan error, 1)
	go func() { done <- refresh(context.Background(), home, "", true, plugins) }()
	<-entered
	p.Enabled = false
	putProviders(t, home, p)
	close(release)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if snapshots, err := Read(home); err != nil || len(snapshots) != 0 {
		t.Fatalf("disabled account present: %+v %v", snapshots, err)
	}
}

func TestSnapshotSwiftWireFormat(t *testing.T) {
	const precise = "2030-01-02T05:06:07.123456+03:00"
	const utc = "2030-01-02T02:06:07Z"
	p := engineProvider("wire")
	got := Snapshot{FetchedAt: precise, Groups: []Group{{}, {Items: []Metric{{ResetAt: precise}, {ResetAt: "invalid"}}}}, ResetCredits: &ResetCredits{Credits: []ResetCredit{{IssuedAt: precise, ExpiresAt: precise}}}}
	got.normalize(p)
	if got.FetchedAt != utc || got.Groups[0].Items == nil || got.Groups[1].Items[0].ResetAt != utc || got.Groups[1].Items[1].ResetAt != "" || got.ResetCredits.Credits[0].IssuedAt != utc || got.ResetCredits.Credits[0].ExpiresAt != utc {
		t.Fatalf("invalid wire dates/array: %+v", got)
	}
	got = Snapshot{ResetCredits: &ResetCredits{}}
	got.normalize(p)
	if got.Groups == nil || got.ResetCredits.Credits == nil {
		t.Fatal("nil wire arrays")
	}
}

func TestDecimalAmountAndQuantityOnlyQuota(t *testing.T) {
	for input, expected := range map[string]string{
		"0": "0", "000.50": "0.50", "-.5": "", "-1.200": "-1.200", "+23": "23",
		"9.007199254740993123456e15": "9007199254740993.123456", "1.2e-4": "0.00012", "23e2": "2300",
		"1e999999999999999": "", "NaN": "", "Inf": "", "1x0": "", "私有信息": "",
	} {
		if actual := DecimalAmount(input); actual != expected {
			t.Errorf("decimal %q: %q, want %q", input, actual, expected)
		}
	}
	p := engineProvider("only-amount")
	now := time.Now()
	prev := NewSnapshot(p)
	prev.Groups = []Group{{Items: []Metric{{Kind: "quota", Label: "余量", RemainingAmount: "0", Unit: "credits"}}}}
	failed := NewSnapshot(p)
	failed.Status = "error"
	got := mergeSnapshot(now, prev, failed)
	if got.Status != "warning" || !usableQuota(got) || got.Groups[0].Items[0].RemainingAmount != "0" {
		t.Fatalf("lost a quantity-only zero: %+v", got)
	}
	malformed := NewSnapshot(p)
	malformed.Groups = []Group{{Items: []Metric{{Label: "bad", UsedAmount: "NaN", Unit: "credits"}}}}
	malformed.normalize(p)
	if usableQuota(malformed) || malformed.Groups[0].Items[0].Unit != "" {
		t.Fatalf("invalid quantity retained: %+v", malformed)
	}
}

func TestRefreshFailureDropsAllCachedWalletRepresentations(t *testing.T) {
	p := engineProvider("wallet")
	previous := NewSnapshot(p)
	previous.AccountCredits = json.RawMessage(`{"codex":{"_0":{"amount":{"_0":123}}}}`)
	previous.Summary = "可用 123 积分"
	wallet := Metric{ID: "wallet", Label: "预付", Kind: "balance", RemainingAmount: "123", Unit: "USD"}
	window := Metric{ID: "window", Label: "额度", Kind: "quota", RemainingAmount: "9", Unit: "Token"}
	failed := NewSnapshot(p)
	failed.Status = "error"
	failed.Message = "登录已过期"
	for _, quota := range []bool{false, true} {
		items := []Metric{wallet}
		if quota {
			items = append(items, window)
		}
		previous.Groups = []Group{{ID: "main", Title: "主额度", Subtitle: previous.Summary, Items: items}}
		got := mergeSnapshot(time.Now(), previous, failed)
		if len(got.AccountCredits) > 0 || got.Summary != "" {
			t.Fatal("cached wallet persisted", got)
		}
		if !quota && (got.Status != "error" || len(got.Groups) != 0) {
			t.Fatal("cached pure wallet persisted", got)
		}
		if quota && (got.Status != "warning" || len(got.Groups) != 1 || got.Groups[0].Subtitle != "" || len(got.Groups[0].Items) != 1 || got.Groups[0].Items[0].ID != "window") {
			t.Fatal("invalid stale quota/group wallet", got)
		}
	}
}
