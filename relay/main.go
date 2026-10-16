// Command relay runs an OpenMaé relay. It is configured by environment
// variables only; see README.md.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/LGentila/openmae/relay/internal/relay"
)

func main() {
	flag.CommandLine.SetOutput(os.Stdout)
	healthcheck := flag.Bool("healthcheck", false,
		"ask the running relay's /healthz on the local HTTP listener; exit 0 if it answers")
	flag.Parse()

	cfg, level, err := configFromEnv(os.Getenv)
	if err != nil {
		fmt.Println("relay:", err)
		os.Exit(2)
	}
	if *healthcheck {
		if err := checkHealth(cfg.HTTPAddr); err != nil {
			fmt.Println("unhealthy:", err)
			os.Exit(1)
		}
		return
	}

	logger := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: level}))
	slog.SetDefault(logger)
	// Libraries log through the standard log package; keep their lines, on
	// standard output, without addresses.
	log.SetFlags(0)
	log.SetOutput(relay.LibraryLogWriter(logger))
	cfg.Logger = logger

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()
	srv, err := relay.New(cfg)
	if err != nil {
		logger.Error("cannot start", "err", err)
		os.Exit(1)
	}
	if err := srv.Run(ctx); err != nil {
		logger.Error("stopped on error", "err", err)
		os.Exit(1)
	}
}

func configFromEnv(getenv func(string) string) (relay.Config, slog.Level, error) {
	get := func(name, def string) string {
		if v := strings.TrimSpace(getenv(name)); v != "" {
			return v
		}
		return def
	}
	cfg := relay.Config{
		HTTPAddr:  get("RELAY_HTTP_ADDR", ":8080"),
		QUICAddr:  get("RELAY_QUIC_ADDR", ":4433"),
		DataDir:   get("RELAY_DATA_DIR", "/data"),
		TLSDomain: get("RELAY_TLS_DOMAIN", ""),
		HTTPSAddr: get("RELAY_HTTPS_ADDR", ":443"),
	}
	var err error
	if v := get("RELAY_QUIC_PUBLIC_PORT", ""); v != "" {
		if cfg.QUICPublicPort, err = strconv.Atoi(v); err != nil || cfg.QUICPublicPort < 1 || cfg.QUICPublicPort > 65535 {
			return cfg, 0, fmt.Errorf("RELAY_QUIC_PUBLIC_PORT: %q is not a port number", v)
		}
	}
	if v := get("RELAY_PREVIOUS_PINS", ""); v != "" {
		cfg.PreviousPins = strings.Split(v, ",") // checked by relay.New
	}
	if v := get("RELAY_BEHIND_PROXY", ""); v != "" {
		if cfg.BehindProxy, err = parseBool(v); err != nil {
			return cfg, 0, fmt.Errorf("RELAY_BEHIND_PROXY: %w", err)
		}
	}
	if v := get("RELAY_MAX_CONNECTIONS", ""); v != "" {
		if cfg.MaxConnections, err = strconv.Atoi(v); err != nil || cfg.MaxConnections < 1 {
			return cfg, 0, fmt.Errorf("RELAY_MAX_CONNECTIONS: %q is not a positive number", v)
		}
	}
	var level slog.Level
	if err := level.UnmarshalText([]byte(get("RELAY_LOG_LEVEL", "info"))); err != nil {
		return cfg, 0, fmt.Errorf("RELAY_LOG_LEVEL: %w", err)
	}
	return cfg, level, nil
}

func parseBool(v string) (bool, error) {
	switch strings.ToLower(v) {
	case "1", "true", "yes", "on":
		return true, nil
	case "0", "false", "no", "off":
		return false, nil
	}
	return false, fmt.Errorf("%q is neither true nor false", v)
}

// checkHealth lets a container health check run without a shell or curl.
func checkHealth(httpAddr string) error {
	host, port, err := net.SplitHostPort(httpAddr)
	if err != nil {
		return err
	}
	if ip := net.ParseIP(host); host == "" || ip != nil && ip.IsUnspecified() {
		host = "127.0.0.1"
	}
	client := &http.Client{
		Timeout:       3 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	resp, err := client.Get("http://" + net.JoinHostPort(host, port) + "/healthz")
	if err != nil {
		return err
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("status %d", resp.StatusCode)
	}
	return nil
}
