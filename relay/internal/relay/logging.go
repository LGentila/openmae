package relay

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"maps"
	"net"
	"net/netip"
	"os"
	"regexp"
	"runtime/debug"
	"strings"
	"sync"

	"github.com/gorilla/websocket"
	"github.com/quic-go/quic-go"
)

// Logs never hold device ids, tube tokens or IP addresses: only kinds of
// events, counts and kinds of errors. Error texts are not logged as they
// are, since network errors often quote addresses.

// errKind names an error without its text.
func errKind(err error) string {
	var appErr *quic.ApplicationError
	var closeErr *websocket.CloseError
	var netErr net.Error
	var idleErr *quic.IdleTimeoutError
	switch {
	case err == nil:
		return "none"
	case errors.Is(err, io.EOF), errors.As(err, &closeErr):
		return "closed"
	case errors.As(err, &appErr):
		return "closed"
	case errors.As(err, &idleErr):
		return "idle timeout"
	case errors.Is(err, errProtocol):
		return "protocol violation"
	case errors.Is(err, context.Canceled):
		return "canceled"
	case errors.Is(err, os.ErrDeadlineExceeded), errors.As(err, &netErr) && netErr.Timeout():
		return "timeout"
	case errors.Is(err, net.ErrClosed), errors.Is(err, websocket.ErrCloseSent):
		return "closed"
	}
	return "error"
}

var (
	addrCandidate = regexp.MustCompile(`[0-9A-Fa-f:.]{2,}`)
	ipv4Anywhere  = regexp.MustCompile(`(?:\d{1,3}\.){3}\d{1,3}`)
)

// redactAddrs replaces the IP addresses in s, with or without a port.
func redactAddrs(s string) string {
	s = addrCandidate.ReplaceAllStringFunc(s, func(m string) string {
		for _, core := range []string{m, strings.TrimRight(m, ".:")} { // "from 192.0.2.1:"
			if _, err := netip.ParseAddr(core); err == nil {
				return "[addr]" + m[len(core):]
			}
			if i := strings.LastIndexByte(core, ':'); i > 0 { // IPv4 and a port
				if ip, err := netip.ParseAddr(core[:i]); err == nil && ip.Is4() {
					return "[addr]" + m[i:]
				}
			}
		}
		return m
	})
	// IPv4 glued to a word: better too much than too little.
	return ipv4Anywhere.ReplaceAllString(s, "[addr]")
}

// LibraryLogWriter receives what libraries print through the standard log
// package (net/http, quic-go) and logs it on l, without addresses.
func LibraryLogWriter(l *slog.Logger) io.Writer { return libraryWriter{l} }

type libraryWriter struct{ log *slog.Logger }

func (w libraryWriter) Write(p []byte) (int, error) {
	text := redactAddrs(strings.TrimSpace(string(p)))
	if strings.Contains(text, "TLS handshake error") { // scanners, all day long
		w.log.Debug("library", "text", text)
	} else {
		w.log.Warn("library", "text", text)
	}
	return len(p), nil
}

func (s *Server) recoverPanic() {
	if v := recover(); v != nil {
		s.log.Error("panic serving a connection", "stack", redactAddrs(string(debug.Stack())))
	}
}

// counters counts refusals by error code between two stats lines.
type counters struct {
	mu sync.Mutex
	n  map[string]int
}

func (c *counters) count(code string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.n == nil {
		c.n = make(map[string]int)
	}
	c.n[code]++
}

func (c *counters) take() map[string]int {
	c.mu.Lock()
	defer c.mu.Unlock()
	n := maps.Clone(c.n)
	clear(c.n)
	return n
}
