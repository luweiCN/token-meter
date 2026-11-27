package main

import (
	"context"
	"crypto/tls"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"math/rand/v2"
	"net"
	"net/http"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/luweiCN/token-meter/internal/device"
	"github.com/luweiCN/token-meter/internal/relay"
)

// Pick a single private interface for the optional fast path. Devices without
// such an interface can pair and sync over their outbound relay connection.
func (s *Store) pairDirectAddress() string {
	listen := s.setting("listen", "")
	port := "47732"
	if listen != "" {
		host, p, err := net.SplitHostPort(listen)
		if err != nil || p == "0" {
			return ""
		}
		port = p
		if device.PrivateAddress(host) {
			return listen
		}
		ip := net.ParseIP(host)
		if host != "" && (ip == nil || !ip.IsUnspecified()) {
			return ""
		}
	}
	faces, err := net.Interfaces()
	if err != nil {
		return ""
	}
	var fallback string
	for _, dev := range faces {
		if dev.Flags&net.FlagUp == 0 || dev.Flags&net.FlagLoopback != 0 {
			continue
		}
		addresses, err := dev.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addresses {
			ip, _, err := net.ParseCIDR(addr.String())
			if err != nil || !ip.IsPrivate() {
				continue
			}
			address := net.JoinHostPort(ip.String(), port)
			if ip.To4() != nil {
				return address
			}
			if fallback == "" {
				fallback = address
			}
		}
	}
	return fallback
}

// Multiple device profiles can share a computer. The service lock belongs
// to the state directory, so two supervisors never poll a single account.
func (s *Store) lockDeviceService() (func(), error) {
	db, err := sql.Open("sqlite", sqlitePath(filepath.Join(s.dir, "daemon-lock.sqlite"))+"?_txlock=immediate&_pragma=busy_timeout(250)")
	if err != nil {
		return nil, err
	}
	lock, err := db.Begin()
	if err != nil {
		db.Close()
		return nil, fmt.Errorf("cannot acquire device service lock: %w", err)
	}
	return func() { lock.Rollback(); db.Close() }, nil
}

func addressInUse(err error) bool {
	return errors.Is(err, syscall.EADDRINUSE) || (runtime.GOOS == "windows" && errors.Is(err, syscall.Errno(10048)))
}

// A node can leave its configured LAN or share a host port with another
// application. Local collection and relay access remain available in either case.
func listenPeerTCP(address string, conf *tls.Config) (net.Listener, string, error) {
	ln, err := tls.Listen("tcp", address, conf)
	missing := errors.Is(err, syscall.EADDRNOTAVAIL) || (runtime.GOOS == "windows" && errors.Is(err, syscall.Errno(10049)))
	if !missing && !addressInUse(err) {
		return ln, "", err
	}
	_, port, err := net.SplitHostPort(address)
	if err != nil {
		return nil, "", err
	}
	if missing && port != "0" {
		ln, err = tls.Listen("tcp", net.JoinHostPort("127.0.0.1", port), conf)
		if !addressInUse(err) {
			return ln, address, err
		}
	}
	ln, err = tls.Listen("tcp", "127.0.0.1:0", conf)
	return ln, address, err
}

func (s *Store) servePeerListener(ctx context.Context, ln net.Listener) error {
	server := &http.Server{
		Handler: s.handler(), ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout: 20 * time.Second, WriteTimeout: 30 * time.Second,
		IdleTimeout: 30 * time.Second, MaxHeaderBytes: 16 << 10,
		BaseContext: func(net.Listener) context.Context { return ctx },
	}
	// Close both pending Accept and in-flight requests on shutdown or revocation.
	defer server.Close()
	stop := context.AfterFunc(ctx, func() { ln.Close(); server.Close() })
	defer stop()
	err := server.Serve(ln)
	if ctx.Err() != nil || errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

type peerListenerPath struct {
	kind    string
	address string
}

func (s *Store) inboundPaths(ctx context.Context) (map[peerListenerPath]bool, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT DISTINCT r.v FROM peers p JOIN settings r ON r.k='peer.relay.'||p.id
		WHERE p.role IN ('viewer','peer') AND r.v<>''`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	paths := make(map[peerListenerPath]bool)
	for rows.Next() {
		var base string
		if err := rows.Scan(&base); err != nil {
			return nil, err
		}
		paths[peerListenerPath{"relay", base}] = true
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if len(paths) != 0 && s.setting("listen", "") == "" {
		if addr := s.pairDirectAddress(); addr != "" {
			paths[peerListenerPath{"lan", addr}] = true
		}
	}
	return paths, nil
}

func (s *Store) maintainPeerListeners(ctx context.Context, conf *tls.Config, missingAddress string) {
	active := make(map[peerListenerPath]context.CancelFunc)
	var tasks sync.WaitGroup
	defer func() {
		for _, stop := range active {
			stop()
		}
		tasks.Wait()
	}()
	// Pairing and revocation can occur in a separate CLI process.
	// Poll the indexed routes locally; no outbound connection is made without a grant.
	tick := time.NewTicker(2 * time.Second)
	defer tick.Stop()
	for ctx.Err() == nil {
		paths, err := s.inboundPaths(ctx)
		if err == nil {
			if missingAddress != "" {
				paths[peerListenerPath{"lan", missingAddress}] = true
			}
			for path, stop := range active {
				if !paths[path] {
					stop()
					delete(active, path)
				}
			}
			for path := range paths {
				if _, ok := active[path]; ok {
					continue
				}
				scope, cancel := context.WithCancel(ctx)
				active[path] = cancel
				tasks.Go(func() { s.runPeerListener(scope, path, conf) })
			}
		} else if ctx.Err() == nil {
			log.Printf("device connection settings: %v", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}

func (s *Store) runPeerListener(ctx context.Context, path peerListenerPath, conf *tls.Config) {
	delay := time.Second
	var lastFailure string
	for ctx.Err() == nil {
		var ln net.Listener
		var err error
		if path.kind == "relay" {
			ln, err = relay.Listen(ctx, path.address, s.key)
		} else {
			var lc net.ListenConfig
			ln, err = lc.Listen(ctx, "tcp", path.address)
		}
		if err == nil {
			delay = time.Second
			lastFailure = ""
			err = s.servePeerListener(ctx, tls.NewListener(ln, conf))
		}
		if ctx.Err() != nil {
			return
		}
		if err != nil && err.Error() != lastFailure {
			lastFailure = err.Error()
			log.Printf("%s device listener: %s", path.kind, strings.ReplaceAll(lastFailure, "\n", " "))
		}
		wait := delay + time.Duration(rand.Int64N(int64(delay/4)))
		select {
		case <-ctx.Done():
			return
		case <-time.After(wait):
		}
		delay = min(30*time.Second, delay*2)
	}
}
