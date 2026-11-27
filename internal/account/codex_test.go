package account

import (
	"bufio"
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestCodexLimitsWalletAndWindows(t *testing.T) {
	p := Provider{ID: "codex", DisplayName: "Codex"}
	parse := func(raw string) (Snapshot, error) {
		var state codexState
		state.fetched = time.Now()
		if err := json.Unmarshal([]byte(raw), &state.limits); err != nil {
			t.Fatal(err)
		}
		return state.snapshot(p)
	}
	s, err := parse(`{"rateLimits":{"primary":{"usedPercent":60,"windowDurationMins":10080,"resetsAt":1782940713},"credits":{"balance":"-00012.3456789125","hasCredits":false}},"rateLimitsByLimitId":{"spark":{"limitName":"Spark","primary":{"usedPercent":"-1","windowDurationMins":300},"credits":{"balance":"999"}}},"rateLimitResetCredits":{"availableCount":3,"credits":[{"id":"secret-card","status":"available","expiresAt":1782940713},{"status":"consumed"}]}}`)
	if err != nil {
		t.Fatal(err)
	}
	if len(s.Groups) != 2 || s.Groups[0].ID != "codex" || s.Groups[0].Items[0].Label != "7d" || *s.Groups[0].Items[0].RemainingPercent != 40 || s.Groups[0].Items[0].ResetAt != "2026-07-01T21:18:33Z" {
		t.Fatalf("%+v", s.Groups)
	}
	if *s.Groups[1].Items[0].RemainingPercent != 100 || s.ResetCredits.AvailableCount != 3 || len(s.ResetCredits.Credits) != 1 {
		t.Fatal(s.Groups, s.ResetCredits)
	}
	raw, _ := json.Marshal(s)
	if strings.Contains(string(raw), "secret-card") || string(s.AccountCredits) != `{"codex":{"_0":{"amount":{"_0":-12.3456789125}}}}` {
		t.Fatal(string(s.AccountCredits))
	}
	for _, test := range []struct{ raw, kind string }{
		{`{"balance":"0","hasCredits":false}`, "amount"},
		{`{"balance":"9","unlimited":true}`, "unlimited"},
		{`{"balance":null,"hasCredits":true}`, "available"},
		{`{"hasCredits":false}`, "noCredits"},
	} {
		s, err = parse(`{"rateLimits":{"credits":` + test.raw + `}}`)
		if err != nil || !strings.Contains(string(s.AccountCredits), test.kind) {
			t.Fatal(s, err)
		}
	}
	if _, err = parse(`{"rateLimitsByLimitId":{"spark":{"credits":{"balance":"999"}}}}`); err == nil {
		t.Fatal("model wallet leaked into account balance")
	}
	if _, err = parse(`{"rateLimits":{"credits":{"balance":"12abc"}}}`); err == nil {
		t.Fatal("invalid amount")
	}
	for n, want := range map[int]string{0: "额度", 90: "90m", 300: "5h", 1440: "1d", 10080: "7d"} {
		if got := codexLabel(n); got != want {
			t.Errorf("%d: %s", n, got)
		}
	}
}

func TestCodexFixtureProcess(t *testing.T) {
	if !slices.Contains(os.Args, "--tokenmeter-fixture") {
		return
	}
	dir := os.Getenv("CODEX_HOME")
	mode, _ := os.ReadFile(filepath.Join(dir, "mode"))
	if idx := slices.Index(os.Args, "--out"); idx != -1 {
		props := map[string]any{"creditId": map[string]any{}, "idempotencyKey": map[string]any{}}
		if string(mode) == "unsupported" {
			delete(props, "creditId")
		}
		dir := filepath.Join(os.Args[idx+1], "v2")
		if os.MkdirAll(dir, 0700) != nil {
			os.Exit(3)
		}
		data, _ := json.Marshal(map[string]any{"properties": props})
		if os.WriteFile(filepath.Join(dir, "ConsumeAccountRateLimitResetCreditParams.json"), data, 0600) != nil {
			os.Exit(3)
		}
		os.Exit(0)
	}
	writer := json.NewEncoder(os.Stdout)
	scan := bufio.NewScanner(os.Stdin)
	for scan.Scan() {
		var req struct {
			ID     int
			Method string
			Params map[string]any
		}
		if json.Unmarshal(scan.Bytes(), &req) != nil {
			os.Exit(4)
		}
		var result any
		switch req.Method {
		case "initialize":
			result = map[string]any{}
		case "initialized":
			continue
		case "account/read":
			if v, ok := req.Params["refreshToken"].(bool); !ok || v {
				os.Exit(4)
			}
			result = map[string]any{"account": map[string]string{"type": "chatgpt"}}
		case "account/rateLimits/read":
			credits := []map[string]any{}
			n := 1
			if string(mode) == "large" {
				n = 4096
			}
			for i := range n {
				exp := time.Now().Unix() + 1800
				if string(mode) == "expired" {
					exp = time.Now().Unix() - 1
				}
				credits = append(credits, map[string]any{"id": fmt.Sprintf("test-credit-%d", i), "resetType": "codexRateLimits", "status": "available", "expiresAt": exp})
			}
			if string(mode) == "slow" {
				os.WriteFile(filepath.Join(dir, "waiting"), nil, 0600)
				time.Sleep(15 * time.Second)
			}
			result = map[string]any{"rateLimits": map[string]any{"credits": map[string]any{"balance": "13"}}, "rateLimitResetCredits": map[string]any{"availableCount": n, "credits": credits}}
		case "account/rateLimitResetCredit/consume":
			f, err := os.OpenFile(filepath.Join(dir, "consumed"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0600)
			if err != nil {
				os.Exit(4)
			}
			_ = json.NewEncoder(f).Encode(req.Params)
			f.Close()
			result = map[string]string{"outcome": "reset"}
		default:
			os.Exit(5)
		}
		_ = writer.Encode(map[string]any{"id": req.ID, "result": result})
	}
	os.Exit(0)
}
func TestCodexProtocolWithoutNode(t *testing.T) {
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	h := t.TempDir()
	segment := base64.RawURLEncoding.EncodeToString([]byte(`{"sub":"test-user"}`))
	if err = os.WriteFile(filepath.Join(h, "auth.json"), []byte(`{"tokens":{"account_id":"test-account","id_token":"a.`+segment+`.b"}}`), 0600); err != nil {
		t.Fatal(err)
	}
	p := codexProgram{binary: exe, prefix: []string{"-test.run=^TestCodexFixtureProcess$", "--", "--tokenmeter-fixture"}, home: h}
	setMode := func(mode string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(h, "mode"), []byte(mode), 0600); err != nil {
			t.Fatal(err)
		}
	}
	setMode("large")
	state, err := p.read(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	if state.identity == "" || len(state.limits.ResetCredits.Credits) != 4096 {
		t.Fatal("truncated state")
	}
	enabled := func() bool { return true }
	snapshot, err := state.snapshot(Provider{ID: "codex", DisplayName: "Codex"})
	if err != nil || len(snapshot.ResetCredits.Credits) != 4096 {
		t.Fatal(err)
	}
	setMode("unsupported")
	if _, err := p.consume(t.Context(), state.identity, "test-credit-0", "fixture-key", enabled); !errors.Is(err, errCodexSchema) {
		t.Fatal(err)
	}
	setMode("expired")
	if _, err := p.consume(t.Context(), state.identity, "test-credit-0", "fixture-key", enabled); !errors.Is(err, errCodexIneligible) {
		t.Fatal(err)
	}
	setMode("")
	if _, err := p.consume(t.Context(), "wrong-account", "test-credit-0", "fixture-key", enabled); !errors.Is(err, errCodexChanged) {
		t.Fatal(err)
	}
	if _, err := p.consume(t.Context(), state.identity, "test-credit-0", "fixture-key", func() bool { return false }); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(h, "consumed")); !os.IsNotExist(err) {
		t.Fatal("unexpected redemption")
	}
	if result, err := p.consume(t.Context(), state.identity, "test-credit-0", "fixture-key", enabled); result != "reset" || err != nil {
		t.Fatal(result, err)
	}
	received, err := os.ReadFile(filepath.Join(h, "consumed"))
	if err != nil || string(received) != "{\"creditId\":\"test-credit-0\",\"idempotencyKey\":\"fixture-key\"}\n" {
		t.Fatal(string(received), err)
	}
	setMode("slow")
	ctx, cancel := context.WithTimeout(t.Context(), 150*time.Millisecond)
	defer cancel()
	if _, err := p.read(ctx); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatal(err)
	}
}

type resetFixture struct {
	state     codexState
	outcome   string
	err       error
	keys      []string
	ids       []string
	afterRead func()
	reads     int
}

func (r *resetFixture) read(context.Context) (codexState, error) {
	r.reads++
	if r.afterRead != nil {
		r.afterRead()
	}
	return r.state, nil
}
func (r *resetFixture) consume(_ context.Context, _, id, key string, _ func() bool) (string, error) {
	r.keys = append(r.keys, key)
	r.ids = append(r.ids, id)
	return r.outcome, r.err
}
func resetFixtureDB(t *testing.T) *sql.DB {
	t.Helper()
	db, err := sql.Open("sqlite", sqliteFile(filepath.Join(t.TempDir(), "journal.sqlite"))+"?_txlock=immediate&_pragma=busy_timeout(4000)")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	_, err = db.Exec(`CREATE TABLE codex_reset_redemptions(account_hash TEXT,credit_hash TEXT,idempotency_key TEXT,state TEXT,quota_hash TEXT,owner TEXT,lease_until REAL,updated_at REAL,PRIMARY KEY(account_hash,credit_hash))`)
	if err != nil {
		t.Fatal(err)
	}
	return db
}
func TestCodexResetJournalAndEligibility(t *testing.T) {
	allowed := true
	enabled := func() bool { return allowed }
	now := time.Unix(1_800_000_000, 0)
	clock := func() time.Time { return now }
	fixture := func(seconds float64) *resetFixture {
		n := 2
		return &resetFixture{state: codexState{identity: "account", fetched: now, limits: codexAccountLimits{RateLimits: json.RawMessage(`{"primary":{"usedPercent":75}}`), ResetCredits: &codexCreditList{AvailableCount: &n, Credits: []codexCredit{
			{ID: "later", ResetType: "codexRateLimits", Status: "available", ExpiresAt: float64(now.Unix()) + 86400},
			{ID: "actual-card", ResetType: "codexRateLimits", Status: "available", ExpiresAt: float64(now.Unix()) + seconds},
		}}}}, outcome: "reset"}
	}
	for _, seconds := range []float64{3601, 3600, 1, 0, -1} {
		r := fixture(seconds)
		result, err := runCodexReset(t.Context(), resetFixtureDB(t), r, enabled, clock)
		if err != nil || result.Consumed != (seconds > 0 && seconds <= 3600) {
			t.Fatal(seconds, result, err)
		}
		if result.Consumed && !slices.Equal(r.ids, []string{"actual-card"}) {
			t.Fatal(r.ids)
		}
	}
	db := resetFixtureDB(t)
	r := fixture(3000)
	allowed = false
	if _, err := runCodexReset(t.Context(), db, r, enabled, clock); err != nil || r.reads != 0 {
		t.Fatal(err)
	}
	allowed = true
	r.afterRead = func() { allowed = false }
	runCodexReset(t.Context(), db, r, enabled, clock)
	if len(r.keys) != 0 {
		t.Fatal("permission changed")
	}
	allowed = true
	r.afterRead = nil
	r.outcome = ""
	r.err = errCodexTimeout
	result, err := runCodexReset(t.Context(), db, r, enabled, clock)
	if err == nil || result.Status != "uncertain" || len(r.keys) != 1 {
		t.Fatal(result, err)
	}
	now = now.Add(121 * time.Second)
	r.state.fetched = now
	r.err = nil
	r.outcome = "alreadyRedeemed"
	if out, err := runCodexReset(t.Context(), db, r, enabled, clock); err != nil || !out.Consumed || len(r.keys) != 2 || r.keys[0] != r.keys[1] {
		t.Fatal(out, r.keys, err)
	}
	now = now.Add(121 * time.Second)
	r.state.fetched = now
	runCodexReset(t.Context(), db, r, enabled, clock)
	if len(r.keys) != 2 {
		t.Fatal("double consumption")
	}
	var hash string
	db.QueryRow("SELECT credit_hash FROM codex_reset_redemptions").Scan(&hash)
	if hash == "" || hash == "actual-card" {
		t.Fatal("raw ID in journal")
	}
	r.state.limits.ResetCredits.Credits = []codexCredit{}
	if out, err := runCodexReset(t.Context(), db, r, enabled, clock); err != nil || out.Status != "succeeded" || out.Consumed {
		t.Fatal("lost the last confirmed redemption", out, err)
	}
	db = resetFixtureDB(t)
	r = fixture(3000)
	r.outcome = "nothingToReset"
	runCodexReset(t.Context(), db, r, enabled, clock)
	now = now.Add(121 * time.Second)
	r.state.fetched = now
	runCodexReset(t.Context(), db, r, enabled, clock)
	if len(r.keys) != 1 {
		t.Fatal("nothingToReset retried unchanged quota")
	}
	r.state.limits.RateLimits = json.RawMessage(`{"primary":{"usedPercent":90}}`)
	runCodexReset(t.Context(), db, r, enabled, clock)
	if len(r.keys) != 2 || r.keys[0] == r.keys[1] {
		t.Fatal("changed quota not retried")
	}
	for i := 0; i < 4; i++ {
		r = fixture(3000)
		switch i {
		case 0:
			r.state.identity = ""
		case 1:
			r.state.fetched = now.Add(-61 * time.Second)
		case 2:
			r.state.limits.ResetCredits.Credits = nil
		case 3:
			r.state.limits.ResetCredits.Credits[1].ResetType = "unrelated"
		}
		runCodexReset(t.Context(), db, r, enabled, clock)
		if len(r.keys) != 0 {
			t.Fatal(i)
		}
	}
}
func TestCodexConcurrentLease(t *testing.T) {
	db := resetFixtureDB(t)
	now := time.Now()
	var accepted atomic.Int32
	var group sync.WaitGroup
	for range 5 {
		group.Go(func() {
			c, err := claimCodex(t.Context(), db, "user", "card", "quota", now)
			if err != nil {
				t.Error(err)
				return
			}
			if c != nil {
				accepted.Add(1)
			}
		})
	}
	group.Wait()
	if accepted.Load() != 1 {
		t.Fatal(accepted.Load())
	}
	c, err := claimCodex(t.Context(), db, "user", "card", "quota", now.Add(121*time.Second))
	if c == nil || err != nil {
		t.Fatal(err)
	}
}

func TestCodexResetRespectsDesktopSettings(t *testing.T) {
	h := t.TempDir()
	check := func(want string, predicate ...func() bool) {
		t.Helper()
		result, err := CheckCodexReset(t.Context(), h, predicate...)
		if err != nil || result.Status != want || result.Consumed {
			t.Fatal(result, err)
		}
	}
	check("disabled")
	base := filepath.Join(h, ".token-meter")
	if err := os.MkdirAll(filepath.Join(base, "node"), 0700); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", sqliteFile(filepath.Join(base, "tokenmeter.sqlite")))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err = db.Exec("CREATE TABLE settings(key TEXT,value_json TEXT); CREATE TABLE provider_config_overrides(provider_id TEXT,enabled INTEGER)"); err != nil {
		t.Fatal(err)
	}
	check("disabled")
	if _, err = db.Exec("INSERT INTO settings VALUES('codex.resetCredits.autoRedeemEnabled','1'); INSERT INTO provider_config_overrides VALUES('codex',0)"); err != nil {
		t.Fatal(err)
	}
	check("paused")
	if _, err = db.Exec("UPDATE provider_config_overrides SET enabled=1"); err != nil {
		t.Fatal(err)
	}
	check("paused", func() bool { return false })
	if err = os.WriteFile(filepath.Join(base, "node", "index-paused"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	check("paused")
}
