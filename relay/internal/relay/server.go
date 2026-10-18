package relay

import (
	"context"
	"crypto/ecdsa"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"log/slog"
	"net"
	"net/http"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
	"github.com/quic-go/quic-go"
	"golang.org/x/crypto/acme/autocert"
)

const (
	statsEvery      = 10 * time.Minute
	shutdownTimeout = 5 * time.Second
	maxTrackedAddrs = 1 << 17 // for attempts per IP
	// Past this many QUIC handshakes in progress, new clients must first
	// prove their address with a Retry, so that a flood of spoofed packets
	// cannot hold the connection slots.
	maxQUICHandshakes = 128
)

// Server is a relay: an HTTP listener (discovery, WebSocket, health), a
// QUIC listener, in standalone mode an HTTPS listener and, with an inbound
// domain, the listener for connections passed through to the Macs.
type Server struct {
	cfg            Config
	lim            Limits
	log            *slog.Logger
	hub            *hub
	attempts       *attempts
	deliveries     *deliveries // home mode and the inbound domain, per inbound name
	passthroughIPs *attempts   // the inbound domain, per caller
	challenges     *challenges // the inbound domain: answers to Let's Encrypt's HTTP-01 challenge
	slots          slots
	handlers       tracker
	stats          counters
	pin            string
	info           []byte // the /v1/info document, fixed at start

	tubesOpen   atomic.Int64
	handshaking atomic.Int64 // QUIC handshakes in progress

	udp       *net.UDPConn
	quicTr    *quic.Transport
	quicLn    *quic.Listener
	httpLn    net.Listener
	httpSrv   *http.Server
	httpsLn   net.Listener
	httpsSrv  *http.Server
	inboundLn net.Listener // the inbound domain behind a proxy
	upgrader  *websocket.Upgrader

	ctx    context.Context // ends at shutdown
	cancel context.CancelFunc
}

// New loads (or creates) the QUIC key and certificate and opens the
// listeners. Run serves them.
func New(cfg Config) (*Server, error) {
	cfg = cfg.withDefaults()
	if cfg.HomeInbound && cfg.TLSDomain != "" {
		// A relay with a public domain is reached from the internet, and
		// would read deliveries from there in clear.
		return nil, errors.New("home mode is for a relay on the home network: it cannot be combined with standalone mode")
	}
	if cfg.HomeInbound && cfg.InboundDomain != "" {
		// A Mac's inbound registration would get deliveries in clear and
		// encrypted ones alike, and could not tell them apart.
		return nil, errors.New("home mode is for a relay on the home network: it cannot be combined with an inbound domain")
	}
	if cfg.InboundDomain != "" {
		d, err := ParseInboundDomain(cfg.InboundDomain)
		if err != nil {
			return nil, fmt.Errorf("inbound domain: %w", err)
		}
		cfg.InboundDomain = d
	}
	s := &Server{
		cfg:            cfg,
		lim:            cfg.Limits,
		log:            cfg.Logger,
		hub:            newHub(cfg.Limits.TubesPerMac, cfg.Limits.MaxPendingTubes),
		attempts:       newAttempts(cfg.Limits.AttemptsPerMinute, time.Minute, maxTrackedAddrs, nil),
		deliveries:     newDeliveries(cfg.Limits.InboundPerMinute, cfg.Limits.InboundAtOnce, maxTrackedNames, nil),
		passthroughIPs: newAttempts(cfg.Limits.PassthroughPerIP, time.Minute, maxTrackedAddrs, nil),
		challenges:     newChallenges(challengeTTL, challengesPerName, maxTrackedNames, nil),
		slots:          slots{max: int64(cfg.MaxConnections)},
		upgrader:       newUpgrader(),
	}
	key, cert, err := loadQUICIdentity(cfg.DataDir, time.Now(), s.log)
	if err != nil {
		return nil, err
	}
	s.pin = spkiPin(cert.Leaf)
	pins, err := pinList(s.pin, cfg.PreviousPins)
	if err != nil {
		return nil, err
	}
	if err := s.listen(key, cert); err != nil {
		s.closeListeners()
		return nil, err
	}
	s.ctx, s.cancel = context.WithCancel(context.Background())
	port := cfg.QUICPublicPort
	if port == 0 {
		port = portOf(s.udp.LocalAddr())
	}
	s.info = infoDocument(port, pins, cfg.Limits, cfg.Pusher != nil, cfg.InboundDomain)
	return s, nil
}

func (s *Server) listen(key *ecdsa.PrivateKey, cert tls.Certificate) error {
	addr, err := net.ResolveUDPAddr("udp", s.cfg.QUICAddr)
	if err != nil {
		return fmt.Errorf("QUIC address: %w", err)
	}
	if s.udp, err = net.ListenUDP("udp", addr); err != nil {
		return err
	}
	resetKey, err := statelessResetKey(key)
	if err != nil {
		return err
	}
	s.quicTr = &quic.Transport{
		Conn:                s.udp,
		StatelessResetKey:   (*quic.StatelessResetKey)(resetKey),
		ConnContext:         s.admitQUIC,
		VerifySourceAddress: func(net.Addr) bool { return s.handshaking.Load() >= maxQUICHandshakes },
	}
	if s.quicLn, err = s.quicTr.Listen(quicTLSConfig(cert), quicConfig()); err != nil {
		return err
	}

	errorLog := log.New(LibraryLogWriter(s.log), "", 0)
	if s.httpLn, err = net.Listen("tcp", s.cfg.HTTPAddr); err != nil {
		return err
	}
	s.httpSrv = newHTTPServer(s.routes(s.cfg.HomeInbound), errorLog)
	if s.cfg.TLSDomain == "" {
		if s.cfg.InboundDomain != "" {
			if s.inboundLn, err = net.Listen("tcp", s.cfg.InboundAddr); err != nil {
				return err
			}
		}
		return nil
	}

	// Standalone mode: HTTPS with a Let's Encrypt certificate, obtained
	// with the TLS-ALPN-01 challenge on HTTPS or HTTP-01 on HTTP.
	m := &autocert.Manager{
		Prompt:     autocert.AcceptTOS,
		HostPolicy: autocert.HostWhitelist(s.cfg.TLSDomain),
		Cache:      autocert.DirCache(filepath.Join(s.cfg.DataDir, "acme")),
	}
	s.httpSrv.Handler = s.inboundChallenges(m.HTTPHandler(s.redirectToHTTPS()))
	tlsConf := m.TLSConfig()
	// WebSocket needs HTTP/1.1: gorilla cannot upgrade HTTP/2 streams.
	tlsConf.NextProtos = []string{"http/1.1", "acme-tls/1"}
	tlsConf.MinVersion = tls.VersionTLS12
	if s.httpsLn, err = net.Listen("tcp", s.cfg.HTTPSAddr); err != nil {
		return err
	}
	if s.cfg.InboundDomain != "" {
		// Names under the inbound domain go to the Macs, unopened.
		s.httpsLn = s.newSortingListener(s.httpsLn)
	}
	s.httpsSrv = newHTTPServer(s.routes(false), errorLog)
	s.httpsSrv.TLSConfig = tlsConf
	var http1 http.Protocols
	http1.SetHTTP1(true)
	s.httpsSrv.Protocols = &http1
	return nil
}

func newHTTPServer(h http.Handler, errorLog *log.Logger) *http.Server {
	// No read or write timeouts: they would cut WebSocket connections, which
	// keep their own deadlines.
	return &http.Server{
		Handler:           h,
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    16 << 10,
		ErrorLog:          errorLog,
	}
}

type handshakeDoneKey struct{}

// admitQUIC refuses connections beyond MaxConnections before their
// handshake, and frees the slot when they end.
func (s *Server) admitQUIC(ctx context.Context, _ *quic.ClientInfo) (context.Context, error) {
	if !s.slots.acquire() {
		return nil, errors.New("too many connections")
	}
	s.handshaking.Add(1)
	handshakeDone := sync.OnceFunc(func() { s.handshaking.Add(-1) })
	context.AfterFunc(ctx, func() {
		handshakeDone()
		s.slots.release()
	})
	return context.WithValue(ctx, handshakeDoneKey{}, handshakeDone), nil
}

// Run serves until ctx ends or a listener fails, then closes every
// connection and the listeners. Clients connect again once the relay is
// back.
func (s *Server) Run(ctx context.Context) error {
	errc := make(chan error, 4)
	go func() { errc <- s.serveQUIC() }()
	go func() { errc <- s.httpSrv.Serve(s.httpLn) }()
	if s.httpsSrv != nil {
		go func() { errc <- s.httpsSrv.ServeTLS(s.httpsLn, "", "") }()
	}
	if s.inboundLn != nil {
		go func() { errc <- s.serveInbound(s.inboundLn) }()
	}
	// Ports only: logs hold no IP address, not even the relay's own.
	attrs := []any{"http_port", portOf(s.httpLn.Addr()), "quic_port", portOf(s.udp.LocalAddr()), "pin", s.pin}
	if s.httpsLn != nil {
		attrs = append(attrs, "https_port", portOf(s.httpsLn.Addr()), "domain", s.cfg.TLSDomain)
	}
	if s.inboundLn != nil {
		attrs = append(attrs, "inbound_port", portOf(s.inboundLn.Addr()))
	}
	if s.cfg.InboundDomain != "" {
		attrs = append(attrs, "inbound_domain", s.cfg.InboundDomain)
	}
	if s.cfg.HomeInbound {
		attrs = append(attrs, "home_mode", true)
	}
	s.log.Info("relay started", attrs...)
	go s.logStats()

	var err error
	select {
	case <-ctx.Done():
	case err = <-errc:
		if errors.Is(err, http.ErrServerClosed) {
			err = nil
		}
	}
	s.shutdown()
	s.log.Info("relay stopped")
	return err
}

func (s *Server) serveQUIC() error {
	for {
		qc, err := s.quicLn.Accept(s.ctx)
		if err != nil {
			if s.ctx.Err() != nil || errors.Is(err, quic.ErrServerClosed) {
				return nil
			}
			return err
		}
		if done, ok := qc.Context().Value(handshakeDoneKey{}).(func()); ok {
			done() // Accept returns connections whose handshake is complete
		}
		if !s.handlers.add() {
			_ = qc.CloseWithError(0, "")
			continue
		}
		go func() {
			defer s.handlers.done()
			s.serveQUICConn(qc)
		}()
	}
}

// serveQUICConn finds the client's main stream, then serves it. Finding it
// and reading the first control message share one deadline.
func (s *Server) serveQUICConn(qc *quic.Conn) {
	deadline := time.Now().Add(s.lim.FirstMessage)
	p := pickMainStream(qc)
	timer := time.NewTimer(time.Until(deadline))
	defer timer.Stop()
	select {
	case <-p.found:
	case <-qc.Context().Done():
		return
	case <-timer.C:
		_ = qc.CloseWithError(0, "")
		return
	case <-s.ctx.Done():
		_ = qc.CloseWithError(0, "")
		return
	}
	c := newQUICConn(qc, p.main, p.head)
	p.setOnExtra(func() { s.extraStream(c) })
	s.handleConn(c, deadline)
}

// extraStream answers data on a second QUIC stream: bad_request, or during a
// tube, where an error message would land among the tube's bytes, closing.
func (s *Server) extraStream(c *quicConn) {
	c.violated.Store(true)
	if c.piping.Load() {
		c.closeNow()
		return
	}
	s.refuse(c, codeBadRequest)
}

func (s *Server) serveWebSocket(w http.ResponseWriter, r *http.Request) {
	if !s.slots.acquire() {
		http.Error(w, "too many connections", http.StatusServiceUnavailable)
		return
	}
	defer s.slots.release()
	if !s.handlers.add() {
		http.Error(w, "shutting down", http.StatusServiceUnavailable)
		return
	}
	defer s.handlers.done()
	ws, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		return // Upgrade answered the error
	}
	s.handleConn(newWSConn(ws, clientIP(r, s.cfg.BehindProxy)), time.Now().Add(s.lim.FirstMessage))
}

func (s *Server) shutdown() {
	s.handlers.close()
	s.cancel() // every connection closes
	ctx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()
	_ = s.httpSrv.Shutdown(ctx)
	if s.httpsSrv != nil {
		_ = s.httpsSrv.Shutdown(ctx)
	}
	if !s.handlers.wait(shutdownTimeout) {
		s.log.Warn("connections still open at shutdown")
	}
	s.closeListeners()
}

func (s *Server) closeListeners() {
	if s.quicLn != nil {
		_ = s.quicLn.Close()
	}
	if s.quicTr != nil {
		_ = s.quicTr.Close()
	}
	if s.udp != nil {
		_ = s.udp.Close()
	}
	for _, ln := range []net.Listener{s.httpLn, s.httpsLn, s.inboundLn} {
		if ln != nil {
			_ = ln.Close()
		}
	}
}

func (s *Server) logStats() {
	t := time.NewTicker(statsEvery)
	defer t.Stop()
	for {
		select {
		case <-s.ctx.Done():
			return
		case <-t.C:
			macs, inbound, pending := s.hub.counts()
			attrs := []any{"macs", macs}
			if s.cfg.HomeInbound || s.cfg.InboundDomain != "" {
				attrs = append(attrs, "macs_for_deliveries", inbound)
			}
			attrs = append(attrs, "tubes", s.tubesOpen.Load(), "pending", pending,
				"connections", s.slots.n.Load(), "refused", s.stats.take())
			s.log.Info("stats", attrs...)
		}
	}
}

func portOf(a net.Addr) int {
	switch a := a.(type) {
	case *net.TCPAddr:
		return a.Port
	case *net.UDPAddr:
		return a.Port
	}
	return 0
}

func infoDocument(port int, pins []string, lim Limits, push bool, inboundDomain string) []byte {
	type quicInfo struct {
		Port int      `json:"port"`
		ALPN string   `json:"alpn"`
		Pins []string `json:"spki_sha256"`
	}
	type wsInfo struct {
		Path string `json:"path"`
	}
	type limitsInfo struct {
		TubesPerMac       int `json:"tubes_per_mac"`
		KbitPerTube       int `json:"kbit_per_tube"`
		AttemptsPerMinute int `json:"attempts_per_minute"`
	}
	type inboundInfo struct {
		Domain string `json:"domain"`
	}
	doc := struct {
		Name      string       `json:"name"`
		Versions  []int        `json:"versions"`
		QUIC      quicInfo     `json:"quic"`
		WebSocket wsInfo       `json:"websocket"`
		Limits    limitsInfo   `json:"limits"`
		Push      bool         `json:"push"`
		Inbound   *inboundInfo `json:"inbound,omitempty"`
	}{
		Name:      "OpenMaé relay",
		Versions:  []int{protocolVersion},
		QUIC:      quicInfo{Port: port, ALPN: ALPN, Pins: pins},
		WebSocket: wsInfo{Path: wsPath},
		Limits: limitsInfo{
			TubesPerMac:       lim.TubesPerMac,
			KbitPerTube:       lim.BytesPerSecond * 8 / 1000,
			AttemptsPerMinute: lim.AttemptsPerMinute,
		},
		Push: push,
	}
	if inboundDomain != "" {
		doc.Inbound = &inboundInfo{Domain: inboundDomain}
	}
	b, _ := json.Marshal(doc) // cannot fail
	return b
}

// slots counts connections against MaxConnections.
type slots struct {
	n   atomic.Int64
	max int64
}

func (s *slots) acquire() bool {
	for {
		n := s.n.Load()
		if n >= s.max {
			return false
		}
		if s.n.CompareAndSwap(n, n+1) {
			return true
		}
	}
}

func (s *slots) release() { s.n.Add(-1) }

// tracker waits for connection handlers at shutdown. Unlike a bare
// WaitGroup, it refuses new handlers once closed, so none can start while
// it waits.
type tracker struct {
	mu     sync.Mutex
	closed bool
	wg     sync.WaitGroup
}

func (t *tracker) add() bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.closed {
		return false
	}
	t.wg.Add(1)
	return true
}

func (t *tracker) done() { t.wg.Done() }

func (t *tracker) close() {
	t.mu.Lock()
	t.closed = true
	t.mu.Unlock()
}

func (t *tracker) wait(timeout time.Duration) bool {
	done := make(chan struct{})
	go func() {
		t.wg.Wait()
		close(done)
	}()
	select {
	case <-done:
		return true
	case <-time.After(timeout):
		return false
	}
}
