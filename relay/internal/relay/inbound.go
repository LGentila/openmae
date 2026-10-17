package relay

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"io"
	"maps"
	"net/http"
	"net/netip"
	"strconv"
	"strings"
	"time"
)

// Home mode: systems on the local network (Home Assistant, scripts) post
// short texts, deliveries, to a Mac through the relay, without any port open
// on the Mac. The Mac keeps one more control connection, registered with
// "inbound"; for each delivery the relay asks it for a tube, writes the
// request into the tube as HTTP/1.1 and returns the Mac's answer. Deliveries
// are not encrypted end to end: the relay reads them in clear.

const (
	inboundPattern  = "/{name}/in/{secret}"
	maxTrackedNames = 1 << 16 // for deliveries per inbound name
	// The Mac's answer: its header section, and its body.
	maxAnswerHeader = 16 << 10
	maxAnswerBody   = 4 << 10
)

var (
	errAnswerTimeout  = errors.New("no answer in time")
	errAnswerTooLarge = errors.New("answer too large")
	errBadAnswer      = errors.New("not a final HTTP answer")
	errNoDatagrams    = errors.New("no datagrams in a delivery's tube")
)

// isLocalAddr tells whether a caller is on the local network: a private
// address (10/8, 172.16/12, 192.168/16, fc00::/7), a link-local one
// (169.254/16, fe80::/10) or the loopback (127/8, ::1).
func isLocalAddr(ip netip.Addr) bool {
	ip = ip.Unmap()
	return ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsLoopback()
}

// serveDelivery passes a delivery to its Mac and returns the Mac's answer.
// The relay keeps nothing: when the Mac is not there, the caller gets 503
// and may try again later.
func (s *Server) serveDelivery(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	// Bounds reading the body, and what net/http discards of it after an
	// early answer.
	rc := http.NewResponseController(w)
	_ = rc.SetReadDeadline(start.Add(s.lim.InboundTimeout))

	from := clientIP(r, s.cfg.BehindProxy)
	name := r.PathValue("name")
	switch {
	case !isLocalAddr(from):
		s.refuseDelivery(w, http.StatusForbidden, "deliveries are accepted from the local network only")
		return
	case !validDeviceID(name) || r.PathValue("secret") == "":
		s.refuseDelivery(w, http.StatusNotFound, "404 page not found") // as for any unknown path
		return
	case !s.deliveries.start(name):
		s.refuseDelivery(w, http.StatusTooManyRequests, "too many deliveries")
		return
	}
	defer s.deliveries.done(name)
	if !s.hub.inboundRegistered(name) {
		s.refuseDelivery(w, http.StatusServiceUnavailable, "Mac not connected")
		return
	}
	body, status, text := s.readDelivery(w, r)
	if status != 0 {
		// What is left of the body stays unread: the connection cannot
		// carry another request.
		w.Header().Set("Connection", "close")
		s.refuseDelivery(w, status, text)
		return
	}
	_ = rc.SetReadDeadline(time.Time{})

	p, reg, code := s.hub.openInbound(name)
	switch code {
	case codeMacOffline:
		s.refuseDelivery(w, http.StatusServiceUnavailable, "Mac not connected")
		return
	case codeBusy:
		s.refuseDelivery(w, http.StatusServiceUnavailable, "relay busy")
		return
	}
	defer s.hub.release(p)
	defer close(p.done) // lets the Mac's tube connection go

	if reg.c.writeControl(inboundMessage(p.token, from)) != nil {
		// That control connection is broken; the Mac will register again.
		s.hub.withdraw(p)
		reg.c.closeNow()
		s.refuseDelivery(w, http.StatusServiceUnavailable, "Mac not connected")
		return
	}
	mac, _ := s.waitForAccept(p, s.lim.InboundTimeout, reg.c.gone())
	if mac == nil {
		s.failDelivery(w, http.StatusServiceUnavailable, "Mac not answering", "not accepted")
		return
	}
	ans, err := s.exchange(mac, r, body)
	if err != nil {
		s.failDelivery(w, http.StatusBadGateway, "no valid answer from the Mac", answerFailure(err))
		return
	}

	h := w.Header()
	if ans.contentType != "" {
		h.Set("Content-Type", ans.contentType)
	} else {
		h["Content-Type"] = nil // not guessed from the body
	}
	h.Set("Content-Length", strconv.Itoa(len(ans.body)))
	w.WriteHeader(ans.status)
	_, _ = w.Write(ans.body)
	s.log.Info("delivery", "status", ans.status, "bytes", len(body), "ms", time.Since(start).Milliseconds())
}

// refuseDelivery answers a delivery the relay does not pass to a Mac.
func (s *Server) refuseDelivery(w http.ResponseWriter, status int, text string) {
	s.stats.count("delivery_" + strconv.Itoa(status))
	s.log.Debug("delivery refused", "status", status)
	http.Error(w, text, status)
}

// failDelivery answers a delivery the Mac was asked for, but did not answer.
func (s *Server) failDelivery(w http.ResponseWriter, status int, text, reason string) {
	s.stats.count("delivery_" + strconv.Itoa(status))
	s.log.Info("delivery failed", "status", status, "reason", reason)
	http.Error(w, text, status)
}

// readDelivery reads a delivery's whole body, within the deadline set at
// its arrival. A status other than 0 turns the delivery away.
func (s *Server) readDelivery(w http.ResponseWriter, r *http.Request) ([]byte, int, string) {
	limit := int64(s.lim.InboundBodyBytes)
	if r.ContentLength > limit {
		return nil, http.StatusRequestEntityTooLarge, "delivery too large"
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, limit))
	var tooLarge *http.MaxBytesError
	switch {
	case err == nil:
		return body, 0, ""
	case errors.As(err, &tooLarge):
		return nil, http.StatusRequestEntityTooLarge, "delivery too large"
	case errKind(err) == "timeout":
		return nil, http.StatusRequestTimeout, "delivery too slow"
	}
	return nil, http.StatusBadRequest, "unreadable delivery"
}

// answer is the Mac's answer to a delivery, as the caller gets it.
type answer struct {
	status      int
	contentType string
	body        []byte
}

// exchange writes a delivery into the Mac's tube connection as an HTTP/1.1
// request and reads the Mac's answer, all within InboundTimeout, then closes
// the tube.
func (s *Server) exchange(mac conn, r *http.Request, body []byte) (*answer, error) {
	// What the Mac sends in the tube comes out of pr. When the time is up,
	// closing the connection unblocks every read and write on it.
	pr, pw := io.Pipe()
	timer := time.AfterFunc(s.lim.InboundTimeout, func() {
		_ = pw.CloseWithError(errAnswerTimeout)
		mac.closeNow()
	})
	defer timer.Stop()
	if err := mac.writeControl(msgAccepted); err != nil {
		mac.closeNow()
		return nil, err
	}

	ctx, cancel := context.WithCancel(s.ctx)
	defer cancel()
	f := &flow{
		budget:   newBucket(float64(s.lim.BytesPerSecond), float64(s.lim.BurstBytes), nil),
		activity: newActivity(),
	}
	forwarded := make(chan struct{})
	go func() {
		defer close(forwarded)
		err := mac.forward(ctx, answerSink{pw}, f)
		if errKind(err) == "closed" {
			err = nil // the Mac closed its side: its answer ends there
		}
		_ = pw.CloseWithError(err)
	}()
	// Written while the answer is read: a Mac may answer before reading the
	// whole request.
	wrote := make(chan error, 1)
	go func() { wrote <- mac.writeBytes(tubeRequest(r, body)) }()

	ans, err := readAnswer(pr, r.Method)

	_ = pr.Close() // anything more the Mac sends is not read
	cancel()
	select {
	case werr := <-wrote:
		if werr == nil {
			mac.closeWrite(time.Now().Add(s.lim.Linger)) // a clean end, after the answer
		}
		mac.closeNow()
	default:
		mac.closeNow() // the request is still being written: cut it short
		<-wrote
	}
	<-forwarded
	return ans, err
}

// answerFailure says why exchange failed, for the logs.
func answerFailure(err error) string {
	switch {
	case errors.Is(err, errAnswerTimeout):
		return "no answer in time"
	case errors.Is(err, errAnswerTooLarge):
		return "answer too large"
	}
	return "broken answer"
}

// answerSink takes what the Mac sends in a delivery's tube: its answer.
// Datagrams have no place there and are dropped.
type answerSink struct{ w *io.PipeWriter }

func (a answerSink) writeBytes(p []byte) error {
	_, err := a.w.Write(p)
	return err
}

func (answerSink) writeDatagram([]byte) error { return errNoDatagrams }

// readAnswer reads the Mac's HTTP/1.1 answer to a delivery made with method.
// Interim (1xx) answers are skipped.
func readAnswer(r io.Reader, method string) (*answer, error) {
	lr := &io.LimitedReader{R: r, N: maxAnswerHeader + maxAnswerBody}
	br := bufio.NewReader(lr)
	req := &http.Request{Method: method}
	for {
		resp, err := http.ReadResponse(br, req)
		if err != nil {
			return nil, err
		}
		switch code := resp.StatusCode; {
		case code == http.StatusSwitchingProtocols, code < 100, code > 599:
			return nil, errBadAnswer
		case code < 200:
			continue // an interim answer
		}
		b, err := io.ReadAll(io.LimitReader(resp.Body, maxAnswerBody+1))
		switch {
		case err != nil:
			return nil, err
		case len(b) > maxAnswerBody, lr.N == 0: // or cut off by the limit, without a length
			return nil, errAnswerTooLarge
		}
		return &answer{status: resp.StatusCode, contentType: resp.Header.Get("Content-Type"), body: b}, nil
	}
}

// Not passed into the tube: the hop-by-hop headers (RFC 9110, section
// 7.6.1); the length, which the relay sets; Expect, since the relay already
// has the whole body; and Host, written first.
var notForwarded = map[string]bool{
	"Connection":          true,
	"Keep-Alive":          true,
	"Proxy-Connection":    true,
	"Proxy-Authenticate":  true,
	"Proxy-Authorization": true,
	"Te":                  true,
	"Trailer":             true,
	"Transfer-Encoding":   true,
	"Upgrade":             true,
	"Content-Length":      true,
	"Expect":              true,
	"Host":                true,
}

// tubeRequest is a delivery as the Mac reads it in its tube: an HTTP/1.1
// request with the whole body and its length, after which the relay sends
// nothing more.
func tubeRequest(r *http.Request, body []byte) []byte {
	exclude := notForwarded
	if named := r.Header.Values("Connection"); len(named) > 0 {
		// Headers named in Connection are hop-by-hop as well.
		exclude = maps.Clone(notForwarded)
		for _, v := range named {
			for _, h := range strings.Split(v, ",") {
				if h = strings.TrimSpace(h); h != "" {
					exclude[http.CanonicalHeaderKey(h)] = true
				}
			}
		}
	}
	uri := r.RequestURI
	if !strings.HasPrefix(uri, "/") { // an absolute URI: its path and query
		uri = r.URL.RequestURI()
	}
	var b bytes.Buffer
	b.WriteString(r.Method + " " + uri + " HTTP/1.1\r\nHost: " + r.Host + "\r\n")
	_ = r.Header.WriteSubset(&b, exclude) // net/http checked the names and values
	b.WriteString("Content-Length: " + strconv.Itoa(len(body)) + "\r\nConnection: close\r\n\r\n")
	b.Write(body)
	return b.Bytes()
}
