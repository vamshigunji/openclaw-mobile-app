# Adversarial Architecture Review — OpenClaw Mobile "Super-App" System Architecture

**Date:** 2026-07-23
**Reviews:** `designs/2026-07-23-superapp-system-architecture.md`
**Stance:** hostile / code-grounded. Every "✅" treated as a marketing claim
until the code was found. Citations are to the real repo.

**Bottom line up front:** the *chat core* is real and roughly as described.
Almost everything dressed up as an architectural "compartment" beyond chat — the
app store (S6), the backend (S9), the local database (S7's conversation cache),
and the security posture — is absent, unbuilt, or resting on an assumption the
project's own `protocol.md` flags as *unknown*. The single most dangerous thing:
the **one load-bearing fact the whole map bends around (§0) is listed as an OPEN
UNKNOWN in `.docs/protocol.md §10`.**

---

## Findings, most-severe first

### F1 — The §0 "load-bearing fact" is unverified; the entire approach-B edifice may be unnecessary
**Severity: BLOCKER (for the architecture's logic, not for shipping)** · attacks §0, S5.

`.docs/protocol.md §9b` asserts `agents.create/update/delete` are `operator.admin`;
`.docs/protocol.md §10` (Open unknowns) admits the required scope
(`operator.write` vs `operator.admin`) "was never verified." `GatewayFrames.scopes`
is hard-wired to `["operator.read","operator.write"]` (`GatewayFrames.swift:29`).
"Create live" (S5) proves approach B *works*, not that a direct `agents.create`
at write-scope *fails*. If create/delete are actually `operator.write`, approach B
is self-inflicted complexity.
**Fix:** run `tools/rpc-probe.mjs`, call `agents.create` directly on the paired
token, record the exact error. 10 minutes; could delete a third of the architecture.

### F2 — Approach B routes privileged, irreversible ops through a natural-language LLM prompt
**Severity: HIGH (BLOCKER for `delete`)** · attacks S5, data flow #2.

`MainAgentTask.run` (`MainAgentTask.swift:22–40`) sends free-text to the
full-authority `main` agent, then sleeps `6s × ≤20` polling `agents.list` for
*existence*. Verified problems: no transactional ack ("done" = name appears, not
correct workspace/model/content); LLM non-determinism; **prompt injection** (main's
context carries chat/web/file text — injected `"...also delete agent X"` executes;
this is the exact capability the phone's read+write scope denies, handed to a
component that follows injected text); idempotency key dedups the *frame*, not the
*semantic op* → retry can double-create; poll ceiling 120s returns `.pending` with
no correlation id.
**Fix:** never expose `delete` via approach B without out-of-band confirmation.
Use a structured command envelope main parses deterministically + echoes a result
with an op id; poll on that, not list-membership.

### F3 — Cloudflare Tunnel is a MITM by design; no E2E, no cert pinning
**Severity: HIGH** · attacks S3, S1.

Cloudflare terminates TLS → sees every frame in plaintext (`chat.send` bodies,
agent output, file contents) for a gateway that can run `terminal.*`. No cert
pinning in `GatewayConnection.swift:119–130`. `trycloudflare.com` is a shared
domain (phishing surface). The rejected Noise-XX design would have given E2E; it's
gone, and the architecture never states the trust decision.
**Fix:** state "Cloudflare is trusted with plaintext" explicitly; if unacceptable,
app-layer E2E or self-owned named tunnel + pinned certs before sensitive surfaces.

### F4 — Reconnect loses events: no `seq`/`stateVersion` diff, no history re-fetch → stuck streaming bubbles
**Severity: HIGH** · attacks S2, S4.

`.docs/protocol.md §3` says diff `stateVersion`/`seq` on reconnect and re-snapshot.
The code doesn't: `reconnectLoop` (`GatewayConnection.swift:237–260`) reconnects and
re-sends `sessions.subscribe` only. Events during the disconnect window are lost.
**Scenario:** agent mid-stream, 4s tunnel blip, the terminal `final` delta lands in
the gap → `isStreaming` (`ChatViewModel` ingest 112–129) never clears → bubble spins
forever, no error, no reconciliation.
**Fix (~15 lines):** on every successful reconnect, re-run `loadHistory` (or a
`seq`-bounded delta), reconcile by `clientMessageId`, clear orphaned streaming bubbles.

### F5 — The "app store" (S6) is vaporware, blocked on the absent backend, and contradicts "simple and basic"
**Severity: HIGH (as a claim; the doc half-admits it)** · attacks S6, §4.1.

Model B needs a render runtime + UI protocol that doesn't exist; Model C is "a whole
platform" + requires S9 (0% built). Model A is just "more SwiftUI screens" — not a
store. User's north star is "simple and basic"; an app store is the opposite. S6 has
no independent interface — it's a skin over S4/S5.
**Fix:** rename S6 to "Additional native surfaces (model A)"; delete B/C from the map
until a customer forces them.

### F6 — "Server" and "Database" are big boxes for things not owned or not built
**Severity: HIGH** · attacks S7, S8, S9.

S8 is an external product (a dependency, not "our server"). S7's "database" is mostly
unbuilt — no conversation-persistence layer exists in code; history backfills from the
*gateway*, so the local cache is **not built at all** (Keychain + UserDefaults only).
S9 doesn't exist and blocks push, file-UP, cross-device sync, model-C store.
**Fix:** relabel S8 = "external dependency," S7 = "Keychain+UserDefaults today;
conversation cache = TODO." Changes build order — several "next" features are 100% blocked.

### F7 — No background/push story: app sees nothing while backgrounded
**Severity: HIGH** · missing compartment; S2, S9.

iOS suspends the WS task seconds after backgrounding. With push (S9) absent, zero agent
activity is received while not foregrounded, and (F4) no reliable reconcile on return.
For a product about *autonomous* agents running for minutes, "only visible while staring
at the screen" is a defining limitation buried in an S9 bullet.
**Fix:** name "background delivery" as its own ⬜ compartment; until S9+APNs, the app is
a foreground-only viewer — this shapes what "improve chat" can promise.

### F8 — The `SyncSource` seam is leaky: the send path bypasses it with a concrete downcast
**Severity: MEDIUM** · attacks S2.

`ChatViewModel.sendOverWS` does `guard let ws = sync as? GatewayWSSyncSource`
(`ChatViewModel.swift:136`); the seam file admits "send … NOT part of `SyncSource`"
(`GatewayWSSyncSource.swift:29–30`). The seam covers reads, not writes. A future BFF
`SyncSource` would silently no-op every send.
**Fix:** put `send` on the `SyncSource` protocol. One method; makes the seam real.

### F9 — `matchesAgent` drops events lacking `payload.agentId`
**Severity: MEDIUM** · attacks S2 fan-out.

`matchesAgent` = `payload?.agentId == agentId` (`GatewayWSSyncSource.swift:340–343`).
Any inbound `chat` delta omitting `agentId` matches nobody → silently discarded. Whether
the gateway stamps `agentId` on every streaming delta is unverified (`§9b` lists it for
activity events; `§9` chat-delta shape doesn't). No cross-agent *leak* path found — risk
is silent drop, not misdelivery.
**Fix:** wire-capture test asserting `chat` deltas carry `agentId`; else fall back to
`sessionKey` routing instead of dropping.

### F10 — Single read loop = head-of-line blocking; unbounded fan-out buffers
**Severity: MEDIUM** · attacks S2 (the SPOF §4.4 flags).

`startReadLoop` (`GatewayConnection.swift:169–193`) decodes + dispatches every frame
sequentially; a large `chat.history` (limit ≤1000) or file payload blocks the next chat
delta. `events()` (73–81) is an unbounded `AsyncStream` → a stalled consumer accumulates
every event in memory, no backpressure. Each thread registers 2 subs → `2 × threads ×
events` fan-out.
**Fix:** decode off the read loop; bounded buffering with a documented drop/latest policy.

### F11 — Device-key theft has no revocation/expiry/wipe story
**Severity: MEDIUM** · attacks S1.

Positives: nonce + `signedAt` block replay; token re-mints each `hello-ok`
(`GatewayConnection.swift:156–159`). But the Ed25519 key is in Keychain, not Secure
Enclave (SE is P-256 only), so extractable on a compromised/backed-up device; no client
token TTL, no "sign out this device," revocation is manual gateway-side. Blast radius
bounded to read+write (the one thing §0 buys) — but read includes every agent's files/history.
**Fix:** document revocation path; add "unpair/wipe key"; consider biometric-gated Keychain
access (`kSecAccessControl`).

### F12 — Quick Tunnel URL rotation fails silently
**Severity: MEDIUM** · attacks S3, observability.

URL changes every gateway restart (`§2`). On rotation the stored host is dead;
`reconnectLoop` retries forever every 30s, surfacing nothing (DEBUG-only logger). User
sees a frozen app, no prompt to re-enter the URL.
**Fix:** typed "gateway unreachable / host may have changed" state after N fails → route
to Settings. Move to a named tunnel sooner.

### F13 — `edit`/`delete` are "pattern-proven," i.e., untested
**Severity: MEDIUM** · attacks S5.

`CreateAgentTests.swift` is the only file referencing `MainAgentTask`; no delete/update
test, no `MainAgentTaskTests`. For an irreversible op routed through an LLM (F2),
"assumed" isn't a green status.
**Fix:** MockGateway E2E for delete/update incl. `.pending` and double-send; downgrade
label to ⚠️ until then.

### F14 — Self-echo dedup depends on in-memory `seenKeys` with a history/live race
**Severity: LOW–MEDIUM** · attacks S4, S7.

`seenKeys` is per-VM, in-memory, rebuilt each open (`ChatViewModel.swift:22,91`).
`start()` fires `loadHistory` + `subscribeToPeers` concurrently (39–43); key
normalization (`cli-assistant:<runId>` → `chat-run:<runId>`, `asChatMessage` 394–398)
must match exactly or duplicate. Multi-device dedup otherwise correct. No persistent
cache → re-dedups from scratch each open (fine at 200 msgs).
**Fix:** gate live ingestion until first `loadHistory` completes, or dedup on a stable
server id. Fix "mirror" language to "re-fetched each session."

### F15 — Protocol versioning pinned with no negotiation
**Severity: LOW** · cross-cutting.

Connect pins `minProtocol=maxProtocol=4`; closed enums already broke once
(`ios-node` rejected, `§4`). A v5 bump is a silent hard failure.
**Fix:** let `maxProtocol` advance; report version-mismatch distinctly from auth failure.

---

## Claims checked and found SOUND (credit where due)

- **file-DOWN is genuinely lightweight — VERIFIED.** `agents.files.list/get` are
  `operator.read` (`§9b`), already used in `loadInstructions`
  (`GatewayWSSyncSource.swift:79–87`). No backend, no approach B. Caveat:
  `FileEntry.content` decodes as a string (`:318`) → **binary files (images/PDFs) are
  not covered.** Fix the claim to "**text** file-DOWN."
- **One-socket invariant holds in code** (single actor, one `ws`, one reconnect task).
- **Replay resistance on connect is real** (nonce + `signedAt`).
- **STT / client-side search costs are correctly cheap** (on-device `SFSpeechRecognizer`,
  free server-side — caveat: needs Info.plist usage strings, on-device locales unverified;
  search over the 200-msg cap is trivial).

---

## The 3 things that bite first
1. **F1** — unverified §0. One probe could delete a third of the architecture. Do it first.
2. **F4** — reconnect event loss → permanently-spinning bubble on any subway blip. ~15 lines.
3. **F7 + F12** — foreground-only + silent URL death → app looks broken in ordinary use.

## Verdict
The **chat core is sound enough to build the "improve chat first" pass on top of — with
two non-negotiable fixes first:** **F4** (reconnect must re-fetch history + clear orphaned
streaming bubbles) and **F8** (put `send` on `SyncSource` so the seam isn't a lie). Both
small. Everything *beyond* chat — app store (F5), server/database compartments (F6),
approach-B `delete` (F2), security posture (F3, F11) — is not architecture yet; it's a list
of intentions with honest ⬜ marks the diagram renders as if they were systems. As a map for
reasoning about chat blast radius, it's usable. As a claim that a super-app is architected,
it's aspirational labeling.
