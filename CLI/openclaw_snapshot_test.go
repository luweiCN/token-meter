package main

import (
	"crypto/sha256"
	"database/sql"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
)

func TestOpenClawRestoreDuringScanReadsOneSnapshot(t *testing.T) {
	path := filepath.Join(t.TempDir(), "openclaw-agent.sqlite")
	writer, err := sql.Open("sqlite", sqlitePath(path))
	check(t, err)
	defer writer.Close()
	_, err = writer.Exec(`PRAGMA journal_mode=WAL;
		CREATE TABLE transcript_events(session_id TEXT, seq INTEGER, event_json TEXT);
		INSERT INTO transcript_events VALUES('live', 1, ?)`, record)
	check(t, err)
	tables := []string{"session_transcript_archives", "session_transcript_cold_archives", "session_transcript_cold_archive_chunks"}
	for _, table := range tables {
		raw := []byte(strings.Replace(record, `"abc"`, `"`+table+`"`, 1))
		_, err = writer.Exec("CREATE TABLE " + table + " (session_id TEXT, archive_name TEXT, archive_sha256 TEXT, archive_blob BLOB)")
		check(t, err)
		_, err = writer.Exec("INSERT INTO "+table+" VALUES(?,?,?,?)", table, table+".jsonl", fmt.Sprintf("%x", sha256.Sum256(raw)), raw)
		check(t, err)
	}

	for scan := 0; scan < 2; scan++ {
		seen := map[string]int{}
		err = (catalog{}).clawFile(path, func(x sample) error {
			seen[x.id]++
			if scan != 0 || len(seen) != 1 {
				return nil
			}
			// Restore each archive and retire its table while the live cursor is open.
			tx, err := writer.Begin()
			if err != nil {
				return err
			}
			defer tx.Rollback()
			for _, table := range tables {
				if _, err := tx.Exec("INSERT INTO transcript_events SELECT session_id, 1, CAST(archive_blob AS TEXT) FROM " + table); err != nil {
					return err
				}
				if _, err := tx.Exec("DROP TABLE " + table); err != nil {
					return err
				}
			}
			return tx.Commit()
		}, nil)
		check(t, err)
		for _, response := range append([]string{"abc"}, tables...) {
			if n := seen[digest("openclaw", "provider", response)]; n != 1 {
				t.Fatalf("scan %d observed %s %d times, want once", scan, response, n)
			}
		}
	}
}
