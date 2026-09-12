# OpenClaw Mobile — end-to-end completion LOOP PROMPT

> ⚠️ **STALE — DO NOT COPY THE COMMANDS BELOW.** This document's `xcodebuild` lines
> pass `CODE_SIGNING_ALLOWED=NO`, which is banned (see `CLAUDE.md`): it strips
> entitlements, every Keychain write fails `-34018`, and pairing cannot persist.
> Kept for history. Drop the flag before running anything here.

> ## ⚠️ SUPERSEDED 2026-09-08
>
> This loop halted at P5.0 for want of a gateway host. A local sandbox now exists
> (`./sandbox/up.sh`) and P5–P7 are complete. Its CHECK commands also pass
> **`CODE_SIGNING_ALLOWED=NO`**, which strips entitlements and silently reinstates defect 2
> (pairing can never persist). Do not re-run this loop; start from
> `designs/2026-09-08-sandbox-validation-loop.md` and its checklist. Kept as a dated record.

Compiled from `designs/2026-09-07-app-completion-prd.md`. House style follows
`designs/2026-09-06-dev-suite-loop.md` (the predecessor); nothing here contradicts it.

**Phases are ordered so every item that needs no gateway runs first.** P1–P4 (about 30 items)
are fully offline. Only P5–P7 need a reachable tunnel, and the loop stops and asks for `HOST`
when it reaches P5. Start it today with no gateway and it still does four phases of real work.

```
/ralph-loop "Read designs/2026-09-07-app-completion-loop.md and keep executing unchecked checklist items. Stop only when the completion promise is literally true" --max-iterations 120 --completion-promise "OPENCLAW V1 COMPLETE"
```

When the gateway is up, add the host to the same prompt — as a bare URL. **Never wrap it in
angle brackets**: the shell reads `<url>` as a file redirect and the command dies before the
loop starts. Keep the whole prompt inside one balanced pair of double quotes.

```
/ralph-loop "Read designs/2026-09-07-app-completion-loop.md and keep executing unchecked checklist items. HOST=wss://REPLACE-ME.trycloudflare.com Stop only when the completion promise is literally true" --max-iterations 120 --completion-promise "OPENCLAW V1 COMPLETE"
```

**Summary (5 lines)**
1. Take the app from v0.2.0.0 to a v1.0 a stranger can install, pair, and use, in phases P1→P7.
2. Ground truth is `xcodebuild test`; the live phases add verbatim gateway captures that replace every schema-derived fixture.
3. Memory is `designs/2026-09-07-app-completion-checklist.md`, seeded verbatim from CHECKLIST SEED below on iteration 0.
4. A phase may not start until the previous one's non-`[H]` items are `[x]`, the full suite is green at or above baseline, and any screen that changed has a screenshot you actually looked at.
5. `[H]` items are human checkpoints. You never tick them. You report them as PENDING FOR HUMAN.

---

GOAL: Every capability the app claims is verified against the real gateway rather than a mock; the Board runs on live data with all six writes proven; the app survives a tunnel drop and a backgrounding without lying about what it knows; a stranger can go from install to a working paired chat using only `README.md`; and the suite is green with no test count below baseline.

CHECK(S):

```bash
# ALWAYS from repo root.
cd /Users/venkatavamshigunji/Documents/Workspace/openclaw-mobile-app
T=${TMPDIR:-/tmp}/completion; mkdir -p "$T"

# C0 — regenerate (after ANY new file or project.yml edit)
( cd OpenClawMobile && xcodegen generate )

# C1 — FULL oracle (phase gates + final). Exit 0 required; read "Executed N tests".
xcodebuild test -project OpenClawMobile/OpenClawMobile.xcodeproj -scheme OpenClawMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO 2>&1 \
  | tee "$T/full.log" | grep -E "Executed|error:|failed|\*\* TEST"

# C2 — FAST oracle for one item. Substitute the class the item names.
xcodebuild test -project OpenClawMobile/OpenClawMobile.xcodeproj -scheme OpenClawMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO \
  -only-testing:OpenClawMobileTests/<TestClass> 2>&1 | grep -E "Executed|error:|failed|\*\* TEST"

# C3 — design system (all must print NOTHING)
grep -rn '\.shadow(' OpenClawMobile/Sources
grep -rn 'Color(hex:' OpenClawMobile/Sources | grep -v 'DesignSystem/Theme.swift'
grep -rEn 'cornerRadius[:(] *[0-9]' OpenClawMobile/Sources | grep -v 'DesignSystem/Theme.swift'

# C4 — architecture (all must print NOTHING)
grep -rn 'ObservableObject\|import Combine\|@Published' OpenClawMobile/Sources
grep -rn 'as? GatewayWSSyncSource' OpenClawMobile/Sources/Features
grep -n '^packages:' OpenClawMobile/project.yml
grep -rn 'URLSession\|Keychain\|UserDefaults\|FileManager' OpenClawMobile/Sources/Features \
  --include='*View.swift' | grep -v 'Settings/SettingsView.swift'

# C5 — live probe (P5+ only; HOST from the human, identity in tools/.phase0-device.json)
node tools/rpc-probe.mjs "$HOST" <method> '<jsonParams>' > OpenClawMobile/Tests/Fixtures/<method>.json
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d, 'empty'" OpenClawMobile/Tests/Fixtures/<method>.json
grep -q '^ERROR' OpenClawMobile/Tests/Fixtures/<method>.json && echo "NOT CAPTURED — record it in Fixtures/README.md"

# C6 — screenshot. Build, install, launch, THEN capture in a SEPARATE tool call
# (`sleep` is blocked in this harness; the tool round-trip is the wait). Then READ the PNG.
xcodebuild build -project OpenClawMobile/OpenClawMobile.xcodeproj -scheme OpenClawMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO -derivedDataPath "$T/dd" 2>&1 | grep -E "error:|\*\* BUILD"
xcrun simctl boot A23F9506-356C-41B2-8A29-9B0022746168 2>/dev/null; xcrun simctl bootstatus A23F9506-356C-41B2-8A29-9B0022746168 -b >/dev/null 2>&1
xcrun simctl install booted "$T/dd/Build/Products/Debug-iphonesimulator/OpenClawMobile.app"
xcrun simctl terminate booted com.openclaw.mobile 2>/dev/null; xcrun simctl launch booted com.openclaw.mobile <QA-ARG>
# separate call:
xcrun simctl io booted screenshot designs/assets/2026-09-07-completion-<SCREEN>.png
# A blank frame or the launch screen is a FAILURE. Note what you saw on the checklist item.
```

LOOP — repeat until DONE:
  0. If `designs/2026-09-07-app-completion-checklist.md` does not exist: create it from CHECKLIST SEED verbatim, run C1 once, write `BASELINE_TESTS: <N>` in its header (expected 166). Stop this iteration.
  1. Open the checklist. Take the FIRST `[ ]` item that is not `[H]`. If it belongs to a later phase than the current one, the PHASE GATE is your item instead.
  2. If a STOP-AND-ASK trigger fires, write the question under `## QUESTIONS`, print it, and STOP. No promise.
  3. TDD: write the test the item names FIRST. Run C2. It MUST fail (a compile error counts). Record `RED: yes (<reason>)`. If it passes before you implement, the test is theater — strengthen it.
  4. Implement the smallest change that makes it green. C0 if files were added, then C2.
  5. Run C3 and C4. Both must print nothing.
  6. Tick `[x]` with evidence: `C2 exit 0, <class> Executed <n>`. Screenshot items name the PNG and what was visible.
  7. At a phase gate: run C1 (exit 0, `Executed N` ≥ BASELINE_TESTS), take that phase's screenshots, READ them, and record `P<k> GATE: C1 exit 0, Executed <N>`.
  8. Same failure three times → STOP, write what you tried under `## BLOCKED`, report.
  9. Back to step 1.

DONE (ALL must hold before printing `OPENCLAW V1 COMPLETE`):
  - [ ] Final C1, run AFTER the last edit, exits 0 with `Executed N` ≥ BASELINE_TESTS.
  - [ ] Every non-`[H]` item P1.*–P7.* is `[x]` with evidence.
  - [ ] C3 and C4 print nothing.
  - [ ] Every file in `OpenClawMobile/Tests/Fixtures/` is a live capture and the PROVISIONAL banner is gone from its README.
  - [ ] Every `[H]` item is listed verbatim under **PENDING FOR HUMAN** and none is ticked.

GUARDRAILS:
  - **Not in v1 — touching any of these means the loop has drifted. Stop instead:** cockpit/terminal control · multi-account or multi-gateway · cross-agent search · message editing · rendering inbound media from history · Workboard plugin mirroring · drag-and-drop between board columns · slash-command picker · workspace/artifact browsing · conversation JSON cache · APNs push.
  - **Invariants, every pass:** zero third-party dependencies; `@Observable` view models, no Combine; views never touch network or disk; all colors and radii only in `Theme.swift`; no `.shadow(`; one shared socket, never one per screen; `async/await` with the typed `GatewayError`; demo mode renders every screen with no host; real gateway signals only — never a fabricated activity verb, status, or task.
  - **Fixtures:** a live capture is NEVER hand-edited. Adding a new capture file is fine. The PROVISIONAL banner in `Tests/Fixtures/README.md` may be deleted only once every file in that directory is a real capture.
  - **Tests:** never delete, skip, `XCTSkip`, rename-to-hide, or loosen an existing test to go green. Never lower BASELINE_TESTS. Never tick an item whose test was not seen red first. Never tick a screenshot item without reading the PNG.
  - **Git:** do not merge, rebase, force-push, or open PRs. The human runs `/ship`. Commit only when an item says to.
  - **Lean (ponytail):** fewest new files, stdlib and first-party frameworks only, no speculative abstractions, no config for a constant. Mark deliberate shortcuts `// ponytail: <ceiling> — <upgrade path>`.

STOP-AND-ASK (write to `## QUESTIONS`, print, stop — no promise):
  - P5 is reached and `HOST` is absent, or `tools/.phase0-device.json` is missing, or the probe cannot connect. Ask for the gateway URL. Never fabricate a fixture. **P1–P4 never need this.**
  - Any live probe returns a scope error. Record the exact error and ask — do not silently route around it.
  - `sessions.create` or `sessions.patch` is refused: the fallback is approach B (instruct `main` via `chat.send`). That is the human's design decision, not yours.
  - Any work that needs a paid Apple Developer account (APNs, device signing, TestFlight).
  - The two-device fan-in needs a second paired device that does not exist.
  - A live capture contradicts a shipped rule (a column, lane, or activity mapping). Report the drift; do not quietly rewrite the rule to match.
  - The same failure three times.

ASSUMPTIONS (repo-grounded):
  - Baseline is 166 XCTest cases, 3 skipped without `LIVE_HOST`. Iteration 0 records the real number.
  - Fixtures and source-grep tests locate files via `#filePath`; no bundle resource wiring.
  - `tools/rpc-probe.mjs` prints the full `res.payload` (or `ERROR …`). It prints neither `hello-ok` nor events; P5 may add two small opt-in flags (`DUMP_HELLO=1`, `--listen <ms>`) rather than inventing output.
  - `MockGateway` already serves `agents.list`, `sessions.list`, `tasks.list`, `sessions.patch` (with `failNextPatch` and a `sessions.changed` broadcast), `sessions.create`, `tasks.cancel`, `chat.send`, `chat.abort`, `chat.history`, and `dropAllConnections()` for reconnect tests. It can serve a `hello-ok` `policy` block too — that is how P3 tests the attachment policy without a gateway.
  - The simulator is iPhone 17 Pro, UDID `A23F9506-356C-41B2-8A29-9B0022746168`.

FLAGGED — no honest automated oracle (human only, never self-signed):
  - Whether onboarding actually reads clearly to someone who has never seen the app.
  - Visual fidelity of the retheme; a screenshot proves it rendered, not that it looks right.
  - Camera, microphone, photo-library, long-press menus, and sheet behavior — `xcrun simctl` cannot tap or drag, and this repo has no UI-test target.
  - Two-device fan-in: needs real hardware and a real second pairing.
  - VoiceOver rotor order and spoken output. (Dynamic Type *clipping* IS checkable — see P4.3.)

---

## CHECKLIST SEED (copy verbatim into `designs/2026-09-07-app-completion-checklist.md` on iteration 0)

```markdown
# OpenClaw v1 completion checklist — memory for designs/2026-09-07-app-completion-loop.md
BASELINE_TESTS: <fill from the first C1 run>
HOST: <fill from the ralph prompt line when the gateway is up; P1–P4 do not need it>
Legend: [ ] todo · [x] done (evidence required) · [H] human checkpoint (never ticked by the agent, never gating)

## P1 — Onboarding a stranger can complete (OFFLINE) (screenshots: first-run, settings)
- [ ] P1.1 First run explains what the app connects to and what pairing does BEFORE asking for a code — CHECK: a first-run view exists; a test asserts it shows when `!settings.isConfigured` and no host was ever set, and never again after pairing.
- [ ] P1.2 Every pairing failure names its fix: expired code, wrong host, unreachable gateway, approval pending — CHECK: C2 `PairingFlowTests` covers all four states mapping to four distinct user-facing strings (no raw error codes).
- [ ] P1.3 `README.md`: what it is, the gateway it needs, how to pair, how to build and test, one screenshot — CHECK: `wc -l README.md` ≥ 40 AND it references a PNG in `designs/assets/`.
- [ ] P1.4 GATE: C1 exit 0 ≥ BASELINE_TESTS; C3 + C4 empty; both screenshots read.
- [H] P1.H Human: hand the README to someone who has never seen this app; they reach a working paired chat without asking a question. PENDING FOR HUMAN.

## P2 — Reliability against the mock gateway (OFFLINE) (screenshot: chat while disconnected)
- [ ] P2.1 `Tests/ReconnectTests.swift::testStreamingBubbleRecoversAfterADrop` — with a run streaming, `gateway.dropAllConnections()`, let it reconnect; assert no bubble is left `isStreaming` forever and the thread is not duplicated — CHECK: C2 ReconnectTests.
- [ ] P2.2 `::testBoardRefreshesAfterADrop` — the Board's `sessions.changed` subscription survives a reconnect and the board re-reads — CHECK: C2 ReconnectTests.
- [ ] P2.3 `::testHistoryBackfillDoesNotDuplicate` — on reconnect, re-read `chat.history` for the open thread and reconcile by idempotency key instead of appending — CHECK: C2 ReconnectTests.
- [ ] P2.4 Staleness is visible, never silent: while the socket is down the chat header and Board say so — a real state, not a spinner implying liveness — CHECK: `grep -rn 'Reconnecting\|Offline' OpenClawMobile/Sources/Features` ≥ 1 AND a test asserting the flag flips on disconnect and clears on reconnect.
- [ ] P2.5 Foreground refresh: on `scenePhase` → `.active`, reconnect and re-read — CHECK: `grep -rn 'scenePhase' OpenClawMobile/Sources` ≥ 1 AND a view-model test for the refresh entry point.
- [ ] P2.6 GATE: C1, C3, C4 clean; screenshot read.
- [H] P2.H Human: pull the tunnel mid-reply on a real device and confirm the app recovers without lying about what it knows. PENDING FOR HUMAN.

## P3 — Notifications, honest subset (OFFLINE)
- [ ] P3.1 Record the cut: APNs needs a paid Apple account this project does not have. Write the design note in `designs/` and cut push from v1 with that reason — CHECK: the note exists AND `.docs/product.md` §5 agrees.
- [ ] P3.2 Local notification on run completion, fired ONLY from a real terminal event (`chat` final/aborted/error) — never a timer — CHECK: `Tests/NotificationTests.swift::testFiresOnTerminalEventOnly` plus a case asserting NO notification on a delta.
- [ ] P3.3 Permission requested at a moment the user understands; a denial is handled without a crash and without nagging — CHECK: a reducer test for granted/denied/not-determined.
- [ ] P3.4 Attachment policy comes from `hello-ok` instead of the hard-coded default: `GatewayConnection` retains `policy`, `ChatViewModel` reads it — CHECK: `AttachmentBudgetTests` decodes a MockGateway-served `hello-ok` with non-default limits and the budget honors them; `grep -rn 'AttachmentPolicy.default' OpenClawMobile/Sources` shows it only as the fallback.
- [ ] P3.5 GATE: C1, C3, C4 clean.
- [H] P3.H Human: background the app during a long run and confirm the notification arrives and opens the right thread. PENDING FOR HUMAN.

## P4 — Polish, accessibility, cut (OFFLINE) (screenshots: board, roster at XXXL)
- [ ] P4.1 Every screen has a real empty state and a real error state (Board columns, roster, chat, settings) — CHECK: a test per screen's view model for the empty and error branches.
- [ ] P4.2 Error copy names the fix, never a raw code — CHECK: `grep -rnE '"[A-Z_]{6,}"' OpenClawMobile/Sources/Features` shows nothing user-facing.
- [ ] P4.3 Dynamic Type: at `.accessibilityExtraExtraExtraLarge` no label is truncated on the five screens plus the Board — CHECK: `Tests/DynamicTypeTests.swift` measuring text at that size (ponytail: measure the string, do not snapshot images).
- [ ] P4.4 VoiceOver labels on every interactive control — CHECK: no icon-only `Button(`/`NavigationLink` in `Sources/Features` lacks an `accessibilityLabel`.
- [ ] P4.5 Contrast: body and caption text on `Theme.card` and `Theme.bg` meet 4.5:1 — CHECK: `DesignSystemTests::testContrastRatios` computing the ratio from the tokens.
- [ ] P4.6 Delete what nothing uses or record why it stays (standing list: `ChatThread.isMain`, the agent-id convenience wrappers; `AttachmentPolicy.from(helloOK:)` is now used by P3.4) — CHECK: each is either referenced in `Sources/` or gone.
- [ ] P4.7 TODOS.md matches reality; `CLAUDE.md` and `.docs/` describe the shipped app — CHECK: no TODOS item describes work already done.
- [ ] P4.8 GATE: C1, C3, C4 clean; both screenshots read.
- [H] P4.H Human: visual review of the retheme, and a VoiceOver pass on a real device. PENDING FOR HUMAN.

## P5 — Truth pass (NEEDS THE GATEWAY; gates P6 and P7; no screenshot)
- [ ] P5.0 GATE: `HOST` known AND `test -f tools/.phase0-device.json`. Otherwise STOP-AND-ASK. Record the human's approval for mutating probes on a throwaway session labeled `v1-probe-2026-09-07`.
- [ ] P5.1 `sessions.list '{"includeDerivedTitles":true,"includeLastMessage":true}'` → `Tests/Fixtures/sessions.list.json` — CHECK: C5, and `grep -c '"status"'` ≥ 1 (0 → STOP-AND-ASK: older gateway, rows lack status).
- [ ] P5.2 `tasks.list '{}'` → `Tests/Fixtures/tasks.list.json` — CHECK: C5.
- [ ] P5.3 `agents.list '{}'` → `Tests/Fixtures/agents.list.json` — CHECK: C5.
- [ ] P5.4 `DUMP_HELLO=1 … tasks.list '{}'` → `Tests/Fixtures/hello-ok.json`; record whether `policy.attachments` is present — CHECK: valid JSON; feed it to P3.4's test.
- [ ] P5.5 Scope truth: probe one admin-only method (`agents.update`) and record the exact error. Settles the unproven `operator.admin` claim in `.docs/protocol.md` §10 — CHECK: the error text is in `Fixtures/README.md`.
- [ ] P5.6 (mutating, approved) `sessions.create {"agentId":"main","label":"v1-probe-2026-09-07"}` → fixture; note the returned key + sessionId — CHECK: C5; scope error → STOP-AND-ASK.
- [ ] P5.7 (mutating, approved) On that session: `chat.send` with a 1-px PNG attachment, then `chat.history`, then `chat.abort` → three fixtures — CHECK: C5 each; an attachments rejection → STOP-AND-ASK.
- [ ] P5.8 (mutating, approved) `sessions.patch` archive → unarchive → archive, with `--listen 5000` running; record whether `sessions.changed` arrived — CHECK: C5; no event → STOP-AND-ASK (the Board would need polling).
- [ ] P5.9 (mutating, approved) `tasks.cancel` against a cancellable task from P5.2, or record "none available" — CHECK: fixture or a recorded reason.
- [ ] P5.10 Optional methods, each captured or recorded unavailable: `commands.list`, `projects.list`, `agents.workspace.list`, `artifacts.list` — CHECK: four rows in `Fixtures/README.md`.
- [ ] P5.11 `Tests/Fixtures/README.md`: one row per method (captured | unknown method | forbidden), gateway version if `hello-ok` carries it, PROVISIONAL banner DELETED — CHECK: `grep -c PROVISIONAL OpenClawMobile/Tests/Fixtures/README.md` == 0.
- [ ] P5.12 Existing decode and rule tests pass unchanged against the real payloads — CHECK: C2 `BoardModelTests`. Any drift → STOP-AND-ASK; do not rewrite a rule to match.
- [ ] P5.13 GATE: C1 exit 0 ≥ BASELINE_TESTS.

## P6 — Board on live data (NEEDS THE GATEWAY) (screenshot: board)
- [ ] P6.1 Board renders the live roster: point the app at HOST, open the Board, confirm real sessions appear — CHECK: C6 `--open-board` with a paired identity; the PNG shows a real session title.
- [ ] P6.2 Live archive → unarchive driven from the app — CHECK: the app's own frame in the wire log; the card moves and comes back.
- [ ] P6.3 Live lane move (`category`) — CHECK: wire log frame; the card lands in the new lane.
- [ ] P6.4 Live start from Backlog (`chat.send`) — CHECK: a reply arrives in that session's thread.
- [ ] P6.5 Live stop (`chat.abort`) — CHECK: the bubble is marked Stopped, not Failed.
- [ ] P6.6 Live new task (`sessions.create`) — CHECK: the card appears in Backlog after a refresh.
- [ ] P6.7 Live task cancel (`tasks.cancel`), or a recorded reason none was available — CHECK: wire log frame or the reason.
- [ ] P6.8 GATE: C1, C3, C4 clean; board screenshot read.
- [H] P6.H Human: long-press menu, archive confirm sheet, lane picker, and new-task sheet all behave on a real device. PENDING FOR HUMAN.

## P7 — Two-device fan-in (NEEDS THE GATEWAY AND A SECOND DEVICE)
- [ ] P7.1 Probe P1 (`.docs/sync.md`): a turn sent on device A appears on device B — CHECK: live, both devices. No second device → STOP-AND-ASK; cutting this is the human's call.
- [ ] P7.2 Probe P7: a remote-paired device receives the same scopes as a loopback-paired one — CHECK: the two `hello-ok` scope arrays match, recorded in `.docs/sync.md`.
- [ ] P7.3 FINAL GATE: C1 exit 0 with `Executed N` ≥ BASELINE_TESTS; C3 + C4 empty; every fixture is a live capture; all screenshots present. Then summarize with **PENDING FOR HUMAN** listing P1.H, P2.H, P3.H, P4.H, P6.H verbatim, and output: OPENCLAW V1 COMPLETE

## QUESTIONS
(none yet)

## BLOCKED
(none yet)
```
