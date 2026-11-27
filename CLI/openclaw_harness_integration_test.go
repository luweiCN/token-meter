package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const (
	harnessThread = "019b8080-d400-7000-8000-000000000001"
	harnessTime   = "2026-01-02T08:00:00Z"
)

func harnessTurn(i int) string { return fmt.Sprintf("019b8080-d401-7000-8000-%012d", i+2) }

func harnessStore(t *testing.T) (*Store, string, string) {
	t.Helper()
	s := testStore(t)
	root := filepath.Join(s.home, ".openclaw", "agents", "main")
	path := filepath.Join(root, "agent", "codex-home", "sessions", "2026", "01", "02", "rollout-2026-01-02T08-00-00-"+harnessThread+".jsonl")
	// The two small requests together exceed the long-context threshold.
	// Pricing their combined usage would disagree with the provider's per-request rate.
	writeTestFile(t, filepath.Join(s.home, ".token-meter", "cache", "litellm-pricing-v2.json"), []byte(`{
		"schemaVersion":2, "models":{"test":{"inputPerMTok":2,"outputPerMTok":11,"cacheReadPerMTok":3,
		"longContext":[{"thresholdTokens":60,"rate":{"inputPerMTok":20,"outputPerMTok":110,"cacheReadPerMTok":30}}]}}}`))
	return s, root, path
}

func harnessProjections(t *testing.T, root string, usage Counts) {
	t.Helper()
	path := filepath.Join(root, "agent", "openclaw-agent.sqlite")
	check(t, os.MkdirAll(filepath.Dir(path), 0700))
	db, err := sql.Open("sqlite", sqlitePath(path))
	check(t, err)
	defer db.Close()
	_, err = db.Exec(`CREATE TABLE transcript_events(session_id TEXT,seq INTEGER,event_json TEXT,created_at INTEGER);
		CREATE TABLE trajectory_runtime_events(session_id TEXT,seq INTEGER,run_id TEXT,event_json TEXT,created_at INTEGER)`)
	check(t, err)
	meter := fmt.Sprintf(`"input":%d,"output":%d,"cacheRead":%d,"cacheWrite":%d`, usage.Input, usage.Output, usage.CacheRead, usage.CacheWrite)
	reportedCost := ""
	if usage.CostMicros > 0 {
		reportedCost = fmt.Sprintf(`,"cost":{"total":%.6f}`, float64(usage.CostMicros)/1e6)
	}
	mirror := fmt.Sprintf(`{"type":"message","id":"m","timestamp":%q,"message":{"role":"assistant","model":"test",
		"provider":"openai","api":"codex-app-server","stopReason":"stop","idempotencyKey":"codex-app-server:%s:%s:assistant",
		"__openclaw":{"runId":"run","mirrorOrigin":"codex-app-server","runTerminal":true},"usage":{%s,"totalTokens":%d%s}}}`,
		harnessTime, harnessThread, harnessTurn(0), meter, usage.tokens(), reportedCost)
	trace := fmt.Sprintf(`{"type":"model.completed","ts":%q,"modelId":"test","runId":"run",
		"data":{"threadId":%q,"turnId":%q,"usage":{%s,"total":%d}}}`, harnessTime, harnessThread, harnessTurn(0), meter, usage.tokens())
	_, err = db.Exec("INSERT INTO transcript_events VALUES ('session',1,?,0)", mirror)
	check(t, err)
	_, err = db.Exec("INSERT INTO trajectory_runtime_events VALUES ('session',1,'run',?,0)", trace)
	check(t, err)
}

func harnessRollout(started bool, turns ...[]Counts) []byte {
	var log strings.Builder
	write := func(kind, payload string) {
		fmt.Fprintf(&log, "{\"type\":%q,\"timestamp\":%q,\"payload\":%s}\n", kind, harnessTime, payload)
	}
	write("session_meta", fmt.Sprintf(`{"id":%q,"originator":"openclaw"}`, harnessThread))
	usageJSON := func(v Counts) string {
		return fmt.Sprintf(`{"input_tokens":%d,"cached_input_tokens":%d,"output_tokens":%d,"total_tokens":%d}`,
			v.Input+v.CacheRead, v.CacheRead, v.Output, v.tokens())
	}
	var total Counts
	for i, calls := range turns {
		turn := harnessTurn(i)
		if started {
			write("event_msg", fmt.Sprintf(`{"type":"task_started","turn_id":%q}`, turn))
		}
		write("turn_context", fmt.Sprintf(`{"turn_id":%q,"model":"test"}`, turn))
		for _, call := range calls {
			total.add(call)
			row := fmt.Sprintf(`{"type":"token_count","info":{"total_token_usage":%s,"last_token_usage":%s}}`, usageJSON(total), usageJSON(call))
			write("event_msg", row)
			write("event_msg", row) // Repeated status snapshots have the same cumulative counters.
		}
	}
	return []byte(log.String())
}

func assertHarnessReport(t *testing.T, host *Store, origin string, want Counts) {
	t.Helper()
	r, err := host.report(origin, "", "")
	check(t, err)
	if r.Tokens != want.tokens() || r.CostMicros != want.CostMicros || len(r.Devices) != 1 ||
		r.Devices[0].PartialSources != 0 || r.Devices[0].Counts != want || len(r.Agents) != 1 ||
		r.Agents[0].Agent != "openclaw" || r.Agents[0].Model != "test" || r.Agents[0].Counts != want {
		t.Fatalf("want %+v, got %+v", want, r)
	}
}

func TestOpenClawHarnessPartialThenFallbackThenComplete(t *testing.T) {
	s, root, rollout := harnessStore(t)
	first := Counts{Input: 10, Output: 2, CacheRead: 5}
	last := Counts{Input: 20, Output: 1, CacheRead: 40, CostMicros: 313}
	writeTestFile(t, filepath.Join(root, "sessions", "old.jsonl"), []byte(record+"\n"))
	writeTestFile(t, rollout, harnessRollout(false, []Counts{first}))
	check(t, s.scan())
	assertHarnessReport(t, s, "local", Counts{Input: 14, Output: 5, CacheRead: 10, CacheWrite: 1, Events: 2, CostMicros: 12057})

	harnessProjections(t, root, last)
	check(t, s.scan())
	assertHarnessReport(t, s, "local", Counts{Input: 24, Output: 4, CacheRead: 45, CacheWrite: 1, Events: 2, CostMicros: 12313})

	writeTestFile(t, rollout, harnessRollout(true, []Counts{first, last}))
	full := Counts{Input: 34, Output: 6, CacheRead: 50, CacheWrite: 1, Events: 3, CostMicros: 12370}
	check(t, s.scan())
	assertHarnessReport(t, s, "local", full)
	archived := filepath.Join(root, "agent", "codex-home", "archived_sessions", filepath.Base(rollout))
	check(t, os.MkdirAll(filepath.Dir(archived), 0700))
	check(t, os.Rename(rollout, archived))
	check(t, s.scan())
	assertHarnessReport(t, s, "local", full)
	check(t, os.Remove(archived))
	check(t, s.scan())
	assertHarnessReport(t, s, "local", full)
}

func TestOpenClawHarnessLateRolloutReachesPairedReader(t *testing.T) {
	s, root, rollout := harnessStore(t)
	reader := testStore(t)
	check(t, reader.addPeer(s.id, "127.0.0.1:24593", "peer"))
	harnessProjections(t, root, Counts{})
	check(t, s.scan())
	empty, err := s.report("local", "", "")
	check(t, err)
	if empty.Tokens != 0 || empty.CostMicros != 0 {
		t.Fatalf("zero-usage terminal before the native file: %+v", empty)
	}
	db, err := sql.Open("sqlite", sqlitePath(filepath.Join(root, "agent", "openclaw-agent.sqlite")))
	check(t, err)
	_, err = db.Exec(`UPDATE trajectory_runtime_events SET event_json=json_set(event_json,'$.data.usage',
		json('{"input":7,"cacheRead":13,"output":2,"cacheWrite":0,"total":22}'))`)
	check(t, err)
	check(t, db.Close())
	check(t, s.scan())
	assertHarnessReport(t, s, "local", Counts{Input: 7, CacheRead: 13, Output: 2, Events: 1, CostMicros: 75})

	turns := make([][]Counts, 20)
	for i := range turns {
		turns[i] = []Counts{{Input: 7, CacheRead: 13, Output: 2}}
	}
	writeTestFile(t, rollout, harnessRollout(true, turns...))
	want := Counts{Input: 140, CacheRead: 260, Output: 40, Events: 20, CostMicros: 1500}
	for range 2 {
		check(t, s.scan())
		assertHarnessReport(t, s, "local", want)
		var body []byte
		check(t, s.db.QueryRow("SELECT body FROM replicas WHERE id=?", s.id).Scan(&body))
		var env Envelope
		check(t, json.Unmarshal(body, &env))
		check(t, reader.acceptFrom(context.Background(), s.id, s.id, 1, env))
		assertHarnessReport(t, reader, s.id, want)
	}
}
