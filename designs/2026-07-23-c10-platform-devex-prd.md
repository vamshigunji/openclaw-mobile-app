# C10 — Platform / DevEx PRD

## 1. Summary

C10 owns the **build system, CI, release loop, gateway probe tooling, and — new under Approach A — the module dependency graph that turns §1's "no sibling imports" rule into a compile error.** It is a separate team because it is the *only* cross-cutting chunk: it touches every other chunk's package boundary without owning any chunk's logic. Concretely it owns `OpenClawMobile/project.yml` (XcodeGen, source of truth), `.github/workflows/ci.yml`, the zero-dep `tools/*.mjs` gateway probes, and the DEBUG QA hooks in `Sources/App/`. Its central deliverable is the **module graph**: one Swift module per chunk (C0–C8) with explicit, minimal dependency edges, so the mechanical wall — not a code-review promise — is what makes "11 teams in parallel" real. If C5 tries to `import FeatureAgents`, the build fails; that guarantee is this chunk's product.

## 2. Scope

**In scope**
- `project.yml` (XcodeGen spec) — the single source of truth for targets, module split, and per-target dependency edges. Regenerated to `.xcodeproj` via `xcodegen generate`.
- The **module graph itself**: one module per chunk (`OpenClawContract`=C0, `OpenClawTransport`=C1, `OpenClawAuth`=C2, `OpenClawDesign`=C3, `OpenClawStore`=C4, `FeatureChat`=C5, `FeatureAgents`=C6, `FeatureSettings`=C7, `FeatureSurfaces`=C8) plus the thin `OpenClawMobile` app target as composition root. C10 owns the **module node set** and the **prohibition** that no feature module may edge to a sibling feature module; the concrete list of *allowed* edges (§3) is a mutable baseline that grows by per-chunk additions. `FeatureSurfaces` (C8) is unbuilt today and lands as an **empty stub module** (a single empty Swift file) — C10 declares its node and its baseline edges so C8's team migrates source into it later; C10 never fills it.
- CI (`.github/workflows/ci.yml`): `xcodegen generate` → `xcodebuild test` on every PR (macos-15, sim UDID discovery, no code signing).
- A **boundary-lint CI job** that fails the build on any *prohibited* edge (a feature importing a sibling feature) — the mechanical §1 enforcement, and a fast named error ahead of the full build.
- The checked-in **`expected-edges.json` fixture** — the single source of truth the parsed-edges golden test and the negative-import test both read. When a chunk team adds a legal edge, they add it to `project.yml` *and* this fixture in the same PR; C10 reviews the fixture diff.
- Zero-dep gateway probes: `tools/phase0-verify.mjs`, `tools/rpc-probe.mjs`, `tools/list-agents.mjs`, `tools/phase0-roundtrip.mjs`, `tools/watch-wire.command`.
- DEBUG QA hooks: `--seed-demo` (+ `SEED_HOST`/`SEED_DEVICE_TOKEN`/`SEED_DEVICE_KEY`/`SEED_TEXT`), `--open-settings`, `--open-create`, `--open-profile <id>` — the launch-arg seams the simulator can't tap. C10 owns the **arg-string contract and its wiring in the app composition root**; the screens the args drive are owned by the feature chunks (C5/C6/C7).
- Release loop: `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` bump discipline, TestResults artifact upload, and the deferred `testflight` job stub (behind `if: false`).

**Out of scope**
- Any DTO, RPC signature, event shape, or protocol definition — owned by **C0 (Protocol/Contract)**. C10 declares the `OpenClawContract` *module* exists and everyone depends on it; it does not author its contents.
- The `ConnectSigner` / `SecretStore` / `SyncSource` protocol *definitions* — **C0** owns them; C10 only encodes the dependency edges that let C1/C2/C4 satisfy them without concrete cross-imports.
- App-launch composition wiring (which concrete `SecretStore` is injected into `PairingFlow`) beyond the DEBUG QA hook plumbing — the composition root's runtime behavior is shared with the feature chunks; C10 owns only the target/module structure and the DEBUG arg seams.
- The actual seed/auto-send/screen behavior the QA hooks trigger — that logic lives in **C2 (Auth)**, **C4 (Store)**, and **C5 (Chat/DemoSyncSource)**. C10 owns the arg parsing and the dispatch; the feature chunks own what happens after dispatch.
- The pairing flow's transport usage — **C2 (Auth)** owns `PairingFlow` and whether it drives `GatewayConnection` directly or only through a `ConnectSigner`/`SyncSource` seam. C10 records C7's declared edges as a baseline and confirms them against C2's and C7's PRDs (§3, §8).
- APNs entitlements, provisioning profiles, App Store Connect keys — deferred; the **C9 (Gateway Daemons)** push work gates the real TestFlight job.
- Any UI, transport, auth, or storage logic — C3–C7 respectively.

## 3. Interface (the stable contract)

C10 exposes **build-graph structure and developer entry points**, not Swift types. The contract has two tiers, and only the first is frozen.

**FROZEN (the real, stable contract — changing any of these is a breaking change requiring org sign-off):**
- **The module node names**: `OpenClawContract`, `OpenClawTransport`, `OpenClawAuth`, `OpenClawDesign`, `OpenClawStore`, `FeatureChat`, `FeatureAgents`, `FeatureSettings`, `FeatureSurfaces`, `OpenClawMobile`.
- **The prohibitions**: (a) no `Feature*` module may depend on another `Feature*` module; (b) no spine module (`OpenClawTransport`/`OpenClawAuth`/`OpenClawStore`/`OpenClawDesign`) may depend on a `Feature*` module; (c) `OpenClawContract` depends on nothing; (d) **no `OpenClawTransport`↔`OpenClawAuth` edge in either direction** — the C1↔C2 cycle is broken by the `ConnectSigner` protocol defined in C0, so both link only `OpenClawContract`. The *absence* of this one edge is load-bearing; the golden test asserts it explicitly.
- **The DEBUG launch-arg strings**: `--seed-demo`, `--open-settings`, `--open-create`, `--open-profile <id>`, and the `SEED_HOST`/`SEED_DEVICE_TOKEN`/`SEED_DEVICE_KEY`/`SEED_TEXT` env var names. The *strings* are frozen; the *effects* are implemented by the owning feature chunk.
- **The commands** a chunk team runs: `cd OpenClawMobile && xcodegen generate`; the `xcodebuild test` invocation; `node tools/<probe>.mjs <host> [token] [--pair <code>]`.

**BASELINE (initial allowed-edge list — mutable; grows by per-chunk additions within the frozen prohibitions):**
```
OpenClawContract     → (none)                    # frozen: keystone, depends on nothing
OpenClawTransport    → OpenClawContract          # NO edge to OpenClawAuth (C1↔C2 broken via ConnectSigner in C0)
OpenClawAuth         → OpenClawContract          # NO edge to OpenClawTransport (same break)
OpenClawDesign       → (none)                    # may add OpenClawContract if C0 declares shared tokens; confirm w/ C0
OpenClawStore        → OpenClawContract
FeatureChat          → OpenClawContract, OpenClawTransport, OpenClawStore, OpenClawDesign
FeatureAgents        → OpenClawContract, OpenClawTransport, OpenClawDesign   # + OpenClawStore if MainAgentTask polls via Store; confirm w/ C6
FeatureSettings      → OpenClawContract, OpenClawAuth, OpenClawDesign        # + OpenClawTransport iff C2's PairingFlow needs it; confirm w/ C2/C7
FeatureSurfaces      → OpenClawContract, OpenClawTransport, OpenClawDesign   # empty stub until C8 migrates source
OpenClawMobile (app) → all of the above          # composition root only
```
This list is the **initial baseline**, not an authoritative freeze. Each entry is confirmed against the owning chunk's PRD before that chunk migrates; several are explicitly provisional (the `# confirm` notes above). A chunk team may **add** an edge to its own module — provided the edge does not violate a frozen prohibition — by editing `project.yml` and `expected-edges.json` in one PR. The frozen tier never changes without org sign-off; the baseline tier grows continuously and that growth is normal, not a contract break.

**Consumes (only via C0 or nothing):**
- The **existence** of the `OpenClawContract` module as declared by C0 — C10 wires every other module's edge to it but never reads its internals.
- Nothing from any spine or feature chunk's *source*. C10 references chunks only as opaque module nodes in the graph.

## 4. Dependencies

- **Allowed:** C10 depends on **C0 only**, and only structurally — it declares that `OpenClawContract` is the keystone node every other module edges to. It has no code-level import of any chunk.
- **The rule that makes a wrong dependency a build error:** each chunk is a distinct Swift module with an explicit `dependencies:` list in `project.yml`. Swift modules cannot access symbols from a module not in their dependency list — `import FeatureAgents` inside `FeatureChat` fails to compile because `FeatureChat`'s target does not list `FeatureAgents`. XcodeGen's per-target `dependencies:` is the wall; the CI `xcodebuild test` step is where a violation surfaces as a hard failure.
- **The boundary-lint fast path (avoiding false positives):** ahead of the full build, a job greps each `Feature*` module's `Sources/` for `import <SiblingFeatureModule>` to give a fast, named error. To avoid firing on non-imports, the grep (a) anchors on `^\s*(@testable\s+)?import\s+FeatureX` at line start (skips imports inside comment/string bodies, which are not at statement position), (b) is scoped to `Sources/`, never test targets, so a legal `@testable import FeatureChat` inside `FeatureChatTests` is never scanned, and (c) is advisory-fast only — the authoritative verdict is always the `xcodebuild` compile, which cannot be fooled by a false match either way.

## 5. Milestones / build order

An isolated C10 team can ship in four increments:

1. **M1 — Graph skeleton.** Rewrite `project.yml` from one app target into 9 module targets (C0–C8) + thin app target + test target(s), with the §3 baseline edge set. Check in `expected-edges.json` mirroring that baseline. `xcodegen generate` succeeds; empty stub modules compile. No source moved yet.
2. **M2 — Wall proof.** Add the boundary-lint CI job plus a standing negative-test script (see §6) that injects an illegal import into a scratch copy, builds expecting failure, and reverts. This is the acceptance-defining increment and is fully demonstrable against empty stub modules.
3. **M3 — CI + release loop.** Port `.github/workflows/ci.yml` to build/test the multi-module project, keep sim-UDID discovery and TestResults upload, keep the `testflight` job deferred behind `if: false`. Document `MARKETING_VERSION` bump discipline.
4. **M4 — Tooling + QA-hook parity.** Verify the four `tools/*.mjs` probes still run zero-dep against a live host. Verify the DEBUG launch-arg/`SEED_*` hooks still fire from the new app-target composition root — **this is verifiable only after each feature chunk (C2/C4/C5/C6/C7) has migrated its source into its module**, because seeding a paired identity and auto-sending exercises real Auth/Store/Chat code. Until then, hook parity is asserted against the current live single-target app (§8). Publish the frozen §3 contract (node names + prohibitions + launch-arg strings) as the stable interface; the baseline edge list ships alongside it explicitly labeled mutable.

## 6. Acceptance criteria

- `cd OpenClawMobile && xcodegen generate` produces a project with one module per chunk. A pure-logic test parses `project.yml`, reads the checked-in **`expected-edges.json`** fixture as the source of truth, and asserts each target's `dependencies` matches the fixture — including the load-bearing **absence** of any `OpenClawTransport`↔`OpenClawAuth` edge and of any `Feature*`→`Feature*` edge. No gateway, no feature source needed.
- **Negative test (the core guarantee), as a standing CI script — not a one-time manual proof:** the script copies the tree to a scratch dir, injects `import FeatureAgents` into a `FeatureChat` source file, runs `xcodebuild`, asserts a **non-zero** exit, then discards the scratch copy (inject → build-expect-fail → revert, all inside the throwaway copy so the real tree is never polluted). A second pass injects `import OpenClawContract` (a legal edge per `expected-edges.json`) into the same spot and asserts a **zero** exit. Both directions pinned against the fixture; the working tree is untouched either way. Demonstrable against empty stub modules.
- `xcodebuild -scheme OpenClawMobile -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test` is green on macos-15 with `CODE_SIGNING_ALLOWED=NO`.
- `node tools/phase0-verify.mjs <host> --pair <code>` completes the handshake with **zero** `node_modules` present (asserts the zero-dep invariant).
- **DEBUG launch-arg parity (scoped to the current live single-target app):** launching the app today with `--seed-demo` + `SEED_HOST`/`SEED_DEVICE_TOKEN`/`SEED_DEVICE_KEY` seeds a paired identity and auto-sends; `--open-profile <id>` opens the profile screen. Verified by an XCUITest asserting the expected screen/state per arg. This runs against real Auth/Store/Chat source and is **not** an empty-stub acceptance. The equivalent check against the new module-split composition root is re-run per M4, once the relevant feature chunks have migrated their source — a post-migration acceptance, not an isolated-C10 one.
- CI uploads `TestResults.xcresult` as an artifact; the `testflight` job remains skipped (`if: false`) until C9 lands push + an Apple team is wired.

## 7. Isolation proof

A single agent in a git worktree can build **C10's structural deliverables (M1–M2) plus its tooling and CI (M3)** from this PRD alone, against **empty stub modules plus a live gateway host string**. The graph skeleton, the illegal-import wall, the boundary-lint job, the parsed-edges golden test (which reads the checked-in `expected-edges.json` fixture as its unambiguous target), and the zero-dep probes require no sibling source: the 9 modules start as single empty Swift files, and the wall-proof uses a throwaway injected import in a scratch copy, not real feature code. The one external fact C10 consumes — that `OpenClawContract` is the keystone module — is a *name* declared by C0's PRD, not a symbol it must link against. The **one deliverable that is NOT an empty-stub acceptance is M4's DEBUG-hook parity against the new module-split composition root**: seeding a paired identity and auto-sending exercises real C2/C4/C5 code, so that specific check is verified only after each feature chunk migrates its source. Until then it is validated against the current live single-target app (§8), where the hooks already work. So: C10's graph and wall are provable in isolation; QA-hook parity in the new roots is explicitly a post-migration, cross-chunk verification, not something an isolated stub-only worktree can close.

## 8. Status & risks

**Status — mixed, honest:**
- **LIVE:** `project.yml` (single-target today), `ci.yml` (xcodegen→xcodebuild test on every PR, sim discovery, TestResults upload, deferred testflight stub), all four `tools/*.mjs` probes, and the `--seed-demo`/`--open-*` DEBUG hooks. The build/release loop works today, and the QA hooks fire against the current single-target app.
- **UNBUILT (the new Approach-A deliverable):** the **module split does not exist yet** — the app is currently one target where every file can import every other file. `FeatureSurfaces` (C8) has no source at all and will land as an empty stub. The mechanical §1 wall (and the `expected-edges.json` fixture) is aspirational until M1–M2 land. This is the chunk's real work.

**Sequencing (not a risk — a stated ownership rule): C10 does NOT edit sibling source.** C10 lands the empty stub modules and baseline edges (M1). Then **each chunk team migrates its own files into its own module**, fixing that chunk's `access` levels (types that were implicitly-internal-shared become invisible across modules and must be made `public` where a legal edge needs them) and, if needed, adding its own baseline edges via the `project.yml` + `expected-edges.json` one-PR path. There is no C10-run flag-day that rewrites everyone's files; the split completes as a wave of per-chunk migrations against the stub graph C10 provides. C10 coordinates the frozen *shape* and the prohibitions, not the *source*, and reviews each baseline-edge addition.

**Risks / open questions:**
- **`project.yml` is a shared file, but the contract absorbs the churn.** Because C10 owns the one XcodeGen file holding every chunk's `dependencies:`, a feature team adding a *legal* edge edits C10's file — a merge point. This is by design under the two-tier §3 contract: the frozen tier (names + prohibitions + launch args) never moves, so these edits are additive baseline growth, not contract renegotiation, and touch disjoint per-target blocks that merge cleanly. The **local-SwiftPM-package alternative** (a `Package.swift` per module) removes even the shared-file touch: each team owns its own manifest and edge list. That is the primary decision input for SwiftPM-vs-XcodeGen below — weigh it alongside build speed, not just below it.
- **Provisional baseline edges (§3).** `FeatureSettings`→`OpenClawTransport` (does C2's `PairingFlow` import transport directly, or only a `ConnectSigner`/`SyncSource` seam?), `FeatureAgents`→`OpenClawStore` (does `MainAgentTask` poll through Store?), and `OpenClawDesign`→`OpenClawContract` (shared tokens?) are all baseline guesses to confirm against C2/C6/C7/C0 PRDs before those chunks migrate. Wrong guesses cost one edge edit, not a contract change.
- **The C1↔C2 non-edge is the keystone rule made mechanical.** `OpenClawTransport` and `OpenClawAuth` each depend only on `OpenClawContract`; neither edges to the other. That absence — enforced by the golden test — is exactly the `ConnectSigner`-in-C0 break the load-bearing constraints require. If C0 fails to define `ConnectSigner`, C1 and C2 cannot compile without an illegal mutual edge; that is the earliest signal C0's keystone is incomplete.
- **F0.3 unproven.** The whole approach-B routing that C6 relies on assumes the phone lacks `operator.admin`. C10 owns `rpc-probe.mjs`, the tool that would *prove* it — worth running to de-risk the org before teams commit.
- **SwiftPM packages vs XcodeGen sub-targets.** §1 allows either. This PRD assumes XcodeGen sub-targets (keeps `project.yml` as the single source of truth, avoids a second package manifest). The reversible tradeoff: XcodeGen keeps one authoritative file but concentrates baseline-edge edits there (above); local SwiftPM packages remove that touch and speed isolated builds at the cost of N manifests. The exposed §3 contract (node names + prohibitions + launch args) is identical either way, so the choice stays inside C10.
