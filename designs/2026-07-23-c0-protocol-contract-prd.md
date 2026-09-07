# C0 — Protocol/Contract (keystone) PRD

## 1. Summary

C0 is the single source of wire truth for OpenClaw Mobile: the Swift DTOs, RPC frame builders, event/envelope shapes, the scope table, idempotency rules, the `GatewayError` taxonomy, and the seam protocols (`SyncSource`, `ConnectSigner`) that every other chunk imports. Today these live inline in the one app target (`Sources/Models/GatewayDTOs.swift`, `Sources/Services/GatewayFrames.swift`, `SyncSource.swift`, `AgentSummary.swift`, `AgentActivity.swift`, `ChatMessage.swift`) — and, critically, `InboundEnvelope` + `matchesAgent` are today buried *inside* a transport file (`Sources/Services/GatewayWSSyncSource.swift`, struct at L272, method at L340). C0's job is to **extract all of these into their own dependency-free module** and freeze them as a versioned contract. It is a separate team because it is the one keystone every spine and feature chunk depends on and the *only* place a change ripples across teams — isolating it lets the other 10 chunks compile against a stable boundary in parallel while contract changes flow through a single owner and review gate.

## 2. Scope

**In scope**
- Extract a standalone module (`OpenClawContract`) via XcodeGen `project.yml` — no app/UI/network code inside it.
- `GatewayDTOs`: `AgentSummary`, `AgentActivity`, `ChatMessage`, `InboundEnvelope`, and the reconnect-delta / approach-B command DTOs specified in `designs/2026-07-23-api-contract-design.md`.
- **REST-convenience DTOs** (single-turn OpenAI-style path, NOT the WS backbone): `ChatRequest` (Encodable) and `ChatStreamChunk` (Decodable), used by `GatewayClient`/`SSEDecoder`. Included in the contract but labelled distinctly so a reader does not mistake them for live WS-verified shapes.
- `GatewayFrames`: outbound request builders (`connect`, `subscribe`, `history`, `message`, `agentsList`) and the canonical `scopes` list.
- **Event routing surface**: `InboundEnvelope` and `matchesAgent` — which today do NOT live in a models file but inline in `Sources/Services/GatewayWSSyncSource.swift` (a C1-owned transport file). Extracting them into C0 is explicit M1 work (see §5), because `AgentActivity.from(_ env: InboundEnvelope)` (`AgentActivity.swift:50`) depends on the type — leaving `InboundEnvelope` in a C1 file while moving `AgentActivity` to C0 would fail to compile.
- Event shapes + the routing key rules (`agentId`, canonical session key `agent:<id>:main`, `InboundEnvelope.matchesAgent`).
- The **scope table** (`operator.read` / `operator.write` / `operator.admin`) as data, and the assertion that the phone holds only read+write (F0.3).
- **Idempotency rules** (client key on `chat.send`, echo-dedupe contract).
- `GatewayError` taxonomy (the 5 cases, verbatim).
- Seam protocols **exposed**: `SyncSource`, and a new `ConnectSigner` (defined here to break the C1↔C2 cycle).
- **Golden-JSON corpus**: extract the live-captured JSON currently inlined as string literals in `Tests/WireProtocolTests.swift` into named `.json` fixtures shipped as a test resource, plus a Swift accessor so any chunk can decode against them.

**Out of scope** (owner named)
- The socket / reconnect / backoff that *uses* these frames — **C1 Transport** (`GatewayConnection`, `GatewayWSSyncSource`). Note: C1 keeps the *behavior* of `GatewayWSSyncSource` but no longer owns `InboundEnvelope`/`matchesAgent` — those move to C0; C1 imports them.
- Ed25519 signing / payload-v3 / pairing state machine that *implements* `ConnectSigner` — **C2 Auth** (`DeviceAuth`, `PairingFlow`).
- The REST/SSE *client* that consumes `ChatRequest`/`ChatStreamChunk` (`GatewayClient`, `SSEDecoder`) — **C5 Chat / demo path**. C0 owns only the DTO shapes.
- Design tokens, `MonoField`/`PrimaryButton` — **C3 Design System**.
- Persistence of conversations/keys — **C4 Local Store**.
- Any view or view model (chat, roster, settings, surfaces) — **C5–C8**.
- New gateway-side RPC handlers/daemons that answer these shapes — **C9 Gateway**.
- The module-graph enforcement build rule itself — **C10 Platform/DevEx** (C0 only ships the module; C10 wires the dependency police).

## 3. Interface (the stable contract)

Each exposed type is tagged **[LIVE]** (live-verified, test-pinned against captured gateway JSON) or **[PROPOSED]** (Swift shape frozen here, but the matching gateway handler is unbuilt — see §8). This honest-status split is part of the public surface, not just prose.

**Exposes** (public surface of `OpenClawContract`):

```swift
// Frames — outbound RPC builders (params dictionaries, transport-agnostic)   [LIVE]
public enum GatewayFrames {
    public enum Auth { case token(String), bootstrap(String), none }
    public static let scopes: [String]                          // ["operator.read","operator.write"]
    public static func connect(auth: Auth, device: [String:Any]?) -> [String:Any]
    public static func subscribe() -> [String:Any]
    public static func history(sessionKey: String) -> [String:Any]
    public static func message(sessionKey: String, text: String, idempotencyKey: String) -> [String:Any]
    public static func agentsList() -> [String:Any]
    // + reconnect-delta / agents.ops (approach-B) builders per api-contract doc   [PROPOSED]
}

// WS-backbone DTOs + events                                                    [LIVE]
public struct AgentSummary: Codable, Sendable { ... }
public enum   AgentActivity: Sendable { ... }               // .from(_ env: InboundEnvelope) verb mapping
public struct ChatMessage: Sendable, Identifiable { ... }
public struct InboundEnvelope: Decodable {                  // type ∈ {req,res,event}
    public func matchesAgent(_ agentId: String?) -> Bool
}

// REST-convenience DTOs — single-turn OpenAI-style path (GatewayClient/SSEDecoder),
// NOT the WS backbone. Included for the demo/REST path only.                    [LIVE, REST]
public struct ChatRequest: Encodable { ... }
public struct ChatStreamChunk: Decodable { ... }

public enum GatewayError: LocalizedError {                  // frozen taxonomy   [LIVE]
    case unauthorized
    case unreachable(String)
    case badStatus(Int)
    case pairingPending(requestId: String?)
    case bootstrapExpired
}

// Seams
public protocol SyncSource: Sendable { /* listAgents/loadHistory/subscribe/activityStream/loadInstructions */ }  // [LIVE]
public protocol ConnectSigner: Sendable {                   // cycle-breaker: C1 imports, C2 implements   [PROPOSED]
    func signedDevice(challengeNonce: String, token: String?, signedAtMs: Int64) throws -> [String:Any]
}

// Golden fixtures
public enum GoldenFixtures { public static func json(_ name: String) -> Data }   // [LIVE]
```

**Consumes**: nothing but Foundation. C0 sits at the graph root (F0.2 — one owned box, one contract).

## 4. Dependencies

Allowed: **Foundation only**. C0 imports no sibling chunk, no spine chunk, no UI.

Module-import rule (enforced by C10): `OpenClawContract` is its own XcodeGen target declaring **zero internal `dependencies:`**. Any `import` of `OpenClawTransport`, `OpenClawAuth`, `OpenClawDesign`, a feature module, or the app target from inside `OpenClawContract` is a compile error because those modules are not linked into it — the linker cannot resolve the symbol. C10's module graph makes the reverse direction one-way: everyone `import OpenClawContract`; C0 imports no one.

## 5. Milestones / build order

1. **M1 — Carve the module (incl. the buried envelope).** Add `OpenClawContract` target to `project.yml`; move `GatewayDTOs.swift`, `GatewayFrames.swift`, `SyncSource.swift`, `AgentSummary.swift`, `AgentActivity.swift`, `ChatMessage.swift` into it. **Then explicitly extract `InboundEnvelope` (struct, `GatewayWSSyncSource.swift:272`) and its `matchesAgent` method (`:340`) OUT of `GatewayWSSyncSource.swift` into a new `InboundEnvelope.swift` in the module** — this file is otherwise a C1 file and out of C0's move list, so the extraction must be named, not assumed. `AgentActivity.from(_:)` (`AgentActivity.swift:50`) then resolves the type from C0, not from a C1 transport file. Leave `GatewayWSSyncSource.swift` (minus the extracted type) in place for C1; it now `import OpenClawContract`. Mark the exposed surface `public`. App target `import OpenClawContract`; `xcodegen generate` + build green.
2. **M2 — Define `ConnectSigner`.** Add the protocol (the C1↔C2 cycle-breaker); C1/C2 have not shipped yet, so this is one of only two net-new types C0 authors rather than extracts.
3. **M3 — Golden corpus.** Extract the inline JSON literals from `Tests/WireProtocolTests.swift` into `Fixtures/*.json` (connect challenge, hello-ok, chat delta, agents.list, activity events), ship as module test resource, add `GoldenFixtures.json(_:)` accessor, repoint `WireProtocolTests` at the files.
4. **M4 — Contract doc + version stamp.** Fold `designs/2026-07-23-api-contract-design.md` into the module as the canonical catalog; add a `ContractVersion` constant so a bump is the visible ripple signal.

## 6. Acceptance criteria

- `xcodegen generate && xcodebuild -scheme OpenClawMobile build` is green with the contract in a separate module and the app importing it.
- **`InboundEnvelope` and `matchesAgent` compile from inside `OpenClawContract`, not from `GatewayWSSyncSource.swift`**: a grep of `Sources/Services/GatewayWSSyncSource.swift` for `struct InboundEnvelope` and `func matchesAgent` returns nothing, and `AgentActivity.from(_:)` resolves `InboundEnvelope` from the module. (Guards the blocking non-overlap/isolation failure.)
- Every extracted type round-trips its golden fixture: `try JSONDecoder().decode(T.self, from: GoldenFixtures.json("…"))` succeeds for `InboundEnvelope`, `AgentSummary`, `ChatStreamChunk`, activity events — decoding is pinned to **verbatim live-captured** JSON, never hand-invented (per CLAUDE.md).
- `GatewayFrames.message(...)` output matches the live-verified frame in `WireProtocolTests` **field-by-field (method + params keys)** — not byte-for-byte, since frames are `[String:Any]` with non-deterministic key ordering (this is exactly how the existing `WireProtocolTests` compare) — including the `:18789`-not-appended host rule.
- `GatewayError`'s 5 cases and `matchesAgent` routing are unchanged (existing tests still pass unmodified).
- `scopes == ["operator.read","operator.write"]`; a golden fixture proves an `operator.admin` method (`agents.create`) is *not* in the phone's set (F0.3 encoded as data).
- Grepping the module's sources for `import OpenClaw` (any sibling) returns nothing; the target's `dependencies:` list is empty.

## 7. Isolation proof

An agent in a fresh git worktree can build C0 from this PRD alone: every type it must expose **already exists** inline in the current target — the models files, plus `GatewayFrames.swift`/`SyncSource.swift`, plus `InboundEnvelope`/`matchesAgent` which today sit inside `GatewayWSSyncSource.swift` (L272/L340) and are lifted out into their own module file in M1. The work is *moving and re-homing* these, not designing them. The only genuinely new types, `ConnectSigner` and `ContractVersion`, are fully specified in §3/§5 with no sibling code required to compile them (C1/C2 don't exist yet and don't need to). The golden corpus is a copy-out of JSON already captured in `Tests/WireProtocolTests.swift`. C0 links only Foundation; after M1 there is no sibling source it needs to touch — it hands the de-envelope'd `GatewayWSSyncSource.swift` back to C1, which will `import OpenClawContract` when C1 ships. The module compiles and its tests decode against static fixtures with zero live gateway and zero other chunk present.

## 8. Status & risks

**Status: partial (live types, no module; one type mis-homed in a C1 file).** The DTOs, frames, `SyncSource`, `InboundEnvelope`, and `GatewayError` are real, live-verified, and test-pinned against captured gateway JSON — but they sit **inline in the single app target**, and `InboundEnvelope`/`matchesAgent` specifically sit inside the transport file `GatewayWSSyncSource.swift`, which C1 otherwise owns; the extraction into `OpenClawContract` is unbuilt. `ConnectSigner` does not exist yet (today `DeviceAuth` is called directly). The golden JSON exists only as **inline string literals** in `WireProtocolTests`, not a reusable corpus.

**Open questions / risks**
- **F0.3 is asserted, not proven** — the scope table encodes "phone = read+write only" as fact; if the gateway ever grants the device token `operator.admin`, approach-B and this table are both wrong. C9 should confirm against a live `connect` scope echo.
- Some gateway versions key events by `method` instead of `event` (noted in the api-contract doc) — the golden corpus must capture both variants or `InboundEnvelope` decoding is version-fragile.
- The five *new* capabilities in `designs/2026-07-23-api-contract-design.md` (reconnect delta, structured approach-B commands, binary file-down, quick-feedback, deferred push/upload) are **unspecified upstream — proposed** (tagged `[PROPOSED]` in §3); C0 can freeze their Swift shapes, but C9 must implement the matching handlers before they're anything but aspirational DTOs.
- `ChatRequest`/`ChatStreamChunk` are the REST/SSE single-turn convenience path, not the WS backbone — freezing them in C0 is fine, but a consumer must not treat them as the live WS-verified contract the rest of §3 describes.
- `GatewayFrames` returns `[String:Any]` (not `Encodable`), so the compiler can't catch a malformed frame — and `[String:Any]` has no stable key order, which is why the M3 golden-frame guard is **field-by-field**, not byte equality. Keep those tests; they are the only guard.
