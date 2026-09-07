# TODOS

## Board (Kanban tab)

### Finish the Board tab from the dev-suite loop

**What:** Run the remaining phases of `designs/2026-09-06-dev-suite-loop.md`: phase 0 live fixture capture (`sessions.list`, `tasks.list`, `hello-ok`, `sessions.create/patch`, `chat.send` with an attachment, `chat.abort`), then phases 4–5 (Board tab: columns from session status, lanes from category/worktree/cwd, archive/start/lane-move/stop/cancel) and phase 6 (docs).

**Why:** The Board is the third cut of the developer suite; phases 1–3 shipped in v0.2.0.0 without it because the gateway was offline for fixture capture. The user chose to continue on schema-derived sample fixtures if the gateway stays down (decision 2026-09-07).

**Context:** Progress memory is `designs/2026-09-06-dev-suite-checklist.md` (21/53 done). Restart with the `/ralph-loop` line in the loop file, passing `HOST=<gateway url>`; mutating probes on the throwaway session `phase0-probe-2026-09-06` are already approved. Session-keyed threads (`ChatThread`, `ChatView(thread:)`) and `chat.abort` are in place for Board cards to open and stop task sessions.

**Effort:** L
**Priority:** P1
**Depends on:** Gateway reachable (or the schema-derived-fixture fallback)

## Chat

### Send should end an in-progress dictation

**What:** `ChatViewModel.send()` stops an active dictation (finishing it into the draft) before sending; today only the mic tap ends it.

**Why:** Design §4.3 says "tap again/send to stop". Sending mid-dictation leaves the recognizer running and its final text lands in the next draft.

**Context:** `SpeechDictation.toggle` already handles `.listening → .finishing`; send would need to await the final transcript or drop it. `DictationState` is a pure reducer with tests.

**Effort:** S
**Priority:** P3
**Depends on:** None

## Infrastructure

### Nightly protocol-drift probe

**What:** cron `node tools/phase0-verify.mjs <stable-host>` nightly against the live gateway; alert on any handshake/frame-shape change.

**Why:** protocol-v4 is upstream-controlled; changes can land anytime. The mock-gateway CI (eng review 2026-07-21, issue 4B) validates yesterday's protocol by design — only a live probe catches drift.

**Context:** Pros: drift pages the founder instead of breaking tester #1; ~30 min setup. Cons: needs the gateway reachable nightly; false alarms on tunnel churn until the named tunnel exists. Declined as an Approach-A plan task (eng review D8); risk documented in `.docs/devicetrust.md` invariants. Reference run: `tools/phase0-roundtrip.mjs` also exercises chat.send.

**Effort:** S
**Priority:** P2
**Depends on:** Stable tunnel URL (B milestone `devicetrust setup` CLI makes this trivial)

## Completed

### Read the attachment policy from hello-ok

**What:** Keep `hello-ok.policy.attachments` / `policy.maxPayload` on `GatewayConnection` and feed it to `ChatViewModel` instead of `AttachmentPolicy.default`.

**Why:** A gateway configured with a smaller `agents.defaults.mediaMaxMb` would reject attachments the phone thinks fit.

**Completed:** v0.2.0.0 (2026-09-07) — `GatewayConnection` retains the advertised policy; `ChatViewModel` replaces its defaults once the handshake lands. The duplicate `AttachmentPolicy.from(helloOK:)` parser was deleted in favour of the envelope the app already decodes.
