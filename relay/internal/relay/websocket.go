package relay

import (
	"context"
	"fmt"
	"io"
	"net/netip"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// Once piping starts, each binary message is one record: its first byte
// says what the rest is.
const (
	recordBytes    = 0x01
	recordDatagram = 0x02
)

var (
	errNotText   = fmt.Errorf("%w: control messages are text", errProtocol)
	errNotRecord = fmt.Errorf("%w: not a tube record", errProtocol)
)

func newUpgrader() *websocket.Upgrader {
	return &websocket.Upgrader{
		HandshakeTimeout: 10 * time.Second,
		// Most connections are Macs idling on their control connection: lend
		// them write buffers only while they write.
		WriteBufferPool: &sync.Pool{},
		// gorilla's default origin check lets in clients that send no Origin
		// or the relay's own, and turns away pages of other sites in browsers.
	}
}

// wsConn is a client's WebSocket connection.
type wsConn struct {
	ws        *websocket.Conn
	addr      netip.Addr
	wmu       sync.Mutex // gorilla allows one writer at a time
	closeOnce sync.Once
	closed    chan struct{}
}

func newWSConn(ws *websocket.Conn, addr netip.Addr) *wsConn {
	return &wsConn{ws: ws, addr: addr, closed: make(chan struct{})}
}

func (c *wsConn) transport() string       { return "websocket" }
func (c *wsConn) ip() netip.Addr          { return c.addr }
func (c *wsConn) supportsDatagrams() bool { return true }
func (c *wsConn) gone() <-chan struct{}   { return c.closed }

// Binary messages before piping are caught by readControl.
func (c *wsConn) policeDatagrams(context.Context, func()) {}

func (c *wsConn) readControl(deadline time.Time) ([]byte, error) {
	_ = c.ws.SetReadDeadline(deadline)
	typ, r, err := c.ws.NextReader()
	if err != nil {
		return nil, err
	}
	if typ != websocket.TextMessage {
		return nil, errNotText
	}
	b, err := io.ReadAll(io.LimitReader(r, maxControlSize+1))
	if err != nil {
		return nil, err
	}
	if len(b) > maxControlSize {
		return nil, errTooLarge
	}
	_ = c.ws.SetReadDeadline(time.Time{})
	return b, nil
}

func (c *wsConn) writeControl(msg []byte) error {
	c.wmu.Lock()
	defer c.wmu.Unlock()
	_ = c.ws.SetWriteDeadline(time.Now().Add(controlWriteTimeout))
	return c.ws.WriteMessage(websocket.TextMessage, msg)
}

func (c *wsConn) writeBytes(p []byte) error    { return c.writeRecord(recordBytes, p) }
func (c *wsConn) writeDatagram(p []byte) error { return c.writeRecord(recordDatagram, p) }

func (c *wsConn) writeRecord(kind byte, p []byte) error {
	c.wmu.Lock()
	defer c.wmu.Unlock()
	_ = c.ws.SetWriteDeadline(time.Now().Add(pipeWriteTimeout))
	w, err := c.ws.NextWriter(websocket.BinaryMessage)
	if err != nil {
		return err
	}
	_, err = w.Write([]byte{kind})
	if err == nil {
		_, err = w.Write(p)
	}
	if cerr := w.Close(); err == nil {
		err = cerr
	}
	return err
}

func (c *wsConn) forward(ctx context.Context, dst sink, f *flow) error {
	buf := make([]byte, readChunk)
	for {
		typ, r, err := c.ws.NextReader()
		if err != nil {
			return err
		}
		var kind [1]byte
		if typ != websocket.BinaryMessage {
			return errNotRecord
		}
		if _, err := io.ReadFull(r, kind[:]); err != nil {
			if err == io.EOF { // an empty message
				return errNotRecord
			}
			return err
		}
		switch kind[0] {
		case recordBytes:
			// Streamed in chunks: a record may be of any size.
			if err := f.forwardStream(ctx, r, buf, dst); err != nil {
				return err
			}
		case recordDatagram:
			p, err := io.ReadAll(io.LimitReader(r, maxDatagramSize+1))
			if err != nil {
				return err
			}
			f.forwardDatagram(p, dst) // drops it when too large
		default:
			return errNotRecord
		}
	}
}

func (c *wsConn) closeWrite(deadline time.Time) {
	msg := websocket.FormatCloseMessage(websocket.CloseNormalClosure, "")
	_ = c.ws.WriteControl(websocket.CloseMessage, msg, deadline)
}

// drain waits for the client's close message: closing the TCP connection
// while unread data is in its buffers would send a reset, which can discard
// what the client has not read yet.
func (c *wsConn) drain(deadline time.Time) {
	_ = c.ws.SetReadDeadline(deadline)
	for {
		if _, _, err := c.ws.NextReader(); err != nil {
			return
		}
	}
}

func (c *wsConn) closeNow() {
	c.closeOnce.Do(func() {
		// Says "going away" unless a close message was already sent.
		msg := websocket.FormatCloseMessage(websocket.CloseGoingAway, "")
		_ = c.ws.WriteControl(websocket.CloseMessage, msg, time.Now().Add(100*time.Millisecond))
		_ = c.ws.Close()
		close(c.closed)
	})
}
