package relay

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/hex"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

func key(t *testing.T) (ed25519.PrivateKey, string) {
	t.Helper()
	pub, priv, e := ed25519.GenerateKey(nil)
	if e != nil {
		t.Fatal(e)
	}
	return priv, hex.EncodeToString(pub)
}
func service(t *testing.T) (*Server, string) {
	t.Helper()
	s := NewServer()
	srv := httptest.NewServer(s)
	t.Cleanup(func() { s.Close(); srv.Close() })
	return s, srv.URL
}
func TestRendezvous(t *testing.T) {
	s, url := service(t)
	a, id := key(t)
	b, _ := key(t)
	ctx := t.Context()
	room := "k8d123"
	if e := CreateRoom(ctx, url, a, room); e != nil {
		t.Fatal(e)
	}
	if e := CreateRoom(ctx, url, b, room); !errors.Is(e, ErrRoomExists) {
		t.Fatalf("collision: %v", e)
	}
	if got, e := ResolveRoom(ctx, url, room); e != nil || got != id {
		t.Fatalf("resolve: %s %v", got, e)
	}
	if e := CancelRoom(ctx, url, b, room); !errors.Is(e, ErrDenied) {
		t.Fatalf("wrong owner: %v", e)
	}
	if e := CancelRoom(ctx, url, a, room); e != nil {
		t.Fatal(e)
	}
	if _, e := ResolveRoom(ctx, url, room); !errors.Is(e, ErrRoomNotFound) {
		t.Fatalf("revoked: %v", e)
	}
	if e := CreateRoom(ctx, url, a, room); e != nil {
		t.Fatal(e)
	}
	s.mu.Lock()
	s.rooms[room].expires = time.Now().Add(-time.Second)
	s.mu.Unlock()
	if _, e := ResolveRoom(ctx, url, room); !errors.Is(e, ErrRoomNotFound) {
		t.Fatalf("expired: %v", e)
	}
	if e := CreateRoom(ctx, url, b, room); e != nil {
		t.Fatal(e)
	}
}
func exerciseDuplex(t *testing.T, url string) {
	t.Helper()
	source, _ := key(t)
	dest, destID := key(t)
	listenerContext, stop := context.WithCancel(t.Context())
	defer stop()
	l, e := Listen(listenerContext, url, dest)
	if e != nil {
		t.Fatal(e)
	}
	defer l.Close()
	if _, e = Listen(t.Context(), url, dest); !errors.Is(e, ErrBusy) {
		t.Fatalf("duplicate listener: %v", e)
	}
	dialCtx, endDial := context.WithTimeout(t.Context(), 5*time.Second)
	client, e := Dial(dialCtx, url, source, destID)
	endDial()
	if e != nil {
		t.Fatal(e)
	}
	defer client.Close()
	server, e := l.Accept()
	if e != nil {
		t.Fatal(e)
	}
	defer server.Close()
	// Prove independent connection lifetimes on both ends.
	if e = l.Close(); e != nil {
		t.Fatal(e)
	}
	// Interrupt an active read just as net/http does between requests.
	waiting := make(chan error, 1)
	go func() { var b [1]byte; _, err := client.Read(b[:]); waiting <- err }()
	client.SetReadDeadline(time.Now().Add(3 * time.Millisecond))
	if err := <-waiting; !errors.Is(err, os.ErrDeadlineExceeded) {
		t.Fatalf("read deadline: %v", err)
	}
	if err := client.SetReadDeadline(time.Time{}); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(10 * time.Second)
	client.SetDeadline(deadline)
	server.SetDeadline(deadline)
	payload := bytes.Repeat([]byte("encrypted application payload "), frameLimit/6)
	write := make(chan error, 1)
	go func() { _, err := client.Write(payload); write <- err }()
	recv := make([]byte, len(payload))
	if _, e = io.ReadFull(server, recv); e != nil || !bytes.Equal(recv, payload) {
		t.Fatalf("delivery: %v", e)
	}
	if e = <-write; e != nil {
		t.Fatal(e)
	}
	if _, e = server.Write([]byte("reply")); e != nil {
		t.Fatal(e)
	}
	if _, e = io.ReadFull(client, recv[:5]); e != nil || string(recv[:5]) != "reply" {
		t.Fatalf("reverse: %v", e)
	}
}
func TestDuplexDetachedContexts(t *testing.T) {
	_, url := service(t)
	exerciseDuplex(t, url)
}
func TestPublicEndpoint(t *testing.T) {
	url := os.Getenv("TOKENMETER_TEST_RELAY")
	if url == "" {
		t.Skip("set TOKENMETER_TEST_RELAY to check an authorized live service")
	}
	exerciseDuplex(t, url)
}
func TestControlReconnects(t *testing.T) {
	s := NewServer()
	var mu sync.Mutex
	var last net.Conn
	srv := httptest.NewUnstartedServer(s)
	srv.Config.ConnState = func(c net.Conn, st http.ConnState) {
		if st == http.StateHijacked {
			mu.Lock()
			last = c
			mu.Unlock()
		}
	}
	srv.Start()
	t.Cleanup(func() { s.Close(); srv.Close() })
	priv, id := key(t)
	l, e := Listen(t.Context(), srv.URL, priv)
	if e != nil {
		t.Fatal(e)
	}
	defer l.Close()
	s.mu.Lock()
	first := s.controls[id]
	s.mu.Unlock()
	mu.Lock()
	c := last
	mu.Unlock()
	if c == nil {
		t.Fatal("missing outbound control")
	}
	c.Close()
	deadline := time.Now().Add(6 * time.Second)
	for {
		s.mu.Lock()
		active := s.controls[id]
		s.mu.Unlock()
		if active != nil && active != first {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("control did not reconnect")
		}
		time.Sleep(10 * time.Millisecond)
	}
	p, _ := key(t)
	link, e := Dial(t.Context(), srv.URL, p, id)
	if e != nil {
		t.Fatal(e)
	}
	remote, e := l.Accept()
	if e != nil {
		t.Fatal(e)
	}
	remote.Close()
	link.Close()
}
func TestProofAndLimits(t *testing.T) {
	s, url := service(t)
	ctx := t.Context()
	_, id := key(t)
	c, _, e := websocket.Dial(ctx, url+connectPath, &websocket.DialOptions{Subprotocols: []string{protocol}})
	if e != nil {
		t.Fatal(e)
	}
	defer c.CloseNow()
	var p packet
	if e = wsjson.Read(ctx, c, &p); e != nil || p.Type != "challenge" {
		t.Fatalf("challenge: %v", e)
	}
	e = wsjson.Write(ctx, c, packet{Type: "listen", ID: id, Proof: string(bytes.Repeat([]byte("A"), 86))})
	if e != nil {
		t.Fatal(e)
	}
	if e = wsjson.Read(ctx, c, &p); e != nil || p.Error != "denied" {
		t.Fatalf("bad signature: %v", e)
	}
	s.mu.Lock()
	n := len(s.controls)
	s.mu.Unlock()
	if n != 0 {
		t.Fatal("unverified listener was retained")
	}
	k, _ := key(t)
	if _, e = Dial(ctx, url, k, id); !errors.Is(e, ErrOffline) {
		t.Fatalf("offline: %v", e)
	}
	for range 24 {
		_, e = ResolveRoom(ctx, url, "abcdef")
		if !errors.Is(e, ErrRoomNotFound) {
			t.Fatal(e)
		}
	}
	if _, e = ResolveRoom(ctx, url, "abcdef"); !errors.Is(e, ErrBusy) {
		t.Fatalf("lookup limit: %v", e)
	}
	for _, v := range []string{"http://example.com", "https://example.com/a/../b", "https://example.com/a%2fb", "https://user@example.com", "https://example.com?x=a", "https://example.com/#pin", "ws://localhost/test"} {
		if _, e := NormalizeBase(v); e == nil {
			t.Fatalf("unexpectedly accepted %q", v)
		}
	}
	if v, e := NormalizeBase("https://example.com/relay/"); e != nil || v != "https://example.com/relay" {
		t.Fatalf("prefix: %s %v", v, e)
	}
}
func TestTrafficBudgets(t *testing.T) {
	s := NewServerWithOptions(ServerOptions{WindowBytes: 1000, IPWindowBytes: 600, EgressBytesPerSecond: 1000})
	defer s.Close()
	releaseA, _ := s.acquire("a")
	defer releaseA()
	releaseB, _ := s.acquire("b")
	defer releaseB()
	if _, ok := s.reserve("a", "a", 250); !ok {
		t.Fatal("initial budget")
	}
	delay, ok := s.reserve("a", "b", 300)
	if !ok || delay <= 0 {
		t.Fatal("fair pacing missing")
	}
	if _, ok := s.reserve("a", "b", 51); ok {
		t.Fatal("per-IP budget not enforced")
	}
	if _, ok := s.reserve("a", "b", 50); !ok {
		t.Fatal("shared IP charged twice")
	}
}
