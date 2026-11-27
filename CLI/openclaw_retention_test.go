package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestOpenClawRetainedRequestsAndCorrectionsReachPairedReader(t *testing.T) {
	s, reader := testStore(t), testStore(t)
	check(t, reader.addPeer(s.id, "127.0.0.1:24593", "peer"))
	agent := filepath.Join(s.home, ".openclaw", "agents", "old")
	live := filepath.Join(agent, "sessions", "x.jsonl")
	sqlite := filepath.Join(agent, "agent", "openclaw-agent.sqlite")
	second := strings.Replace(record, "abc", "second", 1)
	writeTestFile(t, live, []byte(record+"\n"))
	check(t, os.MkdirAll(filepath.Dir(sqlite), 0700))

	var revision int64
	edit := func(query string, args ...any) {
		t.Helper()
		db, err := sql.Open("sqlite", sqlitePath(sqlite))
		check(t, err)
		_, err = db.Exec(query, args...)
		check(t, err)
		check(t, db.Close())
		revision++
		stamp := time.Unix(1_700_000_000+revision, 0)
		check(t, os.Chtimes(sqlite, stamp, stamp))
	}
	assertTotals := func(tokens, events, cost int64, partial int) {
		t.Helper()
		if err := s.scan(); (err != nil) != (partial != 0) {
			t.Fatalf("unexpected scan status: %v", err)
		}
		var raw []byte
		check(t, s.db.QueryRow("SELECT body FROM replicas WHERE id=?", s.id).Scan(&raw))
		var env Envelope
		check(t, json.Unmarshal(raw, &env))
		check(t, reader.acceptFrom(context.Background(), s.id, s.id, 1, env))
		for _, device := range []*Store{s, reader} {
			r, err := device.report(s.id, "", "")
			check(t, err)
			if r.Tokens != tokens || r.CostMicros != cost || len(r.Devices) != 1 || r.Devices[0].Events != events || r.Devices[0].PartialSources != partial {
				t.Fatalf("want %d tokens, %d events, %d cost and %d partial sources, got %+v", tokens, events, cost, partial, r)
			}
		}
	}
	edit("CREATE TABLE transcript_events(session_id TEXT,seq INTEGER,event_json TEXT)")
	first := strings.Replace(record, `"input":4`, `"input":14`, 1)
	edit("INSERT INTO transcript_events VALUES('x',1,?),('x',2,?)", first, second)
	assertTotals(36, 2, 24000, 0)

	// A metadata-only WAL commit changes the fingerprint without touching the
	// database file or any measured request.
	upstream, err := sql.Open("sqlite", sqlitePath(sqlite))
	check(t, err)
	defer upstream.Close()
	upstream.SetMaxOpenConns(1)
	_, err = upstream.Exec(`PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;
		CREATE TABLE metadata(value TEXT); INSERT INTO metadata VALUES('before'); PRAGMA wal_checkpoint(TRUNCATE)`)
	check(t, err)
	assertTotals(36, 2, 24000, 0)
	before, err := os.Stat(sqlite)
	check(t, err)
	for _, trigger := range []string{
		"CREATE TRIGGER reject_sample_rewrite BEFORE UPDATE ON samples BEGIN SELECT RAISE(ABORT, 'unchanged sample rewrite'); END",
		"CREATE TRIGGER reject_sample_delete BEFORE DELETE ON samples BEGIN SELECT RAISE(ABORT, 'unchanged sample delete'); END",
		"CREATE TRIGGER reject_cache_delete BEFORE DELETE ON local_aggregate BEGIN SELECT RAISE(ABORT, 'unchanged aggregate invalidation'); END",
	} {
		_, err := s.db.Exec(trigger)
		check(t, err)
	}
	_, err = upstream.Exec("UPDATE metadata SET value='after'")
	check(t, err)
	after, err := os.Stat(sqlite)
	check(t, err)
	wal, err := os.Stat(sqlite + "-wal")
	check(t, err)
	if before.Size() != after.Size() || !before.ModTime().Equal(after.ModTime()) || wal.Size() == 0 {
		t.Fatalf("expected a WAL-only change: base %d -> %d, WAL %d", before.Size(), after.Size(), wal.Size())
	}
	assertTotals(36, 2, 24000, 0)
	check(t, upstream.Close())
	_, err = s.db.Exec("DROP TRIGGER reject_sample_rewrite; DROP TRIGGER reject_sample_delete; DROP TRIGGER reject_cache_delete")
	check(t, err)

	edit("UPDATE transcript_events SET event_json='{' WHERE seq=2")
	assertTotals(36, 2, 24000, 1)
	edit("DELETE FROM transcript_events WHERE seq=2")
	assertTotals(36, 2, 24000, 0)
	// Changing a measured response can decrease its price and move it to another bucket.
	correction := strings.NewReplacer(`"input":14`, `"input":9`, "0.012", "0.006", "2026-01-02", "2026-01-03").Replace(first)
	edit("UPDATE transcript_events SET event_json=? WHERE seq=1", correction)
	assertTotals(31, 2, 18000, 0)
	originalDay := time.Date(2026, 1, 2, 8, 0, 0, 0, time.UTC).In(time.Local).Format(time.DateOnly)
	jan2, err := s.report("local", originalDay, originalDay)
	check(t, err)
	if jan2.Tokens != 13 || jan2.CostMicros != 12000 {
		t.Fatalf("corrected request remains in its old bucket: %+v", jan2)
	}
	edit("DELETE FROM transcript_events")
	assertTotals(31, 2, 18000, 0)
	retired := filepath.Join(s.home, "retired-agent")
	check(t, os.Rename(agent, retired))
	assertTotals(31, 2, 18000, 0)
	var files, cursors int
	check(t, s.db.QueryRow("SELECT count(*) FROM indexed_sources").Scan(&files))
	check(t, s.db.QueryRow("SELECT count(*) FROM source_cursors").Scan(&cursors))
	if files != 0 || cursors != 0 {
		t.Fatalf("retired sources still hold %d file fingerprints and %d cursors", files, cursors)
	}

	// A reappearing legacy mirror adds a new request without rolling back the
	// SQLite correction. The aggregate may have been evicted or persisted null.
	_, err = s.db.Exec("UPDATE local_aggregate SET buckets='null'")
	check(t, err)
	third := strings.Replace(record, "abc", "third", 1)
	writeTestFile(t, live, []byte(record+"\n"+second+"\n"+third+"\n"))
	assertTotals(44, 3, 30000, 0)
	assertTotals(44, 3, 30000, 0)
	// Both the prior source and its incomplete replacement can disappear at cutover.
	check(t, os.Remove(live))
	writeTestFile(t, live+".reset.2026-01-02T08-00-00Z.zst", []byte("incomplete archive"))
	assertTotals(44, 3, 30000, 1)
}
