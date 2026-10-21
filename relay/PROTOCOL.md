# OpenMaé link protocol

How the iPhone and iPad app talks to OpenMaé on the Mac, directly on the local network or through an OpenMaé relay
(below, "iPhone" stands for either).
Everything the user says or hears, and every text, is encrypted end to end between the iPhone and the Mac: a
relay only passes opaque bytes along. The one exception is a relay's [home mode](#home-mode-deliveries), off by
default: systems on the home network post short texts to the Mac through a relay on that network, which reads them.
Texts posted from the internet through a relay's [inbound domain](#inbound-domain-deliveries-from-the-internet) stay
encrypted: the relay passes their TLS through to the Mac, which holds the certificate.

There are two layers:

1. **The relay layer** (`openmae-relay/1`): how a Mac and an iPhone find each other on a relay and get a
   bidirectional *tube* between them. Only this layer is visible to the relay.
2. **The end-to-end layer** (`openmae/1`): what goes through a tube, or through a direct connection on the local
   network. A relay never sees it in clear.

All integers are big-endian unless stated otherwise. `b64url` is base64url without padding (RFC 4648 §5).

## Device identities

Each device (Mac or iPhone) has two key pairs, created once and kept in its keychain:

- an **X25519** key pair for Noise (end-to-end encryption);
- an **Ed25519** key pair to prove its identity to a relay.

The **device id** is the first 16 bytes of SHA-256 of the raw 32-byte Ed25519 public key, in base32 (RFC 4648
alphabet, lowercase, no padding): 26 characters.

## 1. Relay layer

### Discovery: `GET /v1/info`

Served over HTTPS (behind the usual reverse proxy, with a public certificate). The answer:

```json
{
  "name": "OpenMaé relay",
  "versions": [1],
  "quic": { "port": 443, "alpn": "openmae-relay/1", "spki_sha256": ["<base64>", "…"] },
  "websocket": { "path": "/v1/ws" },
  "limits": { "tubes_per_mac": 3, "kbit_per_tube": 256, "attempts_per_minute": 10 },
  "push": false,
  "inbound": { "domain": "in.openmae.com" }
}
```

- `quic.port`: the public UDP port of the QUIC listener (the relay may listen on another port inside its
  container).
- `quic.spki_sha256`: SHA-256 of the DER `SubjectPublicKeyInfo` of the relay's QUIC certificate, in standard
  base64 with padding. The QUIC certificate is self-signed and kept by the relay; clients accept it only if its
  key matches one of these pins. The first pin is the current key; during a key change the previous one stays
  listed for a month.
- `push`: whether this relay can send push notifications (only the official relay holds the APNs key).
- `inbound`: present only on a relay with an inbound domain (`RELAY_INBOUND_DOMAIN`): it takes deliveries from the
  internet for the Macs, at `<inbound name>.<domain>` (see [Inbound domain](#inbound-domain-deliveries-from-the-internet)).
  Clients that do not know it ignore it.

`GET /healthz` answers `200 ok`.

### Transports

**QUIC** (preferred): UDP, ALPN `openmae-relay/1`, TLS 1.3, QUIC datagrams enabled (RFC 9221, maximum
datagram frame size at least 1200 bytes). The client opens one bidirectional stream, its *main stream*, and sends
nothing on any other stream. The relay takes as main stream the first bidirectional stream that carries data:
some QUIC stacks open an empty stream first (Apple's Network.framework uses stream 4, not 0), and the relay
accepts up to 4 streams so that this one is not refused.

- Before piping, the main stream carries **control frames**: a 4-byte length, then that many bytes of UTF-8 JSON
  (at most 4096).
- Once piping starts (see below), the main stream carries the tube's bytes, unchanged, and QUIC datagrams carry
  the tube's datagrams, unchanged.

**WebSocket** (fallback when UDP is blocked): `GET /v1/ws`, upgraded, over TLS on port 443.

- Before piping, control messages are WebSocket **text** messages (one JSON object each).
- Once piping starts, every WebSocket **binary** message is one record: its first byte is `0x01` (tube bytes, any
  chunking) or `0x02` (one datagram), followed by the payload.

A relay copies between a QUIC peer and a WebSocket peer as well: tube bytes are tube bytes, datagrams are
datagrams. A datagram too large for the receiving side is dropped.

### Control messages

JSON objects with an `"op"` field. Unknown fields are ignored.

**A Mac stays registered** on its *control connection*:

| From | Message |
|---|---|
| Mac | `{"op":"hello","v":1,"role":"mac","id":"<device id>","key":"<Ed25519 public key, b64url>"}` |
| relay | `{"op":"challenge","nonce":"<32 random bytes, b64url>"}` |
| Mac | `{"op":"register","sig":"<b64url Ed25519 signature>"}` |
| relay | `{"op":"registered"}` |

The signed bytes are the ASCII string `openmae-relay/1 register:` followed by the 32 raw nonce bytes. The relay
checks that `id` matches `key` and that the signature is valid. A new registration for the same id replaces the
previous one, whose connection is closed.

`hello` may also carry `"inbound": true`, which registers the Mac for deliveries instead (see
[Home mode](#home-mode-deliveries) and [Inbound domain](#inbound-domain-deliveries-from-the-internet)). Without it, or
with `false`, the registration is the one above.

Then, while the control connection lasts:

- relay → Mac `{"op":"incoming","tube":"<16 random bytes, b64url>"}`: an iPhone asks for this Mac.
- `{"op":"ping"}` from either side is answered with `{"op":"pong"}`. The Mac pings every 25 seconds; the relay
  closes a control connection that sent nothing for 75 seconds.

**An iPhone asks for a Mac** on a new connection:

| From | Message |
|---|---|
| iPhone | `{"op":"connect","v":1,"to":"<Mac device id>"}` |
| relay | `{"op":"connected"}`, then piping |

**The Mac accepts** by opening one more connection, its *tube connection*, within 10 seconds:

| From | Message |
|---|---|
| Mac | `{"op":"accept","v":1,"tube":"<tube token from incoming>"}` |
| relay | `{"op":"accepted"}`, then piping |

The relay answers `connected` to the iPhone once the Mac's tube connection is accepted. From then on it copies the
bytes and datagrams of each side to the other, unchanged, until one side closes; it then closes the other side.

**Errors**: `{"op":"error","code":"<code>"}`, then the relay closes the connection. Codes: `bad_request`,
`bad_signature`, `mac_offline` (no Mac registered with that id), `mac_timeout` (the Mac did not accept in time),
`busy` (the Mac already has its maximum of tubes), `unknown_tube`, `rate_limited`, `unsupported_version`,
`inbound_off` (a `hello` with `"inbound": true` to a relay neither in home mode nor with an inbound domain).

### Limits

- 3 tubes at once per Mac.
- 256 kbit/s per tube and per direction: beyond, datagrams are dropped and tube bytes are slowed down.
- 10 `hello` or `connect` attempts per minute per IP address.
- No other traffic: a connection that does not follow this protocol is closed.
- In home mode, per inbound name: 30 deliveries per minute and 5 at once, bodies of 64 KB at most, and 10 seconds
  each to receive a delivery, for the Mac to accept its tube, and for the Mac to answer.
- With an inbound domain: 30 connections per minute and 5 at once per inbound name, 20 per minute per caller's IP
  address (per /64 for IPv6), and 1 MB (both ways together) and 15 seconds per connection.

The relay keeps everything in memory (no database). After a restart, Macs register again within 30 seconds.

### Home mode: deliveries

A relay run on the home network can also pass **deliveries** to a Mac: short texts that systems on that network
(Home Assistant, scripts) post over plain HTTP, without any port open on the Mac. Deliveries are not encrypted end
to end: the relay reads them in clear. That is why home mode is off by default (`RELAY_HOME_INBOUND`), and only for
a relay on the home network: a public relay never turns it on.

**Inbound name.** A Mac gets deliveries under its *inbound name*: the first 16 bytes of SHA-256 of the ASCII string
`openmae-relay/1 inbound:` followed by the raw 32-byte Ed25519 public key, in base32 as a device id (lowercase, no
padding: 26 characters). For the public key whose bytes are 0x00, 0x01, …, 0x1f, the inbound name is
`4zvomamapw57cf63xyx4cjb3qe` (and the device id `mmg42klgyqzwneiskrelxms3j4`).

**Inbound registration.** The Mac opens one more control connection and registers on it as usual, with
`"inbound": true` in its `hello`:

| From | Message |
|---|---|
| Mac | `{"op":"hello","v":1,"role":"mac","id":"<device id>","key":"<Ed25519 public key, b64url>","inbound":true}` |
| relay | `{"op":"challenge","nonce":"<32 random bytes, b64url>"}` |
| Mac | `{"op":"register","sig":"<b64url Ed25519 signature>"}` |
| relay | `{"op":"registered","inbound":"<inbound name>"}` |

- A relay not in home mode answers `{"op":"error","code":"inbound_off"}` instead of the challenge, and closes.
- The relay takes the inbound name from the key the Mac has just proved it holds: no Mac can take another's.
- An inbound registration is kept apart from the Mac's ordinary registration (same device id), even on the same
  relay: neither replaces the other. A new inbound registration of the same Mac replaces the previous inbound one,
  whose connection is closed.
- It never gets `incoming`. Pings, pongs and the 75-second idle rule are as for an ordinary registration.

**A delivery.** The relay sends on the inbound control connection:

`{"op":"inbound","tube":"<16 random bytes, b64url>","from":"<the caller's IP address>"}`

`from` is the caller's address as text, without zone: for example `192.168.1.20` or `fe80::1` (behind a reverse
proxy, with `RELAY_BEHIND_PROXY`, the last `X-Forwarded-For` entry). The Mac accepts within 10 seconds with a tube
connection, as for an iPhone: `{"op":"accept","v":1,"tube":"<tube token>"}`, answered `{"op":"accepted"}`. Over QUIC
that connection needs datagrams enabled, as every tube connection, although they have no use here: the relay drops
the datagrams a Mac sends in a delivery's tube.

The relay then writes the delivery into the tube's bytes, as an HTTP/1.1 request:

```
<method> <path and query, as the caller sent them> HTTP/1.1
Host: <the caller's Host header>
<the caller's other headers>
Content-Length: <length of the body>
Connection: close

<the body>
```

- The caller's other headers come sorted by name, without the hop-by-hop ones (`Connection`, `Keep-Alive`,
  `Proxy-Connection`, `Proxy-Authenticate`, `Proxy-Authorization`, `TE`, `Trailer`, `Transfer-Encoding`, `Upgrade`,
  and any header that `Connection` names), `Content-Length` and `Expect`: the relay already has the whole body.
- The body is whole, and plain even when the caller sent it chunked.
- The relay sends nothing more in the tube, and does not end its side before the answer (over WebSocket, that would
  end the connection).

The Mac answers with an HTTP/1.1 response, with a `Content-Length` and a body of 4 KB at most, within 10 seconds; it
may close the tube after it. The relay passes the status code, the `Content-Type` and the body on to the caller,
then closes the tube. Interim `1xx` answers are skipped.

**The delivery route.** In home mode only, on the relay's plain HTTP listener (never on HTTPS):
`/<inbound name>/in/<secret>`, any method (the Mac answers `405` itself to those it refuses). The secret means
nothing to the relay: the Mac checks it, and everything else in the request. The relay checks, in this order:

| Status | When |
|---|---|
| `403` | the caller's address is not local: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 127.0.0.0/8, fc00::/7, fe80::/10 or ::1 |
| `404` | not an inbound name (26 characters `a–z`, `2–7`), or an empty secret: as for any unknown path, and as for every such path when home mode is off |
| `429` | more than 30 deliveries in the last minute, or 5 in progress, for that inbound name |
| `503` | no Mac registered for deliveries under that name (`Mac not connected`): nothing is kept, the caller may try again later |
| `413` | a body over 64 KB |
| `408` | the body not received within 10 seconds of the request's header section (which has 10 seconds of its own) |
| `400` | a body that cannot be read (broken chunked encoding, connection cut) |
| `503` | the Mac did not accept the tube within 10 seconds (`Mac not answering`), or too many tubes are waiting on the relay (`relay busy`) |
| `502` | the Mac's answer is missing, broken, larger than 4 KB or later than 10 seconds |
| the Mac's | otherwise: its status code, `Content-Type` and body |

The relay's own answers have a short `text/plain` body.

### Inbound domain: deliveries from the internet

A relay reachable from the internet can take deliveries for the Macs registered with it **without being able to read
them**. Its operator gives it an *inbound domain* (`RELAY_INBOUND_DOMAIN`, for example `in.openmae.com`), with a
wildcard DNS record `*.<inbound domain>` pointing at the relay, and `/v1/info` announces it
(`"inbound": {"domain": "…"}`). A Mac's address for deliveries from the internet is then:

`https://<inbound name>.<inbound domain>/in/<secret>`

The inbound name is the Mac's (see [Home mode](#home-mode-deliveries)). The Mac holds a certificate for that name, from
Let's Encrypt, whose key never leaves it: HTTPS stays encrypted all the way to the Mac, and the relay passes the TLS
connection through without opening it. A relay with an inbound domain is never in home mode (the relay refuses to
start with both).

**Inbound registration.** As in home mode: `hello` with `"inbound": true`, answered
`{"op":"registered","inbound":"<inbound name>"}`. A Mac registers so only while it has a source on the internet.

**A connection.** The relay reads the caller's TLS ClientHello just far enough to know its server name (SNI), without
answering it. Unless the name is `<26 characters a–z, 2–7>.<inbound domain>` (in any case), with a Mac registered for
deliveries under that inbound name, the relay closes the connection without a word: it holds no certificate for these
names. Otherwise it sends on that Mac's inbound control connection:

`{"op":"inbound","tube":"<16 random bytes, b64url>","from":"<the caller's IP address>"}`

as in home mode, and the Mac accepts the tube the same way (`accept`, answered `accepted`). The relay then writes into
the tube every byte it has read from the caller, its ClientHello first, and from then on copies the bytes both ways,
unchanged; datagrams have no place in such a tube and are dropped. It closes both sides when the Mac's side ends, a
moment after the caller's side ends, at 1 MB or at 15 seconds. Nothing is kept: with no Mac connected, the caller's
connection is closed.

The connections reach the relay in one of two ways:

- **Behind a proxy that passes TLS through** (Traefik's TCP routers with `tls.passthrough`): on the relay's inbound
  listener (`RELAY_INBOUND_ADDR`, `:8444`), each connection starting with the PROXY protocol header, version 2 or 1,
  which gives the caller's address. A connection without it is closed.
- **Standalone** (`RELAY_TLS_DOMAIN`): on the relay's own HTTPS port, sorted by server name. Names under the inbound
  domain go to the Macs as above; every other name gets the relay's own HTTPS, as before.

**Let's Encrypt's HTTP-01 challenge.** To get its certificate, the Mac leaves the challenge's answer with the relay on
its inbound control connection, before asking Let's Encrypt to check it:

| From | Message |
|---|---|
| Mac | `{"op":"acme_challenge","token":"<the challenge's token>","key_authorization":"<token>.<account key thumbprint>"}` |
| relay | `{"op":"acme_challenge_stored","token":"<the challenge's token>"}` |

- The token is base64url, 22 to 128 characters; the key authorization is the token, a dot and the 43 characters of the
  ACME account key's SHA-256 thumbprint (RFC 8555 §8.1). Anything else, or the message on any other connection than an
  inbound registration on a relay with an inbound domain, gets `bad_request`.
- The relay keeps it in memory for 10 minutes, keyed by inbound name and token (8 tokens per name at most, the oldest
  going first), and answers `GET http://<inbound name>.<inbound domain>/.well-known/acme-challenge/<token>` on its
  plain HTTP listener with the key authorization, `200` and `text/plain`; `404` for any other token or path of these
  names. The answer is public by nature.

### What a relay sees

IP addresses, device ids, when and how much traffic passes. Never sound, text or notification contents: those
are encrypted by the end-to-end layer. The relay logs errors without device ids, tube tokens or addresses.

In home mode, it also sees each delivery in clear: its path (with the source's secret), headers and body, and the
caller's address. It logs deliveries without any of them: only their status, size and duration.

With an inbound domain, it sees for each delivery the server name (so which Mac), the caller's address, when and how
many bytes pass: never the secret or the text, which travel inside TLS. It logs them without the name or the address:
why the connection ended, its bytes each way and its duration.

## 2. End-to-end layer (`openmae/1`)

The same on a direct QUIC connection (ALPN `openmae/1`, the Mac listening and announcing `_openmae._udp` with
Bonjour, the TXT record `id=<Mac device id>`) and inside a relay tube.

On a direct connection TLS is only QUIC's mandatory envelope: the Mac presents a throwaway self-signed certificate
and the iPhone does not check it. Authentication and encryption are Noise's, below.

### Reliable channel

The tube's bytes (or, on a direct connection, the stream the iPhone opens) are a sequence of **frames**: a 4-byte
length, then the frame (at most 65 535 bytes).

The iPhone's first frame starts with one byte telling what it wants, followed by the first Noise handshake
message:

- `0x50` (`P`): pairing, `Noise_XXpsk3_25519_ChaChaPoly_SHA256`, prologue `openmae/1 pairing`, the pre-shared
  key being the 32-byte code of the pairing link;
- `0x53` (`S`): a session, `Noise_IK_25519_ChaChaPoly_SHA256`, prologue `openmae/1`, the iPhone knowing the Mac's
  static key since pairing.

The iPhone is always the initiator. The following frames are the next handshake messages, then Noise transport
messages (the reliable channel's cipher states from `Split()`: the first for iPhone → Mac, the second for
Mac → iPhone).

A Mac that refuses before keys are agreed sends a frame `0x45` (`E`) followed by an ASCII code, in clear, and
closes: `expired` (no pairing code in progress, or a wrong one), `unknown_device` (that iPhone is not, or no longer,
paired), `busy`.

**Pairing payloads**: second message (Mac → iPhone) `{"name":"<Mac name>","relay":"<relay URL>"}`; third message
(iPhone → Mac) `{"name":"<iPhone name>","model":"<model identifier>"}`. The iPhone checks that the Mac's static key
is the one of the pairing link. The Mac then sends a transport message `{"type":"paired"}` and closes.

**Session payloads**: first message `{"v":1,"features":["partialTranscript","conversationCleared"]}`; second message
`{"name":"<Mac name>","relay":"<relay URL>","features":["device"]}`. The Mac accepts only iPhone static keys of its
paired list.

In the second message, `features` lists the optional messages the Mac understands (today `device`, below); it is left
out by Macs from before it. The iPhone sends an optional message only to a Mac that lists it: a Mac from before closed
the session on a message of a type it did not know. From this version on, both sides skip such a message and keep the
session.

In the first message, `features` lists the optional events the iPhone (or iPad) understands (today
`partialTranscript`: the user's words while they speak; `conversationCleared`: the Mac started a new conversation,
the iPhone clears its transcript); it is left out by apps from before it, and the Mac sends them no such event, for
the same reason. The Mac sends each optional event only to the devices that list it.

`relay` is the relay the Mac is registered with, left out when it has none (reachable at home only). The iPhone
keeps it for its next connections: it follows the relay its Mac chose, whatever the pairing link said.

### Messages

Each transport message is one JSON object with a `"type"`:

| Type | Direction | Meaning |
|---|---|---|
| `command` | iPhone → Mac | `{"type":"command","command":…}`: an assistant command. The Mac accepts `stopSpeaking`, `newConversation`, `talkKey` and, from `updateSettings`, only `pushToTalk`. |
| `event` | Mac → iPhone | `{"type":"event","event":…}`: an assistant event (state, transcript, answer, readiness, problems). The user's words while they speak (`partialTranscript`, about twice a second) and a new conversation (`conversationCleared`: whoever asked for it, the iPhone clears its transcript) only go to an iPhone whose `features` list them. |
| `audio` | both | audio control, see below |
| `removed` | Mac → iPhone | this iPhone was removed from the Mac's settings; the session closes |
| `mac` | Mac → iPhone | `{"type":"mac","name":…,"relay":…}`: the Mac's name or relay changed (as in the handshake) |
| `device` | iPad → Mac | `{"type":"device","station":true}` or `false`: whether the iPad is a home station now (station mode on, plugged in, app in the foreground). Sent when the session opens and on every change, only to a Mac whose `features` list it. |
| `ping`, `pong` | both | keep-alive, every 25 seconds without other traffic |

Audio control (`{"type":"audio","op":…}`):

- iPhone → Mac `start`: the iPhone takes the conversation; the Mac stops using its own microphone and speakers.
- iPhone → Mac `stop`: the iPhone lets go; the Mac takes its microphone and speakers back.
- Mac → iPhone `released`: the Mac took the conversation back (someone used it on the Mac).
- Mac → iPhone `end` (`stream`, `frames`): the voice stream `stream` has `frames` frames in all.
- Mac → iPhone `stop` (`stream`): stop playing the voice stream `stream` at once (the user interrupted).
- iPhone → Mac `finished` (`stream`): everything of that stream has been played, or stopped.

A home station gets the voice of what Maé says on her own (a timer that rings) while it does not have the conversation:
the same voice streams, `end`, `stop` and `finished`, without `start`. It plays a voice stream whenever one comes.

### Datagrams

Sound goes in datagrams, which may be lost or reordered. Each one is:

```
0xA0 | counter (8 bytes) | ChaCha20-Poly1305 ciphertext and tag
```

- One key per direction, derived from the reliable channel's keys `k` of `Split()`:
  `HMAC-SHA256(key: k, "openmae/1 datagrams")`.
- Nonce: 4 zero bytes then the counter in little-endian (as in Noise); the counter starts at 0 and grows by one
  for each datagram sent in that direction. The 9 header bytes are the associated data.
- The receiver drops a datagram whose counter it has already seen, or that is older than the 64 most recent ones
  (a sliding window, as in WireGuard).

The plaintext is `stream (4 bytes) | sequence (4 bytes) | one Opus packet of 20 ms`:

- iPhone → Mac: the microphone, 16 kHz mono; `stream` changes each time the iPhone (re)starts its microphone,
  `sequence` counts the frames from 0.
- Mac → iPhone: the assistant's voice, 24 kHz mono; one `stream` per utterance, `sequence` counts its frames from 0.
