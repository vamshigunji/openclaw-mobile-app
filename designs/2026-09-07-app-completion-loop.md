# OpenClaw Mobile — end-to-end completion LOOP PROMPT

Compiled from `designs/2026-09-07-app-completion-prd.md`. House style follows
`designs/2026-09-06-dev-suite-loop.md` (the predecessor); nothing here contradicts it.

```
/ralph-loop "Read designs/2026-09-07-app-completion-loop.md and keep executing unchecked checklist items. HOST=<wss://your-gateway or 'offline'>. Stop only when the completion promise is literally true" --max-iterations 120 --completion-promise "OPENCLAW V1 COMPLETE"
```

**Summary (5 lines)**
1. Take the app from v0.2.0.0 to a v1.0 a stranger can install, pair, and use, in milestones M0→M5.
2. Ground truth is `xcodebuild test`, plus verbatim live-gateway captures — M0 replaces every schema-derived fixture with a real one and gates everything after it.
3. Memory is `designs/2026-09-07-app-completion-checklist.md`, seeded verbatim from CHECKLIST SEED below on iteration 0.
4. A milestone may not start until the previous one's non-`[H]` items are `[x]`, the full suite is green at or above baseline, and any screen that changed has a screenshot you actually looked at.
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

# C1 — FULL oracle (milestone gates + final). Exit 0 required; read "Executed N tests".
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

# C5 — live probe (M0 only; HOST from the human, identity in tools/.phase0-device.json)
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
  1. Open the checklist. Take the FIRST `[ ]` item that is not `[H]`. If it belongs to a later milestone than the current one, the MILESTONE GATE is your item instead.
  2. If a STOP-AND-ASK trigger fires, write the question under `## QUESTIONS`, print it, and STOP. No promise.
  3. TDD: write the test the item names FIRST. Run C2. It MUST fail (a compile error counts). Record `RED: yes (<reason>)`. If it passes before you implement, the test is theater — strengthen it.
  4. Implement the smallest change that makes it green. C0 if files were added, then C2.
  5. Run C3 and C4. Both must print nothing.
  6. Tick `[x]` with evidence: `C2 exit 0, <class> Executed <n>`. Screenshot items name the PNG and what was visible.
  7. At a milestone gate: run C1 (exit 0, `Executed N` ≥ BASELINE_TESTS), take the milestone's screenshots, READ them, and record `M<k> GATE: C1 exit 0, Executed <N>`.
  8. Same failure three times → STOP, write what you tried under `## BLOCKED`, report.
  9. Back to step 1.

DONE (ALL must hold before printing `OPENCLAW V1 COMPLETE`):
  - [ ] Final C1, run AFTER the last edit, exits 0 with `Executed N` ≥ BASELINE_TESTS.
  - [ ] Every non-`[H]` item M0.*–M5.* is `[x]` with evidence.
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
  - `HOST` is absent or `offline`, `tools/.phase0-device.json` is missing, or the probe cannot connect. Ask for the gateway URL. Never fabricate a fixture.
  - Any live probe returns a scope error. Record the exact error and ask — do not silently route around it.
  - `sessions.create` or `sessions.patch` is refused: the fallback is approach B (instruct `main` via `chat.send`). That is the human's design decision, not yours.
  - Any work that needs a paid Apple Developer account (APNs, device signing, TestFlight).
  - The two-device fan-in needs a second paired device that does not exist.
  - A live capture contradicts a shipped rule (a column, lane, or activity mapping). Report the drift; do not quietly rewrite the rule to match.
  - The same failure three times.

ASSUMPTIONS (repo-grounded):
  - Baseline is 166 XCTest cases, 3 skipped without `LIVE_HOST`. Iteration 0 records the real number.
  - Fixtures and source-grep tests locate files via `#filePath`; no bundle resource wiring.
  - `tools/rpc-probe.mjs` prints the full `res.payload` (or `ERROR …`). It prints neither `hello-ok` nor events; M0 may add two small opt-in flags (`DUMP_HELLO=1`, `--listen <ms>`) rather than inventing output.
  - `MockGateway` already serves `agents.list`, `sessions.list`, `tasks.list`, `sessions.patch` (with `failNextPatch` and a `sessions.changed` broadcast), `sessions.create`, `tasks.cancel`, `chat.send`, `chat.abort`, `chat.history`, and `dropAllConnections()` for reconnect tests.
  - The simulator is iPhone 17 Pro, UDID `A23F9506-356C-41B2-8A29-9B0022746168`.

FLAGGED — no honest automated oracle (human only, never self-signed):
  - Whether onboarding actually reads clearly to someone who has never seen the app.
  - Visual fidelity of the retheme; a screenshot proves it rendered, not that it looks right.
  - Camera, microphone, photo-library, long-press menus, and sheet behavior — `xcrun simctl` cannot tap or drag, and this repo has no UI-test target.
  - Two-device fan-in: needs real hardware and a real second pairing.
  - VoiceOver rotor order and spoken output. (Dynamic Type *clipping* IS checkable — see M5.3.)

---

## CHECKLIST SEED (copy verbatim into `designs/2026-09-07-app-completion-checklist.md` on iteration 0)

```markdown
# OpenClaw v1 completion checklist — memory for designs/2026-09-07-app-completion-loop.md
BASELINE_TESTS: <fill from the first C1 run>
HOST: <fill from the ralph prompt line>
Legend: [ ] todo · [x] done (evidence required) · [H] human checkpoint (never ticked by the agent, never gating)

## M0 — Truth pass (gates every later milestone; no screenshot)
- [ ] M0.0 GATE: HOST known AND `test -f tools/.phase0-device.json`. Otherwise STOP-AND-ASK. Record the human's approval for mutating probes on a throwaway session labeled `v1-probe-2026-09-07`.
- [ ] M0.1 `sessions.list '{"includeDerivedTitles":true,"includeLastMessage":true}'` → `Tests/Fixtures/sessions.list.json` — CHECK: C5, and `grep -c '"status"'` ≥ 1 (0 → STOP-AND-ASK: older gateway, rows lack status).
- [ ] M0.2 `tasks.list '{}'` → `Tests/Fixtures/tasks.list.json` — CHECK: C5.
- [ ] M0.3 `agents.list '{}'` → `Tests/Fixtures/agents.list.json` — CHECK: C5.
- [ ] M0.4 `DUMP_HELLO=1 … tasks.list '{}'` → `Tests/Fixtures/hello-ok.json`; record whether `policy.attachments` is present — CHECK: valid JSON.
- [ ] M0.5 Scope truth: probe one admin-only method (`agents.update`) and record the exact error. Settles the unproven `operator.admin` claim in `.docs/protocol.md` §10 — CHECK: the error text is in `Fixtures/README.md`.
- [ ] M0.6 (mutating, approved) `sessions.create {"agentId":"main","label":"v1-probe-2026-09-07"}` → fixture; note the returned key + sessionId — CHECK: C5; scope error → STOP-AND-ASK.
- [ ] M0.7 (mutating, approved) On that session: `chat.send` with a 1-px PNG attachment, then `chat.history`, then `chat.abort` → three fixtures — CHECK: C5 each; an attachments rejection → STOP-AND-ASK.
- [ ] M0.8 (mutating, approved) `sessions.patch` archive → unarchive → archive on that session, with `--listen 5000` running; record whether `sessions.changed` arrived — CHECK: C5; no event → STOP-AND-ASK (the Board would need polling).
- [ ] M0.9 (mutating, approved) `tasks.cancel` against a task from M0.2 if one is cancellable; otherwise record "none available" — CHECK: fixture or a recorded reason.
- [ ] M0.10 Optional methods, each captured or recorded as unavailable: `commands.list`, `projects.list`, `agents.workspace.list`, `artifacts.list` — CHECK: four rows in `Fixtures/README.md`.
- [ ] M0.11 `Tests/Fixtures/README.md`: one row per method (captured | unknown method | forbidden), gateway version if `hello-ok` carries it, and the PROVISIONAL banner DELETED — CHECK: `grep -c PROVISIONAL OpenClawMobile/Tests/Fixtures/README.md` == 0.
- [ ] M0.12 Existing decode tests pass unchanged against the real payloads — CHECK: C2 `BoardModelTests`. Any drift → STOP-AND-ASK, do not rewrite a rule to match.
- [ ] M0.13 GATE: C1 exit 0, `Executed N` ≥ BASELINE_TESTS. Record `M0 GATE`.

## M1 — Board on live data (screenshot: board)
- [ ] M1.1 Board renders the live roster end to end: point the app at HOST, open the Board, confirm real sessions appear — CHECK: C6 `--open-board` after seeding a paired identity; the PNG shows a real session title.
- [ ] M1.2 Live archive → unarchive on the throwaway session, driven from the app — CHECK: the app's own frame recorded in the wire log; the card moves and comes back.
- [ ] M1.3 Live lane move (`category`) — CHECK: wire log frame; the card lands in the new lane.
- [ ] M1.4 Live start from Backlog (`chat.send`) — CHECK: a reply arrives in that session's thread.
- [ ] M1.5 Live stop (`chat.abort`) — CHECK: the bubble is marked Stopped, not Failed.
- [ ] M1.6 Live new task (`sessions.create`) — CHECK: the card appears in Backlog after a refresh.
- [ ] M1.7 Live task cancel (`tasks.cancel`) or a recorded reason none was available — CHECK: wire log frame or the reason.
- [ ] M1.8 GATE: C1, C3, C4 clean; board screenshot read.
- [H] M1.H Human: long-press menu, archive confirm sheet, lane picker, and new-task sheet all behave on a real device. PENDING FOR HUMAN.

## M2 — Reliability (screenshot: chat mid-reconnect)
- [ ] M2.1 `Tests/ReconnectTests.swift::testStreamingBubbleRecoversAfterADrop` — with a run streaming, `gateway.dropAllConnections()`, then let it reconnect; assert no bubble is left `isStreaming` forever and the thread is not duplicated — CHECK: C2 ReconnectTests.
- [ ] M2.2 `::testBoardRefreshesAfterADrop` — the Board re-reads after reconnect (its `sessions.changed` subscription survives) — CHECK: C2 ReconnectTests.
- [ ] M2.3 Missed-event backfill: on reconnect, re-read `chat.history` for the open thread and reconcile by idempotency key rather than appending duplicates — `::testHistoryBackfillDoesNotDuplicate` — CHECK: C2 ReconnectTests.
- [ ] M2.4 Staleness is visible, never silent: when the socket is down, the chat header and Board say so (a real state, not a spinner that implies liveness) — CHECK: `grep -rn 'Reconnecting\|Offline' OpenClawMobile/Sources/Features` ≥ 1 AND a test asserting the flag flips on disconnect.
- [ ] M2.5 Foreground refresh: on `scenePhase` → active, reconnect and re-read — CHECK: `grep -rn 'scenePhase' OpenClawMobile/Sources` ≥ 1 and a view-model test for the refresh entry point.
- [ ] M2.6 Two-device fan-in P1/P7 (`.docs/sync.md`): a turn sent on device A appears on device B, and a remote-paired device gets the same scopes as a loopback-paired one — CHECK: live, both devices. **If no second device exists → STOP-AND-ASK; cutting this is the human's call.**
- [ ] M2.7 GATE: C1, C3, C4 clean; screenshot read.
- [H] M2.H Human: pull the tunnel mid-reply on a real device and confirm the app recovers without lying about what it knows. PENDING FOR HUMAN.

## M3 — Onboarding (screenshots: first-run, settings)
- [ ] M3.1 First run explains what the app connects to and what pairing does BEFORE asking for a code — CHECK: a first-run view exists and a test asserts it shows when `!settings.isConfigured` and no host was ever set.
- [ ] M3.2 Every pairing failure names its fix: expired code, wrong host, unreachable gateway, approval pending — CHECK: `PairingFlowTests` covers all four states mapping to distinct user-facing strings.
- [ ] M3.3 `README.md`: what it is, the gateway it needs, how to pair, how to build and test, one screenshot — CHECK: `wc -l README.md` ≥ 40 AND it links a PNG in `designs/assets/`.
- [ ] M3.4 GATE: C1 clean; both screenshots read.
- [H] M3.H Human: hand the README to someone who has never seen this app; they reach a working paired chat without asking a question. PENDING FOR HUMAN.

## M4 — Notifications, honest subset
- [ ] M4.1 Decide and record: APNs needs a paid Apple account this project does not have. Write the design note in `designs/` and CUT push from v1 with that reason — CHECK: the note exists and `product.md` §5 agrees.
- [ ] M4.2 Local notification on run completion while the app is foregrounded or recently backgrounded, fired ONLY from a real terminal event (`chat` final/aborted/error) — never a timer — CHECK: `Tests/NotificationTests.swift::testFiresOnTerminalEventOnly`, plus a case asserting no notification on a delta.
- [ ] M4.3 `UNUserNotificationCenter` permission is requested at a moment the user understands, and a denial is handled without a crash — CHECK: a reducer test for granted/denied.
- [ ] M4.4 GATE: C1 clean.
- [H] M4.H Human: background the app during a long run and confirm the notification arrives and opens the right thread. PENDING FOR HUMAN.

## M5 — Polish, accessibility, cut
- [ ] M5.1 Every screen has a real empty state and a real error state (Board columns, roster, chat, settings) — CHECK: a test per screen's view model for the empty and error branches.
- [ ] M5.2 Error copy names the fix, never a raw error code — CHECK: `grep -rnE '"[A-Z_]{6,}"' OpenClawMobile/Sources/Features` prints nothing user-facing.
- [ ] M5.3 Dynamic Type: at `.accessibilityExtraExtraExtraLarge` no label is truncated on the five screens plus the Board — CHECK: `Tests/DynamicTypeTests.swift` measuring the layout at that size (ponytail: measure the text, do not snapshot-test images).
- [ ] M5.4 VoiceOver labels on every interactive control — CHECK: `grep -rn 'accessibilityLabel' OpenClawMobile/Sources/Features | wc -l` ≥ the count of `Button(`/`NavigationLink` without a text label; no unlabeled icon-only control.
- [ ] M5.5 Contrast: body and caption text on `Theme.card` and `Theme.bg` meet 4.5:1 — CHECK: `DesignSystemTests::testContrastRatios` computing the ratio from the tokens.
- [ ] M5.6 Delete what nothing uses, or record why it stays (standing list: `AttachmentPolicy.from(helloOK:)` — wire it in M0.4 or delete it; `ChatThread.isMain`; the agent-id convenience wrappers) — CHECK: each is either referenced in `Sources/` or gone.
- [ ] M5.7 TODOS.md matches reality; CHANGELOG has the release entry; `CLAUDE.md` and `.docs/` describe the shipped app — CHECK: no TODOS item describes work already done.
- [ ] M5.8 FINAL GATE: C1 exit 0 with `Executed N` ≥ BASELINE_TESTS; C3 + C4 empty; every fixture is a live capture; all screenshots present. Then summarize with **PENDING FOR HUMAN** listing M1.H, M2.H, M3.H, M4.H verbatim, and output: OPENCLAW V1 COMPLETE

## QUESTIONS
(none yet)

## BLOCKED
(none yet)
```
