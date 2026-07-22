# Multi-device sync — Path E and the SyncSource seam

How N devices belonging to one operator stay Slack-synced against one gateway, and
how that choice leaves room for a future platform. Full path analysis (A–E scorecard)
is in `archive/prd-handshake.md`; this doc keeps the decision and what's live.

## 1. The decision — Path E: build A now, design the seam to D

- **Path A (built):** thin clients, the gateway is the sync bus. Every device pairs
  independently (own Ed25519 key + device-bound token — `protocol.md`), subscribes via
  `sessions.messages.subscribe`, and sends over WS `session.message`. Sync is a side
  effect of the protocol; local JSON persistence is a *cache* rebuilt from
  `snapshot` + `stateVersion`/`seq`.
- **Path D (designed, not built):** a BFF next to the gateway with durable history,
  search, push, and per-user auth — the "Slack server". It slots in behind the same
  client seam when the platform need is real.
- Rejected: primary-device relay (same shape as the rejected relay architecture) and
  client-side CRDT/iCloud (solves conflicts the append-only model doesn't have).

**A's one structural weakness** is history durability: past gateway retention, a fresh
install can't backfill from snapshot alone. Probe P6 measures that depth — its result
is what *dates* Path D.

## 2. The seam

The app depends on one protocol for fan-in
(`OpenClawMobile/Sources/Services/SyncSource.swift`):

```swift
protocol SyncSource: Sendable {
    func loadHistory(sessionId: String) async throws -> [ChatMessage]
    func subscribe(sessionId: String) -> AsyncThrowingStream<ChatMessage, Error>
}
```

- Today: `GatewayWSSyncSource` (protocol-v4 WS) and `DemoSyncSource` (standalone demo
  mode — must be preserved).
- Path D: a `BFFSyncSource` backs the same two methods; swapping the conformer is a
  one-line change in the composition root. Chat UI, optimistic-send, idempotency
  dedup, and cache logic don't change.

Two deliberate boundaries:
1. **Send is not abstracted.** The write path stays WS `session.message` + client
   idempotency key. A send abstraction waits until Path D is scoped.
2. **Cache authority can shift, not cache shape.** If P6 shows shallow retention,
   `loadHistory` moves from "gateway snapshot" to "BFF durable store" — same
   signature, deeper answer.

## 3. Verification probes P1–P7 (the falsifiers)

Run by `tools/phase0-verify.mjs`; live verdicts are human checkpoints (P1/P7 need two
paired devices). **P1 + P2 are hard gates for Path A/E.**

| # | Probe | If it fails |
|---|---|---|
| P1 | Peer broadcast fan-out: device-2 receives device-1's `session.message` live | Path A collapses → C or D |
| P2 | WS write attaches to the session (vs REST single-turn) | write-path decision reopens |
| P3 | Sender receives own message echoed | dedup keyed on P4 id |
| P4 | Broadcast carries a server message id | rely on client idempotency (P5) |
| P5 | `session.message` accepts a client idempotency key | sends gated on ack |
| P6 | Snapshot/replay backfill depth after offline gap | shallow ⇒ Path D moves up |
| P7 | Remote-paired (`wss://`) device gets same scopes as loopback-paired | multi-device blocked |

**Status: all pending** — they unlock once pairing completes live (`protocol.md` §9).
Defensive default regardless of P5: every send carries a client idempotency key.

## 4. Status ledger (live runs)

- [x] Transport end-to-end over Cloudflare Quick Tunnel (`/health` 200, `connect.challenge` received)
- [x] Enum/auth-field/device-id gates learned and fixed (ladder in `protocol.md` §5)
- [x] v3 signature serialization implemented + selftested (`phase0-verify.mjs --pair`)
- [x] **Live `hello-ok`** (2026-07-21): scopes `[operator.read, operator.write]`, deviceToken minted
- [x] **Live round-trip** (`phase0-roundtrip.mjs` + in-app): `chat.send` → streamed reply rendered
- [x] P2 ✅ (chat.send over WS attaches to session) · P3 ✅ (self-echo, `<runId>:user`)
      · P4 ✅ (`messageId`/`messageSeq`/`seq`) · P5 ✅ (idempotencyKey adopted as runId)
      · P6 ✅ (chat.history backfills prior sessions' messages)
- [ ] P1 / P7 (need a second paired device live)
- [ ] In-app: device-1's message appears on device-2 in-order within ~1s, no dups
