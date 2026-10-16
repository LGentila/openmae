package relay

import (
	"context"
	"io"
	"net/netip"
	"sync/atomic"
	"time"
)

const (
	controlWriteTimeout = 10 * time.Second
	// A peer that does not read its tube for this long is gone.
	pipeWriteTimeout = 30 * time.Second
	readChunk        = 16 << 10
	// The largest datagram the relay passes on, the largest QUIC DATAGRAM
	// frame it accepts; real ones (20 ms of Opus) are far smaller.
	maxDatagramSize = 16383
)

// conn is a client connection over QUIC or WebSocket. Before piping it
// carries control messages; then the tube's bytes and datagrams.
//
// Reads happen on one goroutine at a time; writes and the close methods may
// come from any goroutine.
type conn interface {
	transport() string // "quic" or "websocket", for logs
	ip() netip.Addr    // for rate limiting only
	supportsDatagrams() bool
	// gone is closed when the connection is over. A WebSocket connection
	// only learns that its client left by reading, so its gone is closed
	// only when the relay closes it.
	gone() <-chan struct{}

	readControl(deadline time.Time) ([]byte, error)
	writeControl(msg []byte) error
	// policeDatagrams calls violation if a datagram arrives before ctx ends.
	policeDatagrams(ctx context.Context, violation func())

	// forward copies what the client sends into dst until the client stops,
	// an error occurs, or a write to dst fails.
	forward(ctx context.Context, dst conn, f *flow) error
	writeBytes(p []byte) error
	writeDatagram(p []byte) error

	// closeWrite tells the client that nothing more will come, after what
	// was already written.
	closeWrite(deadline time.Time)
	// drain waits until the client has gone, or until deadline. Only when
	// nothing else reads the connection.
	drain(deadline time.Time)
	closeNow()
}

// fail sends an error to the client, then closes the connection once the
// client had a chance to read it.
func fail(c conn, code string, linger time.Duration) {
	deadline := time.Now().Add(linger)
	if c.writeControl(errorMessage(code)) == nil {
		c.closeWrite(deadline)
		c.drain(deadline)
	}
	c.closeNow()
}

// flow is one direction of a tube.
type flow struct {
	budget    *bucket
	activity  *activity // shared by both directions
	bytes     atomic.Int64
	datagrams atomic.Int64
	dropped   atomic.Int64
}

// activity is when a tube last carried anything, on the monotonic clock so
// that a change of the system time cannot make a tube look idle.
type activity struct {
	start time.Time
	last  atomic.Int64 // time.Since(start)
}

func newActivity() *activity { return &activity{start: time.Now()} }

func (a *activity) touch()                 { a.last.Store(int64(time.Since(a.start))) }
func (a *activity) idleFor() time.Duration { return time.Since(a.start) - time.Duration(a.last.Load()) }

func (f *flow) forwardBytes(ctx context.Context, p []byte, dst conn) error {
	if err := f.budget.wait(ctx, len(p)); err != nil {
		return err
	}
	if err := dst.writeBytes(p); err != nil {
		return err
	}
	f.bytes.Add(int64(len(p)))
	f.activity.touch()
	return nil
}

func (f *flow) forwardDatagram(p []byte, dst conn) {
	if len(p) > maxDatagramSize || !f.budget.allow(len(p)) || dst.writeDatagram(p) != nil {
		f.dropped.Add(1)
		return
	}
	f.datagrams.Add(1)
	f.activity.touch()
}

// forwardStream copies r to dst until r ends.
func (f *flow) forwardStream(ctx context.Context, r io.Reader, buf []byte, dst conn) error {
	for {
		n, err := r.Read(buf)
		if n > 0 {
			if werr := f.forwardBytes(ctx, buf[:n], dst); werr != nil {
				return werr
			}
		}
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
	}
}
