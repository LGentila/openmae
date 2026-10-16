package relay

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/quic-go/quic-go"
)

func TestInfoAndHealth(t *testing.T) {
	r := startRelay(t, func(c *Config) { c.Limits = Limits{} }) // the protocol's limits
	port := portOf(r.srv.udp.LocalAddr())
	want := `{"name":"OpenMaé relay","versions":[1],` +
		`"quic":{"port":` + strconv.Itoa(port) + `,"alpn":"openmae-relay/1","spki_sha256":["` + r.srv.pin + `"]},` +
		`"websocket":{"path":"/v1/ws"},` +
		`"limits":{"tubes_per_mac":3,"kbit_per_tube":256,"attempts_per_minute":10},` +
		`"push":false}`
	resp, err := http.Get(r.httpURL + "/v1/info")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if string(body) != want {
		t.Errorf("/v1/info:\n got %s\nwant %s", body, want)
	}
	if ct := resp.Header.Get("Content-Type"); ct != "application/json" {
		t.Errorf("Content-Type %q", ct)
	}

	for _, c := range []struct {
		method, path string
		status       int
		body         string
	}{
		{"GET", "/healthz", 200, "ok"},
		{"HEAD", "/healthz", 200, ""},
		{"POST", "/v1/info", 405, ""},
		{"GET", "/v1/nope", 404, ""},
		{"GET", "/v1/ws", 400, ""}, // not an upgrade
	} {
		req, _ := http.NewRequest(c.method, r.httpURL+c.path, nil)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode != c.status || c.body != "" && string(body) != c.body {
			t.Errorf("%s %s: %d %q", c.method, c.path, resp.StatusCode, body)
		}
	}

	// The certificate the QUIC listener presents matches the pin: dialQUIC
	// checks it.
	dialQUIC(t, r, &quic.Config{EnableDatagrams: true})
}

func TestInfoPublicPortAndPreviousPins(t *testing.T) {
	old := "47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="
	r := startRelay(t, func(c *Config) {
		c.QUICPublicPort = 443
		c.PreviousPins = []string{" " + old + " ", ""}
	})
	q := r.info(t)["quic"].(map[string]any)
	if q["port"] != 443.0 {
		t.Errorf("port %v", q["port"])
	}
	if pins := fmt.Sprint(q["spki_sha256"]); pins != "["+r.srv.pin+" "+old+"]" {
		t.Errorf("pins %s", pins)
	}
}

func TestTubeAcrossTransports(t *testing.T) {
	r := startRelay(t, nil)
	for _, ctrl := range transports {
		for _, phoneKind := range transports {
			for _, tubeKind := range transports {
				t.Run("control="+ctrl+"/iphone="+phoneKind+"/mac="+tubeKind, func(t *testing.T) {
					mac := newMac(t, r)
					mac.register(ctrl)
					phone, macTube := mac.openTube(phoneKind, tubeKind)

					// Larger than one read: crosses chunk and record boundaries.
					up, down := payload(40_000, 1), payload(40_000, 2)
					phone.write(up[:10])
					phone.write(up[10:])
					macTube.write(down)
					if !bytes.Equal(macTube.read(len(up)), up) {
						t.Error("iPhone → Mac: bytes differ")
					}
					if !bytes.Equal(phone.read(len(down)), down) {
						t.Error("Mac → iPhone: bytes differ")
					}
					datagramPasses(t, phone, macTube, []byte("from the iPhone"))
					datagramPasses(t, macTube, phone, []byte("from the Mac"))

					phone.close()
					if !macTube.waitClosed(waitFor) {
						t.Error("the Mac's end of the tube stayed open")
					}
				})
			}
		}
	}
}

func TestBytesSentBeforeConnectedArePiped(t *testing.T) {
	r := startRelay(t, nil)
	mac := newMac(t, r)
	mac.register(viaQUIC)
	for _, kind := range transports {
		phone := connect(t, r, kind, mac.id)
		phone.write([]byte("early")) // a hasty client: before "connected"
		macTube := mac.accept(viaQUIC, mac.incoming())
		phone.expect("connected")
		macTube.pipe()
		if got := macTube.read(5); string(got) != "early" {
			t.Errorf("%s: got %q", kind, got)
		}
	}
}

func TestMacOffline(t *testing.T) {
	r := startRelay(t, nil)
	for _, kind := range transports {
		connect(t, r, kind, newMac(t, r).id).expectError(codeMacOffline)
	}
	// Gone once its control connection closes.
	mac := newMac(t, r)
	mac.register(viaWS).close()
	deadline := time.Now().Add(waitFor)
	for {
		c := connect(t, r, viaQUIC, mac.id)
		m := c.recv()
		if m["code"] == codeMacOffline {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("still registered: %v", m)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestBusy(t *testing.T) {
	r := startRelay(t, nil)
	mac := newMac(t, r)
	mac.register(viaQUIC)
	var phones []*client
	for i := range 3 {
		phone, _ := mac.openTube(transports[i%2], transports[(i+1)%2])
		phones = append(phones, phone)
	}
	for _, kind := range transports {
		connect(t, r, kind, mac.id).expectError(codeBusy)
	}

	// A tube that ends frees its place.
	phones[0].close()
	waitUntil(t, func() bool { return tubesOf(r.srv.hub, mac.id) < 3 })
	mac.openTube(viaWS, viaWS)
	connect(t, r, viaQUIC, mac.id).expectError(codeBusy)
}

func TestBusyCountsPendingTubes(t *testing.T) {
	r := startRelay(t, nil)
	mac := newMac(t, r)
	mac.register(viaWS)
	for range 3 {
		connect(t, r, viaQUIC, mac.id)
		mac.incoming() // never accepted
	}
	connect(t, r, viaWS, mac.id).expectError(codeBusy)
}

func TestBadSignature(t *testing.T) {
	r := startRelay(t, nil)
	for _, kind := range transports {
		mac := newMac(t, r)
		c := dial(t, r, kind)
		mac.hello(c)
		nonce, _ := decodeFixed(c.expect("challenge")["nonce"].(string), 32)
		other := newMac(t, r)
		sig := ed25519.Sign(other.priv, append([]byte(registerContext), nonce...))
		c.send(map[string]any{"op": "register", "sig": b64url.EncodeToString(sig)})
		c.expectError(codeBadSignature)

		// Signing something else than the challenge.
		c = dial(t, r, kind)
		mac.hello(c)
		c.expect("challenge")
		sig = ed25519.Sign(mac.priv, append([]byte(registerContext), make([]byte, 32)...))
		c.send(map[string]any{"op": "register", "sig": b64url.EncodeToString(sig)})
		c.expectError(codeBadSignature)

		// An id that is not the key's.
		c = dial(t, r, kind)
		c.send(map[string]any{
			"op": "hello", "v": 1, "role": "mac", "id": other.id,
			"key": b64url.EncodeToString(mac.priv.Public().(ed25519.PublicKey)),
		})
		c.expectError(codeBadSignature)
	}
}

func TestUnknownTube(t *testing.T) {
	r := startRelay(t, nil)
	random := make([]byte, 16)
	_, _ = rand.Read(random)
	for _, kind := range transports {
		c := dial(t, r, kind)
		c.send(map[string]any{"op": "accept", "v": 1, "tube": b64url.EncodeToString(random)})
		c.expectError(codeUnknownTube)
	}

	// A token serves once.
	mac := newMac(t, r)
	mac.register(viaQUIC)
	phone := connect(t, r, viaWS, mac.id)
	tube := mac.incoming()
	mac.accept(viaQUIC, tube)
	phone.expect("connected")
	c := dial(t, r, viaWS)
	c.send(map[string]any{"op": "accept", "v": 1, "tube": tube})
	c.expectError(codeUnknownTube)
}

func TestMacTimeout(t *testing.T) {
	r := startRelay(t, func(c *Config) { c.Limits.Accept = 300 * time.Millisecond })
	mac := newMac(t, r)
	mac.register(viaWS)
	for range 4 { // more than 3: each timeout frees its place
		phone := connect(t, r, viaQUIC, mac.id)
		tube := mac.incoming()
		phone.expectError(codeMacTimeout)
		late := dial(t, r, viaWS)
		late.send(map[string]any{"op": "accept", "v": 1, "tube": tube})
		late.expectError(codeUnknownTube)
	}
}

func TestRateLimited(t *testing.T) {
	r := startRelay(t, func(c *Config) { c.Limits.AttemptsPerMinute = 10 })
	mac := newMac(t, r)
	for i := range 10 { // hello and connect, over both transports, all count
		c := dial(t, r, transports[i%2])
		if i < 5 {
			mac.hello(c)
			c.expect("challenge")
		} else {
			c.send(map[string]any{"op": "connect", "v": 1, "to": mac.id})
			c.expectError(codeMacOffline)
		}
		c.close()
	}
	for _, kind := range transports {
		c := dial(t, r, kind)
		mac.hello(c)
		c.expectError(codeRateLimited)
		c = dial(t, r, kind)
		c.send(map[string]any{"op": "connect", "v": 1, "to": mac.id})
		c.expectError(codeRateLimited)
	}
	// accept is not an attempt.
	c := dial(t, r, viaQUIC)
	c.send(map[string]any{"op": "accept", "v": 1, "tube": b64url.EncodeToString(make([]byte, 16))})
	c.expectError(codeUnknownTube)
}

func TestNewRegistrationReplacesOld(t *testing.T) {
	r := startRelay(t, nil)
	for _, kinds := range [][2]string{{viaWS, viaQUIC}, {viaQUIC, viaWS}} {
		mac := newMac(t, r)
		first := mac.register(kinds[0])
		second := mac.register(kinds[1])
		first.expectClosed()
		phone := connect(t, r, viaQUIC, mac.id)
		if mac.ctrl != second {
			t.Fatal("test bug")
		}
		macTube := mac.accept(viaWS, mac.incoming())
		phone.expect("connected")
		phone.pipe()
		macTube.pipe()
		phone.write([]byte("hi"))
		if string(macTube.read(2)) != "hi" {
			t.Error("tube through the new registration failed")
		}
	}
}

func TestTubeTeardown(t *testing.T) {
	r := startRelay(t, nil)
	for _, phoneKind := range transports {
		for _, tubeKind := range transports {
			t.Run("iphone="+phoneKind+"/mac="+tubeKind, func(t *testing.T) {
				mac := newMac(t, r)
				mac.register(viaQUIC)
				// The Mac sends a last message and closes, as at the end of
				// a pairing: the iPhone gets it all, then the tube closes.
				phone, macTube := mac.openTube(phoneKind, tubeKind)
				last := payload(30_000, 5)
				macTube.write(last)
				macTube.closeGracefully()
				if !bytes.Equal(phone.read(len(last)), last) {
					t.Error("last bytes lost")
				}
				if !phone.waitClosed(waitFor) {
					t.Error("the iPhone's end stayed open")
				}
				if !macTube.waitClosed(waitFor) {
					t.Error("the Mac's end stayed open")
				}

				// The iPhone goes away abruptly.
				phone, macTube = mac.openTube(phoneKind, tubeKind)
				phone.close()
				if !macTube.waitClosed(waitFor) {
					t.Error("the Mac's end stayed open")
				}
			})
		}
	}
}

func TestTubeIdle(t *testing.T) {
	r := startRelay(t, func(c *Config) { c.Limits.TubeIdle = 400 * time.Millisecond })
	mac := newMac(t, r)
	mac.register(viaQUIC)
	phone, macTube := mac.openTube(viaWS, viaQUIC)
	if !phone.waitClosed(waitFor) || !macTube.waitClosed(waitFor) {
		t.Error("an idle tube stayed open")
	}
}

func TestThrottling(t *testing.T) {
	const rate, burst = 20_000, 2_000
	r := startRelay(t, func(c *Config) {
		c.Limits.BytesPerSecond = rate
		c.Limits.BurstBytes = burst
	})
	mac := newMac(t, r)
	mac.register(viaQUIC)
	for _, kind := range transports {
		phone, macTube := mac.openTube(kind, kind)

		// Bytes are slowed down, not lost.
		data := payload(12_000, 7)
		start := time.Now()
		phone.write(data)
		if !bytes.Equal(macTube.read(len(data)), data) {
			t.Fatalf("%s: bytes differ", kind)
		}
		if min := time.Duration(float64(len(data)-burst) / rate * float64(time.Second)); time.Since(start) < min*9/10 {
			t.Errorf("%s: %d bytes in %v, faster than %d bytes per second", kind, len(data), time.Since(start), rate)
		}

		// Datagrams beyond the budget are dropped.
		for i := range 100 {
			if err := macTube.sendDatagram(payload(500, byte(i))); err != nil {
				t.Fatal(err)
			}
		}
		got := 0
		timeout := time.After(500 * time.Millisecond)
	count:
		for {
			select {
			case <-phone.datagrams:
				got++
			case <-timeout:
				break count
			}
		}
		// 100 × 500 bytes is 2.5 seconds of budget: about 4 fit in the burst,
		// a few more as it refills while they arrive.
		if got == 0 || got > 40 {
			t.Errorf("%s: %d datagrams of 100 passed", kind, got)
		}
	}
}

func TestControlConnection(t *testing.T) {
	r := startRelay(t, func(c *Config) { c.Limits.ControlIdle = 500 * time.Millisecond })
	for _, kind := range transports {
		ctrl := newMac(t, r).register(kind)
		for range 3 { // pings keep it open past the idle timeout
			time.Sleep(200 * time.Millisecond)
			ctrl.send(map[string]any{"op": "ping"})
			ctrl.expect("pong")
		}
		ctrl.send(map[string]any{"op": "pong"}) // answered by nothing, allowed
		start := time.Now()
		ctrl.expectClosed()
		if time.Since(start) < 400*time.Millisecond {
			t.Errorf("%s: closed after %v, before the idle timeout", kind, time.Since(start))
		}
	}
}

func TestControlFlood(t *testing.T) {
	r := startRelay(t, nil)
	ctrl := newMac(t, r).register(viaWS)
	for range controlBurst {
		ctrl.send(map[string]any{"op": "ping"})
		ctrl.expect("pong")
	}
	ctrl.send(map[string]any{"op": "ping"})
	ctrl.expectError(codeRateLimited)
}

func TestProtocolViolations(t *testing.T) {
	r := startRelay(t, nil)
	mac := newMac(t, r)
	key := b64url.EncodeToString(mac.priv.Public().(ed25519.PublicKey))
	token := b64url.EncodeToString(make([]byte, 16))
	cases := []struct {
		name, msg, code string
	}{
		{"not JSON", `{"op":`, codeBadRequest},
		{"not an object", `["hello"]`, codeBadRequest},
		{"no op", `{"v":1}`, codeBadRequest},
		{"unknown op", `{"op":"dance","v":1}`, codeBadRequest},
		{"invalid UTF-8", "{\"op\":\"hello\",\"role\":\"\xff\"}", codeBadRequest},
		{"op of the wrong type", `{"op":1}`, codeBadRequest},
		{"register first", `{"op":"register","sig":"AA"}`, codeBadRequest},
		{"ping first", `{"op":"ping"}`, codeBadRequest},
		{"hello without v", `{"op":"hello","role":"mac","id":"` + mac.id + `","key":"` + key + `"}`, codeBadRequest},
		{"hello v 2", `{"op":"hello","v":2,"role":"mac","id":"` + mac.id + `","key":"` + key + `"}`, codeUnsupportedVersion},
		{"hello v as text", `{"op":"hello","v":"1","role":"mac","id":"` + mac.id + `","key":"` + key + `"}`, codeBadRequest},
		{"hello from an iphone", `{"op":"hello","v":1,"role":"iphone","id":"` + mac.id + `","key":"` + key + `"}`, codeBadRequest},
		{"hello with a bad id", `{"op":"hello","v":1,"role":"mac","id":"` + strings.ToUpper(mac.id) + `","key":"` + key + `"}`, codeBadRequest},
		{"hello with a padded key", `{"op":"hello","v":1,"role":"mac","id":"` + mac.id + `","key":"` + key + `="}`, codeBadRequest},
		{"hello with a short key", `{"op":"hello","v":1,"role":"mac","id":"` + mac.id + `","key":"` + key[:40] + `"}`, codeBadRequest},
		{"connect v 0", `{"op":"connect","v":0,"to":"` + mac.id + `"}`, codeUnsupportedVersion},
		{"connect to a bad id", `{"op":"connect","v":1,"to":"` + mac.id[:25] + `"}`, codeBadRequest},
		{"accept v 3", `{"op":"accept","v":3,"tube":"` + token + `"}`, codeUnsupportedVersion},
		{"accept a bad token", `{"op":"accept","v":1,"tube":"` + token[:20] + `"}`, codeBadRequest},
		{"too large", `{"op":"hello","pad":"` + strings.Repeat("x", maxControlSize) + `"}`, codeBadRequest},
	}
	for _, kind := range transports {
		for _, c := range cases {
			t.Run(kind+"/"+c.name, func(t *testing.T) {
				cl := dial(t, r, kind)
				cl.sendRaw([]byte(c.msg))
				cl.expectError(c.code)
			})
		}
	}

	t.Run("quic/frame header announcing too much", func(t *testing.T) {
		c := dial(t, r, viaQUIC)
		if _, err := c.st.Write([]byte{0, 0, 0x10, 0x01}); err != nil { // 4097 bytes
			t.Fatal(err)
		}
		c.expectError(codeBadRequest)
	})
	t.Run("websocket/binary before piping", func(t *testing.T) {
		c := dial(t, r, viaWS)
		if err := c.ws.WriteMessage(websocket.BinaryMessage, []byte(`{"op":"hello"}`)); err != nil {
			t.Fatal(err)
		}
		c.expectError(codeBadRequest)
	})
	for _, kind := range transports {
		t.Run(kind+"/hello then not register", func(t *testing.T) {
			c := dial(t, r, kind)
			newMac(t, r).hello(c)
			c.expect("challenge")
			c.send(map[string]any{"op": "ping"})
			c.expectError(codeBadRequest)
		})
		t.Run(kind+"/registered then not a ping", func(t *testing.T) {
			ctrl := newMac(t, r).register(kind)
			ctrl.send(map[string]any{"op": "accept", "v": 1, "tube": token})
			ctrl.expectError(codeBadRequest)
		})
		t.Run(kind+"/silent", func(t *testing.T) {
			r := startRelay(t, func(c *Config) { c.Limits.FirstMessage = 300 * time.Millisecond })
			c := dial(t, r, kind)
			if kind == viaQUIC {
				// The relay only learns of a stream from its first byte.
				if _, err := c.st.Write([]byte{0}); err != nil {
					t.Fatal(err)
				}
			}
			c.expectClosed()
		})
	}
	t.Run("quic/datagram on the control connection", func(t *testing.T) {
		ctrl := newMac(t, r).register(viaQUIC)
		if err := ctrl.qc.SendDatagram([]byte("no")); err != nil {
			t.Fatal(err)
		}
		ctrl.expectError(codeBadRequest)
	})
	t.Run("websocket/text in a tube", func(t *testing.T) {
		m := newMac(t, r)
		m.register(viaQUIC)
		phone, macTube := m.openTube(viaWS, viaQUIC)
		if err := phone.ws.WriteMessage(websocket.TextMessage, []byte(`{"op":"ping"}`)); err != nil {
			t.Fatal(err)
		}
		if !phone.waitClosed(waitFor) || !macTube.waitClosed(waitFor) {
			t.Error("tube still open")
		}
	})
	t.Run("websocket/unknown record in a tube", func(t *testing.T) {
		m := newMac(t, r)
		m.register(viaQUIC)
		phone, macTube := m.openTube(viaQUIC, viaWS)
		if err := macTube.ws.WriteMessage(websocket.BinaryMessage, []byte{0x03, 1}); err != nil {
			t.Fatal(err)
		}
		if !phone.waitClosed(waitFor) || !macTube.waitClosed(waitFor) {
			t.Error("tube still open")
		}
	})
}

// Network.framework, when it carries datagrams, leaves stream 0 empty and
// sends on stream 4.
func TestQUICMainStreamAfterAnEmptyStream(t *testing.T) {
	r := startRelay(t, nil)
	mac := newMac(t, r)
	ctrl := mac.register(viaQUICStream4)
	ctrl.send(map[string]any{"op": "ping"})
	ctrl.expect("pong")
	for _, kinds := range [][2]string{
		{viaQUICStream4, viaQUICStream4},
		{viaQUICStream4, viaWS},
		{viaQUIC, viaQUICStream4},
	} {
		t.Run("iphone="+kinds[0]+"/mac="+kinds[1], func(t *testing.T) {
			phone, macTube := mac.openTube(kinds[0], kinds[1])
			up, down := payload(20_000, 3), payload(20_000, 4)
			phone.write(up)
			macTube.write(down)
			if !bytes.Equal(macTube.read(len(up)), up) {
				t.Error("iPhone → Mac: bytes differ")
			}
			if !bytes.Equal(phone.read(len(down)), down) {
				t.Error("Mac → iPhone: bytes differ")
			}
			datagramPasses(t, phone, macTube, []byte("from the iPhone"))
			datagramPasses(t, macTube, phone, []byte("from the Mac"))
			for _, c := range []*client{phone, macTube} {
				if c.empty != nil {
					c.emptyStreamUntouched()
				}
			}
			phone.close()
			if !macTube.waitClosed(waitFor) {
				t.Error("the Mac's end of the tube stayed open")
			}
		})
	}
	ctrl.emptyStreamUntouched()
	ctrl.send(map[string]any{"op": "ping"})
	ctrl.expect("pong")
}

func TestQUICDataOnASecondStream(t *testing.T) {
	r := startRelay(t, nil)
	mac := newMac(t, r)
	mac.register(viaWS)
	writeOn := func(t *testing.T, st *quic.Stream) {
		t.Helper()
		if _, err := st.Write([]byte{0}); err != nil {
			t.Fatal(err)
		}
	}
	newStream := func(t *testing.T, c *client) *quic.Stream {
		t.Helper()
		st, err := c.qc.OpenStream()
		if err != nil {
			t.Fatal(err)
		}
		return st
	}

	t.Run("during the registration", func(t *testing.T) {
		c := dial(t, r, viaQUIC)
		newMac(t, r).hello(c)
		c.expect("challenge")
		writeOn(t, newStream(t, c))
		c.expectError(codeBadRequest)
	})
	t.Run("on a registered control connection", func(t *testing.T) {
		ctrl := newMac(t, r).register(viaQUIC)
		writeOn(t, newStream(t, ctrl))
		ctrl.expectError(codeBadRequest)
	})
	t.Run("on the empty stream, later", func(t *testing.T) {
		ctrl := newMac(t, r).register(viaQUICStream4)
		writeOn(t, ctrl.empty)
		ctrl.expectError(codeBadRequest)
	})
	t.Run("from an iPhone waiting for its Mac", func(t *testing.T) {
		phone := connect(t, r, viaQUICStream4, mac.id)
		mac.incoming()
		writeOn(t, phone.empty)
		phone.expectError(codeBadRequest)
	})
	t.Run("in a tube", func(t *testing.T) {
		phone, macTube := mac.openTube(viaQUICStream4, viaQUIC)
		phone.write([]byte("before"))
		if string(macTube.read(6)) != "before" {
			t.Fatal("tube failed")
		}
		writeOn(t, phone.empty)
		if !phone.waitClosed(waitFor) || !macTube.waitClosed(waitFor) {
			t.Fatal("tube still open")
		}
		// Closed without an error message among the tube's bytes.
		for _, c := range []*client{phone, macTube} {
			c.mu.Lock()
			if len(c.buf) != 0 {
				t.Errorf("%s got %q after the violation", c.kind, c.buf)
			}
			c.mu.Unlock()
		}
	})
}

func TestQUICClientsWithoutDatagrams(t *testing.T) {
	r := startRelay(t, nil)
	mac := newMac(t, r)
	mac.register(viaWS)
	// A tube without datagrams would carry no sound.
	phone := dialQUIC(t, r, &quic.Config{})
	phone.send(map[string]any{"op": "connect", "v": 1, "to": mac.id})
	phone.expectError(codeBadRequest)
	// A control connection does not need them.
	ctrl := dialQUIC(t, r, &quic.Config{})
	mac.hello(ctrl)
	ctrl.expect("challenge")
}

func TestMaxConnections(t *testing.T) {
	r := startRelay(t, func(c *Config) { c.MaxConnections = 2 })
	a := dial(t, r, viaWS)
	dial(t, r, viaQUIC)
	if _, resp, err := websocket.DefaultDialer.Dial(r.wsURL, nil); err == nil || resp == nil || resp.StatusCode != 503 {
		t.Errorf("third WebSocket connection: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), waitFor)
	defer cancel()
	tlsConf := &tls.Config{NextProtos: []string{ALPN}, InsecureSkipVerify: true}
	if qc, err := quic.DialAddr(ctx, r.quicAddr, tlsConf, &quic.Config{EnableDatagrams: true}); err == nil {
		qc.CloseWithError(0, "")
		t.Error("third QUIC connection accepted")
	}
	a.close()
	waitUntil(t, func() bool {
		ws, _, err := websocket.DefaultDialer.Dial(r.wsURL, nil)
		if err == nil {
			ws.Close()
		}
		return err == nil
	})
}

func TestQUICAddressValidationUnderLoad(t *testing.T) {
	r := startRelay(t, nil)
	// As if a flood of handshakes were in progress: new clients get a Retry
	// first, which real clients follow on their own.
	r.srv.handshaking.Add(maxQUICHandshakes)
	mac := newMac(t, r)
	mac.register(viaQUIC)
	phone, macTube := mac.openTube(viaQUIC, viaQUIC)
	phone.write([]byte("still works"))
	if string(macTube.read(11)) != "still works" {
		t.Error("tube failed")
	}
	if n := r.srv.handshaking.Load(); n != maxQUICHandshakes {
		t.Errorf("handshakes in progress: %d, want %d", n, maxQUICHandshakes)
	}
	r.srv.handshaking.Add(-maxQUICHandshakes)
}

func TestShutdownClosesConnections(t *testing.T) {
	r := startRelay(t, nil)
	mac := newMac(t, r)
	ctrl := mac.register(viaWS)
	phone, macTube := mac.openTube(viaQUIC, viaWS)
	start := time.Now()
	r.stop()
	if !phone.waitClosed(waitFor) || !macTube.waitClosed(waitFor) {
		t.Error("tube still open")
	}
	ctrl.expectClosed()
	if time.Since(start) > 3*time.Second {
		t.Errorf("shutdown took %v", time.Since(start))
	}
}

func TestStandaloneModePlainHTTP(t *testing.T) {
	r := startRelay(t, func(c *Config) {
		c.TLSDomain = "relay.example.test"
		c.HTTPSAddr = "127.0.0.1:0"
	})
	if r.srv.httpsLn == nil {
		t.Fatal("no HTTPS listener")
	}
	noRedirect := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	get := func(path string) *http.Response {
		resp, err := noRedirect.Get(r.httpURL + path)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp
	}
	if resp := get("/healthz"); resp.StatusCode != 200 {
		t.Errorf("/healthz: %d", resp.StatusCode)
	}
	resp := get("/v1/info?x=1")
	if resp.StatusCode != 301 || resp.Header.Get("Location") != "https://relay.example.test/v1/info?x=1" {
		t.Errorf("/v1/info: %d %s", resp.StatusCode, resp.Header.Get("Location"))
	}
	// Challenges for other names are refused without asking Let's Encrypt.
	if resp := get("/.well-known/acme-challenge/token"); resp.StatusCode != 403 {
		t.Errorf("ACME challenge: %d", resp.StatusCode)
	}
}

func TestLogsHoldNoIdentifiers(t *testing.T) {
	r := startRelay(t, nil)
	mac := newMac(t, r)
	mac.register(viaQUIC)
	phone := connect(t, r, viaWS, mac.id)
	tube := mac.incoming()
	macTube := mac.accept(viaQUIC, tube)
	phone.expect("connected")
	phone.pipe()
	macTube.pipe()
	phone.write([]byte("hello"))
	macTube.read(5)
	phone.close()
	macTube.waitClosed(waitFor)
	connect(t, r, viaQUIC, newMac(t, r).id).expectError(codeMacOffline)
	c := dial(t, r, viaWS)
	c.send(map[string]any{"op": "accept", "v": 1, "tube": tube})
	c.expectError(codeUnknownTube)
	r.stop()

	logs := r.logs.String()
	for _, secret := range []string{mac.id, tube, "127.0.0.1", "::1"} {
		if strings.Contains(logs, secret) {
			t.Errorf("the logs contain %q:\n%s", secret, logs)
		}
	}
	for _, event := range []string{"relay started", "mac registered", "tube opened", "tube closed", "code=mac_offline"} {
		if !strings.Contains(logs, event) {
			t.Errorf("the logs miss %q:\n%s", event, logs)
		}
	}
}

func tubesOf(h *hub, mac string) int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.tubes[mac]
}

func waitUntil(t *testing.T, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(waitFor)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatal("condition never met")
		}
		time.Sleep(10 * time.Millisecond)
	}
}
