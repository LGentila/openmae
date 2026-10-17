package relay

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"sync"
	"time"
)

// A registered Mac pings every 25 seconds. Far more than that is abuse.
const (
	controlMessagesPerSecond = 1
	controlBurst             = 20
)

// handleConn serves one client connection, whatever its transport, from its
// first control message on, which must arrive before firstDeadline. That
// message says what the connection is: a Mac's control connection, an
// iPhone asking for a Mac, or a Mac accepting a tube.
func (s *Server) handleConn(c conn, firstDeadline time.Time) {
	defer c.closeNow()
	defer s.recoverPanic()
	stop := context.AfterFunc(s.ctx, c.closeNow) // shutdown
	defer stop()

	raw, err := c.readControl(firstDeadline)
	if err != nil {
		s.readFailed(c, err)
		return
	}
	m, err := parseMessage(raw)
	if err != nil {
		s.refuse(c, codeBadRequest)
		return
	}
	switch m.Op {
	case "hello":
		s.serveMac(c, m)
	case "connect":
		s.servePhone(c, m)
	case "accept":
		s.serveAccept(c, m)
	default:
		s.refuse(c, codeBadRequest)
	}
}

// readFailed answers bad_request to what breaks the protocol. Timeouts and
// closed connections get no answer.
func (s *Server) readFailed(c conn, err error) {
	if errors.Is(err, errProtocol) {
		s.refuse(c, codeBadRequest)
	}
}

func (s *Server) refuse(c conn, code string) {
	s.stats.count(code)
	s.log.Debug("refused", "code", code, "transport", c.transport())
	fail(c, code, s.lim.Linger)
}

// serveMac registers a Mac, then keeps its control connection. A hello with
// "inbound" registers it for deliveries instead (home mode): that control
// connection then gets inbound messages, never incoming ones.
func (s *Server) serveMac(c conn, hello message) {
	if !s.attempts.allow(c.ip()) {
		s.refuse(c, codeRateLimited)
		return
	}
	if code := versionCode(hello.V); code != "" {
		s.refuse(c, code)
		return
	}
	if hello.Inbound && !s.cfg.HomeInbound {
		s.refuse(c, codeInboundOff)
		return
	}
	key, ok := decodeFixed(hello.Key, ed25519.PublicKeySize)
	if hello.Role != "mac" || !validDeviceID(hello.ID) || !ok {
		s.refuse(c, codeBadRequest)
		return
	}
	if deviceID(key) != hello.ID {
		// The id is a claim the key does not back: a failed proof of
		// identity, like a wrong signature.
		s.refuse(c, codeBadSignature)
		return
	}

	nonce := make([]byte, 32)
	_, _ = rand.Read(nonce)
	if c.writeControl(challengeMessage(nonce)) != nil {
		return
	}
	raw, err := c.readControl(time.Now().Add(s.lim.Register))
	if err != nil {
		s.readFailed(c, err)
		return
	}
	m, err := parseMessage(raw)
	if err != nil || m.Op != "register" {
		s.refuse(c, codeBadRequest)
		return
	}
	sig, ok := decodeFixed(m.Sig, ed25519.SignatureSize)
	if !ok {
		s.refuse(c, codeBadRequest)
		return
	}
	if !validRegistration(key, nonce, sig) {
		s.refuse(c, codeBadSignature)
		return
	}

	reg := &registration{id: hello.ID, c: c}
	answer, event := msgRegistered, "mac registered"
	if hello.Inbound {
		// Named after the key the Mac has just proved it holds: no Mac can
		// take another's name.
		reg.id, reg.inbound = inboundName(key), true
		answer, event = registeredInboundMessage(reg.id), "mac registered for deliveries"
	}
	// Answered before the Mac is findable, so that no incoming (or inbound)
	// can come before registered.
	if c.writeControl(answer) != nil {
		return
	}
	if old := s.hub.register(reg); old != nil {
		old.c.closeNow()
		s.log.Debug(event+" again", "transport", c.transport())
	} else {
		s.log.Debug(event, "transport", c.transport())
	}
	defer func() {
		s.hub.unregister(reg)
		s.log.Debug("mac control connection closed")
	}()

	ctx, cancel := context.WithCancel(s.ctx)
	defer cancel()
	c.policeDatagrams(ctx, func() { s.refuse(c, codeBadRequest) })

	limit := newBucket(controlMessagesPerSecond, controlBurst, nil)
	for {
		raw, err := c.readControl(time.Now().Add(s.lim.ControlIdle))
		if err != nil {
			s.readFailed(c, err)
			return
		}
		if !limit.allow(1) {
			s.refuse(c, codeRateLimited)
			return
		}
		m, err := parseMessage(raw)
		if err != nil {
			s.refuse(c, codeBadRequest)
			return
		}
		switch m.Op {
		case "ping":
			if c.writeControl(msgPong) != nil {
				return
			}
		case "pong": // the relay sends no pings, but answering one is harmless
		default:
			s.refuse(c, codeBadRequest)
			return
		}
	}
}

// servePhone asks the Mac for a tube, waits for its accept, then runs the
// tube.
func (s *Server) servePhone(c conn, m message) {
	if !s.attempts.allow(c.ip()) {
		s.refuse(c, codeRateLimited)
		return
	}
	if code := versionCode(m.V); code != "" {
		s.refuse(c, code)
		return
	}
	// Without datagrams over QUIC there would be no sound.
	if !validDeviceID(m.To) || !c.supportsDatagrams() {
		s.refuse(c, codeBadRequest)
		return
	}
	p, reg, code := s.hub.open(m.To)
	if code == "" {
		code = s.connectTube(c, p, reg)
	}
	if code != "" {
		s.refuse(c, code)
	}
}

// connectTube returns an error code for the iPhone, after giving back the
// tube's place so that waiting for the iPhone to read it holds nothing.
func (s *Server) connectTube(c conn, p *pendingTube, reg *registration) string {
	release := sync.OnceFunc(func() { s.hub.release(p) })
	defer release()
	defer close(p.done) // lets the Mac's tube connection go

	if reg.c.writeControl(incomingMessage(p.token)) != nil {
		// That control connection is broken; the Mac will register again.
		s.hub.withdraw(p)
		reg.c.closeNow()
		return codeMacOffline
	}
	mac, code := s.awaitAccept(c, p)
	if mac == nil {
		return code
	}
	if mac.writeControl(msgAccepted) == nil && c.writeControl(msgConnected) == nil {
		s.runTube(c, mac, release)
	}
	return ""
}

func (s *Server) awaitAccept(c conn, p *pendingTube) (conn, string) {
	mac, timedOut := s.waitForAccept(p, s.lim.Accept, c.gone())
	if mac == nil && timedOut {
		return nil, codeMacTimeout
	}
	return mac, ""
}

// waitForAccept waits for the Mac's tube connection for p, for at most
// timeout, and until gone is closed or shutdown. Coming back without one, it
// says whether the time ran out.
func (s *Server) waitForAccept(p *pendingTube, timeout time.Duration, gone <-chan struct{}) (conn, bool) {
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	timedOut := false
	select {
	case mac := <-p.accepted:
		return mac, false
	case <-timer.C:
		timedOut = true
	case <-gone:
	case <-s.ctx.Done():
	}
	if s.hub.withdraw(p) {
		return nil, timedOut
	}
	return <-p.accepted, false // the Mac accepted at the last moment
}

// serveAccept hands a Mac's tube connection to the iPhone, or the delivery,
// waiting for it, then keeps it until the tube is over.
func (s *Server) serveAccept(c conn, m message) {
	if code := versionCode(m.V); code != "" {
		s.refuse(c, code)
		return
	}
	t, ok := parseToken(m.Tube)
	if !ok || !c.supportsDatagrams() {
		s.refuse(c, codeBadRequest)
		return
	}
	p := s.hub.claim(t, c)
	if p == nil {
		s.refuse(c, codeUnknownTube)
		return
	}
	select {
	case <-p.done:
	case <-s.ctx.Done():
	}
}
