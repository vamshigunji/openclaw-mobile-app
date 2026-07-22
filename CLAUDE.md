# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

**OpenClaw Mobile** — a phone-first iOS chat client for talking to autonomous OpenClaw agents running on a private server (Mac Mini / VPS, typically reached over Tailscale). v1 scope is deliberately small: configure gateway host + token, list agents, text an agent, stream its reply. No cockpit control, no push notifications.

Key docs (read before protocol or feature work):

- `.docs/prd.md` — product scope (what & why)
- `.docs/architecture.md` — implementation design (how); PRD wins on scope, architecture wins on implementation detail
- `.docs/connection-handshake.md` — **the protocol decision log**; supersedes protocol assumptions in the other two docs

## Critical protocol context

The PRD/architecture assumed an OpenAI-style REST API (`POST /v1/chat/completions` + SSE). That endpoint exists on the gateway but is a **single-turn convenience only**. The locked decision (2026-07-12, see `.docs/connection-handshake.md`) is:

- **Target = Gateway protocol-v4 native WebSocket RPC** (JSON `req|res|event` frames, port `18789`, docs at docs.openclaw.ai/gateway/protocol). Keep REST+SSE only as the single-turn fast path.
- The alternative `openclaw-app` relay/Noise-XX architecture was **rejected** — incompatible protocol; its `OpenClawCore` is reference material for crypto patterns only.
- **Token-only WS connect authenticates but gets `scopes: []`** — device pairing via setup-code is mandatory for anything beyond chat. `client.id`/`client.mode` are closed enums; wrong values 400 before auth. **LIVE 2026-07-21: `client.id` must be `openclaw-ios` (or `cli`) — the old `ios-node` now 400s.**
- **Reachability = Cloudflare Tunnel** (Quick Tunnel for now → `wss://…trycloudflare.com`; named tunnel + domain later). Tailscale was tried and rejected. See `.docs/seam-d-design-note.md`.
- **Setup-code pairing (verified live):** the setup code's bootstrap token goes in `auth.bootstrapToken` (NOT `auth.token`); connect must also carry a signed `device{ id, publicKey, signature, signedAt, nonce }` where `device.id = hex(sha256(raw ed25519 pubkey))`. The exact signed payload is the gateway's `buildDeviceAuthPayloadV3` (still to be sourced from the gateway box). Full ladder: `.docs/live-handshake-findings-2026-07-21.md`.
- `tools/phase0-verify.mjs` (Node 21+, zero deps) probes a live gateway: `node tools/phase0-verify.mjs <host> [token]`. Use it to verify handshake behavior instead of assuming.

## Repository layout

```
OpenClawMobile/            iOS app (single target, iOS 17+, Swift, SwiftUI)
├── project.yml            XcodeGen spec — source of truth for project config
├── OpenClawMobile.xcodeproj  generated; regenerate after project.yml changes
└── Sources/
    ├── App/               @main entry
    ├── Features/          one folder per screen: Chat/, Settings/ (view + view model + components)
    ├── Services/          GatewayClient, SSEDecoder, SettingsStore, KeychainService
    ├── Models/            ChatMessage, GatewayDTOs (Codable wire types)
    └── DesignSystem/      Theme.swift — color/radius/spacing tokens
tools/phase0-verify.mjs    gateway protocol probe (Node)
.docs/                     PRD, architecture, connection design
```

## Build & run

Regenerate the Xcode project after editing `project.yml` (requires XcodeGen):

```bash
cd OpenClawMobile && xcodegen generate
```

Build for the simulator (no code signing configured — device builds need a team):

```bash
xcodebuild -project OpenClawMobile/OpenClawMobile.xcodeproj \
  -scheme OpenClawMobile \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build
```

There is no test target yet.

## Architecture rules (from .docs/architecture.md)

- **MVVM with a thin service layer.** Views → view models → services; views never touch network or disk. One `@Observable` view model per screen (iOS 17 Observation framework — no Combine, no `ObservableObject`).
- **Zero third-party dependencies** for v1. URLSession, Keychain (Security framework), Foundation only.
- `async/await` everywhere; errors surface as the typed `GatewayError` enum (`.unauthorized`, `.unreachable`, `.badStatus`, …).
- **Optimistic UI:** user messages append + persist immediately; a streaming assistant bubble fills from deltas; failures mark the bubble failed with retry.
- **Demo mode:** `GatewayClient` falls back to a canned local stream when no host is configured, so the app runs and screenshots standalone. Preserve this path.
- Persistence split: token → Keychain; host/prefs → UserDefaults; conversations → JSON files in `Documents/` (versioned schema). No Core Data/SwiftData.

## Design system rules

Dark mode only. All tokens live in `Sources/DesignSystem/Theme.swift` — use them, never inline values:

- Corner radius is **4pt everywhere**; elevation via **1px borders, never shadows**.
- Accent is terminal green (`#22C55E`); agent status colors are defined once in the DesignSystem layer.
- Monospaced type for code/logs/paths; user bubbles green-tinted right, agent bubbles dark left.
