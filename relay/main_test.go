package main

import (
	"log/slog"
	"net"
	"net/http"
	"sync/atomic"
	"testing"
)

func env(vars map[string]string) func(string) string {
	return func(k string) string { return vars[k] }
}

func TestConfigDefaults(t *testing.T) {
	cfg, level, err := configFromEnv(env(nil))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.HTTPAddr != ":8080" || cfg.QUICAddr != ":4433" || cfg.QUICPublicPort != 0 || cfg.DataDir != "/data" ||
		cfg.BehindProxy || cfg.TLSDomain != "" || cfg.HTTPSAddr != ":443" || cfg.MaxConnections != 0 ||
		cfg.HomeInbound || len(cfg.PreviousPins) != 0 || level != slog.LevelInfo {
		t.Errorf("defaults: %+v %v", cfg, level)
	}
}

func TestConfigFromEnv(t *testing.T) {
	cfg, level, err := configFromEnv(env(map[string]string{
		"RELAY_HTTP_ADDR":        "127.0.0.1:9000",
		"RELAY_QUIC_ADDR":        ":9443",
		"RELAY_QUIC_PUBLIC_PORT": "443",
		"RELAY_DATA_DIR":         "/var/lib/relay",
		"RELAY_PREVIOUS_PINS":    "a, b",
		"RELAY_BEHIND_PROXY":     "true",
		"RELAY_TLS_DOMAIN":       "relay.example.com",
		"RELAY_HTTPS_ADDR":       ":8443",
		"RELAY_MAX_CONNECTIONS":  "100",
		"RELAY_HOME_INBOUND":     "true",
		"RELAY_LOG_LEVEL":        "debug",
	}))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.HTTPAddr != "127.0.0.1:9000" || cfg.QUICAddr != ":9443" || cfg.QUICPublicPort != 443 ||
		cfg.DataDir != "/var/lib/relay" || len(cfg.PreviousPins) != 2 || !cfg.BehindProxy ||
		cfg.TLSDomain != "relay.example.com" || cfg.HTTPSAddr != ":8443" || cfg.MaxConnections != 100 ||
		!cfg.HomeInbound || level != slog.LevelDebug {
		t.Errorf("parsed: %+v %v", cfg, level)
	}
	for _, bad := range []map[string]string{
		{"RELAY_QUIC_PUBLIC_PORT": "70000"},
		{"RELAY_QUIC_PUBLIC_PORT": "https"},
		{"RELAY_BEHIND_PROXY": "maybe"},
		{"RELAY_HOME_INBOUND": "perhaps"},
		{"RELAY_MAX_CONNECTIONS": "0"},
		{"RELAY_LOG_LEVEL": "loud"},
	} {
		if _, _, err := configFromEnv(env(bad)); err == nil {
			t.Errorf("%v accepted", bad)
		}
	}
}

func TestCheckHealth(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var healthy atomic.Bool
	healthy.Store(true)
	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !healthy.Load() || r.URL.Path != "/healthz" {
			w.WriteHeader(http.StatusServiceUnavailable)
		}
	})}
	go srv.Serve(ln)
	defer srv.Close()
	_, port, _ := net.SplitHostPort(ln.Addr().String())

	if err := checkHealth(":" + port); err != nil { // listening everywhere: asks 127.0.0.1
		t.Errorf("healthy relay: %v", err)
	}
	healthy.Store(false)
	if err := checkHealth("127.0.0.1:" + port); err == nil {
		t.Error("unhealthy relay passed")
	}
	if err := checkHealth("127.0.0.1:1"); err == nil {
		t.Error("no relay passed")
	}
}
