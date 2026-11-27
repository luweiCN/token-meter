package main

import (
	"encoding/json"
	"path/filepath"
	"testing"
	"time"
)

func TestMenuMachineUsageUsesOnlyTheCurrentDay(t *testing.T) {
	local, remote := testStore(t), testStore(t)
	now := time.Now()
	yesterday := day(now.AddDate(0, 0, -1))
	today := day(now)
	tomorrow := day(now.AddDate(0, 0, 1))

	older := Counts{Input: 999_999_999, CostMicros: 5_000_000, Events: 1}
	check(t, local.publish([]Bucket{{Day: yesterday, Agent: "codex", Model: "old", Counts: older}}, nil, 0))
	check(t, remote.publish([]Bucket{
		{Day: yesterday, Agent: "openclaw", Model: "old", Counts: older},
		{Day: today, Agent: "openclaw", Model: "a", Counts: Counts{
			Input: 8_000_000, Output: 18_000_000, CacheRead: 60_000_000,
			CacheWrite: 12_000_000, CostMicros: 1_250_000, Events: 4,
		}},
		{Day: today, Agent: "hermes", Model: "b", Counts: Counts{
			Input: 1_000_000, Output: 1_000_000, UnknownCost: 1, UnknownTokens: 1, Events: 2,
		}},
		{Day: tomorrow, Agent: "hermes", Model: "next", Counts: Counts{Events: 1, UnknownTokens: 1}},
	}, nil, 0))
	var body []byte
	check(t, remote.db.QueryRow("SELECT body FROM replicas WHERE id=?", remote.id).Scan(&body))
	var envelope Envelope
	check(t, json.Unmarshal(body, &envelope))
	check(t, local.addPeer(remote.id, "127.0.0.1:47732", "peer"))
	check(t, local.acceptFrom(t.Context(), remote.id, remote.id, 1, envelope))
	check(t, local.writeReport())

	var summary struct {
		Day     string   `json:"day"`
		Devices []Device `json:"devices"`
	}
	check(t, loadOptional(filepath.Join(local.dir, "summary.json"), &summary))
	if summary.Day != today && summary.Day != day(time.Now()) {
		t.Fatalf("summary uses unexpected local calendar day %q", summary.Day)
	}
	byID := map[string]Device{}
	for _, d := range summary.Devices {
		byID[d.ID] = d
	}
	if d := byID[local.id]; d.Counts != (Counts{}) {
		t.Fatalf("yesterday's local usage appeared in today's menu: %+v", d)
	}
	want := Counts{
		Input: 9_000_000, Output: 19_000_000, CacheRead: 60_000_000, CacheWrite: 12_000_000,
		CostMicros: 1_250_000, Events: 6, UnknownCost: 1, UnknownTokens: 1,
	}
	if summary.Day == tomorrow {
		want = Counts{Events: 1, UnknownTokens: 1}
	}
	if d := byID[remote.id]; d.Local || d.Counts != want || d.Tokens != want.tokens() {
		t.Fatalf("remote machine usage: got %+v, want %+v", d, want)
	}
	history, err := local.report(local.id, "", "")
	check(t, err)
	if history.Tokens != older.tokens() {
		t.Fatalf("device history after writing daily menu: got %d, want %d", history.Tokens, older.tokens())
	}
}

func TestMachineIsActiveForReportedSpendAndUnreportedTokenUsage(t *testing.T) {
	const current = "2026-11-25"
	for _, tc := range []struct {
		name   string
		counts Counts
		active bool
	}{
		{"idle", Counts{Events: 1}, false},
		{"unpriced zero", Counts{Events: 1, UnknownCost: 1}, false},
		{"tokens", Counts{Input: 1, Events: 1}, true},
		{"unreported tokens", Counts{UnknownTokens: 1, Events: 1}, true},
		{"billed credits", Counts{Credits: 1, Events: 1}, true},
		{"known cost", Counts{CostMicros: 1, Events: 1}, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			snapshot := Snapshot{Origin: "local", Buckets: []Bucket{{Day: current, Agent: "codex", Model: "test", Counts: tc.counts}}}
			summary, err := dailyMenuSummary(current, snapshot.Origin, []Snapshot{snapshot})
			check(t, err)
			if len(summary.Devices) != 1 || summary.Devices[0].Active != tc.active {
				t.Fatalf("menu machines: %+v; want active %t", summary.Devices, tc.active)
			}
		})
	}
}
