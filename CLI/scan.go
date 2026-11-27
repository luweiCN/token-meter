package main

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"
)

type source struct{ path, kind string }

const retiredCheckpoint = "retired-checkpoint:"

const samplePriority = "(file LIKE '%.sqlite') DESC, " +
	"(file LIKE '%.checkpoint.________-____-____-____-____________.jsonl%'), " +
	"(file GLOB '*.jsonl.imported-[0-9]*'), file"

func rootDir(env, fallback string) string {
	if p := os.Getenv(env); p != "" {
		return p
	}
	return fallback
}
func walk(root string, visit func(string, fs.DirEntry) error) error {
	if _, e := os.Stat(root); os.IsNotExist(e) {
		return nil
	} else if e != nil {
		return e
	}
	return filepath.WalkDir(root, func(path string, d fs.DirEntry, e error) error {
		if e != nil {
			return e
		}
		return visit(path, d)
	})
}
func (s *Store) discover() ([]source, error) {
	var out []source
	claw := s.setting("openclaw", rootDir("OPENCLAW_STATE_DIR", filepath.Join(s.home, ".openclaw")))
	hermes := s.setting("hermes", rootDir("HERMES_HOME", filepath.Join(s.home, ".hermes")))
	agents := filepath.Join(claw, "agents")
	e := walk(agents, func(path string, d fs.DirEntry) error {
		rel, _ := filepath.Rel(agents, path)
		p := strings.Split(filepath.ToSlash(rel), "/")
		if d.IsDir() {
			if len(p) == 3 && p[1] == "agent" && p[2] == "codex-home" {
				if err := privateClawRollouts(path, &out); err != nil {
					return err
				}
				return filepath.SkipDir
			}
			if len(p) >= 2 && !(len(p) == 2 && (p[1] == "agent" || p[1] == "sessions" || p[1] == clawImportDirectory)) {
				return filepath.SkipDir
			}
			return nil
		}
		if !d.Type().IsRegular() || len(p) != 3 {
			return nil
		}
		name := d.Name()
		if (p[1] == "agent" && name == "openclaw-agent.sqlite") || (p[1] == "sessions" && clawSessionID(name) != "") {
			out = append(out, source{path, "claw"})
		} else if p[1] == clawImportDirectory && clawImportStem(name) != "" {
			out = append(out, source{path, "claw-import"})
		}
		return nil
	})
	if e != nil {
		return nil, e
	}
	addHermes := func(path string) error {
		if st, e := os.Stat(path); e == nil && st.Mode().IsRegular() {
			out = append(out, source{path, "hermes"})
		} else if e != nil && !os.IsNotExist(e) {
			return e
		}
		return nil
	}
	if e = addHermes(filepath.Join(hermes, "state.db")); e != nil {
		return nil, e
	}
	profiles, e := os.ReadDir(filepath.Join(hermes, "profiles"))
	if e != nil && !os.IsNotExist(e) {
		return nil, e
	}
	for _, p := range profiles {
		if p.IsDir() {
			if e = addHermes(filepath.Join(hermes, "profiles", p.Name(), "state.db")); e != nil {
				return nil, e
			}
		}
	}
	if runtime.GOOS == "linux" {
		for _, directory := range []string{"sessions", "archived_sessions"} {
			err := walk(filepath.Join(s.home, ".codex", directory), func(path string, entry fs.DirEntry) error {
				if entry.Type().IsRegular() && strings.HasPrefix(entry.Name(), "rollout-") && filepath.Ext(path) == ".jsonl" {
					out = append(out, source{path, "codex"})
				}
				return nil
			})
			if err != nil {
				return nil, err
			}
		}
	}
	return out, nil
}
func fingerprint(path, revision string) (string, error) {
	st, e := os.Stat(path)
	if e != nil {
		return "", e
	}
	result := fmt.Sprintf("%s:%d:%d", revision, st.Size(), st.ModTime().UnixNano())
	if strings.HasSuffix(path, ".db") || strings.HasSuffix(path, ".sqlite") {
		if wal, e := os.Stat(path + "-wal"); e == nil {
			result += fmt.Sprintf(":%d:%d", wal.Size(), wal.ModTime().UnixNano())
		} else if !os.IsNotExist(e) {
			return "", e
		}
	}
	return result, nil
}
func (s *Store) index(src source, cat catalog, imports *clawImportOrigins) error {
	compressed := src.kind == "claw" && filepath.Ext(src.path) == ".zst"
	revision := "v1:" + cat.fingerprint
	if src.kind == "codex" {
		revision = "codex:" + revision
	} else if src.kind != "hermes" {
		revision = "claw-turns:" + revision
	}
	if compressed {
		// Older builds could cache a binary frame as an incomplete JSONL line.
		revision = "zstd:" + revision
	}
	name := filepath.Base(src.path)
	checkpoint := isClawCheckpoint(name)
	if checkpoint {
		// Historical readers could use the checkpoint UUID in a headerless event ID.
		revision = "checkpoint:" + revision
	}
	fp, e := fingerprint(src.path, revision)
	if e != nil {
		return e
	}
	var old string
	e = s.db.QueryRow("SELECT fingerprint FROM indexed_sources WHERE file=?", src.path).Scan(&old)
	if e == nil && old == fp {
		return nil
	}
	if e != nil && !errors.Is(e, sql.ErrNoRows) {
		return e
	}
	tx, e := s.db.Begin()
	if e != nil {
		return e
	}
	defer tx.Rollback()
	lines := src.kind == "claw" && filepath.Ext(src.path) != ".sqlite" && !compressed
	// Hermes reports revisable session totals and residuals. OpenClaw reports
	// billed requests that can outlive every transcript containing them.
	changed := src.kind == "hermes" || src.kind == "codex"
	if changed {
		if _, e = tx.Exec("DELETE FROM samples WHERE file=?", src.path); e != nil {
			return e
		}
	}
	if compressed && old != "" {
		if _, e = tx.Exec("DELETE FROM source_cursors WHERE file=?", src.path); e != nil {
			return e
		}
	}
	var repair *checkpointIDRepair
	legacy := strings.TrimPrefix(old, retiredCheckpoint)
	if checkpoint && src.kind == "claw" && (strings.HasPrefix(legacy, "v1:") || strings.HasPrefix(legacy, "zstd:v1:")) {
		scope, _, _ := strings.Cut(name, ".jsonl")
		repair = &checkpointIDRepair{scope, func(id string) error {
			res, err := tx.Exec("DELETE FROM samples WHERE file=? AND id=? AND agent='openclaw'", src.path, id)
			if err != nil {
				return err
			}
			n, err := res.RowsAffected()
			changed = changed || n != 0
			return err
		}}
	}
	const columns = "(day,agent,model,input,output,hit,written,cost,unknown_cost,events)"
	const incoming = "(excluded.day,excluded.agent,excluded.model,excluded.input,excluded.output,excluded.hit,excluded.written,excluded.cost,excluded.unknown_cost,excluded.events)"
	st, e := tx.Prepare("INSERT INTO samples VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(file,id) DO UPDATE SET " +
		columns + "=" + incoming + " WHERE " + columns + " IS NOT " + incoming)
	if e != nil {
		return e
	}
	defer st.Close()
	evidence, e := tx.Prepare(upsertClawEvidence)
	if e != nil {
		return e
	}
	defer evidence.Close()
	identity, e := tx.Prepare("INSERT INTO claw_identities VALUES(?,?) ON CONFLICT(id) DO UPDATE SET turn=excluded.turn WHERE turn!=excluded.turn")
	if e != nil {
		return e
	}
	defer identity.Close()
	var delta *clawAggregateDelta
	var unchanged *sql.Stmt
	if !changed && repair == nil {
		cached, err := readCachedBuckets(tx.QueryRow("SELECT buckets FROM local_aggregate WHERE id=1"))
		if err != nil {
			return err
		}
		if cached != nil {
			winner, err := tx.Prepare("SELECT day,agent,model,input,output,hit,written,cost,unknown_cost,events FROM samples WHERE id=? ORDER BY " + samplePriority + " LIMIT 1")
			if err != nil {
				return err
			}
			defer winner.Close()
			delta = &clawAggregateDelta{tx: tx, cache: bucketMap{}, winner: winner, ids: map[string]bool{}, turns: map[string]bool{}}
			for _, row := range cached {
				delta.cache.addBucket(row, 1)
			}
			unchanged, err = tx.Prepare("SELECT 1 FROM samples s WHERE file=? AND id=? AND " + columns + " IS (?,?,?,?,?,?,?,?,?,?) " +
				"AND (?=0 OR EXISTS(SELECT 1 FROM claw_evidence e WHERE e.file=s.file AND e.id=s.id AND (e.rank,e.response,e.complete,e.actual_cost) IS (?,?,?,?))) " +
				"AND (?='' OR EXISTS(SELECT 1 FROM claw_identities i WHERE i.id=s.id AND i.turn=?))")
			if err != nil {
				return err
			}
			defer unchanged.Close()
		}
	}
	emit := func(x sample) error {
		cost := int64(0)
		if x.sourceCost {
			cost = x.CostMicros
		}
		response := clawResponseID(x)
		wantEvidence := x.clawTurn != "" || response != ""
		rank := x.clawRank
		if rank == 0 {
			rank = clawMirror
		}
		args := []any{src.path, x.id, x.day, x.agent, x.model, x.Input, x.Output, x.CacheRead, x.CacheWrite, x.CostMicros, x.UnknownCost, x.Events}
		if delta != nil {
			var one int
			err := unchanged.QueryRow(append(args, wantEvidence, rank, response, x.clawComplete, cost, x.clawTurn, x.clawTurn)...).Scan(&one)
			if err == nil {
				return nil
			}
			if !errors.Is(err, sql.ErrNoRows) {
				return err
			}
			if err = delta.before(x); err != nil {
				return err
			}
		}
		res, err := st.Exec(args...)
		if err != nil {
			return err
		}
		n, err := res.RowsAffected()
		if err != nil {
			return err
		}
		changed = changed || n != 0
		if !wantEvidence {
			return nil
		}
		for _, id := range []string{x.id, response} {
			if id != "" && x.clawTurn != "" {
				if _, err = identity.Exec(id, x.clawTurn); err != nil {
					return err
				}
			}
		}
		res, err = evidence.Exec(src.path, x.id, rank, response, x.clawComplete, cost)
		if err != nil {
			return err
		}
		n, err = res.RowsAffected()
		changed = changed || n != 0
		return err
	}
	if lines {
		e = s.indexLines(tx, src, cat, old, revision, emit, repair)
	} else if src.kind == "codex" {
		e = cat.readCodexRollout(src.path, true, func(call clawCodexCall) error {
			x := call.sample
			x.agent, x.id = "codex", digest("codex", call.id)
			return emit(x)
		})
	} else if src.kind == "claw-codex" {
		e = cat.clawCodexRollout(src.path, func(call clawCodexCall) error {
			x := call.sample
			x.clawResponse, x.clawComplete = call.response, call.complete
			if call.rolloutID != "" && (call.turn != "" || call.response == "") {
				x.id = call.rolloutID
				if call.response != "" {
					// A reset can reuse a cumulative position in another copy. Two
					// different provider responses always remain two requests.
					var reused bool
					err := tx.QueryRow("SELECT EXISTS(SELECT 1 FROM claw_evidence WHERE id=? AND rank=? AND response!='' AND response!=?)",
						x.id, clawRequest, clawResponseID(x)).Scan(&reused)
					if err != nil {
						return err
					}
					if reused {
						x.id = call.id
					}
				}
			}
			x.clawTurn, x.clawRank = clawTurnKey(call.thread, call.turn), clawRequest
			return emit(x)
		})
	} else if src.kind == "claw-import" {
		e = cat.clawImportedFile(src.path, imports, emit)
	} else if src.kind == "claw" {
		e = cat.clawFile(src.path, emit, repair)
	} else {
		e = hermesFile(src.path, emit)
	}
	if e != nil {
		return e
	}
	if old == "" {
		_, e = tx.Exec("INSERT INTO indexed_sources VALUES(?,?)", src.path, fp)
	} else {
		_, e = tx.Exec("UPDATE indexed_sources SET fingerprint=? WHERE file=?", fp, src.path)
	}
	if e != nil {
		return e
	}
	if delta != nil && (changed || old == "") {
		if e = delta.finish(); e != nil {
			return e
		}
		buckets, err := json.Marshal(delta.cache.buckets())
		if err != nil {
			return err
		}
		_, e = tx.Exec("INSERT INTO local_aggregate VALUES(1,?) ON CONFLICT(id) DO UPDATE SET buckets=excluded.buckets", buckets)
	} else if changed {
		_, e = tx.Exec("DELETE FROM local_aggregate WHERE id=1")
	}
	if e != nil {
		return e
	}
	return tx.Commit()
}

func readCachedBuckets(row *sql.Row) ([]Bucket, error) {
	var raw []byte
	if err := row.Scan(&raw); errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	} else if err != nil {
		return nil, err
	}
	var buckets []Bucket
	// A missing, null or unreadable projection can be rebuilt from the ledger.
	if len(raw) == 0 || json.Unmarshal(raw, &buckets) != nil {
		return nil, nil
	}
	return buckets, nil
}

func bucketRows(db *sql.DB, query string) ([]Bucket, error) {
	rows, e := db.Query(query)
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	out := []Bucket{}
	for rows.Next() {
		var b Bucket
		if e = rows.Scan(&b.Day, &b.Agent, &b.Model, &b.Input, &b.Output, &b.CacheRead, &b.CacheWrite, &b.CostMicros, &b.UnknownCost, &b.UnknownTokens, &b.Events, &b.Credits); e != nil {
			return nil, e
		}
		out = append(out, b)
	}
	return out, rows.Err()
}
func lockScan(dir string, wait time.Duration) (func(), error) {
	// Independent writer lock keeps network queries responsive during a historical import.
	guard, e := sql.Open("sqlite", sqlitePath(filepath.Join(dir, "scan-lock.sqlite"))+fmt.Sprintf("?_txlock=immediate&_pragma=busy_timeout(%d)", wait.Milliseconds()))
	if e != nil {
		return nil, e
	}
	lock, e := guard.Begin()
	if e != nil {
		guard.Close()
		return nil, fmt.Errorf("another scan is running: %w", e)
	}
	return func() { lock.Rollback(); guard.Close() }, nil
}

func (s *Store) scan() error {
	unlock, e := lockScan(s.dir, 500*time.Millisecond)
	if e != nil {
		return e
	}
	defer unlock()
	cat, e := prices(s.home)
	if e != nil {
		return e
	}
	sources, e := s.discover()
	if e != nil {
		return e
	}
	present := map[string]bool{}
	var failures []error
	var imports clawImportOrigins
	for _, src := range sources {
		present[src.path] = true
		if e = s.index(src, cat, &imports); e != nil {
			failures = append(failures, fmt.Errorf("%s: %w", filepath.Base(src.path), e))
		}
	}
	rows, e := s.db.Query("SELECT file FROM indexed_sources WHERE fingerprint NOT LIKE ?", retiredCheckpoint+"%")
	if e != nil {
		return e
	}
	var missing []string
	for rows.Next() {
		var path string
		if e = rows.Scan(&path); e != nil {
			rows.Close()
			return e
		}
		if !present[path] {
			missing = append(missing, path)
		}
	}
	e = rows.Err()
	rows.Close()
	if e != nil {
		return e
	}
	for _, path := range missing {
		tx, e := s.db.Begin()
		if e != nil {
			return e
		}
		removed, deleteErr := tx.Exec("DELETE FROM samples WHERE file=? AND agent != 'openclaw'", path)
		e = deleteErr
		if e == nil {
			var n int64
			n, e = removed.RowsAffected()
			if e == nil && n != 0 {
				_, e = tx.Exec("DELETE FROM local_aggregate WHERE id=1")
			}
		}
		if e == nil && filepath.Base(filepath.Dir(path)) == "sessions" && isClawCheckpoint(filepath.Base(path)) {
			// Keep evidence that this unavailable file still needs a one-time ID repair.
			_, e = tx.Exec("UPDATE indexed_sources SET fingerprint=? || fingerprint WHERE file=? AND (fingerprint LIKE 'v1:%' OR fingerprint LIKE 'zstd:v1:%')", retiredCheckpoint, path)
		}
		if e == nil {
			_, e = tx.Exec("DELETE FROM indexed_sources WHERE file=? AND fingerprint NOT LIKE ?", path, retiredCheckpoint+"%")
		}
		if e == nil {
			_, e = tx.Exec("DELETE FROM source_cursors WHERE file=?", path)
		}
		if e == nil {
			e = tx.Commit()
		} else {
			tx.Rollback()
		}
		if e != nil {
			return e
		}
	}
	// A restored or rotated conversation and the 2.0 SQLite mirror can contain the same generation.
	b, e := readCachedBuckets(s.db.QueryRow("SELECT buckets FROM local_aggregate WHERE id=1"))
	if e != nil {
		return e
	}
	if b == nil {
		b, e = bucketRows(s.db, `WITH unique_events AS (SELECT *,row_number() OVER (PARTITION BY id ORDER BY `+samplePriority+`) AS n FROM samples
 WHERE id NOT IN (`+groupedClawIDs+`))
 SELECT day,agent,model,sum(input),sum(output),sum(hit),sum(written),sum(cost),sum(unknown_cost),0,sum(events),0 FROM unique_events WHERE n=1 GROUP BY day,agent,model`)
		if e != nil {
			return e
		}
		grouped, err := allClawUsage(s.db)
		if err != nil {
			return err
		}
		if len(grouped) != 0 {
			sums := bucketMap{}
			for _, row := range b {
				sums.addBucket(row, 1)
			}
			for _, row := range grouped {
				sums.addBucket(row, 1)
			}
			b = sums.buckets()
		}
		cached, e := json.Marshal(b)
		if e != nil {
			return e
		}
		if _, e = s.db.Exec("INSERT OR REPLACE INTO local_aggregate VALUES(1,?)", cached); e != nil {
			return e
		}
	}
	path := filepath.Join(s.home, ".token-meter", "tokenmeter.sqlite")
	if _, err := os.Stat(path); err == nil {
		local, err := readDB(path)
		if err != nil {
			return err
		}
		defer local.Close()
		legacy, err := bucketRows(local, `SELECT usage_date,provider_id,model_canonical,sum(tokens_input),sum(tokens_output),sum(tokens_cache_read),sum(tokens_cache_write_5m+tokens_cache_write_1h),sum(cost_usd_micros),sum(cost_unknown_events),sum(token_unreported_events),sum(events_count),sum(credits_picos) FROM daily_rollup WHERE provider_id NOT IN ('openclaw','hermes') GROUP BY usage_date,provider_id,model_canonical`)
		if err != nil {
			return fmt.Errorf("desktop usage ledger: %w", err)
		}
		b = append(b, legacy...)
	} else if !os.IsNotExist(err) {
		return err
	}
	sort.Slice(b, func(i, j int) bool {
		a, c := b[i], b[j]
		if a.Day != c.Day {
			return a.Day < c.Day
		}
		if a.Agent != c.Agent {
			return a.Agent < c.Agent
		}
		return a.Model < c.Model
	})
	if e = s.writeSnapshot(func(snap *Snapshot) error {
		quotas, err := s.readQuotas()
		if err != nil {
			return err
		}
		snap.Buckets, snap.Quotas, snap.PartialSources = b, quotas, len(failures)
		return nil
	}); e != nil {
		return e
	}
	if e = s.writeReport(); e != nil {
		return e
	}
	if len(failures) > 0 {
		return fmt.Errorf("%d sources failed; first: %w", len(failures), failures[0])
	}
	return nil
}
func (s *Store) writeReport() error {
	// Serialize publication across daemon and ad-hoc CLI scans so a slower
	// reader cannot replace a more recent menu snapshot.
	tx, e := s.db.Begin()
	if e != nil {
		return e
	}
	defer tx.Rollback()
	snaps, e := s.snapshots()
	if e != nil {
		return e
	}
	summary, e := dailyMenuSummary(day(time.Now()), s.id, snaps)
	if e != nil {
		return e
	}
	return atomicJSON(filepath.Join(s.dir, "summary.json"), summary)
}

type menuDevice struct {
	Device
	Active bool `json:"active"`
}

type menuAgent struct {
	ID        string `json:"id"`
	LocalOnly bool   `json:"localOnly"`
	Tokens    int64  `json:"tokens"`
	Counts
}

type menuModel struct {
	Model string `json:"model"`
	menuUsage
}

type menuSummary struct {
	Day     string       `json:"day"`
	Devices []menuDevice `json:"devices"`
	Agents  []*menuAgent `json:"agents"`
	Models  []menuModel  `json:"models"`
	History menuHistory  `json:"history"`
}

type menuUsage struct {
	Tokens     int64 `json:"tokens"`
	HasCredits bool  `json:"hasCredits,omitempty"`
	Counts
}

func menuUsageFor(counts Counts) menuUsage {
	return menuUsage{Tokens: counts.tokens(), Counts: counts}
}

func (u *menuUsage) addBucket(counts Counts) {
	u.HasCredits = u.HasCredits || counts.Credits > 0
	counts.Credits = 0 // Credits from independent wallets cannot be added.
	u.Counts.add(counts)
	u.Tokens = u.Counts.tokens()
}

type menuDay struct {
	menuUsage
	SessionsIncomplete bool                 `json:"sessionsIncomplete,omitempty"`
	Models             []menuModel          `json:"models"`
	Devices            map[string]menuUsage `json:"devices"`
}

type menuHistory struct {
	Total menuUsage          `json:"total"`
	Month menuUsage          `json:"month"`
	Week  menuUsage          `json:"week"`
	Days  map[string]menuDay `json:"days"`
}

func dailyMenuSummary(today, localID string, snapshots []Snapshot) (menuSummary, error) {
	date, err := time.Parse(time.DateOnly, today)
	if err != nil {
		return menuSummary{}, err
	}
	monthStart := today[:7] + "-01"
	weekStart := date.AddDate(0, 0, -((int(date.Weekday()) + 6) % 7)).Format(time.DateOnly)
	summary := menuSummary{Day: today, Devices: []menuDevice{}, Agents: []*menuAgent{}, Models: []menuModel{}}
	agents := map[string]*menuAgent{}
	type dayCounts struct {
		Counts
		models             map[string]menuUsage
		devices            map[string]menuUsage
		sessionsIncomplete bool
	}
	days := map[string]*dayCounts{}
	var total, month, week Counts
	// replicas has one signed, current snapshot per origin, even when multiple peers relay it.
	for _, snap := range snapshots {
		device := menuDevice{Device: Device{
			ID: snap.Origin, Name: snap.Name, OS: snap.OS, Local: snap.Origin == localID,
			Observed: snap.Observed, PartialSources: snap.PartialSources,
		}}
		for _, b := range snap.Buckets {
			counts := b.Counts
			counts.Credits = 0 // Only per-agent rows can report credits from the same wallet.
			var valid bool
			total, valid = total.checkedSum(counts)
			if !valid {
				return menuSummary{}, errors.New("combined device totals exceed supported range")
			}
			// All other rollups add subsets of the checked, nonnegative device totals.
			if b.Day >= weekStart && b.Day <= today {
				week.add(counts)
			}
			if b.Day >= monthStart && b.Day <= today {
				month.add(counts)
				usage := days[b.Day]
				if usage == nil {
					usage = &dayCounts{models: map[string]menuUsage{}, devices: map[string]menuUsage{}}
					days[b.Day] = usage
				}
				usage.add(counts)
				if b.Counts.hasUsage() {
					model := usage.models[b.Model]
					model.addBucket(b.Counts)
					usage.models[b.Model] = model
					deviceDay := usage.devices[snap.Origin]
					deviceDay.addBucket(b.Counts)
					usage.devices[snap.Origin] = deviceDay
				}
				if !device.Local || b.Agent == "openclaw" || b.Agent == "hermes" {
					usage.sessionsIncomplete = true
				}
			}

			if b.Day != today {
				continue
			}
			device.Counts.add(counts)
			if b.tokens() == 0 && b.CostMicros == 0 && b.Credits == 0 && !(b.UnknownTokens > 0 && b.Events > 0) {
				continue
			}
			device.Active = true
			agent := agents[b.Agent]
			if agent == nil {
				agent = &menuAgent{ID: b.Agent, LocalOnly: true}
				agents[b.Agent] = agent
				summary.Agents = append(summary.Agents, agent)
			}
			agent.LocalOnly = agent.LocalOnly && device.Local
			agent.Counts, valid = agent.Counts.checkedSum(b.Counts)
			if !valid {
				return menuSummary{}, errors.New("daily agent counts are outside the supported range")
			}
			agent.Tokens = agent.Counts.tokens()
		}
		device.Tokens = device.Counts.tokens()
		summary.Devices = append(summary.Devices, device)
	}
	sort.Slice(summary.Agents, func(i, j int) bool {
		a, b := summary.Agents[i], summary.Agents[j]
		if a.Tokens != b.Tokens {
			return a.Tokens > b.Tokens
		}
		return a.ID < b.ID
	})
	summary.History = menuHistory{
		Total: menuUsageFor(total),
		Month: menuUsageFor(month),
		Week:  menuUsageFor(week),
		Days:  make(map[string]menuDay, len(days)),
	}
	for date, usage := range days {
		models := make([]menuModel, 0, len(usage.models))
		for model, amount := range usage.models {
			models = append(models, menuModel{Model: model, menuUsage: amount})
		}
		sort.Slice(models, func(i, j int) bool { return models[i].Model < models[j].Model })
		summary.History.Days[date] = menuDay{
			menuUsage:          menuUsageFor(usage.Counts),
			SessionsIncomplete: usage.sessionsIncomplete,
			Models:             models,
			Devices:            usage.devices,
		}
		if date == today {
			summary.Models = models
		}
	}
	return summary, nil
}

func day(t time.Time) string { return t.In(time.Local).Format(time.DateOnly) }
