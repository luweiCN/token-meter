package main

import (
	"bufio"
	"context"
	"crypto/tls"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/luweiCN/token-meter/internal/device"
	"github.com/luweiCN/token-meter/internal/relay"
)

func privateRelayForTest(t *testing.T) *httptest.Server {
	t.Helper()
	hub := relay.NewServer()
	t.Cleanup(func() { _ = hub.Close() })
	srv := httptest.NewServer(hub)
	t.Cleanup(srv.Close)
	return srv
}

func startPeerRelay(t *testing.T, s *Store, endpoint string) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	cfg, err := s.tlsConfig("")
	check(t, err)
	ln, err := relay.Listen(ctx, endpoint, s.key)
	check(t, err)
	finished := make(chan error, 1)
	go func() { finished <- s.servePeerListener(ctx, tls.NewListener(ln, cfg)) }()
	t.Cleanup(func() {
		cancel()
		select {
		case err := <-finished:
			check(t, err)
		case <-time.After(4 * time.Second):
			t.Error("relay listener did not shut down")
		}
	})
}

func TestPeerRelayAcrossOutboundOnlyDevices(t *testing.T) {
	hub := privateRelayForTest(t)
	a, b := testStore(t), testStore(t)
	ctx := t.Context()
	check(t, a.trustPaired(b.id, "", "peer", hub.URL, "Linux"))
	check(t, b.trustPaired(a.id, "", "peer", hub.URL, "Mac"))
	check(t, a.publish([]Bucket{{Day: "2026-11-25", Counts: Counts{Input: 11}}}, nil, 0))
	check(t, b.publish([]Bucket{{Day: "2026-11-25", Counts: Counts{Input: 33}}}, nil, 0))
	// The only listener with a TCP address is the public gateway. Both
	// node listeners first establish an outbound authenticated control connection.
	startPeerRelay(t, a, hub.URL)
	startPeerRelay(t, b, hub.URL)
	check(t, a.sync(ctx))
	check(t, b.sync(ctx))
	remote, err := a.remoteReport(ctx, "any", "", "", "")
	check(t, err)
	if remote.Tokens != 44 || len(remote.Devices) != 2 {
		t.Fatalf("remote query did not return both sources: %+v", remote)
	}
	paired, err := a.pairedDevices()
	check(t, err)
	if len(paired) != 1 || paired[0].Name != "Linux" || paired[0].LastSync == 0 {
		t.Fatal(paired)
	}
	// A stale private address might now point to a different authenticated
	// device. A failed identity handshake on that route must try the relay.
	other := testStore(t)
	wrong := testPeerServer(t, other)
	check(t, other.addPeer(a.id, "", "viewer"))
	p := peerRoute{ID: b.id, Direct: wrong.Listener.Addr().String(), Relay: hub.URL}
	client, err := a.peerClient(p, 10*time.Second)
	check(t, err)
	defer client.CloseIdleConnections()
	var status struct{ ID string }
	check(t, device.FetchJSON(ctx, client, p.BaseURL()+"/v1/status", 4096, &status))
	if status.ID != b.id {
		t.Fatal("queried a device with the wrong pinned identity")
	}
}

func TestRelayViewerDirectionRevocationAndIdlePrivacy(t *testing.T) {
	hub := privateRelayForTest(t)
	host, phone := testStore(t), testStore(t)
	ctx := t.Context()
	check(t, host.set("listen", defaultPeerListen))
	paths, err := host.inboundPaths(ctx)
	check(t, err)
	if len(paths) != 0 {
		t.Fatal("unpaired service would advertise publicly")
	}
	check(t, host.trustPaired(phone.id, "", "viewer", hub.URL, "手机"))
	check(t, phone.trustPaired(host.id, "", "source", hub.URL, "Mac"))
	if err := host.trustPaired(phone.id, "", "peer", hub.URL, "手机"); err == nil {
		t.Fatal("changed an existing grant without revoking it")
	}
	paths, err = phone.inboundPaths(ctx)
	check(t, err)
	if len(paths) != 0 {
		t.Fatal("outbound-only viewer should not open a relay listener")
	}
	check(t, host.publish([]Bucket{{Day: "2026-11-25", Counts: Counts{Input: 42}}}, nil, 0))
	startPeerRelay(t, host, hub.URL)
	direct := testPeerServer(t, phone)
	if _, err := host.remoteReport(ctx, "any", "", "", ""); err == nil {
		t.Fatal("a viewer appeared as an authorized source")
	}
	remote, err := phone.remoteReport(ctx, "any", "", "", "")
	check(t, err)
	if remote.Tokens != 42 {
		t.Fatal(remote.Tokens)
	}
	routes, err := phone.peerRoutes(ctx, "", false)
	check(t, err)
	if len(routes) != 0 {
		t.Fatal("read-only grant may not fetch replicas")
	}
	p := peerRoute{ID: host.id, Relay: hub.URL}
	client, err := phone.peerClient(p, 5*time.Second)
	check(t, err)
	defer client.CloseIdleConnections()
	statusCode := func(path string) int {
		t.Helper()
		resp, err := client.Get(p.BaseURL() + path)
		check(t, err)
		_, err = io.Copy(io.Discard, resp.Body)
		check(t, err)
		resp.Body.Close()
		return resp.StatusCode
	}
	if statusCode("/v1/usage") != 200 || statusCode("/v1/versions") != 403 {
		t.Fatal("wrong viewer permissions over the relay")
	}
	conf, err := host.tlsConfig(phone.id)
	check(t, err)
	reverse := &http.Client{Transport: &http.Transport{TLSClientConfig: conf}, Timeout: time.Second}
	defer reverse.CloseIdleConnections()
	if _, err := reverse.Get(direct.URL + "/v1/usage"); err == nil {
		t.Fatal("source registration granted reverse access to the viewer")
	}
	// Hold open one concrete connection: after an admin revokes this device,
	// the identical TLS session must no longer return any account information.
	pinnedHost, err := phone.tlsConfig(host.id)
	check(t, err)
	conn, err := device.DialPeer(ctx, phone.key, p, pinnedHost)
	check(t, err)
	defer conn.Close()
	reader := bufio.NewReader(conn)
	keepaliveStatus := func() int {
		t.Helper()
		_, err := fmt.Fprint(conn, "GET /v1/usage HTTP/1.1\r\nHost: paired.local\r\n\r\n")
		check(t, err)
		reply, err := http.ReadResponse(reader, nil)
		check(t, err)
		_, err = io.Copy(io.Discard, reply.Body)
		check(t, err)
		reply.Body.Close()
		return reply.StatusCode
	}
	if keepaliveStatus() != 200 {
		t.Fatal("expected valid reader before revocation")
	}
	check(t, host.removePeer(phone.id))
	if keepaliveStatus() != 403 {
		t.Fatal("revoked viewer reused its existing TLS connection")
	}
	resp, err := client.Get(p.BaseURL() + "/v1/usage")
	if err == nil {
		resp.Body.Close()
		if resp.StatusCode != 403 {
			t.Fatal("revoked viewer could still read over the relay", resp.StatusCode)
		}
	} else if !strings.Contains(err.Error(), "tls:") {
		t.Fatal("expected an identity rejection on reconnection", err)
	}
	var value string
	err = host.db.QueryRow("SELECT v FROM settings WHERE k IN (?,?)", "peer.relay."+phone.id, "peer.name."+phone.id).Scan(&value)
	if !errors.Is(err, sql.ErrNoRows) {
		t.Fatal("peer route metadata was not revoked")
	}
	paths, err = host.inboundPaths(ctx)
	check(t, err)
	if len(paths) != 0 {
		t.Fatal("the last revoked grant kept an outbound listener")
	}
}

func TestDirectPeerSkipsRelayAndSupportsRoaming(t *testing.T) {
	a, b := testStore(t), testStore(t)
	server := testPeerServer(t, b)
	check(t, b.addPeer(a.id, "", "viewer"))
	// An unreachable relay must never delay a working direct route.
	p := peerRoute{ID: b.id, Direct: server.Listener.Addr().String(), Relay: "http://127.0.0.1:1"}
	c, err := a.peerClient(p, 3*time.Second)
	check(t, err)
	defer c.CloseIdleConnections()
	var status struct{ ID string }
	check(t, device.FetchJSON(t.Context(), c, p.BaseURL()+"/v1/status", 4096, &status))
	if status.ID != b.id {
		t.Fatal("incorrect direct peer")
	}
	config, err := a.tlsConfig("")
	check(t, err)
	missing := "192.0.2.99:0"
	ln, retry, err := listenPeerTCP(missing, config)
	check(t, err)
	defer ln.Close()
	host, _, err := net.SplitHostPort(ln.Addr().String())
	check(t, err)
	if retry != missing || host != "127.0.0.1" {
		t.Fatalf("roaming fallback: %v, retry %s", ln.Addr(), retry)
	}
	check(t, a.set("listen", "127.0.0.1:47732"))
	if address := a.pairDirectAddress(); address != "" {
		t.Fatal("advertised a loopback-only endpoint", address)
	}
	if err := a.trustPaired(b.id, "127.0.0.1:99", "peer", "https://example.invalid"); err == nil || !strings.Contains(err.Error(), "private") {
		t.Fatal("accepted an automatic loopback routing hint")
	}
}

func TestRevocationWhilePeerResponseInFlight(t *testing.T) {
	for _, operation := range []string{"sync", "query"} {
		t.Run(operation, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
			defer cancel()
			host, reader := testStore(t), testStore(t)
			check(t, host.publish([]Bucket{{Day: "2026-11-25", Agent: "openclaw", Model: "test", Counts: Counts{Input: 5}}}, nil, 0))
			waiting := make(chan struct{})
			finish := make(chan struct{})
			defer func() {
				select {
				case <-finish:
				default:
					close(finish)
				}
			}()
			handler := host.handler()
			server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if (operation == "query" && r.URL.Path == "/v1/usage") || strings.HasPrefix(r.URL.Path, "/v1/snapshots/") {
					close(waiting)
					select {
					case <-finish:
					case <-ctx.Done():
						return
					}
				}
				handler.ServeHTTP(w, r)
			}))
			cfg, err := host.tlsConfig("")
			check(t, err)
			server.TLS = cfg
			server.StartTLS()
			defer server.Close()
			check(t, reader.addPeer(host.id, server.Listener.Addr().String(), "peer"))
			check(t, host.addPeer(reader.id, "127.0.0.1:47732", "peer"))
			response := make(chan error, 1)
			go func() {
				if operation == "sync" {
					response <- reader.sync(ctx)
				} else {
					_, err := reader.remoteReport(ctx, "any", "", "", "")
					response <- err
				}
			}()
			select {
			case <-waiting:
			case <-ctx.Done():
				t.Fatal(ctx.Err())
			}
			check(t, reader.removePeer(host.id))
			close(finish)
			select {
			case err := <-response:
				if err == nil || !strings.Contains(err.Error(), "authoriz") {
					t.Fatalf("revoked in-flight transfer: %v", err)
				}
			case <-ctx.Done():
				t.Fatal(ctx.Err())
			}
			var n int
			check(t, reader.db.QueryRow("SELECT count(*) FROM replicas WHERE id=?", host.id).Scan(&n))
			if n != 0 {
				t.Fatal("stored usage after the node was revoked")
			}
		})
	}
}

func TestSignedButDamagedDailyTotalsAreRejected(t *testing.T) {
	a, b := testStore(t), testStore(t)
	check(t, a.addPeer(b.id, "127.0.0.1:47732", "peer"))
	for _, s := range []struct {
		name    string
		buckets []Bucket
	}{
		{"per-request sum overflow", []Bucket{{Day: "2026-11-25", Counts: Counts{Input: math.MaxInt64, CacheRead: 1}}}},
		{"device sum overflow", []Bucket{{Day: "2026-11-24", Counts: Counts{Output: math.MaxInt64}}, {Day: "2026-11-25", Counts: Counts{Output: 1}}}},
		{"negative known cost", []Bucket{{Day: "2026-11-25", Counts: Counts{Input: 1, CostMicros: -1}}}},
		{"terminal control in model", []Bucket{{Day: "2026-11-25", Model: "model\x1b[2J", Counts: Counts{Input: 1}}}},
	} {
		t.Run(s.name, func(t *testing.T) {
			check(t, b.publish(s.buckets, nil, 0))
			var raw []byte
			check(t, b.db.QueryRow("SELECT body FROM replicas WHERE id=?", b.id).Scan(&raw))
			var envelope Envelope
			check(t, json.Unmarshal(raw, &envelope))
			if err := a.acceptFrom(t.Context(), b.id, b.id, 1, envelope); err == nil {
				t.Fatal("corrupted snapshot accepted")
			}
		})
	}
}

func TestBackgroundLearnsNewPairWithoutRestart(t *testing.T) {
	host, reader := testStore(t), testStore(t)
	hub := privateRelayForTest(t)
	// Use a loopback-only direct configuration; no incoming test connection can
	// bypass the gateway. The invitation runs through a distinct SQLite connection.
	check(t, host.set("listen", defaultPeerListen))
	second, err := openStore(host.dir, host.home)
	check(t, err)
	defer second.db.Close()
	conf, err := host.tlsConfig("")
	check(t, err)
	ctx, cancel := context.WithCancel(t.Context())
	stopped := make(chan struct{})
	go func() { defer close(stopped); host.maintainPeerListeners(ctx, conf, "") }()
	defer func() {
		cancel()
		select {
		case <-stopped:
		case <-time.After(5 * time.Second):
			t.Error("manager did not release listener")
		}
	}()
	check(t, second.trustPaired(reader.id, "", "viewer", hub.URL, "临时查看"))
	check(t, reader.trustPaired(host.id, "", "source", hub.URL, "Mac"))
	until := time.Now().Add(5 * time.Second)
	for {
		_, err := reader.remoteReport(ctx, "any", "", "", "")
		if err == nil {
			break
		}
		if time.Now().After(until) {
			t.Fatal("daemon did not accept new pairing", err)
		}
		time.Sleep(100 * time.Millisecond)
	}
	check(t, second.removePeer(reader.id))
	until = time.Now().Add(5 * time.Second)
	for {
		conn, err := relay.Dial(ctx, hub.URL, reader.key, host.id)
		if err != nil {
			break
		}
		conn.Close()
		if time.Now().After(until) {
			t.Fatal("daemon kept an advertised relay identity after last grant was removed")
		}
		time.Sleep(200 * time.Millisecond)
	}
}

func TestQuotaWindowsPreserveNumbersAndRejectInvalidUnits(t *testing.T) {
	s := testStore(t)
	q := Quota{Provider: "service", Account: s.id, Observed: time.Now().UTC().Format(time.RFC3339),
		Windows: []Window{{ID: "monthly", Label: "额度", RemainingAmount: "123456789012345678.345", UsedAmount: "0", Unit: "积分"}}}
	envelope := func(q Quota) Envelope {
		t.Helper()
		check(t, s.publish(nil, []Quota{q}, 0))
		var raw []byte
		check(t, s.db.QueryRow("SELECT body FROM replicas WHERE id=?", s.id).Scan(&raw))
		var env Envelope
		check(t, json.Unmarshal(raw, &env))
		return env
	}
	first, err := verify(envelope(q))
	check(t, err)
	if first.Quotas[0].Windows[0].Remaining != nil || first.Quotas[0].Windows[0].RemainingAmount != q.Windows[0].RemainingAmount {
		t.Fatal("lost quantity-only quota")
	}
	q.Windows[0].Unit = "USD\r\n"
	if _, err := verify(envelope(q)); err == nil {
		t.Fatal("accepted unsafe unit")
	}
	q.Windows[0].Unit = "USD"
	q.Windows[0].TotalAmount = "1e99999999"
	if _, err := verify(envelope(q)); err == nil {
		t.Fatal("accepted invalid quota amount")
	}
}

func TestSharedPortKeepsRelayAvailableButOneDaemonPerIdentity(t *testing.T) {
	s := testStore(t)
	release, err := s.lockDeviceService()
	check(t, err)
	defer release()
	second, err := openStore(s.dir, s.home)
	check(t, err)
	defer second.db.Close()
	if duplicate, err := second.lockDeviceService(); err == nil {
		duplicate()
		t.Fatal("two daemons claimed the same profile")
	}
	cfg, err := s.tlsConfig("")
	check(t, err)
	holder, err := net.Listen("tcp", "127.0.0.1:0")
	check(t, err)
	defer holder.Close()
	taken := holder.Addr().String()
	fallback, retry, err := listenPeerTCP(taken, cfg)
	check(t, err)
	defer fallback.Close()
	if retry != taken || fallback.Addr().String() == taken {
		t.Fatal("no alternate private listener while a port was occupied", retry)
	}
}

func TestFreshPairOffersOnePrivateLANPathAlongsideRelay(t *testing.T) {
	host, remote := testStore(t), testStore(t)
	ctx := t.Context()
	check(t, host.addPeer(remote.id, "127.0.0.1:47732", "peer"))
	before, err := host.inboundPaths(ctx)
	check(t, err)
	if len(before) != 0 {
		t.Fatalf("pre-existing manual peer unexpectedly opted into new listeners: %+v", before)
	}
	base := "https://relay.example.invalid"
	check(t, host.trustPaired(remote.id, "", "peer", base))
	paths, err := host.inboundPaths(ctx)
	check(t, err)
	if !paths[peerListenerPath{"relay", base}] {
		t.Fatal("confirmed pairing omitted relay")
	}
	ipPort := host.pairDirectAddress()
	if ipPort == "" {
		if len(paths) != 1 {
			t.Fatalf("no LAN should use the relay: %+v", paths)
		}
		return
	}
	ip, port, err := net.SplitHostPort(ipPort)
	check(t, err)
	if port != "47732" || !device.PrivateAddress(ip) || !paths[peerListenerPath{"lan", ipPort}] || len(paths) != 2 {
		t.Fatalf("unexpected fresh-install direct path: %+v", paths)
	}
	check(t, host.set("listen", "127.0.0.1:47732"))
	paths, err = host.inboundPaths(ctx)
	check(t, err)
	if len(paths) != 1 || !paths[peerListenerPath{"relay", base}] {
		t.Fatal("explicit loopback choice was not honored")
	}
}
