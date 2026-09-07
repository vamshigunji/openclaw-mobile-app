# C6 — Agents / Roster + approach-B PRD

## 1. Summary
C6 owns the agent-management surface of OpenClaw Mobile: the `agents.list` roster (Slack-style team list with status badges + live activity), the per-agent profile page, and create/edit/delete. Because the phone token holds only `operator.read` + `operator.write` (F0.3), every mutating operation routes through **approach B** — `MainAgentTask.run` sends a deterministic instruction envelope to the privileged `main` agent over the write path, then polls `agents.list` to confirm. It is a separate team because roster + admin-via-LLM is a self-contained vertical: it consumes the C0 contract and the C1/C3 spine, never renders a chat thread's internals, and carries a distinct risk profile (irreversible ops driven by an LLM) that wants its own reviewer. Existing code lives in `OpenClawMobile/Sources/Features/Agents/`. **Note:** the isolation this PRD targets is not yet realized in code — today's surface is coupled to Root and to C5 (see §3, §5, §7); the decoupling is scoped as required work, not described as done.

## 2. Scope
**In scope**
- Roster fetch + display via `SyncSource.listAgents()` (`AgentRosterViewModel`, `AgentsListView`), with a never-empty fallback to a `main` row.
- Status badge + live activity per roster row, driven only by real signals (`AgentActivity.from(event)` via `SyncSource.activityStream(agentId:)`).
- Create flow: form → deterministic instruction envelope → poll for the new agent (`CreateAgentView`, `CreateAgentViewModel`, `CreateAgentRequest`, `CreateAgentFlow`).
- Profile page: read identity + instructions (`operator.read`), edit and delete via approach B (`AgentProfileView`, `AgentProfileViewModel`, `AgentProfile`).
- `MainAgentTask` — the shared "instruct `main`, poll to confirm" loop (≤20 polls × 6s = 120s ceiling → `.pending`).
- Op-id / idempotency-keyed envelopes and out-of-band delete confirmation UX.
- Demo-mode behavior (canned roster, client-side create) so the surface runs host-less.
- **The C5/Root decoupling seam** (see §5 M1) — rename `AgentsListView` → `AgentsView`, drop the `AppModel` and `ChatView` dependencies, hoist thread navigation to the app root via an `onOpenThread` callback. Required for C6 to build alone; not yet built.

**Out of scope**
- The chat thread, message bubbles, streaming, STT, history rendering — **C5 Chat** (`ChatView`). Target: C6 hands an `AgentSummary` up to the app root, which presents C5. (Today C6 constructs `ChatView` directly — the coupling M1 removes.)
- Wire DTOs, RPC signatures, `SyncSource` protocol, `AgentSummary`/`AgentActivity` type definitions, golden JSON, `GatewayError` — **C0 Protocol/Contract**.
- The socket, framing, reconnect, idempotency-key transport, the `chat.send` write path, the concrete `GatewayWSSyncSource`/`GatewayConnection` — **C1 Transport**.
- Tokens, colors, `MonoField`, `PrimaryButton`, `ActivityLine`, 4pt/1px rules — **C3 Design System** (`Theme.swift`).
- Persisted roster cache / stars / mutes / last-read — **C4 Local Store**.
- Pairing + gateway config UI — **C7 Settings**.
- The `agents.create/update/delete` / `agents.files.set` admin RPCs themselves — they run on the gateway inside the `main` agent's authority (**C9 / gateway**); C6 only emits the instruction and observes `agents.list`.

## 3. Interface (the stable contract)
**Ownership convention (used throughout):** the `SyncSource` **protocol** is a **C0** contract; the concrete `GatewayWSSyncSource` is **C1**. C6 links both modules but should depend only on the protocol.

**Exposes today (present code):**
```swift
struct AgentsListView: View {           // OpenClawMobile/Sources/Features/Agents/AgentsListView.swift
    init(app: AppModel)                  // couples to Root AppModel
}
```
This surface is **not isolated**: at `AgentsListView.swift:40` it constructs `ChatView(agent:app:)` — a hard C5 sibling reference — and it reads `app.sync` / `app.settings.isConfigured` from Root.

**Exposes after M1 (target contract — required-but-unbuilt):**
```swift
struct AgentsView: View {                // the tab surface
    init(sync: SyncSource, isConfigured: Bool,
         onOpenThread: @escaping (AgentSummary) -> Void)
}
```
`onOpenThread` is the seam to C5: C6 emits a selected `AgentSummary`; the app root presents the chat thread. No C5 type crosses the boundary. Until M1 lands, the `AgentsView` rename, the `sync`+`isConfigured` injection, and the `onOpenThread` decoupling **do not exist** — do not treat them as available.

**Consumes** (via C0 types + protocols + C3 components):
- From **C0**: `AgentSummary`, `AgentsListResult`, `AgentActivity`, `InboundEnvelope`, `GatewayError`, and the `SyncSource` protocol.
- From **C1**: a `SyncSource` instance (concretely `GatewayWSSyncSource`) — reads (`listAgents`, `loadInstructions`, `activityStream`) go through the protocol; the approach-B write path does **not** yet (see §4).
- From **C3**: `Theme` tokens + `MonoField` / `PrimaryButton` / `ActivityLine`.

**Internal-but-load-bearing contracts** (owned by C6, may migrate to C0 if a sibling needs them):
- `MainAgentTask.run(_:instruction:idempotencyKey:onPoll:check:) -> Outcome<T>` with `Outcome { case done(T); case pending; case failed(String) }`. **Note:** its first parameter is currently typed as the concrete `GatewayWSSyncSource` (`MainAgentTask.swift:26`), not a protocol — see §4.
- Instruction envelope builders: `CreateAgentRequest.instruction`, `EditAgentRequest.instruction`, and the inline delete envelope — each ends in a machine-checkable done line (`CREATED <id>` / `DELETED <id>`).

## 4. Dependencies
Allowed: **C0, C1, C3**. Nothing else.

Module-import rule (to be enforced by C10's graph): C6 becomes its own Swift module `FeatureAgents` whose manifest lists exactly `Contract` (C0), `Transport` (C1), `DesignSystem` (C3). It does **not** list `FeatureChat` (C5), `FeatureSettings` (C7), `Auth` (C2), or `LocalStore` (C4), so any `import FeatureChat` (or other sibling) is an unresolved-module **compile error**. **This wall does not bite yet** and is a dependency on C10's not-yet-done module split: `AgentActivity`/`AgentSummary` live in `Sources/Models` and `SyncSource`/`GatewayWSSyncSource` in `Sources/Services` today (single target), and the present `AgentsListView` still imports the C5 `ChatView` (§3). Both must be fixed (C10 relocation + C6's M1) before the compile-error guarantee is real.

**Concrete-C1 coupling — stated accurately.** C6 has **two** concrete C1 links today, not one:
1. `MainAgentTask.run`'s first parameter is typed `GatewayWSSyncSource` (`MainAgentTask.swift:26`) — the load-bearing approach-B send path is on the concrete type, so C6 imports the C1 concrete module.
2. The roster/profile call sites reach the same concrete write path.

Resolution (already an open risk, now a committed M2 task): promote a minimal `send`-capable protocol to **C0** (`func send(agentId:text:idempotencyKey:) async throws`), have `GatewayWSSyncSource` conform, and retype `MainAgentTask.run`'s first parameter to that protocol. Only then is "the C1 dependency is via the protocol surface" a true statement. Until that lands, the concrete coupling is real and must be named as such.

## 5. Milestones / build order
1. **Decoupling seam (unblocks isolated build).** Rename `AgentsListView` → `AgentsView`; replace `init(app:)` with `init(sync:isConfigured:onOpenThread:)`; delete the `ChatView(agent:app:)` construction and the `ProfileRoute`→`AppModel` coupling; hoist thread + profile navigation to the app root. After this, C6 no longer references C5 or Root. (**Unbuilt — required first.**)
2. **Send-protocol promotion.** Land the C0 `send`-capable protocol; retype `MainAgentTask.run` off `GatewayWSSyncSource`. C6 now depends on no concrete C1 type. (**Unbuilt.**)
3. **Read-only roster + activity.** `AgentRosterViewModel` + roster view against `SyncSource.listAgents()`; never-empty fallback; `activityStream` → `AgentActivity` badge/`ActivityLine`; demo roster renders. (**Live** — logic exists, re-homed behind M1's init.)
4. **Create + profile read/edit (approach B).** `CreateAgentRequest` envelope + `MainAgentTask.run` + `CreateAgentFlow.newAgent` delta detection; `AgentProfileViewModel.load`/`saveEdit` via `AgentProfile.updateApplied`. Create is **Live**; edit is **pattern-proven, untested on live**.
5. **Delete + poll-timing calibration & refresh affordance.** Typed-confirmation gate before the `DELETED <id>` envelope; poll for absence. **Plus** the acceptance-gap fix: a re-poll/refresh affordance from the `.pending` state and a live-timing calibration pass on the 120s ceiling (moved out of Risks — see §6). (Delete **pattern-proven, untested**.)

## 6. Acceptance criteria
Testable against golden JSON + the mock gateway (no live host):
- Decoding the live-captured `agents.list` fixture yields the expected `[AgentSummary]` (id/name/emoji/model/workspace mapping); empty result → single `main` fallback row.
- `AgentActivity.from(env)` maps each golden event fixture (`session.tool`, `agent`, `chat`, `skill_expansion`) to the pinned verb; unknown signal → `.working`, never a fabricated verb; non-activity events → `nil` (state unchanged).
- `CreateAgentRequest.normalizedId` folds diacritics and kebab-cases ("Résumé Bot" → "resume-bot"); `.instruction` contains `id:`, `displayName:`, behavior block, and the exact `CREATED <id>` done line.
- `CreateAgentFlow.newAgent(before:after:preferId:)` returns the id-matched new agent when several appear; the first new one otherwise; `nil` when nothing new.
- `MainAgentTask.run`: with a mock `check` that never resolves, returns `.pending` after exactly 20 polls; resolves `.done` on the poll `check` first returns non-nil; a throwing `send` returns `.failed`. (Post-M2: the mock is a `send`-protocol conformer, not `GatewayWSSyncSource`.)
- `AgentProfile.updateApplied(want:in:)` is true only when the roster reflects the requested change; edit poll also accepts a detected instructions change.
- Delete: the confirmation gate blocks envelope emission until satisfied; poll returns success only when the agent is absent from a subsequent `agents.list`.
- **Pending recovery (M5):** from the `.pending` outcome the surface exposes a re-poll/refresh action that re-runs the confirm poll without re-sending the instruction (no duplicate op).
- Demo mode: create adds a client-side agent and reaches `.created` with no gateway; edit/delete report the "needs a paired gateway" path.
- **M1 boundary check:** `grep -R "import FeatureChat\|ChatView\|AppModel" Sources/Features/Agents` returns nothing after the decoupling; C6's target builds with only C0/C1/C3 on the path.

## 7. Isolation proof
This is the **target** state after M1+M2, stated as the goal to build toward — not as present fact. Once M1 removes the `ChatView`/`AppModel` references and M2 retypes `MainAgentTask` off the concrete `GatewayWSSyncSource`, an agent in a fresh worktree can build C6 from its inbound C0 types (`AgentSummary`, `AgentActivity`, `AgentsListResult`, `InboundEnvelope`, `GatewayError`) and the C0 `SyncSource` + `send` protocols alone — all linked as modules, none edited. Every test runs against C0 golden JSON and a mock protocol conformer (the existing `DemoSyncSource` is the template) — no live gateway, no sibling. The one outbound seam, `onOpenThread`, passes a C0 `AgentSummary` and references no C5 type, so C5 could then be absent from the worktree and C6 would still compile, run in demo mode, and pass its suite. **Today none of that holds:** `AgentsListView` imports `ChatView` (`AgentsListView.swift:40`) and depends on Root `AppModel`, and `MainAgentTask` depends on concrete C1 — so a worktree agent cannot build C6 in isolation until M1, M2, and C10's module relocation land. The privileged executor for all mutations remains the remote `main` agent on the Mac Mini (F0.1/F0.2), never a linked module.

## 8. Status & risks
**Status:** Roster/activity/create are **Live** (TDD'd against live-captured JSON); edit + delete are **partial** (pattern-proven, untested on a live gateway). The **isolation contract is unbuilt**: `AgentsListView(app:)` still constructs C5's `ChatView` and couples to Root, and `MainAgentTask` still takes concrete `GatewayWSSyncSource` — M1 and M2 exist precisely to close this gap. Code in `OpenClawMobile/Sources/Features/Agents/`.

**Risks / open questions:**
- **F0.3 is asserted, not proven.** If the phone token turns out to hold `operator.admin`, approach B is unnecessary indirection; verify with `tools/rpc-probe.mjs` before hardening. Whole chunk pivots on this.
- **Isolation is aspirational, not present.** The §3/§7 target contract requires M1 (C5/Root decoupling), M2 (C0 `send` protocol), and C10's relocation of `AgentSummary`/`AgentActivity`/`SyncSource` out of `Sources/Models`+`Sources/Services` into C0/C1 modules. Until all three land, the import wall does not compile-fail a wrong dependency.
- **Irreversible ops through an LLM.** Delete routes a `DELETED <id>` instruction through `main`; a mis-parse or hallucinated target could delete the wrong agent. Mitigation in-scope: deterministic envelope + machine-checkable done line + op-id/idempotency key + out-of-band typed confirmation before send + poll-verified absence. Open: `main` self-reports done via a text line the phone trusts — a true op-id acknowledged by the gateway (C9) would beat string-matching `CREATED/DELETED <id>`.
- **Poll ceiling vs. reality (now an M5 deliverable, not just a risk).** 120s → `.pending` is a guess; a slow provision leaves an ambiguous "may still be working" state with no cancel. M5 commits the re-poll/refresh affordance (acceptance-tested) and a live-timing calibration pass to close the user-facing gap.
