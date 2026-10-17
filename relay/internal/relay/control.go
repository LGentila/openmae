package relay

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base32"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/netip"
	"unicode/utf8"
)

// Error codes, sent as {"op":"error","code":…} before the relay closes a
// connection.
const (
	codeBadRequest         = "bad_request"
	codeBadSignature       = "bad_signature"
	codeMacOffline         = "mac_offline"
	codeMacTimeout         = "mac_timeout"
	codeBusy               = "busy"
	codeUnknownTube        = "unknown_tube"
	codeRateLimited        = "rate_limited"
	codeUnsupportedVersion = "unsupported_version"
	codeInboundOff         = "inbound_off" // a hello with "inbound" to a relay not in home mode
)

// errProtocol marks everything a client sends that openmae-relay/1 does not
// allow; the connection is then closed, with bad_request when still possible.
var errProtocol = errors.New("protocol violation")

var (
	errTooLarge = fmt.Errorf("%w: control message over %d bytes", errProtocol, maxControlSize)
	errBadJSON  = fmt.Errorf("%w: not a control message", errProtocol)
)

// message has the fields of every control message a client may send;
// encoding/json ignores the others, as the protocol asks.
type message struct {
	Op      string `json:"op"`
	V       *int   `json:"v"`
	Role    string `json:"role"`
	ID      string `json:"id"`
	Key     string `json:"key"`
	Inbound bool   `json:"inbound"` // hello: a registration for deliveries, in home mode
	Sig     string `json:"sig"`
	To      string `json:"to"`
	Tube    string `json:"tube"`
}

func parseMessage(b []byte) (message, error) {
	var m message
	if !utf8.Valid(b) {
		return m, errBadJSON
	}
	if err := json.Unmarshal(b, &m); err != nil || m.Op == "" {
		return message{}, errBadJSON
	}
	return m, nil
}

// versionCode says what is wrong with the "v" of hello, connect or accept.
func versionCode(v *int) string {
	switch {
	case v == nil:
		return codeBadRequest
	case *v != protocolVersion:
		return codeUnsupportedVersion
	}
	return ""
}

var (
	msgRegistered = []byte(`{"op":"registered"}`)
	msgPong       = []byte(`{"op":"pong"}`)
	msgConnected  = []byte(`{"op":"connected"}`)
	msgAccepted   = []byte(`{"op":"accepted"}`)
)

// The values put in the messages below never need JSON escaping.

func challengeMessage(nonce []byte) []byte {
	return []byte(`{"op":"challenge","nonce":"` + b64url.EncodeToString(nonce) + `"}`)
}

func incomingMessage(t token) []byte {
	return []byte(`{"op":"incoming","tube":"` + b64url.EncodeToString(t[:]) + `"}`)
}

func registeredInboundMessage(name string) []byte {
	return []byte(`{"op":"registered","inbound":"` + name + `"}`)
}

// inboundMessage asks a Mac to accept a delivery's tube. from is the
// caller's address, without the zone, which only means something on the
// relay's host.
func inboundMessage(t token, from netip.Addr) []byte {
	return []byte(`{"op":"inbound","tube":"` + b64url.EncodeToString(t[:]) +
		`","from":"` + from.Unmap().WithZone("").String() + `"}`)
}

func errorMessage(code string) []byte {
	return []byte(`{"op":"error","code":"` + code + `"}`)
}

// QUIC control frames: a 4-byte big-endian length, then the JSON.

// readFrame reads exactly one frame, so that tube bytes a client sends right
// after its last control message stay in the stream for the tube.
func readFrame(r io.Reader) ([]byte, error) {
	var hdr [4]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return nil, err
	}
	n := binary.BigEndian.Uint32(hdr[:])
	if n > maxControlSize {
		return nil, errTooLarge
	}
	b := make([]byte, n)
	if _, err := io.ReadFull(r, b); err != nil {
		return nil, err
	}
	return b, nil
}

func appendFrame(dst, msg []byte) []byte {
	dst = binary.BigEndian.AppendUint32(dst, uint32(len(msg)))
	return append(dst, msg...)
}

var b64url = base64.RawURLEncoding

// decodeFixed decodes unpadded base64url that must hold exactly n bytes.
func decodeFixed(s string, n int) ([]byte, bool) {
	if b64url.DecodedLen(len(s)) != n {
		return nil, false
	}
	b, err := b64url.DecodeString(s)
	return b, err == nil && len(b) == n
}

// A token names a tube between incoming and accept. It is the only proof
// that the connection sending accept is the Mac's, so it is random and
// used once.
type token [16]byte

func newToken() token {
	var t token
	_, _ = rand.Read(t[:]) // never fails since Go 1.24
	return t
}

func parseToken(s string) (token, bool) {
	var t token
	b, ok := decodeFixed(s, len(t))
	copy(t[:], b)
	return t, ok
}

// Device ids: the first 16 bytes of SHA-256 of the raw Ed25519 public key,
// lowercase base32 without padding.
var deviceIDEncoding = base32.NewEncoding("abcdefghijklmnopqrstuvwxyz234567").WithPadding(base32.NoPadding)

const deviceIDLen = 26

func deviceID(pub ed25519.PublicKey) string {
	sum := sha256.Sum256(pub)
	return deviceIDEncoding.EncodeToString(sum[:16])
}

const inboundContext = "openmae-relay/1 inbound:"

// inboundName is the name a Mac gets deliveries under in home mode: the
// first 16 bytes of SHA-256 of inboundContext and the raw Ed25519 public
// key, encoded like a device id. Unlike the device id, it is given out to
// the systems that post deliveries, and does not tell them the device id.
func inboundName(pub ed25519.PublicKey) string {
	h := sha256.New()
	h.Write([]byte(inboundContext))
	h.Write(pub)
	return deviceIDEncoding.EncodeToString(h.Sum(nil)[:16])
}

// validDeviceID also checks inbound names, which have the same form.
func validDeviceID(s string) bool {
	if len(s) != deviceIDLen {
		return false
	}
	for i := 0; i < len(s); i++ {
		if c := s[i]; !('a' <= c && c <= 'z' || '2' <= c && c <= '7') {
			return false
		}
	}
	return true
}

const registerContext = "openmae-relay/1 register:"

// validRegistration checks the Mac's answer to a challenge.
func validRegistration(pub ed25519.PublicKey, nonce, sig []byte) bool {
	if len(pub) != ed25519.PublicKeySize { // ed25519.Verify panics otherwise
		return false
	}
	msg := make([]byte, 0, len(registerContext)+len(nonce))
	msg = append(msg, registerContext...)
	msg = append(msg, nonce...)
	return ed25519.Verify(pub, msg, sig)
}
