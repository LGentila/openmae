# The relay behind Traefik

An example configuration for Traefik 3: the relay's HTTPS, and the deliveries from the internet (see "Deliveries from
the internet" in [../../README.md](../../README.md)). The routers for the deliveries from the internet (`openmae-acme`,
`openmae-inbound`, `traefik-acme`) were tried with Traefik 3.6.

| File | What it holds |
|---|---|
| [`traefik.yml`](traefik.yml) | Static configuration: the entry points (`allowACMEByPass`, HTTP/3), the file provider, a Let's Encrypt resolver. Merge it into your own. |
| [`openmae-relay.yml`](openmae-relay.yml) | Dynamic configuration, for the file provider's folder: the relay's HTTPS, Let's Encrypt's challenges for the Macs' names, the TLS of those names passed through to the relay. |

The relay's container is reached on Traefik's Docker network, by its name there: `relay` in these files (the Compose
service of [`../../compose.yaml`](../../compose.yaml)). On a hosting platform that runs Traefik for you, use the name it
gave the relay's service (the one in the configuration it generated), and leave out what the platform already does
(usually the `openmae-relay` and `openmae-relay-to-https` routers: it routes the domain you give it).

## Steps

1. **DNS**: `relay.example.com`, and for the deliveries from the internet a wildcard `*.in.example.com`, both pointing
   at the server (A, and AAAA with IPv6). Behind Cloudflare: DNS only (grey cloud).
2. **The relay's environment**: `RELAY_BEHIND_PROXY=true`, `RELAY_QUIC_PUBLIC_PORT` (the published UDP port, see
   below), and `RELAY_INBOUND_DOMAIN=in.example.com` for the deliveries from the internet. Ports 8080 and 8444 are not
   published: only Traefik reaches them.
3. **QUIC**: publish a UDP port of the host to the container's port 4433 (in host mode on Docker Swarm). With HTTP/3 on
   in Traefik, UDP 443 is taken: use 8443. Open it in the firewalls.
4. **Static configuration**: the parts of `traefik.yml`, then restart Traefik.
5. **Dynamic configuration**: `openmae-relay.yml` in the file provider's folder, with the names replaced (the list is at
   the top of the file). Traefik reads it again by itself.

## Checks

```sh
# The relay, through Traefik; with an inbound domain the answer ends with "inbound":{"domain":"in.example.com"}.
curl -s https://relay.example.com/v1/info

# Let's Encrypt's challenge for a Mac's name reaches the relay: 404 with the relay's "404 page not found" (19 bytes).
# An empty 404 is Traefik's own handler (in older versions, after a long wait): allowACMEByPass is missing.
curl -i http://abcdefghijklmnopqrstuvwxyz.in.example.com/.well-known/acme-challenge/test

# The TLS of a Mac's name is passed through: no certificate from Traefik ("TRAEFIK DEFAULT CERT" means the TCP router
# is not active). With no Mac registered under that name, the relay just closes the connection.
echo | openssl s_client -connect relay.example.com:443 -servername abcdefghijklmnopqrstuvwxyz.in.example.com 2>&1 | grep subject=

# Traefik still answers the challenges of its own certificates (any other domain it serves): an empty 404 (in older
# versions, after a long wait), not a redirection or the site's own page.
curl -i -m 60 http://another-site.example.com/.well-known/acme-challenge/test
```

## Why each part

- **`allowACMEByPass`** (Traefik 3.1 or later): Traefik answers every Let's Encrypt HTTP challenge on its entry point
  itself, through an internal router of the highest priority, as soon as one of its resolvers uses that entry point.
  The Macs' challenges, left on the relay, would never be read. With it, user routers may take challenges.
- **`traefik-acme`**: with `allowACMEByPass`, Traefik's internal challenge router keeps only the default priority, the
  length of its rule (42). Any router on the web entry point with a longer rule that matches the request (another
  site's redirection to HTTPS, `Host(`a-long-enough-name.example.com`)`) would take the challenges of Traefik's own
  certificates, and their renewals would fail a month before they expire. `traefik-acme` gives them back to Traefik's
  handler (`acme-http@internal`) above every other router, and `openmae-acme` comes before it for the Macs' names only.
  `acme-http@internal` exists only while a resolver uses the web entry point for its HTTP challenge.
- **`HostSNIRegexp` with `passthrough`**: Traefik reads the name in the TLS ClientHello and passes the connection, still
  encrypted, to the relay, which passes it to the Mac. Every other name stays with the HTTP routers.
- **The PROXY protocol**: the relay needs the caller's address (its limits are per caller) and closes inbound
  connections without it. Before Traefik 3.5 it goes under the service's `loadBalancer` (`proxyProtocol: {version: 2}`)
  instead of a `serversTransport`.
- **No entry-point-wide redirection to HTTPS**: Let's Encrypt asks for the challenges in plain HTTP; per-router
  redirections leave them alone.
