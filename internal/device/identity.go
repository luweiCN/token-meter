package device

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"errors"
	"math/big"
	"strings"
	"time"
)

func ID(key ed25519.PrivateKey) string {
	return hex.EncodeToString(key.Public().(ed25519.PublicKey))
}

func ValidID(id string) bool {
	b, e := hex.DecodeString(id)
	return e == nil && len(b) == ed25519.PublicKeySize && strings.ToLower(id) == id
}
func Certificate(key ed25519.PrivateKey) (tls.Certificate, error) {
	now := time.Now()
	tmpl := &x509.Certificate{SerialNumber: new(big.Int).SetBytes(key.Public().(ed25519.PublicKey)[:16]), Subject: pkix.Name{CommonName: ID(key)}, NotBefore: now.Add(-24 * time.Hour), NotAfter: now.AddDate(1, 0, 0), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth, x509.ExtKeyUsageServerAuth}}
	der, e := x509.CreateCertificate(rand.Reader, tmpl, tmpl, key.Public(), key)
	if e != nil {
		return tls.Certificate{}, e
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}, nil
}
func RemoteID(cs tls.ConnectionState) string {
	if len(cs.PeerCertificates) != 1 {
		return ""
	}
	pub, ok := cs.PeerCertificates[0].PublicKey.(ed25519.PublicKey)
	if !ok {
		return ""
	}
	return hex.EncodeToString(pub)
}
func TLSConfig(key ed25519.PrivateKey, expected string, authorize func(string) error) (*tls.Config, error) {
	if expected == "" && authorize == nil || expected != "" && !ValidID(expected) {
		return nil, errors.New("missing device authentication policy")
	}
	cert, e := Certificate(key)
	if e != nil {
		return nil, e
	}
	cfg := &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{cert}, SessionTicketsDisabled: true}
	if expected == "" {
		cfg.ClientAuth = tls.RequireAnyClientCert
	} else {
		// Private peer certificates use explicit Ed25519 public key pins in place of a DNS CA.
		cfg.InsecureSkipVerify = true
	}
	cfg.VerifyConnection = func(cs tls.ConnectionState) error {
		id := RemoteID(cs)
		if id == "" {
			return errors.New("missing device identity")
		}
		if expected != "" {
			if id != expected {
				return errors.New("untrusted server key")
			}
			return nil
		}
		return authorize(id)
	}
	return cfg, nil
}
