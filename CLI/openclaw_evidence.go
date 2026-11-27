package main

import (
	"database/sql"
	"errors"
	"io/fs"
	"path/filepath"
	"strings"
)

const (
	clawMirror = iota + 1
	clawTrace
	clawRequest
)

const clawEvidenceSchema = `
CREATE TABLE IF NOT EXISTS claw_identities(id TEXT PRIMARY KEY, turn TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS claw_identity_turn ON claw_identities(turn,id);
CREATE TRIGGER IF NOT EXISTS claw_response_turn BEFORE UPDATE OF turn ON claw_identities WHEN old.turn!=new.turn
 BEGIN SELECT RAISE(ABORT,'conflicting OpenClaw response turn'); END;
CREATE TABLE IF NOT EXISTS claw_evidence (
 file TEXT NOT NULL, id TEXT NOT NULL, rank INTEGER NOT NULL,
 response TEXT NOT NULL, complete INTEGER NOT NULL, actual_cost INTEGER NOT NULL,
 PRIMARY KEY(file,id));
CREATE INDEX IF NOT EXISTS claw_evidence_response ON claw_evidence(response,id) WHERE response!='';
CREATE INDEX IF NOT EXISTS claw_evidence_id ON claw_evidence(id,response);
DELETE FROM local_aggregate;
PRAGMA user_version=2;`

func privateClawRollouts(home string, out *[]source) error {
	for _, dir := range []string{"sessions", "archived_sessions"} {
		err := walk(filepath.Join(home, dir), func(path string, entry fs.DirEntry) error {
			name := entry.Name()
			if entry.Type().IsRegular() && strings.HasPrefix(name, "rollout-") && strings.HasSuffix(name, ".jsonl") {
				*out = append(*out, source{path, "claw-codex"})
			}
			return nil
		})
		if err != nil {
			return err
		}
	}
	return nil
}

func clawResponseID(x sample) string {
	if x.clawResponse == "" {
		return ""
	}
	return digest("openclaw", "openai", x.clawResponse)
}

const upsertClawEvidence = `INSERT INTO claw_evidence(file,id,rank,response,complete,actual_cost)
 VALUES(?,?,?,?,?,?) ON CONFLICT(file,id) DO UPDATE SET
 (rank,response,complete,actual_cost)=(excluded.rank,excluded.response,excluded.complete,excluded.actual_cost)
 WHERE (rank,response,complete,actual_cost) IS NOT (excluded.rank,excluded.response,excluded.complete,excluded.actual_cost)`

const linkedClawIDs = `SELECT e.id FROM claw_evidence e JOIN claw_identities i ON i.id=e.response WHERE e.response!=''`
const groupedClawIDs = `SELECT id FROM claw_identities UNION ` + linkedClawIDs

type clawQuery interface {
	Query(string, ...any) (*sql.Rows, error)
}

type clawObservation struct {
	Bucket
	id, response string
	rank         int
	actual       int64
	complete     bool
}

// A response ID can still occur in a retired transcript without a turn tag.
// Associate it through any verified copy, without changing the historical row.
func clawTurnUsage(db clawQuery, turn string) ([]Bucket, error) {
	const query = `WITH ids AS (SELECT id FROM claw_identities WHERE turn=? UNION ` + linkedClawIDs + ` AND i.turn=?)
 SELECT s.id,s.day,s.agent,s.model,s.input,s.output,s.hit,s.written,s.cost,s.unknown_cost,s.events,
 COALESCE(e.rank,1),COALESCE(e.response,''),COALESCE(e.complete,0),COALESCE(e.actual_cost,0)
 FROM ids JOIN samples s ON s.id=ids.id LEFT JOIN claw_evidence e ON e.id=s.id AND e.file=s.file ORDER BY `
	rows, err := db.Query(query+strings.ReplaceAll(samplePriority, "file", "s.file")+",s.id", turn, turn)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var records []clawObservation
	for rows.Next() {
		var r clawObservation
		err := rows.Scan(&r.id, &r.Day, &r.Agent, &r.Model, &r.Input, &r.Output, &r.CacheRead, &r.CacheWrite,
			&r.CostMicros, &r.UnknownCost, &r.Events, &r.rank, &r.response, &r.complete, &r.actual)
		if err != nil {
			return nil, err
		}
		if !r.Counts.valid() {
			return nil, errors.New("invalid stored OpenClaw usage")
		}
		records = append(records, r)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return selectClawUsage(records)
}

func sameClawRequest(a, b clawObservation) bool {
	return a.Model == b.Model && a.Input == b.Input && a.Output == b.Output && a.CacheRead == b.CacheRead && a.CacheWrite == b.CacheWrite
}

func clawObservationTokens(records []clawObservation) (int64, error) {
	var total Counts
	for _, r := range records {
		var ok bool
		if total, ok = total.checkedSum(r.Counts); !ok {
			return 0, errors.New("OpenClaw turn counters overflow")
		}
	}
	return total.tokens(), nil
}

func selectClawUsage(records []clawObservation) ([]Bucket, error) {
	// New rollouts expose both the provider response ID and the thread's
	// cumulative position. Earlier copies may retain only one of those keys.
	aliases := map[string]string{}
	for _, r := range records {
		if r.rank == clawRequest && r.response != "" {
			if prior := aliases[r.id]; prior != "" && prior != r.response {
				return nil, errors.New("conflicting OpenClaw response identities")
			}
			aliases[r.id] = r.response
		}
	}
	var requests, fallbacks []clawObservation
	perRequest := map[string]int{}
	for _, r := range records {
		if r.rank != clawRequest {
			fallbacks = append(fallbacks, r)
			continue
		}
		key := r.id
		if response := aliases[key]; response != "" {
			key = response
			r.response = response
		}
		if idx, ok := perRequest[key]; ok {
			old := requests[idx]
			if (old.tokens() == 0 && r.tokens() > 0) || (old.tokens() == r.tokens() && r.complete && !old.complete) {
				requests[idx] = r
			}
		} else {
			perRequest[key] = len(requests)
			requests = append(requests, r)
		}
	}
	// An explicitly different provider response proves an additional call even
	// when the private rollout ends early. An unidentified request cannot.
	known := map[string]bool{}
	for _, r := range requests {
		known[r.response] = true
	}
	named := map[string]bool{}
	var mirrors []clawObservation
	for _, r := range fallbacks {
		if r.rank != clawMirror || r.response == "" || named[r.response] || (r.tokens() == 0 && r.actual == 0) {
			continue
		}
		mirrors = append(mirrors, r)
		named[r.response] = true
		if len(known) != 0 && !known[""] && !known[r.response] {
			requests = append(requests, r)
			known[r.response] = true
		}
	}
	requestTotal, err := clawObservationTokens(requests)
	if err != nil {
		return nil, err
	}
	if len(mirrors) > 1 && (len(requests) == 0 || known[""]) {
		total, err := clawObservationTokens(mirrors)
		if err != nil {
			return nil, err
		}
		if total > requestTotal {
			requests, requestTotal = mirrors, total
		}
	}
	best := -1
	for i, r := range fallbacks {
		if best == -1 || preferClawFallback(r, fallbacks[best], len(requests) > 0) {
			best = i
		}
	}
	selected := requests
	if best >= 0 && (len(requests) == 0 || requestTotal < fallbacks[best].tokens()) {
		// Even a contiguous prefix need not reach the turn's final response.
		selected = []clawObservation{fallbacks[best]}
	}
	// Matching upstream costs replace the estimate for exactly one request.
	// Prefer explicit identity over a unique model and four-counter match.
	matchQuality := make([]int, len(selected))
	for _, source := range records {
		if source.actual <= 0 {
			continue
		}
		match, quality, ties := -1, 0, 0
		for i, r := range selected {
			q := 0
			if r.id == source.id || (r.response != "" && (r.response == source.response || r.response == source.id)) || (source.response != "" && source.response == r.id) {
				q = 2
			} else if (r.response == "" || source.response == "" || r.response == source.response) && sameClawRequest(r, source) {
				q = 1
			}
			if q > quality {
				match, quality, ties = i, q, 1
			} else if q != 0 && q == quality {
				ties++
			}
		}
		if match >= 0 && ties == 1 {
			priority := quality*4 + source.rank
			if priority > matchQuality[match] {
				selected[match].CostMicros, selected[match].UnknownCost = source.actual, 0
				matchQuality[match] = priority
			}
		}
	}
	buckets := make([]Bucket, 0, len(selected))
	for _, r := range selected {
		buckets = append(buckets, r.Bucket)
	}
	return buckets, nil
}

func preferClawFallback(a, b clawObservation, requestPrefix bool) bool {
	x, y := a.tokens(), b.tokens()
	if (x == 0) != (y == 0) {
		return x > y
	}
	if requestPrefix && x != y {
		return x > y
	}
	return a.rank > b.rank
}

func allClawUsage(db *sql.DB) ([]Bucket, error) {
	rows, err := db.Query("SELECT DISTINCT turn FROM claw_identities ORDER BY turn")
	if err != nil {
		return nil, err
	}
	var turns []string
	for rows.Next() {
		var turn string
		if err := rows.Scan(&turn); err != nil {
			rows.Close()
			return nil, err
		}
		turns = append(turns, turn)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return nil, err
	}
	var buckets []Bucket
	for _, turn := range turns {
		group, err := clawTurnUsage(db, turn)
		if err != nil {
			return nil, err
		}
		buckets = append(buckets, group...)
	}
	return buckets, nil
}

// Existing append cursors update the cached daily aggregate rather than
// sorting the entire historical ledger. A turn is the unit of replacement.
type clawAggregateDelta struct {
	tx     *sql.Tx
	cache  bucketMap
	winner *sql.Stmt
	ids    map[string]bool
	turns  map[string]bool
}

func (d *clawAggregateDelta) owner(id string) (string, error) {
	var turn string
	err := d.tx.QueryRow("SELECT turn FROM claw_identities WHERE id=? UNION SELECT i.turn FROM claw_evidence e JOIN claw_identities i ON i.id=e.response WHERE e.id=? AND e.response!=''", id, id).Scan(&turn)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return turn, err
}

func (d *clawAggregateDelta) group(turn string, sign int64) error {
	b, err := clawTurnUsage(d.tx, turn)
	if err != nil {
		return err
	}
	for _, row := range b {
		d.cache.addBucket(row, sign)
	}
	return nil
}

func (d *clawAggregateDelta) before(x sample) error {
	turns := []string{x.clawTurn}
	response := clawResponseID(x)
	ids := []string{x.id, response}
	if response != "" && x.clawTurn != "" && !d.ids[response] {
		rows, err := d.tx.Query("SELECT DISTINCT id FROM claw_evidence WHERE response=? AND response!=''", response)
		if err != nil {
			return err
		}
		for rows.Next() {
			var id string
			if err := rows.Scan(&id); err != nil {
				rows.Close()
				return err
			}
			ids = append(ids, id)
		}
		err = rows.Err()
		rows.Close()
		if err != nil {
			return err
		}
	}
	for _, id := range ids {
		if id == "" || d.ids[id] {
			continue
		}
		d.ids[id] = true
		existing, err := d.owner(id)
		if err != nil {
			return err
		}
		if existing == "" {
			if err = d.cache.apply(d.winner, id, -1); err != nil {
				return err
			}
		}
		turns = append(turns, existing)
	}
	for _, turn := range turns {
		if turn != "" && !d.turns[turn] {
			if err := d.group(turn, -1); err != nil {
				return err
			}
			d.turns[turn] = true
		}
	}
	return nil
}

func (d *clawAggregateDelta) finish() error {
	for id := range d.ids {
		turn, err := d.owner(id)
		if err != nil {
			return err
		}
		if turn == "" {
			if err := d.cache.apply(d.winner, id, 1); err != nil {
				return err
			}
		}
	}
	for turn := range d.turns {
		if err := d.group(turn, 1); err != nil {
			return err
		}
	}
	return nil
}
