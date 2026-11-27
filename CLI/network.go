package main

import (
	"context"
	"crypto/tls"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/luweiCN/token-meter/internal/device"
)

func (s *Store) tlsConfig(expected string) (*tls.Config, error) {
	return device.TLSConfig(s.key, expected, func(id string) error {
		var role string
		if s.db.QueryRow("SELECT role FROM peers WHERE id=? AND role IN ('peer','viewer')", id).Scan(&role) != nil {
			return errors.New("unpaired device")
		}
		return nil
	})
}

func (s *Store) versions() (map[string]int64, error) {
	rows, e := s.db.Query("SELECT id,revision FROM replicas")
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	v := map[string]int64{}
	for rows.Next() {
		var id string
		var rev int64
		if e = rows.Scan(&id, &rev); e != nil {
			return nil, e
		}
		v[id] = rev
	}
	return v, rows.Err()
}
func (s *Store) handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "GET" {
			http.Error(w, "GET required", 405)
			return
		}
		if r.TLS == nil {
			http.Error(w, "TLS required", 403)
			return
		}
		var role string
		if s.db.QueryRow("SELECT role FROM peers WHERE id=? AND role IN ('peer','viewer')", device.RemoteID(*r.TLS)).Scan(&role) != nil {
			http.Error(w, "unpaired", 403)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		if r.URL.Path == "/v1/status" {
			json.NewEncoder(w).Encode(map[string]any{"protocol": 1, "id": s.id, "version": version})
			return
		}
		if r.URL.Path == "/v1/usage" {
			q := r.URL.Query()
			from, to := q.Get("from"), q.Get("to")
			if !device.ValidRange(from, to) {
				http.Error(w, "invalid date range", 400)
				return
			}
			v, e := s.report(q.Get("host"), from, to)
			if e != nil {
				http.Error(w, "unknown host or unavailable", 404)
				return
			}
			json.NewEncoder(w).Encode(v)
			return
		}
		if role != "peer" {
			http.Error(w, "replication requires peer access", 403)
			return
		}
		if r.URL.Path == "/v1/versions" {
			v, e := s.versions()
			if e != nil {
				http.Error(w, "storage unavailable", 500)
				return
			}
			json.NewEncoder(w).Encode(v)
			return
		}
		id, ok := strings.CutPrefix(r.URL.Path, "/v1/snapshots/")
		if !ok || !device.ValidID(id) {
			http.NotFound(w, r)
			return
		}
		var data []byte
		e := s.db.QueryRow("SELECT body FROM replicas WHERE id=?", id).Scan(&data)
		if errors.Is(e, sql.ErrNoRows) {
			http.NotFound(w, r)
			return
		}
		if e != nil {
			http.Error(w, "storage unavailable", 500)
			return
		}
		w.Write(data)
	})
}
func (s *Store) pull(ctx context.Context, peer peerRoute) error {
	c, e := s.peerClient(peer, 45*time.Second)
	if e != nil {
		return e
	}
	defer c.CloseIdleConnections()
	base := peer.BaseURL() + "/v1/"
	var versions map[string]int64
	if e = s.checkOutboundGrant(ctx, peer.ID, false); e != nil {
		return e
	}
	if e = device.FetchJSON(ctx, c, base+"versions", 1<<20, &versions); e != nil {
		return e
	}
	if len(versions) > 4096 {
		return errors.New("too many device snapshots")
	}
	known, e := s.versions()
	if e != nil {
		return e
	}
	for origin, rev := range versions {
		if !device.ValidID(origin) || rev < 1 {
			return errors.New("invalid snapshot inventory")
		}
		if known[origin] >= rev {
			continue
		}
		if e = s.checkOutboundGrant(ctx, peer.ID, false); e != nil {
			return e
		}
		var env Envelope
		if e = device.FetchJSON(ctx, c, base+"snapshots/"+origin, 64<<20, &env); e != nil {
			return e
		}
		if e = s.acceptFrom(ctx, peer.ID, origin, rev, env); e != nil {
			return e
		}
	}
	return nil
}
func (s *Store) sync(ctx context.Context) error {
	peers, e := s.peerRoutes(ctx, "", false)
	if e != nil {
		return e
	}
	var errs []error
	for _, peer := range peers {
		if err := ctx.Err(); err != nil {
			return err
		}
		err := s.pull(ctx, peer)
		if err != nil {
			errs = append(errs, fmt.Errorf("sync %.12s: %w", peer.ID, err))
		}
		errs = append(errs, s.recordPeerAttempt(ctx, peer.ID, err))
	}
	return errors.Join(append(errs, s.writeReport())...)
}
func (s *Store) serve(ctx context.Context) error {
	release, err := s.lockDeviceService()
	if err != nil {
		return err
	}
	defer release()
	addr := s.setting("listen", defaultPeerListen)
	conf, e := s.tlsConfig("")
	if e != nil {
		return e
	}
	ln, missingAddress, e := listenPeerTCP(addr, conf)
	if e != nil {
		return e
	}
	ctx, cancel := context.WithCancel(ctx)
	var workers sync.WaitGroup
	defer func() { cancel(); workers.Wait() }()
	workers.Go(func() { s.maintainPeerListeners(ctx, conf, missingAddress) })
	start := func(interval time.Duration, name string, fn func() error) {
		workers.Go(func() { periodic(ctx, interval, name, fn) })
	}
	start(15*time.Second, "activation", func() error {
		a, err := s.active()
		if err == nil && newer(a.Version, version) {
			cancel()
		}
		return err
	})
	workers.Go(func() { s.nativeLoop(ctx) })
	start(time.Minute, "accounts", func() error { return s.refreshAccounts(ctx, "", false) })
	start(time.Minute, "Codex reset cards", func() error { return s.checkResetCards(ctx) })
	start(time.Minute, "scan", s.scan)
	start(time.Minute, "sync", func() error { return s.sync(ctx) })
	start(30*time.Minute, "quota", func() error { return s.refreshClawQuota(ctx) })
	start(6*time.Hour, "update", func() error {
		if s.setting("auto-update", "true") != "true" {
			return nil
		}
		updated, e := s.update(ctx)
		if e == nil && updated {
			cancel()
		}
		return e
	})
	log.Printf("TokenMeter %s listening on %s", version, ln.Addr())
	return s.servePeerListener(ctx, ln)
}
func periodic(ctx context.Context, interval time.Duration, name string, fn func() error) {
	for ctx.Err() == nil {
		if e := fn(); e != nil {
			log.Printf("%s: %v", name, e)
		}
		timer := time.NewTimer(interval)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
	}
}
