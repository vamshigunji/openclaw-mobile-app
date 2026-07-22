# TODOS

## Nightly protocol-drift probe
- **What:** cron `node tools/phase0-verify.mjs <stable-host>` nightly against the live gateway; alert on any handshake/frame-shape change.
- **Why:** protocol-v4 is upstream-controlled; changes can land anytime. The mock-gateway CI (eng review 2026-07-21, issue 4B) validates yesterday's protocol by design — only a live probe catches drift.
- **Pros:** drift pages the founder instead of breaking tester #1; ~30 min setup.
- **Cons:** needs the gateway reachable nightly; false alarms on tunnel churn until the named tunnel exists.
- **Context:** declined as an Approach-A plan task (eng review D8); risk documented in `.docs/devicetrust.md` invariants. Reference run: `tools/phase0-roundtrip.mjs` also exercises chat.send.
- **Depends on:** stable tunnel URL (B milestone `devicetrust setup` CLI makes this trivial).
