package relay

import (
	"errors"
	"fmt"
	"net/http"
	"net/netip"
	"os"
	"testing"

	"github.com/gorilla/websocket"
	"github.com/quic-go/quic-go"
)

func TestClientIP(t *testing.T) {
	for _, c := range []struct {
		remote      string
		forwarded   []string
		behindProxy bool
		want        string
	}{
		{"203.0.113.9:5555", nil, false, "203.0.113.9"},
		{"[2001:db8::9]:5555", nil, false, "2001:db8::9"},
		{"[::ffff:203.0.113.9]:5555", nil, false, "203.0.113.9"},
		// Without a proxy, X-Forwarded-For is whatever the client wrote.
		{"203.0.113.9:5555", []string{"198.51.100.1"}, false, "203.0.113.9"},
		// Behind one, the last entry is the one the proxy added.
		{"10.0.0.2:5555", []string{"198.51.100.1, 198.51.100.2"}, true, "198.51.100.2"},
		{"10.0.0.2:5555", []string{"1.1.1.1", "198.51.100.3"}, true, "198.51.100.3"},
		{"10.0.0.2:5555", []string{"2001:db8::3"}, true, "2001:db8::3"},
		{"10.0.0.2:5555", []string{"[2001:db8::4]:443"}, true, "2001:db8::4"},
		{"10.0.0.2:5555", []string{"198.51.100.5:1234"}, true, "198.51.100.5"},
		{"10.0.0.2:5555", []string{"garbage"}, true, "10.0.0.2"},
		{"10.0.0.2:5555", nil, true, "10.0.0.2"},
	} {
		r := &http.Request{RemoteAddr: c.remote, Header: http.Header{}}
		for _, f := range c.forwarded {
			r.Header.Add("X-Forwarded-For", f)
		}
		if got := clientIP(r, c.behindProxy); got != netip.MustParseAddr(c.want) {
			t.Errorf("clientIP(%s, %v, %v) = %v, want %s", c.remote, c.forwarded, c.behindProxy, got, c.want)
		}
	}
}

func TestRedactAddrs(t *testing.T) {
	for in, want := range map[string]string{
		"http: TLS handshake error from 203.0.113.9:443: EOF": "http: TLS handshake error from [addr]:443: EOF",
		"read udp [2001:db8::1]:4433->[fe80::1%en0]:5000":     "read udp [[addr]]:4433->[[addr]%en0]:5000",
		"dial ::1 failed":     "dial [addr] failed",
		"nothing to see here": "nothing to see here",
	} {
		if got := redactAddrs(in); got != want {
			t.Errorf("redactAddrs(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestErrKind(t *testing.T) {
	for err, want := range map[error]string{
		nil: "none",
		fmt.Errorf("x: %w", os.ErrDeadlineExceeded): "timeout",
		errTooLarge:                             "protocol violation",
		&quic.ApplicationError{Remote: true}:    "closed",
		&quic.IdleTimeoutError{}:                "idle timeout",
		&websocket.CloseError{Code: 1000}:       "closed",
		errors.New("read 192.0.2.1: something"): "error",
	} {
		if got := errKind(err); got != want {
			t.Errorf("errKind(%v) = %q, want %q", err, got, want)
		}
	}
}
