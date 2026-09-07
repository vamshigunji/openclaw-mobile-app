# OpenClaw Mobile — Developer Suite: retheme, developer chat, Board tab (design)

**Date:** 2026-09-06 · **Status:** proposed, awaiting approval · **Kind:** design spec (PRD for the loop)
**Companion:** `designs/2026-09-06-dev-suite-loop.md` (TDD loop prompt) · `designs/2026-09-06-dev-suite-ponytail-review.md` (cuts applied)

## 0. One paragraph

Turn the current "basic terminal chat" into a developer cockpit in three cuts: (A) retheme the whole
app to the **official OpenClaw palette** (lobster red on blue-black, system type, 6/10 pt radii),
(B) make chat **developer-centric** — photos, camera, files, speech-to-text, fenced-code rendering
with copy, a live tool-call timeline, Stop and Retry — all over the gateway's **native
`chat.send` attachments**, and (C) add a **Board tab**: a Kanban of every agent task, built only on
**real gateway state** (`sessions.list` + `tasks.list`), self-organized into **project lanes** from
worktree/cwd/category data, interactive through **write-scoped** RPCs the phone already holds. No
approach-B round-trips are needed for any of it; nothing is fabricated; every rule is a pure
function pinned by tests against live-captured JSON.

## 1. Decisions taken (flip any before the loop starts)

| # | Decision | Alternative rejected | Why |
|---|---|---|---|
| D1 | Board cards **are gateway sessions**; columns derive from `session.status`/`unread`/`archived`; sub-tasks come from the task ledger (`tasks.list`). | Phone-local board organized by an LLM ("ask main to sort my tasks"). | Real signals only (repo rule). Shared with the Control UI. Deterministic, testable, no drift. |
| D2 | Project lanes derive **deterministically**: `category` → worktree `repoRoot` → `execCwd`/`spawnedCwd` → agent workspace → agent name. Moving a card between lanes writes `sessions.patch {category}`. | Ask an LLM to cluster titles into projects. | Zero guesswork, instant, works from cached rows. |
| D3 | Adopt OpenClaw UI radii **6 pt (controls) / 10 pt (cards, bubbles)** and **system type for UI, mono only for code/paths/ids**. Keep 1 px borders, no shadows, dark-only. | Keep strict 4 pt + all-mono (the current "basic" look). | The user asked for a less basic UI that matches OpenClaw; the Control UI itself uses 6/10 pt and system type. Overrides CLAUDE.md's "4 pt everywhere" — update that rule when this lands. |
| D4 | Accent = Control UI **`#FF5C5C`**, CTA fill = docs brand **`#D84A31`**, activity/running = teal `#14B8A6`. | Docs-only palette (`#D84A31` everywhere). | Mirrors how OpenClaw's own UI splits "accent" vs "primary button"; teal is their secondary accent. |
| D5 | Attachments go up as base64 in `chat.send.attachments` (native, `operator.write`). | The unbuilt `uploads.intake.*` daemon sketched in `designs/2026-07-23-api-contract-design.md §4.5`. | The gateway already accepts attachments; the daemon is unnecessary. Supersedes C5's "file UP out of cut". |
| D6 | Board is a **top-level tab** across all agents, filterable by agent. | C8's per-agent "surface picker". | The user asked for a tab; cross-agent view is the point of a board. C8's `Surface` seam is not built. |
| D7 | Workboard **plugin** (optional gateway Kanban with 9 statuses) is **not** targeted in v1. | Mirror plugin cards. | Not guaranteed installed; plugin RPC surface unverified. Listed as a later extension. |

## 2. Ground truth (sources checked 2026-09-06)

### 2.1 Brand palette — official
- Docs site config `openclaw/openclaw:docs/docs.json` → `colors: { primary: #D84A31, dark: #E05540, light: #F5654A }`, logo `pixel-lobster.svg`.
- Control UI tokens `ui/src/styles/base.css` (dark): `--bg #0e1015`, `--card #161920`, `--bg-elevated #191c24`,
  `--text-strong #f4f4f5`, `--text #bcbcc0`, `--muted #8b8b94`, `--border #1e2028`, `--border-strong #2e3040`,
  `--accent #ff5c5c`, `--accent-subtle rgba(255,92,92,.10)`, `--primary #d13c3c`, `--accent-2 #14b8a6`, `--ok #22c55e`,
  `--warn #f59e0b`, `--danger #f87171`, `--radius-sm 6px`, `--radius-md 10px`, `--font-body -apple-system…`.
- Nothing in this repo documents a brand palette; terminal green `#22C55E` is a 2026-07 placeholder recorded as settled in four docs. This spec overrides it.

### 2.2 Gateway capabilities the phone can call (scope table from `src/gateway/methods/core-descriptors.ts`)

| Method | Scope | Used for |
|---|---|---|
| `sessions.list` | read | board rows (`status`, `unread`, `archived`, `label`, `worktree`, `execCwd`, `lastActivityAt`, `childSessions`, `isMain`, `category`…) |
| `sessions.subscribe` | read | already used; also emits `sessions.changed` → board live refresh |
| `sessions.create` | dynamic → **write** when `cwd` is omitted or inside the agent workspace | new task card (`agentId`, `label`, `category`) |
| `sessions.patch` | dynamic → **write** for organization fields (`category`, `archived` + `expectedSessionId`) | move lane, archive/unarchive |
| `tasks.list` / `tasks.get` | read | background sub-tasks per card (`status queued|running|completed|failed|cancelled|timed_out`, `runtime`, `title`, `progressSummary`, `lastToolName`, `diffStat`, `terminalOutcome`, `error`) |
| `tasks.cancel` | write | cancel a background task |
| `chat.send` (+ `attachments[]`) | write | send text + photos/files; limits advertised in `hello-ok.policy.attachments` (`maxBytes` 20 MB, `maxImageBytes` 6 MB, `maxPayload` 25 MiB) |
| `chat.abort` | write | Stop button in chat and "Stop run" on the board |
| `chat.history` | read | thread backfill (any session key) |

Later, not this cut (probe before building): `commands.list`, `agents.workspace.*`, `artifacts.*`, `projects.list` (≥ 2026.8), `sessions.goal.*` (≥ 2026.8).

Attachment wire shape (`server-methods/attachment-normalize.ts`): `{ type, mimeType, fileName, content: <base64>, sizeBytes?, width?, height? }`.
Session run status enum (`packages/gateway-protocol/src/schema/sessions-row.ts`): `queued | running | done | failed | killed | timeout`.
Every shape is **probed live first** (`tools/rpc-probe.mjs <host> <method> '<json>'`) and captured verbatim as a fixture.

## 3. Feature A — Retheme + UI polish

### 3.1 Tokens (`Sources/DesignSystem/Theme.swift`, the only home for values)

| Token | Value | Role |
|---|---|---|
| `bg` | `#0E1015` | screens, grouped lists, column background |
| `card` | `#161920` | cards, agent bubbles, fields |
| `elevated` | `#191C24` | sheets, composer, headers |
| `border` / `borderStrong` | `#1E2028` / `#2E3040` | 1 px hairlines / focused |
| `text` / `textBody` / `textMuted` | `#F4F4F5` / `#BCBCC0` / `#8B8B94` | titles / body / captions |
| `accent` | `#FF5C5C` | tab tint, links, icons, user-bubble border, live dot |
| `accentSubtle` | `accent @ 0.10` | user bubble fill, selected chips |
| `brand` | `#D84A31` | primary CTA fill (white text), app mark |
| `teal` | `#14B8A6` | running / activity |
| `ok` / `warn` / `danger` | `#22C55E` / `#F59E0B` / `#F87171` | status |
| `radius` / `radiusCard` | `6` / `10` | controls, chips, fields / cards, bubbles, sheets |
| `border` (width) | `1` | unchanged; **no shadows** |

Pressed/selected states use native SwiftUI button styles, not tokens.

Status mapping (single source of truth in DesignSystem): running → `teal`, needsYou/waiting/blocked → `warn` (icon differentiates), failed → `danger`, done/idle → `textMuted`. Never color alone: every status chip carries an SF Symbol.

Typography roles: `Theme.Font.title` (system, semibold), `.body` (system), `.caption` (system), `.mono` (system monospaced) — mono only for code, paths, ids, keys, logs.

### 3.2 Screen-level changes
- **Root**: three tabs — Agents · Board · Settings — tint `accent`.
- **Agents roster**: rows with emoji avatar on `accentSubtle` square (radius 6), name in system semibold, subtitle = last message preview + relative time (from the agent's main-session row in `sessions.list` when available, else model), running dot (teal) when that row's `status == running`. Demo banner restyled `warn`.
- **Chat**: agent messages full-width on `card` with a small emoji/name header (Control-UI style); user messages right-aligned on `accentSubtle` with `accent @ 0.5` border, radius 10; header keeps name + `ActivityLine`; composer on `elevated` with attach (+), mic, field, send/stop.
- **Settings / Create / Profile / Edit**: keep structure, swap tokens, `PrimaryButton` fill = `brand` with white text, secondary = `accent` outline, destructive = `danger` outline, labels sentence case.
- **Empty states**: SF Symbol + one line. No third-party assets copied.
- `CFBundleDisplayName` stays "OpenClaw".

### 3.3 Retheme acceptance (falsifiable)
- `DesignSystemTests`: `Theme.accent` resolves to sRGB (1.000, 0.361, 0.361) ±1/255; `Theme.brand` → (0.847, 0.290, 0.192) ±1/255; `Theme.bg` → (0.055, 0.063, 0.082) ±1/255; `Theme.radius == 6`, `Theme.radiusCard == 10`, `Theme.border == 1`.
- Source-grep tests (XCTest reading `Sources/` via `#filePath`): zero `.shadow(` anywhere in `Sources/`; zero `Color(hex:` outside `Theme.swift`; zero `cornerRadius(<numeric literal>)` outside `Theme.swift`.
- Every screen still renders in demo mode (existing `--seed-demo`, `--open-settings`, `--open-create`, `--open-profile` QA hooks) — human screenshot checkpoint.

## 4. Feature B — Developer-centric chat

### 4.1 Session-keyed threads (prerequisite)
`ChatView(thread:)` where `ChatThread { sessionKey, agentId, title, emoji }`. Roster taps open `agent:<id>:main`; Board taps open the task's session key. `InboundEnvelope.matchesSession(key)` filters on `payload.sessionKey`, falling back to `agentId` only for main threads. `send`/`abort` are **promoted onto `SyncSource`** (deletes the `sync as? GatewayWSSyncSource` down-cast in `ChatViewModel:136`).

### 4.2 Attachments — photos, camera, files
- Composer "+" → Photo Library (`PhotosPicker`), Camera (`UIImagePickerController` `.camera`, wrapped), Files (`.fileImporter`, `UTType.item`, multiple).
- `Attachment { id, kind: image|file, fileName, mimeType, data, width?, height? }` shown as a tray of thumbnails/file chips with remove.
- **Images**: re-encode once as JPEG (HEIC → JPEG), longest edge 2048 px, quality 0.8; still > `policy.maxImageBytes` (default 6 MB) → reject with inline reason.
- **Files**: text-like types (`.plainText`, `.sourceCode`, `.json`, `.yaml`, `.log`, `.markdown`) ≤ 64 KB are **inlined as a fenced block** (```` ```<ext>\n…``` ````) so the agent reads them directly; everything else attaches as-is if ≤ `policy.maxBytes` (default 20 MB). The whole frame must stay under `policy.maxPayload` (default 25 MiB) — `AttachmentBudget.check(_:policy:)` is pure and tested.
- Send: `chat.send { sessionKey, agentId, message, idempotencyKey, attachments:[{type,mimeType,fileName,content(base64),sizeBytes,width,height}] }`. Optimistic bubble renders local thumbnails/chips immediately, keyed by `idempotencyKey`; failure marks the bubble failed with Retry.
- Info.plist: `NSPhotoLibraryUsageDescription`, `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`; update `NSCameraUsageDescription` to cover photos + QR.
- Inbound media rendering (photos in history from other devices) is **out of v1**.

### 4.3 Speech to text
`SpeechDictation` (`SFSpeechRecognizer` + `AVAudioEngine`), locale `Locale.current`, `requiresOnDeviceRecognition` when supported. Tap mic to start, tap again/send to stop. Partial results replace the dictated span of `draft` (text typed before dictation is preserved). State machine `idle → requesting → listening → finishing → idle | denied | failed` is a pure enum reducer — tested. Denied → inline hint "Enable microphone & speech in Settings", never a crash.

### 4.4 Code-aware rendering
`MessageSegmenter.segments(_ text:) -> [Segment]` with `.prose(String)` and `.code(lang: String?, body: String)`; an unclosed fence during streaming is code. Prose renders through `Text(AttributedString(markdown:))` (inline only); code renders in `CodeBlockView`: language label, mono, horizontal scroll, **Copy** button, no syntax highlighting. Message context menu: Copy text · Share · Copy code (per block).

### 4.5 Tool-call timeline (developer differentiator, real signals only)
`ToolEvent.from(envelope)` maps `session.tool` `data.{phase,name,args}` to `{ name, summary, phase }` where `summary = first non-empty of args.command | args.file_path | args.path | args.query | args.pattern | args.url` (≤ 80 chars), nil when absent. Only string-valued args are decoded. Events for the thread's session collect into the current run's activity group, rendered as a collapsed row ("▸ 5 tool calls · Bash, Edit, Read") above the streaming bubble; expands to the list. Unknown tools show their raw name — **never a fabricated description**. Group closes on `chat final|aborted|error` or `lifecycle end`.

### 4.6 Stop and Retry
While a run is active the send button becomes **Stop** → `chat.abort { sessionKey, agentId, runId? }` (runId from the `chat.send` ack). Failed user bubbles show **Retry** (new idempotencyKey). This replaces the "tap to retry not wired in prototype" text.

### 4.7 Chat acceptance (falsifiable)
- Given the captured `chat.send` ack + echo frames, a send with two attachments renders one optimistic bubble with two thumbnails and no duplicate after echo (MockGateway echo carries the same idempotencyKey).
- `AttachmentBudget`: a 7 MB image plan yields the re-encode step; an 8 KB `.swift` file inlines as a fence; a 21 MB PDF is rejected with `.tooLarge(max:)`; a request whose encoded size exceeds `maxPayload` is rejected before send; policy decodes from the captured `hello-ok` or falls back to defaults.
- `MessageSegmenter`: prose-only, single fence, fence with language, two fences, unclosed fence (streaming) — each yields the expected segments; round-trip concatenation equals input text.
- `ToolEvent`: the live `WebSearch`/`Bash` frames from `AgentActivityTests` yield summaries `x` and `ls`; a frame with no args yields `summary == nil`; `phase == result` closes the entry.
- Stop: while streaming, `abort` is called with the thread's sessionKey (MockGateway records `chat.abort`); the bubble is marked aborted, not failed.
- Dictation reducer: `denied` from `requesting` yields `.denied` and leaves `draft` unchanged; partial results replace only the dictated span.
- Manual checkpoints (simulator): photo library pick → thumbnail in tray → send → bubble; camera path on device only; mic on device only (simulator has no on-device recognizer — the loop must not treat that as failure).

## 5. Feature C — Board tab (smart Kanban)

### 5.1 Data model (pure, `Sources/Features/Board/BoardModel.swift`)
```
SessionSummary  ← sessions.list row (decoded fields: key, sessionId, agentId, label, displayName,
                   derivedTitle, lastMessagePreview, status, unread, archived, lastActivityAt,
                   lastReadAt, updatedAt, isMain, kind, spawnedBy, childSessions,
                   worktree{repoRoot,branch}, execCwd, spawnedCwd, category)
TaskSummary     ← tasks.list row (id, status, runtime, title, sessionKey, childSessionKey,
                   progressSummary, lastToolName, diffStat, terminalOutcome, error, updatedAt)
BoardCard       = SessionSummary + [TaskSummary] (sub-tasks) + live AgentActivity
                   with computed `column: BoardColumn` and `lane: String`
BoardColumn     = backlog | running | needsYou | done
```
The board is `[BoardCard]`; views group with `Dictionary(grouping:by:)` at render time.

### 5.2 Column rule — `BoardColumn.for(session)` (order matters, first match wins)
1. `archived == true` → `.done`
2. `status == running` or `hasActiveRun == true` → `.running`
3. `status == queued` → `.running` (chip "queued")
4. `status ∈ {failed, killed, timeout}` → `.needsYou` (chip shows which; `lastRunError` as subtitle)
5. `unread == true` → `.needsYou` (chip "replied")
6. `status == done` → `.done`
7. `status == nil && lastActivityAt == nil` → `.backlog` (never ran; phone-created cards land here)
8. else → `.done`

Hidden: `isMain` rows (the Agents tab owns them) and `kind ∈ {global, unknown}`. Rows with `spawnedBy` whose parent is on the board fold into the parent as sub-tasks; orphans show as their own card.

### 5.3 Lane rule — `ProjectLane.key(session, agents)`
1. non-empty `category` → lane titled by the category (user-curated, wins)
2. `worktree.repoRoot` → last path component
3. `execCwd ?? spawnedCwd` → last path component
4. agent `workspace` (from `agents.list`) → last path component
5. agent display name
Lanes and cards both sort by most recent activity.

### 5.4 Card
Title = `label ?? displayName ?? derivedTitle ?? first line of lastMessagePreview ?? key`. Agent emoji chip · status chip (icon + label) · live verb from `AgentActivity` for that sessionKey (teal, pulsing) · relative time · sub-task summary ("2 running · 1 failed", the running task's `progressSummary ?? lastToolName`, `diffStat` as `+12 −3 · 4 files`).

### 5.5 Interactions (each maps to one real write; none invent state)
| Gesture | Effect |
|---|---|
| Tap card | open `ChatView(thread:)` for the session |
| Drag card → **Done** chip | `sessions.patch { key, expectedSessionId, archived: true }` (confirm if running — the gateway cancels active work) |
| Drag from Done → any column | `archived: false` |
| Drag **Backlog** card → Running | `chat.send` the card title to its session; the thread opens for follow-ups |
| Drag card → another **lane header** | `sessions.patch { category: lane }` |
| Context menu | Open · Move to project… · Stop run (`chat.abort`) · Archive/Unarchive · Cancel task (`tasks.cancel`) |
| "+" | New task sheet: title, agent, lane → `sessions.create { agentId, label, category }`; the card lands in Backlog |
| Pull to refresh / live | `sessions.changed` events and activity events update rows; optimistic updates roll back on RPC error with a toast |
Drag targets are the column chips in the header and lane headers (phone-sized Kanban: columns are pages in a `TabView(.page)`, lanes are collapsible sections inside a column). Native `.draggable` / `.dropDestination` only.

### 5.6 Demo mode
`DemoSyncSource` returns 3 lanes × ~6 canned sessions and a few tasks so the Board renders without a gateway and screenshots stand alone. Writes in demo mode mutate the in-memory list only.

### 5.7 Board acceptance (falsifiable)
- Column rule table-driven test: the 8 rules above with one fixture row each, plus precedence cases (archived+running → done; running+unread → running; failed+unread → needsYou).
- Lane rule: category wins over worktree; worktree beats execCwd; no data → agent name.
- Live golden decode: `Tests/Fixtures/sessions.list.json` and `tasks.list.json` captured from the real gateway decode into non-empty arrays with the fields above; unknown fields ignored; missing optionals do not fail.
- Fold rule: a child with `spawnedBy` = a board card's key appears as that card's sub-task, not as a card.
- Interaction contract against MockGateway: archive sends `sessions.patch` with `expectedSessionId`; lane move sends `sessions.patch {category}`; start sends `chat.send` to the card's key; stop sends `chat.abort` for the card's key; cancel sends `tasks.cancel {taskId}`; new task sends `sessions.create {agentId,label,category}`; a failing patch restores the previous board state.
- Live: a `sessions.changed` event with a changed `status` moves the card column without a manual refresh (MockGateway emits the event after a patch).
- Demo mode renders three lanes; `--open-board` QA arg opens the tab.

## 6. Architecture changes (minimal)
- `SyncSource` gains methods **one per feature as its test demands**: `send(...)` + `abort` (4.1), `attachmentPolicy` (4.2), `listSessions`/`sessionChanges`/`listTasks` (5), `createSession`/`patchSession`/`cancelTask` (5.5). `DemoSyncSource` conforms with canned data. No new protocol layers, no repository abstraction, no local database (JSON conversation cache stays unbuilt).
- `InboundEnvelope.Payload` gains `sessionKey`-first routing and string-valued `args` for tool events; `hello-ok` `policy` is retained by `GatewayConnection` for `attachmentPolicy`.
- New files: `Features/Board/{BoardView,BoardViewModel,BoardModel}.swift`; `Features/Chat/{Attachments,SpeechDictation,MessageSegmenter,CodeBlockView,ToolTimeline}.swift` (flat, no sub-folders).
- `project.yml`: Info.plist usage strings; frameworks are all first-party (PhotosUI, Speech, AVFoundation, UniformTypeIdentifiers). Regenerate with `xcodegen generate`.
- `MockGateway` learns `sessions.list`, `tasks.list`, `sessions.patch`, `sessions.create`, `chat.abort`, `tasks.cancel`, echoes attachments, records full request params, and broadcasts `sessions.changed` after patches.
- Docs to update on landing: `CLAUDE.md` (tabs, radii rule, palette, board), `.docs/architecture.md` §8/§9.

## 7. Phasing (each phase ends green on `xcodebuild test` and with a simulator screenshot)
0. **Live capture** — probe and save verbatim fixtures: `sessions.list {includeDerivedTitles:true, includeLastMessage:true}`, `tasks.list {}`, `hello-ok` (for `policy`), then on a throwaway session `sessions.create {agentId:"main", label:"phase0-probe-2026-09-06"}` → one `chat.send` with a tiny PNG attachment (ack) → `chat.history` (row) → `sessions.patch` archive/unarchive/archive → `chat.abort`. Record any `unknown method`/`forbidden` in `Tests/Fixtures/README.md`. **Needs the running gateway, the paired probe identity (`tools/.phase0-device.json`), and the user's OK before the mutating probes.**
1. **Retheme** — tokens, typography roles, `DesignSystemTests`, restyle existing screens. No behavior change.
2. **Chat core** — session-keyed threads, `send`/`abort` on `SyncSource`, Stop, Retry, `MessageSegmenter` + `CodeBlockView`, tool timeline.
3. **Attachments + STT** — pickers, budgets, wire send, dictation.
4. **Board read-only** — DTOs, column/lane rules, live refresh, demo data, tab + QA arg.
5. **Board interactive** — archive/unarchive, start, lane move, stop, cancel, new task.
6. **Docs** — CLAUDE.md and architecture updates.

Stop-and-ask triggers: `sessions.create` or `sessions.patch` returns a scope error on the live gateway (fallback design: route through `main`, approach B); `chat.send` rejects `attachments` on the live gateway; `sessions.list` rows lack `status` (older gateway → derive running from activity events only, document it); `sessions.patch` rejects an unknown `category` (then register it via `sessions.groups.put` first).

## 8. Non-goals (this cut)
Light mode · syntax highlighting · inbound media rendering · push notifications / background refresh · Workboard plugin mirroring · LLM auto-triage · conversation JSON cache · share extension · app icon redesign · cockpit/terminal · slash-command picker (`commands.list`) · attach-from-workspace (`agents.workspace.*`) · artifacts (`artifacts.*`) · `projects.list` lane names · card pin/rename.

## 9. Risks
- Gateway version skew on optional fields; phase 0 settles it against the real gateway.
- Base64 attachments share the one socket with the live event stream; keep images ≤ ~2 MB after re-encode.
- Speech and camera cannot be exercised in the simulator; those two checks are device-only human checkpoints.
- Archiving a running session cancels its work (gateway behavior) — the confirm sheet must say so.
