# DeviceTrust — the device trust & auth subsystem

**DeviceTrust** is the name for everything that establishes and maintains trust
between a device and an OpenClaw gateway: identity → pairing → human approval →
scoped tokens → revocation. It is the platform layer under OpenClaw Mobile
(strategy: `.docs/designs/2026-07-21-devicetrust-platform-design.md`); the wire
protocol it implements is specified in `.docs/protocol.md` §3–§6.

## Why "DeviceTrust" and not "auth"

Plain token auth answers "do you know the secret?". DeviceTrust answers "is this
*specific device* known, approved by a human, and still in good standing?" — the
trust is literally a human approving the device. One name for the whole lifecycle,
used in docs, code, and product.

## The lifecycle

```
┌────────────┐   setup code    ┌────────────┐   operator     ┌────────────┐
│ 1. IDENTITY │ ──────────────▶ │ 2. PAIRING │ ─────────────▶ │ 3. STANDING │
│ keypair     │  signed connect │ pending    │  approve       │ deviceToken │
│ minted once │                 │ request    │  (human gate)  │ per-connect │
└────────────┘                 └────────────┘                └────────────┘
```

1. **Identity (once per device).** The app mints an Ed25519 keypair; the private
   key lives in the iOS Keychain and never leaves the device (Keychain, not
   Secure Enclave — SE is P-256-only). The device's identity is
   `deviceId = hex(sha256(raw public key))`.
2. **Pairing (once per gateway).** The user scans/pastes a setup code
   (base64url JSON `{url, bootstrapToken}` — the INNER token goes in
   `auth.bootstrapToken`). The app answers the gateway's `connect.challenge`
   with a v3-signed `device{}` object. The gateway holds the request as
   `PAIRING_REQUIRED` (retryable) until the operator approves the exact
   requestId. Approval mints a device-bound **deviceToken** with operator scopes.
3. **Standing (every connection).** Steady-state connects present the
   deviceToken *plus* a fresh challenge signature — a stolen token is useless
   without the device's private key. The gateway re-issues the deviceToken on
   each hello-ok; the app persists the latest. Revocation is per-device on the
   gateway.

Every step above was verified against a live gateway on 2026-07-21 (first
`hello-ok`, minted deviceToken, in-app round-trip).

## Component map (repo)

| Component | Code | Role |
|---|---|---|
| DeviceIdentity | `Sources/Services/DeviceAuth.swift` | Ed25519 keypair, Keychain persistence, deviceId derivation |
| DeviceAuth signing | `Sources/Services/DeviceAuth.swift` | v3 pipe-string payload + signature, `device{}` builder |
| Connect frames | `Sources/Services/GatewayFrames.swift` | auth precedence (`token` > `bootstrapToken`), signed connect |
| Pairing flow | `Sources/Features/Settings/SettingsView.swift` (`pair()`), `GatewayWSSyncSource.connectOnce()` | setup code → approval-wait loop → token capture |
| Token lifecycle | `Sources/Services/SettingsStore.swift` (`deviceToken`, `wsAuth`) via `KeychainService` | persistence + auth selection |
| Reference impl / probes | `tools/phase0-verify.mjs`, `tools/phase0-roundtrip.mjs` | Node reference, live verification |
| Golden tests | `Tests/DeviceAuthTests.swift`, `Tests/ConnectFrameTests.swift` | pin serialization to the reference — the signature format can never silently drift |

## Invariants (do not break)

- The private key never leaves the device; only signatures travel.
- `deviceId` = sha256 of the **raw** 32-byte public key, hex-encoded.
- The v3 payload is a pipe-delimited string (`.docs/protocol.md` §5), NOT JSON;
  the *signatureToken* is `auth.token ?? auth.bootstrapToken ?? ""`.
- `signedAt` must be fresh; `nonce` must echo the gateway's challenge.
- CryptoKit Ed25519 signatures are randomized — test interop by *verification*
  against the Node reference, never byte-equality.
- Scopes are sent pre-normalized (sorted, implied included).

## Platform direction (approved 2026-07-21)

A→B sequence: the reliable client first (wedge: **pairing that works the first
time**), then the DeviceTrust platform — managed named tunnels on the customer's
own Cloudflare account, then fleet dashboard/push behind a demand gate. Honest
trust boundary: DeviceTrust secures *auth* end-to-end; payload encryption is an
upstream protocol-v4 gap — whoever terminates TLS can see traffic. Details and
premises: the design doc above.
