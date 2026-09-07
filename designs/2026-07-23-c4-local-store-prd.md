# C4 — Local Store PRD

## 1. Summary
C4 owns everything OpenClaw Mobile persists on the device: the Ed25519 device identity key and gateway tokens (Keychain), user preferences (host, model, stars, mutes, per-agent last-read), and — the still-unbuilt part — an on-disk conversation cache, per-agent drafts, and bookmarks. It exposes small, concern-specific repository types (a Keychain repo, a settings/prefs store, a conversation cache, a drafts store) rather than one general database. It is a separate team because persistence is a pure-Foundation concern with zero UI and zero network: it can be built and unit-tested in complete isolation against `Codable` round-trips and golden JSON, and every feature chunk (C5 Chat, C6 Agents, C7 Settings) reads and writes through it without any of them owning storage semantics.

## 2. Scope

### In scope
- **Keychain wrapper** — generic-password store for the Ed25519 private key, shared `token`, and device-bound `deviceToken`. Built: `KeychainService` (`Sources/Services/KeychainService.swift`).
- **Preferences store** — host, model, `stars` (pinned agents), `mutes`, and per-agent last-read markers. Partially built: `SettingsStore` (`Sources/Services/SettingsStore.swift`) holds host/model/token/deviceToken today; stars/mutes/last-read are TODO.
- **Conversation JSON cache** — on-disk, per-agent-session, `[ChatMessage]` persisted to the app container. UNBUILT.
- **Drafts store** — per-agent unsent input text, survives app relaunch. UNBUILT (draft is in-memory in `ChatViewModel` today).
- **Bookmarks store** — user-flagged messages, keyed by `(sessionKey, messageId)`. UNBUILT.
- **Persistence split policy** — secrets → Keychain; small prefs → UserDefaults; bulk conversation data → files. This chunk is the single owner of that split.

### Out of scope
- **Fetching `chat.history` from the gateway** — owned by **C1 Transport** / consumed by **C5 Chat**. C4 caches what C5 hands it; it never talks to the network.
- **The device-auth signing payload and pairing state machine** — owned by **C2 Auth** (`DeviceAuth`, `PairingFlow`). C4 only stores/loads the raw key bytes on C2's behalf.
- **Message/agent type definitions** (`ChatMessage`, `AgentSummary`) — owned by **C0 Contract**. C4 imports them, never redefines them.
- **Multi-device sync / conflict resolution** — the `SyncSource` seam is owned by **C1**; C4 is local-only and last-write-wins.
- **View models that read prefs** (star/mute toggles UI) — owned by **C6 Agents** and **C7 Settings**.

## 3. Interface (the stable contract)

### Consumes (only from C0)
```swift
import Contract   // C0
// ChatMessage (id, role, text, createdAt, isStreaming, failed, clientMessageId)
// AgentSummary (id, ...), SessionKey / agentId string form
```

### Exposes
```swift
// Secrets — already built, signature frozen.
enum KeychainService {
    static func set(_ value: String, for key: String)   // empty value => delete
    static func get(_ key: String) -> String?
}

// Preferences — @Observable, @MainActor. Host/model built; the rest are the C4 deliverable.
@MainActor @Observable
final class SettingsStore {
    var host: String
    var model: String
    var token: String            // Keychain-backed
    var deviceToken: String      // Keychain-backed, wins when present
    var isPaired: Bool { get }
    var isConfigured: Bool { get }

    // NEW surface this chunk adds:
    var starredAgentIDs: Set<String>            // UserDefaults-backed
    var mutedAgentIDs: Set<String>              // UserDefaults-backed
    func lastRead(for sessionKey: String) -> Date?
    func setLastRead(_ date: Date, for sessionKey: String)
}

// Conversation cache — the main unbuilt deliverable. File-backed, one file per session.
protocol ConversationCache {
    func load(sessionKey: String) -> [ChatMessage]           // [] if none
    func save(_ messages: [ChatMessage], sessionKey: String)
    func clear(sessionKey: String)
}

// Drafts — per-agent unsent text.
protocol DraftStore {
    func draft(for sessionKey: String) -> String
    func setDraft(_ text: String, for sessionKey: String)    // "" clears
}

// Bookmarks — flagged messages.
protocol BookmarkStore {
    func bookmarks() -> [Bookmark]                            // Bookmark = (sessionKey, messageId, createdAt)
    func toggle(sessionKey: String, messageId: UUID)
    func isBookmarked(sessionKey: String, messageId: UUID) -> Bool
}
```
Protocols exist because C5/C6 hold references for testability; each has exactly one production file-backed implementation. No general "Database" or "Repository<T>" abstraction — one type per concern.

## 4. Dependencies
- **Allowed:** C0 (Contract) only. Plus Apple frameworks: `Foundation`, `Security` (Keychain), `CryptoKit` (key bytes are handled by C2 — C4 stores raw `Data`).
- **Forbidden:** C1, C2, C3, and every feature chunk. C4 imports no `SyncSource`, no `GatewayConnection`, no view.
- **Import rule (C10-enforced):** C4's module declares `dependencies: [Contract]` in its build target. Any `import Transport`, `import Auth`, or `import ChatFeature` in a C4 file fails to compile because those modules are not on the target's link path. A sibling wanting C4 depends on `LocalStore`; C4 depending on a sibling is a cycle the module graph rejects.

## 5. Milestones / build order
1. **M1 — Lock the built surface (day 0).** Wrap existing `KeychainService` + `SettingsStore` (host/model/token/deviceToken) behind the frozen signatures above; add golden `Codable` round-trip tests. Ships as-is.
2. **M2 — Prefs expansion.** Add `starredAgentIDs`, `mutedAgentIDs`, per-session last-read to `SettingsStore`, UserDefaults-backed with `didSet` persistence (mirrors existing host/model pattern).
3. **M3 — Conversation cache.** `FileConversationCache`: `[ChatMessage]` → JSON at `Application Support/conversations/<sanitized-sessionKey>.json`. Atomic write, tolerant load (corrupt/missing → `[]`).
4. **M4 — Drafts + bookmarks.** `DraftStore` (small, UserDefaults keyed by sessionKey) and `BookmarkStore` (single JSON file). Lowest priority; ship only if scoped.

## 6. Acceptance criteria
- Keychain: `set`/`get` round-trips a value; `set("", …)` deletes; missing key → `nil`. (Existing behavior — pin with tests.)
- SettingsStore: setting `host`/`model`/star/mute/last-read then re-instantiating from `UserDefaults` returns the same values; tokens survive via Keychain, not UserDefaults (assert no plaintext token key in UserDefaults).
- ConversationCache: `save` then `load` on the same sessionKey yields an equal `[ChatMessage]` (decode from a **committed golden JSON fixture**, not a hand-built struct, so wire drift is caught); `load` of a missing or truncated file returns `[]` and does not throw; two sessionKeys never collide (including keys containing `:` and `/`, e.g. `agent:main:main`).
- DraftStore/BookmarkStore: set→get round-trip; `""` draft clears; `toggle` is idempotent-pair (two toggles → unbookmarked).
- Every test runs with **no gateway and no network** — pure Foundation.

## 7. Isolation proof
An agent in a fresh git worktree can build C4 from this PRD alone: it needs only the C0 `ChatMessage`/`AgentSummary` type definitions (a header dependency, resolvable by stubbing C0's public types if C0 isn't merged yet) and Apple's `Foundation`/`Security`. It writes zero UI, opens zero sockets, and imports zero sibling module. Every acceptance test is a `Codable` round-trip or a Keychain/UserDefaults read-back — all runnable in a plain XCTest bundle with no simulator gateway and no mock server. Nothing in C5/C6/C7 needs to exist for C4 to compile, test green, and merge.

## 8. Status & risks
**Built (live):** `KeychainService` (35 lines, generic-password) and `SettingsStore` (host/model/token/deviceToken) — both in production, backing pairing and connect today. Ed25519 key persistence rides `KeychainService` via C2's `DeviceAuth`.

**Partial:** `SettingsStore` has no stars/mutes/last-read yet.

**Unbuilt:** conversation JSON cache, drafts persistence (draft is in-memory `ChatViewModel.draft` only), bookmarks. Chat history currently backfills live from `chat.history` (`GatewayWSSyncSource`), so the cache is a latency/offline nicety, not a correctness dependency — **build it last, and only if offline-open or scroll-back-without-refetch is actually wanted.** (ponytail: don't ship a cache no feature reads yet.)

**Open questions:**
- Does any feature actually consume the conversation cache before multi-device sync (Path E) lands? If not, M3 is speculative — defer.
- Cache invalidation vs. live `chat.history`: last-write-wins from the gateway, or merge? Punt to whoever writes C5's load path.
- sessionKey sanitization for filenames: keys contain `:` (`agent:<id>:main`) — hash or percent-encode; must be collision-free (covered by the acceptance test above).
- Bookmarks may be a YAGNI feature with no UI owner in C5/C6 — confirm a consumer exists before building M4.
