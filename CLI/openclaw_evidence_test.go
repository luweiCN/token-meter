package main

import (
	"database/sql"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestClawExplicitResponsesAndCostAttribution(t *testing.T) {
	observation := func(id, response string, rank int, input, cost, actual int64) clawObservation {
		return clawObservation{id: id, response: response, rank: rank, actual: actual, Bucket: Bucket{
			Day: "2026-01-02", Agent: "openclaw", Model: "test", Counts: Counts{Input: input, Events: 1, CostMicros: cost},
		}}
	}
	a := observation("position-A", "provider-A", clawRequest, 10, 1, 0)
	b := observation("provider-B", "provider-B", clawMirror, 12, 120, 120)
	trace := observation("turn-end", "", clawTrace, 12, 2, 0)
	for _, tc := range []struct {
		name  string
		rows  []clawObservation
		want  int64
		calls int64
		cost  int64
	}{
		{"different named provider responses", []clawObservation{a, b, trace}, 22, 2, 121},
		{"only mirrors prove two responses", []clawObservation{observation("item-A", "provider-A", clawMirror, 10, 31, 31), b, trace}, 22, 2, 151},
		{"unidentified fragment overlaps two named mirrors", []clawObservation{observation("unknown", "", clawRequest, 9, 1, 0), observation("item-A", "provider-A", clawMirror, 10, 31, 31), b, trace}, 22, 2, 151},
		{"same amount different IDs", []clawObservation{a, observation("provider-B", "provider-B", clawMirror, 10, 120, 120)}, 20, 2, 121},
		{"unknown identity preserves larger projection", []clawObservation{observation("unknown", "", clawRequest, 10, 1, 0), b, trace}, 12, 1, 120},
		{"ambiguous cost stays unassigned", []clawObservation{a, observation("position-B", "provider-B", clawRequest, 10, 2, 0), observation("turn-end", "", clawTrace, 10, 120, 120)}, 20, 2, 3},
		{"same response stable across formats", []clawObservation{observation("position-A", "", clawRequest, 10, 1, 0), a, observation("provider-A", "provider-A", clawRequest, 10, 1, 0), observation("mirror", "provider-A", clawMirror, 10, 90, 90)}, 10, 1, 90},
		{"positive mirror after zero terminal", []clawObservation{observation("trace", "", clawTrace, 0, 0, 0), b}, 12, 1, 120},
	} {
		t.Run(tc.name, func(t *testing.T) {
			rows, err := selectClawUsage(tc.rows)
			check(t, err)
			var got Counts
			for _, row := range rows {
				got.add(row.Counts)
			}
			if got.Input != tc.want || got.Events != tc.calls || got.CostMicros != tc.cost {
				t.Fatalf("got %+v", got)
			}
		})
	}
}

func TestClawRolloutUpdatesCachedLedgerAndRetainsReportedCost(t *testing.T) {
	s, root, path := harnessStore(t)
	first := Counts{Input: 10, CacheRead: 1}
	second := Counts{Input: 20, CacheRead: 2}
	writeTestFile(t, path, harnessRollout(true, []Counts{first}))
	check(t, s.scan())
	_, err := s.db.Exec("CREATE TRIGGER no_full_recount BEFORE DELETE ON local_aggregate BEGIN SELECT RAISE(ABORT,'full recount'); END")
	check(t, err)
	writeTestFile(t, path, harnessRollout(true, []Counts{first, second}))
	check(t, s.scan())
	want := Counts{Input: 30, CacheRead: 3, Events: 2, CostMicros: 69}
	assertHarnessReport(t, s, "local", want)
	harnessProjections(t, root, Counts{Input: 20, CacheRead: 2, CostMicros: 300})
	check(t, s.scan())
	want.CostMicros = 323
	assertHarnessReport(t, s, "local", want)
	archive := filepath.Join(root, "agent", "codex-home", "archived_sessions", filepath.Base(path))
	check(t, os.MkdirAll(filepath.Dir(archive), 0700))
	check(t, os.Rename(path, archive))
	check(t, s.scan())
	assertHarnessReport(t, s, "local", want)
	_, err = s.db.Exec("DROP TRIGGER no_full_recount; DELETE FROM local_aggregate")
	check(t, err)
	check(t, s.scan())
	assertHarnessReport(t, s, "local", want)
}

func TestClawSchemaUpgradePreservesUnrelatedHistory(t *testing.T) {
	s := testStore(t)
	id := s.id
	path := filepath.Join(s.home, "retired-session.jsonl")
	_, err := s.db.Exec(`INSERT INTO samples VALUES(?, 'historical', '2026-01-01','openclaw','original',14,0,0,0,22,0,1);
		INSERT INTO indexed_sources VALUES('unrelated-hermes','v1:keep');
		INSERT INTO local_aggregate VALUES(1,'[]');
		DROP TABLE claw_evidence; DROP TABLE claw_identities; ALTER TABLE indexed_sources RENAME TO source_files; PRAGMA user_version=1`, path)
	check(t, err)
	legacyEnumeration, err := s.db.Prepare("SELECT file FROM source_files")
	check(t, err)
	defer legacyEnumeration.Close()
	current, err := openStore(s.dir, s.home)
	check(t, err)
	defer current.db.Close()
	if current.id != id {
		t.Fatal("changed the device identity")
	}
	var v, n int
	check(t, current.db.QueryRow("PRAGMA user_version").Scan(&v))
	check(t, current.db.QueryRow("SELECT count(*) FROM samples WHERE file=? AND input=14", path).Scan(&n))
	var fingerprint string
	check(t, current.db.QueryRow("SELECT fingerprint FROM indexed_sources WHERE file='unrelated-hermes'").Scan(&fingerprint))
	if v != 2 || n != 1 || fingerprint != "v1:keep" {
		t.Fatalf("schema=%d history=%d fingerprint=%q", v, n, fingerprint)
	}
	if err := current.db.QueryRow("SELECT id FROM local_aggregate").Scan(&n); err != sql.ErrNoRows {
		t.Fatalf("stale v1 projection survived upgrade: %v", err)
	}
	if old, err := legacyEnumeration.Query(); err == nil {
		old.Close()
		t.Fatal("an already-open v1 scanner could still enumerate sources")
	}
}

func TestClawCrossTurnResponseConflictKeepsPublishedTotals(t *testing.T) {
	s, root, _ := harnessStore(t)
	dir := filepath.Join(root, "agent", "codex-home", "sessions")
	rows := func(turn string) []byte {
		u := rolloutAmounts(10, 0, 0, 0, 0)
		return []byte(strings.Join([]string{rolloutMeta(rolloutThread, "openclaw"), rolloutContext(turn, "test"),
			rolloutCall(harnessTime, turn, "one-response", u, u, nil)}, "\n") + "\n")
	}
	writeTestFile(t, filepath.Join(dir, "2026", "01", "02", "rollout-one-"+rolloutThread+".jsonl"), rows(rolloutTurn))
	check(t, s.scan())
	want := Counts{Input: 10, Events: 1, CostMicros: 20}
	assertHarnessReport(t, s, "local", want)
	writeTestFile(t, filepath.Join(root, "agent", "codex-home", "archived_sessions", "rollout-two-"+rolloutThread+".jsonl"), rows(harnessTurn(1)))
	if err := s.scan(); err == nil || !strings.Contains(err.Error(), "conflicting OpenClaw response turn") {
		t.Fatalf("expected conflicting named response: %v", err)
	}
	report, err := s.report("local", "", "")
	check(t, err)
	if report.Tokens != 10 || len(report.Devices) != 1 || report.Devices[0].PartialSources != 1 {
		t.Fatalf("conflict leaked duplicate charge: %+v", report)
	}
}
