# OpenClaw Gateway API Contract — WS RPC Method & Event Catalog

**Date:** 2026-07-23
**Scope:** the contract the iOS client speaks to the Mac Mini gateway over. Not
REST, not GraphQL — a single persistent **WebSocket, protocol-v4, native JSON
RPC**. This doc documents the EXISTING surface the client already depends on,
and specifies FIVE new capabilities (reconnect delta, structured approach-B
commands, binary file-DOWN, quick-feedback/slash commands, and deferred S9
push/upload) as RPCs/events to add to the one box we own (F0.2).

Ground truth: `.docs/protocol.md`, `Sources/Models/GatewayDTOs.swift` +
`AgentSummary.swift`, `Sources/Services/GatewayFrames.swift` +
`GatewayWSSyncSource.swift`, `Sources/Features/Agents/MainAgentTask.swift`,
`designs/2026-07-23-superapp-system-architecture.md`,
`designs/2026-07-23-superapp-architecture-review.md`. Where protocol.md is
silent, sections are marked **unspecified upstream — proposed**.

---

## 1. Transport & framing

One WebSocket per app lifetime (`GatewayConnection` actor), port `18789` behind
a Cloudflare Tunnel (`wss://…`). Every frame is JSON with `type ∈ {req, res,
event}`. A `req` carries `id`, `method`, `params`; the matching `res` echoes
`id` with `ok`/`payload`/`error`; unsolicited `event` frames (keyed by `event`
or, on some gateway versions, `method`) carry activity/chat/session broadcasts
to every connection with an active `sessions.subscribe`. Connect is a signed
handshake (`connect.challenge` → `connect{device{...}}` → `hello-ok`) gated on
Ed25519 device auth (`.docs/protocol.md §5`); the resulting connection is
scope-checked per method (`operator.read` / `operator.write` / `operator.admin`).
There is no server-initiated channel outside this socket (F0.1) — every new
capability below is either a request the phone originates, or an event on a
subscription the phone opened.

---

## 2. Method catalog

Namespaces: `connect`, `chat`, `sessions`, `agents`, `agents.files`, `cron`
(read-only, out of scope for writes), plus NEW `sync`, `agents.ops`,
`chat.feedback`, `device.push`, `uploads`.

### 2.1 `connect` — **[EXISTING]**

**Request**
```jsonc
{
  "type": "req", "id": "<client-id>", "method": "connect",
  "params": {
    "minProtocol": 4, "maxProtocol": 4,
    "client": { "id": "openclaw-ios", "version": "0.1.0", "platform": "ios", "mode": "node" },
    "role": "operator",
    "scopes": ["operator.read", "operator.write"],       // pre-normalized, sorted
    "auth": { "token": "<deviceToken>" },                  // OR { "bootstrapToken": "<setupCode>" }
    "device": {
      "id": "<hex sha256(raw ed25519 pubkey)>",
      "publicKey": "<base64url 32 bytes>",
      "signature": "<base64url ed25519 sig over v3 payload>",
      "signedAt": 1753000000000,
      "nonce": "<echoed connect.challenge nonce>"
    }
  }
}
```
**Response (`hello-ok`)** — `payload.auth.deviceToken` (re-minted every
connect, always persist latest), `payload.auth.scopes`.
**Scope:** none required to attempt; the resulting scopes are what get minted.
**Idempotency:** N/A — one handshake per socket lifetime.
**Errors:** `INVALID_REQUEST` (bad enum), `AUTH_TOKEN_MISMATCH`, `NOT_PAIRED` /
`DEVICE_IDENTITY_REQUIRED`, `DEVICE_AUTH_DEVICE_ID_MISMATCH`,
`DEVICE_AUTH_SIGNATURE_INVALID`, `DEVICE_AUTH_SIGNATURE_EXPIRED`,
`DEVICE_AUTH_NONCE_MISMATCH`, `PAIRING_REQUIRED` (retryable).

### 2.2 `chat.send` — **[EXISTING]**

```jsonc
{ "type": "req", "id": "…", "method": "chat.send",
  "params": {
    "sessionKey": "agent:<id>:main",   // canonical key; bare key without agentId is REJECTED
    "agentId": "<id>",                 // MUST match sessionKey's <id>
    "message": "<plain text>",
    "idempotencyKey": "<client-generated>"
  }
}
```
**Scope:** `operator.write`. **Response:** `ok:true`, no payload of note — the
result streams back as `chat`/`session.message` events, not in the `res`.
**Idempotency (frame-level, LIVE):** the gateway adopts `idempotencyKey` as the
run id; the echoed user message carries `<idempotencyKey>:user`; the assistant
transcript message carries `cli-assistant:<runId>`. Resending the same key on
reconnect is safe against duplicate *frames* — it is NOT safe against duplicate
*semantic operations* dispatched to `main` (see §4.2).
**Note:** `session.message` (not `chat.send`) requires `operator.admin` and is
NOT the send path — a documented trap (`GatewayFrames.swift:61-64`).

### 2.3 `chat.history` — **[EXISTING]**

```jsonc
{ "type": "req", "id": "…", "method": "chat.history",
  "params": { "sessionKey": "agent:<id>:main", "agentId": "<id>", "limit": 200 } }
```
**Scope:** `operator.read`. `limit` ≤ 1000 upstream cap. **Response:**
`payload.messages: [WireMessage]` — `role`, `content` (string for user, block
array `[{type:"text", text}]` for assistant), `idempotencyKey`. No pagination
cursor today (fine at ≤1000; becomes a gap once §4.1's `since seq` needs finer
grain — see NEW `sync.eventsSince`).

### 2.4 `sessions.subscribe` — **[EXISTING]**

```jsonc
{ "type": "req", "id": "…", "method": "sessions.subscribe", "params": {} }
```
**Scope:** `operator.read`. Connection-scoped (not per-agent) — subscribes this
socket to ALL session events (`chat`, `session.message`, `sessions.changed`,
`session.tool`, `agent`, `presence`); the client filters per agent via
`InboundEnvelope.matchesAgent` on `payload.agentId`. A keyed
`sessions.messages.subscribe{sessionKey}` variant exists upstream but is
unused (single shared connection serves every thread). **No cursor param
today** — see §4.1.

### 2.5 `agents.list` — **[EXISTING]**

```jsonc
{ "type": "req", "id": "…", "method": "agents.list", "params": {} }
```
**Scope:** `operator.read`. **Response:**
```jsonc
{ "defaultId": "main", "mainKey": "agent:main:main", "scope": "per-sender",
  "agents": [ { "id": "…", "name": "…", "identity": {"emoji":"…","avatarUrl":"…","theme":"…"},
                "model": {"primary":"…"}, "workspace": "…", "agentRuntime": "…",
                "thinkingLevels": [...] } ] }
```
Cron-orchestrated sub-agents are invisible here (`cron.list` only).

### 2.6 `agents.files.list` / `agents.files.get` — **[EXISTING, text-only today]**

```jsonc
{ "method": "agents.files.list", "params": { "agentId": "<id>" } }
// → { "files": [ { "name": "AGENTS.md" }, ... ] }
{ "method": "agents.files.get", "params": { "agentId": "<id>", "name": "AGENTS.md" } }
// → { "file": { "name": "AGENTS.md", "content": "<string>" } }
```
**Scope:** `operator.read`, no `main` involvement. Standard file set:
`AGENTS.md`, `SOUL.md`, `IDENTITY.md`, `TOOLS.md`, `USER.md`, `HEARTBEAT.md`,
`BOOTSTRAP.md`, `MEMORY.md`. **Gap (review's "sound claim" caveat):**
`FileEntry.content` decodes as a plain string only — binary (image/PDF)
workspace files are unrepresentable today. See §4.3.

### 2.7 `agents.create` / `agents.update` / `agents.delete`, `agents.files.set`, `terminal.*` — **[EXISTING, admin-gated, NOT phone-callable]**

`operator.admin` per `.docs/protocol.md §9b` — **UNVERIFIED**, `§10` lists the
exact required scope as an open unknown (review F1). The phone's token is
hard-wired to `["operator.read","operator.write"]`
(`GatewayFrames.swift:29`), so it never presents `operator.admin` and cannot
call these directly today regardless. Approach B (§4.2) exists to route around
this. **If a live probe shows these are actually `operator.write`, approach B
becomes unnecessary for those three verbs** — flagged in §6.

### 2.8 `cron.list` — **[EXISTING, read-only]**

`operator.read`, unchanged, out of scope for this doc beyond noting it exists
for future surfaces (cron-orchestrated sub-agent visibility).

---

## 3. Event catalog — **[EXISTING]**

All ride the single `sessions.subscribe` the phone opened; each carries
`payload.agentId` for per-thread routing (F0.1 — only server→client channel).

| event | shape | meaning |
|---|---|---|
| `chat` | `{ agentId, runId, state: "delta"\|"final"\|"aborted"\|"error", deltaText, message }` | streaming assistant reply; `message.content` = text-so-far; client keys the bubble `chat-run:<runId>`, clears `isStreaming` on `final`. |
| `session.message` | `{ agentId, message: {role, content, idempotencyKey} }` | complete message broadcast (user echo, or assistant final transcript, keyed `cli-assistant:<runId>`). |
| `session.tool` | `{ agentId, stream:"tool", data:{ phase:"start"\|"result", name, args?, result? } }` | tool activity; `name` is claude-cli style (`WebSearch`, `Bash`, `Read`, `Edit`, `Grep`, `Glob`, `Task`, `WebFetch`). |
| `agent` | `{ agentId, stream, data }`; `stream ∈ {lifecycle, thinking, thought, assistant, plan, approval, command_output, patch, compaction, item, acp, error}` | broader activity signal; `lifecycle.phase ∈ {start,end,update,error}`. |
| `sessions.changed` | roster-affecting delta (new/removed session) | drives roster refresh. |
| `presence` / `tick` / `health` | liveness only | NOT activity — must not drive the "Thinking…" indicator. |

`AgentActivity.from(event)` maps `session.tool`/`agent`/`chat` → a verb;
unmapped signal → generic "Working…" fallback, never a fabricated verb — this
rule is unchanged and applies to every NEW event type below too.

---

## 4. The two hard designs

### 4.1 Reconnect delta (`sync.*`) — **[NEW]**

**Problem (review F4):** `sessions.subscribe` has no cursor; a reconnect
re-subscribes but events during the gap are gone forever, and a `final` delta
landing in that gap leaves the client's `isStreaming` bubble spinning forever
with no signal to clear it.

**Design.** Every broadcast event gets a monotonic connection-independent
sequence number stamped by the gateway (**unspecified upstream — proposed**:
per-session monotonic `seq`, since the gateway already serializes writes per
session). `sessions.subscribe` accepts an optional cursor; `hello-ok` and
every event carry `payload.stateVersion` (a coarse epoch bumped on any
gateway-side event-log truncation/restart, so a client can detect "my cursor
predates what the server retains" and fall back to a bounded resync instead of
silently misordering).

**`sessions.subscribe` (extended, backward-compatible — old clients omitting
`since` behave exactly as today):**
```jsonc
{ "method": "sessions.subscribe",
  "params": { "since": { "seq": 481920, "stateVersion": 7 } } }   // omit = today's behavior
```
Response unchanged (`ok:true`); if `stateVersion` is stale, gateway just
starts fresh from "now" and stamps the NEW `stateVersion` on every event —
client compares each incoming event's `stateVersion` to its cached one and
treats a mismatch as "gap, must resync" (see below), never as silent replay.

**NEW bounded catch-up RPC — `sync.eventsSince`** (do NOT reuse
`chat.history`, whose 1000-row cap and message-shape are wrong for a mixed
event log):
```jsonc
{ "method": "sync.eventsSince",
  "params": { "sessionKey": "agent:<id>:main", "agentId": "<id>",
              "sinceSeq": 481920, "limit": 200 } }
// →
{ "events": [ /* same shapes as §3, each with seq/stateVersion stamped */ ],
  "stateVersion": 7,
  "truncated": false }   // true = older than server retention; caller must fall back to chat.history + "New" divider
```
**Scope:** `operator.read`. **Bounded:** `limit` ≤ 500; `truncated:true` means
"gap too old, don't try to reconstruct the stream — refetch `chat.history` and
show a divider," never an unbounded backfill.

**Client-side orphaned-bubble rule (unchanged transport, new client
contract):** on any reconnect, the client MUST call `sync.eventsSince` (or, if
`truncated`, `chat.history`) BEFORE trusting `isStreaming` state; if the
catch-up confirms a `final`/`aborted`/`error` for a run whose bubble is still
`isStreaming`, clear it locally even with no live event — the catch-up IS the
missing final. If catch-up returns nothing for that `runId` at all (agent
still genuinely running), leave the spinner and rely on the now-live stream.

```mermaid
sequenceDiagram
    autonumber
    participant VM as ChatVM
    participant CX as GatewayConnection
    participant GW as Gateway (S8)
    Note over VM,GW: mid-stream, tunnel blips
    GW--xCX: (dropped: chat delta state=final, seq=481925)
    CX->>CX: socket closes, reconnect w/ backoff
    CX->>GW: connect (re-handshake)
    GW-->>CX: hello-ok
    CX->>GW: sessions.subscribe { since: {seq:481920, stateVersion:7} }
    GW-->>CX: ok (resumes live tail from seq 481921)
    CX->>GW: sync.eventsSince { sinceSeq:481920, limit:200 }
    GW-->>CX: events:[...,{seq:481925,state:"final",runId:"r1"}], truncated:false
    CX-->>VM: replay catch-up events
    VM->>VM: runId r1 final found → clear isStreaming, finalize bubble
    Note over VM,GW: live stream now current; no gap, no stuck spinner
```

**Why not just refetch full history on every reconnect:** the review's ~15
line stopgap (re-run `loadHistory`) is a reasonable v0 patch and should ship
now — `sync.eventsSince` is the proper fix for when catch-up needs to be
cheaper than a 200-message re-fetch on every subway blip (i.e. once history
grows past the trivial case). Both are compatible: if `sync.eventsSince` is
unavailable (old gateway), fall back to `chat.history` reconciliation by
`clientMessageId`.

### 4.2 Approach-B structured command envelope (`agents.ops.*`) — **[NEW]**

**Problem (review F2):** free-text instruction to `main`, polling
`agents.list` for name-existence. No transactional ack, no correlation id,
non-deterministic parsing, prompt-injection surface (main's context includes
web/file/chat text it didn't originate — injected imperative text is
indistinguishable from the operator's own instruction), idempotency dedups the
*frame* not the *operation* (retry-on-timeout can double-create), `delete` has
no confirmation step.

**Design.** Replace the free-text instruction with a structured JSON command,
still carried inside `chat.send.message` (the only write path the phone has —
no new RPC needed for the *send* side, because `main` is just another agent
session) but as a **fenced, schema-tagged block** `main`'s system prompt is
instructed to parse deterministically and echo back verbatim as a structured
**result**, not prose. `main` needs a corresponding prompt/tooling change on
the gateway side (S8) to recognize and act on this envelope instead of
free-form English — that is the "add a daemon-side capability to the box we
own" (F0.2) this design assumes.

**Command envelope (client → `main`, via `chat.send`):**
```jsonc
{
  "sessionKey": "agent:main:main", "agentId": "main",
  "message": "```openclaw-op\n{\n  \"opId\": \"op_2f9a...\",       // client-generated UUID, the semantic idempotency key\n  \"opVersion\": 1,\n  \"kind\": \"agents.create\",             // agents.create | agents.update | agents.delete | agents.files.set\n  \"requestedBy\": \"device:<deviceId>\",\n  \"idempotent\": true,                    // false only for kind=agents.delete (see below)\n  \"args\": { \"name\": \"Scout\", \"workspace\": \"/agents/scout\", \"model\": \"claude-…\", \"emoji\": \"🔎\" }\n}\n```",
  "idempotencyKey": "op_2f9a..."             // SAME value as opId: frame-level and op-level idempotency now coincide
}
```
**Result envelope (`main` → client, arrives as a normal assistant
`chat`/`session.message` event; client parses the fenced block instead of
polling `agents.list`):**
```jsonc
{
  "opId": "op_2f9a...",
  "opVersion": 1,
  "kind": "agents.create",
  "status": "ok",                 // ok | error | needs_confirmation
  "result": { "agentId": "scout" },
  "error": null
}
```

**Client poll target changes from list-membership to op-id:** `MainAgentTask`
polls `sync.eventsSince`/live stream for a `session.message`/`chat` `final`
whose parsed body has `opId == <sent opId>`, not `agents.list` diffing. This
also fixes the correlation-id gap (review: "poll ceiling returns `.pending`
with no correlation id") — a resumed poll after app relaunch can still find
the result by `opId` via `sync.eventsSince`.

**Semantic idempotency:** `opId` is stored client-side before send; if
`MainAgentTask.run` is retried (timeout, app relaunch), it resends the SAME
`opId`. `main` is instructed: "if you have already completed (or are
mid-flight on) an `opId` you've seen, re-emit the prior result instead of
repeating the action" — this requires `main` to keep a small opId→result log
(**unspecified upstream — proposed**: a `.openclaw/ops-log.json` in main's
workspace, main's own filesystem write, no new gateway RPC). This is the fix
for "idempotency key dedups the frame, not the semantic op": the frame-level
key (`chat.send.idempotencyKey`) already exists; this reuses the SAME value as
the op's semantic key so one collision check covers both layers.

**Delete requires explicit confirmation — two-phase:**
1. Client sends `kind: "agents.delete"` with `args:{agentId}` and no
   `confirm` field → `main` MUST reply `status: "needs_confirmation"` with
   `result: { confirmToken: "..." }` and MUST NOT delete.
2. Client shows a native (not agent-rendered) confirm dialog, then re-sends
   the SAME `opId` with `args:{agentId, confirmToken}` added. Only then does
   `main` execute. This moves the "are you sure" out of chat prose (which an
   injected message could answer on the user's behalf) into a value `main`
   cannot itself produce and inject back to itself in the same turn a
   malicious payload would need — the confirm token is only ever handed to
   the requesting device, over the same authenticated connection, never
   through content `main` reads from elsewhere.

**Why structured beats prose against prompt injection:** free text asks an
LLM to both (a) recognize operator intent among all the other text in its
context and (b) execute it — the exact ambiguity injection exploits. A fenced,
schema-tagged, single-command-per-turn envelope narrows what `main` is
instructed to *act on* to "the last well-formed `openclaw-op` block the
OPERATOR's own turn contained" — injected text arriving via a tool result or
fetched page is prose, not a well-formed fenced op block with a client-issued
`opId` main hasn't been asked to trust from a non-operator source. This is
mitigation, not a hard guarantee (main is still an LLM parsing a prompt) —
the delete confirm-token step is the actual hard stop for the one irreversible
op, and both should ship together.

```mermaid
sequenceDiagram
    autonumber
    participant VM as CreateAgentVM (S5)
    participant MT as MainAgentTask
    participant TX as Transport (S2)
    participant MAIN as main agent (S8)
    participant OPS as ops-log (main's workspace)
    VM->>MT: run(kind: agents.delete, args:{agentId})
    MT->>MT: opId = uuid(); idempotencyKey = opId
    MT->>TX: chat.send { message: fenced op, no confirmToken }
    TX->>MAIN: deliver to main
    MAIN->>OPS: check opId seen? no
    MAIN-->>TX: result { opId, status: needs_confirmation, confirmToken }
    TX-->>MT: (via sync.eventsSince / live event) matched by opId
    MT-->>VM: needs_confirmation(confirmToken)
    VM->>VM: native confirm dialog (not agent-rendered)
    VM->>MT: run(SAME opId, args + confirmToken)
    MT->>TX: chat.send { message: fenced op, confirmToken }
    TX->>MAIN: deliver to main
    MAIN->>OPS: opId seen but only needs_confirmation stage → proceed
    MAIN->>MAIN: agents.delete (operator.admin, local authority)
    MAIN->>OPS: record opId → status ok
    MAIN-->>TX: result { opId, status: ok, result:{deleted:true} }
    TX-->>MT: matched by opId → done
    MT-->>VM: Outcome.done
```

### 4.3 Binary file-DOWN — **[NEW, extends `agents.files.get`]**

`FileEntry.content` is a plain string today; unusable for images/PDFs in an
agent's workspace. Extend the response, additively (old clients ignoring new
fields keep working):

```jsonc
{ "method": "agents.files.get",
  "params": { "agentId": "<id>", "name": "diagram.png" } }
// →
{ "file": {
    "name": "diagram.png",
    "mimeType": "image/png",             // NEW — proposed, unspecified upstream
    "encoding": "utf8" | "base64",       // NEW — "utf8" preserves today's behavior exactly
    "content": "<string, base64 when encoding=base64>",
    "size": 483920,                      // NEW — bytes, pre-encoding
    "chunk": null                        // NEW — see chunking below; null = whole file in this response
} }
```
**Size limit — unspecified upstream, proposed:** inline whole-file only up to
**4 MB** (base64 inflates ~33%; keeps a single WS frame reasonable). Above
that, `agents.files.get` accepts an optional `range: {offset, length}` and
returns `chunk: {offset, length, totalSize}` alongside a `content` slice —
client issues sequential ranged calls (simplest: no new streaming RPC, no
new event type, reuses the existing request/response RPC the same way
`chat.history`'s `limit` already bounds a payload). **Scope: `operator.read`,
unchanged** — this is a response-shape extension, not a new privilege.

### 4.4 Quick-feedback + slash commands — **[NEW, `chat.send` payload convention]**

No new RPC — these are small structured `message` bodies over the existing
`chat.send`, so `main`/the target agent can act deterministically instead of
parsing "👍" as chat prose. Same fenced-block convention as §4.2, tagged
`openclaw-signal` (distinct tag from `openclaw-op` so agents can special-case
"acknowledge, don't narrate"):

```jsonc
// thumbs up/down on a specific assistant turn
{ "sessionKey": "agent:<id>:main", "agentId": "<id>",
  "message": "```openclaw-signal\n{\"kind\":\"feedback\",\"runId\":\"<runId>\",\"rating\":\"up\"}\n```",
  "idempotencyKey": "fb-<runId>-up" }

// slash commands: /stop, /review, /status
{ "sessionKey": "agent:<id>:main", "agentId": "<id>",
  "message": "```openclaw-signal\n{\"kind\":\"command\",\"name\":\"stop\"}\n```",
  "idempotencyKey": "cmd-<uuid>" }
```
`kind:"command".name ∈ {"stop","review","status"}` closed enum (**unspecified
upstream — proposed**; `stop` implies the agent should abort its current run,
which needs gateway-side support to interrupt a mid-flight tool call —
flagged as unverified in §6). **Scope:** `operator.write`, same as any
`chat.send` — no admin implications, no approach-B needed (these aren't
privileged ops). Result, if any, arrives as a normal `chat`/`session.message`
event; feedback commands may get no reply at all (fire-and-forget), which is
fine — they are telemetry, not a request needing an ack.

### 4.5 Deferred S9 — needs new daemon — **[NEW, sketch only]**

Both require code running on the Mac Mini that doesn't exist yet (S9); the
phone-side contract can be specified now so client work isn't blocked later.

**`device.push.register`** — **[NEW, needs-new-daemon]**
```jsonc
{ "method": "device.push.register",
  "params": { "deviceId": "<hex sha256 pubkey, same as connect's device.id>",
              "apnsToken": "<hex>", "environment": "sandbox" | "production",
              "topics": ["agent.final", "approval.needed"] } }   // which events warrant a push
// → { "ok": true }
```
**Scope:** `operator.write` (this is the device registering itself, not an
admin op). Needs an APNs-talking daemon on S8 that also needs to decide WHEN
to push (an event matching a registered topic while no live socket has ACKed
delivery in N seconds — debounce logic that doesn't exist). This is the only
way to reach a backgrounded phone (F0.1) — flagged as the highest-leverage S9
build, not designed further here (out of this doc's scope per the parent
task).

**`uploads.intake`** — **[NEW, needs-new-daemon]**
```jsonc
{ "method": "uploads.intake.begin",
  "params": { "agentId": "<id>", "name": "photo.jpg", "mimeType": "image/jpeg", "size": 2400000 } }
// → { "uploadId": "up_...", "chunkSize": 262144 }
{ "method": "uploads.intake.chunk",
  "params": { "uploadId": "up_...", "offset": 0, "data": "<base64>" } }
// → { "ok": true, "received": 262144 }
{ "method": "uploads.intake.complete",
  "params": { "uploadId": "up_..." } }
// → { "ok": true, "path": "<agent workspace path>" }
```
**Scope:** `operator.write` (this is file-UP into the requesting session's own
agent workspace, not cross-agent admin). Needs an intake daemon on S8 to
stream chunks to disk with size/type validation before the agent's runtime
ever sees the file — none of that exists; sketch only, not a committed
contract.

---

## 5. Cross-cutting

### 5.1 Error taxonomy

`GatewayError` stays the client-side vocabulary; extend narrowly:

| case | when | new? |
|---|---|---|
| `.unauthorized` | `AUTH_TOKEN_MISMATCH`, bad scope on any method | existing |
| `.unreachable(String)` | transport-level failure | existing |
| `.badStatus(Int)` | `res.ok == false` with no more specific mapping | existing |
| `.pairingPending(requestId:)` | `PAIRING_REQUIRED` | existing |
| `.bootstrapExpired` | `AUTH_BOOTSTRAP_TOKEN_INVALID` | existing |
| `.staleCursor` | `sync.eventsSince` returns `truncated:true` | **NEW** — distinct from `.badStatus`; client MUST fall back to `chat.history`, not retry the same call |
| `.opNeedsConfirmation(confirmToken:)` | approach-B result `status:"needs_confirmation"` | **NEW** — not an error in the transport sense (the RPC succeeded); modeled as a `MainAgentTask.Outcome` case, not `GatewayError`, since it's a normal branch of §4.2, not a failure |
| `.protocolVersionMismatch` | connect rejected purely on `minProtocol`/`maxProtocol`, distinct from auth failure | **NEW** — see §5.3 |

No case is removed; `.badStatus(Int)` remains the catch-all so unmapped
gateway errors degrade gracefully rather than crashing the switch.

### 5.2 Idempotency

- **Frame-level (existing, unchanged):** `chat.send.idempotencyKey` — gateway
  dedups the send frame, echoes `<key>:user`, assistant final is
  `cli-assistant:<runId>`.
- **Semantic-level (NEW, §4.2 only):** `opId` reuses the same value as
  `idempotencyKey` for approach-B commands; `main`'s ops-log is the dedup
  authority for the *action*, not just the *frame* — this is the fix for
  "retry can double-create."
- **Quick-feedback (§4.4):** idempotency key namespaced by kind
  (`fb-<runId>-<rating>`, `cmd-<uuid>`) — feedback is naturally idempotent
  (re-sending "up" twice is a no-op state, not a double action) so no
  server-side ops-log is needed there.

### 5.3 Versioning

Today: `connect` pins `minProtocol=maxProtocol=4`, hard rejection on mismatch,
indistinguishable from an auth failure (review F15). Recommend:
1. Client sends `minProtocol:4, maxProtocol:5` once a v5 exists (advertise a
   range, not a pin) so the gateway can pick the highest it supports.
2. Gateway responds to an unsupported range with a distinct error code
   (**unspecified upstream — proposed:** `PROTOCOL_VERSION_UNSUPPORTED`)
   instead of `AUTH_TOKEN_MISMATCH`/generic `INVALID_REQUEST`, mapped to the
   new `.protocolVersionMismatch` case so the UI can say "update the app,"
   not "check your token."
3. Every NEW method/field in this doc is additive (new optional params, new
   optional response fields) specifically so a v4 gateway and a client that
   speaks the extended contract can still interoperate — old gateway simply
   never returns the new fields, client's optional-decode already tolerates
   that (`InboundEnvelope.Payload` fields are all `Optional`).
4. New methods (`sync.eventsSince`, `agents.ops.*` convention, `device.push.*`,
   `uploads.intake.*`) get their own capability signal
   (**unspecified upstream — proposed**: `hello-ok` payload gains
   `capabilities: ["sync.eventsSince", ...]`) so the client can feature-detect
   rather than trying-and-catching an `UNKNOWN_METHOD` on first use.

### 5.4 Scope table

| method | required scope | phone calls directly? |
|---|---|---|
| `connect` | n/a (issues scopes) | yes |
| `chat.send` | `operator.write` | yes |
| `chat.history` | `operator.read` | yes |
| `sessions.subscribe` (incl. `since` cursor) | `operator.read` | yes |
| `agents.list` | `operator.read` | yes |
| `agents.files.list` / `.get` (incl. binary) | `operator.read` | yes |
| `agents.create` / `.update` / `.delete` | `operator.admin` (UNVERIFIED, F1) | **no — approach B via `main`** |
| `agents.files.set` | `operator.admin` (UNVERIFIED, F1) | **no — approach B via `main`** |
| `terminal.*` | `operator.admin` | **no — approach B via `main`** |
| `sync.eventsSince` (NEW) | `operator.read` | yes |
| approach-B op envelope (NEW, carried in `chat.send`) | `operator.write` (the send itself); the *action* runs at `main`'s own local authority | yes — sends the request; `main` executes |
| quick-feedback / slash signal (NEW, carried in `chat.send`) | `operator.write` | yes |
| `device.push.register` (NEW, needs-new-daemon) | `operator.write` | yes, once daemon exists |
| `uploads.intake.*` (NEW, needs-new-daemon) | `operator.write` | yes, once daemon exists |
| `cron.list` | `operator.read` | yes |

---

## 6. Open questions / what to verify against a live gateway

1. **F1 (blocking this whole doc's §4.2 rationale):** run `tools/rpc-probe.mjs`
   and call `agents.create`/`update`/`delete` directly on the paired
   read+write token. If it succeeds, approach B is unnecessary for those
   three verbs (still keep the structured-envelope pattern for anything that
   genuinely stays admin-gated, e.g. `terminal.*`, but the create/update/delete
   result-polling problem disappears).
2. Does the gateway already stamp a monotonic `seq` anywhere in its internal
   event log, or does §4.1 require a genuinely new counter? Nothing in
   `protocol.md` confirms either way — `.docs/protocol.md §3` *mentions*
   `stateVersion`/`seq` as a re-snapshot concept but the code never uses it
   (review F4) — need to check whether the upstream gateway package already
   has this and the client simply never adopted it, vs. it needs to be added
   server-side.
3. Whether `chat`-stream deltas reliably carry `payload.agentId` on every
   frame (review F9) — if not, §4.1's `sync.eventsSince` filtering by
   `agentId` needs a `sessionKey` fallback too.
4. Whether `main`'s runtime can be given the `openclaw-op`/`openclaw-signal`
   fenced-block parsing instruction reliably (this is a prompt/tooling change
   on `main`'s own config, not a protocol change) — needs a live test that
   `main` doesn't paraphrase or drop the structured result when replying.
5. Whether `/stop` (§4.4) can actually interrupt a mid-flight tool call
   server-side, or only signals "stop after current step" — affects the
   command's promised semantics.
6. Binary file size ceiling (§4.3's proposed 4 MB) is invented, not measured
   against actual gateway/WS frame limits — verify max WS message size the
   Mac Mini's gateway process/URLSession will accept before picking a final
   number.
