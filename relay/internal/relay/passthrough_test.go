package relay

import (
	"bufio"
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/binary"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/netip"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

const testInboundDomain = "in.example.test"

func inboundDomain(c *Config) {
	c.InboundDomain = testInboundDomain
	c.InboundAddr = "127.0.0.1:0"
}

func TestParseInboundDomain(t *testing.T) {
	for in, want := range map[string]string{
		"in.openmae.com":   "in.openmae.com",
		" In.Example.COM.": "in.example.com",
		"a-b.c2.example":   "a-b.c2.example",
	} {
		if got, err := ParseInboundDomain(in); err != nil || got != want {
			t.Errorf("%q: %q, %v", in, got, err)
		}
	}
	for _, in := range []string{"", "com", "*.in.example.com", "in..example.com", "-in.example.com",
		"in.example.com/x", "in example.com", "https://in.example.com"} {
		if got, err := ParseInboundDomain(in); err == nil {
			t.Errorf("%q accepted as %q", in, got)
		}
	}
}

func TestInboundNameOf(t *testing.T) {
	name := "4zvomamapw57cf63xyx4cjb3qe"
	for _, host := range []string{name + ".in.example.test", strings.ToUpper(name) + ".IN.example.test",
		name + ".in.example.test:80"} {
		if got, ok := inboundNameOf(host, testInboundDomain); !ok || got != name {
			t.Errorf("%q: %q %v", host, got, ok)
		}
	}
	for _, host := range []string{"in.example.test", name + ".example.test", "x." + name + ".in.example.test",
		name[:25] + ".in.example.test", name + "1.in.example.test", name + ".in.example.test.evil",
		"relay.example.test", ""} {
		if got, ok := inboundNameOf(host, testInboundDomain); ok {
			t.Errorf("%q gave %q", host, got)
		}
	}
	if _, ok := inboundNameOf(name+".in.example.test", ""); ok {
		t.Error("a name without an inbound domain")
	}
}

func proxyV2(ip netip.Addr, port uint16) []byte {
	b := append([]byte{}, proxyV2Signature...)
	if ip.Is4() {
		b = append(b, 0x21, 0x11, 0, 12)
		a := ip.As4()
		b = append(b, a[:]...)
		b = append(b, 127, 0, 0, 1)
	} else {
		b = append(b, 0x21, 0x21, 0, 36)
		a := ip.As16()
		b = append(b, a[:]...)
		b = append(b, net.IPv6loopback...)
	}
	b = binary.BigEndian.AppendUint16(b, port)
	return binary.BigEndian.AppendUint16(b, 8444)
}

func TestReadProxyHeader(t *testing.T) {
	local := append(append([]byte{}, proxyV2Signature...), 0x20, 0x00, 0, 0)
	withTLV := proxyV2(netip.MustParseAddr("198.51.100.4"), 1234)
	binary.BigEndian.PutUint16(withTLV[14:], 12+7)
	withTLV = append(withTLV, 0x04, 0, 4, 'n', 'o', 'o', 'p')
	for _, c := range []struct {
		name   string
		header []byte
		want   string // "" for the TCP peer's address
	}{
		{"v2 IPv4", proxyV2(netip.MustParseAddr("203.0.113.7"), 51000), "203.0.113.7"},
		{"v2 IPv6", proxyV2(netip.MustParseAddr("2001:db8::7"), 51000), "2001:db8::7"},
		{"v2 IPv4-mapped", proxyV2(netip.MustParseAddr("::ffff:203.0.113.8"), 1), "203.0.113.8"},
		{"v2 with an extension", withTLV, "198.51.100.4"},
		{"v2 LOCAL", local, ""},
		{"v1 IPv4", []byte("PROXY TCP4 203.0.113.9 10.0.0.2 51000 8444\r\n"), "203.0.113.9"},
		{"v1 IPv6", []byte("PROXY TCP6 2001:db8::9 2001:db8::1 51000 8444\r\n"), "2001:db8::9"},
		{"v1 UNKNOWN", []byte("PROXY UNKNOWN\r\n"), ""},
	} {
		r := bufio.NewReader(bytes.NewReader(append(c.header, "\x16\x03\x01rest"...)))
		ip, err := readProxyHeader(r)
		if err != nil {
			t.Errorf("%s: %v", c.name, err)
			continue
		}
		if got := ip.String(); c.want == "" && ip.IsValid() || c.want != "" && got != c.want {
			t.Errorf("%s: %s, want %q", c.name, got, c.want)
		}
		if rest, _ := io.ReadAll(r); string(rest) != "\x16\x03\x01rest" {
			t.Errorf("%s: left %q", c.name, rest)
		}
	}
	badVersion := proxyV2(netip.MustParseAddr("203.0.113.7"), 1)
	badVersion[12] = 0x11
	short := proxyV2(netip.MustParseAddr("203.0.113.7"), 1)
	binary.BigEndian.PutUint16(short[14:], 4)
	for _, c := range []struct {
		name   string
		header []byte
	}{
		{"none: TLS at once", []byte("\x16\x03\x01\x02\x00\x01\x00\x01\xfc\x03\x03rest")},
		{"none: HTTP", []byte("GET / HTTP/1.1\r\nHost: x\r\n\r\n")},
		{"v1 without CRLF", []byte("PROXY TCP4 203.0.113.9 10.0.0.2 51000 8444\n")},
		{"v1 wrong family", []byte("PROXY TCP6 203.0.113.9 10.0.0.2 51000 8444\r\n")},
		{"v1 bad port", []byte("PROXY TCP4 203.0.113.9 10.0.0.2 70000 8444\r\n")},
		{"v1 too long", []byte("PROXY TCP4 " + strings.Repeat("1", 120) + "\r\n")},
		{"v2 bad version", badVersion},
		{"v2 short addresses", short},
	} {
		if ip, err := readProxyHeader(bufio.NewReader(bytes.NewReader(c.header))); err == nil {
			t.Errorf("%s: accepted, %v", c.name, ip)
		}
	}
}

func TestChallengesStore(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	c := newChallenges(10*time.Minute, 2, 2, func() time.Time { return now })
	c.put("a", "t1", "t1.k")
	c.put("a", "t2", "t2.k")
	if got, ok := c.get("a", "t1"); !ok || got != "t1.k" {
		t.Errorf("t1: %q %v", got, ok)
	}
	if _, ok := c.get("b", "t1"); ok {
		t.Error("another name's answer")
	}
	c.put("a", "t3", "t3.k") // the oldest goes
	if _, ok := c.get("a", "t1"); ok {
		t.Error("t1 kept past 2 per name")
	}
	c.put("a", "t3", "t3.k2") // the same token again replaces it
	if got, _ := c.get("a", "t3"); got != "t3.k2" {
		t.Errorf("t3: %q", got)
	}
	if !c.put("b", "u1", "u1.k") || c.put("c", "v1", "v1.k") {
		t.Error("the number of names is not bounded")
	}
	now = now.Add(10*time.Minute - time.Second)
	if _, ok := c.get("a", "t3"); !ok {
		t.Error("expired early")
	}
	now = now.Add(time.Second)
	if _, ok := c.get("a", "t3"); ok {
		t.Error("kept past 10 minutes")
	}
	if !c.put("c", "v1", "v1.k") {
		t.Error("expired names still count")
	}
}

func TestValidChallenge(t *testing.T) {
	token := "evaGxfADs6pSRb2LAv9IZf17Dt3juxGJ-PCt92wr-oA"
	thumb := "NzbLsXh8uDCcd-6MNwXF4W_7noWXFZAfHkxZsRGC9Xs"
	if !validChallenge(token, token+"."+thumb) {
		t.Error("RFC 8555's example refused")
	}
	for _, c := range [][2]string{
		{token, token + "." + thumb[:42]},
		{token, "other." + thumb},
		{token, token + "." + thumb + "x"},
		{"short", "short." + thumb},
		{token + "\"", token + "\"." + thumb},
		{token, token + "." + strings.Replace(thumb, "N", "+", 1)},
		{"", "." + thumb},
	} {
		if validChallenge(c[0], c[1]) {
			t.Errorf("accepted %q %q", c[0], c[1])
		}
	}
}

func TestInfoWithAndWithoutInboundDomain(t *testing.T) {
	plain := startRelay(t, nil).info(t)
	if _, ok := plain["inbound"]; ok {
		t.Errorf("inbound announced without an inbound domain: %v", plain)
	}
	with := startRelay(t, inboundDomain).info(t)
	if got, _ := with["inbound"].(map[string]any); got["domain"] != testInboundDomain || len(got) != 1 {
		t.Errorf("inbound: %v", with["inbound"])
	}
	// The rest is as before: old apps read the same document.
	for _, key := range []string{"name", "versions", "quic", "websocket", "limits", "push"} {
		if _, ok := with[key]; !ok {
			t.Errorf("%s missing", key)
		}
	}
}

func TestInboundDomainRefusesHomeMode(t *testing.T) {
	srv, err := New(Config{
		HTTPAddr: "127.0.0.1:0", QUICAddr: "127.0.0.1:0", InboundAddr: "127.0.0.1:0", DataDir: t.TempDir(),
		HomeInbound: true, InboundDomain: testInboundDomain, Logger: quiet,
	})
	if err == nil {
		srv.closeListeners()
		t.Fatal("home mode accepted with an inbound domain")
	}
	srv, err = New(Config{
		HTTPAddr: "127.0.0.1:0", QUICAddr: "127.0.0.1:0", DataDir: t.TempDir(), InboundDomain: "nodot", Logger: quiet,
	})
	if err == nil {
		srv.closeListeners()
		t.Fatal("a bad inbound domain accepted")
	}
}

func TestInboundDomainOffByDefault(t *testing.T) {
	r := startRelay(t, nil)
	if r.srv.inboundLn != nil {
		t.Fatal("inbound listener without an inbound domain")
	}
	mac := newHomeMac(t, r)
	c := dial(t, r, viaWS)
	mac.helloInbound(c)
	c.expectError(codeInboundOff)
	if status := getChallenge(t, r, inboundName(mac.pub())+"."+testInboundDomain, "token"); status != 404 {
		t.Errorf("challenge route without an inbound domain: %d", status)
	}
}

// passthroughMac is a Mac registered for deliveries on a relay with an
// inbound domain, which holds a certificate for its name.
type passthroughMac struct {
	*homeMac
	host string
	cert tls.Certificate
	pool *x509.CertPool
}

func newPassthroughMac(t *testing.T, r *testRelay, kind string) *passthroughMac {
	t.Helper()
	m := &passthroughMac{homeMac: newHomeMac(t, r)}
	m.registerInbound(kind)
	m.host = m.name + "." + testInboundDomain
	m.cert, m.pool = selfSigned(t, m.host)
	return m
}

func selfSigned(t *testing.T, host string) (tls.Certificate, *x509.CertPool) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		DNSNames:     []string{host},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	leaf, _ := x509.ParseCertificate(der)
	pool := x509.NewCertPool()
	pool.AddCert(leaf)
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key, Leaf: leaf}, pool
}

// tubeConn is a Mac's piping tube connection as a net.Conn, for a TLS
// server on the Mac's side; it also keeps what came through the relay.
type tubeConn struct {
	net.Conn // nil: only Read, Write and Close are used
	c        *client
	seen     bytes.Buffer
}

func (tc *tubeConn) Read(p []byte) (int, error) {
	n, err := tubeReader{tc.c}.Read(p)
	tc.seen.Write(p[:n])
	return n, err
}

func (tc *tubeConn) Write(p []byte) (int, error) {
	var err error
	if tc.c.kind == viaQUIC {
		_, err = tc.c.st.Write(p)
	} else {
		err = tc.c.ws.WriteMessage(websocket.BinaryMessage, append([]byte{recordBytes}, p...))
	}
	if err != nil {
		return 0, err
	}
	return len(p), nil
}

// Close ends the tube as the Mac does: after what it wrote.
func (tc *tubeConn) Close() error                     { tc.c.closeGracefully(); return nil }
func (tc *tubeConn) SetDeadline(time.Time) error      { return nil }
func (tc *tubeConn) SetReadDeadline(time.Time) error  { return nil }
func (tc *tubeConn) SetWriteDeadline(time.Time) error { return nil }
func (tc *tubeConn) LocalAddr() net.Addr              { return &net.TCPAddr{} }
func (tc *tubeConn) RemoteAddr() net.Addr             { return &net.TCPAddr{} }

// dialInbound connects to the relay's inbound listener as the proxy does,
// with the PROXY header for a caller at from.
func dialInbound(t *testing.T, r *testRelay, from string) net.Conn {
	t.Helper()
	c, err := net.DialTimeout("tcp", r.srv.inboundLn.Addr().String(), waitFor)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	_ = c.SetDeadline(time.Now().Add(2 * waitFor))
	if from != "" {
		if _, err := c.Write(proxyV2(netip.MustParseAddr(from), 51000)); err != nil {
			t.Fatal(err)
		}
	}
	return c
}

// serveTLS is the Mac's side of a passthrough tube: a TLS server with the
// Mac's certificate, answering one HTTP request.
func (m *passthroughMac) serveTLS(tube *client, answer string) (*tubeConn, <-chan string) {
	tc := &tubeConn{c: tube}
	got := make(chan string, 1)
	go func() {
		srv := tls.Server(tc, &tls.Config{Certificates: []tls.Certificate{m.cert}, MinVersion: tls.VersionTLS12})
		req, err := http.ReadRequest(bufio.NewReader(srv))
		if err != nil {
			got <- "error: " + err.Error()
			return
		}
		body, _ := io.ReadAll(req.Body)
		got <- req.Method + " " + req.URL.Path + " " + string(body)
		_, _ = io.WriteString(srv, answer)
		_ = srv.Close()
	}()
	return tc, got
}

func TestPassthroughRoundTrip(t *testing.T) {
	r := startRelay(t, inboundDomain)
	const secret = "/in/" + testSecret
	for _, ctrlKind := range transports {
		for _, tubeKind := range transports {
			t.Run("control="+ctrlKind+"/tube="+tubeKind, func(t *testing.T) {
				mac := newPassthroughMac(t, r, ctrlKind)
				raw := dialInbound(t, r, "203.0.113.7")
				client := tls.Client(raw, &tls.Config{ServerName: mac.host, RootCAs: mac.pool})
				errc := make(chan error, 1)
				go func() { errc <- client.Handshake() }()

				tube, from := mac.nextInbound()
				if from != "203.0.113.7" {
					t.Errorf("from %q, want the address in the PROXY header", from)
				}
				macTube := mac.accept(tubeKind, tube)
				macTube.pipe()
				tc, got := mac.serveTLS(macTube, queued)
				if err := <-errc; err != nil {
					t.Fatalf("handshake through the relay: %v", err)
				}
				text := "Quelqu’un a sonné à la porte."
				if _, err := io.WriteString(client, "POST "+secret+" HTTP/1.1\r\nHost: "+mac.host+
					"\r\nContent-Length: "+itoa(len(text))+"\r\n\r\n"+text); err != nil {
					t.Fatal(err)
				}
				if g := <-got; g != "POST "+secret+" "+text {
					t.Errorf("the Mac read %q", g)
				}
				resp, err := http.ReadResponse(bufio.NewReader(client), nil)
				if err != nil {
					t.Fatal(err)
				}
				body, _ := io.ReadAll(resp.Body)
				if resp.StatusCode != 202 || string(body) != `{"status":"queued"}` {
					t.Errorf("the caller got %d %q", resp.StatusCode, body)
				}
				// What went through the relay is TLS from its first byte, the
				// ClientHello read to sort it included, and holds neither the
				// secret nor the text.
				seen := tc.seen.Bytes()
				if len(seen) < 5 || seen[0] != 0x16 {
					t.Errorf("the tube starts with %x, want a TLS handshake record", seen[:min(len(seen), 5)])
				}
				for _, clear := range []string{testSecret, "sonné", "POST"} {
					if bytes.Contains(seen, []byte(clear)) {
						t.Errorf("%q passed through the relay in clear", clear)
					}
				}
				_ = client.Close()
				if !macTube.waitClosed(waitFor) {
					t.Error("the tube stayed open after the caller left")
				}
			})
		}
	}
	r.stop()
	logs := r.logs.String()
	for _, secret := range []string{testSecret, "203.0.113.7", testInboundDomain} {
		if strings.Contains(logs, secret) && secret != testInboundDomain {
			t.Errorf("the logs contain %q", secret)
		}
	}
	if !strings.Contains(logs, "msg=passthrough ") {
		t.Errorf("no passthrough line in the logs:\n%s", logs)
	}
}

func itoa(n int) string { return big.NewInt(int64(n)).String() }

// closedWithoutAnswer checks that the relay closes a connection without
// sending anything: it holds no certificate for these names.
func closedWithoutAnswer(t *testing.T, c net.Conn) {
	t.Helper()
	_ = c.SetReadDeadline(time.Now().Add(waitFor))
	b := make([]byte, 1)
	n, err := c.Read(b)
	if n != 0 || err == nil || isTimeout(err) {
		t.Errorf("got %d bytes, %v: want the connection closed", n, err)
	}
}

func clientHello(t *testing.T, c net.Conn, serverName string) {
	t.Helper()
	go func() {
		_ = tls.Client(c, &tls.Config{ServerName: serverName, InsecureSkipVerify: true}).Handshake()
	}()
}

func TestPassthroughRefusals(t *testing.T) {
	r := startRelay(t, inboundDomain)
	mac := newPassthroughMac(t, r, viaQUIC)
	unknown := inboundName(newHomeMac(t, r).pub()) // a name nobody registered
	for _, c := range []struct{ name, sni string }{
		{"unknown name", unknown + "." + testInboundDomain},
		{"outside the domain", mac.name + ".example.test"},
		{"the domain itself", testInboundDomain},
		{"no server name", ""},
	} {
		t.Run(c.name, func(t *testing.T) {
			conn := dialInbound(t, r, "203.0.113.7")
			clientHello(t, conn, c.sni)
			closedWithoutAnswer(t, conn)
		})
	}
	t.Run("no PROXY header", func(t *testing.T) {
		conn := dialInbound(t, r, "")
		clientHello(t, conn, mac.host)
		closedWithoutAnswer(t, conn)
	})
	t.Run("not TLS", func(t *testing.T) {
		conn := dialInbound(t, r, "203.0.113.7")
		_, _ = io.WriteString(conn, "GET /in/"+testSecret+" HTTP/1.1\r\nHost: "+mac.host+"\r\n\r\n")
		closedWithoutAnswer(t, conn)
	})
	mac.noInbound() // none of them reached the Mac
	counts := r.srv.stats.take()
	for _, reason := range []string{"passthrough_unknown_name", "passthrough_no_proxy_header", "passthrough_no_client_hello"} {
		if counts[reason] == 0 {
			t.Errorf("%s not counted: %v", reason, counts)
		}
	}
}

func TestPassthroughMacNotConnected(t *testing.T) {
	r := startRelay(t, inboundDomain)
	mac := newPassthroughMac(t, r, viaWS)
	mac.inbound.close()
	waitUntil(t, func() bool { return !r.srv.hub.inboundRegistered(mac.name) })
	conn := dialInbound(t, r, "203.0.113.7")
	clientHello(t, conn, mac.host)
	closedWithoutAnswer(t, conn)
	if n := r.srv.stats.take()["passthrough_mac_offline"]; n != 1 {
		t.Errorf("mac_offline counted %d times", n)
	}
	if _, _, pending := r.srv.hub.counts(); pending != 0 {
		t.Errorf("%d tubes kept waiting", pending)
	}
	// Nothing was kept: the Mac, back, gets no late delivery.
	mac.registerInbound(viaQUIC)
	mac.noInbound()
}

func TestPassthroughNotAccepted(t *testing.T) {
	r := startRelay(t, func(c *Config) {
		inboundDomain(c)
		c.Limits.PassthroughTimeout = 500 * time.Millisecond
	})
	mac := newPassthroughMac(t, r, viaQUIC)
	conn := dialInbound(t, r, "203.0.113.7")
	clientHello(t, conn, mac.host)
	mac.nextInbound() // and never accepted
	start := time.Now()
	closedWithoutAnswer(t, conn)
	if d := time.Since(start); d > 2*time.Second {
		t.Errorf("closed after %v", d)
	}
	waitUntil(t, func() bool { _, _, pending := r.srv.hub.counts(); return pending == 0 })
}

func TestPassthroughLimitsPerIP(t *testing.T) {
	r := startRelay(t, func(c *Config) {
		inboundDomain(c)
		c.Limits.PassthroughPerIP = 3
	})
	mac := newPassthroughMac(t, r, viaQUIC)
	for range 3 {
		conn := dialInbound(t, r, "203.0.113.7")
		clientHello(t, conn, "x."+testInboundDomain)
		closedWithoutAnswer(t, conn)
	}
	conn := dialInbound(t, r, "203.0.113.7")
	clientHello(t, conn, mac.host)
	closedWithoutAnswer(t, conn)
	mac.noInbound()
	if n := r.srv.stats.take()["passthrough_rate_limited"]; n != 1 {
		t.Errorf("rate_limited counted %d times", n)
	}
	// Another caller still gets through.
	conn = dialInbound(t, r, "203.0.113.8")
	clientHello(t, conn, mac.host)
	if _, from := mac.nextInbound(); from != "203.0.113.8" {
		t.Errorf("from %q", from)
	}
}

func TestPassthroughLimitsPerName(t *testing.T) {
	// At once: the third connection waiting for the Mac is refused.
	r := startRelay(t, func(c *Config) {
		inboundDomain(c)
		c.Limits.InboundAtOnce = 2
	})
	mac := newPassthroughMac(t, r, viaWS)
	for i := range 2 {
		conn := dialInbound(t, r, "203.0.113."+itoa(10+i))
		clientHello(t, conn, mac.host)
		mac.nextInbound() // left waiting
	}
	conn := dialInbound(t, r, "203.0.113.20")
	clientHello(t, conn, mac.host)
	closedWithoutAnswer(t, conn)
	mac.noInbound()
	if n := r.srv.stats.take()["passthrough_name_rate_limited"]; n != 1 {
		t.Errorf("name_rate_limited counted %d times", n)
	}

	// Per minute: the fourth in the minute is refused.
	r = startRelay(t, func(c *Config) {
		inboundDomain(c)
		c.Limits.InboundPerMinute = 3
	})
	mac = newPassthroughMac(t, r, viaQUIC)
	for i := range 3 {
		conn := dialInbound(t, r, "203.0.113."+itoa(30+i))
		clientHello(t, conn, mac.host)
		mac.nextInbound()
	}
	conn = dialInbound(t, r, "203.0.113.40")
	clientHello(t, conn, mac.host)
	closedWithoutAnswer(t, conn)
	mac.noInbound()
}

func TestPassthroughBytesAndTime(t *testing.T) {
	r := startRelay(t, func(c *Config) {
		inboundDomain(c)
		c.Limits.PassthroughBytes = 64 << 10
		c.Limits.PassthroughTimeout = 1500 * time.Millisecond
	})
	mac := newPassthroughMac(t, r, viaQUIC)

	// Bytes: the caller sends more than allowed after its ClientHello.
	conn := dialInbound(t, r, "203.0.113.7")
	clientHello(t, conn, mac.host)
	tube, _ := mac.nextInbound()
	macTube := mac.accept(viaQUIC, tube)
	macTube.pipe()
	go func() {
		chunk := bytes.Repeat([]byte{0x17}, 16<<10)
		for range 8 {
			if _, err := conn.Write(chunk); err != nil {
				return
			}
		}
	}()
	if !macTube.waitClosed(waitFor) {
		t.Error("the tube stayed open past the bytes allowed")
	}
	macTube.mu.Lock()
	got := len(macTube.buf)
	macTube.mu.Unlock()
	if got > 64<<10 {
		t.Errorf("%d bytes passed", got)
	}

	// Time: a connection that stays open is cut at the deadline.
	conn = dialInbound(t, r, "203.0.113.8")
	start := time.Now()
	clientHello(t, conn, mac.host)
	tube, _ = mac.nextInbound()
	macTube = mac.accept(viaWS, tube)
	macTube.pipe()
	if !macTube.waitClosed(waitFor) {
		t.Fatal("the tube stayed open past the deadline")
	}
	if d := time.Since(start); d < time.Second || d > 3*time.Second {
		t.Errorf("closed after %v, want about 1.5 s", d)
	}
}

func getChallenge(t *testing.T, r *testRelay, host, token string) int {
	t.Helper()
	status, _ := fetchChallenge(t, r, host, token)
	return status
}

func fetchChallenge(t *testing.T, r *testRelay, host, token string) (int, string) {
	t.Helper()
	req, _ := http.NewRequest("GET", r.httpURL+challengePrefix+token, nil)
	req.Host = host
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b)
}

func TestChallengeDeposit(t *testing.T) {
	r := startRelay(t, inboundDomain)
	token := "evaGxfADs6pSRb2LAv9IZf17Dt3juxGJ-PCt92wr-oA"
	keyAuth := token + ".NzbLsXh8uDCcd-6MNwXF4W_7noWXFZAfHkxZsRGC9Xs"
	for _, kind := range transports {
		mac := newPassthroughMac(t, r, kind)
		mac.inbound.send(map[string]any{"op": "acme_challenge", "token": token, "key_authorization": keyAuth})
		if got := mac.inbound.expect("acme_challenge_stored"); got["token"] != token {
			t.Errorf("%s: %v", kind, got)
		}
		status, body := fetchChallenge(t, r, strings.ToUpper(mac.host)+":80", token)
		if status != 200 || body != keyAuth {
			t.Errorf("%s: %d %q", kind, status, body)
		}
		other := inboundName(newHomeMac(t, r).pub()) + "." + testInboundDomain
		for _, c := range []struct{ host, token string }{
			{other, token},          // another Mac's name
			{mac.host, token + "x"}, // another token
			{mac.host, ""},
		} {
			if status := getChallenge(t, r, c.host, c.token); status != 404 {
				t.Errorf("%s %q: %d", c.host, c.token, status)
			}
		}
		// Other paths of these names lead nowhere.
		req, _ := http.NewRequest("GET", r.httpURL+"/v1/info", nil)
		req.Host = mac.host
		if resp, err := http.DefaultClient.Do(req); err != nil || resp.StatusCode != 404 {
			t.Errorf("/v1/info for an inbound name: %v %v", resp.StatusCode, err)
		}
		// The control connection carries on.
		mac.noInbound()
	}
	// The relay's own name still gets /v1/info.
	if doc := startRelay(t, inboundDomain).info(t); doc["name"] != "OpenMaé relay" {
		t.Errorf("info: %v", doc)
	}
}

func TestChallengeDepositRefused(t *testing.T) {
	token := "evaGxfADs6pSRb2LAv9IZf17Dt3juxGJ-PCt92wr-oA"
	keyAuth := token + ".NzbLsXh8uDCcd-6MNwXF4W_7noWXFZAfHkxZsRGC9Xs"
	r := startRelay(t, inboundDomain)
	// On an ordinary registration: the name is the inbound registration's.
	mac := newMac(t, r)
	c := mac.register(viaQUIC)
	c.send(map[string]any{"op": "acme_challenge", "token": token, "key_authorization": keyAuth})
	c.expectError(codeBadRequest)
	// Malformed.
	pm := newPassthroughMac(t, r, viaWS)
	pm.inbound.send(map[string]any{"op": "acme_challenge", "token": token, "key_authorization": "x"})
	pm.inbound.expectError(codeBadRequest)
	// In home mode, there is nothing to leave it for.
	home := startRelay(t, homeMode)
	hm := newHomeMac(t, home)
	hm.registerInbound(viaQUIC)
	hm.inbound.send(map[string]any{"op": "acme_challenge", "token": token, "key_authorization": keyAuth})
	hm.inbound.expectError(codeBadRequest)
}

func TestOldMacsAndPhonesWithInboundDomain(t *testing.T) {
	r := startRelay(t, inboundDomain)
	for _, kind := range transports {
		mac := newMac(t, r)
		ctrl := mac.register(kind)
		phone, macTube := mac.openTube(viaQUIC, viaWS)
		phone.write([]byte("hello"))
		if string(macTube.read(5)) != "hello" {
			t.Error("tube failed")
		}
		macTube.write([]byte("back"))
		if string(phone.read(4)) != "back" {
			t.Error("tube failed back")
		}
		datagramPasses(t, phone, macTube, []byte("sound"))
		ctrl.send(map[string]any{"op": "ping"})
		ctrl.expect("pong")
	}
	connect(t, r, viaWS, newMac(t, r).id).expectError(codeMacOffline)
}

func TestStandaloneModeSortsServerNames(t *testing.T) {
	r := startRelay(t, func(c *Config) {
		c.TLSDomain = "relay.example.test"
		c.HTTPSAddr = "127.0.0.1:0"
		c.InboundDomain = testInboundDomain
	})
	if r.srv.inboundLn != nil {
		t.Error("an inbound listener in standalone mode")
	}
	mac := newPassthroughMac(t, r, viaQUIC)
	httpsAddr := r.srv.httpsLn.Addr().String()

	// A name under the inbound domain goes to its Mac, unopened.
	raw, err := net.DialTimeout("tcp", httpsAddr, waitFor)
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()
	client := tls.Client(raw, &tls.Config{ServerName: mac.host, RootCAs: mac.pool})
	errc := make(chan error, 1)
	go func() { errc <- client.Handshake() }()
	tube, from := mac.nextInbound()
	if from != "127.0.0.1" {
		t.Errorf("from %q", from)
	}
	macTube := mac.accept(viaQUIC, tube) // WebSocket is over HTTPS only, in standalone mode
	macTube.pipe()
	_, got := mac.serveTLS(macTube, queued)
	if err := <-errc; err != nil {
		t.Fatalf("handshake: %v", err)
	}
	_, _ = io.WriteString(client, "GET /in/x HTTP/1.1\r\nHost: "+mac.host+"\r\n\r\n")
	if g := <-got; g != "GET /in/x " {
		t.Errorf("the Mac read %q", g)
	}

	// Another name gets the relay's own HTTPS, which answers with TLS (here
	// an alert: it has no certificate for that name and asks nobody).
	raw2, err := net.DialTimeout("tcp", httpsAddr, waitFor)
	if err != nil {
		t.Fatal(err)
	}
	defer raw2.Close()
	_ = raw2.SetDeadline(time.Now().Add(waitFor))
	err = tls.Client(raw2, &tls.Config{ServerName: "other.example.test", InsecureSkipVerify: true}).Handshake()
	if err == nil || !strings.Contains(err.Error(), "remote error: tls") {
		t.Errorf("the relay's own HTTPS did not answer: %v", err)
	}
	mac.noInbound()

	// Plain HTTP answers the inbound names' challenges, and redirects the
	// rest as before.
	token := "evaGxfADs6pSRb2LAv9IZf17Dt3juxGJ-PCt92wr-oA"
	keyAuth := token + ".NzbLsXh8uDCcd-6MNwXF4W_7noWXFZAfHkxZsRGC9Xs"
	mac.inbound.send(map[string]any{"op": "acme_challenge", "token": token, "key_authorization": keyAuth})
	mac.inbound.expect("acme_challenge_stored")
	if status, body := fetchChallenge(t, r, mac.host, token); status != 200 || body != keyAuth {
		t.Errorf("challenge: %d %q", status, body)
	}
	noRedirect := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := noRedirect.Get(r.httpURL + "/v1/info")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 301 {
		t.Errorf("/v1/info over HTTP: %d", resp.StatusCode)
	}
}
