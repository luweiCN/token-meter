package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/klauspost/compress/zstd"
)

func TestOpenClawCompressedResetDeletedAndRotation(t *testing.T) {
	s := testStore(t)
	dir := filepath.Join(s.home, ".openclaw", "agents", "main", "sessions")
	live := filepath.Join(dir, "x.jsonl")
	reset := live + ".reset.2026-01-02T08-00-00Z.zst"
	deleted := live + ".deleted.2026-01-03T09-30-21.153Z.19c2a38f246b4f33bb46190aed9df458.zst"
	z, err := zstd.NewWriter(nil, zstd.WithEncoderConcurrency(1))
	check(t, err)
	defer z.Close()
	pack := func(lines string) []byte { return z.EncodeAll([]byte(lines), nil) }
	// The fallback session/record ID must survive rotation even without a provider response ID.
	const noResponse = `"responseId":"abc",`
	first := strings.ReplaceAll(record, noResponse, "")
	second := strings.ReplaceAll(first, `"id":"e"`, `"id":"f"`)
	writeTestFile(t, live, []byte(first+"\n"))
	writeTestFile(t, reset, pack(first+"\n"))
	writeTestFile(t, deleted, pack(first+"\n"+second))

	// Older readers could persist an empty result and a cursor on binary data.
	cat, err := prices(s.home)
	check(t, err)
	previous, err := fingerprint(deleted, "v1:"+cat.fingerprint)
	check(t, err)
	_, err = s.db.Exec("INSERT INTO indexed_sources VALUES(?, ?)", deleted, previous)
	check(t, err)
	_, err = s.db.Exec("INSERT INTO source_cursors VALUES(?, 0, 0, '', '', '')", deleted)
	check(t, err)

	assertUsage := func(wantTokens, events int64, partial int) {
		t.Helper()
		r, err := s.report("local", "", "")
		check(t, err)
		if r.Tokens != wantTokens || len(r.Agents) != 1 || r.Agents[0].Events != events || r.CostMicros != events*12000 || len(r.Devices) != 1 || r.Devices[0].PartialSources != partial {
			t.Fatalf("wrong archive totals: %+v", r)
		}
	}
	check(t, s.scan())
	assertUsage(26, 2, 0)
	var cursorFiles, indexedFiles int
	check(t, s.db.QueryRow("SELECT count(*) FROM source_cursors WHERE file <> ?", live).Scan(&cursorFiles))
	check(t, s.db.QueryRow("SELECT count(*) FROM indexed_sources").Scan(&indexedFiles))
	if cursorFiles != 0 || indexedFiles != 3 {
		t.Fatalf("unexpected archive indexing: %d non-live cursors, %d files", cursorFiles, indexedFiles)
	}
	var before, after int64
	check(t, s.db.QueryRow("SELECT revision FROM replicas WHERE id=?", s.id).Scan(&before))
	check(t, s.scan())
	assertUsage(26, 2, 0)
	check(t, s.db.QueryRow("SELECT revision FROM replicas WHERE id=?", s.id).Scan(&after))
	if before != after {
		t.Fatalf("unchanged archives published another revision: %d -> %d", before, after)
	}

	check(t, os.Remove(live))
	check(t, os.Remove(reset))
	check(t, s.scan())
	assertUsage(26, 2, 0)
	third := strings.ReplaceAll(second, `"id":"f"`, `"id":"g"`)
	replacement := pack(first + "\n" + third + "\n" + second + "\n")
	for _, corrupt := range [][]byte{nil, replacement[:len(replacement)-1], pack(first + "\n{")} {
		writeTestFile(t, deleted, corrupt)
		if err := s.scan(); err == nil {
			t.Fatal("a broken compressed archive was counted as complete")
		}
		assertUsage(26, 2, 1)
	}
	writeTestFile(t, deleted, replacement)
	check(t, s.scan())
	assertUsage(39, 3, 0)
	writeTestFile(t, deleted, pack(third+"\n"))
	check(t, s.scan())
	assertUsage(39, 3, 0)
}

func TestOpenClawCountedTranscriptNames(t *testing.T) {
	const stamp = "2026-01-02T08-00-00.123Z"
	const checkpoint = "x.checkpoint.27b3711e-e279-40f8-a7b8-b442e26fe288"
	for name, want := range map[string]bool{
		"x.jsonl":                                     true,
		"x.jsonl.reset." + stamp:                      true,
		"x.jsonl.deleted." + stamp + ".zst":           true,
		"x.jsonl.deleted." + stamp + ".gz":            false,
		"x.jsonl.deleted." + stamp + ".zst.tmp":       false,
		"x.jsonl.bak." + stamp + ".zst":               false,
		"x.trajectory.jsonl":                          false,
		checkpoint + ".jsonl":                         true,
		checkpoint + ".jsonl.reset." + stamp + ".zst": true,
		"x.checkpoint.invalid.jsonl":                  false,
	} {
		if got := clawSessionID(name) != ""; got != want {
			t.Errorf("clawSessionID(%q) reported %v, want %v", name, got, want)
		}
	}
}
