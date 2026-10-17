// Package relay implements the openmae-relay/1 protocol described in
// PROTOCOL.md: Macs stay registered on a control connection, iPhones ask for
// a Mac, and the relay pipes opaque bytes and datagrams between the two over
// QUIC or WebSocket. It never sees anything in clear: the end-to-end layer
// encrypts everything before it reaches a tube. The one exception is home
// mode, off by default, for a relay on the home network: systems there post
// deliveries to a Mac over plain HTTP, and the relay passes them in clear.
package relay

import (
	"log/slog"
	"time"
)

// Values fixed by openmae-relay/1.
const (
	ALPN            = "openmae-relay/1"
	protocolVersion = 1
	maxControlSize  = 4096
	wsPath          = "/v1/ws"
)

// Limits bounds what clients can use. Zero fields take the protocol's
// values; tests shorten the timeouts.
type Limits struct {
	TubesPerMac       int           // tubes at once per Mac, pending ones included
	BytesPerSecond    int           // per tube and per direction
	BurstBytes        int           // how far a direction may run ahead of BytesPerSecond
	AttemptsPerMinute int           // hello and connect messages per IP address
	MaxPendingTubes   int           // iPhones waiting for a Mac's accept, all Macs together
	FirstMessage      time.Duration // to open the main stream and send the first control message
	Register          time.Duration // to answer the challenge
	Accept            time.Duration // for the Mac to accept a tube
	ControlIdle       time.Duration // a control connection silent for this long is closed
	TubeIdle          time.Duration // a tube that carries nothing either way for this long is closed
	Linger            time.Duration // to let a last message reach the peer before closing

	// Home mode only, per inbound name.
	InboundPerMinute int           // deliveries in the last minute
	InboundAtOnce    int           // deliveries in progress at once
	InboundBodyBytes int           // the largest delivery body
	InboundTimeout   time.Duration // to receive a delivery, then for the Mac to accept its tube, then to answer
}

func (l Limits) withDefaults() Limits {
	set := func(v *int, def int) {
		if *v <= 0 {
			*v = def
		}
	}
	setD := func(v *time.Duration, def time.Duration) {
		if *v <= 0 {
			*v = def
		}
	}
	set(&l.TubesPerMac, 3)
	set(&l.BytesPerSecond, 256_000/8)
	set(&l.BurstBytes, l.BytesPerSecond) // one second of traffic
	set(&l.AttemptsPerMinute, 10)
	set(&l.MaxPendingTubes, 1024)
	setD(&l.FirstMessage, 10*time.Second)
	setD(&l.Register, 10*time.Second)
	setD(&l.Accept, 10*time.Second)
	setD(&l.ControlIdle, 75*time.Second)
	// The end-to-end layer pings every 25 seconds without other traffic, so a
	// live tube is never silent this long.
	setD(&l.TubeIdle, 75*time.Second)
	setD(&l.Linger, 2*time.Second)
	set(&l.InboundPerMinute, 30)
	set(&l.InboundAtOnce, 5)
	set(&l.InboundBodyBytes, 64<<10)
	setD(&l.InboundTimeout, 10*time.Second)
	return l
}

// Config describes a relay. Zero fields take defaults.
type Config struct {
	// HTTPAddr is the plain HTTP listener, normally behind a TLS reverse
	// proxy (default ":8080").
	HTTPAddr string
	// QUICAddr is the UDP listener for QUIC (default ":4433").
	QUICAddr string
	// QUICPublicPort is the UDP port announced in /v1/info, for a listener
	// published on another port (0: the port QUICAddr is bound to).
	QUICPublicPort int
	// DataDir keeps the QUIC key and certificate, and the ACME cache in
	// standalone mode (default "/data").
	DataDir string
	// PreviousPins are pins of earlier QUIC keys, still announced after a key
	// change.
	PreviousPins []string
	// BehindProxy makes the WebSocket client address, used only for rate
	// limiting, the last X-Forwarded-For entry instead of the TCP peer.
	BehindProxy bool
	// TLSDomain turns on standalone mode: the relay serves HTTPS itself on
	// HTTPSAddr with a Let's Encrypt certificate for this domain.
	TLSDomain string
	// HTTPSAddr is the HTTPS listener in standalone mode (default ":443").
	HTTPSAddr string
	// MaxConnections caps QUIC and WebSocket connections at once (default 4096).
	MaxConnections int
	// HomeInbound turns on home mode: systems on the local network can post
	// deliveries to Macs registered for them, on the HTTP listener. The relay
	// reads deliveries in clear, so this is only for a relay on the home
	// network: a public relay must never turn it on. It cannot be combined
	// with TLSDomain.
	HomeInbound bool
	Limits      Limits
	Logger      *slog.Logger
	// Pusher sends push notifications; nil on every relay without an APNs key.
	Pusher Pusher
}

func (c Config) withDefaults() Config {
	if c.HTTPAddr == "" {
		c.HTTPAddr = ":8080"
	}
	if c.QUICAddr == "" {
		c.QUICAddr = ":4433"
	}
	if c.DataDir == "" {
		c.DataDir = "/data"
	}
	if c.HTTPSAddr == "" {
		c.HTTPSAddr = ":443"
	}
	if c.MaxConnections <= 0 {
		c.MaxConnections = 4096
	}
	if c.Logger == nil {
		c.Logger = slog.Default()
	}
	c.Limits = c.Limits.withDefaults()
	return c
}
