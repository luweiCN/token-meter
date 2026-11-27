package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/klauspost/compress/zstd"
)

type sample struct {
	id, day, agent, model string
	Counts
	clawTurn, clawResponse   string
	clawRank                 int
	clawComplete, sourceCost bool
}
type emitSample func(sample) error

var clawArchiveSuffix = regexp.MustCompile(`\.jsonl\.(?:deleted|reset)\.(?:\d+|\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}(?:\.\d{3})?Z(?:\.[0-9a-f]{32})?)(?:\.zst)?$`)
var clawCheckpointSuffix = regexp.MustCompile(`(?i)\.checkpoint\.[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

func isClawCheckpoint(name string) bool {
	end := strings.LastIndex(name, ".jsonl")
	return end > 0 && clawCheckpointSuffix.MatchString(name[:end])
}

func clawSessionID(name string) string {
	stem, live := strings.CutSuffix(name, ".jsonl")
	if !live {
		suffix := clawArchiveSuffix.FindStringIndex(name)
		if suffix == nil {
			return ""
		}
		stem = name[:suffix[0]]
	}
	return clawSessionStem(stem)
}

func clawSessionStem(stem string) string {
	if checkpoint := clawCheckpointSuffix.FindStringIndex(stem); checkpoint != nil {
		stem = stem[:checkpoint[0]]
	} else if _, suffix, ok := strings.Cut(stem, ".checkpoint."); ok && !strings.Contains(suffix, ".") {
		return ""
	}
	if strings.HasSuffix(stem, ".trajectory") {
		return ""
	}
	return stem
}

type clawUsage struct {
	Input, Output, CacheRead, CacheWrite int64
	Cost                                 *struct{ Total *float64 }
}

const openClawDeliveryMirrorModel = "delivery-mirror"

type clawEntry struct {
	Kind string
	Row  struct {
		EventJSON string `json:"event_json"`
	}
	Type, ID, Timestamp string
	Message             struct {
		Role, Model, Provider, ResponseID, IdempotencyKey string
		Timestamp                                         int64
		Usage                                             *clawUsage
	}
}

func digest(parts ...string) string {
	return fmt.Sprintf("%x", sha256.Sum256([]byte(strings.Join(parts, "\x00"))))
}

func clawTurnKey(thread, turn string) string {
	if thread == "" || turn == "" {
		return ""
	}
	return digest("openclaw-codex-turn", thread, turn)
}

func clawMirrorTurn(key string) string {
	tail, ok := strings.CutPrefix(key, "codex-app-server:")
	if !ok {
		return ""
	}
	thread, tail, _ := strings.Cut(tail, ":")
	turn, item, ok := strings.Cut(tail, ":")
	if !ok || item == "" {
		return ""
	}
	return clawTurnKey(thread, turn)
}

func (c catalog) clawUsageSample(id, model string, at time.Time, u clawUsage) (sample, error) {
	if model == "" {
		model = "unknown"
	}
	s := sample{id: id, day: at.In(time.Local).Format(time.DateOnly), agent: "openclaw", model: model,
		Counts: Counts{Input: u.Input, Output: u.Output, CacheRead: u.CacheRead, CacheWrite: u.CacheWrite, Events: 1}}
	if !s.Counts.valid() {
		return sample{}, errors.New("invalid OpenClaw usage")
	}
	if u.Cost != nil && u.Cost.Total != nil && *u.Cost.Total > 0 {
		amount := math.Round(*u.Cost.Total * 1e6)
		if amount >= float64(math.MaxInt64) {
			return sample{}, errors.New("invalid OpenClaw cost")
		}
		s.sourceCost = true
		s.CostMicros = int64(amount)
	} else if micros, ok := c.estimate(model, at, s.Counts); ok {
		s.CostMicros = micros
	} else if s.tokens() > 0 {
		s.UnknownCost = 1
	}
	return s, nil
}

type checkpointIDRepair struct {
	legacyScope string
	remove      func(string) error
}

func (c catalog) clawRecord(raw []byte, session *string, emit emitSample, repair *checkpointIDRepair) error {
	var r clawEntry
	if err := json.Unmarshal(raw, &r); err != nil {
		return err
	}
	if r.Kind == "event" && r.Row.EventJSON != "" {
		var stored clawEntry
		if err := json.Unmarshal([]byte(r.Row.EventJSON), &stored); err != nil {
			return err
		}
		r = stored
	}
	if r.Type == "session" && r.ID != "" {
		*session = r.ID
		if repair != nil {
			repair.legacyScope = ""
		}
		return nil
	}
	m := r.Message
	u := m.Usage
	if r.Type != "message" || m.Role != "assistant" || u == nil {
		return nil
	}
	if m.Provider == "openclaw" && m.Model == openClawDeliveryMirrorModel {
		return nil
	}
	at, err := time.Parse(time.RFC3339Nano, r.Timestamp)
	if err != nil {
		if m.Timestamp <= 0 {
			return errors.New("OpenClaw usage missing timestamp")
		}
		at = time.UnixMilli(m.Timestamp)
	}
	var id string
	switch {
	case m.ResponseID != "":
		id = digest("openclaw", m.Provider, m.ResponseID)
	case *session == "":
		return errors.New("cannot determine the original OpenClaw session for a usage record")
	default:
		key := r.ID
		if key == "" {
			key = string(raw)
		}
		id = digest("openclaw", *session, key)
		if repair != nil && repair.legacyScope != "" && repair.legacyScope != *session {
			if err := repair.remove(digest("openclaw", repair.legacyScope, key)); err != nil {
				return err
			}
		}
	}
	x, err := c.clawUsageSample(id, m.Model, at, *u)
	if err != nil {
		return err
	}
	if turn := clawMirrorTurn(m.IdempotencyKey); turn != "" {
		x.clawTurn, x.clawRank = turn, clawMirror
	}
	if x.clawTurn != "" || m.Provider == "openai" {
		x.clawResponse = m.ResponseID
	}
	return emit(x)
}
func (c catalog) clawLines(in io.Reader, session string, emit emitSample) error {
	_, err := c.clawStream(in, &session, emit, false, nil)
	return err
}
func (c catalog) clawStream(in io.Reader, session *string, emit emitSample, allowPartial bool, repair *checkpointIDRepair) (int64, error) {
	r := bufio.NewReaderSize(in, 64*1024)
	var consumed int64
	for {
		raw, e := r.ReadBytes('\n')
		length := len(raw)
		raw = bytes.TrimSpace(raw)
		if len(raw) > 0 {
			if err := c.clawRecord(raw, session, emit, repair); err != nil {
				if allowPartial && e == io.EOF && !json.Valid(raw) {
					return consumed, nil
				}
				return consumed, err
			}
		}
		if e == io.EOF {
			return consumed, nil
		}
		if e != nil {
			return consumed, e
		}
		consumed += int64(length)
	}
}
func tableExists(tx *sql.Tx, table string) (bool, error) {
	var n int
	e := tx.QueryRow("SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?", table).Scan(&n)
	return n != 0, e
}
func columns(db interface {
	Query(string, ...any) (*sql.Rows, error)
}, table string) (map[string]bool, error) {
	rows, e := db.Query("SELECT name FROM pragma_table_info(?)", table)
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	out := map[string]bool{}
	for rows.Next() {
		var k string
		if e = rows.Scan(&k); e != nil {
			return nil, e
		}
		out[k] = true
	}
	return out, rows.Err()
}
func (c catalog) clawFile(path string, emit emitSample, repair *checkpointIDRepair) error {
	decoder, e := zstd.NewReader(nil, zstd.WithDecoderConcurrency(1), zstd.WithDecoderMaxMemory(64<<20))
	if e != nil {
		return e
	}
	defer decoder.Close()
	if filepath.Ext(path) == ".zst" {
		f, e := os.Open(path)
		if e != nil {
			return e
		}
		defer f.Close()
		in := bufio.NewReader(f)
		if _, e = in.Peek(4); e != nil {
			return fmt.Errorf("incomplete OpenClaw zstd frame: %w", e)
		}
		if e = decoder.Reset(in); e != nil {
			return e
		}
		session := clawSessionID(filepath.Base(path))
		_, e = c.clawStream(decoder, &session, emit, false, repair)
		return e
	}
	db, e := readDB(path)
	if e != nil {
		return e
	}
	defer db.Close()
	// A compaction or restore can move the same request between tables.
	tx, e := db.BeginTx(context.Background(), &sql.TxOptions{ReadOnly: true})
	if e != nil {
		return e
	}
	defer tx.Rollback()
	cols, e := columns(tx, "transcript_events")
	if e != nil {
		return e
	}
	if !cols["event_json"] {
		return errors.New("unrecognized OpenClaw transcript schema")
	}
	blob := "NULL"
	if cols["event_zstd"] {
		blob = "event_zstd"
	}
	rows, e := tx.Query("SELECT session_id,event_json," + blob + " FROM transcript_events ORDER BY session_id,seq")
	if e != nil {
		return e
	}
	for rows.Next() {
		var session string
		var raw, z []byte
		if e = rows.Scan(&session, &raw, &z); e != nil {
			break
		}
		if len(z) > 0 {
			raw, e = decoder.DecodeAll(z, nil)
			if e != nil {
				break
			}
		}
		if e = c.clawRecord(raw, &session, emit, nil); e != nil {
			break
		}
	}
	readErr := rows.Err()
	rows.Close()
	if e != nil {
		return e
	}
	if readErr != nil {
		return readErr
	}
	if e = c.clawCompletions(tx, emit); e != nil {
		return e
	}
	for _, table := range []string{"session_transcript_archives", "session_transcript_cold_archives", "session_transcript_cold_archive_chunks"} {
		exist, e := tableExists(tx, table)
		if e != nil {
			return e
		}
		if !exist {
			continue
		}
		// Reclaimed or rotated generations can coexist with their JSONL projection.
		query := "SELECT session_id,archive_name,archive_sha256,archive_blob FROM " + table
		if table == "session_transcript_cold_archives" {
			chunks, err := tableExists(tx, "session_transcript_cold_archive_chunks")
			if err != nil {
				return err
			}
			if chunks {
				query += " AS a WHERE NOT EXISTS (SELECT 1 FROM session_transcript_cold_archive_chunks c WHERE c.session_id=a.session_id)"
			}
		}
		rows, e := tx.Query(query)
		if e != nil {
			return e
		}
		for rows.Next() {
			var session, name, expected string
			var b []byte
			if e = rows.Scan(&session, &name, &expected, &b); e != nil {
				break
			}
			if b == nil {
				if filepath.Base(name) != name {
					e = errors.New("invalid OpenClaw archive name")
					break
				}
				if table == "session_transcript_cold_archives" && strings.HasSuffix(name, ".manifest.json") {
					continue
				}
				for _, dir := range []string{filepath.Join(filepath.Dir(path), "..", "sessions", "cold"), filepath.Join(filepath.Dir(path), "..", "sessions")} {
					b, e = os.ReadFile(filepath.Join(dir, name))
					if e == nil {
						break
					}
				}
				if e != nil {
					break
				}
			}
			if fmt.Sprintf("%x", sha256.Sum256(b)) != expected {
				e = errors.New("OpenClaw archive SHA-256 mismatch")
				break
			}
			var in io.Reader = bytes.NewReader(b)
			if len(b) >= 4 && bytes.Equal(b[:4], []byte{0x28, 0xb5, 0x2f, 0xfd}) {
				if e = decoder.Reset(in); e != nil {
					break
				}
				in = decoder
			}
			if e = c.clawLines(in, session, emit); e != nil {
				break
			}
		}
		readErr = rows.Err()
		rows.Close()
		if e != nil {
			return e
		}
		if readErr != nil {
			return readErr
		}
	}
	return tx.Commit()
}
