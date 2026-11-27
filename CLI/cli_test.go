package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/klauspost/compress/zstd"
	"github.com/luweiCN/token-meter/internal/device"
)

func (s *Store) publish(b []Bucket, q []Quota, partial int) error {
	return s.writeSnapshot(func(snap *Snapshot) error {
		snap.Buckets, snap.Quotas, snap.PartialSources = b, q, partial
		return nil
	})
}

func testStore(t *testing.T) *Store {
	t.Helper()
	home := t.TempDir()
	s, e := openStore(filepath.Join(home, ".token-meter", "node"), home)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { s.db.Close() })
	return s
}
func check(t *testing.T, e error) {
	t.Helper()
	if e != nil {
		t.Fatal(e)
	}
}
func writeTestFile(t *testing.T, p string, b []byte) {
	t.Helper()
	check(t, os.MkdirAll(filepath.Dir(p), 0700))
	check(t, os.WriteFile(p, b, 0600))
}

const record = `{"type":"message","id":"e","timestamp":"2026-01-02T08:00:00Z","message":{"role":"assistant","model":"test","provider":"provider","responseId":"abc","usage":{"input":4,"output":3,"cacheRead":5,"cacheWrite":1,"cost":{"total":0.012}}}}`

func TestMirroredOpenClawArchivesCorrectionsAndPrices(t *testing.T) {
	s := testStore(t)
	agent := filepath.Join(s.home, ".openclaw", "agents", "main")
	old := filepath.Join(agent, "sessions", "x.jsonl")
	writeTestFile(t, old, []byte(record+"\n"))
	writeTestFile(t, old+".reset.2026", []byte(record+"\n"))
	check(t, s.scan())
	r, e := s.report("local", "", "")
	check(t, e)
	if r.Tokens != 13 || r.CostMicros != 12000 || r.Agents[0].Events != 1 {
		t.Fatalf("legacy report %+v", r)
	}
	archive := filepath.Join(agent, "agent", "openclaw-agent.sqlite")
	check(t, os.MkdirAll(filepath.Dir(archive), 0700))
	db, e := sql.Open("sqlite", sqlitePath(archive))
	check(t, e)
	defer db.Close()
	_, e = db.Exec("CREATE TABLE transcript_events(session_id TEXT,seq INTEGER,event_json TEXT,event_zstd BLOB); CREATE TABLE session_transcript_cold_archives(session_id TEXT,archive_name TEXT,archive_sha256 TEXT,archive_blob BLOB);")
	check(t, e)
	z, e := zstd.NewWriter(nil, zstd.WithEncoderConcurrency(1))
	check(t, e)
	defer z.Close()
	blob := z.EncodeAll([]byte(record), nil)
	_, e = db.Exec("INSERT INTO transcript_events VALUES('x',1,NULL,?)", blob)
	check(t, e)
	cold, _ := json.Marshal(map[string]any{"kind": "event", "row": map[string]any{"event_json": strings.ReplaceAll(record, "abc", "def")}})
	blob = z.EncodeAll(cold, nil)
	hash := fmt.Sprintf("%x", sha256.Sum256(blob))
	writeTestFile(t, filepath.Join(agent, "sessions", "cold", hash+".jsonl.zst"), blob)
	_, e = db.Exec("INSERT INTO session_transcript_cold_archives VALUES('x',?,?,NULL)", hash+".jsonl.zst", hash)
	check(t, e)
	check(t, s.scan())
	r, e = s.report("local", "", "")
	check(t, e)
	if r.Tokens != 26 || r.Agents[0].Events != 2 {
		t.Fatalf("hot/cold/mirror %+v", r)
	}
	check(t, os.Remove(old))
	check(t, s.scan())
	r, e = s.report("local", "", "")
	check(t, e)
	if r.Tokens != 26 {
		t.Fatal("rotation lost records")
	}
	var prior int64
	check(t, s.db.QueryRow("SELECT revision FROM replicas WHERE id=?", s.id).Scan(&prior))
	check(t, s.scan())
	var next int64
	check(t, s.db.QueryRow("SELECT revision FROM replicas WHERE id=?", s.id).Scan(&next))
	if prior != next {
		t.Fatal("unchanged scan created revision")
	}
	cat, e := prices(s.home)
	check(t, e)
	v := Counts{Input: 100001}
	lo, ok := cat.estimate("anthropic.claude-haiku-5-5", time.Now(), v)
	if !ok || lo != 50001 {
		t.Fatalf("context pricing %d %v", lo, ok)
	}
}
func TestHermesRouteAndSessionResidual(t *testing.T) {
	s := testStore(t)
	path := filepath.Join(s.home, ".hermes", "profiles", "other", "state.db")
	check(t, os.MkdirAll(filepath.Dir(path), 0700))
	db, e := sql.Open("sqlite", sqlitePath(path))
	check(t, e)
	defer db.Close()
	_, e = db.Exec(`CREATE TABLE sessions(id TEXT PRIMARY KEY,started_at REAL,model TEXT,input_tokens INT,output_tokens INT,cache_read_tokens INT,api_call_count INT,actual_cost_usd REAL);
 CREATE TABLE session_model_usage(session_id TEXT,model TEXT,input_tokens INT,output_tokens INT,cache_read_tokens INT,api_call_count INT,actual_cost_usd REAL);
 INSERT INTO sessions VALUES('s',1680000000,'original',100,20,10,3,0.2);
 INSERT INTO session_model_usage VALUES('s','route',80,20,10,2,0.15)`)
	check(t, e)
	check(t, s.scan())
	r, e := s.report("", "", "")
	check(t, e)
	if r.Tokens != 130 || r.CostMicros != 200000 || len(r.Agents) != 2 {
		t.Fatalf("double counting: %+v", r)
	}
	_, e = db.Exec("UPDATE sessions SET input_tokens=110")
	check(t, e)
	check(t, s.scan())
	r, e = s.report("", "", "")
	check(t, e)
	if r.Tokens != 140 {
		t.Fatal(r.Tokens)
	}
	_, e = db.Exec("DELETE FROM session_model_usage; UPDATE sessions SET input_tokens=5,output_tokens=0,cache_read_tokens=0,api_call_count=1,actual_cost_usd=0.01")
	check(t, e)
	check(t, s.scan())
	r, e = s.report("", "", "")
	check(t, e)
	if r.Tokens != 5 || r.CostMicros != 10000 || len(r.Agents) != 1 {
		t.Fatalf("Hermes route and residual must follow the current totals: %+v", r)
	}
	check(t, db.Close())
	check(t, os.Remove(path))
	check(t, s.scan())
	r, e = s.report("", "", "")
	check(t, e)
	if r.Tokens != 0 || r.CostMicros != 0 {
		t.Fatalf("removed Hermes source still contributes: %+v", r)
	}
}
func testPeerServer(t *testing.T, s *Store) *httptest.Server {
	t.Helper()
	server := httptest.NewUnstartedServer(s.handler())
	conf, e := s.tlsConfig("")
	check(t, e)
	server.TLS = conf
	server.StartTLS()
	t.Cleanup(server.Close)
	return server
}
func TestPeerReplicationAndOfflineReader(t *testing.T) {
	a, b, c := testStore(t), testStore(t), testStore(t)
	ctx := context.Background()
	sa, sb, sc := testPeerServer(t, a), testPeerServer(t, b), testPeerServer(t, c)
	connect := func(x, y *Store, server *httptest.Server) {
		check(t, x.addPeer(y.id, server.Listener.Addr().String(), "peer"))
	}
	connect(a, b, sb)
	connect(b, a, sa)
	connect(b, c, sc)
	connect(c, b, sb)
	q := Quota{Provider: "test", Account: "shared", Observed: "2026-01-02T00:00:00Z", Balance: "25"}
	for i, s := range []*Store{a, b, c} {
		qq := q
		qq.Observed = fmt.Sprintf("2026-01-0%dT00:00:00Z", i+1)
		check(t, s.publish([]Bucket{{Day: "2026-01-01", Agent: "openclaw", Model: "m", Counts: Counts{Input: int64(i + 1)}}}, []Quota{qq}, 0))
	}
	check(t, b.sync(ctx))
	check(t, c.sync(ctx))
	check(t, a.sync(ctx))
	check(t, b.sync(ctx))
	r, e := c.report("", "", "")
	check(t, e)
	if r.Tokens != 6 || len(r.Devices) != 3 || len(r.Quotas) != 1 || r.Quotas[0].Observed != "2026-01-03T00:00:00Z" {
		t.Fatal(r)
	}
	// Changing A's history replaces A on both relays. Delayed signed revisions cannot undo it.
	var old []byte
	check(t, a.db.QueryRow("SELECT body FROM replicas WHERE id=?", a.id).Scan(&old))
	check(t, a.publish([]Bucket{{Day: "2026-01-01", Agent: "openclaw", Model: "m", Counts: Counts{Input: 7}}}, nil, 0))
	check(t, b.sync(ctx))
	check(t, c.sync(ctx))
	var env Envelope
	check(t, json.Unmarshal(old, &env))
	check(t, c.acceptFrom(ctx, b.id, a.id, 1, env))
	env.Signature[0] ^= 1
	if c.acceptFrom(ctx, b.id, a.id, 1, env) == nil {
		t.Fatal("accepted a forged origin")
	}
	sa.Close()
	r, e = c.report(a.id, "", "")
	check(t, e)
	if r.Tokens != 7 {
		t.Fatal("offline host lost")
	}
	viewer := testStore(t)
	cfg, e := viewer.tlsConfig(c.id)
	check(t, e)
	client := &http.Client{Transport: &http.Transport{TLSClientConfig: cfg}, Timeout: 2 * time.Second}
	if _, err := client.Get(sc.URL + "/v1/usage"); err == nil {
		t.Fatal("allowed unpaired reader")
	}
	check(t, c.addPeer(viewer.id, "", "viewer"))
	var report Report
	check(t, device.FetchJSON(ctx, client, sc.URL+"/v1/usage", 1<<20, &report))
	if report.Tokens != 12 {
		t.Fatal(report.Tokens)
	}
	var versions map[string]int64
	if device.FetchJSON(ctx, client, sc.URL+"/v1/versions", 1<<20, &versions) == nil {
		t.Fatal("viewer could replicate")
	}
	client.CloseIdleConnections()
}

type roundTrip func(*http.Request) (*http.Response, error)

func (f roundTrip) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func TestVerifiedReleaseActivation(t *testing.T) {
	s := testStore(t)
	const v = "99.0.0"
	candidate := os.Getenv("TOKEN_METER_TEST_CANDIDATE")
	if candidate == "" {
		candidate = filepath.Join(t.TempDir(), binaryName())
		cmd := exec.Command("go", "build", "-ldflags", "-X main.version="+v, "-o", candidate, ".")
		if out, e := cmd.CombinedOutput(); e != nil {
			t.Fatalf("build: %s %v", out, e)
		}
	}
	data, e := os.ReadFile(candidate)
	check(t, e)
	asset := assetName()
	url := "https://github.com/luweiCN/token-meter/releases/download/v" + v + "/" + asset
	var rel release
	meta, _ := json.Marshal(map[string]any{"tag_name": "v" + v, "assets": []map[string]string{{"name": asset, "digest": "sha256:" + fmt.Sprintf("%x", sha256.Sum256(data)), "browser_download_url": url}}})
	check(t, json.Unmarshal(meta, &rel))
	client := &http.Client{Transport: roundTrip(func(r *http.Request) (*http.Response, error) {
		if r.URL.String() != url {
			t.Errorf("unexpected URL %s", r.URL)
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(bytes.NewReader(data)), Header: http.Header{}}, nil
	})}
	good := rel.Assets[0].Digest
	rel.Assets[0].Digest = "sha256:" + strings.Repeat("0", 64)
	if ok, e := s.applyRelease(context.Background(), client, rel); e == nil || ok {
		t.Fatal("accepted damaged artifact")
	}
	a, e := s.active()
	check(t, e)
	if a.Version != "" {
		t.Fatal("changed active release on failure")
	}
	rel.Assets[0].Digest = good
	ok, e := s.applyRelease(context.Background(), client, rel)
	check(t, e)
	if !ok {
		t.Fatal("didn't activate")
	}
	out, e := exec.Command(s.buildPath(v), "_check").Output()
	check(t, e)
	if strings.TrimSpace(string(out)) != v {
		t.Fatal("wrong installed build")
	}
	// Exercise the daemon's normal release check and the production supervisor.
	auto := testStore(t)
	available, err := net.Listen("tcp", "127.0.0.1:0")
	check(t, err)
	addr := available.Addr().String()
	available.Close()
	check(t, auto.set("listen", addr))
	realTransport := http.DefaultTransport
	http.DefaultTransport = roundTrip(func(r *http.Request) (*http.Response, error) {
		switch r.URL.String() {
		case releaseAPI:
			return &http.Response{StatusCode: 200, Header: http.Header{}, Body: io.NopCloser(bytes.NewReader(meta))}, nil
		case url:
			return client.Transport.RoundTrip(r)
		default:
			return nil, fmt.Errorf("unexpected outbound request")
		}
	})
	ctx, stop := context.WithTimeout(context.Background(), 30*time.Second)
	defer stop()
	e = auto.serve(ctx)
	http.DefaultTransport = realTransport
	check(t, e)
	active, e := auto.active()
	check(t, e)
	if active.Version != v {
		t.Fatal("daemon did not activate release")
	}
	check(t, auto.set("auto-update", "false"))
	viewer := testStore(t)
	check(t, auto.addPeer(viewer.id, "", "viewer"))
	tlsConf, e := viewer.tlsConfig(auto.id)
	check(t, e)
	reader := &http.Client{Transport: &http.Transport{TLSClientConfig: tlsConf}, Timeout: time.Second}
	defer reader.CloseIdleConnections()
	supervising, finish := context.WithCancel(ctx)
	done := make(chan error, 1)
	go func() { done <- auto.supervise(supervising) }()
	defer func() {
		finish()
		if err := <-done; err != nil {
			t.Error(err)
		}
	}()
	var health struct{ Version string }
	for ctx.Err() == nil {
		if device.FetchJSON(ctx, reader, "https://"+addr+"/v1/status", 1024, &health) == nil {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if health.Version != v {
		t.Fatalf("supervisor did not start verified release: %q", health.Version)
	}

	if runtime.GOOS == "windows" && !strings.HasSuffix(asset, ".exe") {
		t.Fatal(asset)
	}
}

func TestAppendPartialTruncateAndRotate(t *testing.T) {
	s := testStore(t)
	p := filepath.Join(s.home, ".openclaw", "agents", "main", "sessions", "one.jsonl")
	writeTestFile(t, p, []byte(record+"\n"))
	check(t, s.scan())
	next := strings.ReplaceAll(record, "abc", "def")
	appendText := func(data string) {
		t.Helper()
		f, e := os.OpenFile(p, os.O_APPEND|os.O_WRONLY, 0600)
		check(t, e)
		_, e = f.WriteString(data)
		check(t, e)
		check(t, f.Close())
		check(t, s.scan())
	}
	expect := func(total int64) {
		t.Helper()
		r, e := s.report("", "", "")
		check(t, e)
		if r.Tokens != total {
			t.Errorf("got %d want %d", r.Tokens, total)
		}
	}
	appendText(next[:80])
	expect(13)
	appendText(next[80:] + "\n")
	expect(26)
	corrected := strings.ReplaceAll(next, "\"input\":4", "\"input\":8")
	appendText(corrected + "\n")
	expect(30)
	check(t, os.Rename(p, p+".reset.1"))
	writeTestFile(t, p, []byte(strings.ReplaceAll(record, "abc", "ghi")+"\n"))
	check(t, s.scan())
	expect(43)
	writeTestFile(t, p, []byte("{}\n"))
	check(t, s.scan())
	expect(43) // Truncating a transcript leaves its already measured requests intact.
}
