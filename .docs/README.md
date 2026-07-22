# OpenClaw Mobile — docs

Five living docs, one topic each. If two ever disagree, fix them — don't rank them.

| Doc | Question it answers |
|---|---|
| [`product.md`](./product.md) | What are we building, for whom, and how should it look? |
| [`architecture.md`](./architecture.md) | How is the iOS app structured? (MVVM, services, persistence, design system) |
| [`protocol.md`](./protocol.md) | How do we talk to the gateway? (transport, handshake, device auth, scopes) |
| [`devicetrust.md`](./devicetrust.md) | **DeviceTrust** — the device trust & auth subsystem (lifecycle, components, invariants) |
| [`sync.md`](./sync.md) | How do multiple devices stay in sync? (Path E, SyncSource seam, probes P1–P7) |

`designs/` holds approved design docs (platform strategy:
`designs/2026-07-21-devicetrust-platform-design.md`).

`archive/` holds the superseded originals and the raw 2026-07-21 live-run log —
history, not guidance. `tools/phase0-verify.mjs` is the executable protocol probe.

---

## Current milestone — prove Path A is real

A phone running OpenClaw Mobile pairs to a private OpenClaw gateway over a public
`wss://` Cloudflare Tunnel, sends a text message to an agent, and streams the reply
back — **no per-user network setup**.

### Definition of done

1. **Pairing** — app completes protocol-v4 device-auth from a setup code and receives
   a scoped `deviceToken` (`hello-ok` with `operator.write`).
2. **Round-trip** — a real `session.message` to the `main` agent, streamed reply
   rendered in the chat UI.
3. **Fan-in** — a second paired device on the same session receives it live (P1) with
   equal scopes (P7).
4. **Transport** — all of it over the Cloudflare Tunnel, gateway loopback-bound.

### Status (2026-07-21 evening: DoD 1 + 2 ✅ LIVE)

| Step | State |
|---|---|
| Transport over Quick Tunnel | ✅ live-verified |
| Pairing ladder (enums, bootstrapToken, device.id) | ✅ live-verified |
| v3 signature serialization | ✅ solved + implemented (probe **and** Swift `DeviceAuth`, golden-vector tests) |
| Live `hello-ok` → deviceToken minted | ✅ **DONE** (probe device approved) |
| In-app round-trip: `chat.send` → streamed reply in chat UI | ✅ **DONE** (simulator, seeded identity; port-443 bug fixed) |
| Probes P2–P6 | ✅ live-verified (`protocol.md` §9, `sync.md` §4) |
| Two-device probes P1/P7 (DoD 3) | ⬜ needs second paired device |

### Next actions

1. Pair a **second** device (e.g. real iPhone via Settings pairing UI — needs an
   Apple dev team for device builds) and run P1/P7 (`sync.md` §3).
2. Reconnect/backoff polish: auto-resubscribe on drop, `AUTH_TOKEN_MISMATCH`
   bounded retry (`protocol.md` §3).
3. Named tunnel + own domain when ready (no app-side change).

### Out of scope

Cockpit control · push notifications · the rejected relay/Noise-XX protocol · the
named-tunnel + BFF build (seam designed in `sync.md`).
