package main

import (
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestMenuSummaryAggregatesCurrentReplicasByAgentAndModel(t *testing.T) {
	local, remote := testStore(t), testStore(t)
	check(t, local.addPeer(remote.id, "127.0.0.1:47732", "peer"))
	today := day(time.Now())
	check(t, local.publish([]Bucket{
		{Day: today, Agent: "shared", Model: "m", Counts: Counts{Input: 90, CacheRead: 10, CostMicros: 60, Credits: 300}},
		{Day: today, Agent: "local-only", Model: "m", Counts: Counts{Output: 2}},
		{Day: "2000-01-01", Agent: "yesterday", Model: "old", Counts: Counts{Input: 1_000}},
	}, nil, 0))
	copyReplica := func() Envelope {
		var raw []byte
		check(t, remote.db.QueryRow("SELECT body FROM replicas WHERE id=?", remote.id).Scan(&raw))
		var envelope Envelope
		check(t, json.Unmarshal(raw, &envelope))
		check(t, local.acceptFrom(t.Context(), remote.id, remote.id, 1, envelope))
		return envelope
	}
	check(t, remote.publish([]Bucket{{Day: today, Agent: "shared", Counts: Counts{Input: 999}}}, nil, 0))
	old := copyReplica()
	check(t, remote.publish([]Bucket{
		{Day: today, Agent: "shared", Model: "m", Counts: Counts{CacheRead: 30, CacheWrite: 10, UnknownCost: 1, Credits: 25}},
		{Day: today, Agent: "shared", Model: "other", Counts: Counts{Input: 10, Output: 3, CostMicros: 9}},
		{Day: today, Agent: "qoder-cli", Model: "qwen", Counts: Counts{UnknownTokens: 1, Events: 1, Credits: 120}},
		{Day: today, Agent: "remote-only", Model: "remote-model", Counts: Counts{Input: 2}},
		{Day: today, Agent: "openclaw", Model: "delivery-mirror", Counts: Counts{Events: 3}},
	}, nil, 0))
	current := copyReplica()
	check(t, local.acceptFrom(t.Context(), remote.id, remote.id, 1, old))
	check(t, local.acceptFrom(t.Context(), remote.id, remote.id, 1, current))
	check(t, local.writeReport())
	data, err := os.ReadFile(filepath.Join(local.dir, "summary.json"))
	check(t, err)
	var report menuSummary
	check(t, json.Unmarshal(data, &report))
	if len(report.Agents) != 4 || report.Agents[0].ID != "shared" {
		t.Fatalf("today's agents: %+v", report.Agents)
	}
	agents := map[string]*menuAgent{}
	for _, a := range report.Agents {
		agents[a.ID] = a
	}
	shared := agents["shared"]
	if shared.LocalOnly || shared.Tokens != 153 || shared.CostMicros != 69 || shared.UnknownCost != 1 ||
		shared.Input != 100 || shared.CacheRead != 40 || shared.CacheWrite != 10 || shared.Credits != 325 {
		t.Fatalf("merged totals: %+v", shared)
	}
	if !agents["local-only"].LocalOnly || agents["remote-only"].LocalOnly ||
		agents["qoder-cli"].UnknownTokens != 1 || agents["qoder-cli"].Credits != 120 {
		t.Fatalf("origin and per-agent credits: %+v", agents)
	}
	for _, d := range report.Devices {
		if d.Credits != 0 {
			t.Fatal("device totals mix currencies")
		}
	}
	wantModels := []menuModel{
		{Model: "m", menuUsage: menuUsage{Tokens: 142, HasCredits: true, Counts: Counts{Input: 90, Output: 2, CacheRead: 40, CacheWrite: 10, CostMicros: 60, UnknownCost: 1}}},
		{Model: "other", menuUsage: menuUsage{Tokens: 13, Counts: Counts{Input: 10, Output: 3, CostMicros: 9}}},
		{Model: "qwen", menuUsage: menuUsage{HasCredits: true, Counts: Counts{UnknownTokens: 1, Events: 1}}},
		{Model: "remote-model", menuUsage: menuUsage{Tokens: 2, Counts: Counts{Input: 2}}},
	}
	if len(report.Models) != len(wantModels) {
		t.Fatalf("today's models: %+v", report.Models)
	}
	for i, want := range wantModels {
		if got := report.Models[i]; got != want {
			t.Errorf("model %d: got %+v, want %+v", i, got, want)
		}
	}
	usage, err := local.report("", today, today)
	check(t, err)
	for _, row := range usage.Agents {
		if row.Model == "delivery-mirror" {
			t.Fatal("a signed transcript-only event appeared in device usage")
		}
	}
}

func TestOpenClawCollectorSkipsDeliveryMirror(t *testing.T) {
	record := `{"type":"message","id":"delivery","timestamp":"2026-11-26T08:00:00Z","message":{"role":"assistant","provider":"openclaw","model":"delivery-mirror","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"cost":{"total":0}}}}`
	check(t, (catalog{}).clawLines(strings.NewReader(record+"\n"), "session", func(row sample) error {
		t.Fatalf("indexed delivery mirror as model usage: %+v", row)
		return nil
	}))
}

func TestMenuSummaryIncludesReplicaHistoryThroughToday(t *testing.T) {
	const today = "2026-09-02"
	summary, err := dailyMenuSummary(today, "local", []Snapshot{
		{Origin: "local", Buckets: []Bucket{
			{Day: today, Agent: "codex", Model: "local-model", Counts: Counts{Input: 50, CacheRead: 10, CostMicros: 30, Events: 1}},
		}},
		{Origin: "remote", Buckets: []Bucket{
			{Day: "2025-12-31", Agent: "openclaw", Model: "old", Counts: Counts{Input: 800}},
			{Day: "2026-08-30", Agent: "openclaw", Model: "old", Counts: Counts{Input: 5}},
			{Day: "2026-08-31", Agent: "openclaw", Model: "old", Counts: Counts{Input: 10}},
			{Day: "2026-09-01", Agent: "openclaw", Model: "remote-model", Counts: Counts{Input: 40, Events: 1}},
			{Day: today, Agent: "openclaw", Model: "remote-model", Counts: Counts{Input: 25, CacheRead: 75, CostMicros: 50, UnknownCost: 1, UnknownTokens: 2, Events: 2}},
			{Day: "2026-09-03", Agent: "openclaw", Model: "next", Counts: Counts{Input: 500}},
		}},
	})
	check(t, err)
	data, err := json.Marshal(summary)
	check(t, err)
	var cached struct {
		History struct {
			Total, Month, Week struct{ Tokens int64 }
			Days               map[string]struct {
				Tokens             int64
				SessionsIncomplete bool
				Counts
				Models  []menuModel
				Devices map[string]menuUsage
			}
		}
	}
	check(t, json.Unmarshal(data, &cached))
	history := cached.History
	if history.Total.Tokens != 1515 || history.Month.Tokens != 200 || history.Week.Tokens != 210 {
		t.Fatalf("all-time, month, week: %+v", history)
	}
	if len(history.Days) != 2 {
		t.Fatalf("current-month heatmap through today: %+v", history.Days)
	}
	prior := history.Days["2026-09-01"]
	if prior.Tokens != 40 || len(prior.Models) != 1 || prior.Models[0].Model != "remote-model" {
		t.Fatalf("historical remote heatmap details: %+v", prior)
	}
	if len(prior.Devices) != 1 || prior.Devices["remote"].Tokens != 40 {
		t.Fatalf("historical device usage: %+v", prior.Devices)
	}
	daily := history.Days[today]
	if daily.Tokens != 160 || daily.CacheRead != 85 || daily.CostMicros != 80 || daily.UnknownCost != 1 ||
		daily.UnknownTokens != 2 || daily.Events != 3 || !daily.SessionsIncomplete {
		t.Fatalf("today's shared heatmap totals: %+v", daily)
	}
	if len(daily.Devices) != 2 || daily.Devices["local"].Tokens != 60 ||
		daily.Devices["remote"].Tokens != 100 || daily.Devices["remote"].UnknownCost != 1 {
		t.Fatalf("today's device usage: %+v", daily.Devices)
	}
}

func TestMenuSummaryRejectsOutOfRangeTotals(t *testing.T) {
	const today = "2026-06-12"
	for _, counts := range [][]Counts{
		{{Input: -1}}, {{CostMicros: -1}}, {{Input: math.MaxInt64, CacheRead: 1}},
		{{Input: math.MaxInt64}, {Output: 1}}, {{Credits: math.MaxInt64}, {Credits: 1}},
	} {
		var snaps []Snapshot
		for i, c := range counts {
			snaps = append(snaps, Snapshot{Origin: string(rune('a' + i)), Buckets: []Bucket{{Day: today, Agent: "one", Counts: c}}})
		}
		if _, err := dailyMenuSummary(today, "a", snaps); err == nil {
			t.Errorf("accepted inconsistent counts: %+v", counts)
		}
	}
}

func TestMenuHistoryRequiresUsageEvidence(t *testing.T) {
	const today = "2026-11-26"
	for _, tc := range []struct {
		name   string
		counts Counts
		listed bool
	}{
		{"only log events", Counts{Events: 40}, false},
		{"tokens", Counts{CacheRead: 500, Events: 1}, true},
		{"known cost", Counts{CostMicros: 100, Events: 1}, true},
		{"unreported tokens", Counts{UnknownTokens: 1, Events: 1}, true},
		{"unpriced usage", Counts{UnknownCost: 1, Events: 1}, true},
		{"credits", Counts{Credits: 120, Events: 1}, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			snapshot := Snapshot{Origin: "remote", Buckets: []Bucket{
				{Day: today, Agent: "openclaw", Model: "model", Counts: tc.counts},
			}}
			summary, err := dailyMenuSummary(today, "local", []Snapshot{snapshot})
			check(t, err)
			daily := summary.History.Days[today]
			if (len(summary.Models) > 0) != tc.listed || (len(daily.Models) > 0) != tc.listed {
				t.Fatalf("today models %+v and heatmap models %+v, expected listed=%t", summary.Models, daily.Models, tc.listed)
			}
			device, listed := daily.Devices[snapshot.Origin]
			if listed != tc.listed {
				t.Fatalf("heatmap devices %+v, expected listed=%t", daily.Devices, tc.listed)
			}
			if listed && (device.Credits != 0 || device.HasCredits != (tc.counts.Credits > 0)) {
				t.Fatalf("device credit evidence: %+v", device)
			}
			if tc.listed && (daily.Models[0].HasCredits != (tc.counts.Credits > 0) || daily.Models[0].Credits != 0) {
				t.Fatalf("model credit evidence: %+v", daily.Models[0])
			}
			if daily.Events != tc.counts.Events {
				t.Fatalf("daily events: got %d, want %d", daily.Events, tc.counts.Events)
			}
		})
	}
}
