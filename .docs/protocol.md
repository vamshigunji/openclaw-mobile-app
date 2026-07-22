# Gateway protocol — transport, handshake, device auth

Single source of truth for how the app talks to the OpenClaw gateway. Everything
tagged **LIVE** was observed from a real gateway (2026-07-21, over a Cloudflare Quick
Tunnel); the raw session logs are in `archive/live-handshake-findings-2026-07-21.md`.

## 1. The two transports

| | Backbone | Fast path |
|---|---|---|
| What | **Protocol-v4 WebSocket RPC** — JSON `req\|res\|event` frames, port `18789` | OpenAI-style REST |
| Used for | pairing, sessions, `session.message` sends, live subscribe/fan-in, `agents.list` | `GET /health`, single-turn `POST /v1/chat/completions` + SSE |
| Docs | docs.openclaw.ai/gateway/protocol | — |

The REST API **cannot** list agents, hold sessions, or stream cross-agent activity —
it is a convenience, never the backbone. The rejected alternative (`openclaw-app`
relay/Noise-XX; `OpenClawCore`) is an incompatible protocol — reference for crypto
patterns only.

## 2. Reachability — Cloudflare Tunnel (LIVE)

`cloudflared` runs on the gateway box and dials out, exposing the loopback-bound
gateway at a public `https://` → real `wss://` with managed TLS. No opened ports, no
client-side setup, no ATS exception.

- Now: **Quick Tunnel** — `cloudflared tunnel --url http://localhost:18789` →
  ephemeral `https://<random>.trycloudflare.com` (URL changes on restart).
- Later: named tunnel + own domain (no app-side change).
- **Tailscale was tried and rejected** (GUI build can't `serve`; users can't join a
  private tailnet — not a product transport). Rationale: `archive/seam-d-design-note.md`.

## 3. Connect handshake

**Every launch:**
1. Open WS to the tunnel host → gateway emits `connect.challenge` event
   `{ nonce: <uuid>, ts: <ms> }`.
2. Send `connect` (see §4) — signed with the device key, carrying either the
   `deviceToken` (steady state) or the setup code's `bootstrapToken` (first pairing).
3. Receive `hello-ok` `{ snapshot, stateVersion, seq, auth: { scopes, deviceToken? } }`.
4. Re-subscribe (`sessions.subscribe`, `sessions.messages.subscribe`), render from
   snapshot, apply live events.

**First pairing only:** after the signed bootstrap connect, expect
`PAIRING_REQUIRED / wait_then_retry` until the operator approves the device
(`device.pair.approve` / CLI). Then `hello-ok` returns a scoped **deviceToken** —
persist it (Keychain in the app); the private key never leaves the device.

**Reconnect:** exponential backoff 1s→30s; >~30s silence = dead; diff
`stateVersion`/`seq` on reconnect, re-snapshot if history pruned. On
`AUTH_TOKEN_MISMATCH`: one bounded retry, then stop.

## 4. The connect frame (LIVE-verified fields)

```jsonc
{
  "type": "req", "id": "…", "method": "connect",
  "params": {
    "minProtocol": 4, "maxProtocol": 4,
    "client": { "id": "openclaw-ios", "mode": "node", "version": "…", "platform": "ios" },
    "role": "operator",
    "scopes": ["operator.read", "operator.write"],   // send pre-normalized (sorted, implied included)
    "auth": { "token": "…" },                        // OR { "bootstrapToken": "<setup code>" } — token wins
    "device": {                                      // REQUIRED for any scopes (see §5)
      "id": "<hex sha256(raw ed25519 pubkey)>",
      "publicKey": "<base64url raw 32 bytes>",
      "signature": "<base64url ed25519 sig>",
      "signedAt": 1753000000000,
      "nonce": "<challenge nonce>"
    }
  }
}
```

Hard-won enum facts (each 400s before auth if wrong):
- `client.id` closed enum — **`openclaw-ios`** for the app (`cli` also passes; the
  once-documented `ios-node` is now rejected). Full registry: `webchat-ui`,
  `openclaw-control-ui`, `openclaw-tui`, `webchat`, `cli`, `gateway-client`,
  `openclaw-macos`, `openclaw-ios`, `openclaw-android`, `node-host`, `test`,
  `fingerprint`, `openclaw-probe`.
- `client.mode` closed enum: `webchat|cli|ui|backend|node|probe|test`. "operator" is
  a **role**, not a mode.
- The setup code goes in **`auth.bootstrapToken`** — `auth.token` →
  `AUTH_TOKEN_MISMATCH`; `auth.setupCode`/`code`/`pairingCode` → schema reject.

## 5. Device auth — the v3 signature (SOLVED 2026-07-21)

A token-only connect (no `device{}`) authenticates but gets **`scopes: []`** — inert.
Pairing is mandatory. The signature covers `buildDeviceAuthPayloadV3`, sourced from
the **public `openclaw` npm package** (v2026.7.1-2 bundles
`packages/gateway-client/src/device-auth.ts` in `dist/`). It is a **pipe-delimited
string, not JSON**:

```
v3|deviceId|clientId|clientMode|role|scopes.join(",")|signedAtMs|token|nonce|platform|deviceFamily
```

- `deviceId = hex( sha256( raw ed25519 public-key bytes ) )` (LIVE-confirmed).
- `token` = the *signatureToken* = `auth.token ?? auth.bootstrapToken ?? ""` — the
  bootstrap token is bound into the first signature.
- `clientId/clientMode/role/scopes` must equal the frame's fields; scopes comma-joined.
- `platform`/`deviceFamily` ASCII-lowercased; absent → `""` (still a trailing field).
- `signature = base64url( ed25519.sign( utf8(payload) ) )`;
  `publicKey = base64url(raw 32 bytes)`; `signedAt` must be fresh (skew →
  `DEVICE_AUTH_SIGNATURE_EXPIRED`); `nonce` must echo the challenge.
- A `v2` payload (same minus platform/deviceFamily) is still accepted.
- Key type is **Ed25519** → the key lives in the **Keychain**, not the Secure
  Enclave (SE only supports P-256).

Reference implementation: `tools/phase0-verify.mjs` (`buildDeviceAuthPayloadV3`,
`buildDeviceParams`; selftest pins the exact serialization). Probe usage:

```bash
node tools/phase0-verify.mjs https://<tunnel>.trycloudflare.com --pair <setupCode>
# identity persists in tools/.phase0-device.json (gitignored; holds the private key)
```

### The error ladder (LIVE — each gate reached by fixing the previous)

| Gate | Error when wrong |
|---|---|
| `client.id`/`client.mode` enum | `INVALID_REQUEST` (400 before auth) |
| setup code in wrong field | `AUTH_TOKEN_MISMATCH` / schema reject |
| missing `device{}` | `NOT_PAIRED / DEVICE_IDENTITY_REQUIRED` |
| wrong `device.id` derivation | `DEVICE_AUTH_DEVICE_ID_MISMATCH` |
| wrong signature payload | `DEVICE_AUTH_SIGNATURE_INVALID` |
| stale `signedAt` | `DEVICE_AUTH_SIGNATURE_EXPIRED` |
| wrong nonce | `DEVICE_AUTH_NONCE_MISMATCH` |
| unapproved device | `PAIRING_REQUIRED / wait_then_retry` (retryable) |

## 6. Scopes

- Setup-code pairing mints a per-device token with scopes
  `[operator.approvals, operator.read, operator.talk.secrets, operator.write]`.
- Normalization (server-side): trims, dedupes, sorts; `operator.admin` implies
  read+write; `operator.write` implies read. Send scopes already normalized so both
  sides serialize identically.

## 7. Method map

Verified against docs + reference client: `connect.challenge` → `connect` →
`hello-ok`; `agents.list/create/update/delete`; `sessions.groups.*`;
`sessions.subscribe` / `sessions.messages.subscribe` (events: `chat`,
`session.message`, `session.operation`, `session.tool`, `sessions.changed`,
`presence`); `sessions.messages.list`; REST `GET /health` (LIVE),
`GET /v1/models`, `POST /v1/chat/completions`.

## 8. Decision log

- **2026-07-12** — target = gateway protocol-v4 WS RPC; relay/Noise-XX architecture
  rejected. Token-only connect verified to yield `scopes: []` → pairing mandatory.
- **2026-07-21** — Cloudflare Tunnel replaces Tailscale (rejected). Live ladder run:
  `client.id=openclaw-ios`, `auth.bootstrapToken`, `device.id` derivation confirmed.
- **2026-07-21 (later)** — v3 signature serialization solved from the public npm
  package; implemented + selftested in `tools/phase0-verify.mjs`.

## 9. Chat API (LIVE-verified 2026-07-21, `tools/phase0-roundtrip.mjs`)

Pairing + full round-trip verified live; the app is texting the agent for real.

- **Send = `chat.send`** `{sessionKey, message: <string>, idempotencyKey}`, scope
  `operator.write`. Ack: `{runId, status:"started"}` — the gateway adopts the
  idempotencyKey as the runId. `session.message` as a *method* requires
  `operator.admin` — do not use it for sends.
- **Subscribe = `sessions.subscribe {}`** (connection-scoped, no key) → streams
  `chat` deltas, `session.message`, `sessions.changed`, `agent`, `health`, `tick`.
- **History = `chat.history`** `{sessionKey, limit≤1000}`, scope `operator.read`.
- Session key `"main"` canonicalizes to `agent:main:main`.
- **Streaming**: `chat` events, `state: delta|final|aborted|error`; delta carries
  `deltaText` + `message.content` = text-so-far; `final` carries the complete
  message.
- **Content shapes**: user `message.content` is a string; assistant content is an
  array of `{type:"text", text}` blocks.
- **Echo keys**: our send's user echo has idempotencyKey `<runId>:user`; the
  assistant transcript message has `cli-assistant:<runId>` (app normalizes both
  for dedup/merge, see `InboundEnvelope`).
- **Bootstrap tokens** are short-lived but survive `PAIRING_REQUIRED` retries; a
  pairing request stays pending ≥1 min. Approval: `openclaw devices approve <requestId>`.
- **Port gotcha**: `https://` tunnel hosts are implicit-443 — never append the
  `18789` default to a TLS host (live bug, fixed in `wsURL`).
- deviceToken from hello-ok is re-issued on every connect; persist the latest.

## 10. Open unknowns

- Exact scope required by `agents.create/update/delete`, `sessions.groups.*`
  (`operator.write` vs `operator.admin`).
- Write rate limits on `agents.create` / `sessions.groups.*`.
- Two-device probes P1/P7 (fan-out + remote scope parity) — see `sync.md`.
