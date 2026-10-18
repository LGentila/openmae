package relay

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"strconv"
	"strings"
	"sync"
	"time"
)

// The inbound domain: systems on the internet post deliveries to a Mac at
// https://<inbound name>.<inbound domain>/in/<secret>, and the relay cannot
// read them. It reads the TLS ClientHello just far enough to learn the server
// name, finds the Mac registered for deliveries under that name, and passes
// the TLS connection, unopened, through a tube to the Mac, which holds the
// name's certificate (obtained from Let's Encrypt with the HTTP-01 challenge,
// whose answer the Mac leaves with the relay: see challenges).

const (
	// The largest ClientHello the relay reads to find the server name; real
	// ones take a few kilobytes.
	maxClientHello = 64 << 10
	// The PROXY protocol header: version 1 is one line of 107 bytes at most;
	// version 2 is 16 bytes and its addresses, whose extensions the relay
	// skips up to this length.
	maxProxyHeader = 4 << 10
)

var (
	errNoProxyHeader = errors.New("no PROXY protocol header")
	errBadProxy      = errors.New("bad PROXY protocol header")
	errHelloRead     = errors.New("ClientHello read") // stops the TLS handshake once the server name is known
	errHelloTooLarge = errors.New("ClientHello too large")
	errBytesUsed     = errors.New("connection used its bytes")
)

// ParseInboundDomain checks RELAY_INBOUND_DOMAIN: a DNS name of at least two
// labels, such as "in.openmae.com", in lowercase.
func ParseInboundDomain(s string) (string, error) {
	d := strings.TrimSuffix(strings.ToLower(strings.TrimSpace(s)), ".")
	labels := strings.Split(d, ".")
	if len(d) > 200 || len(labels) < 2 {
		return "", fmt.Errorf("%q is not a domain such as in.example.com", s)
	}
	for _, l := range labels {
		if l == "" || len(l) > 63 || l[0] == '-' || l[len(l)-1] == '-' {
			return "", fmt.Errorf("%q is not a domain such as in.example.com", s)
		}
		for i := 0; i < len(l); i++ {
			if c := l[i]; !('a' <= c && c <= 'z' || '0' <= c && c <= '9' || c == '-') {
				return "", fmt.Errorf("%q is not a domain such as in.example.com", s)
			}
		}
	}
	return d, nil
}

// inboundNameOf returns the inbound name of a host under the inbound
// domain, "<inbound name>.<domain>", in any case and with or without a port.
func inboundNameOf(host, domain string) (string, bool) {
	if domain == "" {
		return "", false
	}
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	host = strings.ToLower(host)
	name, ok := strings.CutSuffix(host, "."+domain)
	if !ok || !validDeviceID(name) {
		return "", false
	}
	return name, true
}

// MARK: The PROXY protocol

var proxyV2Signature = []byte("\r\n\r\n\x00\r\nQUIT\n")

// readProxyHeader reads the PROXY protocol header a proxy sends before the
// client's bytes (version 1 or 2) and returns the client's address. A
// LOCAL (version 2) or UNKNOWN (version 1) connection comes from the proxy
// itself: its address is not valid, and the caller uses the TCP peer's.
func readProxyHeader(r *bufio.Reader) (netip.Addr, error) {
	start, err := r.Peek(12)
	if err != nil {
		return netip.Addr{}, err
	}
	switch {
	case bytes.Equal(start, proxyV2Signature):
		return readProxyV2(r)
	case bytes.HasPrefix(start, []byte("PROXY ")):
		return readProxyV1(r)
	}
	return netip.Addr{}, errNoProxyHeader
}

func readProxyV1(r *bufio.Reader) (netip.Addr, error) {
	var line []byte
	for len(line) < 107 {
		b, err := r.ReadByte()
		if err != nil {
			return netip.Addr{}, err
		}
		line = append(line, b)
		if b == '\n' {
			break
		}
	}
	text, ok := strings.CutSuffix(string(line), "\r\n")
	if !ok {
		return netip.Addr{}, errBadProxy
	}
	f := strings.Split(text, " ")
	switch {
	case len(f) >= 2 && f[1] == "UNKNOWN":
		return netip.Addr{}, nil
	case len(f) != 6 || f[1] != "TCP4" && f[1] != "TCP6":
		return netip.Addr{}, errBadProxy
	}
	ip, err := netip.ParseAddr(f[2])
	if err != nil || ip.Is4() != (f[1] == "TCP4") || ip.Zone() != "" {
		return netip.Addr{}, errBadProxy
	}
	for _, port := range f[4:] {
		if p, err := strconv.Atoi(port); err != nil || p < 0 || p > 65535 {
			return netip.Addr{}, errBadProxy
		}
	}
	return ip.Unmap(), nil
}

func readProxyV2(r *bufio.Reader) (netip.Addr, error) {
	var hdr [16]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return netip.Addr{}, err
	}
	length := int(binary.BigEndian.Uint16(hdr[14:16]))
	if hdr[12]>>4 != 2 || length > maxProxyHeader {
		return netip.Addr{}, errBadProxy
	}
	rest := make([]byte, length)
	if _, err := io.ReadFull(r, rest); err != nil {
		return netip.Addr{}, err
	}
	switch hdr[12] & 0x0f {
	case 0: // LOCAL: the proxy's own connection, a health check
		return netip.Addr{}, nil
	case 1: // PROXY
	default:
		return netip.Addr{}, errBadProxy
	}
	switch hdr[13] {
	case 0x11, 0x12: // TCP or UDP over IPv4
		if length < 12 {
			return netip.Addr{}, errBadProxy
		}
		return netip.AddrFrom4([4]byte(rest[:4])), nil
	case 0x21, 0x22: // over IPv6
		if length < 36 {
			return netip.Addr{}, errBadProxy
		}
		return netip.AddrFrom16([16]byte(rest[:16])).Unmap(), nil
	case 0x00: // UNSPEC: no address to tell
		return netip.Addr{}, nil
	}
	return netip.Addr{}, errBadProxy
}

// MARK: The ClientHello

// recordingConn gives crypto/tls a client's bytes while keeping a copy of
// them, and writes nothing back: the relay only reads the ClientHello.
type recordingConn struct {
	net.Conn
	r    io.Reader
	seen bytes.Buffer
}

func (c *recordingConn) Read(p []byte) (int, error) {
	n, err := c.r.Read(p)
	c.seen.Write(p[:n])
	if c.seen.Len() > maxClientHello {
		return n, errHelloTooLarge
	}
	return n, err
}

func (c *recordingConn) Write(p []byte) (int, error) { return 0, io.ErrClosedPipe }
func (c *recordingConn) Close() error                { return nil }

// readServerName reads a client's TLS ClientHello from r without answering
// it, and returns its server name and every byte read, which the Mac must
// receive first. The handshake goes no further.
func readServerName(c net.Conn, r io.Reader) (string, []byte, error) {
	rc := &recordingConn{Conn: c, r: r}
	var name string
	var found bool
	err := tls.Server(rc, &tls.Config{
		GetConfigForClient: func(hello *tls.ClientHelloInfo) (*tls.Config, error) {
			name, found = hello.ServerName, true
			return nil, errHelloRead
		},
	}).Handshake()
	if !found {
		if err == nil {
			err = errBadProxy // cannot happen: the handshake stops at the ClientHello
		}
		return "", nil, err
	}
	return strings.ToLower(name), rc.seen.Bytes(), nil
}

// MARK: Connections

// prefixConn is a connection whose first bytes were already read: Read
// returns them first.
type prefixConn struct {
	net.Conn
	r io.Reader
}

func newPrefixConn(c net.Conn, head []byte, rest io.Reader) *prefixConn {
	return &prefixConn{Conn: c, r: io.MultiReader(bytes.NewReader(head), rest)}
}

func (c *prefixConn) Read(p []byte) (int, error) { return c.r.Read(p) }

// serveInbound accepts the connections a TLS-passthrough proxy forwards to
// the inbound listener, each preceded by the PROXY protocol header.
func (s *Server) serveInbound(ln net.Listener) error {
	for {
		c, err := ln.Accept()
		if err != nil {
			if s.ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return nil
			}
			var ne net.Error
			if errors.As(err, &ne) && ne.Timeout() {
				time.Sleep(10 * time.Millisecond)
				continue
			}
			return err
		}
		if !s.handlers.add() {
			_ = c.Close()
			continue
		}
		go func() {
			defer s.handlers.done()
			s.handleInbound(c, true)
		}()
	}
}

// handleInbound serves one connection for the inbound domain: the PROXY
// header when it comes from the proxy, the ClientHello, then the tube to the
// Mac. Every refusal closes the connection without a word: the relay holds
// no certificate for these names.
func (s *Server) handleInbound(c net.Conn, proxied bool) {
	defer c.Close()
	defer s.recoverPanic()
	start := time.Now()
	deadline := start.Add(s.lim.PassthroughTimeout)
	_ = c.SetDeadline(deadline)
	stop := context.AfterFunc(s.ctx, func() { _ = c.Close() }) // shutdown
	defer stop()
	if !s.slots.acquire() {
		s.stats.count("passthrough_busy")
		return
	}
	defer s.slots.release()

	from, _ := parseHostAddr(c.RemoteAddr().String())
	br := bufio.NewReaderSize(c, 4096)
	if proxied {
		ip, err := readProxyHeader(br)
		if err != nil {
			s.passthroughRefused("no_proxy_header")
			return
		}
		if ip.IsValid() {
			from = ip
		}
	}
	s.passthroughFrom(c, br, from, start, deadline)
}

// passthroughFrom goes on with a connection from a caller at from, whose
// bytes come out of r: its server name decides, then its tube.
func (s *Server) passthroughFrom(c net.Conn, r io.Reader, from netip.Addr, start, deadline time.Time) {
	if !s.passthroughIPs.allow(from) {
		s.passthroughRefused("rate_limited")
		return
	}
	helloBy := start.Add(s.lim.FirstMessage)
	if deadline.Before(helloBy) {
		helloBy = deadline
	}
	_ = c.SetReadDeadline(helloBy)
	sni, head, err := readServerName(c, r)
	if err != nil {
		s.passthroughRefused("no_client_hello")
		return
	}
	_ = c.SetReadDeadline(deadline)
	name, ok := inboundNameOf(sni, s.cfg.InboundDomain)
	if !ok {
		s.passthroughRefused("unknown_name")
		return
	}
	s.passthrough(c, r, head, name, from, start, deadline)
}

func (s *Server) passthroughRefused(reason string) {
	s.stats.count("passthrough_" + reason)
	s.log.Debug("passthrough refused", "reason", reason)
}

// passthrough asks the Mac registered under name for a tube and pipes the
// connection through it, head first.
func (s *Server) passthrough(c net.Conn, r io.Reader, head []byte, name string, from netip.Addr, start, deadline time.Time) {
	if !s.hub.inboundRegistered(name) {
		s.passthroughRefused("mac_offline")
		return
	}
	if !s.deliveries.start(name) {
		s.passthroughRefused("name_rate_limited")
		return
	}
	defer s.deliveries.done(name)
	p, reg, code := s.hub.openInbound(name)
	if code != "" {
		s.passthroughRefused(code)
		return
	}
	defer s.hub.release(p)
	defer close(p.done) // lets the Mac's tube connection go

	if reg.c.writeControl(inboundMessage(p.token, from)) != nil {
		s.hub.withdraw(p)
		reg.c.closeNow()
		s.passthroughRefused("mac_offline")
		return
	}
	mac, _ := s.waitForAccept(p, time.Until(deadline), reg.c.gone())
	if mac == nil {
		s.passthroughRefused("not_accepted")
		return
	}
	if mac.writeControl(msgAccepted) != nil {
		mac.closeNow()
		s.passthroughRefused("not_accepted")
		return
	}
	reason, up, down := s.pipePassthrough(c, r, head, mac, deadline)
	s.log.Info("passthrough", "reason", reason, "up_bytes", up, "down_bytes", down,
		"ms", time.Since(start).Milliseconds())
}

// byteBudget is what a passthrough connection may still carry, both ways
// together.
type byteBudget struct {
	mu   sync.Mutex
	left int
}

func (b *byteBudget) take(n int) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.left -= n
	return b.left >= 0
}

// tcpSink writes what the Mac sends in a passthrough tube to the caller.
// Datagrams have no place there and are dropped.
type tcpSink struct {
	c      net.Conn
	budget *byteBudget
}

func (t tcpSink) writeBytes(p []byte) error {
	if !t.budget.take(len(p)) {
		return errBytesUsed
	}
	_, err := t.c.Write(p)
	return err
}

func (tcpSink) writeDatagram([]byte) error { return errNoDatagrams }

// pipePassthrough copies the caller's bytes (head, then the rest of r) into
// the Mac's tube and the Mac's bytes back, until the Mac's side ends, the
// caller's ends and the Mac has had a moment to finish, the bytes are used
// up, or the deadline. It returns why it stopped and the bytes each way.
func (s *Server) pipePassthrough(c net.Conn, r io.Reader, head []byte, mac conn, deadline time.Time) (string, int64, int64) {
	s.tubesOpen.Add(1)
	defer s.tubesOpen.Add(-1)
	ctx, cancel := context.WithDeadline(s.ctx, deadline)
	defer cancel()
	force := time.AfterFunc(time.Until(deadline), func() {
		_ = c.Close()
		mac.closeNow()
	})
	defer force.Stop()

	budget := &byteBudget{left: s.lim.PassthroughBytes}
	act := newActivity()
	rate, burst := float64(s.lim.BytesPerSecond), float64(s.lim.BurstBytes)
	up := &flow{budget: newBucket(rate, burst, nil), activity: act}
	down := &flow{budget: newBucket(rate, burst, nil), activity: act}

	upDone := make(chan error, 1)
	go func() {
		buf := make([]byte, readChunk)
		src := io.MultiReader(bytes.NewReader(head), r)
		for {
			n, err := src.Read(buf)
			if n > 0 {
				if !budget.take(n) {
					upDone <- errBytesUsed
					return
				}
				if werr := up.forwardBytes(ctx, buf[:n], mac); werr != nil {
					upDone <- werr
					return
				}
			}
			if err != nil {
				upDone <- err
				return
			}
		}
	}()
	downDone := make(chan error, 1)
	go func() { downDone <- mac.forward(ctx, tcpSink{c, budget}, down) }()

	var reason string
	select {
	case err := <-downDone:
		reason = "mac_" + endKind(err)
		downDone = nil
	case err := <-upDone:
		reason = "caller_" + endKind(err)
		upDone = nil
		if errors.Is(err, io.EOF) {
			// The caller has said everything; the Mac may still be answering.
			linger := time.NewTimer(s.lim.Linger)
			select {
			case <-downDone:
				downDone = nil
			case <-linger.C:
			}
			linger.Stop()
		}
	case <-ctx.Done():
		reason = "deadline"
	}
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		reason = "deadline"
	}

	// Close each side behind what was already written to it, and give both
	// a moment to read it all and leave: closing a TCP connection with
	// unread bytes would reset it, and could lose what the caller has not
	// read yet.
	cancel()
	lingerUntil := time.Now().Add(s.lim.Linger)
	if tc, ok := c.(interface{ CloseWrite() error }); ok {
		_ = c.SetWriteDeadline(lingerUntil)
		_ = tc.CloseWrite()
	}
	mac.closeWrite(lingerUntil)
	cut := time.AfterFunc(time.Until(lingerUntil), func() {
		_ = c.Close()
		mac.closeNow()
	})
	if upDone != nil {
		<-upDone
	}
	if downDone != nil {
		<-downDone
	}
	cut.Stop()
	_ = c.Close()
	mac.closeNow()
	return reason, up.bytes.Load(), down.bytes.Load()
}

// endKind says why one side of a passthrough connection stopped, for logs.
func endKind(err error) string {
	if errors.Is(err, errBytesUsed) {
		return "bytes used"
	}
	return errKind(err)
}

// MARK: Standalone mode

// sortingListener is the HTTPS listener in standalone mode with an inbound
// domain: connections whose server name is under the inbound domain go to
// the Macs, the others to the relay's own HTTPS server through Accept.
type sortingListener struct {
	net.Listener
	s     *Server
	conns chan net.Conn
	done  chan struct{}
	once  sync.Once
}

func (s *Server) newSortingListener(ln net.Listener) *sortingListener {
	l := &sortingListener{Listener: ln, s: s, conns: make(chan net.Conn), done: make(chan struct{})}
	go l.run()
	return l
}

func (l *sortingListener) run() {
	for {
		c, err := l.Listener.Accept()
		if err != nil {
			var ne net.Error
			if errors.As(err, &ne) && ne.Timeout() {
				time.Sleep(10 * time.Millisecond)
				continue
			}
			l.Close()
			return
		}
		go l.sort(c)
	}
}

// sort reads a connection's ClientHello and decides where it goes.
func (l *sortingListener) sort(c net.Conn) {
	s := l.s
	start := time.Now()
	_ = c.SetReadDeadline(start.Add(s.lim.FirstMessage))
	sni, head, err := readServerName(c, c)
	if err != nil {
		_ = c.Close()
		return
	}
	_ = c.SetReadDeadline(time.Time{})
	name, ok := inboundNameOf(sni, s.cfg.InboundDomain)
	if !ok {
		select { // the relay's own HTTPS, as before
		case l.conns <- newPrefixConn(c, head, c):
		case <-l.done:
			_ = c.Close()
		}
		return
	}
	if !s.handlers.add() {
		_ = c.Close()
		return
	}
	defer s.handlers.done()
	defer c.Close()
	defer s.recoverPanic()
	if !s.slots.acquire() {
		s.stats.count("passthrough_busy")
		return
	}
	defer s.slots.release()
	deadline := start.Add(s.lim.PassthroughTimeout)
	_ = c.SetDeadline(deadline)
	stop := context.AfterFunc(s.ctx, func() { _ = c.Close() })
	defer stop()
	from, _ := parseHostAddr(c.RemoteAddr().String())
	if !s.passthroughIPs.allow(from) {
		s.passthroughRefused("rate_limited")
		return
	}
	s.passthrough(c, c, head, name, from, start, deadline)
}

func (l *sortingListener) Accept() (net.Conn, error) {
	select {
	case c := <-l.conns:
		return c, nil
	case <-l.done:
		return nil, net.ErrClosed
	}
}

func (l *sortingListener) Close() error {
	l.once.Do(func() { close(l.done) })
	return l.Listener.Close()
}

// MARK: The HTTP-01 challenge

// challenges keeps, for a while, the answers to Let's Encrypt's HTTP-01
// challenge that Macs leave on their inbound registration: Let's Encrypt
// then fetches http://<inbound name>.<inbound domain>/.well-known/acme-challenge/<token>
// from the relay. The answers are public by nature (anyone who asks gets
// them).
type challenges struct {
	mu        sync.Mutex
	ttl       time.Duration
	perName   int
	maxNames  int
	names     map[string][]challenge
	lastSweep time.Time
	now       func() time.Time
}

type challenge struct {
	token, keyAuthorization string
	expires                 time.Time
}

const (
	challengeTTL      = 10 * time.Minute
	challengesPerName = 8
)

func newChallenges(ttl time.Duration, perName, maxNames int, now func() time.Time) *challenges {
	if now == nil {
		now = time.Now
	}
	return &challenges{ttl: ttl, perName: perName, maxNames: maxNames, names: make(map[string][]challenge),
		lastSweep: now(), now: now}
}

// put keeps an answer for name; past perName, the oldest goes. It returns
// false when the relay keeps too many names already.
func (c *challenges) put(name, token, keyAuthorization string) bool {
	now := c.now()
	c.mu.Lock()
	defer c.mu.Unlock()
	if now.Sub(c.lastSweep) >= c.ttl {
		c.sweep(now)
	}
	list := live(c.names[name], now)
	if list == nil && len(c.names) >= c.maxNames {
		return false
	}
	for i, ch := range list {
		if ch.token == token {
			list = append(list[:i], list[i+1:]...)
			break
		}
	}
	if len(list) >= c.perName {
		list = list[1:]
	}
	c.names[name] = append(list, challenge{token: token, keyAuthorization: keyAuthorization, expires: now.Add(c.ttl)})
	return true
}

func (c *challenges) get(name, token string) (string, bool) {
	now := c.now()
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, ch := range c.names[name] {
		if ch.token == token && now.Before(ch.expires) {
			return ch.keyAuthorization, true
		}
	}
	return "", false
}

func live(list []challenge, now time.Time) []challenge {
	var out []challenge
	for _, ch := range list {
		if now.Before(ch.expires) {
			out = append(out, ch)
		}
	}
	return out
}

func (c *challenges) sweep(now time.Time) {
	for name, list := range c.names {
		if list = live(list, now); list == nil {
			delete(c.names, name)
		} else {
			c.names[name] = list
		}
	}
	c.lastSweep = now
}

// validChallenge checks an answer a Mac leaves: an ACME token (base64url,
// at least 128 bits) and its key authorization, the token, a dot and the
// account key's thumbprint (SHA-256, 43 characters of base64url).
func validChallenge(token, keyAuthorization string) bool {
	thumbprint, ok := strings.CutPrefix(keyAuthorization, token+".")
	return len(token) >= 22 && len(token) <= 128 && isBase64URL(token) && ok && len(thumbprint) == 43 &&
		isBase64URL(thumbprint)
}

func isBase64URL(s string) bool {
	for i := 0; i < len(s); i++ {
		if c := s[i]; !('a' <= c && c <= 'z' || 'A' <= c && c <= 'Z' || '0' <= c && c <= '9' || c == '-' || c == '_') {
			return false
		}
	}
	return true
}

func challengeStoredMessage(token string) []byte {
	return []byte(`{"op":"acme_challenge_stored","token":"` + token + `"}`) // a checked token: no escaping needed
}
