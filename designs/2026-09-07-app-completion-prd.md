# OpenClaw Mobile — App completion PRD (v0.2.0.0 → v1.0)

**Date:** 2026-09-07 · **Kind:** PRD (source for the end-to-end loop)
**Compiles to:** `designs/2026-09-07-app-completion-loop.md`

## 0. Goal

Take the app from its current state (v0.2.0.0 shipped: pairing, multi-agent chat, retheme,
developer chat, attachments, dictation, Board tab) to a **v1.0 a stranger can install, pair,
and use every day** — every claimed capability verified against the real gateway, not a mock,
and the three "still out" items from `CLAUDE.md` either built or explicitly cut with a reason.

## 1. Where the app is (verified 2026-09-07)

| Capability | State |
|---|---|
| Transport, pairing ladder, v3 signature, single-connection actor | live-verified |
| Multi-agent roster, per-agent chat, activity indicator, create/edit/delete agents | live-verified |
| Retheme, developer chat (Stop/Retry, code blocks, tool timeline) | shipped v0.2.0.0, PR #10 |
| Attachments (photo/camera/file), on-device dictation | shipped v0.2.0.0, PR #10 |
| Board tab (columns, lanes, 6 interactions) | built on `dev-suite-board`, **schema-derived fixtures** |
| Two-device fan-in (sync probes P1/P7) | never run — needs a second paired device |
| Push notifications, cockpit control, multi-gateway | not built (`product.md` §5 out of scope for v1) |
| `README.md` | one-line stub |
| Conversation persistence, drafts, bookmarks (C4) | designed, unbuilt |

Test suite: 166 XCTest cases. CI green on every PR. Zero third-party dependencies.

## 2. Scope — what "done" means

### M0. Truth pass (blocks everything else)
Every shape the app asserts must be confirmed against the live gateway. Until this passes, the
Board's fixtures are schema-derived guesses and three chat features are mock-verified only.

- Capture verbatim fixtures: `sessions.list`, `tasks.list`, `hello-ok` (policy), `agents.list`,
  `chat.history` with an attachment, `sessions.create`, `sessions.patch`, `chat.abort`,
  `tasks.cancel`, `commands.list`, `projects.list`, `agents.workspace.list`, `artifacts.list`.
- Replace `Tests/Fixtures/*.json` and delete the PROVISIONAL banner from its README.
- Record which optional methods answer `unknown method` or a scope error.
- Confirm the phone's real scope set (`operator.admin` assertion in `.docs/protocol.md` §10 is
  still unproven; `tools/rpc-probe.mjs` settles it).

### M1. Board on live data
- Board renders the real roster; column and lane rules hold against live rows.
- All six writes verified against the live gateway on a throwaway session, not just MockGateway.
- If `sessions.create`/`sessions.patch` return a scope error: fall back to approach B (instruct
  `main`), documented as a decision.

### M2. Reliability — the app survives a real day
- **Reconnect without gaps.** After a tunnel drop, no bubble is stuck streaming and no board
  card is stale. Today's reconnect resubscribes but does not replay missed events
  (`sync.md` P6 backfill depth is the open question).
- **Backgrounding.** iOS suspends the socket seconds after backgrounding. Decide and implement:
  reconnect-and-backfill on foreground (minimum), and state plainly in the UI when the view is
  stale rather than showing stale data as live.
- **Two-device fan-in (P1, P7).** Pair a second device (or a second simulator identity) and
  prove a turn sent on one appears on the other, and that a remote-paired device gets the same
  scopes as a loopback-paired one.

### M3. Onboarding a stranger can complete
- First run explains what this app talks to and what pairing does, before asking for a code.
- Pairing failures name the fix (expired code, wrong host, gateway unreachable, pending approval).
- `README.md`: what it is, the gateway it needs, how to pair, how to build, and a screenshot.

### M4. Notifications (the one big missing capability)
`product.md` lists push as out of scope for v1; `designs/2026-07-23-c9-gateway-daemons-prd.md`
says it needs a daemon **and an Apple Developer team**, which this project does not have.
- Ship the honest subset that needs no team: local notifications when the app is foregrounded
  or recently backgrounded, driven by real run-completion events.
- Write the APNs path as a design note, not code, and cut it from v1 with the reason.
- STOP AND ASK before any work that needs a paid Apple account.

### M5. Polish and cut
- Empty states, error copy, and loading states on every screen (Board, roster, chat, settings).
- Accessibility pass: Dynamic Type at XXL does not clip, VoiceOver labels on every control,
  contrast on the new palette.
- Delete what nothing uses (the ponytail review's standing list) or record why it stays.
- TODOS.md reflects reality; CHANGELOG entry per release; docs match the code.

## 3. Explicitly NOT in v1 (do not build; a loop that touches these has drifted)
Cockpit/terminal control · multi-account or multi-gateway · cross-agent search · message
editing · rendering inbound media from history · Workboard plugin mirroring · drag-and-drop
between board columns · slash-command picker · workspace/artifact browsing · conversation
JSON cache (nothing reads it yet) · APNs push (needs an Apple team).

## 4. Constraints (invariant every pass)
- Zero third-party dependencies. `@Observable` view models, no Combine. Views never touch
  network or disk. One shared socket. All colors and radii only in `Theme.swift`. No shadows.
- Real gateway signals only — never a fabricated activity verb, status, or task.
- TDD: every pure rule gets a failing test first. Never weaken or skip a test to pass.
- Fixtures captured from the live gateway are never hand-edited.
- Demo mode keeps working on every screen with no host configured.

## 5. Definition of done
1. `xcodebuild test` green, test count never below 166.
2. Every fixture in `Tests/Fixtures/` is a live capture; the PROVISIONAL banner is gone.
3. Every M1 write verified against the live gateway at least once, recorded with its frame.
4. Two-device fan-in demonstrated (P1, P7) or explicitly cut with a reason.
5. A stranger can go from install to a working paired chat using only `README.md`.
6. Accessibility: Dynamic Type XXL and VoiceOver pass on all five screens plus the Board.
7. Every human checkpoint listed as PENDING FOR HUMAN, never self-signed.

## 6. Human checkpoints (an agent may never tick these)
Camera capture · microphone dictation · photo-library pick · Board long-press menu and sheets ·
visual review of the retheme · pairing against the real gateway with a fresh setup code ·
two-device fan-in · Dynamic Type and VoiceOver on device.
