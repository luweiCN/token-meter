package main

import (
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestOpenClawMigrationPreservesOriginalSessionAndPrefersCurrentCounts(t *testing.T) {
	s := testStore(t)
	root := filepath.Join(s.home, ".openclaw")
	agent := filepath.Join(root, "agents", "main")
	archive := filepath.Join(agent, clawImportDirectory)
	live := filepath.Join(agent, "sessions", "real.name.jsonl")
	base := strings.ReplaceAll(record, `"responseId":"abc",`, "")
	raw := func(input string) []byte {
		return []byte(strings.Replace(base, `"input":4`, `"input":`+input, 1) + "\n")
	}
	writeTestFile(t, live, raw("8"))
	writeTestFile(t, filepath.Join(archive, "archive-tier.real.name.jsonl.imported-1780000000000"), raw("4"))
	withHeader := []byte(`{"type":"session","id":"real.name"}` + "\n")
	writeTestFile(t, filepath.Join(archive, "other.wrong.jsonl.imported-1780000000000.1"), append(withHeader, raw("4")...))
	second := filepath.Join(archive, "session.key.with.dots.topic.two.jsonl.imported-1780000000000.2")
	writeTestFile(t, second, raw("4"))
	manifest := map[string]any{"targets": []any{map[string]any{
		"completedMoves": []any{map[string]string{
			"kind": "transcript", "archivePath": second,
			"sourcePath": filepath.Join(agent, "sessions", "topic.two.jsonl"),
		}},
	}}}
	encoded, err := json.Marshal(manifest)
	check(t, err)
	writeTestFile(t, filepath.Join(root, "session-sqlite-migration-runs", "run.json"), encoded)
	third := filepath.Join(archive, "session.third.jsonl.imported-1780000000000")
	writeTestFile(t, third, raw("4"))

	for _, path := range []string{
		filepath.Join(archive, "archive-tier.secret.trajectory.jsonl.imported-1780000000000"),
		filepath.Join(archive, "archive-tier.secret.checkpoint.invalid.jsonl.imported-1780000000000"),
		filepath.Join(archive, "session.orphan.jsonl.imported-1780000000000.tmp"),
		filepath.Join(archive, "session.sessions.json.imported-1780000000000"),
		filepath.Join(archive, "backup", "key.nested.jsonl.imported-1780000000000"),
		filepath.Join(agent, "other-backup", "archive-tier.backup.jsonl.imported-1780000000000"),
		filepath.Join(agent, "sessions", "archive-tier.misplaced.jsonl.imported-1780000000000"),
	} {
		writeTestFile(t, path, []byte("not a transcript\n"))
	}
	assertUsage := func(want int64) {
		t.Helper()
		check(t, s.scan())
		r, err := s.report("local", "", "")
		check(t, err)
		if r.Tokens != want || len(r.Agents) != 1 || r.Agents[0].Events != 3 || len(r.Devices) != 1 || r.Devices[0].PartialSources != 0 {
			t.Fatalf("got %+v, want 3 events and %d tokens", r, want)
		}
	}
	assertUsage(17 + 13 + 13)
	assertUsage(17 + 13 + 13)
	var files, cursors int
	check(t, s.db.QueryRow("SELECT count(*) FROM indexed_sources").Scan(&files))
	check(t, s.db.QueryRow("SELECT count(*) FROM source_cursors").Scan(&cursors))
	if files != 5 || cursors != 1 {
		t.Fatalf("unexpected source selection: %d files, %d cursors", files, cursors)
	}
	// The same request can be corrected in the active append-only projection.
	f, err := os.OpenFile(live, os.O_APPEND|os.O_WRONLY, 0600)
	check(t, err)
	_, err = f.Write(raw("9"))
	check(t, err)
	check(t, f.Close())
	assertUsage(18 + 13 + 13)

	// The SQLite import still has one mirrored session. Only the remaining
	// two historical sessions are supplied exclusively by the migration files.
	dbPath := filepath.Join(agent, "agent", "openclaw-agent.sqlite")
	check(t, os.MkdirAll(filepath.Dir(dbPath), 0700))
	db, err := sql.Open("sqlite", sqlitePath(dbPath))
	check(t, err)
	_, err = db.Exec("CREATE TABLE transcript_events (session_id TEXT,seq INTEGER,event_json TEXT)")
	check(t, err)
	_, err = db.Exec("INSERT INTO transcript_events VALUES ('real.name',1,?)", string(raw("12")))
	check(t, err)
	check(t, db.Close())
	check(t, os.Remove(live))
	assertUsage(21 + 13 + 13)
	check(t, os.Remove(dbPath))
	assertUsage(21 + 13 + 13)
}

func TestOpenClawCheckpointRecoversOnlyDistinctRequestsAcrossRollback(t *testing.T) {
	s := testStore(t)
	agent := filepath.Join(s.home, ".openclaw", "agents", "main")
	sessions, archive := filepath.Join(agent, "sessions"), filepath.Join(agent, clawImportDirectory)
	const ck1 = "real.name.checkpoint.27b3711e-e279-40f8-a7b8-b442e26fe288.jsonl"
	const ck2 = "real.name.checkpoint.27b3711e-e279-40f8-a7b8-b442e26fe299.jsonl"
	plain := filepath.Join(sessions, ck1)
	archived := filepath.Join(archive, "archive-tier."+ck1+".imported-1780000000000")
	duplicate := filepath.Join(archive, "archive-tier."+ck2+".imported-1780000000000.1")
	live := filepath.Join(sessions, "real.name.jsonl")
	imported := filepath.Join(archive, "archive-tier.real.name.jsonl.imported-1780000000000")
	// One mirrored request only has its original session/record ID, the
	// other represents a provider response retained solely in the checkpoints.
	shared := strings.ReplaceAll(record, `"responseId":"abc",`, "")
	unique := strings.ReplaceAll(record, "abc", "retained-response")
	copies := []byte(shared + "\n" + unique + "\n")
	writeTestFile(t, plain, copies)
	writeTestFile(t, archived, copies)
	writeTestFile(t, duplicate, copies)
	assertUsage := func(tokens, events int64) {
		t.Helper()
		check(t, s.scan())
		r, err := s.report("local", "", "")
		check(t, err)
		if r.Tokens != tokens || len(r.Agents) != 1 || r.Agents[0].Events != events || len(r.Devices) != 1 || r.Devices[0].PartialSources != 0 {
			t.Fatalf("expected %d tokens across %d requests, got %+v", tokens, events, r)
		}
	}
	assertUsage(26, 2)
	assertUsage(26, 2)
	corrected := func(input string) []byte {
		return []byte(strings.Replace(shared, `"input":4`, `"input":`+input, 1) + "\n")
	}
	writeTestFile(t, imported, corrected("8"))
	assertUsage(17+13, 2)
	writeTestFile(t, live, corrected("9"))
	assertUsage(18+13, 2)
	// Restoring a checkpoint to the live session does not create new requests.
	writeTestFile(t, live, copies)
	assertUsage(26, 2)
	check(t, os.Remove(live))
	check(t, os.Remove(plain))
	assertUsage(26, 2)
	check(t, os.Remove(imported))
	writeTestFile(t, archived, []byte(shared+"\n"))
	assertUsage(26, 2)
	check(t, os.Remove(duplicate))
	assertUsage(26, 2)
}
