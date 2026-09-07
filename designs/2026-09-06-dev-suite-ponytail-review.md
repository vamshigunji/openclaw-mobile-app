# Ponytail review — dev-suite design + loop (2026-09-06)

Scope: over-engineering only. Reviewed `designs/2026-09-06-dev-suite-design.md` (234 lines, "spec") and
`designs/2026-09-06-dev-suite-loop.md` (222 lines, "loop") as drafted. Line numbers refer to the drafts;
**every finding below was applied** to the committed versions unless marked *kept*.

## Findings

- `spec:L130-133 + L57-60`, `loop:L139-142, L211-213`: yagni: three progressive features (slash picker, attach-from-workspace, artifacts) each with its own picker UI, gated on methods nobody has probed. One "later" line in Non-goals; add one when a user asks.
- `spec:L23, L60, L175`, `loop:L140, L183, L122`: yagni: `projects.list` (gateway ≥ 2026.8) lane-name upgrade. Last path component of `repoRoot` is the lane name; nothing else.
- `spec:L70-75`: delete: `bgRaised`, `hover`, `accentHover` tokens. iOS has no hover; pressed state is the native button style; grouped lists sit on `bg`. Three tokens gone.
- `spec:L103`, `loop:L40, L151`: delete: `0x22C55E`-outside-Theme grep. Already implied by "no `Color(hex:` outside Theme.swift".
- `spec:L110`: delete: "up to 4" photo cap. `AttachmentBudget`'s payload check is the real limit.
- `spec:L112`: shrink: three-step JPEG quality ladder (0.8 → 0.6 → 0.4). One re-encode at 2048 px / 0.8 (≈1–2 MB, far under the 6 MB cap); still over → reject.
- `spec:L113`: yagni: "inline as fence / attach instead" toggle for text files. Text ≤ 64 KB inlines, larger attaches. No toggle.
- `spec:L146-158`: stdlib: `Board = [ProjectLane: [BoardColumn: [BoardCard]]]` nested dictionaries. `[BoardCard]` with computed `column`/`lane`; group at render with `Dictionary(grouping:by:)`.
- `spec:L151, L181`: delete: `model` and `estimatedCostUsd` on a Kanban card. Not progress. Nothing replaces them.
- `spec:L170`: yagni: "Show main threads" toggle. Main threads live in the Agents tab; hide them, no setting.
- `spec:L178`, `loop:L185`: shrink: two-level lane order plus pinned → running → activity card order. One comparator: most recent activity; running cards already have their own column.
- `spec:L187`: yagni: "Start" sheet with extra instructions. Start sends the card title; the thread opens for follow-ups.
- `spec:L190, L206`, `loop:L197`: yagni: lane move = `sessions.patch {category}` + list→append→`sessions.groups.put`. Patch only; the gateway registers new categories on create, and patch is probed live — if it rejects unknown categories, that is a STOP-AND-ASK, not pre-built machinery.
- `spec:L191`, `loop:L201`: yagni: Pin/Unpin and Rename in the card menu. Nobody asked; two actions and one test gone.
- `spec:L192`: shrink: New-task sheet with description + "start now" toggle. Title · agent · lane → `sessions.create {agentId,label,category}`; card lands in Backlog; drag to start.
- `spec:L216`, `loop:L200`: shrink: two abort RPCs (`chat.abort` in chat, `sessions.abort` on the board). `chat.abort {sessionKey, agentId}` for both; one `SyncSource` method.
- `spec:L218`: shrink: four sub-folders under `Features/Chat/` for ~6 files. Flat files: `Attachments.swift`, `SpeechDictation.swift`, `MessageSegmenter.swift`, `CodeBlockView.swift`, `ToolTimeline.swift`.
- `loop:L76, L215`: delete: `N ≥ BASELINE_TESTS + 40` floor. Invites padding; the named tests are the floor.
- `loop:L80-83`: shrink: DONE restates every checklist test. DONE = final full run green, every non-`[H]` item ticked, C3/C4 empty, screenshots read.
- `loop:L138`: delete: `sessions.groups.list` probe. Lanes come from row fields.
- `loop:L143`: delete: attachment *echo* capture. MockGateway already carries the live echo shape; inbound media is a non-goal.
- `loop:L167, L53`: delete: separate `chat-code` screenshot. The demo canned reply gains a fence in P2.7, so `chat` covers it.
- `loop:L171`: shrink: `AttachmentPolicyTests` as its own file. One assertion inside `AttachmentBudgetTests`.
- `loop:L186`: delete: `testCardTitleFallback`. A `??` chain is a one-liner; YAGNI applies to tests too.
- `loop:L203`: delete: `P5.10` duplicates `P4.8` (`sessions.changed` moves a card).
- `loop:L205`: delete: `testDemoWritesAreInMemoryOnly`. `DemoSyncSource` has no connection by construction; the compiler proves it.
- `loop:L162`: shrink: `EventData.args: [String: JSONValue]` needs a new JSON enum. Decode only string-valued args (`[String: String]`, lenient); that is all the summary reads. `// ponytail:` note added.
- *kept*: `loop:L151` red-proof for grep tests, `spec:L124-126` six-key tool summary rule, `spec:§4.3` dictation reducer, `spec:§2` ground-truth tables — each is the minimum check or evidence, not bloat.

net: -28 lines applied (spec 234 → 223, loop 222 → 205); the remaining length is evidence tables and the checklist, which stay. Two features (progressive extras phase, groups registration) and nine tests/items were removed outright, so the code the loop will produce shrinks far more than the docs did.

## Outside ponytail scope — correctness fixes applied to the loop at the same time
- `loop:L44` C4 `URLSession` grep would fail at baseline: `SettingsView.swift` already calls `URLSession` for the health probe. Excluded that pre-existing file.
- `loop:L46` C4 `dependencies:` grep prints the test target's own `dependencies:` line at baseline. Check `packages:` only (that is where SPM deps appear).
- `loop:L59, L113` `sleep 4` is blocked in this harness. Screenshot is taken in a separate tool call after launch returns a PID; retry once if the launch screen shows.
- `loop:L29, L54` session-specific scratch paths would not exist in the session that runs the loop. `${TMPDIR:-/tmp}/dev-suite/…`.
- `loop:L143` attachment probe targeted `agent:main:main` (pollutes the real main thread). Now sent to the throwaway `phase0-probe-2026-09-06` session created just before it, then archived.
- `loop:L65` `[H]` items must never block a phase gate. Made explicit.
