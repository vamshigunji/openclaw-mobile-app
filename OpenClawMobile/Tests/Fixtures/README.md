# Test fixtures

| File | Source | Status |
|---|---|---|
| `sessions.list.json` | SCHEMA-DERIVED from `openclaw/openclaw` `packages/gateway-protocol/src/schema/sessions-row.ts` (`SessionRowSchema`) | **PROVISIONAL** |
| `tasks.list.json` | SCHEMA-DERIVED from `openclaw/openclaw` `packages/gateway-protocol/src/schema/tasks.ts` (`TaskSummarySchema`, `TaskLedgerStatusSchema`) | **PROVISIONAL** |

**These are not live captures.** Field names, types, and enum values come from the gateway's
own published TypeScript schemas, so a decode failure here is still a real failure. The row
*values* are hand-built to exercise every board rule (see `BoardModelTests`), not observed
traffic.

Phase 0 of `designs/2026-09-06-dev-suite-loop.md` replaces both files with verbatim
`tools/rpc-probe.mjs` output once the gateway is reachable:

```bash
node tools/rpc-probe.mjs "$HOST" sessions.list '{"includeDerivedTitles":true,"includeLastMessage":true}' \
  > OpenClawMobile/Tests/Fixtures/sessions.list.json
node tools/rpc-probe.mjs "$HOST" tasks.list '{}' > OpenClawMobile/Tests/Fixtures/tasks.list.json
```

The decode tests run unchanged against the real payloads; any drift between these shapes and
the live gateway surfaces there. Until then, treat a green board test as "the rules are right",
not as "the wire shape is confirmed".
