package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/klauspost/compress/zstd"
)

func TestCheckpointUpgradeRekeysOnlyProvenLegacyIDs(t *testing.T) {
	for _, mode := range []string{"v1-with-append-cursor", "zstd-v1", "returning-legacy-checkpoint"} {
		t.Run(mode, func(t *testing.T) {
			s := testStore(t)
			dir := filepath.Join(s.home, ".openclaw", "agents", "test", "sessions")
			const stem = "original.checkpoint.27b3711e-e279-40f8-a7b8-b442e26fe288"
			path := filepath.Join(dir, stem+".jsonl")
			pack := func(data string) []byte { return []byte(data) }
			prefix := "v1:"
			if mode == "zstd-v1" {
				path += ".reset.2026-01-02T08-00-00Z.zst"
				prefix = "zstd:v1:"
				encoder, err := zstd.NewWriter(nil, zstd.WithEncoderConcurrency(1))
				check(t, err)
				defer encoder.Close()
				pack = func(data string) []byte { return encoder.EncodeAll([]byte(data), nil) }
			}
			withoutResponse := strings.Replace(record, `"responseId":"abc",`, "", 1)
			withoutID := strings.Replace(withoutResponse, `"id":"e",`, "", 1)
			afterHeader := strings.Replace(withoutResponse, `"id":"e"`, `"id":"after"`, 1)
			body := strings.Join([]string{withoutResponse, withoutID, record, `{"type":"session","id":"identified"}`, afterHeader, ""}, "\n")
			writeTestFile(t, path, pack(body))
			cat, err := prices(s.home)
			check(t, err)
			storeOld := func(x sample) error {
				_, err := s.db.Exec("INSERT INTO samples VALUES(?,?,?,?,?,?,?,?,?,?,?,?)", path, x.id, x.day, x.agent, x.model,
					x.Input, x.Output, x.CacheRead, x.CacheWrite, x.CostMicros, x.UnknownCost, x.Events)
				return err
			}
			// Reproduce the pre-checkpoint reader's file-based session fallback.
			check(t, cat.clawLines(strings.NewReader(body), stem, storeOld))
			unavailable := strings.Replace(withoutResponse, `"id":"e"`, `"id":"retired"`, 1)
			check(t, cat.clawLines(strings.NewReader(unavailable), stem, storeOld))
			// A historical session actually used the checkpoint name as its ID.
			check(t, cat.clawLines(strings.NewReader(`{"type":"session","id":"`+stem+`"}`+"\n"+afterHeader), stem, storeOld))
			fp, err := fingerprint(path, prefix+cat.fingerprint)
			check(t, err)
			_, err = s.db.Exec("INSERT INTO indexed_sources VALUES(?,?)", path, fp)
			check(t, err)
			if mode == "returning-legacy-checkpoint" {
				check(t, os.Remove(path))
				check(t, s.scan())
				var retained string
				check(t, s.db.QueryRow("SELECT fingerprint FROM indexed_sources WHERE file=?", path).Scan(&retained))
				if retained != retiredCheckpoint+fp {
					t.Fatal("unavailable checkpoint lost its old parser provenance")
				}
			}
			if mode == "v1-with-append-cursor" {
				f, err := os.Open(path)
				check(t, err)
				offset := int64(len(body))
				identity, err := fileIdentity(f)
				check(t, err)
				last, err := anchor(f, offset)
				check(t, err)
				check(t, f.Close())
				_, err = s.db.Exec("INSERT INTO source_cursors VALUES(?,?,?,?,?,?)", path, offset, offset, "identified", identity, last)
				check(t, err)
			}
			count := func(id string) int {
				t.Helper()
				var n int
				check(t, s.db.QueryRow("SELECT count(*) FROM samples WHERE file=? AND id=?", path, id).Scan(&n))
				return n
			}
			writeTestFile(t, path, pack(body+"broken\n"))
			if err = s.scan(); err == nil || count(digest("openclaw", stem, "e")) != 1 {
				t.Fatal("incomplete upgrade lost the previous ledger or reported success")
			}
			writeTestFile(t, filepath.Join(dir, "original.jsonl"), []byte(withoutResponse+"\n"+withoutID+"\n"))
			writeTestFile(t, path, pack(body+`{"type":"custom"}`+"\n"))
			check(t, s.scan())
			for _, key := range []string{"e", withoutID} {
				if count(digest("openclaw", stem, key)) != 0 || count(digest("openclaw", "original", key)) != 1 {
					t.Fatal("legacy checkpoint ID was not replaced exactly once")
				}
			}
			for _, keep := range []string{digest("openclaw", "provider", "abc"), digest("openclaw", "identified", "after"),
				digest("openclaw", stem, "after"), digest("openclaw", stem, "retired")} {
				if count(keep) != 1 {
					t.Fatal("an unrelated or unobservable historical event was removed")
				}
			}
			check(t, s.scan())
			r, err := s.report("local", "", "")
			check(t, err)
			if r.Tokens != 6*13 || len(r.Agents) != 1 || r.Agents[0].Events != 6 {
				t.Fatalf("corrected identities, mirror or retained history counted incorrectly: %+v", r)
			}

			// With the current format, an explicit session ID matching the old
			// filename is legitimate, even after repricing and a later retirement.
			writeTestFile(t, path, pack(`{"type":"session","id":"`+stem+`"}`+"\n"+withoutResponse+"\n"))
			check(t, s.scan())
			writeTestFile(t, filepath.Join(s.home, ".token-meter", "cache", "litellm-pricing-v2.json"),
				[]byte(`{"schemaVersion":2,"models":{"test":{"inputPerMTok":1}}}`))
			writeTestFile(t, path, pack(withoutResponse+"\n"))
			check(t, s.scan())
			check(t, os.Remove(path))
			check(t, s.scan())
			writeTestFile(t, path, pack(withoutResponse+"\n"))
			check(t, s.scan())
			if count(digest("openclaw", stem, "e")) != 1 || count(digest("openclaw", "original", "e")) != 1 {
				t.Fatal("ordinary repricing or retirement reapplied the legacy ID repair")
			}
		})
	}
}
