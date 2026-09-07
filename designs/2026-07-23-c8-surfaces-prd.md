# C8 — Surfaces (model A) PRD

> **STATUS: UNBUILT / ASPIRATIONAL.** No `Surfaces` module exists today. Chat is the only "surface" the app ships, and it lives in **C5**, not here. This PRD defines the *target* and the *extension seam*; every type below is proposed, none is built. Do not read green into any of it.

## 1. Summary

C8 is the home for **native, specialized read-mostly views** — a Kanban board, a Code Reviewer, a Files browser — each rendered in SwiftUI over **RPCs the gateway already exposes** (`agents.files.*`, `cron.list`, `chat.history`, the `agent`/`session.tool` event streams) with writes routed through **approach B**. This is **model A**: OpenClaw ships each surface as first-party Swift; there is **no agent-defined render runtime and no third-party surface store** (that would be model B — explicitly out of scope). It is a separate team because a surface is a self-contained vertical slice that touches no other feature's source: it consumes only the **C0 contract** (DTOs plus the `SyncSource` / `OpCommandSending` protocols) and the C3 design tokens, so one agent can add a whole new surface in a worktree without coordinating with Chat, Agents, or Settings. The unit of parallelism is "one surface = one file conforming to `Surface` + one line in a static registry."

## 2. Scope

**In scope**
- The `Surface` protocol + `SurfaceContext` (the render seam) + `SurfaceRegistry` (a **compile-time static list of C8-owned builtIn surfaces**, not a runtime plugin store).
- A `SurfacePickerView` whose surface list is **`SurfaceRegistry.builtIn` merged with an injected `[any Surface]`** (the injection point is how a non-C8 conformer — e.g. Chat — reaches the picker without C8 importing it; see §3 and blocking-issue reconciliation below), then filtered by `isAvailable(for: agent)`.
- First-party surfaces built entirely inside C8 over existing RPCs: **Files** (over `agents.files.list`/`.get`), **Kanban** (over `cron.list` or a tasks file via `agents.files.get`), **Code Reviewer** (over `agent` `stream:"patch"` events + `agents.files.get`).
- Surface writes via **approach B only**, through the C0-declared `OpCommandSending` protocol (never a direct `chat.send` call from C8).

**Out of scope**
- Any **new RPC or wire shape** — owned by **C0** (contract) and **C9** (new gateway daemons). Model A's whole premise is "no new server surface."
- The **transport / socket / reconnect** — owned by **C1**; C8 never links C1 at all. It only calls the `SyncSource`/`OpCommandSending` *protocols* (C0), whose concrete C1 impls are injected at the **C10** app root.
- **Chat** as a surface conformer — the thread view is owned by **C5**; it is adapted to `Surface` at the app composition root (**C10**) and *injected* into the picker, not built inside C8 (see §3).
- **Create/edit/delete agents + `MainAgentTask`** — owned by **C6**. A surface that needs a privileged write uses C0's `OpCommandSending`, never imports C6.
- **Pairing / gateway config** — owned by **C7**.
- **Wiring the picker into navigation + injecting the concrete `SyncSource`/`OpCommandSending`/Chat-surface** — owned by **C10** (the composition root).
- An **agent-defined render runtime** or a **downloadable surface marketplace** (model B) — out of scope by charter; if ever built it is a new chunk, not C8.

## 3. Interface (the stable contract)

**Exposes** (defined in the C8 `Surfaces` module):

```swift
/// A first-party specialized view over existing gateway RPCs. Self-contained:
/// everything it needs arrives in SurfaceContext — no globals, no sibling imports.
protocol Surface: Identifiable, Sendable {
    var id: String { get }           // stable slug, e.g. "kanban" — unique across the picker
    var title: String { get }
    var systemImage: String { get }  // SF Symbol; DesignSystem (C3) styles the chrome
    /// Whether this surface applies to a given agent (e.g. only agents with a tasks file).
    func isAvailable(for agent: AgentSummary) -> Bool
    @MainActor func makeView(context: SurfaceContext) -> AnyView
}

@MainActor
struct SurfaceContext {
    let agent: AgentSummary          // C0 model
    let sync: any SyncSource         // C0-declared read path (C1 impl injected at C10)
    let ops: any OpCommandSending    // C0-declared approach-B write path (C1 impl injected at C10)
}

/// Model A: a plain compile-time list of C8's OWN builtIn surfaces.
/// NOT a runtime registration store. New C8 surface == new conformer file + one line here.
enum SurfaceRegistry {
    static let builtIn: [any Surface] = [ /* FilesSurface, KanbanSurface, ReviewerSurface, … */ ]
}

/// The picker's surface list is builtIn PLUS an injected extra list. This is the seam that
/// lets a conformer C8 cannot see — Chat, adapted to `Surface` at the C10 root — appear in the
/// picker without C8 importing C5. The registry stays static; the PICKER SOURCE is injectable.
struct SurfacePickerView: View {
    let agent: AgentSummary
    let context: SurfaceContext
    let extra: [any Surface]         // injected at C10 (default []); merged with SurfaceRegistry.builtIn
    // body lists (SurfaceRegistry.builtIn + extra).filter { $0.isAvailable(for: agent) }, routes on tap
}
```

**Reconciliation of the M4 contradiction (blocking issue 1).** A static list C8 populates cannot contain a conformer C8 cannot import. So the registry does *not* need to hold Chat. `SurfaceRegistry.builtIn` holds only C8's own surfaces; `SurfacePickerView` takes an **injected `extra: [any Surface]`** and displays `builtIn + extra`. At the C10 root, C5's `ChatView` is wrapped in a tiny `Surface` conformer and passed as `extra`. Chat therefore appears in the picker exactly as specified in M4, and C8 still never imports C5. Both facts now hold simultaneously; the earlier draft's "picker lists exactly `SurfaceRegistry.available(for:)`" wording is replaced by this injectable source.

**Consumes** (only via C0 or C0-declared protocols):
- `SyncSource` (C0 protocol) for all reads — roster, history, instructions, event/activity streams.
- `OpCommandSending` — **C0 protocol** wrapping the approach-B `openclaw-op` envelope send (`designs/2026-07-23-api-contract-design.md §4.2`), so C8 never calls `chat.send` itself. If this protocol doesn't yet exist in C0, C8 blocks on C0 adding it.
- C0 DTOs: `AgentSummary`, `ChatMessage`, `GatewayDTOs`, event shapes.
- C3 `Theme` + shared components for all chrome (4pt radius, 1px borders, terminal-green accent — no inline values).

## 4. Dependencies

Allowed edges: **C8 → C0 (contract: DTOs + `SyncSource`/`OpCommandSending` protocols), C8 → C3 (DesignSystem).** Nothing else — **not even C1 (Transport)**. The concrete `SyncSource`/`OpCommandSending` implementations are C1 types, but C8 only ever names the C0 *protocols*; C10 constructs the C1 impls and injects them into `SurfaceContext`. Approach-B writes are a C0 protocol edge (`OpCommandSending`), not a C6 import.

**Module-import rule (enforced by C10's package graph):** the `Surfaces` SPM target declares `.dependencies = [Contract, DesignSystem]` and *nothing* else — **no `Transport` (C5-visible concrete types), no `Chat`, no `Agents`**. Because those targets are absent from the dependency list, `import Transport`, `import Chat`, or `import Agents` inside C8 is an **unresolved-module compile error** — the wall is the package graph, not a lint. Dropping Transport (vs. the draft that linked it "to receive an injected `SyncSource`") is deliberate: injection happens through C0 protocol *types*, so C8 needs zero visibility into concrete transport, which is the isolation this PRD argues for. A surface that "needs" chat data reads it through `SyncSource.loadHistory`; a surface that "needs" to mutate an agent sends an op through `OpCommandSending` — both C0 seams, neither a sibling.

## 5. Milestones / build order

**Buildable in a lone worktree with zero cross-team gating** (Contract stubs + mock gateway + golden JSON are all C8 needs):

1. **M1 — the seam.** Define `Surface`, `SurfaceContext`, `SurfaceRegistry`, `SurfacePickerView` (with its injectable `extra`). Ship one trivial read-only conformer — **FilesSurface** over `agents.files.list`/`.get` — to prove the seam end-to-end against the mock gateway. Deliverable: an agent shows a "Files" surface that lists and opens text files. *Gating: none beyond C0 exposing `SyncSource` + the file DTOs, which already exist (`agents.files.*` is [EXISTING], contract §2.6).*
2. **M2 — Kanban (read-only).** `KanbanSurface` over `cron.list` (or a tasks file via `agents.files.get`), parsed into a board model, rendered as columns/cards. Golden-JSON-tested on the parse. No writes. *Gating: none — read-only over [EXISTING] RPCs.*

**Gated on other chunks** (cannot fully land in isolation):

3. **M3 — Code Reviewer + first approach-B write.** `ReviewerSurface` reads `agent` `stream:"patch"` events + file contents (read half is ungated); adds a write action ("comment"/"request change") through `OpCommandSending`. **Blocks on two C0/C9 items, not just "the protocol existing":** (a) C0 declaring the `OpCommandSending` protocol, and (b) C0 adding a **review-comment op `kind`** to the `openclaw-op` envelope — the §4.2 enum today is only `agents.create | agents.update | agents.delete | agents.files.set`, which has **no backing kind** for a comment/request-change write — *plus* C9/`main` honoring that new kind. Ship the read-only half against the mock gateway now; land the write when C0+C9 deliver.
4. **M4 — wire into navigation.** *This milestone is owned/completed at the **C10** root, using C8's seam.* C10 mounts `SurfacePickerView` on the agent thread, injects the concrete C1 `SyncSource`/`OpCommandSending`, and passes C5's `ChatView`-as-`Surface` as the picker's `extra`. **Blocks on C10 (graph + injection) and C5 (a `Surface` conformer wrapping `ChatView`).** C8's contribution here is only the injectable picker from M1 — no new C8 code is required for Chat to appear.

## 6. Acceptance criteria

- **Picker source merge:** given a golden `agents.list` agent and an injected `extra` list, `SurfacePickerView`'s displayed set equals `(SurfaceRegistry.builtIn + extra).filter { $0.isAvailable(for: agent) }` — assert on a fixture agent with/without a tasks file, and assert an injected fake surface appears (proves the Chat-injection seam).
- **Deterministic parse:** `KanbanSurface`'s board model, fed a captured golden `cron.list` (or tasks-file) JSON, produces the expected columns/cards — a value-level `assert`, no snapshot flakiness.
- **Unique ids (testable half of the isolated-add proof):** a test asserts every id across `SurfaceRegistry.builtIn` (and, in the picker, `builtIn + extra`) is unique. *(The "adding a conformer costs only a new file + one registry line" property is a **design note in §7**, not a runtime assertion — a test cannot observe file counts.)*
- **No back-channel writes:** an architecture test / grep asserts the C8 target contains **zero** `chat.send` / socket calls — every write goes through `OpCommandSending`.
- **Wall holds:** a C10 graph test confirms adding `import Chat`, `import Agents`, or `import Transport` to C8 fails to compile.
- **Read-only against mock gateway:** each surface renders from `DemoSyncSource`-style canned JSON with no host configured (preserve the demo path).

## 7. Isolation proof

An agent in a fresh git worktree builds C8 from this PRD alone: it imports **`Contract` (C0)** for `AgentSummary`/DTOs and the `SyncSource`/`OpCommandSending` protocols, and **`DesignSystem` (C3)** for chrome — and nothing else, not even Transport. Every surface reads through `SyncSource` and writes through `OpCommandSending` (both C0 protocol seams), so no C1/C5/C6/C7 source is ever opened, and the mock gateway plus golden JSON exercise the whole slice offline. Because concrete impls arrive only as injected protocol values in `SurfaceContext`, C8 compiles against C0 stubs with no live transport. The one cross-module seam (Chat-as-surface) is deliberately pushed **out** of C8 to the C10 root and reaches the picker through the injected `extra` list, so C8 itself stays a leaf that only C10's graph wires in. The package graph (`.dependencies = [Contract, DesignSystem]`) makes any accidental sibling or transport import a build error, so isolation is mechanically guaranteed, not merely intended. **Design note (the untestable half of "isolated add"):** by construction, adding a new C8 surface is one new conformer file plus one line in `SurfaceRegistry.builtIn`, editing no other surface — a property of the seam's shape, asserted here rather than by a runtime test.

## 8. Status & risks

**Current state: unbuilt.** The `Surfaces` module, the `Surface` protocol, the registry, the injectable picker, and every listed surface do not exist. Chat is the only specialized view today and it lives in C5. `OpCommandSending` is a *proposed* C0 protocol, and the approach-B `openclaw-op` envelope (`designs/2026-07-23-api-contract-design.md §4.2`) is itself unbuilt/unverified.

**What's shippable in isolation vs. gated:** M1 (seam + FilesSurface) and M2 (read-only Kanban) land in a lone worktree against the mock gateway with zero cross-team coordination. M3's write half is gated on C0 (`OpCommandSending` + a new review-comment op kind) and C9/`main`; M4 is owned at the C10 root and gated on C10 (graph + injection) and C5 (Chat-as-`Surface`). The read halves of M3 are ungated and can ship alongside M1/M2.

**Open questions / risks:**
- **Which existing RPC actually backs each surface is unproven.** Kanban-over-`cron.list` and Reviewer-over-`agent` patch events are asserted, not verified — cron-orchestrated sub-agents are invisible to `agents.list` (contract §2.8), so the tasks-file route may be the only real option.
- **Read-only usefulness ceiling.** Model A surfaces without a render runtime may be too rigid to be worth the build; validate one surface (Files) end-to-end before committing to more.
- **M3 blocks on a contract addition, not just an implementation.** There is no `openclaw-op` kind for a review comment/request-change today; C0 must add one (and C9/`main` must honor it) before the Reviewer's write action can exist.
- **`AnyView` erasure** in `makeView` costs some SwiftUI diffing efficiency; acceptable for a picker-gated surface, revisit only if a surface measurably janks.
- **Chat-as-surface adaptation** is the single cross-module seam; it now lives entirely at the C10 root as an injected `extra` conformer. If that wrapper can't cleanly satisfy `Surface`, the "chat is just another surface" framing weakens and Chat stays special-cased in C5 — but C8's contract is unaffected because it never referenced Chat.
