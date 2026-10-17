package relay

import (
	"context"
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"net/netip"
	"sync"
	"sync/atomic"
	"time"

	"github.com/quic-go/quic-go"
)

func quicTLSConfig(cert tls.Certificate) *tls.Config {
	return &tls.Config{
		Certificates: []tls.Certificate{cert},
		NextProtos:   []string{ALPN},
		MinVersion:   tls.VersionTLS13,
	}
}

func quicConfig() *quic.Config {
	return &quic.Config{
		EnableDatagrams: true,
		// The main stream is not always stream 0 (see streamPicker), so a
		// few bidirectional streams may open; none of the other kind.
		MaxIncomingStreams:    4,
		MaxIncomingUniStreams: -1,
		// Longer than the 75 seconds after which the relay closes a silent
		// control connection, so that its own timer decides.
		MaxIdleTimeout: 90 * time.Second,
		// A tube carries 256 kbit/s at most: small windows are plenty and
		// bound what a client can make the relay buffer.
		InitialStreamReceiveWindow:     64 << 10,
		MaxStreamReceiveWindow:         256 << 10,
		InitialConnectionReceiveWindow: 64 << 10,
		MaxConnectionReceiveWindow:     256 << 10,
	}
}

var errExtraStream = fmt.Errorf("%w: data on a second stream", errProtocol)

// streamPicker finds a client's main stream: the first bidirectional stream
// that carries data. Apple's Network.framework, when it carries datagrams
// too, sends on stream 4 and leaves stream 0 empty. Empty streams are left
// alone, neither reset nor cancelled; data on any stream but the main one
// breaks the protocol.
type streamPicker struct {
	mu      sync.Mutex
	main    *quic.Stream
	head    []byte        // read from main to find it
	found   chan struct{} // closed once main is known
	extra   bool          // another stream carried data
	onExtra func()
}

// pickMainStream watches the client's streams for as long as the connection
// lasts.
func pickMainStream(qc *quic.Conn) *streamPicker {
	p := &streamPicker{found: make(chan struct{})}
	go func() {
		for {
			st, err := qc.AcceptStream(qc.Context())
			if err != nil {
				return // the connection is over
			}
			go p.watch(st)
		}
	}()
	return p
}

// watch waits for the first byte on st. On a stream that stays empty it
// waits until the connection ends; MaxIncomingStreams bounds such streams,
// since they are never closed and so never make room for others.
func (p *streamPicker) watch(st *quic.Stream) {
	b := make([]byte, 1)
	if n, _ := st.Read(b); n == 0 {
		return // finished without data, reset, or the connection is over
	}
	p.mu.Lock()
	if p.main == nil {
		p.main, p.head = st, b
		p.mu.Unlock()
		close(p.found)
		return
	}
	first := !p.extra
	p.extra = true
	onExtra := p.onExtra
	p.mu.Unlock()
	if first && onExtra != nil {
		onExtra()
	}
}

// setOnExtra says what to do if another stream carries data, and does it at
// once if that already happened.
func (p *streamPicker) setOnExtra(f func()) {
	p.mu.Lock()
	p.onExtra = f
	already := p.extra
	p.mu.Unlock()
	if already {
		go f()
	}
}

// quicConn is a client's QUIC connection with its main stream.
type quicConn struct {
	qc       *quic.Conn
	st       *quic.Stream
	head     []byte // read from st to find it, and read again first
	addr     netip.Addr
	wmu      sync.Mutex // quic-go forbids concurrent Write, and Close during Write
	piping   atomic.Bool
	violated atomic.Bool // data came on a second stream
}

func newQUICConn(qc *quic.Conn, st *quic.Stream, head []byte) *quicConn {
	c := &quicConn{qc: qc, st: st, head: head}
	if ua, ok := qc.RemoteAddr().(*net.UDPAddr); ok {
		c.addr = ua.AddrPort().Addr().Unmap()
	}
	return c
}

// Read reads the main stream, starting with what was read to find it, so
// that nothing is lost or reordered.
func (c *quicConn) Read(p []byte) (int, error) {
	if len(c.head) > 0 {
		n := copy(p, c.head)
		c.head = c.head[n:]
		return n, nil
	}
	return c.st.Read(p)
}

func (c *quicConn) transport() string     { return "quic" }
func (c *quicConn) ip() netip.Addr        { return c.addr }
func (c *quicConn) gone() <-chan struct{} { return c.qc.Context().Done() }

func (c *quicConn) supportsDatagrams() bool {
	return c.qc.ConnectionState().SupportsDatagrams.Remote
}

func (c *quicConn) readControl(deadline time.Time) ([]byte, error) {
	_ = c.st.SetReadDeadline(deadline)
	defer c.st.SetReadDeadline(time.Time{})
	return readFrame(c)
}

func (c *quicConn) writeControl(msg []byte) error {
	return c.write(appendFrame(nil, msg), controlWriteTimeout)
}

func (c *quicConn) writeBytes(p []byte) error { return c.write(p, pipeWriteTimeout) }

func (c *quicConn) write(p []byte, timeout time.Duration) error {
	c.wmu.Lock()
	defer c.wmu.Unlock()
	_ = c.st.SetWriteDeadline(time.Now().Add(timeout))
	_, err := c.st.Write(p)
	return err
}

// writeDatagram fails, and the datagram is dropped, when it is too large
// for the client's path or the client did not enable datagrams.
func (c *quicConn) writeDatagram(p []byte) error { return c.qc.SendDatagram(p) }

func (c *quicConn) policeDatagrams(ctx context.Context, violation func()) {
	go func() {
		if _, err := c.qc.ReceiveDatagram(ctx); err == nil {
			violation()
		}
	}()
}

func (c *quicConn) forward(ctx context.Context, dst sink, f *flow) error {
	c.piping.Store(true)
	dctx, stop := context.WithCancel(ctx)
	defer stop()
	go func() {
		for {
			p, err := c.qc.ReceiveDatagram(dctx)
			if err != nil {
				return
			}
			f.forwardDatagram(p, dst)
		}
	}()
	err := f.forwardStream(ctx, c, make([]byte, readChunk), dst)
	switch {
	case c.violated.Load():
		return errExtraStream
	case err != nil:
		return err
	}
	return io.EOF // the client finished its main stream
}

func (c *quicConn) closeWrite(time.Time) {
	c.wmu.Lock()
	defer c.wmu.Unlock()
	_ = c.st.Close() // FIN, sent after the data already written
}

// drain waits for the client to close the connection: closing it first
// would cut off data still in flight to the client.
func (c *quicConn) drain(deadline time.Time) {
	t := time.NewTimer(time.Until(deadline))
	defer t.Stop()
	select {
	case <-c.qc.Context().Done():
	case <-t.C:
	}
}

func (c *quicConn) closeNow() { _ = c.qc.CloseWithError(0, "") }
