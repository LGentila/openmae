package relay

import (
	"bytes"
	"crypto/ed25519"
	"encoding/hex"
	"errors"
	"io"
	"strings"
	"testing"
)

// The public key of RFC 8032, test 1. Its device id was computed apart,
// with Python's hashlib and base64.
const (
	rfc8032Seed   = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
	rfc8032Public = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
)

func TestDeviceID(t *testing.T) {
	pub, _ := hex.DecodeString(rfc8032Public)
	if got, want := deviceID(pub), "eh7ddx5bksrgcytl7bkai36se4"; got != want {
		t.Errorf("deviceID = %q, want %q", got, want)
	}
	for _, c := range []struct {
		id string
		ok bool
	}{
		{"eh7ddx5bksrgcytl7bkai36se4", true},
		{"EH7DDX5BKSRGCYTL7BKAI36SE4", false}, // lowercase only
		{"eh7ddx5bksrgcytl7bkai36se", false},
		{"eh7ddx5bksrgcytl7bkai36se4a", false},
		{"eh7ddx5bksrgcytl7bkai36se1", false}, // 1 is not in the alphabet
		{"eh7ddx5bksrgcytl7bkai36se=", false},
		{"", false},
	} {
		if got := validDeviceID(c.id); got != c.ok {
			t.Errorf("validDeviceID(%q) = %v", c.id, got)
		}
	}
}

func TestRegistrationSignature(t *testing.T) {
	seed, _ := hex.DecodeString(rfc8032Seed)
	priv := ed25519.NewKeyFromSeed(seed)
	pub := priv.Public().(ed25519.PublicKey)
	if hex.EncodeToString(pub) != rfc8032Public {
		t.Fatal("seed and public key do not match")
	}
	nonce := bytes.Repeat([]byte{0xA5}, 32)
	sig := ed25519.Sign(priv, append([]byte("openmae-relay/1 register:"), nonce...))
	if !validRegistration(pub, nonce, sig) {
		t.Fatal("valid signature refused")
	}
	other := bytes.Repeat([]byte{0x5A}, 32)
	if validRegistration(pub, other, sig) {
		t.Error("signature over another nonce accepted")
	}
	plain := ed25519.Sign(priv, nonce) // without the context string
	if validRegistration(pub, nonce, plain) {
		t.Error("signature without the context accepted")
	}
	if validRegistration(pub[:31], nonce, sig) {
		t.Error("short key accepted")
	}
	if validRegistration(pub, nonce, sig[:63]) {
		t.Error("short signature accepted")
	}
}

func TestParseMessage(t *testing.T) {
	m, err := parseMessage([]byte(`{"op":"hello","v":1,"role":"mac","id":"x","key":"k","extra":{"a":[1]}}`))
	if err != nil || m.Op != "hello" || m.V == nil || *m.V != 1 || m.Role != "mac" || m.ID != "x" || m.Key != "k" {
		t.Errorf("hello: %+v %v", m, err)
	}
	for _, bad := range []string{
		``, `{`, `[]`, `null`, `"hello"`, `{}`, `{"op":""}`, `{"op":1}`, `{"op":"hello"} {}`,
		`{"op":"hello","v":"1"}`, `{"op":"hello","v":1.5}`, "{\"op\":\"h\xffi\"}",
	} {
		if _, err := parseMessage([]byte(bad)); !errors.Is(err, errProtocol) {
			t.Errorf("parseMessage(%q) = %v", bad, err)
		}
	}
}

func TestVersionCode(t *testing.T) {
	one, two := 1, 2
	if versionCode(&one) != "" || versionCode(&two) != codeUnsupportedVersion || versionCode(nil) != codeBadRequest {
		t.Error("versionCode")
	}
}

func TestMessagesSent(t *testing.T) {
	var tok token
	for i := range tok {
		tok[i] = byte(i)
	}
	nonce := bytes.Repeat([]byte{0xFF}, 32)
	for got, want := range map[string]string{
		string(challengeMessage(nonce)): `{"op":"challenge","nonce":"__________________________________________8"}`,
		string(incomingMessage(tok)):    `{"op":"incoming","tube":"AAECAwQFBgcICQoLDA0ODw"}`,
		string(errorMessage(codeBusy)):  `{"op":"error","code":"busy"}`,
	} {
		if got != want {
			t.Errorf("got %s, want %s", got, want)
		}
	}
}

func TestFrames(t *testing.T) {
	var stream bytes.Buffer
	stream.Write(appendFrame(nil, []byte(`{"op":"connect"}`)))
	stream.WriteString("tube bytes")
	b, err := readFrame(&stream)
	if err != nil || string(b) != `{"op":"connect"}` {
		t.Fatalf("readFrame = %q, %v", b, err)
	}
	if rest := stream.String(); rest != "tube bytes" {
		t.Errorf("readFrame read past its frame: %q left", rest)
	}

	if _, err := readFrame(bytes.NewReader(appendFrame(nil, make([]byte, maxControlSize)))); err != nil {
		t.Errorf("frame of %d bytes: %v", maxControlSize, err)
	}
	// Too large: refused from the header, before the client sends it all.
	if _, err := readFrame(bytes.NewReader([]byte{0, 0, 0x10, 0x01})); !errors.Is(err, errTooLarge) {
		t.Errorf("frame of %d bytes: %v", maxControlSize+1, err)
	}
	if _, err := readFrame(bytes.NewReader([]byte{0, 0, 0, 5, '{'})); !errors.Is(err, io.ErrUnexpectedEOF) {
		t.Errorf("truncated frame: %v", err)
	}
}

func TestDecodeFixed(t *testing.T) {
	tok := b64url.EncodeToString(bytes.Repeat([]byte{7}, 16))
	if _, ok := parseToken(tok); !ok {
		t.Error("valid token refused")
	}
	for _, bad := range []string{tok + "=", tok[:21], tok + "A", strings.ReplaceAll(tok, "B", "+"), ""} {
		if _, ok := parseToken(bad); ok {
			t.Errorf("parseToken(%q) accepted", bad)
		}
	}
}
