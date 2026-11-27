package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

const rolloutThread = "019f8178-5e10-7000-8000-000000000001"
const rolloutTurn = "019f8178-5e11-7000-8000-000000000002"

func rolloutPath(t *testing.T, dir string) string {
	t.Helper()
	return filepath.Join(t.TempDir(), "state", "agents", "main", "agent", "codex-home", dir, "2026", "11", "25", "rollout-2026-11-25T00-00-00-"+rolloutThread+".jsonl")
}
func rolloutJSON(kind, stamp string, payload map[string]any) string {
	raw, err := json.Marshal(map[string]any{"type": kind, "timestamp": stamp, "payload": payload})
	if err != nil {
		panic(err)
	}
	return string(raw)
}
func rolloutMeta(id, origin string) string {
	return rolloutJSON("session_meta", "", map[string]any{"id": id, "originator": origin})
}
func rolloutContext(turn, model string) string {
	return rolloutJSON("turn_context", "", map[string]any{"turn_id": turn, "model": model})
}
func rolloutTask(kind, turn string) string {
	return rolloutJSON("event_msg", "", map[string]any{"type": kind, "turn_id": turn})
}
func rolloutAmounts(input, cache, written, output, reasoning int) map[string]any {
	return map[string]any{"input_tokens": input, "cached_input_tokens": cache, "cache_write_input_tokens": written, "output_tokens": output, "reasoning_output_tokens": reasoning, "total_tokens": input + output}
}
func rolloutCall(at, turn, response string, usage, turnUsage, threadUsage map[string]any) string {
	return rolloutJSON("token_usage_record", at, map[string]any{"thread_id": rolloutThread, "turn_id": turn, "response_id": response, "usage": usage, "turn_token_usage": turnUsage, "thread_token_usage": threadUsage})
}
func rolloutSnapshot(at string, last, total map[string]any) string {
	return rolloutJSON("event_msg", at, map[string]any{"type": "token_count", "info": map[string]any{"last_token_usage": last, "total_token_usage": total}})
}
func readTestRollout(t *testing.T, prices catalog, path string, lines ...string) []clawCodexCall {
	t.Helper()
	writeTestFile(t, path, []byte(strings.Join(lines, "\n")+"\n"))
	var out []clawCodexCall
	check(t, prices.clawCodexRollout(path, func(call clawCodexCall) error { out = append(out, call); return nil }))
	return out
}

func TestLinuxCodexScanReadsStandaloneAndDeduplicatesArchive(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("standalone Codex uses the Linux CLI collector")
	}
	s := testStore(t)
	name := "rollout-2026-11-25T00-00-00-" + rolloutThread + ".jsonl"
	at := "2026-11-25T01:02:51Z"
	usage := rolloutAmounts(100, 20, 0, 10, 2)
	lines := []string{
		rolloutMeta(rolloutThread, "T3 Code"),
		rolloutTask("task_started", rolloutTurn),
		rolloutContext(rolloutTurn, "model-a"),
		rolloutCall(at, rolloutTurn, "response-a", usage, usage, usage),
		rolloutSnapshot(at, usage, usage),
	}
	for _, dir := range []string{"sessions", "archived_sessions"} {
		writeTestFile(t, filepath.Join(s.home, ".codex", dir, name), []byte(strings.Join(lines, "\n")+"\n"))
	}
	check(t, s.scan())
	report, err := s.report("local", "", "")
	check(t, err)
	if report.Tokens != 110 || len(report.Agents) != 1 || report.Agents[0].Events != 1 {
		t.Fatalf("standalone Codex usage: %+v", report)
	}
}

func TestClawCodexExplicitPerRequestAndLegacyMirror(t *testing.T) {
	one, two := 1.0, 2.0
	prices := catalog{Models: map[string]price{"model-a": {rate: rate{InputPerMTok: &one, OutputPerMTok: &two, CacheReadPerMTok: &one, CacheWrite5mPerMTok: &two}}}}
	path := rolloutPath(t, "sessions")
	t1 := time.Date(2026, 11, 24, 23, 59, 59, 0, time.Local)
	t2 := t1.Add(2 * time.Second)
	a, b, ab := rolloutAmounts(100, 20, 5, 10, 2), rolloutAmounts(60, 10, 3, 5, 1), rolloutAmounts(160, 30, 8, 15, 3)
	first := rolloutCall(t1.Format(time.RFC3339), rolloutTurn, "resp-A", a, a, a)
	second := rolloutCall(t2.Format(time.RFC3339), rolloutTurn, "resp-B", b, ab, ab)
	lines := []string{rolloutMeta(rolloutThread, "openclaw"), rolloutTask("task_started", rolloutTurn), rolloutContext(rolloutTurn, "model-a"), first, rolloutSnapshot(t1.Format(time.RFC3339), a, a),
		rolloutContext(rolloutTurn, "model-b"), second, rolloutSnapshot(t2.Format(time.RFC3339), b, ab), rolloutTask("task_complete", rolloutTurn),
		first, rolloutSnapshot(t1.Format(time.RFC3339), a, a)}
	out := readTestRollout(t, prices, path, lines...)
	if len(out) != 2 {
		t.Fatalf("got %+v", out)
	}
	wantFirst := Counts{Input: 75, CacheRead: 20, CacheWrite: 5, Output: 10}
	wantTotal := Counts{Input: 122, CacheRead: 30, CacheWrite: 8, Output: 15}
	if out[0].id != digest("openclaw", "openai", "resp-A") || out[0].response != "resp-A" || out[0].rolloutID == "" || out[0].thread != rolloutThread || out[0].turn != rolloutTurn || out[0].cumulative != wantFirst || !out[0].complete || out[0].tokens() != 110 || out[0].CostMicros != 125 || out[0].Events != 1 || out[0].day != t1.Format(time.DateOnly) {
		t.Fatalf("%+v", out[0])
	}
	if out[1].id != digest("openclaw", "openai", "resp-B") || out[1].model != "model-b" || out[1].rolloutID == out[0].rolloutID || out[1].cumulative != wantTotal || !out[1].complete || out[1].tokens() != 65 || out[1].UnknownCost != 1 || out[1].day != t2.Format(time.DateOnly) {
		t.Fatalf("%+v", out[1])
	}
	// The archived legacy copy has a different timestamp and no response ID.
	legacy := readTestRollout(t, prices, rolloutPath(t, "archived_sessions"), rolloutMeta(rolloutThread, ""), rolloutTask("task_started", rolloutTurn), rolloutContext(rolloutTurn, "model-a"), rolloutSnapshot(t2.Format(time.RFC3339), a, a), rolloutContext(rolloutTurn, "model-b"), rolloutSnapshot(t2.Format(time.RFC3339), b, ab))
	if len(legacy) != 2 || legacy[0].id != out[0].rolloutID || legacy[1].id != out[1].rolloutID || !legacy[1].complete || legacy[1].cumulative != wantTotal {
		t.Fatalf("%+v", legacy)
	}
}

func TestClawCodexPartialSnapshotsAndTurnBoundaries(t *testing.T) {
	at := "2026-11-25T01:02:51Z"
	a, b, ab := rolloutAmounts(100, 20, 0, 10, 0), rolloutAmounts(60, 10, 0, 5, 0), rolloutAmounts(160, 30, 0, 15, 0)
	prev := rolloutAmounts(400, 100, 0, 30, 0)
	aprev := rolloutAmounts(500, 120, 0, 40, 0)
	abprev := rolloutAmounts(560, 130, 0, 45, 0)
	next := "019f8178-5e12-7000-8000-000000000003"
	out := readTestRollout(t, catalog{}, rolloutPath(t, "sessions"),
		rolloutMeta(rolloutThread, "openclaw"), rolloutContext("earlier", "m"), rolloutSnapshot(at, nil, prev),
		rolloutTask("task_aborted", "earlier"), rolloutTask("task_started", rolloutTurn), rolloutContext(rolloutTurn, "m"),
		rolloutSnapshot(at, a, aprev), rolloutSnapshot(at, nil, abprev), rolloutSnapshot(at, b, abprev), rolloutTask("task_complete", rolloutTurn),
		rolloutContext(next, "other"), rolloutCall(at, next, "only-middle", b, ab, nil), rolloutSnapshot(at, b, nil))
	if len(out) != 3 || out[0].tokens() != 110 || !out[0].complete || out[1].tokens() != 65 || !out[1].complete ||
		out[2].complete || out[2].tokens() != 65 || out[2].cumulative.tokens() != 175 || out[2].turn != next {
		t.Fatalf("%+v", out)
	}
}

func TestClawCodexSourceScopeForkAndPartialTail(t *testing.T) {
	at := "2026-11-25T01:02:51Z"
	parent := "019f54c2-0000-7000-8000-000000000001"
	parentTurn := "019f54c2-1000-7000-8000-000000000001"
	p := rolloutAmounts(100, 20, 0, 5, 0)
	child := rolloutAmounts(10, 2, 0, 1, 0)
	all := rolloutAmounts(110, 22, 0, 6, 0)
	meta := rolloutJSON("session_meta", at, map[string]any{"id": rolloutThread, "originator": "openclaw", "forked_from_id": parent})
	valid := []string{meta, rolloutMeta(parent, "codex_cli_rs"), rolloutTask("task_started", parentTurn), rolloutContext(parentTurn, "parent"), rolloutSnapshot(at, p, p),
		rolloutTask("task_started", rolloutTurn), rolloutContext(rolloutTurn, "child"), rolloutSnapshot(at, p, p), rolloutSnapshot(at, child, all), meta, rolloutSnapshot(at, child, all)}
	path := rolloutPath(t, "archived_sessions")
	out := readTestRollout(t, catalog{}, path, valid...)
	if len(out) != 1 || out[0].model != "child" || out[0].turn != rolloutTurn || out[0].tokens() != 11 || !out[0].complete {
		t.Fatalf("%+v", out)
	}
	if got := readTestRollout(t, catalog{}, path, append([]string{rolloutMeta(rolloutThread, "codex_cli_rs")}, valid[1:]...)...); len(got) != 0 {
		t.Fatal(got)
	}
	standalone := filepath.Join(t.TempDir(), ".codex", "sessions", "rollout-session.jsonl")
	if got := readTestRollout(t, catalog{}, standalone, valid...); len(got) != 0 {
		t.Fatal(got)
	}
	writeTestFile(t, path, []byte(strings.Join(valid, "\n")+"\n"+`{"timestamp":"2026`))
	var n int
	check(t, (catalog{}).clawCodexRollout(path, func(clawCodexCall) error { n++; return nil }))
	if n != 1 {
		t.Fatal(n)
	}
	f, e := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0600)
	check(t, e)
	_, e = fmt.Fprint(f, "broken\n")
	check(t, e)
	check(t, f.Close())
	if e := (catalog{}).clawCodexRollout(path, func(clawCodexCall) error { return nil }); e == nil {
		t.Fatal("completed malformed line accepted")
	}
}

func TestClawCodexResponseWithoutThreadCounterGetsStatusAlias(t *testing.T) {
	at := "2026-11-25T01:02:51Z"
	r := rolloutAmounts(100, 20, 0, 10, 2)
	sum := rolloutAmounts(870, 400, 0, 80, 20)
	path := rolloutPath(t, "sessions")
	out := readTestRollout(t, catalog{}, path, rolloutMeta(rolloutThread, "openclaw"), rolloutContext(rolloutTurn, "m"), rolloutCall(at, rolloutTurn, "resp-y", r, r, nil), rolloutSnapshot(at, r, sum), rolloutSnapshot(at, r, sum))
	legacy := readTestRollout(t, catalog{}, path, rolloutMeta(rolloutThread, ""), rolloutContext(rolloutTurn, "m"), rolloutSnapshot(at, r, sum))
	if len(out) != 1 || len(legacy) != 1 || out[0].response != "resp-y" || out[0].rolloutID != legacy[0].id || !out[0].complete || legacy[0].complete {
		t.Fatalf("explicit %+v legacy %+v", out, legacy)
	}
	stop := errors.New("stop consuming")
	if err := (catalog{}).clawCodexRollout(path, func(clawCodexCall) error { return stop }); !errors.Is(err, stop) {
		t.Fatal(err)
	}
}

func TestClawCodexResetsExplicitIdentityAndOldStatusOrdinal(t *testing.T) {
	path := rolloutPath(t, "sessions")
	at := "2026-11-25T01:02:51Z"
	r := rolloutAmounts(10, 4, 1, 3, 1)
	next := "019f8178-5e12-7000-8000-000000000003"
	body := []string{rolloutMeta(rolloutThread, "openclaw"), rolloutContext(rolloutTurn, "m"), rolloutCall(at, rolloutTurn, "resp-1", r, r, r),
		rolloutTask("turn_aborted", rolloutTurn), rolloutTask("task_started", next), rolloutContext(next, "m"), rolloutCall(at, next, "resp-2", r, r, r), rolloutCall(at, next, "resp-2", r, r, r),
		rolloutJSON("event_msg", at, map[string]any{"type": "arbitrary_tool_status", "usage": "not a metering object", "id": 64})}
	out := readTestRollout(t, catalog{}, path, body...)
	if len(out) != 2 || out[0].response == out[1].response || out[1].rolloutID != "" || !out[1].complete || out[1].cumulative.tokens() != 13 {
		t.Fatalf("%+v", out)
	}
	weak := rolloutSnapshot(at, r, nil)
	withOrdinal := func(i int) string { return fmt.Sprintf(`{"ordinal":%d,%s`, i, weak[1:]) }
	out = readTestRollout(t, catalog{}, path, rolloutMeta(rolloutThread, ""), rolloutContext(rolloutTurn, "m"), withOrdinal(1), withOrdinal(2), withOrdinal(1))
	if len(out) != 2 || out[0].id == out[1].id || out[0].complete {
		t.Fatalf("%+v", out)
	}
}

func TestClawCodexReversedStatusAliasAndInheritedOldSnapshot(t *testing.T) {
	at := "2026-11-25T01:02:51Z"
	r := rolloutAmounts(90, 10, 0, 8, 1)
	before := rolloutAmounts(400, 20, 0, 20, 4)
	full := rolloutAmounts(490, 30, 0, 28, 5)
	path := rolloutPath(t, "sessions")
	out := readTestRollout(t, catalog{}, path, rolloutMeta(rolloutThread, "openclaw"), rolloutContext(rolloutTurn, "m"), rolloutSnapshot(at, r, full), rolloutCall(at, rolloutTurn, "resp-1", r, r, full))
	if len(out) != 1 || out[0].response != "resp-1" || !out[0].complete || out[0].cumulative.tokens() != 98 {
		t.Fatalf("%+v", out)
	}
	parent := "019f54c2-0000-7000-8000-000000000001"
	ancestor := "019f54c2-1000-7000-8000-000000000001"
	child := rolloutJSON("session_meta", at, map[string]any{"id": rolloutThread, "forked_from_id": parent})
	out = readTestRollout(t, catalog{}, path, child, rolloutMeta(parent, ""), rolloutContext(ancestor, "old"), rolloutSnapshot(at, r, before), rolloutTask("task_started", rolloutTurn), rolloutContext(rolloutTurn, "m"), rolloutSnapshot(at, r, r), rolloutSnapshot(at, r, full))
	if len(out) != 1 || out[0].tokens() != 98 || !out[0].complete {
		t.Fatalf("%+v", out)
	}
}

func TestClawCodexOldUnseenStaleFrameAndUnscopedLegacy(t *testing.T) {
	at := "2026-11-25T01:02:51Z"
	prev := rolloutAmounts(400, 100, 0, 30, 0)
	latest := rolloutAmounts(500, 120, 0, 40, 0)
	first := rolloutAmounts(100, 20, 0, 10, 0)
	stale := rolloutAmounts(460, 110, 0, 35, 0)
	last := rolloutAmounts(60, 10, 0, 5, 0)
	final := rolloutAmounts(560, 130, 0, 45, 0)
	path := rolloutPath(t, "sessions")
	out := readTestRollout(t, catalog{}, path, rolloutMeta(rolloutThread, ""), rolloutSnapshot(at, nil, prev),
		rolloutTask("item_completed", rolloutTurn), rolloutContext(rolloutTurn, "m"), rolloutSnapshot(at, first, latest),
		rolloutSnapshot(at, last, stale), rolloutSnapshot(at, last, final))
	if len(out) != 2 || out[0].turn != rolloutTurn || out[0].complete || out[1].complete || out[1].cumulative.tokens() != 175 {
		t.Fatalf("%+v", out)
	}
}

func TestClawCodexInvalidAndOverflowingUsage(t *testing.T) {
	path := rolloutPath(t, "sessions")
	at := "2026-11-25T01:02:51Z"
	for _, usage := range []map[string]any{{"input_tokens": 10, "cached_input_tokens": 8, "cache_write_input_tokens": 3}, {"input_tokens": int64(1<<63 - 1), "output_tokens": 1}, {"output_tokens": -1}} {
		writeTestFile(t, path, []byte(rolloutMeta(rolloutThread, "openclaw")+"\n"+rolloutCall(at, rolloutTurn, "bad", usage, nil, nil)+"\n"))
		if err := (catalog{}).clawCodexRollout(path, func(clawCodexCall) error { t.Fatal("invalid call emitted"); return nil }); err == nil {
			t.Fatal("accepted invalid usage", usage)
		}
	}
}

func TestClawCodexRepeatedThreadCountersRequireProvenReset(t *testing.T) {
	next := "019f8178-5e12-7000-8000-000000000003"
	path := rolloutPath(t, "sessions")
	frame := func(turn string, quantity, ordinal int) string {
		v := rolloutAmounts(quantity, 0, 0, 0, 0)
		row := rolloutJSON("event_msg", "2026-11-25T01:02:51Z", map[string]any{"type": "token_count", "turn_id": turn, "info": map[string]any{"last_token_usage": v, "total_token_usage": v}})
		return fmt.Sprintf(`{"ordinal":%d,%s`, ordinal, row[1:])
	}
	start := []string{rolloutMeta(rolloutThread, "openclaw"), rolloutTask("task_started", rolloutTurn), rolloutContext(rolloutTurn, "m"), frame(rolloutTurn, 12, 10), rolloutTask("task_complete", rolloutTurn), rolloutTask("task_started", next), rolloutContext(next, "m")}
	projected := readTestRollout(t, catalog{}, path, append(start, frame(next, 12, 21))...)
	if len(projected) != 1 {
		t.Fatalf("cross-turn duplicate charged: %+v", projected)
	}
	reset := readTestRollout(t, catalog{}, path, append(start, frame(next, 0, 20), frame(next, 12, 21), frame(next, 12, 22), frame(rolloutTurn, 12, 10))...)
	if len(reset) != 2 || reset[1].tokens() != 12 || !reset[1].complete || reset[1].turn != next || reset[1].id == reset[0].id || reset[0].id != projected[0].id {
		t.Fatalf("%+v", reset)
	}
}

func TestClawCodexLateResponseAliasKeepsNewestBaselineAndActualUsage(t *testing.T) {
	at := "2026-11-25T01:02:51Z"
	a, b := rolloutAmounts(10, 0, 0, 0, 0), rolloutAmounts(20, 0, 0, 0, 0)
	ab, abc := rolloutAmounts(30, 0, 0, 0, 0), rolloutAmounts(32, 0, 0, 0, 0)
	path := rolloutPath(t, "sessions")
	out := readTestRollout(t, catalog{}, path, rolloutMeta(rolloutThread, "openclaw"), rolloutContext(rolloutTurn, "m"),
		rolloutCall(at, rolloutTurn, "A", a, a, nil), rolloutCall(at, rolloutTurn, "B", b, ab, ab), rolloutCall(at, rolloutTurn, "A", a, a, a), rolloutSnapshot(at, nil, abc))
	if len(out) != 3 || out[2].tokens() != 2 || out[2].cumulative.tokens() != 32 || !out[2].complete {
		t.Fatalf("%+v", out)
	}

	weak := rolloutAmounts(7, 0, 0, 0, 0)
	out = readTestRollout(t, catalog{}, path, rolloutMeta(rolloutThread, "openclaw"), rolloutContext(rolloutTurn, "m"),
		rolloutSnapshot(at, weak, a), rolloutCall(at, rolloutTurn, "B", b, ab, ab), rolloutCall(at, rolloutTurn, "A", a, a, a), rolloutSnapshot(at, nil, abc))
	if len(out) != 3 || out[0].tokens() != 10 || !out[0].complete || !out[1].complete || out[2].tokens() != 2 || out[2].cumulative.tokens() != 32 || !out[2].complete {
		t.Fatalf("%+v", out)
	}
}
