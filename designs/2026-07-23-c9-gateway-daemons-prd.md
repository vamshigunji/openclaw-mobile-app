# C9 — Gateway Daemons (Mac Mini, UNBUILT) PRD

## 1. Summary

C9 is the server-side code that runs **inside the Mac Mini gateway box we already own** (F0.2) — not a new cloud tier, no new machine, no new trust boundary. Two unbuilt daemons plus one small new arm on an existing mechanism: an **APNs push notifier** (the only path to a backgrounded phone, since F0.1 means a sleeping phone can't poll), an **upload intake** service (file-UP into an agent's own workspace), and the **offline notifier arm of cross-device fan-out** (the online arm — a live device's socket receiving another device's event — already ships today via connection-scoped `sessions.subscribe`, §2.4; the only new work is notifying the *sleeping* phones). It's a separate team because it's the only chunk written in the gateway's runtime (Node/TypeScript, protocol-v4 server), it holds secrets no client ever sees (the APNs signing key, disk write paths), and its entire client-facing surface is a set of **new RPC shapes added to C0** — so the iOS app consumes it purely through the existing `SyncSource` seam and its shape never changes. It ships behind C0's contract; everything else is server-internal.

## 2. Scope

**In scope**
- APNs notifier daemon: holds the APNs auth key (`.p8`), decides *when* to push (an event matching a device's registered `topics` when that device has **no live socket present at broadcast time**), sends to registered devices.
- Device push registry: persist `{deviceId, apnsToken, environment, topics}` from `device.push.register`; deviceId keyed to `connect`'s `device.id` (hex sha256 of the Ed25519 pubkey).
- Upload intake daemon: `uploads.intake.begin/chunk/complete` — stream base64 chunks to disk, enforce declared `size`/`mimeType` before the agent runtime ever sees the file, land it in the requesting session's own agent workspace.
- Cross-device fan-out — **offline arm only**: the online arm (broadcast to every connection with an active `sessions.subscribe`) already exists in the gateway (§2.4). The unbuilt work is routing to the APNs notifier for a device that has no live socket at broadcast time.
- The **C0 contract additions** these daemons expose: `device.push.*`, `uploads.intake.*` method/param/response shapes + golden JSON fixtures.

**Out of scope**
- Any iOS UI, view model, or `SyncSource` conformer wiring — **C1 (Transport)** owns the socket, **C5 (Chat)** / **C6 (Agents)** own where an upload button or a push-tap deep-link lands. C9 ships the RPC; clients call it.
- Registering/scoping the device token, the Ed25519 handshake, and APNs token capture on-device (`UIApplication` registration) — **C2 (Auth)** owns device identity; C9 only trusts the `deviceId` C2 already minted onto the connection.
- The `SecretStore` / Keychain on the phone — **C4 (Local Store)**. C9's secrets live on the Mac Mini filesystem, not the client.
- Reconnect-delta (`sync.eventsSince`), approach-B command envelopes (`agents.ops.*`), binary file-DOWN, feedback/slash — separate NEW capabilities in the same contract doc, **not** C9 daemons (§4.1–4.4 of `designs/2026-07-23-api-contract-design.md`).
- The module graph that enforces all of this — **C10 (Platform/DevEx)**.

## 3. Interface (the stable contract)

C9 exposes **no Swift types of its own** — it is server code. Its contract is the set of RPC shapes it adds to C0, which C0 mirrors as DTOs in `Sources/Models/GatewayDTOs.swift` and which the client reaches only through the existing `SyncSource` seam (`Sources/Services/SyncSource.swift`). **C0 owns the declaration**; the requirements C0 would add to the `SyncSource` protocol (shown illustratively — these are new protocol requirements, not default-implementation extensions), C1 wires as WS calls, and C9 answers:

```swift
// C0 adds these as REQUIREMENTS on the existing protocol (not an extension —
// an extension gives defaults, not a boundary). C1 wires the WS call; C9 answers it.
protocol SyncSource {
    // …existing requirements…

    /// Register this device for APNs pushes. Backed by `device.push.register`.
    /// deviceId MUST equal connect's device.id; topics = events warranting a push.
    func registerPush(deviceId: String, apnsToken: String,
                      environment: PushEnvironment, topics: [PushTopic]) async throws

    /// Upload a file INTO one agent's workspace. Backed by uploads.intake.begin/chunk/complete.
    /// Returns the landed workspace path. Chunked; daemon validates size/mime before the agent sees it.
    func uploadFile(agentId: String, name: String, mimeType: String,
                    data: Data) async throws -> String   // -> agent workspace path
}

enum PushEnvironment: String, Codable { case sandbox, production }
enum PushTopic: String, Codable { case agentFinal = "agent.final", approvalNeeded = "approval.needed" }
```

**Wire shapes C9 must serve** (from `designs/2026-07-23-api-contract-design.md §4.5`):
- `device.push.register` — params `{deviceId, apnsToken, environment, topics}` → `{ok:true}`. Scope: `operator.write`.
- `uploads.intake.begin` — `{agentId, name, mimeType, size}` → `{uploadId, chunkSize}`.
- `uploads.intake.chunk` — `{uploadId, offset, data(base64)}` → `{ok:true, received}`.
- `uploads.intake.complete` — `{uploadId}` → `{ok:true, path}`. Scope: `operator.write`.
- Fan-out reuses the existing `sessions.subscribe` broadcast (§2.4) — **no new client RPC**; the offline notifier is the only new arm, and it needs no client-facing signal (the gateway already knows which `deviceId`s have live sockets).

**Consumes:** only C0 (the wire-frame conventions — `req|res|event`, scope-check, `device.id` derivation, error enum) and the gateway-internal fact that C2 has stamped the authenticated `device.id` onto the connection object (see §6 deviceId-binding assumption). No sibling chunk, no client module.

## 4. Dependencies

- **Allowed:** C0 only. C9 reads C0's frame/scope/error conventions and the `device.id` derivation rule; it **authors** the RPC shapes that C0 then ratifies into DTOs (milestone 1). C9 never edits C0-owned source — it hands the shapes over; C0 lands them.
- **Forbidden by construction:** C9 must not import any client module (C1–C8) and no client module may import C9. Because C9 is a distinct runtime (gateway Node package, not the SwiftPM graph), the wall is physical: the iOS build cannot name a C9 symbol at all. The **module-import rule** C10 enforces is that the *only* C9→client coupling is through C0's published DTOs — a client that reached for a C9-internal shape (a daemon type, a registry row) would have no module to import it from and fail to compile. The one legal edge is `C0 → (DTO mirror of C9's RPCs)`; every client touches those DTOs through `SyncSource`, never C9.

## 5. Milestones / build order

1. **Contract freeze (C0 ratifies, C9 authors the shapes).** C9 authors the `device.push.*` + `uploads.intake.*` request/response shapes and proposed golden JSON; **C0 lands them** into `Sources/Models/GatewayDTOs.swift` + test fixtures and freezes them. This is a coordination step across the module wall — C9 does not edit C0-owned source. Once frozen, client and daemon teams build in parallel against the same JSON. (Unblocks everyone; no daemon yet.)
2. **Upload intake daemon.** `begin/chunk/complete` streaming to disk with size/mime validation, landing in the requesting session's agent workspace. Lowest-risk (no APNs key, no offline logic) — proves the C9 runtime + contract end to end.
3. **Push registry + APNs sender.** Persist registrations; wire APNs (`.p8` key on the box); send on a `device.push.register` topic match. Naive first: push on every matching event.
4. **Debounce (socket-liveness) + offline fan-out arm.** Suppress a push when the target device has a live socket present at broadcast time; broadcast to other devices' live sockets first (existing online arm), notify only the offline ones. This is the "decide WHEN to push" logic flagged as the hard part.

## 6. Acceptance criteria

- **Golden-JSON parity:** every C9 RPC request/response decodes from and re-encodes to the fixtures in the C0 contract with byte-stable field names (`deviceId`, `apnsToken`, `uploadId`, `chunkSize`, `received`, `path`). Verifiable client-side with no live box.
- **Scope enforcement:** `device.push.register` and `uploads.intake.*` accept an `operator.write` token and reject a read-only or unscoped connect with the C0 error enum — provable against a mock gateway / `tools/rpc-probe.mjs`.
- **Upload validation:** a chunk stream whose bytes exceed declared `size`, or whose completed file mismatches declared `mimeType`, is rejected before the agent runtime is handed the file; the workspace path is returned only on a clean complete.
- **deviceId binding:** a `device.push.register` whose `deviceId` doesn't equal the connection's authenticated `device.id` is rejected (a device can only register itself). *Assumption made explicit:* the gateway connection object carries the C2-minted authenticated `device.id`, readable by C9 at RPC-handling time; this criterion depends on that gateway-internal fact and is void if C2 does not stamp it.
- **Debounce (socket liveness, no new contract element):** given a topic-matching event where the target device **has a live socket at broadcast time**, no APNs push is emitted; where it has **no live socket in the window**, exactly one push is emitted (no duplicate storms on reconnect). N is a tunable knob. Testable with a scripted mock socket presence table + a stub APNs sink — needs **no** client-emitted delivery signal.
- **Dead-token reap:** a `device.push.register` sent to a stub APNs sink that returns `410 Unregistered` results in the matching registry row being removed, so a rotated/uninstalled token cannot rot the registry. Testable against the stub sink, no live APNs.
- **Fan-out:** an event raised by device A reaches device B's live `sessions.subscribe` stream unchanged (existing online arm), and B's sleeping phone only via the notifier arm.

## 7. Isolation proof

One agent in a git worktree can build C9 alone: its entire input is the frozen RPC contract in `designs/2026-07-23-api-contract-design.md §4.5` plus C0's frame/scope/error conventions, the `device.id` derivation rule, and the one stated gateway-internal assumption (C2 stamps the authenticated `device.id` onto the connection) — all documents, no sibling source. It writes gateway-runtime code in a separate package that the iOS SwiftPM graph cannot even name, so there is no source file a client owns that C9 edits and none of C9's that a client edits; the only shared artifact is the golden JSON, which C0 freezes and both sides pin independently. The daemons can be exercised end to end against `tools/rpc-probe.mjs`, a scripted socket-presence table, and a stub APNs sink without a single iOS build. The client half proceeds in parallel against the same fixtures — neither team blocks the other after milestone 1.

## 8. Status & risks

**Status: UNBUILT.** Nothing here exists — no daemon, no registry, no APNs integration, no intake service. The client-facing contract is *sketched* (`§4.5`, explicitly "sketch only, not a committed contract"); milestone 1 is for C9 to author the shapes and C0 to freeze them before either side builds.

**Risks / open questions:**
- **F0.3 is asserted, not proven.** The push register scope is claimed `operator.write` (device registering itself), but the whole approach-B premise rests on an unverified scope table — verify with `tools/rpc-probe.mjs` before committing (review finding F1, `designs/2026-07-23-superapp-system-architecture.md §0`).
- **deviceId binding assumes an unstated gateway fact.** The isolation and test story depend on C2 having stamped the authenticated `device.id` onto the connection object, readable by C9 at RPC time (§6). If that binding isn't there, deviceId enforcement moves out of C9 and back into the handshake — confirm with C2 at contract freeze.
- **Debounce is socket-liveness, not delivery-ACK.** Resolved: the daemon suppresses on *server-observed live socket present at broadcast*, which the gateway already tracks — **no new client-facing ACK RPC/event, no C0 contract change**. Remaining real work is picking N and defining "live" (raw socket open vs active `sessions.subscribe`); leave N a tunable knob, not a constant.
- **APNs environment split.** `sandbox` vs `production` must key off the registered `environment`; a wrong-env token fails silently at Apple. Covered by the §6 dead-token reap criterion (410 → registry row removed), but the reap only fires on send — a never-sent-to stale token lingers until its next event.
- **Upload size ceiling / backpressure.** Base64-over-WS chunking (`chunkSize` 262144) is simple but has no resumability and competes with the live event stream for the one socket; acceptable for photos, a known ceiling for large files — upgrade to a side channel only if it measurably hurts.
- **No push entitlement / provisioning yet.** APNs needs an Apple Developer team + push capability + a `.p8` key on the box; device builds already lack a signing team (CLAUDE.md) — this is a prerequisite outside the code.
