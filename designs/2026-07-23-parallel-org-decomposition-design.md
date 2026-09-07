# Parallel Org Decomposition — OpenClaw Mobile (Approach A)

**Date:** 2026-07-23
**Purpose:** Cut the whole product into chunks that separate organizations/teams
(human squads OR autonomous agents in worktrees) can build **in parallel** without
colliding. This is a *Conway's-law* cut (minimize cross-team coordination), not the
blast-radius cut in `2026-07-23-superapp-system-architecture.md` (S1–S10). The two
deliberately differ.

**Chosen approach:** **A — Contract-centric hub-and-spoke.** One Contract chunk at the
center; every other chunk depends **only on the Contract**, never on a sibling. The
rule is enforced *mechanically* — each chunk is its own Swift module (local SwiftPM
package or XcodeGen sub-target), and the build **fails** if one feature imports a
sibling feature. The compile-time wall is what makes "parallel" real rather than a
promise.

---

## 0. Load-bearing facts (inherited)

- **F0.1 — Origin is always the client.** Every flow originates on the phone; the only
  server→client traffic is the event stream on a client-opened subscription.
- **F0.2 — The Mac Mini is one owned box.** Gateway + storage + agent runtime are the
  same machine we own.
- **F0.3 — Phone holds only `operator.read` + `operator.write`.** Admin ops go through
  the `main` agent ("approach B"). *(Asserted, not proven — verify with `rpc-probe.mjs`.)*

These constrain the chunks but do not change the cut.

---

## 1. The cut — 11 chunks in 4 orgs

| Org | Chunk (team) | Status |
|---|---|---|
| **Contract & Build** | `C0` Protocol/Contract *(keystone)* | amber (extract) |
|  | `C10` Platform / DevEx | live |
| **Client Infra** (split spine) | `C1` Transport | live |
|  | `C2` Auth / DeviceTrust | live |
|  | `C3` Design System | live |
|  | `C4` Local Store | partial |
| **Client Features** (vertical slices) | `C5` Chat | live |
|  | `C6` Agents / Roster + approach-B | live |
|  | `C7` Settings / Onboarding | live |
|  | `C8` Surfaces ("app store", model A) | unbuilt |
| **Gateway** (Mac Mini) | `C9` Daemons — push / upload / fan-out | unbuilt |

### The one rule (mechanically enforced)

```
C0 (Contract) ← everyone
Spine (C1–C4) depends only on C0 (and declared protocols)
Features (C5–C8) depend only on C0 + spine protocols — NEVER on a sibling feature
Gateway (C9) depends only on C0 (new RPC shapes)
C10 owns the module graph that makes the above a compile error to violate
```

**Circular-dep resolution (C1 ↔ C2):** Transport carries the signed `connect`; Auth
signs it. Break the cycle in C0: it defines a `ConnectSigner` protocol. C2 implements
it, C1 depends on the *protocol* only. No concrete cross-import.

**Secret-storage edge (C2 needs C4):** resolved by the *same* pattern. C0 defines a
`SecretStore` protocol; C4 implements it, C2 depends on the *protocol* only. So the
spine stays sibling-edge-free: **C2 → C0 only** (was "C2 → C0 + C4"), with C4's
`SecretStore` implementation injected at the app composition root. This makes both
cross-spine needs — signing and secret storage — protocol edges through C0, not
concrete module imports. C10 encodes and enforces this refined edge set.

---

## 2. Per-chunk contract

Each chunk's PRD must pin: **responsibility · exposes (stable interface) · consumes
(only via C0/protocols) · depends on · acceptance · module-wall proof · status.**

- **C0 · Protocol/Contract (keystone).** Owns the wire truth: DTOs (`GatewayDTOs`,
  `GatewayFrames`), RPC method signatures, event shapes, the scope table, idempotency
  rules, the `GatewayError` taxonomy, and a **golden-JSON corpus** captured from the
  live gateway. Exposes: Swift types + protocols (`SyncSource`, `ConnectSigner`) +
  golden fixtures (`SyncSource`, `ConnectSigner`, **`SecretStore`**). Consumes: nothing.
  Every chunk compiles against it. Changing C0 is the *only* cross-team coordination event.

- **C1 · Transport.** One WS socket; `req|res|event` framing; request/response
  correlation; idempotency keys; reconnect w/ backoff + auto-resubscribe; event
  fan-out. Exposes: `SyncSource` impl (`GatewayWSSyncSource` → `GatewayConnection`
  actor). Consumes: C0 types, `ConnectSigner`. Invariant: one shared connection, never
  a socket per screen.

- **C2 · Auth / DeviceTrust.** Ed25519 keypair, pairing state machine, v3 signature
  payload, scoped token lifecycle, Keychain secrets. Exposes: `ConnectSigner`,
  `PairingFlow`. Consumes: **C0 only** — its secret-storage need is satisfied by C0's
  `SecretStore` protocol (implemented by C4, injected at the app root), never a
  concrete C4 import.

- **C3 · Design System.** Tokens + shared components (`MonoField`, `PrimaryButton`,
  `ActivityLine`); dark-only, 4pt radius, 1px borders. Exposes: `Theme` + components.
  Consumes: nothing. Any inline color/radius is a review failure.

- **C4 · Local Store.** Keychain wrapper, UserDefaults prefs (host, stars, mutes,
  last-read), on-disk conversation JSON cache, drafts, bookmarks. Exposes: repository
  types per concern + the `SecretStore` implementation (C0 protocol). Consumes: C0
  (message types). Note: conversation cache is largely
  TODO today (history backfills live).

- **C5 · Chat.** Per-agent thread; optimistic send; streaming assembly; self-echo
  dedup; history backfill; activity indicator (real signals only); STT; file-DOWN.
  Exposes: `ChatView`. Consumes: C0, C1 (`SyncSource`), C4, C3. Never imports C6.

- **C6 · Agents / Roster + approach-B.** `agents.list` roster, status/activity,
  create/edit/delete/profile via `MainAgentTask` (instruct `main`, poll to confirm).
  Exposes: `AgentsView`. Consumes: C0, C1, C3. Never imports C5.

- **C7 · Settings / Onboarding.** Pairing UI (QR + paste), gateway config. Exposes:
  `SettingsView`. Consumes: C0, C2 (`PairingFlow`), C3.

- **C8 · Surfaces (model A, unbuilt).** Native specialized views (Kanban, Reviewer…)
  over RPCs the gateway already exposes. Exposes: `Surface` protocol + registry.
  Consumes: C0, C1, read-only feature data. PRD defines the *target*, not existing code.

- **C9 · Gateway Daemons (Mac Mini, unbuilt).** APNs push notifier (the only way to
  reach a backgrounded phone), upload intake (file-UP), cross-device fan-out. Exposes:
  new RPCs added to C0. Consumes: C0. PRD defines daemons on a box we own — not a new
  cloud tier.

- **C10 · Platform / DevEx.** `project.yml` (XcodeGen), CI, `tools/*.mjs` probes, QA
  hooks, and — new under Approach A — the **module dependency graph** that makes the
  §1 rule a build error. Exposes: the build/release loop + boundary enforcement.
  Consumes: cross-cutting.

---

## 3. How each chunk becomes a PRD (the swarm)

One **writer agent per chunk** drafts that chunk's PRD from this doc. Each draft goes to
a dedicated **reviewer agent** scoring against a fixed rubric; writer revises; loop until
the reviewer is satisfied or a **3-round cap** is hit. Output: `designs/2026-07-23-<chunk>-prd.md`.

**Reviewer rubric (all must pass for `satisfied`):**
1. Scope crisp and non-overlapping with sibling chunks.
2. Interface stated as a *stable contract* (types/protocols), not an implementation.
3. Dependencies flow only through C0 / declared protocols — no sibling-internal imports.
4. Acceptance criteria are testable (ideally against golden JSON / mock gateway).
5. Isolation: one agent could build this alone in a worktree from the PRD.
6. Honest status — unbuilt chunks (C8, C9) say so; no aspirational green.
