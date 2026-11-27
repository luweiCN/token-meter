package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"sort"
	"strings"
	"time"
	"unicode"

	"github.com/luweiCN/token-meter/internal/account"
	"github.com/luweiCN/token-meter/internal/device"
	_ "modernc.org/sqlite"
)

type Counts struct {
	Input         int64 `json:"input"`
	Output        int64 `json:"output"`
	CacheRead     int64 `json:"cacheRead"`
	CacheWrite    int64 `json:"cacheWrite"`
	CostMicros    int64 `json:"costMicros"`
	UnknownCost   int64 `json:"unknownCost"`
	UnknownTokens int64 `json:"unknownTokens"`
	Events        int64 `json:"events"`
	Credits       int64 `json:"creditsPicos,string,omitempty"`
}

func (c Counts) tokens() int64  { return c.Input + c.Output + c.CacheRead + c.CacheWrite }
func (c Counts) hasUsage() bool { return c != (Counts{Events: c.Events}) }

func (c *Counts) add(o Counts) {
	c.Input += o.Input
	c.Output += o.Output
	c.CacheRead += o.CacheRead
	c.CacheWrite += o.CacheWrite
	c.CostMicros += o.CostMicros
	c.UnknownCost += o.UnknownCost
	c.UnknownTokens += o.UnknownTokens
	c.Events += o.Events
	c.Credits += o.Credits
}

func (c Counts) valid() bool {
	if c.CostMicros < 0 || c.UnknownCost < 0 || c.UnknownTokens < 0 || c.Events < 0 || c.Credits < 0 {
		return false
	}
	var tokens int64
	for _, count := range [...]int64{c.Input, c.Output, c.CacheRead, c.CacheWrite} {
		if count < 0 || count > math.MaxInt64-tokens {
			return false
		}
		tokens += count
	}
	return true
}

func (c Counts) checkedSum(other Counts) (Counts, bool) {
	if !c.valid() || !other.valid() {
		return Counts{}, false
	}
	c.add(other)
	return c, c.valid()
}

type Bucket struct {
	Day   string `json:"day"`
	Agent string `json:"agent"`
	Model string `json:"model"`
	Counts
}
type Window struct {
	ID              string   `json:"id"`
	Label           string   `json:"label"`
	Remaining       *float64 `json:"remainingPercent,omitempty"`
	ResetAt         string   `json:"resetAt,omitempty"`
	UsedAmount      string   `json:"usedAmount,omitempty"`
	RemainingAmount string   `json:"remainingAmount,omitempty"`
	TotalAmount     string   `json:"totalAmount,omitempty"`
	Unit            string   `json:"unit,omitempty"`
}
type Quota struct {
	Provider    string   `json:"provider"`
	Account     string   `json:"account"`
	Observed    string   `json:"observedAt"`
	Windows     []Window `json:"windows,omitempty"`
	Balance     string   `json:"balance,omitempty"`
	BalanceUnit string   `json:"balanceUnit,omitempty"`
}
type Snapshot struct {
	Protocol       int      `json:"protocol"`
	Origin         string   `json:"origin"`
	Name           string   `json:"name"`
	OS             string   `json:"os"`
	Revision       int64    `json:"revision"`
	Observed       int64    `json:"observed"`
	Buckets        []Bucket `json:"buckets"`
	Quotas         []Quota  `json:"quotas"`
	PartialSources int      `json:"partialSources,omitempty"`
}
type Envelope struct {
	Data      json.RawMessage `json:"data"`
	Signature []byte          `json:"signature"`
}
type Store struct {
	db            *sql.DB
	dir, home, id string
	key           ed25519.PrivateKey
}

const schema = `
CREATE TABLE IF NOT EXISTS settings(k TEXT PRIMARY KEY, v TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS peers(id TEXT PRIMARY KEY, address TEXT NOT NULL, last_ok INTEGER NOT NULL DEFAULT 0, last_error TEXT NOT NULL DEFAULT '', role TEXT NOT NULL DEFAULT 'peer');
CREATE TABLE IF NOT EXISTS replicas(id TEXT PRIMARY KEY, revision INTEGER NOT NULL, body BLOB NOT NULL);
CREATE TABLE IF NOT EXISTS indexed_sources(file TEXT PRIMARY KEY, fingerprint TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS samples(file TEXT NOT NULL, id TEXT NOT NULL, day TEXT NOT NULL, agent TEXT NOT NULL, model TEXT NOT NULL,
 input INTEGER NOT NULL, output INTEGER NOT NULL, hit INTEGER NOT NULL, written INTEGER NOT NULL, cost INTEGER NOT NULL, unknown_cost INTEGER NOT NULL, events INTEGER NOT NULL, PRIMARY KEY(file,id));
CREATE TABLE IF NOT EXISTS source_cursors(file TEXT PRIMARY KEY,offset INTEGER NOT NULL,size INTEGER NOT NULL,session TEXT NOT NULL,identity TEXT NOT NULL,anchor TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS local_aggregate(id INTEGER PRIMARY KEY, buckets BLOB NOT NULL);
CREATE INDEX IF NOT EXISTS sample_identity ON samples(id,file);`

func sqlitePath(path string) string {
	p := filepath.ToSlash(path)
	if !strings.HasPrefix(p, "/") {
		p = "/" + p
	}
	u := url.URL{Scheme: "file", Path: p}
	return u.String()
}
func readDB(path string) (*sql.DB, error) {
	d, e := sql.Open("sqlite", sqlitePath(path)+"?mode=ro&_pragma=busy_timeout(4000)&_pragma=query_only(1)")
	if e != nil {
		return nil, e
	}
	d.SetMaxOpenConns(1)
	return d, nil
}
func openStore(dir, home string) (*Store, error) {
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(filepath.Join(dir, "node.sqlite"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err = f.Chmod(0600); err != nil {
		f.Close()
		return nil, err
	}
	if err = f.Close(); err != nil {
		return nil, err
	}
	db, e := sql.Open("sqlite", sqlitePath(filepath.Join(dir, "node.sqlite"))+"?_pragma=busy_timeout(10000)&_pragma=journal_mode(WAL)&_txlock=immediate")
	if e != nil {
		return nil, e
	}
	fail := func(e error) (*Store, error) { db.Close(); return nil, e }
	var schemaVersion int
	if e = db.QueryRow("PRAGMA user_version").Scan(&schemaVersion); e != nil {
		return fail(e)
	}
	if schemaVersion > 2 {
		return fail(errors.New("device database requires a newer CLI"))
	}
	if schemaVersion < 2 {
		unlock, err := lockScan(dir, 30*time.Second)
		if err != nil {
			return fail(err)
		}
		defer unlock()
		tx, err := db.Begin()
		if err != nil {
			return fail(err)
		}
		err = tx.QueryRow("PRAGMA user_version").Scan(&schemaVersion)
		if err == nil && schemaVersion > 2 {
			err = errors.New("device database requires a newer CLI")
		}
		if err == nil && schemaVersion == 0 {
			_, err = tx.Exec(schema)
			if err == nil {
				var key ed25519.PrivateKey
				_, key, err = ed25519.GenerateKey(rand.Reader)
				if err == nil {
					_, err = tx.Exec("INSERT OR IGNORE INTO settings(k,v) VALUES('identity',?)", hex.EncodeToString(key.Seed()))
				}
			}
		}
		if err == nil && schemaVersion == 1 {
			// An already-open v1 scanner must fail its source enumeration before
			// it can erase observations or publish totals from an older projection.
			_, err = tx.Exec(`DROP TRIGGER IF EXISTS invalidate_on_index; DROP TRIGGER IF EXISTS invalidate_on_removal;
				ALTER TABLE source_files RENAME TO indexed_sources`)
		}
		if err == nil && schemaVersion < 2 {
			_, err = tx.Exec(clawEvidenceSchema)
		}
		if err == nil {
			err = tx.Commit()
		} else {
			tx.Rollback()
		}
		if err != nil {
			return fail(err)
		}
	}
	var stored string
	if e = db.QueryRow("SELECT v FROM settings WHERE k='identity'").Scan(&stored); e != nil {
		return fail(e)
	}
	seed, e := hex.DecodeString(stored)
	if e != nil || len(seed) != ed25519.SeedSize {
		return fail(errors.New("invalid device key"))
	}
	key := ed25519.NewKeyFromSeed(seed)
	return &Store{db, dir, home, hex.EncodeToString(key.Public().(ed25519.PublicKey)), key}, nil
}
func (s *Store) setting(k, def string) string {
	var v string
	if s.db.QueryRow("SELECT v FROM settings WHERE k=?", k).Scan(&v) == nil {
		return v
	}
	return def
}
func (s *Store) set(k, v string) error {
	_, e := s.db.Exec("INSERT INTO settings(k,v) VALUES(?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v", k, v)
	return e
}
func verify(env Envelope) (Snapshot, error) {
	var snap Snapshot
	if err := json.Unmarshal(env.Data, &snap); err != nil {
		return snap, err
	}
	pub, e := hex.DecodeString(snap.Origin)
	if e != nil || len(pub) != ed25519.PublicKeySize || !ed25519.Verify(pub, env.Data, env.Signature) {
		return snap, errors.New("invalid snapshot signature")
	}
	if snap.Protocol != 1 || snap.Revision < 1 || snap.Observed < 1 || snap.Observed > 253402300799 || snap.PartialSources < 0 || !device.ValidPairName(snap.Name) || !replicaText(snap.OS) {
		return snap, errors.New("invalid snapshot header")
	}
	var total Counts
	for _, bucket := range snap.Buckets {
		if _, err := time.Parse(time.DateOnly, bucket.Day); err != nil || !replicaText(bucket.Agent) || !replicaText(bucket.Model) || !bucket.Counts.valid() {
			return snap, errors.New("invalid daily usage bucket")
		}
		counts := bucket.Counts
		counts.Credits = 0 // Wallets are independent across providers.
		var ok bool
		total, ok = total.checkedSum(counts)
		if !ok {
			return snap, errors.New("device totals exceed supported range")
		}
	}
	for _, quota := range snap.Quotas {
		if !replicaText(quota.Provider) || !replicaText(quota.Account) || !(quota.Balance == "unlimited" || optionalAmount(quota.Balance)) || !replicaText(quota.BalanceUnit) {
			return snap, errors.New("invalid quota description")
		}
		if _, err := time.Parse(time.RFC3339Nano, quota.Observed); err != nil {
			return snap, errors.New("invalid quota observation time")
		}
		for _, window := range quota.Windows {
			if !replicaText(window.Label) || !replicaText(window.ID) || !replicaText(window.ResetAt) ||
				!replicaText(window.Unit) || !optionalAmount(window.UsedAmount) || !optionalAmount(window.RemainingAmount) || !optionalAmount(window.TotalAmount) {
				return snap, errors.New("invalid quota window")
			}
		}
	}
	return snap, nil
}

func optionalAmount(s string) bool { return s == "" || account.DecimalAmount(s) != "" }

func replicaText(s string) bool {
	return len(s) <= 4096 && strings.IndexFunc(s, func(r rune) bool {
		return unicode.IsControl(r) || unicode.In(r, unicode.Cf, unicode.Zl, unicode.Zp)
	}) < 0
}

func (s *Store) acceptFrom(ctx context.Context, peerID, origin string, minimumRevision int64, env Envelope) error {
	snap, err := verify(env)
	if err != nil {
		return err
	}
	if snap.Origin != origin || snap.Revision < minimumRevision {
		return errors.New("snapshot does not match inventory")
	}
	body, err := json.Marshal(env)
	if err != nil {
		return err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	// A user may revoke a device while its signed snapshot is in flight.
	var allowed int
	if err = tx.QueryRowContext(ctx, "SELECT 1 FROM peers WHERE id=? AND role='peer'", peerID).Scan(&allowed); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return errors.New("peer no longer authorized to replicate")
		}
		return err
	}
	// Newer authentic revisions also recover this device's counter after restoring a backup.
	_, err = tx.ExecContext(ctx, "INSERT INTO replicas VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,body=excluded.body WHERE excluded.revision>replicas.revision", origin, snap.Revision, body)
	if err != nil {
		return err
	}
	return tx.Commit()
}

// Update the local signed snapshot under the same writer transaction for scans
// and manual quota refreshes; neither may overwrite the other one's newer data.
func (s *Store) writeSnapshot(update func(*Snapshot) error) error {
	hostname, _ := os.Hostname()
	name := s.setting("name", hostname)
	tx, e := s.db.Begin()
	if e != nil {
		return e
	}
	defer tx.Rollback()
	snap := Snapshot{Protocol: 1, Origin: s.id, OS: runtime.GOOS}
	var raw []byte
	var old Envelope
	e = tx.QueryRow("SELECT body FROM replicas WHERE id=?", s.id).Scan(&raw)
	if e == nil {
		if e = json.Unmarshal(raw, &old); e != nil {
			return e
		}
		if e = json.Unmarshal(old.Data, &snap); e != nil {
			return e
		}
	} else if !errors.Is(e, sql.ErrNoRows) {
		return e
	}
	snap.Name = name
	if e = update(&snap); e != nil {
		return e
	}
	now := time.Now().Unix()
	if len(old.Data) > 0 && now-snap.Observed < 900 {
		data, err := json.Marshal(snap)
		if err != nil {
			return err
		}
		if bytes.Equal(data, old.Data) {
			return nil
		}
	}
	snap.Observed = now
	snap.Revision++
	data, e := json.Marshal(snap)
	if e != nil {
		return e
	}
	body, e := json.Marshal(Envelope{data, ed25519.Sign(s.key, data)})
	if e != nil {
		return e
	}
	if _, e = tx.Exec("INSERT OR REPLACE INTO replicas VALUES(?,?,?)", s.id, snap.Revision, body); e != nil {
		return e
	}
	return tx.Commit()
}
func (s *Store) snapshots() ([]Snapshot, error) {
	rows, e := s.db.Query("SELECT body FROM replicas ORDER BY id")
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	var out []Snapshot
	for rows.Next() {
		var b []byte
		var env Envelope
		var snap Snapshot
		if e = rows.Scan(&b); e != nil {
			return nil, e
		}
		if e = json.Unmarshal(b, &env); e != nil {
			return nil, e
		}
		if e = json.Unmarshal(env.Data, &snap); e != nil {
			return nil, e
		}
		// Older collectors included OpenClaw's delivery copies in signed daily buckets.
		snap.Buckets = slices.DeleteFunc(snap.Buckets, func(b Bucket) bool {
			return b.Agent == "openclaw" && b.Model == openClawDeliveryMirrorModel && !b.Counts.hasUsage()
		})
		out = append(out, snap)
	}
	return out, rows.Err()
}

type Device struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	OS       string `json:"os"`
	Observed int64  `json:"observed"`
	Local    bool   `json:"local"`
	Counts
	Tokens         int64 `json:"tokens"`
	PartialSources int   `json:"partialSources,omitempty"`
}
type Report struct {
	Devices       []Device `json:"devices"`
	Agents        []Bucket `json:"agents"`
	Quotas        []Quota  `json:"quotas"`
	Tokens        int64    `json:"tokens"`
	CostMicros    int64    `json:"costMicros"`
	UnknownCost   int64    `json:"unknownCost"`
	UnknownTokens int64    `json:"unknownTokens"`
}

func (s *Store) report(host, from, to string) (Report, error) {
	snaps, e := s.snapshots()
	if e != nil {
		return Report{}, e
	}
	r := Report{Devices: []Device{}, Agents: []Bucket{}, Quotas: []Quota{}}
	var combined Counts
	groups := map[string]*Bucket{}
	quotas := map[string]Quota{}
	for _, snap := range snaps {
		if host != "" && host != snap.Origin && !(host == "local" && snap.Origin == s.id) {
			continue
		}
		d := Device{ID: snap.Origin, Name: snap.Name, OS: snap.OS, Observed: snap.Observed, Local: snap.Origin == s.id, PartialSources: snap.PartialSources}
		for _, b := range snap.Buckets {
			if (from != "" && b.Day < from) || (to != "" && b.Day > to) {
				continue
			}
			deviceCounts := b.Counts
			deviceCounts.Credits = 0
			var ok bool
			d.Counts, ok = d.Counts.checkedSum(deviceCounts)
			if !ok {
				return Report{}, errors.New("device totals exceed supported range")
			}
			k := b.Agent + "\x00" + b.Model
			g := groups[k]
			if g == nil {
				g = &Bucket{Agent: b.Agent, Model: b.Model}
				groups[k] = g
			}
			g.Counts, ok = g.Counts.checkedSum(b.Counts)
			if !ok {
				return Report{}, errors.New("model totals exceed supported range")
			}
		}
		d.Tokens = d.Counts.tokens()
		r.Devices = append(r.Devices, d)
		var ok bool
		combined, ok = combined.checkedSum(d.Counts)
		if !ok {
			return Report{}, errors.New("combined device totals exceed supported range")
		}
		for _, q := range snap.Quotas {
			k := q.Provider + "\x00" + q.Account
			old, ok := quotas[k]
			observed, err := time.Parse(time.RFC3339Nano, q.Observed)
			previous, _ := time.Parse(time.RFC3339Nano, old.Observed)
			if err == nil && (!ok || observed.After(previous)) {
				quotas[k] = q
			}
		}
	}
	r.Tokens, r.CostMicros = combined.tokens(), combined.CostMicros
	r.UnknownCost, r.UnknownTokens = combined.UnknownCost, combined.UnknownTokens
	if host != "" && len(r.Devices) == 0 {
		return r, fmt.Errorf("unknown device %q", host)
	}
	for _, g := range groups {
		r.Agents = append(r.Agents, *g)
	}
	for _, q := range quotas {
		r.Quotas = append(r.Quotas, q)
	}
	sort.Slice(r.Agents, func(i, j int) bool {
		a, b := r.Agents[i], r.Agents[j]
		if a.tokens() != b.tokens() {
			return a.tokens() > b.tokens()
		}
		return a.Agent+"\x00"+a.Model < b.Agent+"\x00"+b.Model
	})
	sort.Slice(r.Quotas, func(i, j int) bool {
		a, b := r.Quotas[i], r.Quotas[j]
		return a.Provider+a.Account < b.Provider+b.Account
	})
	return r, nil
}
