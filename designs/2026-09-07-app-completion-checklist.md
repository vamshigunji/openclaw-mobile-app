# OpenClaw v1 completion checklist — memory for designs/2026-09-07-app-completion-loop.md
BASELINE_TESTS: 166 (C1 exit 0, 3 skipped without LIVE_HOST, 2026-09-07)
HOST: (not supplied — gateway offline 2026-09-07; P1–P4 run without it, P5 stops and asks)
Legend: [ ] todo · [x] done (evidence required) · [H] human checkpoint (never ticked by the agent, never gating)

## P1 — Onboarding a stranger can complete (OFFLINE) (screenshots: first-run, settings)
- [x] P1.1 — RED: yes (cannot find 'FirstRunGate' in scope) — GREEN: C2 exit 0 FirstRunTests Executed 4 tests; gate wired in OpenClawMobileApp, QA launch args skip it — First run explains what the app connects to and what pairing does BEFORE asking for a code — CHECK: a first-run view exists; a test asserts it shows when `!settings.isConfigured` and no host was ever set, and never again after pairing.
- [x] P1.2 — RED: yes (FailureReason has no member headline/recovery) — GREEN: C2 exit 0 PairingFailureCopyTests 12 + PairingFlowTests 6; added .badHost/.unreachable, headline+recovery on the reason, FailureReason.from() routing real errors, view and VoiceOver both read from it — Every pairing failure names its fix: expired code, wrong host, unreachable gateway, approval pending — CHECK: C2 `PairingFlowTests` covers all four states mapping to four distinct user-facing strings (no raw error codes).
- [x] P1.3 — CHECK: 104 lines (≥40), references designs/assets/2026-09-06-dev-suite-board.png which exists; covers what it is, gateway prerequisites, the 4-step pairing walkthrough, build/test/run commands, the probe tools, and the architecture — `README.md`: what it is, the gateway it needs, how to pair, how to build and test, one screenshot — CHECK: `wc -l README.md` ≥ 40 AND it references a PNG in `designs/assets/`.
- [x] P1.4 P1 GATE: C1 exit 0, Executed 176 ≥ 166 baseline; C3 + C4 empty; first-run PNG read (lobster, OpenClaw title, 3 explanation paragraphs, brand CTA), settings PNG read — GATE: C1 exit 0 ≥ BASELINE_TESTS; C3 + C4 empty; both screenshots read.
- [H] P1.H Human: hand the README to someone who has never seen this app; they reach a working paired chat without asking a question. PENDING FOR HUMAN.

## P2 — Reliability against the mock gateway (OFFLINE) (screenshot: chat while disconnected)
- [x] P2.1 — RED: yes (ChatViewModel has no member isConnected) — GREEN: C2 ReconnectTests 4/4; a drop ends every streaming bubble via endStreamingOnDisconnect — `Tests/ReconnectTests.swift::testStreamingBubbleRecoversAfterADrop` — with a run streaming, `gateway.dropAllConnections()`, let it reconnect; assert no bubble is left `isStreaming` forever and the thread is not duplicated — CHECK: C2 ReconnectTests.
- [x] P2.2 — GREEN: C2 ReconnectTests::testBoardRefreshesAfterADrop; BoardViewModel re-loads when connectionState returns true — `::testBoardRefreshesAfterADrop` — the Board's `sessions.changed` subscription survives a reconnect and the board re-reads — CHECK: C2 ReconnectTests.
- [x] P2.3 — GREEN: C2 ReconnectTests::testHistoryBackfillReconcilesByIdempotencyKey; two refreshes yield one copy — `::testHistoryBackfillDoesNotDuplicate` — on reconnect, re-read `chat.history` for the open thread and reconcile by idempotency key instead of appending — CHECK: C2 ReconnectTests.
- [x] P2.4 — CHECK: `grep -rn Reconnecting Sources/Features` = 2 (chat header + board banner); transition test asserts the drop is published after the socket was up — Staleness is visible, never silent: while the socket is down the chat header and Board say so — a real state, not a spinner implying liveness — CHECK: `grep -rn 'Reconnecting\|Offline' OpenClawMobile/Sources/Features` ≥ 1 AND a test asserting the flag flips on disconnect and clears on reconnect.
- [x] P2.5 — CHECK: `grep -rn scenePhase Sources` = 2; RootTabView calls AppModel.refreshOnForeground on .active, which revives the socket and each screen re-reads — Foreground refresh: on `scenePhase` → `.active`, reconnect and re-read — CHECK: `grep -rn 'scenePhase' OpenClawMobile/Sources` ≥ 1 AND a view-model test for the refresh entry point.
- [x] P2.6 P2 GATE: C1 exit 0, Executed 180 ≥ 166; C3 + C4 empty; chat screenshot read (demo thread renders with the composer and code block) — GATE: C1, C3, C4 clean; screenshot read.
- [H] P2.H Human: pull the tunnel mid-reply on a real device and confirm the app recovers without lying about what it knows. PENDING FOR HUMAN.

## P3 — Notifications, honest subset (OFFLINE)
- [x] P3.1 — designs/2026-09-07-push-notifications-decision.md records why APNs is cut (no paid Apple team, C9 daemon unbuilt) and states the honest ceiling: nothing fires once iOS suspends the socket — Record the cut: APNs needs a paid Apple account this project does not have. Write the design note in `designs/` and cut push from v1 with that reason — CHECK: the note exists AND `.docs/product.md` §5 agrees.
- [x] P3.2 — RED: yes (cannot find 'RunNotification') — GREEN: C2 NotificationTests 6/6; fires only on chat final/aborted/error, asserts NO notification on a delta or on tick/presence/session.tool — Local notification on run completion, fired ONLY from a real terminal event (`chat` final/aborted/error) — never a timer — CHECK: `Tests/NotificationTests.swift::testFiresOnTerminalEventOnly` plus a case asserting NO notification on a delta.
- [x] P3.3 — GREEN: NotificationPermission state machine tested (notDetermined→ask once, denial remembered, never re-asked); requested in start(), not at launch — Permission requested at a moment the user understands; a denial is handled without a crash and without nagging — CHECK: a reducer test for granted/denied/not-determined.
- [x] P3.4 — RED: yes (no member attachmentPolicy on MockGateway/GatewayWSSyncSource) — GREEN: C2 AttachmentBudgetTests 9/9 incl. a gateway advertising 2MB/1MB overriding our defaults end to end; AttachmentPolicy.default now appears only as the fallback — Attachment policy comes from `hello-ok` instead of the hard-coded default: `GatewayConnection` retains `policy`, `ChatViewModel` reads it — CHECK: `AttachmentBudgetTests` decodes a MockGateway-served `hello-ok` with non-default limits and the budget honors them; `grep -rn 'AttachmentPolicy.default' OpenClawMobile/Sources` shows it only as the fallback.
- [x] P3.5 P3 GATE: C1 exit 0, Executed 187 ≥ 166; C3 + C4 empty. ChatViewModelLifecycleTests caught a fresh retain cycle from the two new start() tasks — fixed with weak captures before ticking — GATE: C1, C3, C4 clean.
- [H] P3.H Human: background the app during a long run and confirm the notification arrives and opens the right thread. PENDING FOR HUMAN.

## P4 — Polish, accessibility, cut (OFFLINE) (screenshots: board, roster at XXXL)
- [x] P4.1 — GREEN: C2 ScreenStatesTests 8/8; empty board stays empty (never fabricated), every column has title+icon, roster falls back to main, board and roster both surface a failure without blanking — Every screen has a real empty state and a real error state (Board columns, roster, chat, settings) — CHECK: a test per screen's view model for the empty and error branches.
- [x] P4.2 — GREEN: tests assert no [A-Z_]{6,} in any user-facing error and that every GatewayError has a readable description; the grep's only hits in Features are SEED_* env var names, not copy — Error copy names the fix, never a raw code — CHECK: `grep -rnE '"[A-Z_]{6,}"' OpenClawMobile/Sources/Features` shows nothing user-facing.
- [x] P4.3 — RED: yes (4 real failures: 'Waiting on you' 268pt, 'Settings' tab 141pt, 'Scan Setup Code' 391pt, 'Set up my gateway' 425pt at XXXL) — GREEN: PrimaryButton and StatusBadge now wrap to 2 lines with minimumScaleFactor; AccessibilityTests measures the longest unbreakable word, the property that actually clips — Dynamic Type: at `.accessibilityExtraExtraExtraLarge` no label is truncated on the five screens plus the Board — CHECK: `Tests/DynamicTypeTests.swift` measuring text at that size (ponytail: measure the string, do not snapshot images).
- [x] P4.4 — RED: yes (Settings gear icon had no label) — GREEN: labelled it; ScreenStatesTests scans every Features file for icon-only controls. Proved the scan works by injecting an unlabelled button (went red) and removing it — VoiceOver labels on every interactive control — CHECK: no icon-only `Button(`/`NavigationLink` in `Sources/Features` lacks an `accessibilityLabel`.
- [x] P4.5 — GREEN: AccessibilityTests computes WCAG 2.1 ratios from the tokens; text/textBody/textMuted all ≥4.5:1 on bg, card and elevated; status colours ≥3:1 on card — Contrast: body and caption text on `Theme.card` and `Theme.bg` meet 4.5:1 — CHECK: `DesignSystemTests::testContrastRatios` computing the ratio from the tokens.
- [x] P4.6 — Deleted AttachmentPolicy.from(helloOK:) (production decodes through InboundEnvelope; the fixture test now exercises that real path) and the three agent-id SyncSource wrappers plus GatewayWSSyncSource.send(agentId:) after migrating MockGatewayE2ETests to the session-keyed API. ChatThread.isMain kept — used by BoardModel — Delete what nothing uses or record why it stays (standing list: `ChatThread.isMain`, the agent-id convenience wrappers; `AttachmentPolicy.from(helloOK:)` is now used by P3.4) — CHECK: each is either referenced in `Sources/` or gone.
- [x] P4.7 — TODOS.md: the hello-ok policy item moved to Completed (shipped this phase); remaining items are genuinely open. CLAUDE.md and .docs were synced by the v0.2.0.0 doc-release pass — TODOS.md matches reality; `CLAUDE.md` and `.docs/` describe the shipped app — CHECK: no TODOS item describes work already done.
- [x] P4.8 P4 GATE: C1 exit 0, Executed 201 ≥ 166; C3 + C4 empty; board and roster screenshots read — GATE: C1, C3, C4 clean; both screenshots read.
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

### 2026-09-07 — P5.0 blocked: no gateway host

The loop finished every offline phase (P1–P4, 23 items, 201 tests) and reached P5, which
cannot start without a live gateway. Two things are needed:

1. **The gateway URL.** `tools/.phase0-device.json` has the paired identity (deviceToken +
   Ed25519 key) but no host, and nothing in the repo records one. Restart the loop with it:

   ```
   /ralph-loop "Read designs/2026-09-07-app-completion-loop.md and keep executing unchecked checklist items. HOST=wss://your-real-host.trycloudflare.com Stop only when the completion promise is literally true" --max-iterations 120 --completion-promise "OPENCLAW V1 COMPLETE"
   ```

   No angle brackets around the URL — the shell reads `<url>` as a redirect.

2. **Approval for the mutating probes.** P5.6–P5.9 create a throwaway session labelled
   `v1-probe-2026-09-07`, send it a 1-pixel PNG, archive and unarchive it, abort its run,
   and cancel a task. The session stays archived on the gateway afterwards.

**Host search exhausted (2026-09-07).** Before declaring the block I checked: git history
across all branches, the simulator app's stored `gateway.host` (empty), `.docs/`, `designs/`,
`tools/`, and localhost:18789 (closed). The only real Quick Tunnel URL anywhere is
`wss://certificates-geography-arising-von.trycloudflare.com` from July; probing it returns
`ws error` — Quick Tunnel URLs are regenerated on every restart, so it is long dead. There is
no host to recover; it has to come from the human.

Also still open and needing a person: **P7, the two-device fan-in**, which needs a second
paired device that does not exist yet. Cutting P7 is the human's call, not the loop's.


## BLOCKED
(none yet)
