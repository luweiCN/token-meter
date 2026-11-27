package device

import (
	"context"
	"crypto/ed25519"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"time"

	"github.com/luweiCN/token-meter/internal/relay"
)

type Route struct {
	ID     string
	Direct string
	Relay  string
}

func (p Route) BaseURL() string {
	// HTTP uses the pinned device identity as its authority on both routes.
	return "https://" + p.ID + ".peer.invalid"
}

func PeerClient(key ed25519.PrivateKey, p Route, timeout time.Duration) (*http.Client, error) {
	config, err := TLSConfig(key, p.ID, nil)
	if err != nil {
		return nil, err
	}
	transport := &http.Transport{
		DialTLSContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return DialPeer(ctx, key, p, config)
		},
		MaxResponseHeaderBytes: 16 << 10,
		IdleConnTimeout:        25 * time.Second,
	}
	return &http.Client{Transport: transport, Timeout: timeout, CheckRedirect: func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse
	}}, nil
}

func DialPeer(ctx context.Context, key ed25519.PrivateKey, p Route, config *tls.Config) (net.Conn, error) {
	var directErr error
	if p.Direct != "" {
		directCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
		var dialer net.Dialer
		raw, err := dialer.DialContext(directCtx, "tcp", p.Direct)
		if err == nil {
			raw, err = handshakePeer(directCtx, raw, config)
		}
		cancel()
		if err == nil {
			return raw, nil
		}
		directErr = fmt.Errorf("direct connection: %w", err)
	}
	if p.Relay == "" {
		if directErr == nil {
			return nil, errors.New("no route to paired device")
		}
		return nil, directErr
	}
	relayCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	raw, err := relay.Dial(relayCtx, p.Relay, key, p.ID)
	if err == nil {
		raw, err = handshakePeer(relayCtx, raw, config)
	}
	if err != nil {
		return nil, errors.Join(directErr, fmt.Errorf("relay connection: %w", err))
	}
	return raw, nil
}

func handshakePeer(ctx context.Context, raw net.Conn, config *tls.Config) (net.Conn, error) {
	conn := tls.Client(raw, config)
	if err := conn.HandshakeContext(ctx); err != nil {
		raw.Close()
		return nil, err
	}
	return conn, nil
}

func PrivateAddress(host string) bool {
	ip, err := netip.ParseAddr(host)
	return err == nil && ip.Zone() == "" && ip.Unmap().IsPrivate()
}

func FetchJSON(ctx context.Context, c *http.Client, u string, limit int64, v any) error {
	req, e := http.NewRequestWithContext(ctx, "GET", u, nil)
	if e != nil {
		return e
	}
	res, e := c.Do(req)
	if e != nil {
		return e
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		return fmt.Errorf("HTTP %d", res.StatusCode)
	}
	data, e := io.ReadAll(io.LimitReader(res.Body, limit+1))
	if e != nil {
		return e
	}
	if int64(len(data)) > limit {
		return errors.New("response exceeds size limit")
	}
	return json.Unmarshal(data, v)
}

func ValidRange(from, to string) bool {
	for _, v := range []string{from, to} {
		if v != "" {
			if _, e := time.Parse(time.DateOnly, v); e != nil {
				return false
			}
		}
	}
	return from == "" || to == "" || from <= to
}

func QueryUsage(ctx context.Context, key ed25519.PrivateKey, route Route, host, from, to string, report any) error {
	client, err := PeerClient(key, route, 15*time.Second)
	if err != nil {
		return err
	}
	defer client.CloseIdleConnections()
	return FetchUsage(ctx, client, route, host, from, to, report)
}

func FetchUsage(ctx context.Context, client *http.Client, route Route, host, from, to string, report any) error {
	if !ValidRange(from, to) {
		return errors.New("invalid usage date range")
	}
	values := url.Values{"host": {host}, "from": {from}, "to": {to}}
	return FetchJSON(ctx, client, route.BaseURL()+"/v1/usage?"+values.Encode(), 16<<20, report)
}
