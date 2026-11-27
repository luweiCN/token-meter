package device

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/tls"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/bytemare/opaque"
)

const pairProtocol = "tokenmeter-pair/1"

var (
	errPairProtocol  = errors.New("对方发送了无法识别的配对数据")
	errPairAuth      = errors.New("配对码未通过验证，请核对两台设备显示的邀请")
	errPairRejected  = errors.New("配对已被拒绝")
	ErrPairCancelled = errors.New("配对已取消")
)

type PairIdentity struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Address string `json:"address,omitempty"`
}

type pairPacket struct {
	Type   string        `json:"type"`
	Mode   string        `json:"mode,omitempty"`
	Role   string        `json:"role,omitempty"`
	Data   []byte        `json:"data,omitempty"`
	Device *PairIdentity `json:"device,omitempty"`
}

func sendPacket(w io.Writer, packet pairPacket) error {
	data, err := json.Marshal(packet)
	if err != nil {
		return err
	}
	if len(data) > 4096 {
		return errPairProtocol
	}
	frame := binary.BigEndian.AppendUint16(nil, uint16(len(data)))
	_, err = w.Write(append(frame, data...))
	return err
}

func readPacket(r io.Reader, want string) (pairPacket, error) {
	var packet pairPacket
	var length [2]byte
	if _, err := io.ReadFull(r, length[:]); err != nil {
		return packet, err
	}
	n := binary.BigEndian.Uint16(length[:])
	if n == 0 || n > 4096 {
		return packet, errPairProtocol
	}
	data := make([]byte, n)
	if _, err := io.ReadFull(r, data); err != nil {
		return packet, err
	}
	if err := json.Unmarshal(data, &packet); err != nil {
		return packet, errPairProtocol
	}
	if packet.Type == "rejected" {
		return packet, errPairRejected
	}
	if want != "" && packet.Type != want {
		return packet, errPairProtocol
	}
	return packet, nil
}

func ValidPairName(name string) bool {
	if name == "" || len(name) > 255 || !utf8.ValidString(name) || strings.TrimSpace(name) != name {
		return false
	}
	return strings.IndexFunc(name, func(r rune) bool {
		return unicode.IsControl(r) || unicode.In(r, unicode.Cf, unicode.Zl, unicode.Zp)
	}) < 0
}

func (p Pairing) localPairIdentity() (PairIdentity, error) {
	if !ValidPairName(p.Name) {
		return PairIdentity{}, errors.New("设备名称无效")
	}
	return PairIdentity{ID: ID(p.Key), Name: p.Name, Address: p.Address}, nil
}

// The TLS certificate keys are the device identities. During initial enrollment
// OPAQUE binds this exact TLS session, both keys and the requested permission
// before names, addresses or authorization decisions can cross the connection.
func (p Pairing) pairingTLS(ctx context.Context, conn net.Conn, inviting bool) (*tls.Conn, string, []byte, error) {
	cert, err := Certificate(p.Key)
	if err != nil {
		return nil, "", nil, err
	}
	cfg := &tls.Config{
		MinVersion: tls.VersionTLS13, MaxVersion: tls.VersionTLS13,
		Certificates: []tls.Certificate{cert}, NextProtos: []string{pairProtocol},
		SessionTicketsDisabled: true,
		VerifyConnection: func(state tls.ConnectionState) error {
			peer := RemoteID(state)
			if state.NegotiatedProtocol != pairProtocol || !ValidID(peer) || peer == ID(p.Key) {
				return errPairAuth
			}
			return nil
		},
	}
	var stream *tls.Conn
	if inviting {
		cfg.ClientAuth = tls.RequireAnyClientCert
		stream = tls.Server(conn, cfg)
	} else {
		// First pairing has no CA or pre-existing public key pin. OPAQUE verifies
		// the enrolled keys and TLS exporter before this stream carries user data.
		cfg.InsecureSkipVerify = true
		stream = tls.Client(conn, cfg)
	}
	if err = stream.HandshakeContext(ctx); err != nil {
		return nil, "", nil, err
	}
	state := stream.ConnectionState()
	binding, err := state.ExportKeyingMaterial("EXPORTER-TokenMeter-pair-v1", nil, 32)
	return stream, RemoteID(state), binding, err
}

func pairConfig(room, role string, binding []byte) *opaque.Configuration {
	cfg := opaque.DefaultConfiguration()
	cfg.Context = append([]byte(pairProtocol+"\x00"+room+"\x00"+role+"\x00"), binding...)
	return cfg
}

// The fixed profile also works with Argon2 libraries that require the RFC's
// minimum salt length. Both sides already have this session-specific context.
func pairPasswordOptions(cfg *opaque.Configuration) *opaque.ClientOptions {
	digest := sha256.Sum256(cfg.Context)
	return &opaque.ClientOptions{KSFSalt: digest[:16], KSFParameters: []uint64{3, 64 * 1024, 4}, KSFLength: 32}
}

func opaqueHost(conn net.Conn, cfg *opaque.Configuration, password []byte, host, join string) ([]byte, error) {
	packet, err := readPacket(conn, "ke1")
	if err != nil {
		return nil, err
	}
	server, err := cfg.Server()
	if err != nil {
		return nil, err
	}
	ke1, err := server.Deserialize.KE1(packet.Data)
	if err != nil {
		return nil, errPairAuth
	}
	priv, pub := cfg.KeyGen()
	if err = server.SetKeyMaterial(&opaque.ServerKeyMaterial{Identity: []byte(host), PrivateKey: priv, PublicKeyBytes: pub.Encode(), OPRFGlobalSeed: cfg.GenerateOPRFSeed()}); err != nil {
		return nil, err
	}
	// Registration is local and ephemeral. The public rendezvous never holds a
	// password record, and even a malicious transport gets only an online guess.
	client, err := cfg.Client()
	if err != nil {
		return nil, err
	}
	defer client.ClearState()
	req, err := client.RegistrationInit(password)
	if err != nil {
		return nil, err
	}
	credID := opaque.RandomBytes(32)
	resp, err := server.RegistrationResponse(req, credID, nil)
	if err != nil {
		return nil, err
	}
	record, _, err := client.RegistrationFinalize(resp, []byte(join), []byte(host), pairPasswordOptions(cfg))
	if err != nil {
		return nil, err
	}
	ke2, secrets, err := server.GenerateKE2(ke1, &opaque.ClientRecord{
		CredentialIdentifier: credID, ClientIdentity: []byte(join), RegistrationRecord: record,
	})
	if err != nil {
		return nil, err
	}
	if err = sendPacket(conn, pairPacket{Type: "ke2", Data: ke2.Serialize()}); err != nil {
		return nil, err
	}
	packet, err = readPacket(conn, "ke3")
	if err != nil {
		return nil, err
	}
	ke3, err := server.Deserialize.KE3(packet.Data)
	if err != nil {
		return nil, errPairAuth
	}
	if err = server.LoginFinish(ke3, secrets.ClientMAC); err != nil {
		return nil, errPairAuth
	}
	return secrets.SessionSecret, nil
}

func opaqueJoin(conn net.Conn, cfg *opaque.Configuration, password []byte, host, join string) ([]byte, error) {
	client, err := cfg.Client()
	if err != nil {
		return nil, err
	}
	defer client.ClearState()
	ke1, err := client.GenerateKE1(password)
	if err != nil {
		return nil, err
	}
	if err = sendPacket(conn, pairPacket{Type: "ke1", Data: ke1.Serialize()}); err != nil {
		return nil, err
	}
	packet, err := readPacket(conn, "ke2")
	if err != nil {
		return nil, err
	}
	ke2, err := client.Deserialize.KE2(packet.Data)
	if err != nil {
		return nil, errPairAuth
	}
	ke3, secret, _, err := client.GenerateKE3(ke2, []byte(join), []byte(host), pairPasswordOptions(cfg))
	if err != nil {
		return nil, errPairAuth
	}
	if err = sendPacket(conn, pairPacket{Type: "ke3", Data: ke3.Serialize()}); err != nil {
		return nil, err
	}
	return secret, nil
}

func readPairDevice(conn net.Conn, id string) (PairIdentity, error) {
	p, err := readPacket(conn, "device")
	if err != nil {
		return PairIdentity{}, err
	}
	if p.Device == nil || p.Device.ID != id || !ValidPairName(p.Device.Name) {
		return PairIdentity{}, errPairProtocol
	}
	if p.Device.Address != "" && !allowedDirectPairAddress(p.Device.Address) {
		return PairIdentity{}, errPairProtocol
	}
	return *p.Device, nil
}

func allowedDirectPairAddress(addr string) bool {
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return false
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsPrivate() {
		return false
	}
	n, err := strconv.ParseUint(port, 10, 16)
	return err == nil && n > 0 && strconv.FormatUint(n, 10) == port
}

func verificationCode(key []byte, role string, host, guest PairIdentity) string {
	mac := hmac.New(sha256.New, key)
	// Prefix UTF-8 byte lengths so independent mobile implementations agree
	// even for non-ASCII names, without a JSON serializer's escaping rules.
	for _, field := range []string{pairProtocol, role, host.ID, host.Name, host.Address, guest.ID, guest.Name, guest.Address} {
		mac.Write(binary.BigEndian.AppendUint16(nil, uint16(len(field))))
		mac.Write([]byte(field))
	}
	n := binary.BigEndian.Uint32(mac.Sum(nil)[:4]) % 1_000_000
	return fmt.Sprintf("%03d %03d", n/1000, n%1000)
}

type pairHandshake struct {
	conn               net.Conn
	peer               PairIdentity
	role, verification string
}

func (p Pairing) pairHandshake(ctx context.Context, raw net.Conn, inv *pairInvite, host bool, grant string) (pairHandshake, error) {
	var h pairHandshake
	local, err := p.localPairIdentity()
	if err != nil {
		return h, err
	}
	deadline := time.Now().Add(20 * time.Second)
	if expires, ok := ctx.Deadline(); ok && expires.Before(deadline) {
		deadline = expires
	}
	if err = raw.SetDeadline(deadline); err != nil {
		return h, err
	}
	conn, id, binding, err := p.pairingTLS(ctx, raw, host)
	if err != nil {
		return h, err
	}
	var secret []byte
	if host {
		mode, err := readPacket(conn, "join")
		if err != nil {
			return h, err
		}
		if mode.Role != "peer" && mode.Role != "viewer" {
			return h, errPairProtocol
		}
		if mode.Role == "viewer" {
			grant = "viewer"
		}
		password := inv.password(mode.Mode)
		if password == "" {
			return h, errPairAuth
		}
		if err = sendPacket(conn, pairPacket{Type: "offer", Role: grant}); err != nil {
			return h, err
		}
		secret, err = opaqueHost(conn, pairConfig(inv.room, grant, binding), []byte(password), ID(p.Key), id)
		if err != nil {
			return h, err
		}
		if err = sendPacket(conn, pairPacket{Type: "device", Device: &local}); err != nil {
			return h, err
		}
	} else {
		mode := "manual"
		if inv.linkSecret != "" {
			mode = "link"
		}
		if err = sendPacket(conn, pairPacket{Type: "join", Mode: mode, Role: grant}); err != nil {
			return h, err
		}
		offer, err := readPacket(conn, "offer")
		if err != nil {
			return h, err
		}
		if grant == "viewer" && offer.Role != "viewer" {
			return h, errPairAuth
		}
		grant = offer.Role
		if grant != "peer" && grant != "viewer" {
			return h, errPairProtocol
		}
		secret, err = opaqueJoin(conn, pairConfig(inv.room, grant, binding), []byte(inv.password(mode)), id, ID(p.Key))
		if err != nil {
			return h, err
		}
	}
	defer clear(secret)
	peer, err := readPairDevice(conn, id)
	if err != nil {
		return h, err
	}
	first, second := local, peer
	if !host {
		if err = sendPacket(conn, pairPacket{Type: "device", Device: &local}); err != nil {
			return h, err
		}
		first, second = peer, local
	}
	var expires time.Time
	if t, ok := ctx.Deadline(); ok {
		expires = t
	}
	if err = conn.SetDeadline(expires); err != nil {
		return h, err
	}
	return pairHandshake{conn: conn, peer: peer, role: grant, verification: verificationCode(secret, grant, first, second)}, nil
}
