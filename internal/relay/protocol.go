// Package relay establishes byte streams between outbound-only devices. The
// caller authenticates and encrypts the application protocol inside each stream.
package relay

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"net"
	"net/http"
	"net/url"
	"path"
	"regexp"
	"strings"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

const (
	RoomLifetime     = 10 * time.Minute
	connectPath      = "/v1/connect"
	protocol         = "tokenmeter.relay.v1"
	handshakeTimeout = 8 * time.Second
	answerTimeout    = 15 * time.Second
	controlLimit     = 2048
	frameLimit       = 64 << 10
)

var (
	ErrRoomExists   = errors.New("relay: room already exists")
	ErrRoomNotFound = errors.New("relay: invitation expired or unknown")
	ErrOffline      = errors.New("relay: device unavailable")
	ErrBusy         = errors.New("relay: capacity or rate limit reached")
	ErrDenied       = errors.New("relay: operation refused")
	roomPattern     = regexp.MustCompile(`^[a-z0-9]{6,16}$`)
)

// NormalizeBase permits plaintext only for local development or a local TLS proxy.
func NormalizeBase(base string) (string, error) {
	u, err := url.Parse(base)
	if err != nil || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || u.ForceQuery || u.RawPath != "" || strings.ContainsAny(base, "\\#") {
		return "", errors.New("relay: invalid service URL")
	}
	ip := net.ParseIP(u.Hostname())
	if u.Scheme != "https" && !(u.Scheme == "http" && (strings.EqualFold(u.Hostname(), "localhost") || ip.IsLoopback())) {
		return "", errors.New("relay: HTTPS required")
	}
	if strings.Contains(u.Path, "//") || path.Clean("/"+strings.Trim(u.Path, "/")) != "/"+strings.Trim(u.Path, "/") {
		return "", errors.New("relay: invalid service path")
	}
	u.Path = strings.TrimRight(u.Path, "/")
	return u.String(), nil
}

type packet struct {
	Type   string `json:"type"`
	ID     string `json:"id,omitempty"`
	Target string `json:"target,omitempty"`
	Room   string `json:"room,omitempty"`
	Ticket string `json:"ticket,omitempty"`
	Nonce  string `json:"nonce,omitempty"`
	Proof  string `json:"proof,omitempty"`
	Error  string `json:"error,omitempty"`
}

func randomToken() string {
	b := make([]byte, 32)
	rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)
}
func validID(id string) bool {
	b, err := hex.DecodeString(id)
	return err == nil && len(b) == ed25519.PublicKeySize && id == strings.ToLower(id)
}
func (p packet) signedBytes(nonce, authority string) []byte {
	return []byte(strings.Join([]string{protocol, strings.ToLower(authority), nonce, p.Type, p.ID, p.Target, p.Room, p.Ticket}, "\x00"))
}

func wireError(code string) error {
	switch code {
	case "notfound":
		return ErrRoomNotFound
	case "exists":
		return ErrRoomExists
	case "offline":
		return ErrOffline
	case "busy":
		return ErrBusy
	default:
		return ErrDenied
	}
}

var clientHTTP = &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}

// request signs an action and reads its acknowledgement. The connection is
// detached from the dial context once acknowledgement has completed.
func request(ctx context.Context, base string, key ed25519.PrivateKey, p packet) (*websocket.Conn, packet, error) {
	if len(key) != ed25519.PrivateKeySize && !(p.Type == "resolve" && len(key) == 0) {
		return nil, packet{}, ErrDenied
	}
	base, err := NormalizeBase(base)
	if err != nil {
		return nil, packet{}, err
	}
	u, _ := url.Parse(base + connectPath)
	if u.Scheme == "https" {
		u.Scheme = "wss"
	} else {
		u.Scheme = "ws"
	}
	ctx, cancel := context.WithTimeout(ctx, handshakeTimeout+answerTimeout)
	defer cancel()
	ws, _, err := websocket.Dial(ctx, u.String(), &websocket.DialOptions{HTTPClient: clientHTTP, Subprotocols: []string{protocol}})
	if err != nil {
		return nil, packet{}, err
	}
	fail := func(e error) (*websocket.Conn, packet, error) {
		ws.CloseNow()
		return nil, packet{}, e
	}
	if ws.Subprotocol() != protocol {
		return fail(ErrDenied)
	}
	ws.SetReadLimit(controlLimit)
	var challenge packet
	if err = wsjson.Read(ctx, ws, &challenge); err != nil {
		return fail(err)
	}
	nonce, err := base64.RawURLEncoding.DecodeString(challenge.Nonce)
	if challenge.Type != "challenge" || err != nil || len(nonce) != 32 {
		return fail(ErrDenied)
	}
	if len(key) != 0 {
		p.ID = hex.EncodeToString(key.Public().(ed25519.PublicKey))
		p.Proof = base64.RawURLEncoding.EncodeToString(ed25519.Sign(key, p.signedBytes(challenge.Nonce, u.Host)))
	}
	if err = wsjson.Write(ctx, ws, p); err != nil {
		return fail(err)
	}
	var reply packet
	if err = wsjson.Read(ctx, ws, &reply); err != nil {
		return fail(err)
	}
	if reply.Type != "ok" {
		return fail(wireError(reply.Error))
	}
	return ws, reply, nil
}

func CreateRoom(ctx context.Context, base string, key ed25519.PrivateKey, room string) error {
	if !roomPattern.MatchString(room) {
		return ErrDenied
	}
	c, _, e := request(ctx, base, key, packet{Type: "create", Room: room})
	if c != nil {
		c.CloseNow()
	}
	return e
}
func ResolveRoom(ctx context.Context, base, room string) (string, error) {
	if !roomPattern.MatchString(room) {
		return "", ErrRoomNotFound
	}
	c, reply, e := request(ctx, base, nil, packet{Type: "resolve", Room: room})
	if e != nil {
		return "", e
	}
	defer c.CloseNow()
	if !validID(reply.ID) {
		return "", ErrDenied
	}
	return reply.ID, nil
}
func CancelRoom(ctx context.Context, base string, key ed25519.PrivateKey, room string) error {
	if !roomPattern.MatchString(room) {
		return ErrDenied
	}
	c, _, e := request(ctx, base, key, packet{Type: "cancel", Room: room})
	if c != nil {
		c.CloseNow()
	}
	return e
}
