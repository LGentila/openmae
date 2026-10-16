# OpenMaé link protocol

How the iPhone app talks to OpenMaé on the Mac, directly on the local network or through an OpenMaé relay.
Everything the user says or hears, and every text, is encrypted end to end between the iPhone and the Mac: a
relay only passes opaque bytes along.

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
  "push": false
}
```

- `quic.port`: the public UDP port of the QUIC listener (the relay may listen on another port inside its
  container).
- `quic.spki_sha256`: SHA-256 of the DER `SubjectPublicKeyInfo` of the relay's QUIC certificate, in standard
  base64 with padding. The QUIC certificate is self-signed and kept by the relay; clients accept it only if its
  key matches one of these pins. The first pin is the current key; during a key change the previous one stays
  listed for a month.
- `push`: whether this relay can send push notifications (only the official relay holds the APNs key).

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
`busy` (the Mac already has its maximum of tubes), `unknown_tube`, `rate_limited`, `unsupported_version`.

### Limits

- 3 tubes at once per Mac.
- 256 kbit/s per tube and per direction: beyond, datagrams are dropped and tube bytes are slowed down.
- 10 `hello` or `connect` attempts per minute per IP address.
- No other traffic: a connection that does not follow this protocol is closed.

The relay keeps everything in memory (no database). After a restart, Macs register again within 30 seconds.

### What a relay sees

IP addresses, device ids, when and how much traffic passes. Never sound, text or notification contents: those
are encrypted by the end-to-end layer. The relay logs errors without device ids, tube tokens or addresses.

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

**Session payloads**: first message `{"v":1}`; second message `{"name":"<Mac name>","relay":"<relay URL>"}`. The
Mac accepts only iPhone static keys of its paired list.

`relay` is the relay the Mac is registered with, left out when it has none (reachable at home only). The iPhone
keeps it for its next connections: it follows the relay its Mac chose, whatever the pairing link said.

### Messages

Each transport message is one JSON object with a `"type"`:

| Type | Direction | Meaning |
|---|---|---|
| `command` | iPhone → Mac | `{"type":"command","command":…}`: an assistant command. The Mac accepts `stopSpeaking`, `newConversation`, `talkKey` and, from `updateSettings`, only `pushToTalk`. |
| `event` | Mac → iPhone | `{"type":"event","event":…}`: an assistant event (state, transcript, answer, readiness, problems). |
| `audio` | both | audio control, see below |
| `removed` | Mac → iPhone | this iPhone was removed from the Mac's settings; the session closes |
| `mac` | Mac → iPhone | `{"type":"mac","name":…,"relay":…}`: the Mac's name or relay changed (as in the handshake) |
| `ping`, `pong` | both | keep-alive, every 25 seconds without other traffic |

Audio control (`{"type":"audio","op":…}`):

- iPhone → Mac `start`: the iPhone takes the conversation; the Mac stops using its own microphone and speakers.
- iPhone → Mac `stop`: the iPhone lets go; the Mac takes its microphone and speakers back.
- Mac → iPhone `released`: the Mac took the conversation back (someone used it on the Mac).
- Mac → iPhone `end` (`stream`, `frames`): the voice stream `stream` has `frames` frames in all.
- Mac → iPhone `stop` (`stream`): stop playing the voice stream `stream` at once (the user interrupted).
- iPhone → Mac `finished` (`stream`): everything of that stream has been played, or stopped.

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
