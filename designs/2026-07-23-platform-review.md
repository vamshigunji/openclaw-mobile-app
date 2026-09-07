# Platform Review — OpenClaw Mobile build/CI/DX loop

Date: 2026-07-23
Scope: `project.yml`, `.github/workflows/ci.yml`, golden path, `tools/*.mjs`, DEBUG QA hooks. Swift feature code out of scope by design.

## 1. Summary verdict

**Healthy.** The golden path is green from the two documented commands with no manual fixup. `project.yml` and `ci.yml` are correct, valid, and boring in the good way. Probes are zero-dep and disciplined. Two small drifts worth fixing: (a) the documented `--open-settings` QA hook is not implemented, and (b) CI has no recorded wall-time baseline. Nothing blocks the loop.

## 2. Golden-path status

Toolchain present: XcodeGen 2.45.4, Xcode 26.1.1 (build 17B100), Node v25.2.1.

Commands run and outcomes:

- `cd OpenClawMobile && xcodegen generate` → **OK**, ~0.04s. Wrote `OpenClawMobile.xcodeproj` cleanly; no diff churn beyond regeneration.
- `xcodebuild test -project OpenClawMobile/OpenClawMobile.xcodeproj -scheme OpenClawMobile -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO` → **TEST SUCCEEDED**. 76 tests, 3 skipped, 0 failures.

`iPhone 17 Pro` (the model named in CLAUDE.md's documented command) exists and was booted on this machine, so the documented command works verbatim. Green from a clean regenerate.

## 3. Findings by area

### Build system — `project.yml` (healthy)
- Correct single-app + unit-test target, iOS 17 deployment, `TARGETED_DEVICE_FAMILY: "1"` (iPhone-only, matches phone-first). Signing disabled for simulator (`CODE_SIGNING_REQUIRED: NO`, empty team) — correct for the no-team golden path.
- `NSAppTransportSecurity: NSAllowsLocalNetworking` only (no ArbitraryLoads) — deliberate and documented; TLS stays enforced for public hosts. Good.
- Generated `.xcodeproj` is not hand-edited; XcodeGen remains source of truth. No structural issues.
- Nit (info): `SWIFT_VERSION: "5.0"` pins Swift 5 language mode under an Xcode-26 toolchain. Deliberate/safe; flag only so a future Swift-6 migration is a conscious choice, not a surprise.

### CI — `.github/workflows/ci.yml` (healthy, two low items)
- Valid YAML; the `xcodegen generate → xcodebuild test` contract on push + PR to `main` is intact. `concurrency` cancel-in-progress, `-resultBundlePath` + artifact upload, and the `if: false` deferred TestFlight job are all clean and correct.
- The "Pick a simulator" step selects the first available iPhone via `simctl … -j` + a python3 one-liner — robust against runner image drift (does not hardcode a model). Good.
- **Low — unpinned tools installed every run.** `brew install xcodegen xcbeautify` runs on each job with no version pin or cache. Costs wall-time and admits silent version drift (supply-chain + reproducibility). Consider pinning versions and/or a tool cache if CI time matters.
- **Low — "Select latest stable Xcode" is a misnomer.** The step just `xcode-select`s the default `/Applications/Xcode.app`; it neither picks "latest" nor pins a version. Xcode drift on the runner could change build behavior invisibly. Pin an explicit Xcode version if determinism is wanted.
- **Low — no wall-time baseline recorded.** Neither `ci.yml` nor any doc carries a baseline number, so regressions have nothing to compare against (see section 5).

### Probes — `tools/*.mjs` (healthy, one hygiene note)
- All four probes (`phase0-verify`, `phase0-roundtrip`, `list-agents`, `rpc-probe`) are zero-dependency, Node built-ins only (crypto/fetch/WebSocket). Discipline intact.
- `phase0-verify.mjs` has an offline `--selftest` path (frame-build + assertions, no network) — testable without a live gateway. Nice.
- `watch-wire.command` is a thin `simctl … log stream` tap — fine, zero-dep.
- **Info (hygiene, not a leak).** `list-agents.mjs`, `rpc-probe.mjs`, and `phase0-roundtrip.mjs` read a **persisted `deviceToken`** from `tools/.phase0-device.json` (mode 600, and `git check-ignore` confirms it is gitignored — not tracked, not leaked). `phase0-verify.mjs` also accepts a token as `argv[2]`, which is visible in `ps`/shell history. This is the user's local convenience identity, not something the platform role mints. Prefer env-supplied tokens over an at-rest file / argv when convenient; leave the file as-is otherwise. No action required for safety.

### DX / QA hooks (one real drift)
- **Medium — documented `--open-settings` hook is not implemented.** CLAUDE.md's QA-hooks line advertises `--open-settings / --open-create / --open-profile <id>`. Grep of `OpenClawMobile/Sources` finds handlers for `--seed-demo` (ChatView, AgentsListView), `--open-create`, and `--open-profile <id>` (both AgentsListView) — but **nothing** for `--open-settings` (also absent from Root/ and Settings/). Anyone following the docs to screenshot the pairing/settings screen gets a no-op. Fix: either wire the hook in the Settings/Root layer or drop it from the docs.
- Env-vs-argv split is intentional and documented: `SEED_HOST` / `SEED_DEVICE_TOKEN` / `SEED_DEVICE_KEY` are read in the App entry (`OpenClawMobileApp.swift`); the `--open-*` / `--seed-demo` argv hooks live in the views they drive. Scattered but discoverable — acceptable.

## 4. Recommended actions (prioritized)

1. **(Medium) Resolve the `--open-settings` drift** — implement the hook (Settings/Root `.onAppear` reading `ProcessInfo.arguments`, mirroring `--open-create`) or remove it from CLAUDE.md. Smallest correct fix: match whichever way the screen is actually reached.
2. **(Low) Record a CI wall-time baseline** — add a one-line `# baseline: <n>s` comment to `ci.yml` on the next CI touch (see section 5), so regressions are measurable.
3. **(Low) Pin CI tool versions** — pin `xcodegen`/`xcbeautify` (and optionally an explicit Xcode version) for reproducibility and to shave/​stabilize install time. Rename the misleading "Select latest stable Xcode" step accordingly.
4. **(Info) Probe token hygiene** — document/prefer env-supplied tokens over the at-rest `.phase0-device.json` and over `argv` for `phase0-verify`. Optional; current state is gitignored and not leaking.

Skipped: caching brew/DerivedData in CI, Swift-6 migration, consolidating QA-hook parsing. Add when CI wall-time is measured to be a problem or the hooks multiply — none are today.

## 5. CI wall-time baseline

No CI run was triggered (that's out of scope for a review), so a clean-runner number is **not obtainable here**. What is measurable is the **local warm-cache** figure, recorded for reference:

- **Local, warm DerivedData, booted sim:** `xcodebuild test` reported `Testing started completed` at **8.3s**; total wall (build + test) **~13.9s**; 76 tests / 3 skipped / 0 failures.

Caveat: CI on a fresh `macos-15` runner does a **clean** build plus `brew install xcodegen xcbeautify`, so its wall-time will be materially higher than 13.9s and is not represented by this local number. Establish the real baseline from the next green CI run's "Build & test" step duration and pin it as the `# baseline:` comment in `ci.yml`.

---
No secrets are contained in this note. Live host and device/setup tokens were neither read nor written; no probe was run; no token minted or persisted.
