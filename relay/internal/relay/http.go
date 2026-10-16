package relay

import (
	"io"
	"net/http"
	"net/netip"
	"strings"
)

func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/info", s.serveInfo)
	mux.HandleFunc("GET /healthz", serveHealth)
	mux.HandleFunc("GET "+wsPath, s.serveWebSocket)
	return mux
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

// clientIP is the address used to rate-limit a WebSocket client. Behind a
// reverse proxy, the TCP peer is the proxy; the last X-Forwarded-For entry
// is the one the proxy added, the only one a client cannot forge.
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
