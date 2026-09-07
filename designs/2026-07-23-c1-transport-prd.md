# C1 — Transport PRD

## 1. Summary
C1 owns the single live wire to the gateway: one `URLSessionWebSocketTask`, the `req|res|event` framing, request/response correlation by id, idempotency-keyed sends, reconnect with exponential backoff, and fan-out of every inbound event to every listener. It exposes exactly one seam upward — `GatewayWSSyncSource` (conforming to the C0 `SyncSource` read/subscribe protocol **plus** a concrete `send`) backed by the `GatewayConnection` actor — so features never see a socket. It is a separate team because it is the only place allowed to hold a socket and the only place that must get reconnect/correlation/backoff exactly right; every feature chunk (C5–C8) depends on its seam but none may reimplement transport. Today this code is live (`Sources/Services/GatewayConnection.swift`, `GatewayWSSyncSource.swift`, `GatewayFrames.swift`) and the sole open defect is the reconnect event-loss window.

## 2. Scope
**In scope**
- One shared `URLSessionWebSocketTask` per `GatewayConnection`; the ONE-connection invariant (never a socket per screen/agent).
- **The outbound frame-BUILDER functions** — `GatewayFrames.connect / subscribe / history / message / agentsList`, each emitting a `[String: Any]` wire dict from typed args. This file (`Sources/Services/GatewayFrames.swift`) is **C1-owned** and is the *implementation* of C0's frame-shape contract: C0 pins the method names and required param keys; C1 is the only code that assembles the dicts. It is imported by `GatewayConnection` alone, never by a feature.
- Request/response correlation: unique ids → `CheckedContinuation` map, per-request timeout watchdog.
- The WS **write/send path** — `send(agentId:text:idempotencyKey:)` on the concrete `GatewayWSSyncSource` — including passing the caller/C5-generated idempotency key through to `chat.send` verbatim. C1 owns the wire call; C5 owns key generation and optimistic-bubble reconciliation.
- Reconnect: exponential backoff 1s→2s→…→30s cap (each step doubles, then clamps at 30, so the raw 32 becomes 30), single in-flight connect task, deviceToken refresh on hello-ok.
- Event fan-out: `events()` `AsyncStream` per listener that survives reconnects; per-agent filtering via the C0 `InboundEnvelope.matchesAgent`.
- Reconnect delta fix: resubscribe with a `since: { seq, stateVersion }` cursor and drive a bounded catch-up so no events are lost in the disconnect window (closes the orphaned-spinner gap). This is **internal to the reconnect loop** — it adds no new seam method; C5/C6 must NOT expect a public resync entry point.
- `SyncSource` conformance: `listAgents / loadInstructions / loadHistory / subscribe / activityStream` over the WS RPCs.

**Out of scope**
- The **frame-shape contract itself** — method-name strings, required param keys, and their meaning (connect/subscribe/history/send/agents.list) — C0 (Contract). C0 pins *what a valid frame contains*; C1's `GatewayFrames` builders are the code that produces one. C1 defines the builders, not the contract they satisfy.
- The `GatewayAuth` credential type that the feature-facing init accepts — C0 (Contract). See §3; this is the type C7/Settings constructs, so it is a C0 contract type, not a C1 type. (It lives today as `GatewayFrames.Auth`; the integration step in §8 promotes it to a standalone C0 `GatewayAuth`.)
- The handshake signature payload and challenge signing — C2 (Auth); consumed here only via the `ConnectSigner` protocol from C0. C1 never touches CryptoKit or Keychain.
- Wire DTO shapes (`InboundEnvelope`, `GatewayError`, the `sync.eventsSince` / `since`-cursor decode shapes) — C0 (Contract). C1 imports, never defines them.
- The gateway daemon that implements `sync.eventsSince` + `since`/`stateVersion` stamping — C9 (Gateway). C1 is only the client caller.
- Idempotency-key generation and message→bubble mapping, `isStreaming` bookkeeping, orphaned-bubble clearing decisions — C5 (Chat). C1 passes the key through and delivers the catch-up events; C5 decides key values and what to clear.
- Roster/activity semantics beyond passing frames through — C6 (Agents).
- Host/token persistence — C7 (Settings) via `SettingsStore`.
- The module-graph enforcement itself — C10 (Platform).

## 3. Interface (the stable contract)
**Exposes**
```swift
// The only type features construct. Backed by GatewayConnection.
// Conforms to the C0 SyncSource (read/subscribe) AND adds the write path.
// `auth` is the C0 GatewayAuth contract type — NOT a C1 type — so constructing
// this source leaks nothing from the Transport module into a feature.
struct GatewayWSSyncSource: SyncSource {
    init(host: String, auth: GatewayAuth, signer: ConnectSigner,
         onDeviceToken: (@Sendable (String) -> Void)?)

    // WRITE PATH — concrete-only, NOT on the SyncSource protocol (see boundary note).
    // C1 forwards `idempotencyKey` to chat.send byte-for-byte; C5 generates it.
    func send(agentId: String, text: String, idempotencyKey: String) async throws
}

// SyncSource (defined in C0) — the read/subscribe seam, UNCHANGED (no send):
protocol SyncSource: Sendable {
    func listAgents() async throws -> [AgentSummary]
    func loadInstructions(agentId: String) async throws -> String?
    func loadHistory(agentId: String) async throws -> [ChatMessage]
    func subscribe(agentId: String?) -> AsyncThrowingStream<ChatMessage, Error>
    func activityStream(agentId: String) -> AsyncStream<AgentActivity>
}

// Low-level actor (exposed for tests + the SyncSource impl only):
actor GatewayConnection {
    // params is [String: Any] BY DESIGN — an untyped, impl/test-only wire dict.
    // This actor is deliberately NOT the feature-facing seam; features use
    // GatewayWSSyncSource, never this. Nobody should type-model against `params`.
    func request(_ method: String, params: [String: Any],
                 timeout: Duration) async throws -> InboundEnvelope
    func events() -> AsyncStream<InboundEnvelope>
    func shutdown()
}
```

`GatewayFrames` (the builders) is **C1-internal** — it is not part of this exposed surface. Features never see it; only `GatewayConnection` calls `GatewayFrames.connect(...)` etc. to turn typed args into the `[String: Any]` a socket write needs. C1 exports `GatewayWSSyncSource` + `GatewayConnection`; it does not export the builder enum.

**C0/C1 boundary decision — where `send` lives (PINNED).** `send` lives on the **concrete `GatewayWSSyncSource` only**, not on the C0 `SyncSource` protocol. Rationale, matching live code:
- `SyncSource` stays read/subscribe-only so `DemoSyncSource` (no gateway, must stay compilable — CLAUDE.md preserves the demo path) needs no write implementation. Adding `send` to the protocol would force a demo write path that has no meaning.
- C5 reaches the write path by narrowing the shared `SyncSource` it holds: `guard let ws = sync as? GatewayWSSyncSource else { return }` then `ws.send(...)` (exactly `ChatViewModel.swift:136–140` today). In demo mode the downcast fails and send is a no-op — the correct behavior (no peer to send to).
- Because the signature is published here as part of C1's exposed surface, C5 and any worktree agent can compile against `send(agentId:text:idempotencyKey:)` with only C1's declaration in hand.

**Consumes (only via C0 or declared protocols)**
- C0 types: `GatewayAuth` (the credential contract the init accepts), `InboundEnvelope` (+ `matchesAgent`), `GatewayError`, `AgentSummary`, `ChatMessage`, `AgentActivity`, and the frame-shape contract (method names + required param keys) that C1's `GatewayFrames` builders satisfy, plus the `sync.eventsSince` / subscribe-`since` decode shapes. **C1 does NOT consume a `GatewayFrames` type from C0 — C1 defines the builders itself; C0 only pins the shape they must produce.**
- C0 protocol `ConnectSigner` — the seam that breaks the C1↔C2 cycle:
```swift
protocol ConnectSigner: Sendable {   // defined in C0, implemented in C2
    func device(nonce: String, role: String, scopes: [String],
                signatureToken: String?, signedAtMs: Int64) throws -> [String: Any]
}
```
C1 calls `signer.device(...)` at handshake time instead of importing `DeviceAuth`.

## 4. Dependencies
Allowed: **C0 only** (types + `GatewayAuth` + `SyncSource` + `ConnectSigner` + the frame-shape contract). No dependency on C2, C3, C4, or any feature.
Import rule (enforced by C10): the `Transport` module declares `import Contract` and nothing else from the app graph. `DeviceAuth`, `KeychainService`, and any `Features/*` symbol live in modules C1 does not link, so referencing them is an unresolved-symbol **build error**. The C1↔C2 cycle is structurally impossible because the only auth touchpoint is `ConnectSigner`, which lives in C0 — C1 links C0, C2 links C0, neither links the other. `GatewayFrames` staying inside the Transport module (not C0) means C0 never links C1, so the frame-shape contract cannot accidentally become a back-dependency.

## 5. Milestones / build order
1. **Frames + correlation** — `GatewayFrames` builder functions (C1-internal), `request()` id map + timeout watchdog, `events()` fan-out. Testable against a Network.framework mock gateway with golden JSON.
2. **Handshake via ConnectSigner** — challenge → `signer.device(...)` → signed connect → hello-ok; deviceToken mint/refresh callback. Swap the direct `DeviceAuth` call for the injected protocol; take `GatewayAuth` as a C0 type in the init.
3. **Read/subscribe + write path** — `SyncSource` conformance complete (`listAgents/loadInstructions/loadHistory/subscribe/activityStream`) plus concrete `send(agentId:text:idempotencyKey:)` forwarding the key to `chat.send`; backoff loop, single in-flight connect, resubscribe on reconnect.
4. **Reconnect delta (gap fix)** — resubscribe with `since: {seq, stateVersion}`; on reconnect call `sync.eventsSince`, replay events into the fan-out; on `truncated:true` fall back to `chat.history` reconciliation by `clientMessageId`. Purely internal to the reconnect loop — no new seam method. Falls back cleanly against an old gateway that ignores `since`.

## 6. Acceptance criteria
- Constructing two agent threads + roster yields exactly ONE `URLSessionWebSocketTask` (assert via injected socket-factory count in the mock).
- `GatewayFrames.message(sessionKey:text:idempotencyKey:)` produces a `chat.send` frame with method `"chat.send"` and the three required param keys — asserted against golden JSON, proving the builder satisfies C0's frame-shape contract without C0 owning the builder.
- `request()` correlates concurrent in-flight ids to the right continuation; an id with no reply resolves `.unreachable("request timed out")` at the deadline, never hangs.
- `send(agentId:text:idempotencyKey:)` forwards the caller's `idempotencyKey` byte-for-byte into the `chat.send` frame; the gateway's `<runId>:user` echo is delivered on the same subscribe stream (golden capture). A non-`ok` `res` surfaces as `GatewayError` and does not silently swallow.
- **Demo no-op boundary (pins the send-downcast decision):** a `DemoSyncSource` value held as `SyncSource` and passed through the C5 downcast (`sync as? GatewayWSSyncSource`) fails the cast and emits ZERO outbound frames — send is a silent no-op with no socket touched (assert the mock socket-factory count stays 0 and no `chat.send` is written).
- Every `events()` listener receives every dispatched event; a listener's `onTermination` deregisters it; the stream stays open across a simulated disconnect/reconnect.
- Backoff sequence is 1,2,4,8,16,**30**,30… s — the raw doubled value 32 is clamped to the 30s cap (explicit clamp assertion, not an off-by-one); single reconnect task, resubscribe fires exactly once per successful reconnect (mock asserts one `sessions.subscribe`).
- **Gap test:** mock drops a `state:"final", seq=N` during the disconnect window; after reconnect, `sync.eventsSince` replays it and the final reaches the listener — no lost event. With `truncated:true` the source instead replays `chat.history`. No public resync method is exposed — the test drives it purely by triggering a reconnect.
- `ConnectSigner` is the only auth call; grepping C1 sources for `CryptoKit`, `DeviceAuth`, `Keychain` returns nothing.

## 7. Isolation proof
An agent in a worktree builds C1 against only the `Contract` module (C0), which supplies `GatewayAuth`, `InboundEnvelope`, `GatewayError`, the model types, the frame-shape contract, `SyncSource`, and `ConnectSigner`. C1 defines its own `GatewayFrames` builders inside the Transport module — nothing to import for them. Auth is a stub conforming to `ConnectSigner` that returns a canned `device` dict — no C2 source needed. Because `send` is declared here as concrete C1 surface, the **send/idempotency acceptance test compiles against the declared interface** the moment `send` exists — a test constructs `GatewayWSSyncSource`, calls `send(agentId:text:idempotencyKey:)`, and asserts the key on the outbound `chat.send` frame, with no C5 code in the tree. The whole thing is exercised end-to-end against the existing Network.framework mock gateway with live-captured golden JSON (the pattern already in `OpenClawMobileTests`), so handshake, correlation, reconnect, the write path, the demo no-op boundary, and the gap fix are all provable with zero feature, design-system, or store code in the tree.

## 8. Status & risks
**Live/partial.** Correlation, fan-out, backoff, resubscribe, the concrete `send` write path, the `GatewayFrames` builders, and the `SyncSource` read/subscribe impl are already shipped and live-verified (`GatewayConnection.swift`; `GatewayFrames.swift` for the builders; `GatewayWSSyncSource.swift:131` for `send`; `ChatViewModel.swift:136–140` for the C5 downcast call site). Two refactors remain: (a) extract the direct `DeviceAuth` handshake call behind `ConnectSigner`, and (b) build the reconnect delta — currently reconnect re-sends `sessions.subscribe` only and can lose events in the disconnect window, orphaning spinning bubbles.

**Integration coordination (do these in the named order so two worktrees never compile duplicates):**
- **I0 — `GatewayAuth` promotion.** Today `Auth` is nested as `GatewayFrames.Auth` (`GatewayFrames.swift:6`) and the init exposes it as `GatewayFrames.Auth`, which would leak a C1 type into every feature that constructs the source. C0 defines a standalone `GatewayAuth` enum first (same `.token/.bootstrap/.none` cases + `dict`/`signatureToken`); C1 then deletes the nested `Auth`, retargets the init to `GatewayAuth`, and keeps only the frame builders in `GatewayFrames`. Ordered: **C0 adds `GatewayAuth` → C1 deletes its nested copy in the same integration**, so the two never coexist as compiled duplicates.
- **I1 — `InboundEnvelope` move.** It physically lives in `GatewayWSSyncSource.swift:272` today. C0 defines `InboundEnvelope` (+ `matchesAgent`) in the Contract module first; C1 deletes its copy from `GatewayWSSyncSource.swift` in the **same integration commit**. Ordered so two worktrees don't both compile a duplicate `InboundEnvelope`.

**Open questions / risks**
- `sync.eventsSince`, `since`, and `stateVersion` are **designed, not yet in the gateway** (C9). C1 must ship the `chat.history` fallback first so it works before C9 lands, then light up the cheap path once the daemon exists.
- The `send`-via-downcast seam (`sync as? GatewayWSSyncSource`) is the pinned contract but is fragile-by-convention: it silently no-ops for any non-WS `SyncSource`. That is intentional for demo mode (now pinned by an explicit test, see §6); if a second real (non-demo) `SyncSource` ever ships a write path, promote `send` to a narrow C0 `MessageSender` protocol rather than adding a second downcast. Not needed now (YAGNI) — one WS implementation exists.
- `GatewayConnection.request(params: [String: Any])` is untyped by design (impl/test-only, non-`Sendable` dict). It is deliberately NOT the feature-facing seam; keep it out of the feature contract so nobody models against it.
- Actor reentrancy on `ensureConnected` (two `request()`s observing `ws == nil` across an await) is handled by the single in-flight `connectTask`; keep that invariant when adding the catch-up call so a reconnect doesn't spawn two sockets.
- F0.3 (phone holds only `operator.read`+`operator.write`) is asserted, not proven; if `sync.eventsSince` turns out to require `operator.admin`, the cheap path is dead and only the `chat.history` fallback survives — the design already tolerates this.
