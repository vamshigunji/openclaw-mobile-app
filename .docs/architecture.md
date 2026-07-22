# Architecture — OpenClaw Mobile Chat Client

> How the iOS app is built. Scope and design language: [`product.md`](./product.md).
> The wire protocol (transport, handshake, device auth) is owned by
> [`protocol.md`](./protocol.md); multi-device sync and the `SyncSource` seam by
> [`sync.md`](./sync.md) — this doc only describes the app-side layering around them.

---

## 1. Goals & Constraints

| Concern | Decision | Source |
|---|---|---|
| Platform | iOS 17.0+ | PRD §5 |
| Language | Swift 5.10 | PRD §5 |
| UI framework | SwiftUI (no UIKit except where unavoidable) | PRD §5 |
| Third-party dependencies | **None** for v1 — URLSession, Keychain, and Foundation only | NFR: direct client↔server, small surface |
| Networking | Direct device → user's private Gateway. No relays. | PRD §5 |
| Boot to interactive | < 1.5 s | PRD §5 |

**Design principle:** keep the dependency graph shallow and the layers thin. This is a
text client, not a cockpit. Every abstraction must earn its place.

---

## 2. High-Level Architecture

The app follows **MVVM** with a thin **repository/service** layer beneath the view models.
SwiftUI views observe `@Observable` view models (the iOS 17 Observation framework —
no Combine, no `ObservableObject` boilerplate).

```
┌─────────────────────────────────────────────────────────────┐
│                          SwiftUI Views                        │
│   SettingsView · AgentListView · ChatView · shared components │
└───────────────▲───────────────────────────▲──────────────────┘
                │ observes                   │ observes
┌───────────────┴───────────────┐ ┌──────────┴──────────────────┐
│         View Models            │ │      View Models             │
│  @Observable, one per screen   │ │  own UI state + call layer   │
└───────────────▲────────────────┘ └──────────▲──────────────────┘
                │ calls                        │
┌───────────────┴──────────────────────────────┴─────────────────┐
│                        Service Layer                            │
│  GatewayClient (networking) · SettingsStore · ChatStore         │
│  KeychainService · streaming SSE decoder                        │
└───────────────▲──────────────────────────────▲─────────────────┘
                │                               │
┌───────────────┴───────┐        ┌──────────────┴──────────────────┐
│   OpenClaw Gateway     │        │   On-device persistence         │
│   (remote HTTP API)    │        │   Keychain · UserDefaults · JSON │
└────────────────────────┘        └─────────────────────────────────┘
```

**Data-flow rule:** Views never touch the network or disk directly. Views → View Models →
Services. Nothing flows the other way except async return values and observed state.

---

## 3. Module / Folder Structure

Single app target, organized by feature with shared foundations. No SPM split for v1
(one target keeps build times low and there is no second consumer of the code).

As built today (`OpenClawMobile/Sources/`):

```
Sources/
├── App/
│   └── OpenClawMobileApp.swift        // @main entry, root scene, DI composition root
├── Features/
│   ├── Settings/
│   │   └── SettingsView.swift
│   └── Chat/
│       ├── ChatView.swift
│       ├── ChatViewModel.swift        // depends on SyncSource for history/subscribe
│       ├── MessageBubble.swift
│       └── ChatInputBar.swift
├── Services/
│   ├── GatewayClient.swift            // REST fast path + demo-mode stream
│   ├── SSEDecoder.swift               // Server-Sent Events line parser
│   ├── SettingsStore.swift            // host/token read+write (UserDefaults + Keychain)
│   ├── KeychainService.swift
│   ├── SyncSource.swift               // seam: loadHistory + subscribe (sync.md)
│   └── GatewayWSSyncSource.swift      // protocol-v4 WS conformer (pairing layer still unbuilt)
├── Models/
│   ├── ChatMessage.swift
│   └── GatewayDTOs.swift              // Codable wire types
└── DesignSystem/
    └── Theme.swift                    // colors, radii, spacing tokens
```

Planned but not yet built: an AgentList feature, a `ChatStore` (JSON persistence),
and the device-pairing service. Add them when their milestone arrives — not before.

---

## 4. Domain Models

Kept deliberately small. Wire types (`GatewayDTOs`) are decoded from the API and mapped
into app-facing domain models so the UI never depends on the exact JSON shape.

```swift
struct Agent: Identifiable, Hashable {
    let id: String
    let name: String
    let status: AgentStatus
    let createdAt: Date?
    let promptSnippet: String?
}

enum AgentStatus: String, Codable {
    case working, waiting, blocked, failed, done, idle
    // .color and .label are computed in the DesignSystem layer, not here.
}

struct ChatMessage: Identifiable, Codable, Hashable {
    let id: UUID
    let agentId: String
    let role: Role          // .user or .assistant
    var text: String        // mutable so streaming deltas can append in place
    let createdAt: Date
    var isStreaming: Bool
    enum Role: String, Codable { case user, assistant }
}
```

**Status → UI mapping** (single source of truth, in `DesignSystem`):

| Status | Color | Hex |
|---|---|---|
| `working` | Green | `#22C55E` |
| `waiting` | Amber | `#F59E0B` |
| `blocked` | Purple | `#A855F7` |
| `failed` | Red | `#EF4444` |
| `done` | Muted Gray | `#6B7280` |
| `idle` | Muted Gray | `#6B7280` |

---

## 5. Networking Layer

Two transports, one rule (decision log in `protocol.md`):

- **Backbone — protocol-v4 WebSocket RPC** (`GatewayWSSyncSource` behind the `SyncSource`
  seam): device-auth pairing, `session.message` sends with a client idempotency key,
  `sessions.messages.subscribe` fan-in.
- **Fast path — REST** (`GatewayClient`, below): `/health` and single-turn
  `/v1/chat/completions` + SSE only. It cannot list agents, hold sessions, or fan out.

### `GatewayClient` (REST fast path)

A single actor that owns the HTTP communication. Using an `actor` serializes access to
the current host/token config and gives us safe concurrency for free.

```swift
actor GatewayClient {
    // As built: single-turn streaming send; falls back to a canned demo stream
    // when no host is configured (demo mode — must be preserved).
    func streamReply(history: [ChatMessage]) -> AsyncThrowingStream<String, Error>
}
```

A `health()` probe is planned for the Settings connectivity indicator. Agent listing
and session traffic belong to the WS layer, not here.

**Conventions**
- Base URL + `Authorization: Bearer <token>` injected from `SettingsStore` on every request.
- `async/await` throughout; no completion handlers, no Combine.
- Errors surface as a typed `GatewayError` enum (`.unauthorized`, `.unreachable`,
  `.badStatus(Int)`, `.decoding(Error)`) so view models can render precise messages.
- 15 s request timeout for unary calls; streaming calls have no idle timeout while data flows.

### 5.1 Endpoints (v1)

| Purpose | Method | Path | Notes |
|---|---|---|---|
| Connection test | `GET` | `/health` | Powers the Settings connectivity indicator (live-verified) |
| Send message (single-turn) | `POST` | `/v1/chat/completions` | OpenAI-compatible; `stream: true` |

The agent directory is **not REST** — it comes from the WS RPC (`agents.list`), which
requires a paired device (`operator.read`).

### 5.2 Streaming (chat)

`/v1/chat/completions` returns **Server-Sent Events** when `stream: true`. `SSEDecoder`
parses the `data:` lines off `URLSession.bytes(for:)`, ignores heartbeats, and terminates
on `data: [DONE]`. Each decoded `CompletionDelta` carries an incremental token that the
`ChatViewModel` appends to the in-flight assistant `ChatMessage`.

```
URLSession.bytes  →  SSEDecoder (line framing)  →  CompletionDelta stream
                                                        │
                                              ChatViewModel appends → view updates
```

---

## 6. Persistence

Three distinct stores, each matched to the sensitivity and shape of its data.

| Data | Store | Rationale |
|---|---|---|
| Gateway token | **Keychain** | Secret; must survive backup exclusion & be encrypted at rest (PRD §5) |
| Host endpoint, UI prefs | **UserDefaults** | Non-secret config, trivially small |
| Message histories | **JSON files** in `Documents/` | PRD §3.3 — one file per agent conversation |

### 6.1 `ChatStore`

- One JSON file per agent: `Documents/conversations/<agentId>.json`.
- Writes are debounced and performed off the main actor to keep scrolling smooth.
- Loaded lazily when a chat opens; kept in memory for the session.
- Schema is versioned (`{ "version": 1, "messages": [...] }`) so the format can evolve.

**Why flat JSON over Core Data / SwiftData:** the dataset is small (text logs for a handful
of agents), append-mostly, and never queried relationally. A file-per-conversation model is
simpler, debuggable by hand, and has zero migration ceremony for v1. Revisit if history
volume or cross-agent search becomes a real requirement.

### 6.2 `KeychainService`

Thin wrapper over the Security framework (`SecItemAdd`/`SecItemCopyMatching`) storing a
single generic-password item keyed by service+account. No third-party keychain wrapper.

---

## 7. State Management

- **Observation framework** (`@Observable`) for all view models — the iOS 17 replacement
  for `ObservableObject`; only the properties a view actually reads trigger re-renders.
- **One view model per screen.** View models own UI state and orchestrate services; they
  contain no view code and no direct persistence logic.
- **Optimistic UI (PRD §5):** on Send, the user message is appended to the list and
  persisted *immediately*, before the network call resolves. A placeholder streaming
  assistant bubble is inserted and filled by SSE deltas. On failure the assistant bubble is
  marked `.failed` and offers a retry.
- **Dependency injection:** services are constructed once in `AppEnvironment` (the
  composition root) and passed into view models via initializers — no global singletons,
  which keeps view models unit-testable with fakes.

---

## 8. Design System Implementation

Encodes PRD §4 as reusable tokens and components. Dark mode only for v1.

```swift
enum Theme {
    // Backgrounds
    static let bgPrimary   = Color(hex: 0x0E0F12)
    static let bgSecondary = Color(hex: 0x1E2026)
    // Accent
    static let accent      = Color(hex: 0x22C55E)   // terminal green
    // Geometry
    static let radius: CGFloat  = 4                  // strict 4px everywhere
    static let border: CGFloat  = 1                  // 1px crisp borders, no shadows
}
```

**Rules baked into components, not left to call sites:**
- All corners use `Theme.radius` (4px). No other radius values in the codebase.
- Elevation is expressed with **1px borders**, never drop-shadows.
- Message bubbles: user = terminal-green (right), agent = near-black/gray (left).
- Typography roles: **Space Grotesk** (headers) / **Inter · SF Pro** (body) /
  **SF Mono · Roboto Mono** (code, file paths, logs). A `MonospaceText` component wraps
  the mono role so log/code content is consistent.
- Custom fonts are bundled and registered via `Info.plist` (`UIAppFonts`); the mono/body
  roles fall back to system `SF Mono`/`SF Pro` if a bundled font is missing.

---

## 9. App Flow & Navigation

```
Launch
  │
  ├─ No host/token configured ──▶ SettingsView (first-run)
  │
  └─ Configured ──▶ AgentListView ──(tap agent)──▶ ChatView
                          │
                          └─ Settings reachable from toolbar
```

- Root is a `NavigationStack`. Agent list is the home screen once configured.
- Settings is always reachable; changing host/token invalidates cached agents.

---

## 10. Error Handling & Connectivity

| Situation | Behavior |
|---|---|
| No config yet | Route to Settings; agent list shows an empty/setup state |
| Health check fails | Settings indicator turns red with the `GatewayError` reason |
| `401 Unauthorized` | Non-blocking banner: "Token rejected — check Settings" |
| Network unreachable | Retry affordance on the failed screen; cached data stays visible |
| Streaming drops mid-response | Assistant bubble marked `.failed` with a Retry action |

The app is **offline-tolerant for reads**: previously loaded conversations render from the
local JSON store even with no connectivity.

---

## 11. Performance Notes (meeting PRD §5)

- **< 1.5 s to interactive:** no network on the launch path. The agent list renders its
  last-known cached state instantly, then refreshes in the background.
- Conversation JSON is loaded lazily per-chat, not all at boot.
- Persistence writes are debounced and run off the main actor.
- `LazyVStack` + stable `ChatMessage.id` keep long logs scrolling at 60fps.

---

## 12. Security Posture

- Device → gateway via the Cloudflare Tunnel (`wss://`, managed TLS — no ATS exception
  needed); the tunnel is a dumb pipe, not a protocol relay. Gateway stays loopback-bound.
- Tokens and the Ed25519 device key live in the Keychain, excluded from unencrypted
  backups; never logged.
- Plain HTTP is used only for on-box `localhost` development.
- No analytics, no telemetry, no outbound calls other than to the configured Gateway.

---

## 13. Explicitly Out of Scope for v1

Deferred to later milestones (tracked here so the architecture doesn't over-build):
full cockpit control, push notifications, multi-account/multi-Gateway switching,
cross-agent search, message editing, and rich attachments. The layering above leaves room
for these (typed service layer, versioned JSON schema) without inviting them now.

---

## 14. Open Questions

Resolved 2026-07-21 (live-verified — `protocol.md`):
`/health` confirmed (`200 {"ok":true,"status":"live"}`); agent status/conversations
come from the WS event stream (`sessions.subscribe`), not REST polling; sessions are
gateway-held, addressed by `session.message`; a bare token yields `scopes: []`, so
per-device pairing is the auth model.

Still open: the remaining unknowns live in `protocol.md` §9 and the
P1–P7 probe table in `sync.md` §3.
