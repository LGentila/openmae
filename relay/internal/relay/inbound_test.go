package relay

import (
	"bufio"
	"bytes"
	"crypto/ed25519"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"
)

// Home mode: deliveries from systems on the local network to a Mac.

const (
	testSecret = "dGhlLXNlY3JldC1vZi1hLXNvdXJjZS1mb3ItdGVzdHM" // like a source's: 43 base64url characters
	queued     = "HTTP/1.1 202 Accepted\r\nContent-Type: application/json\r\nContent-Length: 19\r\n\r\n" +
		`{"status":"queued"}`
)

func homeMode(c *Config) { c.HomeInbound = true }

func TestInboundName(t *testing.T) {
	pub := make(ed25519.PublicKey, ed25519.PublicKeySize)
	for i := range pub {
		pub[i] = byte(i)
	}
	// The same vector is in the Mac's tests.
	if got, want := inboundName(pub), "4zvomamapw57cf63xyx4cjb3qe"; got != want {
		t.Errorf("inboundName = %q, want %q", got, want)
	}
	if got, want := deviceID(pub), "mmg42klgyqzwneiskrelxms3j4"; got != want {
		t.Errorf("deviceID = %q, want %q", got, want)
	}
	if !validDeviceID(inboundName(pub)) {
		t.Error("an inbound name does not have the form of a device id")
	}
}

func TestIsLocalAddr(t *testing.T) {
	for s, want := range map[string]bool{
		"10.1.2.3":            true,
		"172.16.0.1":          true,
		"172.31.255.255":      true,
		"192.168.1.20":        true,
		"169.254.10.1":        true,
		"127.0.0.1":           true,
		"127.8.9.10":          true,
		"fc00::1":             true,
		"fd12:3456::1":        true,
		"fe80::1":             true,
		"fe80::1%en0":         true,
		"::1":                 true,
		"::ffff:192.168.1.20": true,
		"172.32.0.1":          false,
		"192.169.0.1":         false,
		"100.64.0.1":          false, // shared address space (carrier NAT, Tailscale)
		"8.8.8.8":             false,
		"203.0.113.9":         false,
		"0.0.0.0":             false,
		"::":                  false,
		"::ffff:8.8.8.8":      false,
		"2001:db8::1":         false,
		"fec0::1":             false,
	} {
		if got := isLocalAddr(netip.MustParseAddr(s)); got != want {
			t.Errorf("isLocalAddr(%s) = %v", s, got)
		}
	}
	if isLocalAddr(netip.Addr{}) {
		t.Error("an unknown address is local")
	}
}

func TestInboundMessages(t *testing.T) {
	var tok token
	for i := range tok {
		tok[i] = byte(i)
	}
	for _, c := range []struct{ got, want string }{
		{string(registeredInboundMessage("4zvomamapw57cf63xyx4cjb3qe")), `{"op":"registered","inbound":"4zvomamapw57cf63xyx4cjb3qe"}`},
		{string(inboundMessage(tok, netip.MustParseAddr("192.168.1.20"))), `{"op":"inbound","tube":"AAECAwQFBgcICQoLDA0ODw","from":"192.168.1.20"}`},
		{string(inboundMessage(tok, netip.MustParseAddr("fe80::1%en0"))), `{"op":"inbound","tube":"AAECAwQFBgcICQoLDA0ODw","from":"fe80::1"}`},
		{string(inboundMessage(tok, netip.MustParseAddr("::ffff:10.0.0.7"))), `{"op":"inbound","tube":"AAECAwQFBgcICQoLDA0ODw","from":"10.0.0.7"}`},
		{string(errorMessage(codeInboundOff)), `{"op":"error","code":"inbound_off"}`},
	} {
		if c.got != c.want {
			t.Errorf("got %s, want %s", c.got, c.want)
		}
	}
	m, err := parseMessage([]byte(`{"op":"hello","v":1,"inbound":true}`))
	if err != nil || !m.Inbound {
		t.Errorf("hello with inbound: %+v %v", m, err)
	}
	if m, err := parseMessage([]byte(`{"op":"hello","v":1}`)); err != nil || m.Inbound {
		t.Errorf("hello without inbound: %+v %v", m, err)
	}
}

func TestTubeRequest(t *testing.T) {
	read := func(raw string) (*http.Request, []byte) {
		t.Helper()
		req, err := http.ReadRequest(bufio.NewReader(strings.NewReader(raw)))
		if err != nil {
			t.Fatal(err)
		}
		body, err := io.ReadAll(req.Body)
		if err != nil {
			t.Fatal(err)
		}
		return req, body
	}
	req, body := read("POST /name/in/secret?text=Bonjour%20Ma%C3%A9&x HTTP/1.1\r\n" +
		"Host: relay.home:8080\r\n" +
		"Title: Porte\r\n" +
		"Connection: keep-alive, X-Hop\r\n" +
		"X-Hop: 1\r\n" +
		"Keep-Alive: timeout=5\r\n" +
		"Proxy-Connection: keep-alive\r\n" +
		"Proxy-Authorization: Basic eDp5\r\n" +
		"Te: trailers\r\n" +
		"Trailer: X-Checksum\r\n" +
		"Upgrade: websocket\r\n" +
		"Expect: 100-continue\r\n" +
		"Priority: 5\r\n" +
		"Transfer-Encoding: chunked\r\n" +
		"\r\n" +
		"5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n")
	want := "POST /name/in/secret?text=Bonjour%20Ma%C3%A9&x HTTP/1.1\r\n" +
		"Host: relay.home:8080\r\n" +
		"Priority: 5\r\n" +
		"Title: Porte\r\n" +
		"Content-Length: 11\r\n" +
		"Connection: close\r\n" +
		"\r\n" +
		"hello world"
	if got := string(tubeRequest(req, body)); got != want {
		t.Errorf("got\n%q\nwant\n%q", got, want)
	}

	// An absolute URI gives its path and query; the caller's length is
	// replaced by the body's.
	req, body = read("GET http://relay.home:8080/name/in/secret?text=hi HTTP/1.1\r\nHost: other\r\nContent-Length: 0\r\n\r\n")
	want = "GET /name/in/secret?text=hi HTTP/1.1\r\nHost: relay.home:8080\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
	if got := string(tubeRequest(req, body)); got != want {
		t.Errorf("got\n%q\nwant\n%q", got, want)
	}
}

func TestReadAnswer(t *testing.T) {
	big := strings.Repeat("x", maxAnswerBody)
	for _, c := range []struct {
		name, raw, method string
		status            int // 0: refused
		contentType, body string
	}{
		{"queued", queued, "POST", 202, "application/json", `{"status":"queued"}`},
		{"interim answers skipped", "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 103 Early Hints\r\n\r\n" + queued, "POST", 202, "application/json", `{"status":"queued"}`},
		{"chunked", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nok\r\n0\r\n\r\n", "POST", 200, "", "ok"},
		{"until the end", "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nok", "POST", 200, "text/plain", "ok"},
		{"HEAD", "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 18\r\n\r\n", "HEAD", 405, "", ""},
		{"HTTP/1.0", "HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nok", "POST", 200, "", "ok"},
		{"4 KB", "HTTP/1.1 200 OK\r\nContent-Length: 4096\r\n\r\n" + big, "POST", 200, "", big},
		{"over 4 KB", "HTTP/1.1 200 OK\r\nContent-Length: 4097\r\n\r\n" + big + "x", "POST", 0, "", ""},
		{"over 4 KB, until the end", "HTTP/1.1 200 OK\r\n\r\n" + big + "x", "POST", 0, "", ""},
		{"truncated", queued[:len(queued)-3], "POST", 0, "", ""},
		{"nothing", "", "POST", 0, "", ""},
		{"not HTTP", "nonsense\r\n\r\n", "POST", 0, "", ""},
		{"switching protocols", "HTTP/1.1 101 Switching Protocols\r\n\r\n", "POST", 0, "", ""},
		{"status 600", "HTTP/1.1 600 Odd\r\nContent-Length: 0\r\n\r\n", "POST", 0, "", ""},
		{"headers too large", "HTTP/1.1 200 OK\r\nX-Pad: " + strings.Repeat("p", maxAnswerHeader+maxAnswerBody) + "\r\nContent-Length: 0\r\n\r\n", "POST", 0, "", ""},
	} {
		ans, err := readAnswer(strings.NewReader(c.raw), c.method)
		switch {
		case c.status == 0 && err == nil:
			t.Errorf("%s: accepted %+v", c.name, ans)
		case c.status == 0:
		case err != nil:
			t.Errorf("%s: %v", c.name, err)
		case ans.status != c.status || ans.contentType != c.contentType || string(ans.body) != c.body:
			t.Errorf("%s: got %d %q %q", c.name, ans.status, ans.contentType, ans.body)
		}
	}
}

func TestDeliveriesLimits(t *testing.T) {
	clock := newClock()
	d := newDeliveries(30, 5, 3, clock.now)
	for i := range 5 {
		if !d.start("a") {
			t.Fatalf("delivery %d refused", i+1)
		}
	}
	if d.start("a") {
		t.Error("6th delivery at once allowed")
	}
	if !d.start("b") {
		t.Error("another name held back")
	}
	d.done("b")
	for range 5 {
		d.done("a")
	}
	// 30 a minute, over a sliding window: 5 at the start, then one a second.
	for i := 5; i < 30; i++ {
		clock.add(time.Second)
		if !d.start("a") {
			t.Fatalf("delivery %d refused", i+1)
		}
		d.done("a")
	}
	if d.start("a") {
		t.Error("31st delivery within a minute allowed")
	}
	clock.add(35 * time.Second) // a minute after the first five
	for i := range 5 {
		if !d.start("a") {
			t.Fatalf("delivery %d refused once the first ones left the window", i+1)
		}
		d.done("a")
	}
	if d.start("a") {
		t.Error("the 6th of the first second is still in the window")
	}

	// Bounded memory: past 3 names, new ones wait for the sweep, which keeps
	// names with deliveries in progress.
	d = newDeliveries(30, 5, 3, clock.now)
	for _, name := range []string{"a", "b", "c"} {
		if !d.start(name) {
			t.Fatalf("%s refused", name)
		}
	}
	d.done("a")
	d.done("b") // "c" is still in progress
	if d.start("d") {
		t.Error("a fourth name allowed past the bound")
	}
	clock.add(time.Minute)
	if !d.start("d") {
		t.Error("new name refused after the sweep")
	}
	if _, kept := d.names["c"]; !kept || len(d.names) != 2 {
		t.Errorf("after the sweep: %v", d.names)
	}
	d.done("c")
	d.done("d")
	d.done("unknown") // harmless
}

func TestHubInbound(t *testing.T) {
	h := newHub(1, 2)
	ordinary := &registration{id: "mac"}
	inbound := &registration{id: "name", inbound: true}
	if h.register(ordinary) != nil || h.register(inbound) != nil {
		t.Fatal("one kind of registration replaced the other")
	}
	if _, _, code := h.open("name"); code != codeMacOffline {
		t.Errorf("an iPhone reached an inbound registration: %q", code)
	}
	if _, _, code := h.openInbound("mac"); code != codeMacOffline {
		t.Errorf("a delivery reached an ordinary registration: %q", code)
	}
	if !h.inboundRegistered("name") || h.inboundRegistered("mac") {
		t.Error("inboundRegistered")
	}

	// A delivery counts as pending, not against the Mac's tubes.
	p, reg, code := h.openInbound("name")
	if code != "" || reg != inbound || !p.delivery {
		t.Fatalf("openInbound: %q", code)
	}
	if _, _, code := h.open("mac"); code != "" {
		t.Fatalf("the iPhone's tube: %q", code)
	}
	if _, _, code := h.openInbound("name"); code != codeBusy {
		t.Errorf("past the pending bound: %q", code)
	}
	if h.claim(p.token, nil) != p {
		t.Fatal("claim")
	}
	h.release(p)
	if tubesOf(h, "name") != 0 || tubesOf(h, "mac") != 1 {
		t.Errorf("tubes: %v", h.tubes)
	}

	// Replaced by its own kind only.
	again := &registration{id: "name", inbound: true}
	if h.register(again) != inbound {
		t.Error("inbound registration not replaced")
	}
	h.unregister(inbound) // the old connection closing must not remove the new one
	if !h.inboundRegistered("name") {
		t.Error("the new inbound registration was removed")
	}
	h.unregister(again)
	if macs, inb, _ := h.counts(); macs != 1 || inb != 0 {
		t.Errorf("counts: %d Macs, %d inbound", macs, inb)
	}
}

func TestHomeModeOffByDefault(t *testing.T) {
	r := startRelay(t, nil)
	mac := newHomeMac(t, r)
	unknown := await(t, sendRaw(r, "GET /v1/nope HTTP/1.1\r\nHost: relay\r\n\r\n"))
	if unknown.status != 404 {
		t.Fatalf("unknown path: %+v", unknown)
	}
	for _, method := range []string{"GET", "POST", "PUT"} {
		got := await(t, sendRaw(r, method+" /"+inboundName(mac.pub())+"/in/"+testSecret+" HTTP/1.1\r\n"+
			"Host: relay\r\nContent-Length: 2\r\n\r\nhi"))
		if got != unknown {
			t.Errorf("%s a delivery: %+v, want what an unknown path gets", method, got)
		}
	}
	for _, kind := range transports {
		c := dial(t, r, kind)
		mac.helloInbound(c)
		c.expectError(codeInboundOff)
	}
	// "inbound": false is an ordinary hello, and ordinary registrations work.
	c := dial(t, r, viaQUIC)
	c.send(map[string]any{
		"op": "hello", "v": 1, "role": "mac", "id": mac.id,
		"key": b64url.EncodeToString(mac.pub()), "inbound": false,
	})
	c.expect("challenge")
	mac.register(viaWS)
	phone, macTube := mac.openTube(viaQUIC, viaWS)
	phone.write([]byte("hi"))
	if string(macTube.read(2)) != "hi" {
		t.Error("tube failed")
	}
}

func TestHomeModeRefusesStandaloneMode(t *testing.T) {
	srv, err := New(Config{
		HTTPAddr:    "127.0.0.1:0",
		QUICAddr:    "127.0.0.1:0",
		HTTPSAddr:   "127.0.0.1:0",
		DataDir:     t.TempDir(),
		TLSDomain:   "relay.example.test",
		HomeInbound: true,
		Logger:      quiet,
	})
	if err == nil {
		srv.closeListeners()
		t.Fatal("home mode accepted with a public domain")
	}
}

func TestDeliveryRoundTrip(t *testing.T) {
	r := startRelay(t, homeMode)
	for _, ctrlKind := range transports {
		for _, tubeKind := range transports {
			t.Run("control="+ctrlKind+"/tube="+tubeKind, func(t *testing.T) {
				mac := newHomeMac(t, r)
				mac.registerInbound(ctrlKind)
				text := "Quelqu’un a sonné à la porte."
				target := "/" + mac.name + "/in/" + testSecret + "?source=ha&lang=fr"
				res := sendRaw(r, "POST "+target+" HTTP/1.1\r\n"+
					"Host: 192.168.1.10:8080\r\n"+
					"Title: Sonnette\r\n"+
					"Content-Type: text/plain; charset=utf-8\r\n"+
					"Connection: keep-alive, X-Hop\r\n"+
					"X-Hop: dropped\r\n"+
					"Keep-Alive: timeout=5\r\n"+
					"Content-Length: "+strconv.Itoa(len(text))+"\r\n"+
					"\r\n"+text)

				tube, from := mac.nextInbound()
				if from != "127.0.0.1" {
					t.Errorf("from %q", from)
				}
				macTube := mac.accept(tubeKind, tube)
				macTube.pipe()
				want := "POST " + target + " HTTP/1.1\r\n" +
					"Host: 192.168.1.10:8080\r\n" +
					"Content-Type: text/plain; charset=utf-8\r\n" +
					"Title: Sonnette\r\n" +
					"Content-Length: " + strconv.Itoa(len(text)) + "\r\n" +
					"Connection: close\r\n" +
					"\r\n" + text
				got := macTube.read(len(want))
				if string(got) != want {
					t.Errorf("in the tube:\n%q\nwant\n%q", got, want)
				}
				req, err := http.ReadRequest(bufio.NewReader(bytes.NewReader(got)))
				if err != nil {
					t.Fatal(err)
				}
				body, _ := io.ReadAll(req.Body)
				if req.Method != "POST" || req.URL.Path != "/"+mac.name+"/in/"+testSecret ||
					req.URL.Query().Get("source") != "ha" || req.Header.Get("Title") != "Sonnette" ||
					string(body) != text || !req.Close {
					t.Errorf("the Mac read %s %s %v %q", req.Method, req.URL, req.Header, body)
				}

				// Datagrams have no place in such a tube: dropped, and the
				// answer still passes.
				if err := macTube.sendDatagram([]byte("dropped")); err != nil {
					t.Fatal(err)
				}
				macTube.write([]byte(queued))
				ans := await(t, res)
				if ans.status != 202 || ans.contentType != "application/json" || ans.body != `{"status":"queued"}` {
					t.Errorf("the caller got %+v", ans)
				}
				if !macTube.waitClosed(waitFor) {
					t.Error("the relay left the tube open after the answer")
				}
			})
		}
	}
}

func TestDeliveryAnswers(t *testing.T) {
	r := startRelay(t, homeMode)
	for _, kind := range transports {
		for _, c := range []struct {
			name, answer      string
			end               bool // the Mac closes its side after answering
			status            int
			contentType, body string
		}{
			{"interim answer first", "HTTP/1.1 100 Continue\r\n\r\n" + queued, false, 202, "application/json", `{"status":"queued"}`},
			{"chunked", "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nok\r\n0\r\n\r\n", false, 200, "text/plain", "ok"},
			{"until the end", "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nok", true, 200, "text/plain", "ok"},
			{"refused by the Mac", "HTTP/1.1 422 Unprocessable Entity\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 13\r\n\r\nno text field", false, 422, "text/plain; charset=utf-8", "no text field"},
			{"no content type", "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nnot found", false, 404, "", "not found"},
			{"4 KB", "HTTP/1.1 200 OK\r\nContent-Length: 4096\r\n\r\n" + strings.Repeat("x", 4096), false, 200, "", strings.Repeat("x", 4096)},
		} {
			t.Run(kind+"/"+c.name, func(t *testing.T) {
				mac := newHomeMac(t, r)
				mac.registerInbound(viaWS)
				res := post(r, mac.name, "hi")
				tube, _, _ := mac.acceptDelivery(kind)
				tube.write([]byte(c.answer))
				if c.end {
					tube.closeGracefully()
				}
				if got := await(t, res); got.status != c.status || got.contentType != c.contentType || got.body != c.body {
					t.Errorf("the caller got %+v", got)
				}
			})
		}
	}
}

func TestDeliveryWithoutAValidAnswer(t *testing.T) {
	r := startRelay(t, func(c *Config) {
		c.HomeInbound = true
		c.Limits.InboundTimeout = 500 * time.Millisecond
	})
	t.Run("not accepted", func(t *testing.T) {
		mac := newHomeMac(t, r)
		mac.registerInbound(viaQUIC)
		res := post(r, mac.name, "hi")
		tube, _ := mac.nextInbound()
		if got := await(t, res); got.status != 503 || got.body != "Mac not answering\n" {
			t.Errorf("the caller got %+v", got)
		}
		late := dial(t, r, viaWS)
		late.send(map[string]any{"op": "accept", "v": 1, "tube": tube})
		late.expectError(codeUnknownTube)
	})
	for _, kind := range transports {
		for _, c := range []struct {
			name   string
			answer func(*client)
		}{
			{"no answer", func(*client) {}},
			{"tube closed", func(c *client) { c.close() }},
			{"not HTTP", func(c *client) { c.write([]byte("nonsense\r\n\r\n")) }},
			{"truncated", func(c *client) {
				c.write([]byte(queued[:len(queued)-5]))
				c.closeGracefully()
			}},
			{"body over 4 KB", func(c *client) {
				c.write([]byte("HTTP/1.1 200 OK\r\nContent-Length: 4097\r\n\r\n" + strings.Repeat("x", 4097)))
			}},
		} {
			t.Run(kind+"/"+c.name, func(t *testing.T) {
				mac := newHomeMac(t, r)
				mac.registerInbound(viaQUIC)
				// Dialled beforehand, so that only the answer races the
				// short timeout, even on a busy machine.
				tube := dial(t, r, kind)
				res := post(r, mac.name, "hi")
				token, _ := mac.nextInbound()
				tube.send(map[string]any{"op": "accept", "v": 1, "tube": token})
				tube.expect("accepted")
				tube.pipe()
				readTubeRequest(t, tube)
				c.answer(tube)
				if got := await(t, res); got.status != 502 {
					t.Errorf("the caller got %+v", got)
				}
			})
		}
	}
}

func TestDeliveryFromBehindAProxy(t *testing.T) {
	r := startRelay(t, func(c *Config) {
		c.HomeInbound = true
		c.BehindProxy = true
	})
	mac := newHomeMac(t, r)
	mac.registerInbound(viaQUIC)
	deliver := func(forwardedFor string) <-chan result {
		return sendRaw(r, "POST /"+mac.name+"/in/"+testSecret+" HTTP/1.1\r\nHost: relay.home\r\n"+
			"X-Forwarded-For: "+forwardedFor+"\r\nContent-Length: 2\r\n\r\nhi")
	}
	for _, public := range []string{"203.0.113.9", "2001:db8::9", "192.168.1.20, 198.51.100.7", "100.64.0.1"} {
		if got := await(t, deliver(public)); got.status != 403 {
			t.Errorf("from %s: %+v", public, got)
		}
	}
	mac.noInbound()
	for forwardedFor, want := range map[string]string{
		"192.168.1.20":           "192.168.1.20",
		"198.51.100.7, 10.0.0.7": "10.0.0.7",
		"fe80::1":                "fe80::1",
		"[fd00::5]:5555":         "fd00::5",
		"::ffff:172.16.5.4":      "172.16.5.4",
	} {
		res := deliver(forwardedFor)
		tube, from := mac.nextInbound()
		if from != want {
			t.Errorf("X-Forwarded-For %s: from %q, want %q", forwardedFor, from, want)
		}
		c := mac.accept(viaWS, tube)
		c.pipe()
		readTubeRequest(t, c)
		c.write([]byte(queued))
		if got := await(t, res); got.status != 202 {
			t.Errorf("X-Forwarded-For %s: %+v", forwardedFor, got)
		}
	}
}

func TestDeliveryMacNotConnected(t *testing.T) {
	r := startRelay(t, homeMode)
	mac := newHomeMac(t, r)
	name := inboundName(mac.pub())
	notConnected := func(when string) {
		t.Helper()
		if got := await(t, post(r, name, "hi")); got.status != 503 || got.body != "Mac not connected\n" {
			t.Errorf("%s: %+v", when, got)
		}
	}
	notConnected("never registered")

	// An ordinary registration does not take deliveries.
	ctrl := mac.register(viaQUIC)
	notConnected("registered for iPhones only")
	ctrl.send(map[string]any{"op": "ping"})
	ctrl.expect("pong") // and got nothing before

	// Gone once its control connection for deliveries closes.
	mac.registerInbound(viaWS)
	mac.deliver(viaQUIC, "here")
	mac.inbound.close()
	waitUntil(t, func() bool { return !r.srv.hub.inboundRegistered(name) })
	notConnected("after the control connection closed")

	// What cannot be an inbound name: 404, as for an unknown path.
	for _, path := range []string{
		"/" + strings.ToUpper(name) + "/in/x",
		"/" + name[:25] + "/in/x",
		"/" + name + "1/in/x",
		"/" + name + "/in/",
		"/" + name + "/in/x/y",
		"/" + name + "/out/x",
	} {
		if got := await(t, sendRaw(r, "POST "+path+" HTTP/1.1\r\nHost: relay\r\nContent-Length: 2\r\n\r\nhi")); got.status != 404 ||
			got.body != "404 page not found\n" {
			t.Errorf("%s: %+v", path, got)
		}
	}
}

func TestInboundNameComesFromTheKey(t *testing.T) {
	r := startRelay(t, homeMode)
	a, b := newHomeMac(t, r), newHomeMac(t, r)
	a.registerInbound(viaQUIC)
	b.registerInbound(viaWS)
	if a.name == b.name || a.name == a.id {
		t.Fatal("inbound names not apart")
	}
	for _, kind := range transports {
		// B, showing A's key, cannot answer the challenge.
		c := dial(t, r, kind)
		a.helloInbound(c)
		nonce, _ := decodeFixed(c.expect("challenge")["nonce"].(string), 32)
		sig := ed25519.Sign(b.priv, append([]byte(registerContext), nonce...))
		c.send(map[string]any{"op": "register", "sig": b64url.EncodeToString(sig)})
		c.expectError(codeBadSignature)
		// Nor show A's id with its own key.
		c = dial(t, r, kind)
		c.send(map[string]any{
			"op": "hello", "v": 1, "role": "mac", "id": a.id,
			"key": b64url.EncodeToString(b.pub()), "inbound": true,
		})
		c.expectError(codeBadSignature)
	}
	// Each name leads to its own Mac.
	res := post(r, a.name, "for A")
	tube, _, body := a.acceptDelivery(viaWS)
	b.noInbound()
	if body != "for A" {
		t.Errorf("A got %q", body)
	}
	tube.write([]byte(queued))
	if got := await(t, res); got.status != 202 {
		t.Errorf("%+v", got)
	}
	b.deliver(viaQUIC, "for B")
	a.noInbound()
}

func TestInboundAndOrdinaryRegistrationsCoexist(t *testing.T) {
	r := startRelay(t, homeMode)
	mac := newHomeMac(t, r)
	ctrl := mac.register(viaQUIC)
	inbound := mac.registerInbound(viaWS)

	// iPhones still reach the Mac; its tubes for them do not hold deliveries
	// back.
	for range 3 {
		phone, macTube := mac.openTube(viaQUIC, viaWS)
		phone.write([]byte("hi"))
		if string(macTube.read(2)) != "hi" {
			t.Fatal("tube failed")
		}
	}
	connect(t, r, viaWS, mac.id).expectError(codeBusy)
	mac.deliver(viaQUIC, "with three iPhones")

	// A new inbound registration replaces the inbound one only.
	mac.registerInbound(viaQUIC)
	inbound.expectClosed()
	ctrl.send(map[string]any{"op": "ping"})
	ctrl.expect("pong")
	mac.deliver(viaWS, "on the new inbound registration")

	// A new ordinary registration replaces the ordinary one only.
	mac.register(viaWS)
	ctrl.expectClosed()
	mac.noInbound()
	mac.deliver(viaQUIC, "after the iPhones' registration changed")
}

func TestDeliveriesPerMinute(t *testing.T) {
	r := startRelay(t, homeMode)
	mac := newHomeMac(t, r)
	mac.registerInbound(viaQUIC)
	for i := range 30 {
		mac.deliver(transports[i%2], "delivery "+strconv.Itoa(i+1))
	}
	if got := await(t, post(r, mac.name, "31")); got.status != 429 {
		t.Errorf("31st delivery within a minute: %+v", got)
	}
	mac.noInbound()
	// Per inbound name: another one is not held back.
	if got := await(t, post(r, inboundName(newHomeMac(t, r).pub()), "hi")); got.status != 503 {
		t.Errorf("another name: %+v", got)
	}
}

func TestDeliveriesAtOnce(t *testing.T) {
	r := startRelay(t, homeMode)
	mac := newHomeMac(t, r)
	mac.registerInbound(viaWS)
	var results []<-chan result
	var tubes []*client
	for i := range 5 {
		results = append(results, post(r, mac.name, "delivery "+strconv.Itoa(i+1)))
		tube, _, _ := mac.acceptDelivery(transports[i%2])
		tubes = append(tubes, tube)
	}
	if got := await(t, post(r, mac.name, "one too many")); got.status != 429 {
		t.Errorf("6th delivery at once: %+v", got)
	}
	mac.noInbound()
	for i, tube := range tubes {
		tube.write([]byte(queued))
		if got := await(t, results[i]); got.status != 202 {
			t.Errorf("delivery %d: %+v", i+1, got)
		}
	}
	mac.deliver(viaQUIC, "once they are over")
}

func TestDeliveriesCountAsPendingTubes(t *testing.T) {
	r := startRelay(t, func(c *Config) {
		c.HomeInbound = true
		c.Limits.MaxPendingTubes = 1
	})
	mac := newHomeMac(t, r)
	mac.register(viaQUIC)
	mac.registerInbound(viaWS)
	connect(t, r, viaQUIC, mac.id)
	mac.incoming() // never accepted
	if got := await(t, post(r, mac.name, "hi")); got.status != 503 || got.body != "relay busy\n" {
		t.Errorf("past the pending bound: %+v", got)
	}
	mac.noInbound()
}

func TestDeliveryTooLarge(t *testing.T) {
	r := startRelay(t, homeMode)
	mac := newHomeMac(t, r)
	mac.registerInbound(viaWS)
	const limit = 64 << 10
	head := "POST /" + mac.name + "/in/" + testSecret + " HTTP/1.1\r\nHost: relay.home\r\n"

	// Announced too large: refused before the body comes.
	if got := await(t, sendRaw(r, head+"Content-Length: "+strconv.Itoa(limit+1)+"\r\n\r\n")); got.status != 413 {
		t.Errorf("announced too large: %+v", got)
	}
	// Chunked: found too large while reading.
	var b strings.Builder
	b.WriteString(head + "Transfer-Encoding: chunked\r\n\r\n")
	chunk := strings.Repeat("a", 4096)
	for range limit/len(chunk) + 1 {
		fmt.Fprintf(&b, "%x\r\n%s\r\n", len(chunk), chunk)
	}
	b.WriteString("0\r\n\r\n")
	if got := await(t, sendRaw(r, b.String())); got.status != 413 {
		t.Errorf("chunked too large: %+v", got)
	}
	mac.noInbound()

	// Exactly the limit passes.
	mac.deliver(viaQUIC, strings.Repeat("b", limit))
}

func TestDeliveryUnreadableBody(t *testing.T) {
	r := startRelay(t, homeMode)
	mac := newHomeMac(t, r)
	mac.registerInbound(viaQUIC)
	got := await(t, sendRaw(r, "POST /"+mac.name+"/in/"+testSecret+" HTTP/1.1\r\nHost: relay.home\r\n"+
		"Transfer-Encoding: chunked\r\n\r\nnot a chunk size\r\n"))
	if got.status != 400 || got.body != "unreadable delivery\n" {
		t.Errorf("broken chunked encoding: %+v", got)
	}
	mac.noInbound()
}

func TestDeliverySlowSender(t *testing.T) {
	r := startRelay(t, func(c *Config) {
		c.HomeInbound = true
		c.Limits.InboundTimeout = 300 * time.Millisecond
	})
	mac := newHomeMac(t, r)
	mac.registerInbound(viaWS)
	start := time.Now()
	got := await(t, sendRaw(r, "POST /"+mac.name+"/in/"+testSecret+" HTTP/1.1\r\nHost: relay.home\r\n"+
		"Content-Length: 10\r\n\r\nslow"))
	if got.status != 408 {
		t.Errorf("slow sender: %+v", got)
	}
	if d := time.Since(start); d < 250*time.Millisecond || d > 3*time.Second {
		t.Errorf("answered after %v", d)
	}
	mac.noInbound()
}

func TestDeliveryAtShutdown(t *testing.T) {
	r := startRelay(t, homeMode)
	mac := newHomeMac(t, r)
	mac.registerInbound(viaWS)
	res := post(r, mac.name, "hi")
	mac.nextInbound() // never accepted
	start := time.Now()
	r.stop()
	select {
	case got := <-res:
		if got.err == nil && got.status != 503 {
			t.Errorf("the caller got %+v", got)
		}
	case <-time.After(waitFor):
		t.Fatal("the caller got no answer")
	}
	if time.Since(start) > 3*time.Second {
		t.Errorf("shutdown took %v", time.Since(start))
	}
}

func TestDeliveryLogsHoldNoIdentifiers(t *testing.T) {
	r := startRelay(t, homeMode)
	mac := newHomeMac(t, r)
	mac.registerInbound(viaQUIC)
	res := sendRaw(r, "POST /"+mac.name+"/in/"+testSecret+"?code=4242 HTTP/1.1\r\nHost: relay.home\r\n"+
		"Title: Sonnette\r\nContent-Length: 13\r\n\r\nSecret phrase")
	tube, _ := mac.nextInbound()
	c := mac.accept(viaWS, tube)
	c.pipe()
	readTubeRequest(t, c)
	c.write([]byte(queued))
	await(t, res)
	await(t, post(r, inboundName(newHomeMac(t, r).pub()), "hi"))
	r.stop()

	logs := r.logs.String()
	for _, secret := range []string{mac.name, mac.id, testSecret, tube, "127.0.0.1", "Sonnette", "Secret phrase", "4242"} {
		if strings.Contains(logs, secret) {
			t.Errorf("the logs contain %q:\n%s", secret, logs)
		}
	}
	for _, event := range []string{"home_mode=true", "mac registered for deliveries", "msg=delivery status=202", `msg="delivery refused" status=503`} {
		if !strings.Contains(logs, event) {
			t.Errorf("the logs miss %q:\n%s", event, logs)
		}
	}
}

// homeMac is a fake Mac that also registers for deliveries.
type homeMac struct {
	*fakeMac
	inbound *client // its control connection for deliveries
	name    string  // the inbound name the relay gave it
}

func newHomeMac(t *testing.T, r *testRelay) *homeMac { return &homeMac{fakeMac: newMac(t, r)} }

func (m *homeMac) pub() ed25519.PublicKey { return m.priv.Public().(ed25519.PublicKey) }

func (m *homeMac) helloInbound(c *client) {
	m.t.Helper()
	c.send(map[string]any{
		"op": "hello", "v": 1, "role": "mac", "id": m.id,
		"key": b64url.EncodeToString(m.pub()), "inbound": true,
	})
}

// registerInbound opens a control connection for deliveries and registers
// on it.
func (m *homeMac) registerInbound(kind string) *client {
	m.t.Helper()
	c := dial(m.t, m.r, kind)
	m.helloInbound(c)
	nonce, ok := decodeFixed(c.expect("challenge")["nonce"].(string), 32)
	if !ok {
		m.t.Fatal("bad nonce")
	}
	sig := ed25519.Sign(m.priv, append([]byte(registerContext), nonce...))
	c.send(map[string]any{"op": "register", "sig": b64url.EncodeToString(sig)})
	reg := c.expect("registered")
	if want := inboundName(m.pub()); reg["inbound"] != want || len(reg) != 2 {
		m.t.Fatalf("got %v, want registered with the inbound name %s", reg, want)
	}
	m.inbound, m.name = c, reg["inbound"].(string)
	return c
}

// nextInbound waits for the relay's next inbound message.
func (m *homeMac) nextInbound() (tube, from string) {
	m.t.Helper()
	msg := m.inbound.expect("inbound")
	tube, _ = msg["tube"].(string)
	from, _ = msg["from"].(string)
	return tube, from
}

// noInbound checks that the relay sent no inbound message: it answers a ping
// first.
func (m *homeMac) noInbound() {
	m.t.Helper()
	m.inbound.send(map[string]any{"op": "ping"})
	m.inbound.expect("pong")
}

// acceptDelivery accepts the next delivery's tube and reads the request in
// it.
func (m *homeMac) acceptDelivery(kind string) (*client, *http.Request, string) {
	m.t.Helper()
	tube, _ := m.nextInbound()
	c := m.accept(kind, tube)
	c.pipe()
	req, body := readTubeRequest(m.t, c)
	return c, req, body
}

// deliver posts text to the Mac, plays the Mac's part over a tube
// connection of the given kind, and checks that the caller gets its answer.
func (m *homeMac) deliver(tubeKind, text string) {
	m.t.Helper()
	res := post(m.r, m.name, text)
	tube, _, body := m.acceptDelivery(tubeKind)
	if body != text {
		m.t.Errorf("the Mac got %d bytes, want %d", len(body), len(text))
	}
	tube.write([]byte(queued))
	if got := await(m.t, res); got.status != 202 || got.body != `{"status":"queued"}` {
		m.t.Errorf("the caller got %+v", got)
	}
}

// tubeReader reads a piping client's tube bytes as a stream.
type tubeReader struct{ c *client }

func (r tubeReader) Read(p []byte) (int, error) {
	deadline := time.After(waitFor)
	for {
		ended := false
		select {
		case <-r.c.closed: // checked first: what came before the end is in buf
			ended = true
		default:
		}
		r.c.mu.Lock()
		n := copy(p, r.c.buf)
		r.c.buf = r.c.buf[n:]
		r.c.mu.Unlock()
		switch {
		case n > 0:
			return n, nil
		case ended:
			return 0, io.EOF
		}
		select {
		case <-r.c.changed:
		case <-r.c.closed:
		case <-deadline:
			return 0, os.ErrDeadlineExceeded
		}
	}
}

// readTubeRequest reads the HTTP/1.1 request the relay wrote into a piping
// tube.
func readTubeRequest(t *testing.T, c *client) (*http.Request, string) {
	t.Helper()
	req, err := http.ReadRequest(bufio.NewReader(tubeReader{c}))
	if err != nil {
		t.Fatalf("%s: reading the delivery: %v", c.kind, err)
	}
	body, err := io.ReadAll(req.Body)
	if err != nil {
		t.Fatalf("%s: reading the delivery's body: %v", c.kind, err)
	}
	return req, string(body)
}

// result is what a caller got for a delivery.
type result struct {
	status      int
	contentType string
	body        string
	err         error
}

// sendRaw sends request, as it is, to the relay's HTTP listener, and gives
// the answer once it comes.
func sendRaw(r *testRelay, request string) <-chan result {
	ch := make(chan result, 1)
	go func() { ch <- roundTrip(r.srv.httpLn.Addr().String(), request) }()
	return ch
}

func roundTrip(addr, request string) result {
	c, err := net.DialTimeout("tcp", addr, waitFor)
	if err != nil {
		return result{err: err}
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(2 * waitFor))
	// Written while the answer is read: the relay may answer before reading
	// it all.
	go func() { _, _ = io.WriteString(c, request) }()
	resp, err := http.ReadResponse(bufio.NewReader(c), nil)
	if err != nil {
		return result{err: err}
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	return result{status: resp.StatusCode, contentType: resp.Header.Get("Content-Type"), body: string(b), err: err}
}

// post delivers text to an inbound name from the loopback, as a local
// system would.
func post(r *testRelay, name, text string) <-chan result {
	return sendRaw(r, "POST /"+name+"/in/"+testSecret+" HTTP/1.1\r\nHost: relay.home\r\n"+
		"Content-Type: text/plain\r\nContent-Length: "+strconv.Itoa(len(text))+"\r\n\r\n"+text)
}

func await(t *testing.T, ch <-chan result) result {
	t.Helper()
	select {
	case res := <-ch:
		if res.err != nil {
			t.Fatalf("delivery: %v", res.err)
		}
		return res
	case <-time.After(3 * waitFor):
		t.Fatal("no answer to the delivery")
	}
	return result{}
}
