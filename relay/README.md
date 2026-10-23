# OpenMaé relay

A small server that lets the OpenMaé iPhone app reach OpenMaé on a Mac when the two are not on the same
network. The Mac stays registered on the relay; when the iPhone asks for it, the relay opens a *tube* between
them and passes their bytes and datagrams along, unchanged.

Everything in a tube is encrypted end to end between the iPhone and the Mac (Noise), before it reaches the
relay. The relay holds no key that could open it.

The protocol is described in [PROTOCOL.md](PROTOCOL.md): section 1 is what the relay implements, section 2 is
what goes through a tube, which the relay never parses.

## What the relay sees, and what it cannot see

The relay sees:

- the IP addresses of the Macs and iPhones that connect, kept in memory for rate limiting only;
- the device ids of the Macs (a hash of their public key) and which device id an iPhone asks for;
- when a tube opens and closes, and how many bytes and datagrams pass.

It cannot see what is said or heard, any text, or any notification: tubes carry ciphertext only. It does not
learn which iPhone is talking either, beyond its IP address: the iPhone authenticates to the Mac, not to the
relay, and the Mac turns away iPhones it has not paired.

It keeps nothing on disk except its own QUIC key and certificate (and, in standalone mode, its Let's Encrypt
certificate). There is no database: after a restart, Macs register again within about 30 seconds.

Its logs hold no device id, tube token or IP address (see [Logs](#logs)).

One exception, off by default: a relay run on the home network in **home mode** also passes short texts that
systems on that network post to the Mac, and reads them in clear (see [Home relay](#home-relay)).

A public relay can also take short texts that systems on the internet post to a Mac, **without reading them**: with an
**inbound domain**, it passes their TLS through to the Mac, which holds the certificate (see
[Deliveries from the internet](#deliveries-from-the-internet)).

## How it is reached

| What | Transport | Where |
|---|---|---|
| Discovery: `GET /v1/info` | HTTPS | behind your reverse proxy (or the relay itself in standalone mode) |
| Tubes, preferred | QUIC over UDP, ALPN `openmae-relay/1` | a UDP port published straight to the container (4433 inside) |
| Tubes, fallback when UDP is blocked | WebSocket, `GET /v1/ws` | HTTPS, through the reverse proxy |
| Health: `GET /healthz` | HTTP | answers `200 ok` |
| Deliveries, home mode only: `/<inbound name>/in/<secret>` | plain HTTP | the HTTP listener, on the home network (see [Home relay](#home-relay)) |
| Deliveries from the internet, with an inbound domain: `https://<inbound name>.<inbound domain>/in/<secret>` | TLS passed through to the Mac | the inbound listener (8444), behind a proxy passing TLS through; Let's Encrypt's HTTP-01 challenge on the HTTP listener (see [Deliveries from the internet](#deliveries-from-the-internet)) |

Inside the container the relay speaks plain HTTP on port 8080 and QUIC on UDP port 4433. QUIC cannot go
through an HTTP reverse proxy, so its UDP port is published on the host directly. `/v1/info` tells the apps
which UDP port to use (`quic.port`), so it can be any port.

## Running

### Published image

Each change to `relay/` on `main` (documentation aside) is built for `linux/amd64` and `linux/arm64` (Intel and AMD
machines, Apple Silicon, a Raspberry Pi with a 64-bit system) and published as a public image, pulled without
logging in:

| Image | Relay |
|---|---|
| `ghcr.io/lgentila/openmae-relay:latest` | the latest one on `main` |
| `ghcr.io/lgentila/openmae-relay:<short commit hash>`, for example `:a1b2c3d` | the one built from that commit of `main` |
| `ghcr.io/lgentila/openmae-relay:<version>`, for example `:1.2.0` | a version, published for a Git tag `relay-v<version>` |

To use it instead of building the image: `image: ghcr.io/lgentila/openmae-relay:latest` instead of `build: .` in
a Compose file, or that name instead of `openmae-relay` after `docker run`. To update: `docker compose pull`, then
`docker compose up -d`. To stay on one relay, use a commit's short hash or a version instead of `latest`.

The image holds only the relay's binary, built from this folder by
[.github/workflows/relay-image.yml](../.github/workflows/relay-image.yml), which runs the tests first.

### With Docker behind a reverse proxy

```sh
docker build -t openmae-relay .
docker run -d --name openmae-relay --restart unless-stopped \
  -e RELAY_BEHIND_PROXY=true \
  -e RELAY_QUIC_PUBLIC_PORT=443 \
  -p 127.0.0.1:8080:8080 \
  -p 443:4433/udp \
  -v openmae-relay-data:/data \
  openmae-relay
```

Then point your reverse proxy's HTTPS domain at `127.0.0.1:8080`. WebSocket must be allowed through (Traefik
and Caddy pass it without configuration). The image is distroless (no shell), runs as user 65532 and keeps its
state in the `/data` volume. With a host directory instead of a named volume, make it writable by that user
(`chown 65532:65532 <directory>`): the relay refuses to start if it cannot save its key.

### With Docker Compose

[compose.yaml](compose.yaml) is a commented example for a host with a reverse proxy (a self-hosting platform,
Traefik, Caddy…): HTTP on 8080 for the proxy, QUIC published as `443:4433/udp`, and the `/data` volume.

```sh
docker compose up -d --build
```

### Standalone, without a reverse proxy

When `RELAY_TLS_DOMAIN` is set, the relay serves HTTPS itself, with a Let's Encrypt certificate for that
domain, obtained and renewed automatically (cache in `/data/acme`). Point the domain's DNS at the server first.

```sh
docker run -d --name openmae-relay --restart unless-stopped \
  -e RELAY_TLS_DOMAIN=relay.example.com \
  -e RELAY_QUIC_PUBLIC_PORT=443 \
  -p 443:443/tcp \
  -p 80:8080/tcp \
  -p 443:4433/udp \
  -v openmae-relay-data:/data \
  openmae-relay
```

- HTTPS listens on `RELAY_HTTPS_ADDR` (`:443`). TCP 443 and UDP 443 do not collide: HTTPS uses one, QUIC the
  other.
- The certificate is obtained with the TLS-ALPN-01 challenge on port 443, or HTTP-01 on the HTTP listener, which
  must then be reachable on port 80 (here `80:8080`). Besides the challenge, the HTTP listener only answers
  `/healthz` and redirects everything else to HTTPS.
- Setting `RELAY_TLS_DOMAIN` accepts the Let's Encrypt Subscriber Agreement.
- Inside Docker, a non-root process may listen on port 443. Outside a container, give the binary the
  `cap_net_bind_service` capability or choose another `RELAY_HTTPS_ADDR`.

### From source

Go 1.26 or later:

```sh
go build -o relay .
RELAY_DATA_DIR=./data RELAY_LOG_LEVEL=debug ./relay
```

## Configuration

Environment variables only. All are optional.

| Variable | Default | Meaning |
|---|---|---|
| `RELAY_HTTP_ADDR` | `:8080` | Plain HTTP listener: `/v1/info`, `/v1/ws`, `/healthz`, and deliveries in home mode. Normally behind a TLS reverse proxy. In standalone mode, it answers the HTTP-01 challenge and `/healthz`, and redirects the rest to HTTPS. |
| `RELAY_QUIC_ADDR` | `:4433` | UDP listener for QUIC. |
| `RELAY_QUIC_PUBLIC_PORT` | the port of `RELAY_QUIC_ADDR` | The UDP port announced in `/v1/info`, as clients reach it: set it when the listener is published on another port, for example `443` with `-p 443:4433/udp`. |
| `RELAY_DATA_DIR` | `/data` | Where the QUIC key (`quic-key.pem`) and certificate (`quic-cert.pem`) are kept, and the Let's Encrypt cache (`acme/`) in standalone mode. Created if missing. |
| `RELAY_PREVIOUS_PINS` | none | Comma-separated pins of earlier QUIC keys, still listed in `/v1/info` after a key change (see [Key rotation](#quic-certificate-and-key-rotation)). |
| `RELAY_BEHIND_PROXY` | `false` | When true, the client address used to rate-limit WebSocket clients (and, in home mode, to take deliveries from the local network only) is the last entry of `X-Forwarded-For` (the one your proxy adds) instead of the TCP peer, which is then the proxy. Set it behind a proxy, and only there: without a proxy, clients could write that header themselves. |
| `RELAY_TLS_DOMAIN` | none | Turns on standalone mode for this domain. |
| `RELAY_HTTPS_ADDR` | `:443` | HTTPS listener in standalone mode. |
| `RELAY_MAX_CONNECTIONS` | `4096` | QUIC and WebSocket connections at once. Past it, new QUIC connections are refused during their handshake and WebSocket upgrades get `503`. |
| `RELAY_HOME_INBOUND` | `false` | Home mode: systems on the local network can post deliveries to the Macs registered for them, on the HTTP listener (see [Home relay](#home-relay)). Only for a relay on the home network: the relay reads deliveries in clear, so a public relay must never turn it on. Refused with `RELAY_TLS_DOMAIN`. |
| `RELAY_INBOUND_DOMAIN` | none | Deliveries from the internet, unread: names under this domain (`<inbound name>.<domain>`) are passed through to the Mac holding their certificate (see [Deliveries from the internet](#deliveries-from-the-internet)). Refused with `RELAY_HOME_INBOUND`. |
| `RELAY_INBOUND_ADDR` | `:8444` | With `RELAY_INBOUND_DOMAIN`: the TCP listener for those connections, behind a proxy that passes TLS through and sends the PROXY protocol. Not used in standalone mode, where the HTTPS port sorts them. |
| `RELAY_LOG_LEVEL` | `info` | `debug`, `info`, `warn` or `error`. `debug` adds registrations and refusals. |

Booleans accept `true`/`false`, `1`/`0`, `yes`/`no`, `on`/`off`. A malformed value stops the relay at start,
with a message saying which variable is wrong.

## Home relay

The same program, run on a machine of the home network (a NAS, a home server, a Raspberry Pi with Docker), can also
pass **deliveries** to OpenMaé on the Mac: short texts that systems on that network post over plain HTTP, for
example Home Assistant telling Maé that someone rang at the door. No port opens on the Mac: it keeps a connection
to the home relay, which hands it each delivery through that connection and returns its answer (see "Home mode" in
[PROTOCOL.md](PROTOCOL.md)). The Mac keeps using its usual relay for the iPhone.

This is **home mode**, off by default, turned on with `RELAY_HOME_INBOUND=true`. Unlike what goes through tubes,
deliveries are not encrypted end to end: the home relay reads them in clear. Hence two rules:

- **Never forward the home relay's port 8080 from the internet**, nor expose it through a reverse proxy reachable
  from the internet. The relay only takes deliveries from local addresses, but that is a safety net, not a
  protection: behind Docker Desktop (macOS, Windows), a userland proxy or a router's NAT loopback, callers from the
  internet can show up with a local address.
- **A public relay must never turn home mode on**: it would receive deliveries in clear. The relay refuses to start
  in home mode together with standalone mode (`RELAY_TLS_DOMAIN`).

With Docker Compose on the home machine, from the [published image](#published-image), with no copy of the
repository and no login: save this file as `compose.home.yaml`, in a folder of its own.

```yaml
# A home relay: on the home network only.
services:
  relay:
    image: ghcr.io/lgentila/openmae-relay:latest
    restart: unless-stopped
    environment:
      RELAY_HOME_INBOUND: "true"
      # The UDP port published below, as the Mac reaches it.
      RELAY_QUIC_PUBLIC_PORT: "4433"
    ports:
      # Published on the home network, never forwarded from the internet.
      - "8080:8080/tcp"
      - "4433:4433/udp"
    volumes:
      - relay-data:/data

volumes:
  relay-data:
```

```sh
docker compose -f compose.home.yaml up -d
```

Check it: `curl http://<home relay>:8080/healthz` answers `ok`, and `docker compose -f compose.home.yaml logs relay`
shows a `relay started` line with `home_mode=true`. To update it later: `docker compose -f compose.home.yaml pull`,
then `docker compose -f compose.home.yaml up -d` again. (From a copy of the repository instead, put the file in the
`relay` folder, write `build: .` instead of `image: …`, and start it with `up -d --build`.)

If the machine also has an interface on the internet, publish the ports on its home network address only, for
example `"192.168.1.10:8080:8080/tcp"` and `"192.168.1.10:4433:4433/udp"`.

Then:

1. In OpenMaé's settings on the Mac, give `http://<home relay>:8080` as the home relay, `<home relay>` being the
   machine's name or address on the home network. The Mac registers there for deliveries.
2. Each source created on the Mac gets an address on the home relay,
   `http://<home relay>:8080/<inbound name>/in/<secret>`, to paste into the system that sends. The inbound name comes
   from the Mac's key; the secret is the source's, and only the Mac checks it.
3. Try it from the home network: `curl -d 'Hello from the home network' http://<home relay>:8080/<inbound name>/in/<secret>`.

The relay answers `403` to callers outside the local network (10/8, 172.16/12, 192.168/16, 169.254/16, 127/8,
fc00::/7, fe80::/10, ::1: the shared address space 100.64/10 of carrier NAT and Tailscale is not local), `503` while
the Mac is not connected (it keeps nothing: the sender may try again), `429` beyond 30 deliveries a minute or 5 at
once for a Mac, `413` beyond 64 KB, `408` for a body that takes more than 10 seconds; otherwise, it passes on the
Mac's answer. Behind a reverse proxy on the home network, set `RELAY_BEHIND_PROXY=true`, so that the caller's address
comes from `X-Forwarded-For`.

## Deliveries from the internet

A relay reachable from the internet can take deliveries for the Macs registered with it, from systems anywhere (a
server's alert, a web service's webhook), **without being able to read them**. Each Mac gets a name under the relay's
inbound domain, `<inbound name>.in.example.com`, and a certificate for it from Let's Encrypt, whose key never leaves the
Mac. A delivery is `https://<inbound name>.in.example.com/in/<secret>`: the relay reads the TLS ClientHello just far
enough to see the name, then passes the encrypted connection, unopened, to that Mac through the Mac's own connection.
No port opens on the Mac (see "Inbound domain" in [PROTOCOL.md](PROTOCOL.md)).

What the relay sees: the name (so which Mac), the caller's address, when and how many bytes. Never the secret or the
text. The names are public anyway (Let's Encrypt publishes every certificate in the certificate transparency logs); they
hold nothing personal.

To turn it on:

1. **DNS.** A wildcard record `*.in.example.com` pointing at the server (A, and AAAA if the server has IPv6). Behind
   Cloudflare, set it **DNS only** (grey cloud): its proxy would end TLS itself.
2. **Environment.** `RELAY_INBOUND_DOMAIN=in.example.com`. The relay then listens on `RELAY_INBOUND_ADDR` (`:8444` in
   the container) and announces the domain in `/v1/info`. Port 8444 needs no publishing: only the proxy reaches it,
   on its network.
3. **The proxy**, which already serves the relay's HTTPS: it passes the TLS of these names through, unopened, to the
   relay's port 8444 with the PROXY protocol (the relay closes connections without it), and sends Let's Encrypt's
   HTTP-01 challenge for these names (`http://<name>/.well-known/acme-challenge/…`) to the relay's port 8080. With
   Traefik 3: [deploy/traefik/](deploy/traefik/) holds a whole example (static and dynamic configuration, checks, and
   why each part). Two things to keep from it:
   - **Traefik keeps Let's Encrypt's challenges for itself** as soon as it has a certificate resolver of its own: allow
     other routers to take them with `allowACMEByPass: true` on the `web` entry point (Traefik 3.1 or later), then
     restart Traefik.
   - That also lowers the priority of Traefik's own challenge router: put it back on top with the example's
     `traefik-acme` router, or another site's redirection to HTTPS may take the challenges of Traefik's own
     certificates, and their renewals fail.

   Check: `curl -i http://abcdefghijklmnopqrstuvwxyz.in.example.com/.well-known/acme-challenge/test` must answer
   `404` with the relay's `404 page not found`. An empty `404` comes from Traefik's own challenge handler (in older
   versions, after a long wait): `allowACMEByPass` is missing.

   **Standalone mode** (`RELAY_TLS_DOMAIN`, no proxy): nothing more to do. The relay sorts its own HTTPS port by server
   name, and its HTTP listener (port 80) answers the challenges. `RELAY_INBOUND_ADDR` is not used.
4. **Let's Encrypt's limits.** Each Mac's certificate counts against Let's Encrypt's limit of 50 new certificates per
   registered domain per week (here `example.com`), renewals aside. That is plenty for a relay of one's own. A large
   public relay needs Let's Encrypt to raise it, or its inbound domain on the
   [Public Suffix List](https://publicsuffix.org), which makes each name a registered domain of its own.

Then, in OpenMaé on the Mac, with this relay chosen as the internet relay (Settings › Relay), a source that goes
through the internet relay gets its `https://` address once the Mac has its certificate, a few seconds after the
first such source is added. Try it from anywhere:
`curl -d 'Hello from the internet' https://<inbound name>.in.example.com/in/<secret>`.

Limits, per inbound name (that is, per Mac): 30 connections per minute and 5 at once. Per caller: 20 a minute (per /64
for IPv6). Per connection: 1 MB both ways together and 15 seconds. Beyond, or with no Mac connected, the connection is
closed: nothing is kept.

## Deploying behind a reverse proxy

For a relay at `relay.example.com`, built from `relay/Dockerfile` (build context `relay`) or pulled as the
[published image](#published-image), or as a Compose service from `relay/compose.yaml`, on a host whose reverse proxy
already serves HTTPS:

1. **Domain.** Route `relay.example.com` to container port **8080**, HTTPS on, certificate from Let's Encrypt. The
   proxy then serves HTTPS, `/v1/info` and the WebSocket fallback.
2. **Environment.** `RELAY_BEHIND_PROXY=true`, and `RELAY_QUIC_PUBLIC_PORT` set to the published UDP port
   (step 3).
3. **UDP port for QUIC.** Publish a host UDP port to container port **4433**, protocol **UDP**; on Docker Swarm,
   publish mode **Host**:
   - **443** is best (`RELAY_QUIC_PUBLIC_PORT=443`): it passes most firewalls.
   - Many proxies enable HTTP/3 by default and hold **UDP 443** themselves. On such a server, publish **8443**
     instead and set `RELAY_QUIC_PUBLIC_PORT=8443`, or turn HTTP/3 off in the proxy to give UDP 443 to the relay.
     `/v1/info` announces whichever port you choose, so the apps need no update.
   - Not Swarm's **Ingress** mode: its ingress network replaces the client's address with its own, so every QUIC
     client would share one rate limit of 10 attempts a minute. (A Compose service publishes ports directly and
     keeps the addresses.)
4. **Volume.** Mount a named volume on **`/data`**. It holds the QUIC key; if it is lost, the key pin changes
   (the apps recover by fetching `/v1/info` again, but keep it anyway).
5. **Deliveries from the internet** (optional): see [Deliveries from the internet](#deliveries-from-the-internet),
   with `RELAY_INBOUND_DOMAIN=in.example.com`, the wildcard record `*.in.example.com`, and the proxy's configuration
   (with Traefik: [deploy/traefik/](deploy/traefik/)).
6. **Health check.** The image's `HEALTHCHECK` runs `/relay -healthcheck`, which asks `/healthz` on port 8080
   (the image has no shell or curl). Docker marks the container unhealthy when it fails, and Docker Swarm replaces
   it. For outside monitoring, watch `https://relay.example.com/healthz`.
7. **Firewall.** Open the UDP port (443 or 8443) in the server's firewall and in the hosting provider's
   firewall, if it has one. TCP 80 and 443 are already open for the proxy.

Check from anywhere: `curl https://relay.example.com/v1/info` shows the QUIC port and the key pin.

### Proxies

- **Traefik**: a whole example in [deploy/traefik/](deploy/traefik/), or the labels commented out in `compose.yaml`
  for the relay's HTTPS only. Traefik replaces or extends `X-Forwarded-For` with the address it sees, which is what
  `RELAY_BEHIND_PROXY` expects.
- **Caddy**: `relay.example.com { reverse_proxy relay:8080 }` is enough, WebSocket included. Caddy serves HTTP/3
  on UDP 443 by default: use another UDP port for QUIC, or limit Caddy to `protocols h1 h2`.
- **A CDN in front** (Cloudflare and others) would make the last `X-Forwarded-For` entry the CDN's address, so
  rate limiting would apply per CDN node. QUIC cannot go through such a proxy anyway; keep the relay's domain
  DNS-only.

quic-go may log, once, that it could not raise the UDP buffer sizes. The relay's traffic is small and works
without it; to silence it, raise `net.core.rmem_max` and `net.core.wmem_max` on the host (see the
[quic-go wiki](https://github.com/quic-go/quic-go/wiki/UDP-Buffer-Sizes)).

## QUIC certificate and key rotation

The QUIC listener presents a self-signed ECDSA P-256 certificate, created at first start in `RELAY_DATA_DIR`
and reused afterwards. Clients accept it only if its key matches one of the pins of `/v1/info`
(`quic.spki_sha256`: SHA-256 of the DER SubjectPublicKeyInfo, standard base64), which they fetch over HTTPS
with a public certificate. The current pin is also printed at start (`relay started … pin=…`).

The pin depends on the key alone (`quic-key.pem`, readable by the relay only). The certificate
(`quic-cert.pem`) is made again from the key when it is missing, does not match, or has less than a year left:
the pin does not change.

To change the key, for example if `/data` may have leaked:

1. Note the current pin: `curl -s https://relay.example.com/v1/info`.
2. Stop the relay and move `quic-key.pem` and `quic-cert.pem` out of the volume, keeping a copy. With the
   distroless image, use another container, for example
   `docker run --rm -v openmae-relay-data:/data alpine sh -c 'mkdir -p /data/old && mv /data/quic-*.pem /data/old/'`.
3. Set `RELAY_PREVIOUS_PINS` to the old pin and start the relay. It creates a new key; `/v1/info` lists the new
   pin first, then the old one.
4. After a month, remove `RELAY_PREVIOUS_PINS`.

Keeping the old pin listed for a month, as the protocol asks, lets you put the old key back (restore the two
files) if something goes wrong, without the apps refusing it.

## Limits

From the protocol, announced in `/v1/info`:

- 3 tubes at once per Mac, those still waiting for the Mac counted: the next iPhone gets `busy`.
- 256 kbit/s per tube and per direction, with a one-second burst. Beyond it, tube bytes are slowed down (never
  lost) and datagrams are dropped. Bytes and datagrams share each direction's budget.
- 10 `hello` or `connect` messages per minute per IP address (per /64 for IPv6, the usual size of one network):
  beyond, `rate_limited`. `accept` is not counted: it needs a valid one-time tube token.
- Control messages of 4096 bytes at most.

Bounds of this relay, so that nothing grows without limit:

- every waiting step has a timeout: 10 s to open the QUIC stream and send the first message, 10 s to answer the
  challenge, 10 s for the Mac to accept a tube (`mac_timeout`), 75 s of silence on a control connection, 75 s
  without traffic either way in a tube;
- a registered Mac sends about one message per second at most (it pings every 25 s), with a burst of 20;
- 1024 iPhones waiting for an accept, all Macs together (`busy` beyond), and `RELAY_MAX_CONNECTIONS` connections;
- past 128 QUIC handshakes in progress, new clients must first prove their address (a QUIC Retry, which clients
  follow on their own), so that a flood of spoofed packets cannot take the connection slots;
- QUIC flow-control windows of 256 KiB, datagrams of 16383 bytes at most, 4 bidirectional streams at most and no
  unidirectional one. The main stream is the first stream that carries data: Apple's Network.framework, when it
  carries datagrams, sends on stream 4 and leaves stream 0 empty, and the relay leaves such empty streams alone.
  Data on any other stream gets `bad_request` (during a tube, the tube closes);
- a client that does not read what the relay writes to it for 30 s (10 s on a control connection) is
  disconnected.

In home mode, per inbound name (that is, per Mac): 30 deliveries per minute and 5 at once (`429` beyond), bodies of
64 KB at most (`413`), 10 s to receive a body (`408`), then 10 s for the Mac to accept the delivery's tube and 10 s
for it to answer, in 4 KB at most (`503`, `502`). Deliveries also count among the tubes waiting for an accept, but not
against a Mac's 3 tubes, which are for iPhones.

Anything that does not follow the protocol gets `bad_request` (when still possible) and the connection is closed.
A QUIC client that has not enabled datagrams can keep a control connection, but cannot open or accept a tube
(`bad_request`): without datagrams there would be no sound.

## Logs

Logs go to standard output, one `key=value` line per event: start and stop (ports, key pin), tubes opened and
closed (transports, duration, bytes and datagrams each way, datagrams dropped, why it closed), and every 10
minutes a line of counts (Macs registered, tubes, connections, refusals by error code). `RELAY_LOG_LEVEL=debug`
adds registrations and refusals. In home mode, each delivery passed to a Mac adds a line with its status, size and
duration, and the counts add the Macs registered for deliveries and the deliveries turned away, by status. With an
inbound domain, each connection passed to a Mac adds a `passthrough` line (why it ended, bytes each way, duration),
and the counts add those turned away by reason (`passthrough_unknown_name`, `passthrough_no_proxy_header`,
`passthrough_mac_offline`, `passthrough_rate_limited`…) and the challenge answers not found (`challenge_404`).

They never contain device ids, tube tokens or IP addresses, not even the relay's own: errors are logged by
kind, not by their text, and messages from libraries have their addresses removed. Nor inbound names, secrets or
anything of a delivery's contents.

## Push notifications

Not implemented: `/v1/info` says `"push": false`. Only a relay holding the app's APNs key could send them. The
`Pusher` interface in `internal/relay/push.go` is the place where such a sender would plug in; the protocol does
not define the messages that would use it yet.

## Development

```sh
go vet ./...
go test -race ./...
```

[.github/workflows/relay-image.yml](../.github/workflows/relay-image.yml) runs the same checks, then builds the image
for both platforms: on a pull request that changes `relay/`, without publishing it; on `main` and for a `relay-v*`
tag, publishing it (see [Published image](#published-image)).

The tests start the relay in-process on random local ports and drive it with test Macs and iPhones over QUIC and
WebSocket: registration, tubes across every transport combination (bytes and datagrams both ways), every error
code, rate limits, throttling, teardown, idle timeouts and shutdown; in home mode, deliveries from end to end, and
each status the relay answers; with an inbound domain, TLS connections sorted by server name and passed through
unopened, the PROXY protocol, Let's Encrypt's challenge answers, the limits, and standalone mode's sorting.

Code layout: `main.go` reads the environment; `internal/relay` holds the relay. Start with `server.go`
(listeners, shutdown) and `session.go` (what each control message does); then `tube.go` (piping), `quic.go` and
`websocket.go` (the two transports), `hub.go` (registrations and pending tubes, in memory), `control.go`
(messages, device ids, signatures), `limit.go` (rate limits), `cert.go` (QUIC key and pins), `inbound.go`
(home mode: deliveries) and `passthrough.go` (the inbound domain: deliveries from the internet, passed through).

## Licences

The relay's own licence is the repository's (see the main README).

It is built with:

| Module | Version | Licence |
|---|---|---|
| [github.com/quic-go/quic-go](https://github.com/quic-go/quic-go) | v0.63.0 | MIT |
| [github.com/gorilla/websocket](https://github.com/gorilla/websocket) | v1.5.3 | BSD-2-Clause |
| [golang.org/x/crypto](https://pkg.go.dev/golang.org/x/crypto) (`acme/autocert`) | v0.58.0 | BSD-3-Clause |
| golang.org/x/net, golang.org/x/sys, golang.org/x/text (required by the above) | v0.60.0, v0.49.0, v0.43.0 | BSD-3-Clause |
| The Go standard library | 1.26 | BSD-3-Clause |

The container image is based on `gcr.io/distroless/static-debian13` (Apache-2.0; it contains CA certificates,
time zone data and `/etc/passwd`, under their own licences).
