package device

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"io"
	"net"
	"net/url"
	"strings"
	"time"

	"github.com/luweiCN/token-meter/internal/relay"
)

const DefaultRelayURL = "https://tokenmeter.luwei.host"
const pairAlphabet = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
const pairLifetime = relay.RoomLifetime

type pairInvite struct{ room, manual, linkSecret string }

func newPairInvite() pairInvite {
	var raw [12]byte
	rand.Read(raw[:])
	for i, b := range raw {
		raw[i] = pairAlphabet[b&31]
	}
	var secret [24]byte
	rand.Read(secret[:])
	return pairInvite{room: strings.ToLower(string(raw[:6])), manual: string(raw[6:]), linkSecret: base64.RawURLEncoding.EncodeToString(secret[:])}
}
func (p pairInvite) code() string {
	full := strings.ToUpper(p.room) + p.manual
	return full[:4] + "-" + full[4:8] + "-" + full[8:]
}
func (p pairInvite) link() string {
	return "tokenmeter://pair/" + strings.ToUpper(p.room) + "#v1." + p.linkSecret
}
func (p pairInvite) password(mode string) string {
	switch mode {
	case "link":
		return p.linkSecret
	case "manual":
		return p.manual
	default:
		return ""
	}
}
func validPairLetters(value string) bool {
	return strings.IndexFunc(value, func(r rune) bool { return !strings.ContainsRune(pairAlphabet, r) }) < 0
}
func parsePairInvite(value string) (pairInvite, error) {
	var p pairInvite
	bad := errors.New("请输入 12 位配对码，或粘贴完整的 TokenMeter 邀请链接")
	value = strings.TrimSpace(value)
	if len(value) > 512 {
		return p, bad
	}
	if strings.Contains(value, ":") {
		u, err := url.Parse(value)
		if err != nil || u.Scheme != "tokenmeter" || u.Host != "pair" || u.User != nil || u.RawQuery != "" || u.ForceQuery || u.RawPath != "" {
			return p, bad
		}
		room := strings.ToUpper(strings.TrimPrefix(u.Path, "/"))
		secret, ok := strings.CutPrefix(u.Fragment, "v1.")
		b, err := base64.RawURLEncoding.Strict().DecodeString(secret)
		if !ok || err != nil || len(b) != 24 || len(room) != 6 || !validPairLetters(room) {
			return p, bad
		}
		return pairInvite{room: strings.ToLower(room), linkSecret: secret}, nil
	}
	value = strings.NewReplacer("-", "", " ", "").Replace(strings.ToUpper(value))
	if len(value) != 12 || !validPairLetters(value) {
		return p, bad
	}
	return pairInvite{room: strings.ToLower(value[:6]), manual: value[6:]}, nil
}

type PairEvent struct {
	State        string `json:"state"`
	Code         string `json:"code,omitempty"`
	URL          string `json:"url,omitempty"`
	ExpiresAt    string `json:"expiresAt,omitempty"`
	Name         string `json:"name,omitempty"`
	ID           string `json:"id,omitempty"`
	Role         string `json:"role,omitempty"`
	Verification string `json:"verification,omitempty"`
	CanApprove   bool   `json:"canApprove"`
	Message      string `json:"message,omitempty"`
}
type PairInteraction struct {
	Emit    func(PairEvent) error
	Approve func(context.Context) (bool, error)
}

type PreparedGrant interface {
	Commit() error
	Rollback() error
}

type Pairing struct {
	Key       ed25519.PrivateKey
	Name      string
	Address   string
	Preflight func(id, role string) error
	Prepare   func(peer PairIdentity, role, relayURL string) (PreparedGrant, error)
}

func (h pairHandshake) event(state string) PairEvent {
	return PairEvent{State: state, ID: h.peer.ID, Name: h.peer.Name, Role: h.role}
}
func RemoteRole(host bool, grant string) string {
	if !host && grant == "viewer" {
		return "source"
	}
	return grant
}

// A peer can read this node's history, so both peer owners must consent. A
// viewer receives a source-only entry: only the owner sharing data grants access.
func (p Pairing) finishPair(ctx context.Context, h pairHandshake, host bool, base string, ui PairInteraction) error {
	remoteRole := RemoteRole(host, h.role)
	if p.Preflight != nil {
		if err := p.Preflight(h.peer.ID, remoteRole); err != nil {
			return err
		}
	}
	event := h.event("confirm")
	event.Verification, event.CanApprove = h.verification, host || h.role == "peer"
	if err := ui.Emit(event); err != nil {
		return err
	}

	child, cancel := context.WithCancel(ctx)
	defer cancel()
	type signal struct {
		kind string
		err  error
	}
	signals := make(chan signal)
	go func() {
		for {
			packet, err := readPacket(h.conn, "")
			if err == nil && packet.Type == "keepalive" {
				continue
			}
			select {
			case signals <- signal{packet.Type, err}:
			case <-child.Done():
				return
			}
			if err != nil {
				return
			}
		}
	}()
	// Human confirmation can last most of the invitation's lifetime, including
	// on a relay that reclaims otherwise idle streams.
	go func() {
		tick := time.NewTicker(25 * time.Second)
		defer tick.Stop()
		for {
			select {
			case <-child.Done():
				return
			case <-tick.C:
				if sendPacket(h.conn, pairPacket{Type: "keepalive"}) != nil {
					return
				}
			}
		}
	}()

	type answer struct {
		yes bool
		err error
	}
	var answers <-chan answer
	if event.CanApprove {
		response := make(chan answer, 1)
		answers = response
		go func() { ok, err := ui.Approve(child); response <- answer{ok, err} }()
	}
	local, remote := !event.CanApprove, false
	if local {
		if err := sendPacket(h.conn, pairPacket{Type: "consent"}); err != nil {
			return err
		}
	}
	for !local || !remote {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case a := <-answers:
			answers = nil
			if a.err != nil {
				return a.err
			}
			if !a.yes {
				_ = sendPacket(h.conn, pairPacket{Type: "rejected"})
				return errPairRejected
			}
			if err := sendPacket(h.conn, pairPacket{Type: "consent"}); err != nil {
				return err
			}
			local = true
			if err := ui.Emit(h.event("waiting")); err != nil {
				return err
			}
		case sig := <-signals:
			if sig.err != nil {
				return sig.err
			}
			if remote || sig.kind != "consent" {
				return errPairProtocol
			}
			remote = true
		}
	}
	wait := func(want string) error {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case msg := <-signals:
			if msg.err != nil {
				return msg.err
			}
			if msg.kind != want {
				return errPairProtocol
			}
			return nil
		}
	}
	// Stage both local writes before either can grant access. If a disk rejects
	// a write or a role changed concurrently, the other node rolls back. No
	// database writer is held while a human is considering the invitation.
	deadline := time.Now().Add(8 * time.Second)
	if expires, ok := ctx.Deadline(); ok && expires.Before(deadline) {
		deadline = expires
	}
	if err := h.conn.SetDeadline(deadline); err != nil {
		return err
	}
	tx, err := p.Prepare(h.peer, remoteRole, base)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if host {
		if err := wait("ready"); err != nil {
			return err
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		if err := tx.Commit(); err != nil {
			return err
		}
		if err := sendPacket(h.conn, pairPacket{Type: "saved"}); err != nil {
			return errPairReceipt
		}
		if err := wait("saved"); err != nil {
			return errPairReceipt
		}
	} else {
		if err := sendPacket(h.conn, pairPacket{Type: "ready"}); err != nil {
			return err
		}
		if err := wait("saved"); err != nil {
			return err
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		if err := tx.Commit(); err != nil {
			return err
		}
		if err := sendPacket(h.conn, pairPacket{Type: "saved"}); err != nil {
			return errPairReceipt
		}
	}
	return ui.Emit(h.event("paired"))
}

var errPairReceipt = errors.New("本机已保存经过确认的设备，对端未返回完成回执；可重新配对核对")

func (p Pairing) Run(ctx context.Context, base, invitation, role string, ui PairInteraction) error {
	var inv *pairInvite
	if invitation != "" {
		parsed, err := parsePairInvite(invitation)
		if err != nil {
			return err
		}
		inv = &parsed
	}
	return p.run(ctx, base, inv, role, ui)
}

func (p Pairing) run(ctx context.Context, base string, inv *pairInvite, role string, ui PairInteraction) error {
	ctx, cancel := context.WithTimeout(ctx, pairLifetime)
	defer cancel()
	// A rendezvous lookup uses a one-time address, independent from the long-
	// lived device that serves authenticated replication connections.
	_, ephemeral, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	if inv != nil {
		if err = ui.Emit(PairEvent{State: "connecting"}); err != nil {
			return err
		}
		target, e := relay.ResolveRoom(ctx, base, inv.room)
		if e != nil {
			return e
		}
		raw, e := relay.Dial(ctx, base, ephemeral, target)
		if e != nil {
			return e
		}
		defer raw.Close()
		stop := context.AfterFunc(ctx, func() { raw.Close() })
		defer stop()
		h, e := p.pairHandshake(ctx, raw, inv, false, role)
		if e != nil {
			return e
		}
		return p.finishPair(ctx, h, false, base, ui)
	}
	listener, err := relay.Listen(ctx, base, ephemeral)
	if err != nil {
		return err
	}
	defer listener.Close()
	stop := context.AfterFunc(ctx, func() { listener.Close() })
	defer stop()
	var invitation pairInvite
	for {
		invitation = newPairInvite()
		err = relay.CreateRoom(ctx, base, ephemeral, invitation.room)
		if !errors.Is(err, relay.ErrRoomExists) {
			break
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
	}
	if err != nil {
		return err
	}
	defer func() {
		cleanup, done := context.WithTimeout(context.Background(), 2*time.Second)
		defer done()
		_ = relay.CancelRoom(cleanup, base, ephemeral, invitation.room)
	}()
	expiry, _ := ctx.Deadline()
	if err = ui.Emit(PairEvent{State: "invitation", Code: invitation.code(), URL: invitation.link(), ExpiresAt: expiry.UTC().Format(time.RFC3339), Role: role}); err != nil {
		return err
	}
	for range 3 {
		raw, e := listener.Accept()
		if e != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			return e
		}
		done := context.AfterFunc(ctx, func() { raw.Close() })
		h, e := p.pairHandshake(ctx, raw, &invitation, true, role)
		if e == nil {
			// Exactly one authenticated joiner reaches the approval step.
			// Stop accepting callers; CancelRoom on exit also removes the code.
			e = p.finishPair(ctx, h, true, base, ui)
			raw.Close()
			done()
			return e
		}
		raw.Close()
		done()
		if ctx.Err() != nil {
			return ctx.Err()
		}
	}
	return errors.New("多次验证失败，邀请已关闭；请重新生成配对码")
}

func PairErrorState(err error) (string, string) {
	switch {
	case errors.Is(err, context.DeadlineExceeded), errors.Is(err, relay.ErrRoomNotFound):
		return "expired", "邀请已过期或找不到，请在另一台设备重新生成"
	case errors.Is(err, context.Canceled), errors.Is(err, ErrPairCancelled):
		return "cancelled", "配对已取消"
	case errors.Is(err, errPairRejected):
		return "rejected", errPairRejected.Error()
	case errors.Is(err, relay.ErrOffline):
		return "error", "邀请设备当前离线，请保持另一台设备的配对窗口打开"
	case errors.Is(err, relay.ErrBusy):
		return "error", "配对服务当前繁忙，请稍后重试"
	case errors.Is(err, relay.ErrDenied):
		return "error", "配对服务拒绝了本次请求，请重新创建邀请"
	case errors.Is(err, errPairAuth):
		return "error", errPairAuth.Error()
	case errors.Is(err, io.EOF), errors.Is(err, net.ErrClosed):
		return "error", "对端已结束配对，请重新生成邀请"
	default:
		return "error", err.Error()
	}
}
