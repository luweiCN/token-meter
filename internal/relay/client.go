package relay

import (
	"context"
	"crypto/ed25519"
	"io"
	"math/rand/v2"
	"net"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

// A large net.Conn Write can span multiple bounded websocket messages.
type stream struct {
	net.Conn
	input net.Conn
	mu    sync.Mutex
}

func newStream(ws *websocket.Conn) net.Conn {
	c := websocket.NetConn(context.Background(), ws, websocket.MessageBinary)
	ws.SetReadLimit(frameLimit)
	// The HTTP/1 server periodically interrupts its pending Read to take
	// ownership of the connection for the next request. A websocket read
	// cancellation closes the entire transport. Keep that read on its own
	// side of a backpressured pipe so deadlines on the HTTP side are reusable.
	input, feed := net.Pipe()
	go func() {
		defer feed.Close()
		io.Copy(feed, c)
	}()
	return &stream{Conn: c, input: input}
}
func (s *stream) Read(b []byte) (int, error) { return s.input.Read(b) }

func (s *stream) SetReadDeadline(t time.Time) error { return s.input.SetReadDeadline(t) }

func (s *stream) SetDeadline(t time.Time) error {
	if err := s.SetReadDeadline(t); err != nil {
		return err
	}
	return s.SetWriteDeadline(t)
}

func (s *stream) Close() error {
	s.input.Close()
	return s.Conn.Close()
}

func (s *stream) Write(b []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	written := 0
	for len(b) > 0 {
		n, e := s.Conn.Write(b[:min(len(b), frameLimit)])
		written += n
		if e != nil {
			return written, e
		}
		b = b[n:]
	}
	return written, nil
}
func Dial(ctx context.Context, base string, key ed25519.PrivateKey, targetID string) (net.Conn, error) {
	if !validID(targetID) {
		return nil, ErrDenied
	}
	ws, _, err := request(ctx, base, key, packet{Type: "dial", Target: targetID})
	if err != nil {
		return nil, err
	}
	return newStream(ws), nil
}

type listener struct {
	ctx      context.Context
	cancel   context.CancelFunc
	base     string
	key      ed25519.PrivateKey
	incoming chan net.Conn
	finished chan struct{}
}
type relayAddr string

func (a relayAddr) Network() string { return "relay" }
func (a relayAddr) String() string  { return string(a) }

// Listen is ready when it returns. After a network outage it reconnects with
// backoff and jitter while Accept remains usable; Close cancels outstanding waits.
func Listen(ctx context.Context, base string, key ed25519.PrivateKey) (net.Listener, error) {
	base, e := NormalizeBase(base)
	if e != nil {
		return nil, e
	}
	c, _, e := request(ctx, base, key, packet{Type: "listen"})
	if e != nil {
		return nil, e
	}
	ctx, cancel := context.WithCancel(ctx)
	l := &listener{ctx: ctx, cancel: cancel, base: base, key: key, incoming: make(chan net.Conn), finished: make(chan struct{})}
	go l.run(c)
	return l, nil
}
func (l *listener) Addr() net.Addr { return relayAddr(l.base) }
func (l *listener) Accept() (net.Conn, error) {
	select {
	case c := <-l.incoming:
		return c, nil
	case <-l.ctx.Done():
		return nil, net.ErrClosed
	}
}
func (l *listener) Close() error {
	l.cancel()
	<-l.finished
	return nil
}
func (l *listener) run(c *websocket.Conn) {
	defer close(l.finished)
	var workers sync.WaitGroup
	defer workers.Wait()
	slots := make(chan struct{}, 8)
	for l.ctx.Err() == nil {
		for {
			var offer packet
			if wsjson.Read(l.ctx, c, &offer) != nil {
				break
			}
			if offer.Type != "offer" || len(offer.Ticket) != 43 {
				break
			}
			select {
			case slots <- struct{}{}:
				workers.Go(func() {
					defer func() { <-slots }()
					l.answer(offer.Ticket)
				})
			default:
				// The caller's bounded rendezvous deadline reclaims excess offers.
			}
		}
		c.CloseNow()
		delay := 250 * time.Millisecond
		for {
			select {
			case <-l.ctx.Done():
				return
			case <-time.After(delay + time.Duration(rand.Int64N(int64(delay/2)))):
			}
			var e error
			c, _, e = request(l.ctx, l.base, l.key, packet{Type: "listen"})
			if e == nil {
				break
			}
			delay = min(delay*2, 20*time.Second)
		}
	}
	c.CloseNow()
}
func (l *listener) answer(ticket string) {
	ctx, cancel := context.WithTimeout(l.ctx, answerTimeout)
	defer cancel()
	c, _, err := request(ctx, l.base, l.key, packet{Type: "answer", Ticket: ticket})
	if err != nil {
		return
	}
	conn := newStream(c)
	select {
	case l.incoming <- conn:
	case <-ctx.Done():
		conn.Close()
	}
}
