# C7 — Settings / Onboarding PRD

## 1. Summary
C7 is the **front door**: the only place a phone becomes usable against a real gateway. It owns the pairing flow (QR scan + paste of an `openclaw qr` setup code) and gateway config (host URL, optional legacy token/model), and exposes a single screen, `SettingsView`. It is a separate team because onboarding is a self-contained vertical — one screen, one state-machine driver (C2's `PairingFlow`), no dependency on Chat or Roster — and because getting the "no host yet / tunnel rotated / code expired" recovery paths right (see §8) is its own design problem that shouldn't block feature teams. Everything downstream (C5 Chat, C6 Agents) is dead until C7 mints a device token; conversely C7 needs nothing from them. C7 does **not** own the `SettingsStore` *type* (that is a C0 contract — see §3); it owns only the view layer that binds it.

## 2. Scope

**In scope**
- `SettingsView` (`OpenClawMobile/Sources/Features/Settings/SettingsView.swift`) — pairing-first hierarchy: unpaired → pairing hero + "Advanced" disclosure; paired → compact status row + Advanced.
- `QRScannerView` (`.../Settings/QRScannerView.swift`) — camera capture → raw string, plus `onUnavailable` fallback to paste.
- Setup-code entry: scan **and** paste, both routed through C2's `SetupCode.parse`.
- Gateway config UI: host URL, legacy shared token, model — the manual fallback under "Advanced". C7 renders and two-way-binds these fields on the injected `SettingsStore`; it does not define, persist, or own the type.
- Pairing state rendering: the 6 `PairingFlow.Step` states + the exact `openclaw devices approve <lastRequestId>` guidance string and countdown.
- **Re-config / re-pair recovery** (see §8): "Re-pair" action, and a non-DEBUG in-app path to replace a stale host, triggered by the C0-owned `GatewayError.unreachable` signal (§5 M4).
- A user-facing "Test Connection" reachability check — rendered by C7, **executed through C0's injected `ReachabilityProbe` seam** (impl owned by C1), never a raw socket/URLSession call inside the view (see §3).

**Out of scope**
- Ed25519 keypair, v3 signature payload, pairing retry loop, token minting — **C2 (Auth/DeviceTrust)**; C7 only drives `PairingFlow` and renders `step`.
- The WS socket, bootstrap connect, reconnect, **and the concrete `/health` reachability probe** — **C1 (Transport)**; C7 never opens a socket or calls URLSession. The pairing connect is C2's `PairingFlow.gatewayRunner` closure (wraps C1); Test Connection is C1's `ReachabilityProbe` impl (behind C0's seam).
- `SettingsStore` **type definition + persistence mechanics** — the *type* is exported by **C0 (Protocol/Contract)** as the shared app-config contract; its persistence routes through C0's `SecretStore` protocol whose concrete Keychain/UserDefaults impl is **C4 (Local Store)**, injected at the composition root. C7 imports neither C4 nor `KeychainService`.
- Tokens, DTOs, `GatewayFrames.Auth`, `GatewayError` taxonomy, the `SecretStore` and `ReachabilityProbe` seams — **C0 (Protocol/Contract)**.
- Theme tokens, `MonoField`, `PrimaryButton` — **C3 (Design System)**.
- Chat threads, roster, agent create/edit — **C5 / C6**; C7 dismisses to them but never imports them.

## 3. Interface (the stable contract)

**Exposes**
```swift
struct SettingsView: View {
    @Bindable var settings: SettingsStore   // C0-owned type, injected at the app root
}
```
`SettingsView` is the only public surface. It is presented by the app root (RootTabView / AppModel), takes a bound `SettingsStore`, and calls `dismiss()` on completion. No other type in C7 is public. C7 defines **no** shared-state type of its own.

**Consumes (only via C0 or declared protocols)**
- From **C0**:
  - `SettingsStore` — the shared `@Observable` app-config **type** (host/model/token/deviceToken). Its computed accessors `wsAuth: GatewayFrames.Auth`, `isPaired`, `isConfigured` **stay on the type** in C0 — they are the shared contract surface C5 (`ChatViewModel`) and Root/AppModel also read; moving them would fork the contract. Persistence is delegated to an injected `SecretStore`, so C0 carries no Keychain import.
  - `GatewayFrames.Auth`, `GatewayError` (incl. `.unreachable`, surfaced by `PairingFlow` and the probe).
  - `SecretStore` protocol (backs `SettingsStore` persistence; C4 impl injected at root).
  - `ReachabilityProbe` seam — the contract edge for "Test Connection", mirroring `gatewayRunner`:
    ```swift
    // Declared in C0. Concrete impl (URLSession GET /health, wss→https normalize) owned by C1, injected at root.
    enum ReachabilityResult { case ok(Int), reached(Int), unreachable(String), noHost }
    typealias ReachabilityProbe = (_ host: String, _ token: String) async -> ReachabilityResult
    ```
    C7 holds the closure and renders its result; the network lives in C1, never in `SettingsView`.
- From **C2**: `PairingFlow` (`@Observable` — `step`, `lastRequestId`, `pair(runOnce:storeToken:)`, `beginScanning/cancel/reset/cameraDenied`), `SetupCode.parse(_:)`, `PairingFlow.gatewayRunner(host:code:)` as the injected connect closure.
- From **C3**: `Theme`, `MonoField`, `PrimaryButton`.

## 4. Dependencies
Allowed: **C0**, **C2** (`PairingFlow`, `SetupCode`), **C3**. Nothing else.

Module-import rule (enforced by C10's module graph): C7 is its own module `FeatureSettings` whose Package/target manifest lists dependencies `[Contract (C0), Auth (C2), DesignSystem (C3)]` only. It does **not** list `FeatureChat` (C5), `FeatureAgents` (C6), `Transport` (C1), or `LocalStore` (C4). Any `import FeatureChat`, `import Transport`, or `import LocalStore`/`KeychainService` is an unresolved-module **build error**. The `SettingsStore` type, the `SecretStore` protocol, and the `ReachabilityProbe` seam all resolve from C0 — the single hub every chunk imports. C1 is reached only transitively through two C0/C2 closures injected at the root (`gatewayRunner` for pairing, `ReachabilityProbe` for Test Connection); C4 is reached only transitively through C0's `SecretStore`. C7 holds no C1 or C4 import.

## 5. Milestones / build order
1. **Static screen + config fields.** `SettingsView` scaffold binding a stub C0 `SettingsStore`; Advanced disclosure with host/token/model `MonoField`s + a "Test Connection" button wired to a stub `ReachabilityProbe`. Ships standalone with a fake `PairingFlow` (idle only). *(largely done)*
2. **Pairing render, all 6 states.** Bind real `PairingFlow.Step` → hero UI (ladder, badges, exact `openclaw devices approve <lastRequestId>` block, countdown, failure views). Paste path via `SetupCode.parse`. *(done)*
3. **QR scan.** `QRScannerView` capture → `startPairing`; `onUnavailable` → `cameraDenied` → paste fallback. *(done)*
4. **Re-config recovery.** Non-DEBUG "host looks stale / tunnel rotated" path. **Trigger is explicit: `GatewayError.unreachable` returned by C2's `gatewayRunner` on a re-connect attempt, or a `ReachabilityResult.unreachable` from Test Connection** — both C0-owned taxonomy C7 consumes. On that signal, surface host re-entry + re-scan without a DEBUG hook; also wire the `--open-settings` QA hook (currently missing). *(TODO)*
5. **Persistence + type migration.** Relocate the `SettingsStore` *type* out of `Services/SettingsStore.swift` into the C0 Contract module and reroute its reads/writes onto C0's injected `SecretStore` (C4 impl). Only after this lands does the §6 isolation criterion hold (today the file imports `KeychainService` directly and compiles only because services are co-compiled). *(TODO)*

## 6. Acceptance criteria
- `SetupCode.parse` accepts (a) a base64url `{url, bootstrapToken}` blob, (b) a bare ≥20-char token; rejects empty, short garbage, non-base64url, and a valid blob missing `bootstrapToken`. Golden vectors from a live `openclaw qr` capture. *(C2-owned logic, asserted by C7's flow tests.)*
- Given a mock gateway that replies PAIRING_REQUIRED N times then hello-ok with a minted token: `PairingFlow.step` walks `connecting → waitingApproval(attempt:) → paired(minted: true)` and `storeToken` fires exactly once; `SettingsStore.isPaired` becomes true. Driven against the in-repo mock gateway (Network.framework), no live server.
- Failure mapping is exact: `bootstrapExpired` → `.failed(.expiredCode)`; loop exhaustion → `.failed(.timeout)` with `lastRequestId` preserved; camera denied → `.failed(.cameraDenied)` showing the paste field.
- **Approve-command golden:** in `.failed(.timeout)`/`waitingApproval` with `lastRequestId == "req-abc123"`, the rendered guidance string equals exactly `openclaw devices approve req-abc123` (snapshot/string-equality test). This is the load-bearing recovery affordance and is pinned, not just asserted "preserved".
- A QR carrying `url` sets `settings.host` before connect (`startPairing` writes it); paste without `url` leaves host unchanged.
- **Test Connection routes through the seam:** `SettingsView`'s test action invokes the injected `ReachabilityProbe` and renders its `ReachabilityResult` (ok/reached/unreachable/noHost). A test injects a fake probe and asserts the rendered string per case; a grep/review asserts **no `URLSession`, no socket, no `import Transport`** appears in `Sources/Features/Settings/`.
- **Isolation (post-M5):** `xcodebuild build` of the `FeatureSettings` module alone (C0+C2+C3 present, C1/C4/C5/C6 absent) succeeds. This passes **only after milestone 5** relocates the `SettingsStore` type to C0 and removes the direct `KeychainService` import; it is a false claim about the tree as it stands today and is gated accordingly.
- No inline colors/radii — all styling via `Theme` (C3), verified by review/grep.

## 7. Isolation proof
An agent in a fresh worktree can build C7 from this PRD alone once M5 lands. Its only inputs are C0 types (`SettingsStore`, `GatewayFrames.Auth`, `GatewayError`, the `SecretStore` and `ReachabilityProbe` seams), C2's `PairingFlow` + `SetupCode` (already defined and unit-tested in `Services/PairingFlow.swift`), and C3's `Theme`/`MonoField`/`PrimaryButton`. Every edge to C1/C4 is a closure or protocol handed in by the composition root: pairing is C2's `gatewayRunner`, reachability is C0's `ReachabilityProbe` (C1 impl), persistence is C0's `SecretStore` (C4 impl). So C7 holds no socket code, no URLSession call, and no Keychain call — it renders `step`/`ReachabilityResult` and binds a C0-owned `SettingsStore`. There is no code path from `SettingsView` into Chat or Roster (it only `dismiss()`es back to the tab host), so a sibling feature's source is never read or compiled. Against a stub root that supplies the three injected seams, C7 builds and screenshots on its own.

## 8. Status & risks
**Status: live, but two layering fixes outstanding before the isolation contract is true.** `SettingsView`, `QRScannerView`, `PairingFlow`, `SettingsStore`, and `SetupCode` all exist and are exercised in the app today; pairing was live-verified 2026-07-21 (hello-ok mint + round-trip). As it stands, `SettingsStore.swift` imports `KeychainService` and `SettingsView.swift:239` calls `URLSession.shared` directly — both violate the C10 module wall and are scheduled for M4/M5.

**Risks / open questions**
- **`SettingsStore` type ownership (now resolved, migration pending).** The type is assigned to **C0** as the shared app-config contract (consumed by C5, Root/AppModel, and C7). Today it lives in `Services/SettingsStore.swift` and writes `KeychainService`/`UserDefaults` inline; under C10's wall that is a C4 import C7 can't have. M5 must move the type into C0 and reroute persistence through C0's `SecretStore` (C4 impl injected at root). Until then, "FeatureSettings builds alone" is aspirational, not current.
- **Test Connection had no contract edge (now resolved via seam).** The raw `/health` GET is being lifted behind C0's `ReachabilityProbe` (C1 impl). This also doubles as the re-pair trigger source, so the seam earns its keep rather than being a one-off abstraction.
- **Tunnel URL rotation is the top user-facing gap.** A paired phone whose stored Quick-Tunnel host went stale has no first-class in-app recovery today — only the unimplemented DEBUG `--open-settings` hook. M4 fixes this, keyed on the now-named `GatewayError.unreachable` / `ReachabilityResult.unreachable` signals. The named-tunnel + stable-domain plan (`designs/2026-07-22-stable-tunnel-onepager-guide.md`) would retire the gap; until then it's the top onboarding-support risk.
- **F0.3 (phone holds only operator.read/write) is asserted, not proven** — C7 doesn't exercise admin scopes, so it's unaffected, but "Re-pair" assumes revocation happens gateway-side (`openclaw devices`) with no in-app revoke; confirm that's acceptable.
- **Camera permission copy** assumes the Info.plist usage string is present (platform/C10 concern); verify before shipping to device.
