# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

**OpenClaw Mobile** — a phone-first iOS chat client for talking to autonomous OpenClaw agents running on a private server (Mac Mini / VPS, reached over a Cloudflare Tunnel `wss://` URL). v1 scope is deliberately small: configure gateway host + token, list agents, text an agent, stream its reply. No cockpit control, no push notifications.

Key docs — one topic each, start at the README (`.docs/archive/` is history, not guidance):

- `.docs/README.md` — **start here**: doc map, milestone status, next actions
- `.docs/product.md` — what & why, design language
- `.docs/architecture.md` — how the iOS app is structured
- `.docs/protocol.md` — how we talk to the gateway (transport, handshake, device auth, scopes)
- `.docs/sync.md` — multi-device sync (Path E, `SyncSource` seam, probes P1–P7)

## Critical protocol context (details in `.docs/protocol.md`)

- **Backbone = Gateway protocol-v4 native WebSocket RPC** (JSON `req|res|event` frames, port `18789`, docs at docs.openclaw.ai/gateway/protocol). The OpenAI-style REST endpoint is a **single-turn convenience only**. The `openclaw-app` relay/Noise-XX architecture was **rejected** — incompatible; its `OpenClawCore` is crypto-pattern reference only.
- **Reachability = Cloudflare Tunnel** (Quick Tunnel now → `wss://…trycloudflare.com`; named tunnel + domain later). Tailscale was tried and rejected.
- **Device pairing is mandatory** — token-only WS connect gets `scopes: []`. `client.id` must be `openclaw-ios` (or `cli`); setup code goes in `auth.bootstrapToken`; connect carries a signed `device{ id, publicKey, signature, signedAt, nonce }`, `device.id = hex(sha256(raw ed25519 pubkey))`.
- **The v3 signature payload is SOLVED** (sourced from the public `openclaw` npm package): a pipe-delimited string `v3|deviceId|clientId|clientMode|role|scopes,csv|signedAtMs|token|nonce|platform|deviceFamily`, Ed25519 → base64url. Reference implementation lives in `tools/phase0-verify.mjs`.
- `tools/phase0-verify.mjs` (Node 21+, zero deps) probes a live gateway: `node tools/phase0-verify.mjs <host> [token] [--pair <setupCode>]`. Use it to verify handshake behavior instead of assuming.

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

## Docs location rule

**Every generated document (design docs, specs, review reports, plans — including
output from gstack/office-hours/superpowers skills) must be saved INSIDE this
project at `.docs/designs/` (or the matching `.docs/` subfolder), named
`YYYY-MM-DD-<topic>-<kind>.md`.** Tools may keep their own copies elsewhere
(e.g. `~/.gstack/projects/...`), but the project copy is mandatory — the user
works from the repo and must be able to access every doc here.

## gstack

Use the `/browse` skill from gstack for **all** web browsing. Never use `mcp__claude-in-chrome__*` tools.

Available gstack skills:

- `/office-hours`
- `/plan-ceo-review`
- `/plan-eng-review`
- `/plan-design-review`
- `/design-consultation`
- `/design-shotgun`
- `/design-html`
- `/review`
- `/ship`
- `/land-and-deploy`
- `/canary`
- `/benchmark`
- `/browse`
- `/connect-chrome`
- `/qa`
- `/qa-only`
- `/design-review`
- `/setup-browser-cookies`
- `/setup-deploy`
- `/setup-gbrain`
- `/retro`
- `/investigate`
- `/document-release`
- `/document-generate`
- `/codex`
- `/cso`
- `/autoplan`
- `/plan-devex-review`
- `/devex-review`
- `/careful`
- `/freeze`
- `/guard`
- `/unfreeze`
- `/gstack-upgrade`
- `/learn`
