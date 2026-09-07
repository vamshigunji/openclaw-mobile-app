# C2 — Auth / DeviceTrust PRD

## 1. Summary
C2 owns the phone's cryptographic identity and its trust relationship with one owned Mac Mini gateway: an Ed25519 device keypair, the pairing state machine, the exact v3 device-auth signature payload, and the scoped-token lifecycle — everything needed to turn "unknown phone" into "approved operator device." It is a separate team because it is the only chunk that touches signing keys and pairing secrets, its correctness is defined entirely by golden signature vectors and a state machine (not UI, not wire framing), and it sits on the C1↔C2 cycle break: Transport (C1) needs a *signed* connect frame but must not import Auth concretely. C2 satisfies that by implementing the `ConnectSigner` protocol declared in C0, so it can be built, tested against golden JSON, and shipped in a worktree with zero knowledge of how the socket or the UI works. The signing/pairing core already exists and is LIVE-verified (`OpenClawMobile/Sources/Services/DeviceAuth.swift`, `PairingFlow.swift`); this PRD pins the boundary so it can be extracted into an isolated module that imports **C0 only** — which is not yet true today (see Status: `gatewayRunner` still constructs a Transport type inline).

## 2. Scope
**In scope**
- Ed25519 device identity: mint, persist, load — `DeviceIdentity` (CryptoKit `Curve25519.Signing`).
- `deviceId = hex(sha256(raw ed25519 public key))` derivation (LIVE-confirmed).
- The v3 signature payload builder — the exact pipe-delimited string `v3|deviceId|clientId|clientMode|role|scopes,csv|signedAtMs|token|nonce|platform|deviceFamily`, Ed25519-signed, base64url (no padding), plus metadata ASCII-normalization.
- The signed `device{ id, publicKey, signature, signedAt, nonce }` object — Auth's contribution to the connect frame.
- `ConnectSigner` implementation (the C0 protocol) — signs a connect challenge on demand.
- Pairing state machine (`PairingFlow`): idle → scanning → connecting → waitingApproval(attempt) → paired/failed, with retry through `PAIRING_REQUIRED`, timeout, cancel, expired-code, camera-denied.
- Setup-code parsing (`SetupCode`): `openclaw qr` base64url JSON blob `{url, bootstrapToken}` and bare-token paste; reject-on-empty-token.
- Scoped-token lifecycle: capture the gateway-minted `deviceToken` on hello-ok, hand it to the injected `SecretStore`, distinguish minted vs. already-approved-reconnect (`RunResult`).

**Out of scope**
- Opening the socket / sending the connect frame / correlating hello-ok — **C1 Transport**. C2 only *signs*; C1 *carries*.
- **The production `runOnce` runner** (today `PairingFlow.gatewayRunner`, lines 132-144) that constructs `GatewayWSSyncSource` and calls `DeviceIdentity.loadOrCreate()` — this is concrete Transport + Store wiring and must NOT live in Auth. It moves to **C10's composition root** (or C1). Auth only defines the `runOnce: () async throws -> RunResult` seam; the composition root supplies the concrete closure.
- The actual Keychain read/write primitive and UserDefaults prefs — **C4 Local Store**. C4 *implements* the `SecretStore` protocol (which C0 defines); C2 consumes that protocol only and never imports C4. Today `KeychainService` is a shared util slated to move behind C4's `SecretStore`.
- The `SecretStore` protocol *definition* itself — **C0 Contract** (same pattern as `ConnectSigner`).
- The pairing *screens* (QR camera view, paste field, countdown label, "run `openclaw devices approve <id>`" instruction UI) — **C7 Settings/Onboarding**. C2 exposes `PairingFlow.Step`; C7 renders it.
- DTOs, `GatewayError` taxonomy, the scope table, the `ConnectSigner` / `SecretStore` / `DeviceParams` type *definitions* — **C0 Contract**.
- Design tokens for any auth UI — **C3 Design System**.

## 3. Interface (the stable contract)
**Exposes:**
```swift
// Identity + signing (implements C0's ConnectSigner)
struct DeviceIdentity: Sendable {
    var deviceId: String { get }        // hex(sha256(rawPublicKey))
    var rawPublicKey: Data { get }
    init()                              // mint
    init(rawPrivateKey: Data) throws    // rehydrate
    func sign(payload: String) throws -> String   // base64url ed25519
    // Load-or-create via an injected C0 SecretStore (never a concrete Keychain type).
    static func loadOrCreate(store: SecretStore) throws -> DeviceIdentity
}

enum DeviceAuth {
    // The v3 payload string — the load-bearing artifact.
    static func payloadV3(deviceId:clientId:clientMode:role:scopes:
                          signedAtMs:token:nonce:platform:deviceFamily:) -> String
    // Signed device{} object for C1's connect frame (see DeviceParams below).
    static func deviceParams(identity:nonce:role:scopes:signatureToken:
                             signedAtMs:...) throws -> DeviceParams
}

// C0-declared protocol; C1 depends only on this.
extension DeviceAuth: ConnectSigner { /* sign(challenge) -> DeviceParams */ }

@MainActor @Observable final class PairingFlow {
    enum Step: Equatable { case idle, scanning, connecting,
                            waitingApproval(attempt: Int), paired(minted: Bool),
                            failed(FailureReason) }
    enum FailureReason: Equatable { case expiredCode, timeout, cameraDenied, other(String) }
    enum RunResult: Equatable { case minted(String), connected }
    // Terminal outcome of a pair() run.
    enum Outcome: Equatable { case paired, timedOut, failed, cancelled }
    var step: Step { get }
    var lastRequestId: String? { get }
    // runOnce is injected by C10's composition root (was gatewayRunner, now relocated out of Auth).
    func pair(runOnce: () async throws -> RunResult,
              storeToken: (String) -> Void) async -> Outcome
}

// bootstrapToken is NON-optional (shipped signature); parse() rejects an empty token.
struct SetupCode: Equatable { let url: String?; let bootstrapToken: String
    static func parse(_ raw: String) -> SetupCode? }
```

**Consumes (only via C0 — no sibling import):**
- **C0** `ConnectSigner` protocol — the type C2 implements; C1 depends only on this, so neither Transport nor Auth imports the other.
- **C0** `SecretStore` protocol — get/set for the raw Ed25519 private key + minted `deviceToken`. C2 depends on the *protocol*; C4 provides the concrete Keychain-backed implementation, **injected at C10's app composition root**. C2 does not know it is Keychain-backed and never writes `import Store`.
- **C0** `DeviceParams` — **NEW requirement this PRD places on C0**: a `Sendable` typed struct owning `{ id, publicKey, signature, signedAt, nonce }`. It is NOT yet in C0's `2026-07-23-api-contract-design.md`; C0's owner must add it. `deviceParams(...)` / `ConnectSigner.sign(...)` return it so C1 consumes a firm typed contribution to the connect frame rather than an untyped `[String: Any]`.
- **C0** `GatewayError` (`.pairingPending(requestId:)`, `.bootstrapExpired`, `.unauthorized`) and scope constants (`operator.read`, `operator.write`).
- Injected closures at the seam: `PairingFlow.pair` takes `runOnce` (C10/C1 performs the signed connect) and `storeToken` (persists via the injected `SecretStore`) — Auth never imports Transport or Store concretely.

## 4. Dependencies
Allowed: **C0 only** (types + `ConnectSigner` + `SecretStore` + `DeviceParams` (new) + `GatewayError` + scope table). Nothing else.

Module-import rule (enforced by C10's graph): C2 is its own module `Auth`. Its manifest declares `dependencies: [Contract]` and NOTHING more. An `import Transport`, `import Store`, `import Chat`, `import Settings`, or `import DesignSystem` inside `Auth` fails to resolve → compile error. Both cross-spine needs are protocol edges through C0, not concrete imports: the C1↔C2 cycle is impossible because `Transport` reaches Auth only through the `ConnectSigner` protocol in `Contract`; the C2→C4 secret-storage need is satisfied by the `SecretStore` protocol in `Contract`, with C4's implementation **injected at the app composition root (C10)**. The single blocker to `dependencies: [Contract]` compiling clean today is `gatewayRunner`'s inline `GatewayWSSyncSource` (C1) + `DeviceIdentity.loadOrCreate()` (implicit Keychain via C4) — relocating it (Milestone 3) is what makes this rule pass.

## 5. Milestones / build order
1. **Identity + golden signature.** `DeviceIdentity` (mint/derive/sign) + `payloadV3` builder. Ship when golden vectors (copied into the worktree from `tools/phase0-verify.mjs`) pass byte-for-byte. (Exists.)
2. **ConnectSigner + typed DeviceParams.** Wrap identity as the C0 protocol; emit the signed `DeviceParams` struct (once C0 adds the type). Ship when a mock C1 gets a frame the gateway accepts. (Exists; migrate return type from `[String: Any]` to C0's `DeviceParams`.)
3. **Relocate `gatewayRunner` + SecretStore seam.** Move the production runner (concrete `GatewayWSSyncSource` construction) out of `PairingFlow` to C10's composition root; replace `DeviceIdentity.loadOrCreate()`'s implicit Keychain and any direct `KeychainService` calls with C0's injected `SecretStore`. Ship when `Auth` compiles against `dependencies: [Contract]` with zero sibling imports. (Not done — this is the extraction-blocking task.)
4. **Pairing state machine.** `PairingFlow.pair` retry/timeout/cancel loop + `SetupCode.parse`. Ship when the state-machine suite is green against injected `runOnce` results. (Exists; already closure-driven.)

## 6. Acceptance criteria
- **Golden payload:** `payloadV3(...)` for the captured fixture inputs equals the exact string produced by `buildDeviceAuthPayloadV3` (reference vector copied from `tools/phase0-verify.mjs` into the worktree as a test fixture — the probe is not a module dependency), character-for-character (field order, csv scopes, empty-token `""`, ASCII-normalized metadata).
- **Golden signature:** `sign(payload:)` output base64url-decodes to a 64-byte signature that `isValidSignature` accepts; verifies against the public `openclaw` npm reference vector (also copied into the worktree as a fixture).
- **deviceId:** matches `hex(sha256(rawPublicKey))` for a known keypair fixture (LIVE-captured).
- **Round-trip identity:** `init(rawPrivateKey:)` of a persisted key reproduces the same `deviceId` and signatures; `loadOrCreate(store:)` against an in-memory fake `SecretStore` mints once then rehydrates on the second call.
- **DeviceParams:** `deviceParams(...)` returns a `Sendable` struct whose serialized form equals the LIVE-captured `device{}` object; no untyped `[String: Any]` crosses the boundary.
- **State machine:** injected `runOnce` throwing `.pairingPending` N times then returning `.minted` drives `waitingApproval(1..N)` → `paired(minted: true)`, returns `.paired`, and calls `storeToken` exactly once; `.bootstrapExpired` → `failed(.expiredCode)` / `.failed`; exhausting `maxAttempts` → `.timedOut`; `cancel()` → `.idle` / `.cancelled`.
- **SetupCode:** parses the LIVE base64url `{url, bootstrapToken}` blob AND a bare `^[A-Za-z0-9_-]{20,}$` token; rejects junk AND rejects a valid JSON blob whose `bootstrapToken` is empty (returns `nil`, does not misread it as a bare token).
- **Isolation gate:** the `Auth` module builds with `dependencies: [Contract]` and no `import Transport`/`import Store` anywhere in-module (grep + compile check).
- All above run against golden JSON / injected closures / an in-memory fake `SecretStore` — **no live gateway and no C4 import required in CI** (`OpenClawMobileTests` DeviceAuthTests + PairingFlow suites).

## 7. Isolation proof
An agent in a git worktree builds C2 from this PRD alone: the module declares `dependencies: [Contract]`, so once Milestone 3 lands (relocating `gatewayRunner` and moving persistence behind the injected `SecretStore`) the compiler blocks any accidental sibling import — including `import Transport` and `import Store`. Every behavior is pinned by artifacts the agent holds without touching another chunk's source — the v3 payload and signature are checked against golden vectors **copied into the worktree as fixtures** from `tools/phase0-verify.mjs` (a probe, not a sibling module, so no network or sibling access is needed), the state machine is exercised entirely through the injected `runOnce`/`storeToken` closures, and identity persistence is tested against an in-memory fake conforming to C0's `SecretStore` (the real Keychain-backed one is C4's, injected only at the C10 app root; the real socket runner is C10/C1's, injected the same way). `ConnectSigner`, `SecretStore`, and `DeviceParams` are all protocols/types the agent finds in C0. The agent never opens the socket, renders a screen, or reads Keychain — it hands a signed `DeviceParams` up and a token down through C0-declared seams. Green golden tests plus a clean `dependencies: [Contract]` compile are sufficient proof of done.

## 8. Status & risks
**Status: LIVE-verified core, extraction incomplete.** `DeviceIdentity`, `payloadV3`, `deviceParams`, `PairingFlow`, `SetupCode` exist and were confirmed 2026-07-21 against the real gateway (hello-ok + minted `deviceToken` + chat round-trip). The `Auth`-is-importable-with-`Contract`-only claim is **not yet true** — three tasks remain:
- (a) **Relocate `gatewayRunner`** (PairingFlow.swift lines 132-144): it concretely constructs `GatewayWSSyncSource` (C1) and calls `DeviceIdentity.loadOrCreate()` (implicit C4 Keychain), a live sibling dependency inside the file being extracted. Move it to C10's composition root (or C1); `PairingFlow` keeps only the `runOnce` seam. This is the blocker on the isolation claim.
- (b) **Migrate `deviceParams`'s return** from `[String: Any]` to C0's new `DeviceParams` struct (which C0 must first add — this PRD introduces that requirement; it is not in the current api-contract doc).
- (c) **Replace direct `KeychainService` / `loadOrCreate()` Keychain access** with C0's injected `SecretStore`, so Auth stops owning storage.

**Open questions / risks:**
- **No revocation / expiry / wipe story.** Scoped tokens are captured and stored but never rotated or invalidated; a lost phone stays trusted until manually removed server-side. Needs a C9/gateway-side revocation RPC + a client "forget device" path. Asserted-not-designed.
- **Key in Keychain, not Secure Enclave.** Ed25519 is CryptoKit software keys; SE is P-256-only, so the private key is not hardware-bound. Acceptable for one owned box today; revisit if threat model tightens.
- **F0.3 is asserted, not proven here.** C2 signs with `operator.read`+`operator.write` scopes on the assumption admin ops route through the main agent; C2 does not itself enforce or test the scope ceiling — that lives in C0's scope table and C6's approach-B.
- **`maxAttempts`/`retryDelay` are the calibration knob** for the human-in-the-loop approval window (default 40 × 3s = 2min); tune to real approval latency, don't hardcode away.
