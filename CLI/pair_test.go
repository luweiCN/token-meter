package main

import (
	"bufio"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/luweiCN/token-meter/internal/device"
	"github.com/luweiCN/token-meter/internal/relay"
)

type pairTestProcess struct {
	in     *io.PipeWriter
	result <-chan error
	events <-chan device.PairEvent
}

func runJSONPair(t *testing.T, ctx context.Context, s *Store, args ...string) pairTestProcess {
	in, w := io.Pipe()
	out, writer := io.Pipe()
	events := make(chan device.PairEvent, 10)
	res := make(chan error, 1)
	go func() {
		defer close(events)
		defer out.Close()
		sc := bufio.NewScanner(out)
		for sc.Scan() {
			var e device.PairEvent
			if json.Unmarshal(sc.Bytes(), &e) != nil {
				return
			}
			events <- e
		}
	}()
	go func() {
		err := s.pairIO(ctx, append([]string{"--json"}, args...), in, writer)
		writer.Close()
		in.Close()
		res <- err
	}()
	t.Cleanup(func() { w.Close() })
	return pairTestProcess{w, res, events}
}
func (p pairTestProcess) next(t *testing.T, state string) device.PairEvent {
	t.Helper()
	select {
	case e, ok := <-p.events:
		if !ok || e.State != state {
			t.Fatalf("expected %s, received state=%q message=%s", state, e.State, e.Message)
		}
		return e
	case <-time.After(12 * time.Second):
		t.Fatalf("timed out awaiting %s", state)
	}
	return device.PairEvent{}
}
func (p pairTestProcess) send(t *testing.T, v any) {
	t.Helper()
	check(t, json.NewEncoder(p.in).Encode(v))
}
func (p pairTestProcess) done(t *testing.T, successful bool) {
	t.Helper()
	select {
	case e := <-p.result:
		if (e == nil) != successful {
			t.Fatalf("expected success=%v; error %v", successful, e)
		}
	case <-time.After(12 * time.Second):
		t.Fatal("pair process failed to exit")
	}
}
func pairTestHub(t *testing.T) string {
	t.Helper()
	hub := relay.NewServer()
	web := httptest.NewServer(hub)
	t.Cleanup(func() { hub.Close(); web.Close() })
	return web.URL
}
func assertPairRole(t *testing.T, s *Store, id, want string) {
	t.Helper()
	var role string
	err := s.db.QueryRow("SELECT role FROM peers WHERE id=?", id).Scan(&role)
	if want == "" {
		if !errors.Is(err, sql.ErrNoRows) {
			t.Fatalf("expected unpaired, role=%s err=%v", role, err)
		}
		return
	}
	check(t, err)
	if role != want {
		t.Fatalf("got role %s want %s", role, want)
	}
}

func TestPairAcrossRelayAndSingleUse(t *testing.T) {
	for _, kind := range []string{"peer", "viewer"} {
		t.Run(kind, func(t *testing.T) {
			base := pairTestHub(t)
			ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
			defer cancel()
			owner, joiner := testStore(t), testStore(t)
			check(t, owner.set("name", "家里的 Linux"))
			check(t, joiner.set("name", "我的 Mac"))
			check(t, owner.set("listen", "127.0.0.1:47732"))
			check(t, joiner.set("listen", "127.0.0.1:47732"))
			issuer := runJSONPair(t, ctx, owner, "--relay", base)
			inv := issuer.next(t, "invitation")
			invitation := inv.Code
			if kind == "viewer" {
				invitation = inv.URL
			}
			guest := runJSONPair(t, ctx, joiner, "--relay", base, "--role", kind, "--join-stdin")
			guest.send(t, map[string]string{"invitation": invitation})
			guest.next(t, "connecting")
			h, g := issuer.next(t, "confirm"), guest.next(t, "confirm")
			if h.ID != joiner.id || g.ID != owner.id || h.Name != "我的 Mac" || g.Name != "家里的 Linux" || h.Role != kind || g.Role != kind ||
				len(h.Verification) != 7 || h.Verification != g.Verification || !h.CanApprove || g.CanApprove != (kind == "peer") {
				t.Fatal("confirmation did not bind both devices, permissions and the same verification code")
			}
			assertPairRole(t, owner, joiner.id, "")
			assertPairRole(t, joiner, owner.id, "")
			issuer.send(t, map[string]bool{"approve": true})
			issuer.next(t, "waiting")
			if kind == "peer" {
				assertPairRole(t, owner, joiner.id, "")
				assertPairRole(t, joiner, owner.id, "")
				guest.send(t, map[string]bool{"approve": true})
				guest.next(t, "waiting")
			}
			guest.next(t, "paired")
			issuer.next(t, "paired")
			issuer.done(t, true)
			guest.done(t, true)
			assertPairRole(t, owner, joiner.id, kind)
			assertPairRole(t, joiner, owner.id, device.RemoteRole(false, kind))
			if owner.setting("peer.relay."+joiner.id, "") != base {
				t.Fatal("missing relay for subsequent connections")
			}
			replay := runJSONPair(t, ctx, joiner, "--relay", base, inv.Code)
			replay.next(t, "connecting")
			replay.next(t, "expired")
			replay.done(t, false)
		})
	}
}

func TestPairMistypedPasswordAndDenial(t *testing.T) {
	base := pairTestHub(t)
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	owner, joiner := testStore(t), testStore(t)
	issuer := runJSONPair(t, ctx, owner, "--relay", base, "--role", "viewer")
	inv := issuer.next(t, "invitation")
	changed := "A"
	if strings.HasSuffix(inv.Code, changed) {
		changed = "B"
	}
	wrong := runJSONPair(t, ctx, joiner, "--relay", base, inv.Code[:len(inv.Code)-1]+changed)
	wrong.next(t, "connecting")
	wrong.next(t, "error")
	wrong.done(t, false)
	assertPairRole(t, owner, joiner.id, "")
	assertPairRole(t, joiner, owner.id, "")
	guest := runJSONPair(t, ctx, joiner, "--relay", base, inv.Code)
	guest.next(t, "connecting")
	g := guest.next(t, "confirm")
	h := issuer.next(t, "confirm")
	if g.Role != "viewer" || h.Role != "viewer" {
		t.Fatal("issuer read-only permission was expanded")
	}
	issuer.send(t, map[string]bool{"approve": false})
	issuer.next(t, "rejected")
	guest.next(t, "rejected")
	issuer.done(t, false)
	guest.done(t, false)
	assertPairRole(t, owner, joiner.id, "")
	assertPairRole(t, joiner, owner.id, "")
}

func TestPairCancellation(t *testing.T) {
	t.Run("abandon", func(t *testing.T) {
		base := pairTestHub(t)
		owner, joiner := testStore(t), testStore(t)
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		host := runJSONPair(t, ctx, owner, "--relay", base)
		inv := host.next(t, "invitation")
		guestCtx, cancelGuest := context.WithCancel(ctx)
		guest := runJSONPair(t, guestCtx, joiner, "--relay", base, inv.URL)
		guest.next(t, "connecting")
		guest.next(t, "confirm")
		host.next(t, "confirm")
		cancelGuest()
		guest.done(t, false)
		host.done(t, false)
		assertPairRole(t, owner, joiner.id, "")
		assertPairRole(t, joiner, owner.id, "")
	})
}

func TestPairClosingGUIInvalidatesOutstandingInvitation(t *testing.T) {
	base := pairTestHub(t)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	owner, guest := testStore(t), testStore(t)
	host := runJSONPair(t, ctx, owner, "--relay", base)
	inv := host.next(t, "invitation")
	check(t, host.in.Close())
	host.next(t, "cancelled")
	host.done(t, false)
	replay := runJSONPair(t, ctx, guest, "--relay", base, inv.Code)
	replay.next(t, "connecting")
	replay.next(t, "expired")
	replay.done(t, false)
	assertPairRole(t, owner, guest.id, "")
}

func TestPairJoiningPeerCanDeclineAfterSeeingIdentity(t *testing.T) {
	base := pairTestHub(t)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	owner, guest := testStore(t), testStore(t)
	host := runJSONPair(t, ctx, owner, "--relay", base)
	inv := host.next(t, "invitation")
	join := runJSONPair(t, ctx, guest, "--relay", base, inv.Code)
	join.next(t, "connecting")
	host.next(t, "confirm")
	join.next(t, "confirm")
	host.send(t, map[string]bool{"approve": true})
	host.next(t, "waiting")
	join.send(t, map[string]bool{"approve": false})
	join.next(t, "rejected")
	host.next(t, "rejected")
	host.done(t, false)
	join.done(t, false)
	assertPairRole(t, owner, guest.id, "")
	assertPairRole(t, guest, owner.id, "")
}

func TestPairStorageErrorRollsBackRemoteGrant(t *testing.T) {
	for _, side := range []string{"joining", "inviting"} {
		t.Run(side, func(t *testing.T) {
			base := pairTestHub(t)
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			owner, guest := testStore(t), testStore(t)
			failing := guest
			if side == "inviting" {
				failing = owner
			}
			_, err := failing.db.Exec("CREATE TRIGGER simulate_storage_error BEFORE INSERT ON peers BEGIN SELECT RAISE(FAIL,'storage unavailable'); END")
			check(t, err)
			host := runJSONPair(t, ctx, owner, "--relay", base, "--role", "viewer")
			inv := host.next(t, "invitation")
			join := runJSONPair(t, ctx, guest, "--relay", base, inv.Code)
			join.next(t, "connecting")
			join.next(t, "confirm")
			host.next(t, "confirm")
			host.send(t, map[string]bool{"approve": true})
			host.next(t, "waiting")
			join.done(t, false)
			host.done(t, false)
			assertPairRole(t, owner, guest.id, "")
			assertPairRole(t, guest, owner.id, "")
		})
	}
}
