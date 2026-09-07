# C3 — Design System PRD

## 1. Summary

C3 is the visual vocabulary of OpenClaw Mobile: one file, `Sources/DesignSystem/Theme.swift` (162 lines), exposing the `Theme` token namespace plus a handful of shared SwiftUI components (`MonoField`, `PrimaryButton`, `ActivityLine`, `StatusBadge`) and the `AgentStatus` enum. It is a separate team/chunk because it is almost entirely leaf code — it consumes only Foundation + SwiftUI — and centralizing color, radius, border, and type here is what makes "any inline color or radius in a consumer is a review failure" a mechanically checkable rule: there is exactly one place those values are allowed to live. It is the most parallelizable chunk in the plan with **one caveat**: today `ActivityLine` still references the C0-owned `AgentActivity` type (Theme.swift:120), so C3 is *nearly* isolated, not *fully* isolated. Closing that gap is one coordinated C3+C5 edit (§8).

## 2. Scope

**In scope**
- The `Theme` enum: background/text/accent/bubble colors, `radius` (4), `border` (1), `borderColor`. Dark-mode only.
- `Color(hex:)` convenience initializer (the one sanctioned way to name a color).
- Shared components: `MonoField` (the app's one labeled monospaced text input, plain + `secure`), `PrimaryButton` (solid accent CTA + `secondary` outlined + `disabled`), `ActivityLine` (pulsing dot + verb label), `StatusBadge` (color-coded status chip).
- `AgentStatus` enum + its `color`/`label` mapping (the canonical status→color source of truth).
- SwiftUI `#Preview`s so the whole system renders in Xcode canvas.
- The planned migration of `ActivityLine`'s parameter from `AgentActivity` to a plain `label: String?` — the C3 half of a coordinated C3+C5 change (see §8).

**Out of scope**
- The activity verb mapping and the `AgentActivity` type itself (`AgentActivity.from(event:)` → "Searching the web"…, plus its computed `var label: String?`) — owned by **C0 (Protocol/Contract)**, defined at `Sources/Models/AgentActivity.swift`.
- The `activity.label` extraction and the `ActivityLine(...)` call site — the **sole** caller is `ChatView.swift:37` (the chat header), owned by **C5 (Chat)**. The signature migration in §8 requires C5 to update this call site; it is not a C3-only edit.
- Any screen or navigation (roster, chat thread, settings, tab bar) — owned by **C5 / C6 (Agents) / C7 (Settings) / C8 (Surfaces)**.
- Message bubble layout/streaming — **C5 (Chat)**.
- Light mode, theming preferences, user-selectable accent — deferred; dark-only is a product constraint.
- App icon / launch screen assets — **C10 (Platform/DevEx)** via `project.yml`.
- The repo-wide inline-color/inline-radius lint gate — **C10 (Platform/DevEx)** owns and enforces it; C3 only provides the single sanctioned home the gate points at.

## 3. Interface (the stable contract)

**Exposes** (all in the app target's `DesignSystem` namespace; no separate module today):

```swift
enum Theme {
    static let bgPrimary, bgSecondary: Color
    static let accent: Color                 // #22C55E
    static let textPrimary, textSecondary: Color
    static let userBubble, agentBubble: Color
    static let radius: CGFloat               // 4
    static let border: CGFloat               // 1
    static let borderColor: Color
}

extension Color { init(hex: UInt32) }

enum AgentStatus: String, Codable, CaseIterable {
    var color: Color; var label: String
}

struct MonoField: View     { let label: String; var placeholder: String; var secure: Bool; @Binding var text: String }
struct PrimaryButton: View { let title: String; var secondary: Bool; var disabled: Bool; let action: () -> Void }
struct StatusBadge: View   { let status: AgentStatus }
```

**`ActivityLine` — current signature vs. target signature.** This one component is mid-migration, so both are stated explicitly:

```swift
// CURRENT (shipped, Theme.swift:120) — consumes the C0-owned AgentActivity type:
struct ActivityLine: View { let activity: AgentActivity }   // renders activity.label; nil → "Idle"

// TARGET (planned, §8) — plain optional verb, zero cross-chunk types:
struct ActivityLine: View { let label: String? }            // nil → "Idle"
```

**Consumes**: today, exactly one cross-chunk type — `AgentActivity` (C0), via `ActivityLine`. Every other C3 type references only SwiftUI or Foundation. After the §8 migration lands, C3 consumes **nothing** cross-chunk. Until then, treat the `AgentActivity` reference as the single known coupling, not zero.

## 4. Dependencies

Allowed: **C0 only, and only until the §8 migration lands** (for `AgentActivity`, used by `ActivityLine`). No C1, no C2, no sibling feature. Target end state after §8: **none** — SwiftUI + Foundation only.

Module-import rule (enforced by C10's graph): the DesignSystem sources may `import SwiftUI` / `import Foundation` and nothing from `Services/` or `Features/`. The `Models/AgentActivity.swift` (C0) reference is the sole permitted-today exception, tracked for removal in §8. Because the app is a single target, C10 enforces this as a lint/review gate (no `import`-level firewall exists intra-target); the moment DesignSystem is promoted to its own SPM module, an `import` of any Service/Feature symbol — or of `Models/` once the §8 edit lands — becomes a compile error. The inverse rule — a consumer writing `Color(hex:...)` or `cornerRadius(8)` inline — is a **C10-owned** review/lint gate that this chunk's existence makes checkable.

## 5. Milestones / build order

1. **Tokens** — `Theme` enum + `Color(hex:)` + `AgentStatus`. Compiles, previewable as a swatch sheet. **(Done, shipped.)**
2. **Form primitives** — `MonoField` (+ secure), `PrimaryButton` (+ secondary/disabled). **(Done, shipped.)**
3. **Live indicators** — `ActivityLine`, `StatusBadge`. **(Done, shipped — but `ActivityLine` still takes `AgentActivity`; see M5.)**
4. **Test file + preview gallery** — add `OpenClawMobileTests/DesignSystemTests.swift` (§6: radius/border/hex golden/status table) plus one `#Preview` stacking every component, doubling as the visual regression snapshot target. **(Unbuilt.)**
5. **Decouple `ActivityLine`** — the coordinated C3+C5 change: C3 flips the parameter to `label: String?`; C5 updates `ChatView.swift:37` to pass `vm.activity.label`. This is the one edit that takes C3 from "nearly isolated" to "zero cross-chunk coupling." **(Unbuilt; requires C5 sign-off.)**

## 6. Acceptance criteria

Add one test file, `OpenClawMobileTests/DesignSystemTests.swift`, asserting:

- `Theme.radius == 4` and `Theme.border == 1`; `Theme.accent == Color(hex: 0x22C55E)`.
- `Color(hex: 0x22C55E)` golden-vector: resolves to sRGB (r, g, b) = (**0.133, 0.773, 0.369**) ±1/255, i.e. (34, 197, 94)/255. Pins the hex decoder. (0x22=34, 0xC5=197, 0x5E=94.)
- `AgentStatus.allCases` each return a distinct non-nil color and a non-empty label; `working` maps to `accent`. Table-driven.
- No SwiftUI `.shadow(` anywhere in `Theme.swift` (grep gate — elevation is 1px borders only).

Plus (verified in Xcode canvas, no test target):
- Every component has a `#Preview` and renders with the scheme's dark appearance, no gateway/network.

**C10 acceptance criterion (not C3's to make pass alone):** a repo-wide review/lint check — zero `cornerRadius(` with a literal ≠ `Theme.radius`, zero `Color(hex:` outside `Theme.swift`, in any consumer chunk. C3 supplies the single sanctioned location; C10 supplies and runs the gate.

## 7. Isolation proof (with the one honest caveat)

An agent in a fresh git worktree can open `Theme.swift` and build + preview `Theme`, `Color(hex:)`, `AgentStatus`, `MonoField`, `PrimaryButton`, and `StatusBadge` with no gateway, no `Services/`, no sibling feature file, and no network. **The one exception is `ActivityLine`**, which today references `AgentActivity` (Theme.swift:120) — so a truly fresh worktree needs the C0 model file `Sources/Models/AgentActivity.swift` present (or a one-line stub) for the file to compile as-is. That is the single, known coupling. Once the §8 migration lands (`ActivityLine` takes `label: String?`, C5 passes `vm.activity.label`), C3 references zero cross-chunk types and the "one file, no siblings, no C0 stub" claim becomes literally true. **Until §8 lands, this section and §4 are aspirational for exactly one component; everything else in C3 is isolated today.**

## 8. Status & risks

**Status: LIVE except tests, with one decoupling edit outstanding.** `Sources/DesignSystem/Theme.swift` ships all listed types and is in production use by the single-target app. Two items remain:

- **Coordinated C3+C5 edit (concrete diff):**
  - `Theme.swift:120` — `struct ActivityLine: View { let activity: AgentActivity }` → `{ let label: String? }`, and the body reads `label` directly instead of `activity.label`.
  - `ChatView.swift:37` (**owned by C5, Chat**) — `ActivityLine(activity: vm.activity)` → `ActivityLine(label: vm.activity.label)`.
  - This is the sole cross-chunk reference in C3. Removing it is the ONE change that flips this chunk from "nearly isolated" to "truly zero-coupling"; it cannot be done by C3 alone because it changes a C5 call site. Until it lands, §4 and §7 are aspirational for `ActivityLine`.

**Risks / open questions**
- **`DesignSystemTests.swift` does not exist yet** (§6 tests are specified but unwritten) — cheap, ~1 file. Writing it as part of this chunk is the cheapest way to close this gap; it is also what would have caught a golden-vector channel slip in an earlier draft. Highest-value unbuilt item.
- The inline-color review gate is currently human review, not automated, and is **C10's** to land (grep-based CI is the lazy version). Until then the "review failure" rule is convention, not enforcement — enforcement gap is C10's, not C3's.
- Single-target means "wrong import = compile error" is aspirational until DesignSystem becomes its own SPM module; today it's review + C10 graph lint. Not blocking given dark-mode-only, one-file scope, and (post-§8) zero cross-chunk types.
