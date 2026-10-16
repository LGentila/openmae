package relay

import (
	"context"
	"crypto/tls"
	"io"
	"testing"
	"time"

	"github.com/quic-go/quic-go"
)

// rawQUIC returns the server side of a fresh QUIC connection with the
// relay's settings, and the client side.
func rawQUIC(t *testing.T) (server, client *quic.Conn) {
	t.Helper()
	_, cert, err := loadQUICIdentity(t.TempDir(), time.Now(), quiet)
	if err != nil {
		t.Fatal(err)
	}
	ln, err := quic.ListenAddr("127.0.0.1:0", quicTLSConfig(cert), quicConfig())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	ctx, cancel := context.WithTimeout(context.Background(), waitFor)
	defer cancel()
	tlsConf := &tls.Config{NextProtos: []string{ALPN}, InsecureSkipVerify: true}
	client, err = quic.DialAddr(ctx, ln.Addr().String(), tlsConf, &quic.Config{EnableDatagrams: true})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { client.CloseWithError(0, "") })
	if server, err = ln.Accept(ctx); err != nil {
		t.Fatal(err)
	}
	return server, client
}

// openEmptyThenWrite opens stream 0 without writing to it, then writes msg
// on stream 4, as Network.framework does.
func openEmptyThenWrite(t *testing.T, client *quic.Conn, msg string) {
	t.Helper()
	if _, err := client.OpenStream(); err != nil { // stream 0
		t.Fatal(err)
	}
	st, err := client.OpenStream() // stream 4
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.Write([]byte(msg)); err != nil {
		t.Fatal(err)
	}
}

// The reason for streamPicker: data on stream 4 opens stream 0 too, and
// quic-go hands that empty stream over first.
func TestQUICHandsOverTheEmptyStreamFirst(t *testing.T) {
	server, client := rawQUIC(t)
	openEmptyThenWrite(t, client, "hello")
	ctx, cancel := context.WithTimeout(context.Background(), waitFor)
	defer cancel()
	st, err := server.AcceptStream(ctx)
	if err != nil || st.StreamID() != 0 {
		t.Fatalf("first stream accepted: %v, %v", st, err)
	}
}

func TestPickMainStream(t *testing.T) {
	server, client := rawQUIC(t)
	openEmptyThenWrite(t, client, "hello")
	p := pickMainStream(server)
	select {
	case <-p.found:
	case <-time.After(waitFor):
		t.Fatal("main stream not found")
	}
	if p.main.StreamID() != 4 {
		t.Errorf("main stream %d, want 4", p.main.StreamID())
	}
	// The byte read to find the stream is read again, in order.
	c := newQUICConn(server, p.main, p.head)
	got := make([]byte, 5)
	if _, err := io.ReadFull(c, got); err != nil || string(got) != "hello" {
		t.Errorf("read %q, %v", got, err)
	}
}
