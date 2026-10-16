package relay

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/quic-go/quic-go"
)

// Test helpers: a relay started in-process on random ports, and clients
// playing the Mac and the iPhone over either transport.

const (
	viaQUIC = "quic"
	viaWS   = "websocket"
	waitFor = 5 * time.Second
)

type testRelay struct {
	t        *testing.T
	srv      *Server
	httpURL  string
	wsURL    string
	quicAddr string
	logs     *syncBuffer
	stop     func() // shuts the relay down and waits for it
}

// testLimits keep the protocol's values that tests check, and shorten the
// waits.
func testLimits() Limits {
	return Limits{
		AttemptsPerMinute: 1000,
		BytesPerSecond:    10 << 20,
		BurstBytes:        10 << 20,
		Linger:            300 * time.Millisecond,
	}
}

func startRelay(t *testing.T, change func(*Config)) *testRelay {
	t.Helper()
	logs := &syncBuffer{}
	cfg := Config{
		HTTPAddr: "127.0.0.1:0",
		QUICAddr: "127.0.0.1:0",
		DataDir:  t.TempDir(),
		Limits:   testLimits(),
		Logger:   slog.New(slog.NewTextHandler(logs, &slog.HandlerOptions{Level: slog.LevelDebug})),
	}
	if change != nil {
		change(&cfg)
	}
	srv, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- srv.Run(ctx) }()
	httpAddr := srv.httpLn.Addr().String()
	r := &testRelay{
		t:        t,
		srv:      srv,
		httpURL:  "http://" + httpAddr,
		wsURL:    "ws://" + httpAddr + wsPath,
		quicAddr: srv.udp.LocalAddr().String(),
		logs:     logs,
	}
	r.stop = sync.OnceFunc(func() {
		cancel()
		if err := <-done; err != nil {
			t.Errorf("Run: %v", err)
		}
	})
	t.Cleanup(func() {
		r.stop()
		if t.Failed() {
			t.Logf("relay logs:\n%s", logs.String())
		}
	})
	return r
}

type syncBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.b.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.b.String()
}

// info fetches /v1/info.
func (r *testRelay) info(t *testing.T) map[string]any {
	t.Helper()
	resp, err := http.Get(r.httpURL + "/v1/info")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var doc map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&doc); err != nil {
		t.Fatal(err)
	}
	return doc
}

func (r *testRelay) pins(t *testing.T) []string {
	t.Helper()
	var pins []string
	for _, p := range r.info(t)["quic"].(map[string]any)["spki_sha256"].([]any) {
		pins = append(pins, p.(string))
	}
	return pins
}

// client is one connection to the relay.
type client struct {
	t    *testing.T
	kind string
	qc   *quic.Conn
	st   *quic.Stream
	ws   *websocket.Conn
	// empty is a stream opened before st and never written to, as
	// Network.framework does with stream 0 when it carries datagrams.
	empty *quic.Stream

	// Filled by pipe.
	mu        sync.Mutex
	buf       []byte
	changed   chan struct{}
	datagrams chan []byte
	closed    chan struct{}
}

// viaQUICStream4 is QUIC with stream 0 left empty and stream 4 as the main
// stream.
const viaQUICStream4 = "quic-stream-4"

func dial(t *testing.T, r *testRelay, kind string) *client {
	t.Helper()
	switch kind {
	case viaQUIC:
		return dialQUIC(t, r, &quic.Config{EnableDatagrams: true})
	case viaQUICStream4:
		return dialQUICAfterEmptyStream(t, r)
	case viaWS:
		return dialWS(t, r)
	}
	t.Fatalf("unknown transport %q", kind)
	return nil
}

func dialQUICAfterEmptyStream(t *testing.T, r *testRelay) *client {
	t.Helper()
	c := dialQUIC(t, r, &quic.Config{EnableDatagrams: true})
	c.empty = c.st
	st, err := c.qc.OpenStream()
	if err != nil {
		t.Fatal(err)
	}
	c.st = st
	if c.empty.StreamID() != 0 || c.st.StreamID() != 4 {
		t.Fatalf("streams %d and %d, want 0 and 4", c.empty.StreamID(), c.st.StreamID())
	}
	return c
}

// emptyStreamUntouched checks that the relay neither reset, cancelled nor
// finished the empty stream.
func (c *client) emptyStreamUntouched() {
	c.t.Helper()
	if err := context.Cause(c.empty.Context()); err != nil {
		c.t.Errorf("stream 0 cancelled by the relay: %v", err)
	}
	_ = c.empty.SetReadDeadline(time.Now().Add(50 * time.Millisecond))
	if _, err := c.empty.Read(make([]byte, 1)); !isTimeout(err) {
		c.t.Errorf("stream 0: read gave %v, want nothing at all", err)
	}
}

// dialQUIC accepts the relay's certificate as an OpenMaé client does: only
// if its key matches a pin from /v1/info.
func dialQUIC(t *testing.T, r *testRelay, conf *quic.Config) *client {
	t.Helper()
	pins := r.pins(t)
	tlsConf := &tls.Config{
		NextProtos:         []string{ALPN},
		InsecureSkipVerify: true, // replaced by the pin check below
		VerifyPeerCertificate: func(raw [][]byte, _ [][]*x509.Certificate) error {
			cert, err := x509.ParseCertificate(raw[0])
			if err != nil {
				return err
			}
			sum := sha256.Sum256(cert.RawSubjectPublicKeyInfo)
			for _, p := range pins {
				if p == base64.StdEncoding.EncodeToString(sum[:]) {
					return nil
				}
			}
			return errors.New("certificate key matches no pin")
		},
	}
	ctx, cancel := context.WithTimeout(context.Background(), waitFor)
	defer cancel()
	qc, err := quic.DialAddr(ctx, r.quicAddr, tlsConf, conf)
	if err != nil {
		t.Fatal(err)
	}
	st, err := qc.OpenStreamSync(ctx)
	if err != nil {
		t.Fatal(err)
	}
	c := &client{t: t, kind: viaQUIC, qc: qc, st: st}
	t.Cleanup(c.close)
	return c
}

func dialWS(t *testing.T, r *testRelay) *client {
	t.Helper()
	ws, _, err := websocket.DefaultDialer.Dial(r.wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	c := &client{t: t, kind: viaWS, ws: ws}
	t.Cleanup(c.close)
	return c
}

func (c *client) send(v any) {
	c.t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		c.t.Fatal(err)
	}
	c.sendRaw(b)
}

// sendRaw sends one control message as it is: framed over QUIC, a text
// message over WebSocket.
func (c *client) sendRaw(b []byte) {
	c.t.Helper()
	var err error
	if c.kind == viaQUIC {
		_, err = c.st.Write(appendFrame(nil, b))
	} else {
		err = c.ws.WriteMessage(websocket.TextMessage, b)
	}
	if err != nil {
		c.t.Fatal(err)
	}
}

func (c *client) recvErr() (map[string]any, error) {
	var b []byte
	var err error
	if c.kind == viaQUIC {
		_ = c.st.SetReadDeadline(time.Now().Add(waitFor))
		b, err = readFrame(c.st)
	} else {
		_ = c.ws.SetReadDeadline(time.Now().Add(waitFor))
		var typ int
		typ, b, err = c.ws.ReadMessage()
		if err == nil && typ != websocket.TextMessage {
			err = fmt.Errorf("message of type %d before piping", typ)
		}
	}
	if err != nil {
		return nil, err
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		return nil, fmt.Errorf("%q: %w", b, err)
	}
	return m, nil
}

func (c *client) recv() map[string]any {
	c.t.Helper()
	m, err := c.recvErr()
	if err != nil {
		c.t.Fatalf("%s: waiting for a control message: %v", c.kind, err)
	}
	return m
}

func (c *client) expect(op string) map[string]any {
	c.t.Helper()
	m := c.recv()
	if m["op"] != op {
		c.t.Fatalf("%s: got %v, want op %q", c.kind, m, op)
	}
	return m
}

// expectError checks the error message, and that the relay then closes.
func (c *client) expectError(code string) {
	c.t.Helper()
	if m := c.expect("error"); m["code"] != code {
		c.t.Fatalf("%s: got error %v, want %q", c.kind, m["code"], code)
	}
	c.expectClosed()
}

// expectClosed checks that the relay closes the connection, without a
// control message first.
func (c *client) expectClosed() {
	c.t.Helper()
	m, err := c.recvErr()
	if err == nil {
		c.t.Fatalf("%s: got %v, want the connection closed", c.kind, m)
	}
	if isTimeout(err) {
		c.t.Fatalf("%s: the relay did not close the connection", c.kind)
	}
}

func isTimeout(err error) bool {
	var ne net.Error
	return errors.As(err, &ne) && ne.Timeout()
}

// pipe starts reading tube bytes and datagrams in the background.
func (c *client) pipe() {
	c.changed = make(chan struct{}, 1)
	c.datagrams = make(chan []byte, 1024)
	c.closed = make(chan struct{})
	if c.kind == viaQUIC {
		_ = c.st.SetReadDeadline(time.Time{})
		go func() {
			defer close(c.closed)
			buf := make([]byte, 32<<10)
			for {
				n, err := c.st.Read(buf)
				c.add(buf[:n])
				if err != nil {
					return
				}
			}
		}()
		go func() {
			for {
				p, err := c.qc.ReceiveDatagram(context.Background())
				if err != nil {
					return
				}
				c.datagrams <- p
			}
		}()
		return
	}
	_ = c.ws.SetReadDeadline(time.Time{})
	go func() {
		defer close(c.closed)
		for {
			typ, b, err := c.ws.ReadMessage()
			if err != nil {
				return
			}
			if typ != websocket.BinaryMessage || len(b) == 0 {
				c.t.Errorf("websocket: unexpected message %d %q", typ, b)
				return
			}
			switch b[0] {
			case recordBytes:
				c.add(b[1:])
			case recordDatagram:
				c.datagrams <- b[1:]
			default:
				c.t.Errorf("websocket: unknown record %#x", b[0])
				return
			}
		}
	}()
}

func (c *client) add(p []byte) {
	c.mu.Lock()
	c.buf = append(c.buf, p...)
	c.mu.Unlock()
	select {
	case c.changed <- struct{}{}:
	default:
	}
}

func (c *client) write(p []byte) {
	c.t.Helper()
	var err error
	if c.kind == viaQUIC {
		_, err = c.st.Write(p)
	} else {
		err = c.ws.WriteMessage(websocket.BinaryMessage, append([]byte{recordBytes}, p...))
	}
	if err != nil {
		c.t.Fatal(err)
	}
}

// read waits for n tube bytes and takes them.
func (c *client) read(n int) []byte {
	c.t.Helper()
	deadline := time.After(waitFor)
	for {
		c.mu.Lock()
		if len(c.buf) >= n {
			p := c.buf[:n:n]
			c.buf = c.buf[n:]
			c.mu.Unlock()
			return p
		}
		have := len(c.buf)
		c.mu.Unlock()
		select {
		case <-c.changed:
		case <-deadline:
			c.t.Fatalf("%s: got %d tube bytes, want %d", c.kind, have, n)
		}
	}
}

func (c *client) sendDatagram(p []byte) error {
	if c.kind == viaQUIC {
		return c.qc.SendDatagram(p)
	}
	return c.ws.WriteMessage(websocket.BinaryMessage, append([]byte{recordDatagram}, p...))
}

// waitClosed reports whether the relay closed the tube within d.
func (c *client) waitClosed(d time.Duration) bool {
	select {
	case <-c.closed:
		return true
	case <-time.After(d):
		return false
	}
}

func (c *client) close() {
	if c.kind == viaQUIC {
		_ = c.qc.CloseWithError(0, "")
	} else {
		_ = c.ws.Close()
	}
}

// closeGracefully ends the tube from the client side the way a careful
// client does: what it wrote is delivered before it goes.
func (c *client) closeGracefully() {
	if c.kind == viaQUIC {
		_ = c.st.Close()
		return // the relay closes the connection after the FIN
	}
	msg := websocket.FormatCloseMessage(websocket.CloseNormalClosure, "")
	_ = c.ws.WriteControl(websocket.CloseMessage, msg, time.Now().Add(time.Second))
}

// Macs and iPhones.

type fakeMac struct {
	t    *testing.T
	r    *testRelay
	priv ed25519.PrivateKey
	id   string
	ctrl *client
}

func newMac(t *testing.T, r *testRelay) *fakeMac {
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	return &fakeMac{t: t, r: r, priv: priv, id: deviceID(pub)}
}

func (m *fakeMac) hello(c *client) {
	m.t.Helper()
	c.send(map[string]any{
		"op": "hello", "v": 1, "role": "mac", "id": m.id,
		"key": b64url.EncodeToString(m.priv.Public().(ed25519.PublicKey)),
	})
}

// register opens a control connection and registers on it.
func (m *fakeMac) register(kind string) *client {
	m.t.Helper()
	c := dial(m.t, m.r, kind)
	m.hello(c)
	nonce, ok := decodeFixed(c.expect("challenge")["nonce"].(string), 32)
	if !ok {
		m.t.Fatal("bad nonce")
	}
	sig := ed25519.Sign(m.priv, append([]byte(registerContext), nonce...))
	c.send(map[string]any{"op": "register", "sig": b64url.EncodeToString(sig)})
	c.expect("registered")
	m.ctrl = c
	return c
}

// incoming waits for the relay's next incoming and returns its tube token.
func (m *fakeMac) incoming() string {
	m.t.Helper()
	return m.ctrl.expect("incoming")["tube"].(string)
}

func (m *fakeMac) accept(kind, tube string) *client {
	m.t.Helper()
	c := dial(m.t, m.r, kind)
	c.send(map[string]any{"op": "accept", "v": 1, "tube": tube})
	c.expect("accepted")
	return c
}

func connect(t *testing.T, r *testRelay, kind, mac string) *client {
	t.Helper()
	c := dial(t, r, kind)
	c.send(map[string]any{"op": "connect", "v": 1, "to": mac})
	return c
}

// openTube connects an iPhone to a registered Mac and returns both ends of
// the tube, piping.
func (m *fakeMac) openTube(phoneKind, tubeKind string) (phone, mac *client) {
	m.t.Helper()
	phone = connect(m.t, m.r, phoneKind, m.id)
	mac = m.accept(tubeKind, m.incoming())
	phone.expect("connected")
	phone.pipe()
	mac.pipe()
	return phone, mac
}

var transports = []string{viaQUIC, viaWS}

func payload(n int, seed byte) []byte {
	p := make([]byte, n)
	for i := range p {
		p[i] = seed + byte(i*7)
	}
	return p
}

// datagramPasses sends a datagram from one end until the other gets it:
// datagrams may be lost, even on loopback.
func datagramPasses(t *testing.T, from, to *client, p []byte) {
	t.Helper()
	deadline := time.After(waitFor)
	tick := time.NewTicker(20 * time.Millisecond)
	defer tick.Stop()
	for {
		if err := from.sendDatagram(p); err != nil {
			t.Fatalf("%s → %s: %v", from.kind, to.kind, err)
		}
		select {
		case got := <-to.datagrams:
			if bytes.Equal(got, p) {
				return
			}
			// A late copy of an earlier datagram: keep waiting.
		case <-tick.C:
		case <-deadline:
			t.Fatalf("%s → %s: datagram never arrived", from.kind, to.kind)
		}
	}
}
