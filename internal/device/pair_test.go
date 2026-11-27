package device

import (
	"net"
	"strings"
	"testing"
	"time"
)

func TestPairInvitationFormats(t *testing.T) {
	p := newPairInvite()
	for _, input := range []string{p.code(), strings.ToLower(p.code()), strings.ReplaceAll(p.code(), "-", " ")} {
		got, e := parsePairInvite(input)
		if e != nil {
			t.Fatal(e)
		}
		if got.room != p.room || got.manual != p.manual || got.linkSecret != "" {
			t.Fatal("manual code failed to round-trip")
		}
	}
	got, e := parsePairInvite(p.link())
	if e != nil {
		t.Fatal(e)
	}
	if got.room != p.room || got.linkSecret != p.linkSecret || got.manual != "" {
		t.Fatal("link failed to round-trip")
	}
	for _, junk := range []string{"", "https://pair.example/" + p.room, p.link() + "x", strings.Replace(p.link(), "//pair/", "//pair@evil/", 1), "IIII-IIII-IIII", strings.Repeat("a", 513)} {
		if _, e := parsePairInvite(junk); e == nil {
			t.Fatal("accepted invalid invitation")
		}
	}
	if ValidPairName("Linux\u202eadmin") || ValidPairName("hi\nname") || !ValidPairName("我的 Linux") {
		t.Fatal("invalid device name filtering")
	}
}

func TestPairVerificationInteroperability(t *testing.T) {
	key := make([]byte, 32)
	for i := range key {
		key[i] = byte(i)
	}
	host := PairIdentity{ID: strings.Repeat("11", 32), Name: "家里的 Linux", Address: "192.168.1.20:47732"}
	guest := PairIdentity{ID: strings.Repeat("22", 32), Name: "手机 & <iOS>"}
	if got := verificationCode(key, "viewer", host, guest); got != "266 243" {
		t.Fatalf("interoperability vector: %s", got)
	}
}

func TestPairChannelBinding(t *testing.T) {
	a, b := net.Pipe()
	defer a.Close()
	defer b.Close()
	a.SetDeadline(time.Now().Add(5 * time.Second))
	b.SetDeadline(time.Now().Add(5 * time.Second))
	server := make(chan error, 1)
	go func() {
		defer a.Close()
		_, e := opaqueHost(a, pairConfig("abc345", "peer", []byte("original")), []byte("pass"), "host", "join")
		server <- e
	}()
	_, err := opaqueJoin(b, pairConfig("abc345", "peer", []byte("another connection")), []byte("pass"), "host", "join")
	b.Close()
	if err == nil || <-server == nil {
		t.Fatal("channel binding failed")
	}
}
