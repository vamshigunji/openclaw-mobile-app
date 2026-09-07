# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

**OpenClaw Mobile** — a phone-first iOS chat client for talking to autonomous OpenClaw agents running on a private server (Mac Mini / VPS, reached over a Cloudflare Tunnel `wss://` URL).

Built and live-verified against a real gateway (2026-07): device pairing (DeviceTrust), real chat over WS with streamed replies, a **Slack-style multi-agent client** — bottom tab bar → agent roster (`agents.list`) → per-agent chat thread, all on one shared connection — a live **activity indicator** ("Searching the web", "Thinking…") driven only by real gateway signals, and **create / edit / delete agents** from the app. As of v0.2.0.0 the chat thread is a **developer chat**: Stop and Retry on a live run, fenced code blocks with Copy, a tool-call timeline built from `session.tool` events, photo/camera/file attachments, and on-device dictation — all on the official OpenClaw palette. Still out: cockpit control, push notifications.

**Two authority contexts (the load-bearing mental model).** The phone's paired device token holds only `operator.read` + `operator.write`. Admin operations (`agents.create/update/delete`, `agents.files.set`, `terminal.*`) are `operator.admin` — the phone CANNOT call them. So agent create/edit/delete go through **approach B**: the app sends a structured instruction to the `main` agent (which runs in-process on the gateway with full local authority) via `chat.send`, then polls to confirm. The phone is always the *requester*; the main agent is the privileged *executor*. See `designs/2026-07-22-multi-agent-research.md`.

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
    ├── App/               @main entry (seeds AppModel; DEBUG env/arg QA hooks)
    ├── Features/
    │   ├── Root/          AppModel (settings + ONE shared SyncSource), RootTabView (bottom nav)
    │   ├── Agents/        roster + per-agent create/edit/profile + MainAgentTask (approach B)
    │   ├── Chat/          ChatView/ChatViewModel (session-keyed thread), bubble, input bar,
    │   │                  MessageSegmenter + CodeBlockView (fenced code), ToolTimeline,
    │   │                  Attachments (photo/camera/file), SpeechDictation
    │   └── Settings/      pairing flow (QR + paste) + gateway config
    ├── Services/          GatewayConnection (actor: 1 socket, reconnect), GatewayWSSyncSource,
    │                      SyncSource seam, DeviceAuth, PairingFlow, GatewayClient (demo), Keychain
    ├── Models/            ChatMessage, ChatThread, AgentSummary, AgentActivity, GatewayDTOs
    └── DesignSystem/      Theme.swift — tokens + shared MonoField/PrimaryButton/ActivityLine
tools/phase0-verify.mjs    gateway handshake probe · phase0-roundtrip.mjs · rpc-probe.mjs · list-agents.mjs
designs/                   tracked design docs (platform strategy, multi-agent research, tunnel guide)
.docs/                     local-only living docs (README, architecture, protocol, sync, devicetrust)
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
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build   # or test
```

**Tests:** `OpenClawMobileTests` target, ~21 suites (crypto golden vectors, wire-protocol decode from live captures, pairing state machine, mock-gateway E2E, agent roster/activity/create/profile mapping, design-system token enforcement, thread keys, Stop/Retry lifecycle, message segmenting, tool events, attachment intake/budget/send, dictation). CI (`.github/workflows/ci.yml`) runs `xcodegen generate` → `xcodebuild test` on every PR. All pure logic is TDD'd against verbatim live-captured gateway JSON — never hand-invented shapes.

**QA hooks (DEBUG only):** `--seed-demo` (+ `SEED_HOST`/`SEED_DEVICE_TOKEN`/`SEED_DEVICE_KEY`/`SEED_TEXT` env) seeds a paired identity and auto-sends; `--open-settings` / `--open-create` / `--open-profile <id>` drive screens the simulator can't tap.

## Architecture rules (from .docs/architecture.md)

- **MVVM with a thin service layer.** Views → view models → services; views never touch network or disk. One `@Observable` view model per screen (iOS 17 Observation framework — no Combine, no `ObservableObject`).
- **One shared connection.** `AppModel` owns settings + a single `SyncSource` (`GatewayWSSyncSource` → `GatewayConnection` actor: one socket, one handshake, reconnect w/ backoff + auto-resubscribe). Every agent thread and the roster share it — never open a socket per agent/screen.
- **Multi-agent routing.** Roster from `agents.list`; `ChatThread` (Models) carries the session key + agentId a screen is bound to, with `ChatThread.mainKey(agentId:)` producing the canonical `agent:<id>:main` (a bare key + separate agentId is rejected — LIVE-verified). Every `SyncSource` method is session-keyed, so a non-main session (a task thread) needs no new plumbing. Inbound events carry `agentId`; each thread filters the shared stream via `InboundEnvelope.matchesAgent`.
- **Admin ops go through the main agent (approach B).** The phone can't call `agents.create/update/delete` (operator.admin). `MainAgentTask.run` sends a structured instruction to `main` via `chat.send`, then polls `agents.list` to confirm. Same pattern for create, edit, delete.
- **Activity indicator = real signals only.** `AgentActivity.from(event)` maps `session.tool`/`agent`/`chat` events to a verb ("Searching the web"…). Unknown signal → "Working…" fallback; NEVER a fabricated verb. Tool names are claude-cli style (`WebSearch`, `Bash`). Pinned by tests against live JSON.
- **Zero third-party dependencies.** URLSession, Keychain (Security framework), CryptoKit, Network.framework (mock gateway in tests), Foundation only.
- `async/await` everywhere; errors surface as the typed `GatewayError` enum (`.unauthorized`, `.unreachable`, `.badStatus`, `.pairingPending(requestId:)`, `.bootstrapExpired`).
- **Optimistic UI:** user messages append immediately; streaming assistant bubble fills from `chat` deltas; the gateway's echo of our own send is deduped by idempotency key; failures mark the bubble failed with retry.
- **Developer chat surface.** `SyncSource.send` returns the gateway's `runId` and `abort` cancels it (`chat.send` / `chat.abort`, both operator.write) — that pair backs Stop; `runEnds` clears Stop exactly when the run finishes, and a failed bubble offers Retry. `MessageSegmenter` splits a turn into prose and fenced code, `CodeBlockView` renders code with Copy, `ToolTimeline` renders `session.tool` start/result pairs as a per-turn timeline.
- **Attachments and dictation.** Photo, camera, and file picks go out on native `chat.send` (`Attachments.swift`), sized against the ceilings the gateway advertises in `hello-ok` `policy` (fallback defaults: 20 MB per attachment, 6 MB per image, 25 MB per frame) — check the size before decoding, not after. Dictation is on-device `SFSpeechRecognizer` (`SpeechDictation.swift`). Both need the `Info.plist` usage strings declared in `project.yml`; add new ones there, not in the generated plist.
- **Demo mode:** `DemoSyncSource` serves a canned 3-agent roster + `GatewayClient` canned stream when no host is configured, so the app runs and screenshots standalone. Preserve this path.
- Persistence split: Ed25519 device key + token → Keychain; host/prefs/deviceToken → UserDefaults+Keychain. (Conversation JSON persistence is designed but not yet built — history backfills live from `chat.history`.)

## Design system rules

Dark mode only. All tokens live in `Sources/DesignSystem/Theme.swift` — use them, never inline values
(`DesignSystemTests` fails the build on any `Color(hex:`, numeric `cornerRadius(`, or `.shadow(` outside it):

- **Official OpenClaw palette** (2026-09, from `openclaw/openclaw` docs.json + Control UI `base.css`): bg `#0E1015`,
  card `#161920`, elevated `#191C24`; accent lobster red `#FF5C5C` (tint, links, live dot), brand `#D84A31`
  (primary CTA fill, white text), teal `#14B8A6` (running/activity), ok/warn/danger `#22C55E`/`#F59E0B`/`#F87171`.
- Corner radius **6pt for controls, chips, fields** (`Theme.radius`) and **10pt for cards, bubbles, sheets**
  (`Theme.radiusCard`); elevation via **1px borders, never shadows**.
- Agent/task status colors + SF Symbols are defined once (`AgentStatus`); status is never color alone.
- **System type for UI** (`Theme.Font.title/body/caption/label`); **mono only for code, paths, ids, keys, logs**
  (`Theme.Font.mono/monoCaption`). User bubbles accent-tinted right, agent turns full-width cards left.

## Docs location rule

**Every generated document (design docs, specs, review reports, plans — including
output from gstack/office-hours/superpowers skills) must be saved INSIDE this
project at `designs/` (tracked), named `YYYY-MM-DD-<topic>-<kind>.md`; visual
assets go in `designs/assets/`.** `.docs/`, `.gstack/`, `.reviews/`, `.archive/`
are local-only and gitignored. Tools may keep their own copies elsewhere
(e.g. `~/.gstack/projects/...`), but the tracked project copy is mandatory —
the user works from the repo and must be able to access every doc here.

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
