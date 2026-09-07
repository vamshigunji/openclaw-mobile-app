# Dev Suite — LOOP PROMPT (compiled from `designs/2026-09-06-dev-suite-design.md`; ponytail cuts applied)

```
/ralph-loop "Read designs/2026-09-06-dev-suite-loop.md and keep executing unchecked checklist items; stop only when the completion promise is literally true" --max-iterations 80 --completion-promise "DEV SUITE LOOP COMPLETE"
```

**Summary (5 lines)**
1. Build the PRD's three cuts — retheme, developer chat, Board tab — checklist item by item, TDD (red → green → refactor). **Execution order: phases 1 → 2 → 3 → 0 → 4 → 5 → 6.** Phases 1–3 need no live gateway; phase 0 (fixture capture) needs `HOST` from the ralph prompt line and gates phases 4–6. An iteration ends only when you stop; complete as many items as you can per iteration.
2. Ground truth is `xcodebuild test` on the `OpenClawMobile` scheme; every pure rule gets a named XCTest, every gateway interaction is asserted against `MockGateway`'s recorded frames, fixtures are verbatim live captures from `tools/rpc-probe.mjs`.
3. Memory = `designs/2026-09-06-dev-suite-checklist.md` (seeded verbatim from CHECKLIST SEED below on iteration 1); an item is ticked only when ITS check passed and the red run was observed first.
4. A phase may not start until every non-`[H]` item of the previous phase is `[x]`, the full suite is green, and that phase's screenshot exists and was LOOKED at.
5. Camera, microphone and "does it look like OpenClaw" are human checkpoints — listed as `[H]`, never ticked by the agent, never gating, always reported as PENDING FOR HUMAN.

---

GOAL: The app is rethemed to the OpenClaw palette (accent `#FF5C5C`, brand `#D84A31`, bg `#0E1015`, radii 6/10), chat supports session-keyed threads + attachments + dictation + fenced-code rendering + tool timeline + Stop/Retry over native `chat.send`, and a Board tab renders every agent session as a Kanban card from `sessions.list`/`tasks.list` with write-scoped interactions — all proven by a green `xcodebuild test` run whose test count never dropped below baseline, and every screen still renders in demo mode.

CHECK(S):

```bash
# ALWAYS from repo root. Regenerate first — XcodeGen only sees new .swift files after regen.
cd /Users/venkatavamshigunji/Documents/Workspace/openclaw-mobile-app
T=${TMPDIR:-/tmp}/dev-suite; mkdir -p "$T"

# C0 — regenerate project (run after ANY new file or project.yml edit)
( cd OpenClawMobile && xcodegen generate )

# C1 — FULL oracle (phase gates + final). Exit 0 required. Read the "Executed N tests" line.
xcodebuild test -project OpenClawMobile/OpenClawMobile.xcodeproj -scheme OpenClawMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$T/full.log" | grep -E "Executed|error:|failed|\*\* TEST"

# C2 — FAST oracle for one item (inner loop). Substitute the test class named in the item.
xcodebuild test -project OpenClawMobile/OpenClawMobile.xcodeproj -scheme OpenClawMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO \
  -only-testing:OpenClawMobileTests/<TestClass> 2>&1 | grep -E "Executed|error:|failed|\*\* TEST"

# C3 — design-system shell mirror (must all print nothing; the XCTest twin is P1.2)
grep -rn '\.shadow(' OpenClawMobile/Sources
grep -rn 'Color(hex:' OpenClawMobile/Sources | grep -v 'DesignSystem/Theme.swift'
grep -rEn 'cornerRadius[:(] *[0-9]' OpenClawMobile/Sources | grep -v 'DesignSystem/Theme.swift'

# C4 — architecture invariants (must print nothing)
grep -rn 'ObservableObject\|import Combine\|@Published' OpenClawMobile/Sources
grep -rn 'URLSession\|Keychain\|UserDefaults\|FileManager' OpenClawMobile/Sources/Features --include='*View.swift' | grep -v 'Settings/SettingsView.swift'   # SettingsView's health probe pre-dates this loop
grep -rn 'as? GatewayWSSyncSource' OpenClawMobile/Sources/Features          # must be empty from P2.2 on
grep -n '^packages:' OpenClawMobile/project.yml                              # no SPM deps

# C5 — live probe (phase 0 only; HOST supplied by the human, identity in tools/.phase0-device.json)
node tools/rpc-probe.mjs "$HOST" <method> '<jsonParams>' > OpenClawMobile/Tests/Fixtures/<method>.json
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d, 'empty'" OpenClawMobile/Tests/Fixtures/<method>.json
grep -q '^ERROR' OpenClawMobile/Tests/Fixtures/<method>.json && echo "NOT CAPTURED — record in Fixtures/README.md"

# C6 — screenshot (per phase; SCREEN ∈ agents|chat|settings|create|profile|board). Then READ the PNG.
xcrun simctl boot A23F9506-356C-41B2-8A29-9B0022746168 2>/dev/null; xcrun simctl bootstatus A23F9506-356C-41B2-8A29-9B0022746168 -b >/dev/null   # idempotent
xcodebuild build -project OpenClawMobile/OpenClawMobile.xcodeproj -scheme OpenClawMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO -derivedDataPath "$T/dd" 2>&1 | grep -E "error:|\*\* BUILD"
xcrun simctl install booted "$T/dd/Build/Products/Debug-iphonesimulator/OpenClawMobile.app"
xcrun simctl terminate booted com.openclaw.mobile 2>/dev/null; xcrun simctl launch booted com.openclaw.mobile <QA-ARG>   # no SEED_HOST ⇒ demo mode
# In a SEPARATE tool call (never `sleep` — it is blocked in this harness; the tool round-trip gives the app time to render):
xcrun simctl io booted screenshot designs/assets/2026-09-06-dev-suite-<SCREEN>.png
# Then: Read the PNG. Launch screen showing → take it once more. Blank/black frame or still launch screen = FAIL. Note what you saw in the checklist.
```

LOOP — repeat until DONE:
  0. If `designs/2026-09-06-dev-suite-checklist.md` does not exist: create it by copying CHECKLIST SEED below verbatim, then run C1 once and write `BASELINE_TESTS: <N from "Executed N tests">` in its header. Stop this iteration.
  1. Open the checklist. Walk phases in execution order 1 → 2 → 3 → 0 → 4 → 5 → 6 and find the FIRST item that is `[ ]` and not `[H]`. Before starting a new phase, confirm the PHASE GATE of the previous phase in that order holds (all its non-`[H]` items `[x]`, last C1 exit 0, its screenshot exists and was viewed); if not, the gate is your item. `[H]` items never block. If the next item is in phase 0 and `HOST` is not on the ralph prompt line (or the probe cannot connect), that is the STOP-AND-ASK for the host — phases 1–3 must already be green by then.
  2. If the item has a STOP-AND-ASK trigger that fires (see list) → write the question into the checklist under `## QUESTIONS`, print it, and STOP (no completion promise).
  3. TDD: write the test the item names FIRST. Run C2 on that class. It MUST fail (compile error counts). Record `RED: yes (<one-line reason>)` on the item. If it passes before you implement, the test is theater — strengthen it.
  4. Implement the smallest change that makes it green. Run C0 (if files were added) then C2. Diagnose root cause before editing on a failure; do not pattern-match.
  5. Run C3 + C4. All must print nothing.
  6. Tick the item `[x]` with an evidence line: `C2 exit 0, <class> Executed <n> tests`. For screenshot items: the PNG path + what was visible.
  7. At a phase gate: run C1 (full). Exit 0 and `Executed N` ≥ BASELINE_TESTS required. Record `PHASE <k> GATE: C1 exit 0, Executed <N>` in the checklist. Then take the phase screenshot (C6) and READ it.
  8. Same failure after 3 attempts → STOP, write what you tried under `## BLOCKED` in the checklist, report.
  9. Return to step 1.

DONE (exit conditions — ALL must hold; only then output `DEV SUITE LOOP COMPLETE`):
  - [ ] Final C1 run, executed AFTER the last source edit, exits 0 with `Executed N tests`, N ≥ BASELINE_TESTS.
  - [ ] Every non-`[H]` checklist item P0.*–P6.* is `[x]` with an evidence line.
  - [ ] C3 and C4 print nothing.
  - [ ] `designs/assets/2026-09-06-dev-suite-{agents,chat,settings,create,profile,board}.png` all exist and each was read by the agent (evidence line names the visible screen title/elements).
  - [ ] `[H]` items are NOT ticked by the agent and are listed verbatim under **PENDING FOR HUMAN** in the final summary.

GUARDRAILS:
  - Do NOT modify: any file in `OpenClawMobile/Tests/Fixtures/` once captured (adding NEW capture files is allowed); existing test assertions in `OpenClawMobile/Tests/*.swift` (you may ADD tests and ADD MockGateway capabilities; you may not weaken, delete, rename-to-hide, or `XCTSkip` an existing test); `tools/.phase0-device.json`; `.github/workflows/ci.yml`.
  - Do NOT weaken any check to make it pass: no deleting/skipping tests, no `|| true`, no loosening tolerances, no `-only-testing` as final proof, no ticking an item whose test never ran red, no screenshot ticked without reading the PNG, no lowering BASELINE_TESTS.
  - Do NOT fabricate fixtures, gateway frames, tool names, or activity verbs. Unknown signal → "Working…" fallback. Every fixture comes from `tools/rpc-probe.mjs` against the human-supplied host, or from the already-captured frames in `AgentActivityTests.swift`/`MockGateway.swift`. Precedence-case rows in tests may only be derived by mutating a decoded live row's fields in Swift — never by hand-writing JSON.
  - If the same failure persists after 3 attempts, STOP and report what you tried.
  - If progress requires a design decision, STOP and ask (see STOP-AND-ASK).
  - Invariants every pass: zero third-party dependencies (no `packages:` in project.yml; PhotosUI/Speech/AVFoundation/UniformTypeIdentifiers only); `@Observable` view models, no Combine/`ObservableObject`/`@Published`; views never touch network/disk (C4); every color/radius literal lives only in `Sources/DesignSystem/Theme.swift` (C3); no `.shadow(`; 1 px borders; dark only; demo mode (no host) renders every screen; one shared `SyncSource`/socket — never a socket per screen; `async/await` + typed `GatewayError`; every new pure function has a failing test first; `CFBundleDisplayName` stays "OpenClaw".
  - Scope: PRD §8 non-goals are forbidden — no light mode, no syntax highlighting, no inbound media rendering, no push/background refresh, no Workboard plugin mirroring, no LLM triage, no conversation JSON cache, no share extension, no icon redesign, no cockpit/terminal, no slash picker, no workspace/artifacts browsing, no `projects.list`, no card pin/rename.
  - Lean (ponytail): no new protocol layers, no repository abstraction, no local DB, no config for constants; new files only as the PRD names them (`Features/Board/{BoardView,BoardViewModel,BoardModel}.swift`, `Features/Chat/{Attachments,SpeechDictation,MessageSegmenter,CodeBlockView,ToolTimeline}.swift`, flat). Mark deliberate shortcuts in code with `// ponytail: <ceiling> — <upgrade path>`.
  - Commits: none unless the human asks (repo rule). The checklist file is the durable memory.

STOP-AND-ASK (write the question to `## QUESTIONS` in the checklist, print it, then invoke the `ralph-loop:cancel-ralph` skill so the loop hands control back to the human, then stop — no promise. Inside a ralph loop a plain stop only re-feeds this prompt; cancelling is what lets the human answer. HOST and any approvals arrive on the ralph prompt line itself — read them there first):
  - Phase 0 (only reached after phases 1–3 are green): `tools/.phase0-device.json` is missing OR `HOST` is not on the ralph prompt line OR the probe cannot connect. Ask: "Phases 1–3 are green. What is the gateway host (wss://… or https://…) for phase-0 fixture capture? Restart with: /ralph-loop \"Read designs/2026-09-06-dev-suite-loop.md and keep executing unchecked checklist items. HOST=<url>. Mutating phase-0 probes approved 2026-09-07. Stop only when the completion promise is literally true\" --max-iterations 60 --completion-promise \"DEV SUITE LOOP COMPLETE\"". Never fabricate fixtures.
  - Phase 0 mutating probes (`sessions.create`, `chat.send` with attachment, `sessions.patch`, `chat.abort`) on the throwaway session `phase0-probe-2026-09-06` were approved by the human in chat on 2026-09-07; do not ask again unless the prompt line lacks that approval.
  - PRD §7 verbatim: `sessions.create` or `sessions.patch` returns a scope error on the live gateway (fallback design: route through `main`, approach B).
  - PRD §7 verbatim: `chat.send` rejects `attachments` on the live gateway.
  - PRD §7 verbatim: `sessions.list` rows lack `status` (older gateway → derive running from activity events only, document it).
  - PRD §7 verbatim: `sessions.patch` rejects an unknown `category` (then register it via `sessions.groups.put` first).
  - Live `sessions.patch` did NOT produce a `sessions.changed` event during phase 0 (P0.6 listen) — ask whether the Board should poll instead.
  - Any behavior the PRD leaves open that a test needs pinned (e.g., what a Backlog "Start" sends when the card has no title).

ASSUMPTIONS (repo-grounded):
  - Fixtures and source-grep tests locate files via `#filePath` (`Tests/X.swift` → `../Sources`, `./Fixtures`); no bundle resource wiring. ponytail: avoids project.yml resource config.
  - `tools/rpc-probe.mjs` prints the full `res.payload` JSON (or `ERROR …`) — verbatim for req/res fixtures. It does not print `hello-ok` or events; phase 0 may add two tiny opt-in flags to it (`DUMP_HELLO=1` prints the connect payload; `--listen <ms>` prints raw event frames untruncated). `phase0-roundtrip.mjs` truncates events to 500 chars and is NOT a verbatim source.
  - `hello-ok.policy.attachments` may be absent on this gateway; then `AttachmentPolicy.default` = maxBytes 20 MB, maxImageBytes 6 MB, maxPayload 25 MiB (PRD §2.2) and the README records "policy absent".
  - Baseline test functions today: 76 across 11 suites (3 skip without `LIVE_HOST`). BASELINE_TESTS is whatever C1 prints on iteration 0.
  - `--seed-demo` with no `SEED_HOST` runs demo mode and auto-sends `SEED_TEXT`; the demo canned reply in `GatewayClient.cannedReply` may be extended to include one fenced block so the `chat` screenshot shows a code block (demo data, not a gateway signal).
  - `InboundEnvelope.Payload.EventData` decodes only string-valued `args` (`[String: String]`, lenient) — that is all `ToolEvent.summary` reads. ponytail: no JSON-value enum until something needs nested args.
  - MockGateway gains `receivedFrames: [[String: Any]]` (full params), `sessions.list`/`tasks.list` served from `Tests/Fixtures/*.json`, `sessions.patch`/`sessions.create`/`chat.abort`/`tasks.cancel` handlers, a `failNextPatch` flag, and emits `sessions.changed` after a successful patch.
  - Simulator: booted iPhone 17 Pro, UDID `A23F9506-356C-41B2-8A29-9B0022746168`; `-destination 'platform=iOS Simulator,name=iPhone 17 Pro'` resolves to it.

FLAGGED / NOT-YET-VERIFIABLE (no honest automated oracle — human only):
  - Visual fidelity ("matches OpenClaw", "less basic") — screenshots prove render, not taste. `[H]`.
  - Camera capture and microphone dictation — simulator cannot exercise; device-only. `[H]`.
  - Photo-library pick UX and drag-and-drop feel on the Board — `xcrun simctl` cannot tap/drag; no UI-test target exists in this repo. `[H]`.
  - Live-gateway `sessions.changed` emission on patch — asserted only against MockGateway; real behavior is observed once in P0.6, not continuously.

---

## CHECKLIST SEED (copy verbatim into `designs/2026-09-06-dev-suite-checklist.md` on iteration 0)

```markdown
# Dev Suite checklist — memory for designs/2026-09-06-dev-suite-loop.md
BASELINE_TESTS: <fill from first C1 run>
Legend: [ ] todo · [x] done (evidence line required) · [H] human checkpoint (never ticked by agent, never gating)
Item format after completion: `- [x] Pk.n … — RED: yes (<why>) — GREEN: C2 exit 0 <class> Executed <n>`

## Phase 0 — Live capture (no screenshot; needs HOST from human)
- [ ] P0.0 GATE: `test -f tools/.phase0-device.json` AND HOST known (from the ralph prompt line) AND `node tools/rpc-probe.mjs $HOST agents.list '{}'` returns JSON. If any is false → STOP-AND-ASK (cancel-ralph). Human approval for the mutating probes (P0.4–P0.6) was given in chat on 2026-09-07 — note it here.
- [ ] P0.1 `mkdir -p OpenClawMobile/Tests/Fixtures`; `node tools/rpc-probe.mjs $HOST sessions.list '{"includeDerivedTitles":true,"includeLastMessage":true}' > Tests/Fixtures/sessions.list.json` — CHECK: C5 valid non-empty JSON, no `^ERROR`; `grep -c '"status"' Tests/Fixtures/sessions.list.json` ≥ 1 (0 → §7 STOP-AND-ASK "rows lack status").
- [ ] P0.2 `tasks.list {}` → `Tests/Fixtures/tasks.list.json` — CHECK: C5.
- [ ] P0.3 `DUMP_HELLO=1 node tools/rpc-probe.mjs $HOST tasks.list '{}'` → `Tests/Fixtures/hello-ok.json` — CHECK: valid JSON; `grep -c attachments Tests/Fixtures/hello-ok.json` recorded (0 ⇒ defaults per ASSUMPTIONS).
- [ ] P0.4 (mutating — approved in P0.0) `sessions.create {"agentId":"main","label":"phase0-probe-2026-09-06"}` → `Tests/Fixtures/sessions.create.json`; note the returned session `key` and `sessionId` — CHECK: C5; any `forbidden`/scope error → §7 STOP-AND-ASK.
- [ ] P0.5 (mutating — approved) `chat.send` to the P0.4 key with message "phase0 attachment probe" + one ≤1 KB PNG attachment `{type:"image",mimeType:"image/png",fileName:"dot.png",content:<base64>,sizeBytes,width:1,height:1}` → `Tests/Fixtures/chat.send.attachment.ack.json`; then `chat.history {"sessionKey":<key>,"agentId":"main","limit":3}` → `Tests/Fixtures/chat.history.attachment.json`; then `chat.abort {"sessionKey":<key>,"agentId":"main"}` → `Tests/Fixtures/chat.abort.json` — CHECK: C5 on each; ack `ERROR` mentioning attachments → §7 STOP-AND-ASK.
- [ ] P0.6 (mutating — approved) with `--listen 5000` running: `sessions.patch {key,expectedSessionId,archived:true}` → `sessions.patch.archive.json`; `sessions.patch {…archived:false}` → `sessions.patch.unarchive.json`; `sessions.patch {…archived:true}` (leave archived); note whether a `sessions.changed` event arrived — CHECK: C5 each; scope error → STOP-AND-ASK; no `sessions.changed` observed → STOP-AND-ASK.
- [ ] P0.7 `Tests/Fixtures/README.md`: one line per method (`sessions.list`, `tasks.list`, `hello-ok`, `sessions.create`, `chat.send`, `chat.history`, `chat.abort`, `sessions.patch`) → `captured | unknown method | forbidden`, plus gateway version if hello-ok carries it — CHECK: `grep -cE '^\| (sessions\.list|tasks\.list|hello-ok|sessions\.create|chat\.send|chat\.history|chat\.abort|sessions\.patch)' OpenClawMobile/Tests/Fixtures/README.md` == 8.
- [ ] P0.8 GATE: C1 exit 0, `Executed N` ≥ BASELINE_TESTS (no code changed except tools/ flags). Record `PHASE 0 GATE`.

## Phase 1 — Retheme (screenshots: agents, chat, settings, create, profile)
- [ ] P1.1 `Tests/DesignSystemTests.swift::testTokenValues` — accent (1.000,0.361,0.361), brand (0.847,0.290,0.192), bg (0.055,0.063,0.082) ±1/255 via `UIColor(Theme.x).getRed`; `Theme.radius==6`, `Theme.radiusCard==10`, `Theme.border==1`. Implement tokens table §3.1 in Theme.swift (rename old tokens, keep `Color(hex:)`). — CHECK: C2 DesignSystemTests.
- [ ] P1.2 `DesignSystemTests::testNoShadows/testHexOnlyInTheme/testCornerRadiusLiteralOnlyInTheme` reading `Sources/` via `#filePath` — CHECK: C2 DesignSystemTests + C3 prints nothing. RED requirement: prove each test can fail by temporarily adding a violation in a scratch file, observing red, then deleting it (record).
- [ ] P1.3 Status mapping in DesignSystem: running→teal, waiting/blocked/needsYou→warn, failed→danger, done/idle→textMuted; each carries an SF Symbol name — `DesignSystemTests::testStatusColorsAndSymbols` — CHECK: C2 DesignSystemTests.
- [ ] P1.4 Restyle existing screens with new tokens: system type for UI, mono only for code/paths/ids; `PrimaryButton` fill=brand/white text; secondary=accent outline; destructive=danger outline; labels sentence case; radii via `Theme.radius`/`Theme.radiusCard`; no behavior change — CHECK: C1 exit 0 + C3/C4 empty.
- [ ] P1.5 CLAUDE.md "Design system rules" updated: 6 pt controls / 10 pt cards, accent `#FF5C5C`, brand `#D84A31` — CHECK: `grep -n 'FF5C5C' CLAUDE.md` ≥ 1 AND `grep -c '4pt everywhere' CLAUDE.md` == 0.
- [ ] P1.6 GATE: C1 exit 0, N ≥ BASELINE_TESTS. Screenshots via C6: `agents` with NO arg, `chat` with `--seed-demo`, `settings` with `--open-settings`, `create` with `--open-create`, `profile` with `--open-profile main`. READ each; record visible titles.
- [H] P1.H Human: review the 5 screenshots for OpenClaw look (red accent, blue-black bg, 6/10 radii, no green accent left). PENDING FOR HUMAN.

## Phase 2 — Chat core (screenshot: chat re-taken showing a code block)
- [ ] P2.1 `Tests/ChatThreadTests.swift`: `ChatThread{sessionKey,agentId,title,emoji}`; `InboundEnvelope.matchesSession("agent:x:task1")` true for payload.sessionKey match, false for other key, and main-thread fallback (no sessionKey in payload, agentId matches, key `agent:x:main`) — frames derived from `MockGateway`'s live-shaped `session.message` shape — CHECK: C2 ChatThreadTests.
- [ ] P2.2 `send(sessionKey:agentId:text:idempotencyKey:attachments:)` + `abort(sessionKey:agentId:runId:)` on `SyncSource`; `DemoSyncSource` conforms (canned) — CHECK: `grep -rn 'as? GatewayWSSyncSource' OpenClawMobile/Sources/Features` prints nothing AND C1 compiles (existing MockGatewayE2ETests still green).
- [ ] P2.3 `Tests/MessageSegmenterTests.swift`: prose-only; single fence; fence with language; two fences; unclosed fence (streaming) → expected `[Segment]`; `segments.map(text).joined() == input` for all — CHECK: C2 MessageSegmenterTests.
- [ ] P2.4 `Tests/ToolEventTests.swift`: `ToolEvent.from(env)` on the verbatim WebSearch/Bash frames from AgentActivityTests → `summary == "x"` / `"ls"`; frame without args → `summary == nil`; `phase:"result"` closes the open entry; summary truncated to 80 chars. Requires string-valued `EventData.args` decode (see ASSUMPTIONS) — CHECK: C2 ToolEventTests + C2 AgentActivityTests (unchanged, still green).
- [ ] P2.5 Stop: MockGateway handles `chat.abort` (records frame, emits `chat state:"aborted"`); `Tests/ChatStopRetryTests.swift::testStopSendsAbortAndMarksAborted` — while streaming, `vm.stop()` → `gateway.receivedMethods.contains("chat.abort")`, frame `sessionKey == thread.sessionKey`, bubble `.aborted` not `.failed` — CHECK: C2 ChatStopRetryTests.
- [ ] P2.6 Retry: `ChatStopRetryTests::testRetryUsesNewIdempotencyKey` — sync stub throws once; `vm.retry(message)` → second `chat.send` with a different idempotencyKey; failed flag cleared — CHECK: C2 ChatStopRetryTests.
- [ ] P2.7 `CodeBlockView` (language label, mono, horizontal scroll, Copy) + message context menu (Copy text · Share · Copy code); prose via `Text(AttributedString(markdown:))` inline-only. Demo canned reply gains one fenced block — CHECK: C1 exit 0 + C3 empty.
- [ ] P2.8 Tool timeline view in thread (entries from `ToolEvent`, closed on result/final/lifecycle end); unknown tool → name shown verbatim, no invented verb — CHECK: C1 exit 0; `grep -rn 'ToolEvent.from' OpenClawMobile/Sources/Features/Chat` ≥ 1.
- [ ] P2.9 GATE: C1 exit 0, N ≥ BASELINE_TESTS. Re-take `chat` via `--seed-demo` (canned fenced reply visible). READ it: code block with Copy visible.

## Phase 3 — Attachments + STT (screenshot: chat re-taken showing attach + mic buttons)
- [ ] P3.1 `Tests/AttachmentBudgetTests.swift`: 7 MB image → plan includes the re-encode step; 8 KB `.swift` → `.inlineFence`; 21 MB PDF → `.tooLarge(max:)`; encoded request > `maxPayload` → `.payloadTooLarge` before send; `AttachmentPolicy` decodes from `Tests/Fixtures/hello-ok.json` `policy.attachments` when that file exists, else equals `.default` (phase 3 runs before phase 0, so the decode sub-case is re-run and recorded after P0.3 lands) — CHECK: C2 AttachmentBudgetTests.
- [ ] P3.2 `Tests/AttachmentSendTests.swift`: two attachments → ONE optimistic bubble with two thumbnails; MockGateway `chat.send` echoes `idempotencyKey` → no duplicate bubble; frame `attachments.count == 2` with `type,mimeType,fileName,content,sizeBytes` — CHECK: C2 AttachmentSendTests.
- [ ] P3.3 `Tests/SpeechDictationTests.swift`: reducer `idle→requesting→listening→finishing→idle|denied|failed`; `.denied` from `.requesting` leaves `draft` unchanged; partial result replaces only the dictated span (typed prefix preserved) — CHECK: C2 SpeechDictationTests.
- [ ] P3.4 Pickers wired (PhotosPicker, camera via UIImagePickerController, files via `.fileImporter` `UTType.item`); one JPEG re-encode at 2048 px / 0.8; Info.plist strings `NSPhotoLibraryUsageDescription`, `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`, updated `NSCameraUsageDescription` — CHECK: `grep -c 'NSPhotoLibraryUsageDescription\|NSMicrophoneUsageDescription\|NSSpeechRecognitionUsageDescription' OpenClawMobile/project.yml` == 3, C0, C1 exit 0.
- [ ] P3.5 Denied mic/speech → inline hint "Enable microphone & speech in Settings", no crash — CHECK: `grep -rn 'Enable microphone' OpenClawMobile/Sources` ≥ 1 + P3.3 denied case green.
- [ ] P3.6 GATE: C1 exit 0, N ≥ BASELINE_TESTS. Re-take `chat` screenshot (`--seed-demo`): composer shows attach + mic controls. READ it.
- [H] P3.H Human (simulator): photo-library pick renders thumbnail chip and sends. PENDING FOR HUMAN.
- [H] P3.H2 Human (device only): camera capture and microphone dictation produce an attachment / draft text. PENDING FOR HUMAN.

## Phase 4 — Board read-only (screenshot: board)
- [ ] P4.1 `Tests/BoardModelTests.swift::testDecodesLiveFixtures`: `SessionSummary` from `Fixtures/sessions.list.json`, `TaskSummary` from `Fixtures/tasks.list.json`; both non-empty else fail — CHECK: C2 BoardModelTests.
- [ ] P4.2 `BoardModelTests::testColumnRuleTable`: 8 rules (§5.2) one row each + precedence archived+running→done, running+unread→running, failed+unread→needsYou; rows = decoded live row with fields mutated in Swift — CHECK: C2 BoardModelTests.
- [ ] P4.3 `BoardModelTests::testLaneRulePrecedence`: category > worktree.repoRoot > execCwd ?? spawnedCwd > agent workspace > agent name — CHECK: C2 BoardModelTests.
- [ ] P4.4 `BoardModelTests::testFoldRule`: child with `spawnedBy` == a board card's key appears as that card's sub-task, not its own card; orphan shows own card — CHECK: C2 BoardModelTests.
- [ ] P4.5 `BoardModelTests::testOrderingAndHiding`: lanes and cards sort by `lastActivityAt` desc; `isMain` and `kind ∈ {global,unknown}` hidden — CHECK: C2 BoardModelTests.
- [ ] P4.6 `SyncSource.listSessions/listTasks/sessionChanges`; MockGateway serves fixtures; `Tests/BoardViewModelTests.swift::testLoadsFromGateway` — non-empty lanes — CHECK: C2 BoardViewModelTests.
- [ ] P4.7 `BoardViewModelTests::testSessionsChangedRefreshes`: MockGateway emits `sessions.changed` with a changed `status` → card column changes without manual refresh — CHECK: C2 BoardViewModelTests.
- [ ] P4.8 `BoardViewModelTests::testDemoRendersThreeLanes`: `DemoSyncSource` → 3 lanes, ~6 sessions, some tasks — CHECK: C2 BoardViewModelTests.
- [ ] P4.9 Board tab in `RootTabView` (columns as `TabView(.page)`, lanes collapsible), `--open-board` QA arg — CHECK: `grep -n 'open-board' OpenClawMobile/Sources/Features/Root/RootTabView.swift OpenClawMobile/Sources/Features/Board/*.swift` ≥ 1; C1 exit 0.
- [ ] P4.10 GATE: C1 exit 0, N ≥ BASELINE_TESTS. Screenshot `board` via `--open-board` (demo). READ it: three lane headers visible.

## Phase 5 — Board interactive (screenshot: board re-taken)
- [ ] P5.1 MockGateway: `receivedFrames` (full params), handlers `sessions.patch`/`sessions.create`/`tasks.cancel`, `failNextPatch`, emits `sessions.changed` after successful patch — CHECK: C1 still green (no behavior change yet).
- [ ] P5.2 `Tests/BoardInteractionTests.swift::testArchiveSendsPatchWithExpectedSessionId` — CHECK: C2 BoardInteractionTests.
- [ ] P5.3 `::testUnarchiveSendsArchivedFalse` — CHECK: C2.
- [ ] P5.4 `::testLaneMoveSendsCategory` — `sessions.patch{category}` only — CHECK: C2.
- [ ] P5.5 `::testStartSendsChatSendToCardKey` — Backlog→Running sends `chat.send{sessionKey: card.key, message: title}` — CHECK: C2.
- [ ] P5.6 `::testCancelSendsTasksCancel` — `tasks.cancel{taskId}` — CHECK: C2.
- [ ] P5.7 `::testStopRunSendsChatAbort` — `chat.abort{sessionKey: card.key}` — CHECK: C2.
- [ ] P5.8 `::testFailingPatchRestoresState` — `failNextPatch=true` → board equals pre-action snapshot, error toast set — CHECK: C2.
- [ ] P5.9 `::testNewTaskSendsSessionsCreate` — `{agentId,label,category}` — CHECK: C2.
- [ ] P5.10 Archive-running confirm sheet copy states the gateway cancels active work — CHECK: `grep -rn 'cancel' OpenClawMobile/Sources/Features/Board/BoardView.swift` ≥ 1 within the confirm dialog text.
- [ ] P5.11 GATE: C1 exit 0, N ≥ BASELINE_TESTS. Re-take `board` screenshot. READ it.
- [H] P5.H Human (simulator): drag card → Done chip; drag → lane header; context menu actions; confirm sheet wording. PENDING FOR HUMAN.

## Phase 6 — Docs
- [ ] P6.1 `.docs/architecture.md` §8/§9 + CLAUDE.md layout tree updated for `Features/Board` and the new `Features/Chat` files — CHECK: `grep -n 'Features/Board\|Board/' CLAUDE.md` ≥ 1.
- [ ] P6.2 FINAL: C1 exit 0, N ≥ BASELINE_TESTS; C3 + C4 empty; all 6 screenshots present (`ls designs/assets/2026-09-06-dev-suite-*.png | wc -l` ≥ 6). Summarize with **PENDING FOR HUMAN** listing P1.H, P3.H, P3.H2, P5.H verbatim. Only then output: DEV SUITE LOOP COMPLETE

## QUESTIONS
(none yet)

## BLOCKED
(none yet)
```
