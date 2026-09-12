# CLAUDE.md

Current development status (2026-09-08): PR #10 remains open and `dev-suite-board` is
still LOCAL-ONLY — `git ls-remote --heads origin dev-suite-board` returns nothing, so 17
commits plus ~500 uncommitted lines exist on this machine alone. Not a v1 release.
Remote APNs and TestFlight remain deferred.

**P5–P7 live validation is DONE** (2026-09-08). The old blocker — no reachable gateway —
is gone: `./sandbox/up.sh` runs openclaw 2026.9.2 in Docker and the Simulator reaches it
at `http://127.0.0.1:18789` with no tunnel and no Tailscale. Verified live against it:
pairing, chat, history backfill across an offline gap, all Board reads and writes,
disconnect/reconnect with auto-resubscribe, approach B (create AND edit), multi-agent
routing isolation, attachments reaching the model, and two-device fan-in (P7). All seven
sync probes P1–P7 now have real evidence, not just frame checks.

**Nine defects were found doing it, none of which the 201-test suite could see** (a tenth was claimed and later retracted — see the findings doc) — see
`designs/2026-09-08-live-validation-findings.md`. Three were actively masked by fixtures
asserting a protocol the gateway does not speak. Live captures now sit alongside the
schema-derived Board fixtures (both are kept, for different jobs — see
`Tests/Fixtures/README.md`).

⚠️ Never build or test with `CODE_SIGNING_ALLOWED=NO`. It strips the app's entitlements,
every Keychain write then fails with `-34018`, the device identity is re-minted on each
launch, and pairing can never persist. That flag is why CI was green for months with the
bug present.
**The suite now enforces this (verified 2026-09-12).** Controlled run: `DeviceAuthTests`
is 8/8 green normally and 6/8 RED under the flag, failing `status=-34018` on keychain
write, accessibility, and identity-reuse. No CI grep is needed — reintroducing the flag
turns the suite red on its own.
**Mechanism corrected 2026-09-12** (the ban is unchanged; the reason given here was wrong):
this is NOT about a missing `keychain-access-groups` entitlement.
`Sources/OpenClawMobile.entitlements` is an empty `<dict/>` and `KeychainService` sets no
`kSecAttrAccessGroup` — the app uses the DEFAULT access group, which is derived from the
`application-identifier` entitlement that the signing step injects. Strip signing and that
entitlement is absent, so there is no access group to write into. Same outcome, different
cause; worth stating correctly because the wrong mechanism sends the next reader hunting for
an entitlement that was never needed.

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

**Device builds work as of 2026-09-11.** `Signing.xcconfig` is tracked and contains only
`#include? "Signing.local.xcconfig"`; the team ID lives in that gitignored local file, so it never
reaches the tracked `project.pbxproj` (verified: 0 occurrences). Bundle ID is
`com.openclaw-gv.mobile` — `com.openclaw.mobile` was unavailable. Build with
`-destination 'platform=iOS,id=<udid>' -allowProvisioningUpdates`; the device must be registered
in the developer account and have Developer Mode enabled.

Build for the simulator (signs ad-hoc, needs no team):

```bash
xcodebuild -project OpenClawMobile/OpenClawMobile.xcodeproj \
  -scheme OpenClawMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build   # or test
```

**Tests:** `OpenClawMobileTests` target, 305 tests across ~32 files, 5 skipped without a live gateway (crypto golden vectors, wire-protocol decode from live captures, pairing state machine, mock-gateway E2E, agent roster/activity/create/profile mapping, design-system token enforcement, thread keys, Stop/Retry lifecycle, message segmenting, tool events, attachment intake/budget/send, dictation). CI (`.github/workflows/ci.yml`) runs `xcodegen generate` → `xcodebuild test` on every PR. All pure logic is TDD'd against verbatim live-captured gateway JSON — never hand-invented shapes.

**QA hooks (DEBUG only):** `--seed-demo` (+ `SEED_HOST` / `SEED_TOKEN` / `SEED_DEVICE_TOKEN` / `SEED_DEVICE_KEY` / `SEED_TEXT` env) seeds a paired identity and auto-sends; `--open-settings` / `--open-create` / `--open-board` / `--open-profile <id>` drive screens the simulator can't tap. `SEED_TOKEN` is the SHARED gateway token and `SEED_DEVICE_TOKEN` the pairing-minted device token — they travel in different auth fields, and putting a shared token in the device slot gets `device_token_mismatch`.

## Architecture rules (from .docs/architecture.md)

- **MVVM with a thin service layer.** Views → view models → services; views never touch network or disk. One `@Observable` view model per screen (iOS 17 Observation framework — no Combine, no `ObservableObject`).
- **One shared connection.** `AppModel` owns settings + a single `SyncSource` (`GatewayWSSyncSource` → `GatewayConnection` actor: one socket, one handshake, reconnect w/ backoff + auto-resubscribe). Every agent thread and the roster share it — never open a socket per agent/screen.
- **Multi-agent routing.** Roster from `agents.list`; `ChatThread` (Models) carries the session key + agentId a screen is bound to, with `ChatThread.mainKey(agentId:)` producing the canonical `agent:<id>:main` (the app always sends this canonical form; note 2026.9.2 no longer REJECTS a bare key +
  separate agentId as it did on 2026-07-22 — the gateway became lenient, but do not rely on it). Every `SyncSource` method is session-keyed, so a non-main session (a task thread) needs no new plumbing. Inbound events carry `agentId`; each thread filters the shared stream via `InboundEnvelope.matchesAgent`.
- **Admin ops go through the main agent (approach B).** The phone can't call `agents.create/update/delete` (operator.admin). `MainAgentTask.run` sends a structured instruction to `main` via `chat.send`, then polls `agents.list` to confirm. Same pattern for create, edit, delete.
- **Activity indicator = real signals only.** `AgentActivity.from(event)` maps `session.tool`/`agent`/`chat` events to a verb ("Searching the web"…). Unknown signal → "Working…" fallback; NEVER a fabricated verb. Tool names: openclaw 2026.9.2 emits its OWN vocabulary — `exec`, `web_search`, `browser`,
  `read`, `write`, `edit`, `apply_patch`, `ls`, `grep`, `tasks`, `skills`, `memory_*` — NOT the
  claude-cli names this file used to claim (`Bash`, `WebSearch`). `AgentActivity.forTool` now
  covers both; an unknown tool still falls back to "Working…", never a fabricated verb.
  Corrected 2026-09-08 from a live `session.tool` capture (defect 7).
- **Zero third-party dependencies.** URLSession, Keychain (Security framework), CryptoKit, Network.framework (mock gateway in tests), Foundation only.
- `async/await` everywhere; errors surface as the typed `GatewayError` enum (`.unauthorized`, `.unreachable`, `.badStatus`, `.pairingPending(requestId:)`, `.bootstrapExpired`, `.sessionChanged`). **Several RPCs report failure IN-BAND rather than with `ok:false`** — `tasks.cancel` → `cancelled:false`, `chat.abort` → `aborted:false`, `sessions.patch` → `details.reason:"session-changed"`, `sessions.list` → `hasMore`/`nextOffset` that must be followed. Checking only `ok` reports those refusals to the user as success (defects 8–10, 2026-09-08). Audit any new RPC's real response shape before trusting `ok`.
- **Optimistic UI:** user messages append immediately; streaming assistant bubble fills from `chat` deltas; the gateway's echo of our own send is deduped by idempotency key; failures mark the bubble failed with retry.
- **Developer chat surface.** `SyncSource.send` returns the gateway's `runId` and `abort` cancels it (`chat.send` / `chat.abort`, both operator.write) — that pair backs Stop; `runEnds` clears Stop exactly when the run finishes, and a failed bubble offers Retry. `MessageSegmenter` splits a turn into prose and fenced code, `CodeBlockView` renders code with Copy, `ToolTimeline` renders `session.tool` start/result pairs as a per-turn timeline.
- **Attachments and dictation.** Photo, camera, and file picks go out on native `chat.send` (`Attachments.swift`), sized against `AttachmentPolicy` (20 MB per attachment, 6 MB per image, 25 MB per frame) — check the size before decoding, not after. Those are only FALLBACKS: openclaw 2026.9.2 **does** advertise a `policy` block in `hello-ok` (`maxPayload`, `attachments.maxBytes`, `attachments.maxImageBytes`) and it reflects `agents.defaults.mediaMaxMb`. `GatewayConnection` reads it and overrides the defaults, which matters — a gateway set to 7 MB caps attachments the app would otherwise allow at 20 MB. Verified 2026-09-08; the captured handshake is `Tests/Fixtures/hello-ok.json`. Dictation is on-device `SFSpeechRecognizer` (`SpeechDictation.swift`). Both need the `Info.plist` usage strings declared in `project.yml`; add new ones there, not in the generated plist.
- **Demo mode:** `DemoSyncSource` serves a canned 3-agent roster + `GatewayClient` canned stream when no host is configured, so the app runs and screenshots standalone. Preserve this path.
- Persistence split: Ed25519 device key + token → Keychain; host/prefs/deviceToken → UserDefaults+Keychain. **Conversation persistence now EXISTS** (2026-09-10, `Services/ChatHistoryStore.swift`): one JSON file per session under Application Support, 500 messages kept, written at turn boundaries only — never per streaming delta. `ChatViewModel` renders the cached transcript at init, then merges the live snapshot through the existing `reconcileHistory`. Two things are deliberately NOT persisted: `isStreaming` (a bubble saved mid-run would restore as a permanent typing indicator) and attachment BYTES (`Attachment.data` runs to 20 MB; metadata is kept so the turn still reads as "I sent photo.jpg"). Demo mode never writes. The store is injected with a `nil` default so tests opt in rather than silently writing to the shared app container. Proven live with the gateway stopped.

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
