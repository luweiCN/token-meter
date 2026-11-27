package relay

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

const (
	maxSockets     = 512
	maxIPSockets   = 48
	maxControls    = 192
	maxStreams     = 128
	maxPerDevice   = 8
	maxRooms       = 512
	maxIPs         = 4096
	maxStreamBytes = 256 << 20
	trafficWindow  = 10 * time.Minute
)

type ServerOptions struct {
	TrustLoopbackProxy   bool
	WindowBytes          int64
	IPWindowBytes        int64
	EgressBytesPerSecond int64
}
type counter struct {
	at   time.Time
	used int64
}

func (c *counter) available(t time.Time, d time.Duration, n, max int64) bool {
	if t.Sub(c.at) >= d {
		c.at = t
		c.used = 0
	}
	return n <= max-c.used
}

type ipState struct {
	open                       int
	requests, lookups, traffic counter
	last                       time.Time
}
type roomEntry struct {
	owner   string
	ip      string
	expires time.Time
	reads   counter
}
type leg struct {
	conn *websocket.Conn
	ip   string
}
type call struct {
	target  string
	owner   string
	answer  chan leg
	done    chan struct{}
	claimed bool
}
type control struct {
	offers chan packet
}
type Server struct {
	options   ServerOptions
	ctx       context.Context
	cancel    context.CancelFunc
	mu        sync.Mutex
	controls  map[string]*control
	calls     map[string]*call
	rooms     map[string]*roomEntry
	clients   map[string]*ipState
	open      int
	traffic   counter
	nextWrite time.Time
	nextSweep time.Time
}

func NewServer() *Server { return NewServerWithOptions(ServerOptions{}) }
func NewServerWithOptions(o ServerOptions) *Server {
	if o.WindowBytes <= 0 {
		o.WindowBytes = 4 << 30
	}
	if o.IPWindowBytes <= 0 {
		o.IPWindowBytes = 512 << 20
	}
	ctx, cancel := context.WithCancel(context.Background())
	return &Server{
		options: o, ctx: ctx, cancel: cancel,
		controls: make(map[string]*control), calls: make(map[string]*call),
		rooms: make(map[string]*roomEntry), clients: make(map[string]*ipState),
	}
}
func (s *Server) Close() error { s.cancel(); return nil }
func (s *Server) sweep(now time.Time) {
	if now.Before(s.nextSweep) {
		return
	}
	s.nextSweep = now.Add(time.Second)
	for code, r := range s.rooms {
		if !now.Before(r.expires) {
			delete(s.rooms, code)
		}
	}
	for ip, c := range s.clients {
		if c.open == 0 && now.Sub(c.last) >= trafficWindow {
			delete(s.clients, ip)
		}
	}
}
func (s *Server) acquire(ip string) (func(), bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now()
	s.sweep(now)
	if s.open >= maxSockets || s.ctx.Err() != nil {
		return nil, false
	}
	c := s.clients[ip]
	if c == nil {
		if len(s.clients) >= maxIPs {
			return nil, false
		}
		c = &ipState{}
		s.clients[ip] = c
	}
	c.last = now
	if c.open >= maxIPSockets || !c.requests.available(now, time.Minute, 1, 240) {
		return nil, false
	}
	c.open++
	s.open++
	c.requests.used++
	return func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		c.open--
		s.open--
		c.last = time.Now()
	}, true
}
func (s *Server) clientIP(r *http.Request) string {
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	if s.options.TrustLoopbackProxy && net.ParseIP(host).IsLoopback() {
		for _, header := range []string{"X-Real-IP", "X-Forwarded-For"} {
			if ip := net.ParseIP(strings.TrimSpace(r.Header.Get(header))); ip != nil {
				return ip.String()
			}
		}
	}
	if ip := net.ParseIP(host); ip != nil {
		return ip.String()
	}
	return "unknown"
}
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		http.Error(w, "GET required", 405)
		return
	}
	if r.URL.Path == "/healthz" {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Write([]byte("ok\n"))
		return
	}
	if r.URL.Path != connectPath || r.URL.RawQuery != "" {
		http.NotFound(w, r)
		return
	}
	if r.Header.Get("Sec-WebSocket-Protocol") != protocol {
		http.Error(w, "protocol required", 400)
		return
	}
	ip := s.clientIP(r)
	release, ok := s.acquire(ip)
	if !ok {
		http.Error(w, "busy", 429)
		return
	}
	defer release()
	ws, e := websocket.Accept(w, r, &websocket.AcceptOptions{Subprotocols: []string{protocol}})
	if e != nil {
		return
	}
	defer ws.CloseNow()
	ws.SetReadLimit(controlLimit)
	stop := context.AfterFunc(s.ctx, func() { ws.CloseNow() })
	defer stop()
	if s.ctx.Err() != nil {
		return
	}
	p, err := s.authenticate(ws, r.Host)
	if err != nil {
		return
	}
	switch p.Type {
	case "listen":
		s.listen(ws, p.ID)
	case "dial":
		s.dial(ws, ip, p.ID, p.Target)
	case "answer":
		s.answer(ws, ip, p.ID, p.Ticket)
	case "create", "resolve", "cancel":
		s.send(ws, s.room(ip, p))
	default:
		s.send(ws, packet{Type: "error", Error: "denied"})
	}
}
func (s *Server) authenticate(ws *websocket.Conn, authority string) (packet, error) {
	ctx, cancel := context.WithTimeout(s.ctx, handshakeTimeout)
	defer cancel()
	nonce := randomToken()
	if err := wsjson.Write(ctx, ws, packet{Type: "challenge", Nonce: nonce}); err != nil {
		return packet{}, err
	}
	var p packet
	if err := wsjson.Read(ctx, ws, &p); err != nil {
		return packet{}, err
	}
	if !validRequest(p) {
		s.send(ws, packet{Type: "error", Error: "denied"})
		return packet{}, ErrDenied
	}
	if p.Type == "resolve" {
		return p, nil
	}
	key, _ := hex.DecodeString(p.ID)
	sig, e := base64.RawURLEncoding.DecodeString(p.Proof)
	if e != nil || !ed25519.Verify(key, p.signedBytes(nonce, authority), sig) {
		s.send(ws, packet{Type: "error", Error: "denied"})
		return packet{}, ErrDenied
	}
	return p, nil
}
func validRequest(p packet) bool {
	if p.Nonce != "" || p.Error != "" {
		return false
	}
	if p.Type == "resolve" {
		return p.ID == "" && p.Proof == "" && p.Ticket == "" && p.Target == "" && roomPattern.MatchString(p.Room)
	}
	if !validID(p.ID) || len(p.Proof) != 86 {
		return false
	}
	switch p.Type {
	case "listen":
		return p.Target == "" && p.Room == "" && p.Ticket == ""
	case "dial":
		return p.ID != p.Target && validID(p.Target) && p.Room == "" && p.Ticket == ""
	case "answer":
		t, e := base64.RawURLEncoding.DecodeString(p.Ticket)
		return p.Target == "" && p.Room == "" && e == nil && len(t) == 32
	case "create", "cancel":
		return p.Target == "" && p.Ticket == "" && roomPattern.MatchString(p.Room)
	default:
		return false
	}
}
func (s *Server) send(ws *websocket.Conn, p packet) error {
	ctx, cancel := context.WithTimeout(s.ctx, handshakeTimeout)
	defer cancel()
	return wsjson.Write(ctx, ws, p)
}
func (s *Server) room(ip string, p packet) packet {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now()
	r := s.rooms[p.Room]
	if r != nil && !now.Before(r.expires) {
		delete(s.rooms, p.Room)
		r = nil
	}
	bad := func(code string) packet { return packet{Type: "error", Error: code} }
	switch p.Type {
	case "create":
		if r != nil {
			return bad("exists")
		}
		if len(s.rooms) >= maxRooms {
			return bad("busy")
		}
		numRooms := 0
		for _, entry := range s.rooms {
			if entry.ip == ip {
				numRooms++
			}
			if entry.owner == p.ID {
				return bad("busy")
			}
		}
		if numRooms >= 12 {
			return bad("busy")
		}
		s.rooms[p.Room] = &roomEntry{owner: p.ID, ip: ip, expires: now.Add(RoomLifetime)}
	case "cancel":
		if r != nil && r.owner != p.ID {
			return bad("denied")
		}
		delete(s.rooms, p.Room)
	case "resolve":
		lookups := &s.clients[ip].lookups
		if !lookups.available(now, time.Minute, 1, 24) {
			return bad("busy")
		}
		lookups.used++
		if r == nil {
			return bad("notfound")
		}
		if !r.reads.available(now, time.Minute, 1, 12) {
			return bad("busy")
		}
		r.reads.used++
		return packet{Type: "ok", ID: r.owner}
	}
	return packet{Type: "ok"}
}
func (s *Server) listen(ws *websocket.Conn, id string) {
	c := &control{offers: make(chan packet, maxPerDevice)}
	s.mu.Lock()
	if len(s.controls) >= maxControls || s.controls[id] != nil {
		s.mu.Unlock()
		s.send(ws, packet{Type: "error", Error: "busy"})
		return
	}
	s.controls[id] = c
	s.mu.Unlock()
	defer func() { s.mu.Lock(); delete(s.controls, id); s.mu.Unlock() }()
	if s.send(ws, packet{Type: "ok"}) != nil {
		return
	}
	ctx := ws.CloseRead(s.ctx)
	timer := time.NewTicker(25 * time.Second)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case offer := <-c.offers:
			if s.send(ws, offer) != nil {
				return
			}
		case <-timer.C:
			ping, cancel := context.WithTimeout(ctx, 8*time.Second)
			err := ws.Ping(ping)
			cancel()
			if err != nil {
				return
			}
		}
	}
}
func (s *Server) startCall(sender, target string) (string, *call, string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.controls[target]
	if c == nil {
		return "", nil, "offline"
	}
	if len(s.calls) >= maxStreams {
		return "", nil, "busy"
	}
	from, to := 0, 0
	for _, p := range s.calls {
		if p.owner == sender {
			from++
		}
		if p.target == target {
			to++
		}
	}
	if from >= maxPerDevice || to >= maxPerDevice {
		return "", nil, "busy"
	}
	ticket := randomToken()
	p := &call{target: target, owner: sender, answer: make(chan leg), done: make(chan struct{})}
	select {
	case c.offers <- packet{Type: "offer", Ticket: ticket}:
		s.calls[ticket] = p
		return ticket, p, ""
	default:
		return "", nil, "busy"
	}
}
func (s *Server) dial(ws *websocket.Conn, ip, sender, target string) {
	ticket, p, code := s.startCall(sender, target)
	if code != "" {
		s.send(ws, packet{Type: "error", Error: code})
		return
	}
	defer func() { s.mu.Lock(); delete(s.calls, ticket); close(p.done); s.mu.Unlock() }()
	timer := time.NewTimer(answerTimeout)
	defer timer.Stop()
	select {
	case <-s.ctx.Done():
		return
	case <-timer.C:
		s.send(ws, packet{Type: "error", Error: "offline"})
	case other := <-p.answer:
		if s.send(ws, packet{Type: "ok"}) == nil {
			s.bridge(ws, other.conn, ip, other.ip)
		}
	}
}
func (s *Server) answer(ws *websocket.Conn, ip, id, ticket string) {
	s.mu.Lock()
	p := s.calls[ticket]
	if p == nil || p.target != id || p.claimed {
		s.mu.Unlock()
		s.send(ws, packet{Type: "error", Error: "denied"})
		return
	}
	p.claimed = true
	s.mu.Unlock()
	if s.send(ws, packet{Type: "ok"}) != nil {
		return
	}
	select {
	case p.answer <- leg{conn: ws, ip: ip}:
		select {
		case <-p.done:
		case <-s.ctx.Done():
		}
	case <-p.done:
	case <-s.ctx.Done():
	}
}
