# Product — OpenClaw Mobile chat client

## 1. What & why

**OpenClaw Mobile** is a phone-first chat client that lets developers talk directly to
their autonomous OpenClaw agents running on private servers. Not a cockpit (that's a
later milestone): a **simple, reliable text interface** — configure the gateway, see
your agents, text one, stream its reply.

**Problem:** agents run for hours on remote boxes; developers step away from the desk
but still need to check status, review output, or say "run the tests again". There is
no lightweight mobile way to do that.

**Persona:** developer / devops engineer — commuting, walking, in a meeting. Expects
fast load, monospaced clarity for logs/code, reliable exchange.

## 2. Core features (v1)

### Connection & settings
- Gateway endpoint input (the Cloudflare Tunnel `https://…` URL; `localhost` for dev).
- Device pairing from a **setup code** (see `protocol.md` — a bare token has no scopes).
- Connection test against `GET /health`; token/keys in Keychain, prefs in UserDefaults.

### Agent directory
- List agents via WS `agents.list` (paired device required), with status badges
  (working / waiting / blocked / failed / done), name/ID search.

### Chat
- Slack-style thread: user bubbles right (green-tinted), agent bubbles left (dark),
  monospaced rendering for code/logs/paths.
- Sends over WS `session.message` with a client idempotency key; streamed reply fills
  a live assistant bubble. (`POST /v1/chat/completions` remains a single-turn fast
  path only.)
- Optimistic UI: user message appends + persists immediately; failures mark the
  bubble with retry. Histories cached locally as JSON.

## 3. Design language

Dark mode only. Tokens live in `Sources/DesignSystem/Theme.swift` — never inline.

- Backgrounds `#0E0F12` / `#1E2026`; accent terminal green `#22C55E`.
- Status colors: working `#22C55E` · waiting `#F59E0B` · blocked `#A855F7` ·
  failed `#EF4444` · done/idle `#6B7280`.
- **4px corner radius everywhere; elevation via 1px borders, never shadows.**
- Type: Space Grotesk (headers) · Inter/SF Pro (body) · SF Mono/Roboto Mono (code).

## 4. Non-functional

- **Security:** phone → gateway over `wss://` through the tunnel; no third-party
  protocol relay; secrets in Keychain; no telemetry.
- **Performance:** < 1.5s to interactive; optimistic local feedback on send.
- **Compatibility:** iOS 17.0+, SwiftUI, Swift 5.10.

## 5. Out of scope (v1)

Cockpit/agent control · push notifications · multi-account/multi-gateway ·
cross-agent search · message editing · attachments · the BFF (designed at the seam,
`sync.md`).
