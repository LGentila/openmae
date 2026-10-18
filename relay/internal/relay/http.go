package relay

import (
	"io"
	"net/http"
	"net/netip"
	"strings"
)

// routes serves the HTTP listener, and the HTTPS one in standalone mode.
// Deliveries come to the plain HTTP listener only, in home mode. With an
// inbound domain, the plain HTTP listener also answers Let's Encrypt's
// HTTP-01 challenge for the names under it.
func (s *Server) routes(deliveries bool) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/info", s.serveInfo)
	mux.HandleFunc("GET /healthz", serveHealth)
	mux.HandleFunc("GET "+wsPath, s.serveWebSocket)
	if deliveries {
		mux.HandleFunc(inboundPattern, s.serveDelivery)
	}
	if s.cfg.InboundDomain == "" {
		return mux
	}
	return s.inboundChallenges(mux)
}

const challengePrefix = "/.well-known/acme-challenge/"

// inboundChallenges answers requests for names under the inbound domain:
// the answers Macs left for Let's Encrypt's HTTP-01 challenge, and 404 for
// anything else. Other names go to next.
func (s *Server) inboundChallenges(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		name, ok := inboundNameOf(r.Host, s.cfg.InboundDomain)
		if !ok {
			next.ServeHTTP(w, r)
			return
		}
		token, isChallenge := strings.CutPrefix(r.URL.Path, challengePrefix)
		var answer string
		if isChallenge && (r.Method == http.MethodGet || r.Method == http.MethodHead) {
			answer, ok = s.challenges.get(name, token)
		} else {
			ok = false
		}
		if !ok {
			s.stats.count("challenge_404")
			http.NotFound(w, r)
			return
		}
		s.log.Debug("challenge answered")
		w.Header().Set("Content-Type", "text/plain")
		w.Header().Set("Cache-Control", "no-store")
		_, _ = io.WriteString(w, answer)
	})
}

func (s *Server) serveInfo(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	// Clients take the QUIC pins from here: a cached copy could miss a new key.
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(s.info)
}

func serveHealth(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	_, _ = io.WriteString(w, "ok")
}

// redirectToHTTPS serves plain HTTP in standalone mode: the health check
// for local probes, a redirect for everything else.
func (s *Server) redirectToHTTPS() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", serveHealth)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		// The configured domain, not the Host header, which the client chooses.
		http.Redirect(w, r, "https://"+s.cfg.TLSDomain+r.URL.RequestURI(), http.StatusMovedPermanently)
	})
	return mux
}

// clientIP is the address of a client of the HTTP listener, used to
// rate-limit WebSocket clients and to take deliveries from the local network
// only. Behind a reverse proxy, the TCP peer is the proxy; the last
// X-Forwarded-For entry is the one the proxy added, the only one a client
// cannot forge.
func clientIP(r *http.Request, behindProxy bool) netip.Addr {
	if behindProxy {
		if values := r.Header.Values("X-Forwarded-For"); len(values) > 0 {
			last := values[len(values)-1]
			if i := strings.LastIndexByte(last, ','); i >= 0 {
				last = last[i+1:]
			}
			if ip, ok := parseHostAddr(strings.TrimSpace(last)); ok {
				return ip
			}
		}
	}
	ip, _ := parseHostAddr(r.RemoteAddr)
	return ip
}

// parseHostAddr reads "1.2.3.4", "2001:db8::1", "[2001:db8::1]" or any of
// them with a port.
func parseHostAddr(s string) (netip.Addr, bool) {
	if ap, err := netip.ParseAddrPort(s); err == nil {
		return ap.Addr().Unmap(), true
	}
	s = strings.TrimSuffix(strings.TrimPrefix(s, "["), "]")
	if ip, err := netip.ParseAddr(s); err == nil {
		return ip.Unmap(), true
	}
	return netip.Addr{}, false
}
