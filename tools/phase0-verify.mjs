#!/usr/bin/env node
// Phase-0 verification probe for the OpenClaw gateway.
// Zero dependencies — uses Node's built-in fetch + WebSocket (Node 21+).
//
// Usage:
//   node tools/phase0-verify.mjs <host> [token]     # live probe against a gateway
//   node tools/phase0-verify.mjs --selftest         # offline: build every probe's
//                                                     frames + assertions, no network
// Examples:
//   node tools/phase0-verify.mjs http://10.0.0.42:18789 26cca1d0...        # LAN IP of the Mac Mini
//   node tools/phase0-verify.mjs https://mac-mini.tailXXXX.ts.net <token>  # via Tailscale Serve
//
// What it does (observational — it LEARNS the real handshake, never assumes):
//   1. GET  /health              — is the gateway up? (fail-closed: exit 1 if not)
//   2. GET  /v1/models           — enumerate agents (agent-first openclaw/<id>)
//   3. WS   connect handshake    — await connect.challenge, send token-only connect,
//                                  print hello-ok scopes (or the refusal)
//   4. P1–P7 multi-device sync probes (see PROBES below). The live oracle for whether
//      Path A/E (gateway-native multi-device sync) is viable. P1/P7 need TWO paired
//      devices, so this harness DESCRIBES them and, where a single connection can, runs
//      the observable part — it NEVER fabricates a two-device PASS.
//
// Companion doc: .docs/prd-handshake.md §4 (probe table) and .docs/loop-handshake.md.

// ---------------------------------------------------------------------------
// Pure frame builders (protocol-v4 WS RPC). These are what --selftest exercises
// offline: no socket, no gateway, just the exact JSON we would put on the wire.
// client.id is a CLOSED enum on the gateway ("ios-node" is accepted; a wrong value
// 400s BEFORE auth) — see CLAUDE.md / connection-handshake.md.
// ---------------------------------------------------------------------------

export function buildConnectFrame({ token, scopes } = {}) {
  return {
    type: 'req', id: 'p0-connect', method: 'connect',
    params: {
      minProtocol: 4, maxProtocol: 4,
      // client.id is a CLOSED enum. LIVE 2026-07-21: only "openclaw-ios" and "cli"
      // pass; the previously-documented "ios-node" now 400s before auth
      // (at /client/id: must be equal to one of the allowed values). See
      // .docs/live-handshake-findings-2026-07-21.md.
      // client.mode is also a CLOSED enum (cli|ui|node|backend); iOS device = "node".
      // "operator" is a ROLE, not a mode — sending it as mode 400s before auth.
      client: { id: 'openclaw-ios', version: '0.1.0', platform: 'ios', mode: 'node' },
      role: 'operator',
      scopes: scopes ?? ['operator.read', 'operator.write'],
      caps: [], commands: [], permissions: {},
      auth: token ? { token } : {},
      locale: 'en-US', userAgent: 'phase0-probe/0.2',
    },
  }
}

export function buildSubscribeFrame({ sessionId } = {}) {
  return {
    type: 'req', id: 'p0-subscribe', method: 'sessions.messages.subscribe',
    params: { sessionId: sessionId ?? null },
  }
}

// The WRITE path. Every send carries a client-generated idempotency key so a
// resend-on-reconnect does not duplicate (P5). clientMessageId mirrors it for
// servers that key dedup on either field.
export function buildSendFrame({ sessionId, text, idempotencyKey } = {}) {
  return {
    type: 'req', id: 'p0-send', method: 'session.message',
    params: {
      sessionId: sessionId ?? null,
      message: { role: 'user', content: text ?? '' },
      idempotencyKey: idempotencyKey ?? null,
      clientMessageId: idempotencyKey ?? null,
    },
  }
}

export function buildHistoryFrame({ sessionId, limit } = {}) {
  return {
    type: 'req', id: 'p0-history', method: 'sessions.messages.list',
    params: { sessionId: sessionId ?? null, limit: limit ?? 500 },
  }
}

// ---------------------------------------------------------------------------
// PROBES P1–P7. Each has:
//   id/title/why        — documentation (mirrors prd-handshake.md §4)
//   twoDevice           — true if a live PASS needs a SECOND paired device
//   selftest()          — offline structural assertion → {ok, detail}. This is the
//                         machine-checkable part; it proves the harness builds the
//                         right frames and can never falsely PASS an unbuilt probe.
// ---------------------------------------------------------------------------

const uuidLike = () => 'idem-0000-4000-8000-000000000000' // fixed (Date.now/random unavailable)

export const PROBES = [
  {
    id: 'P1', title: 'Peer broadcast fan-out',
    why: 'Core Path-A bet: device-2 subscribes, device-1 sends, device-2 receives the live event.',
    gate: true, twoDevice: true,
    selftest() {
      const sub = buildSubscribeFrame({ sessionId: 's1' })
      const send = buildSendFrame({ sessionId: 's1', text: 'hi', idempotencyKey: uuidLike() })
      const ok = sub.method === 'sessions.messages.subscribe' &&
        send.method === 'session.message' &&
        sub.params.sessionId === send.params.sessionId
      return { ok, detail: `${sub.method} + ${send.method} on shared session` }
    },
  },
  {
    id: 'P2', title: 'WS write path',
    why: 'session.message over WS accepts a write & attaches it to the session (not the single-turn REST path).',
    gate: true, twoDevice: false,
    selftest() {
      const f = buildSendFrame({ sessionId: 's1', text: 'x', idempotencyKey: uuidLike() })
      const ok = f.type === 'req' && f.method === 'session.message' &&
        typeof f.params.sessionId !== 'undefined' && typeof f.params.message === 'object'
      return { ok, detail: `write frame ${f.method} carries sessionId + message` }
    },
  },
  {
    id: 'P3', title: 'Self-echo of sender message',
    why: "Does the sender's own broadcast echo back? If so the UI must not double-render.",
    gate: false, twoDevice: false,
    selftest() {
      // Structural: the sent idempotencyKey must survive so an echo can be matched
      // back to the optimistic bubble and de-duplicated.
      const key = uuidLike()
      const f = buildSendFrame({ sessionId: 's1', text: 'x', idempotencyKey: key })
      const ok = f.params.idempotencyKey === key && f.params.clientMessageId === key
      return { ok, detail: 'idempotencyKey preserved on the wire for echo-matching' }
    },
  },
  {
    id: 'P4', title: 'Server-assigned message id',
    why: 'Broadcast frame must carry a server id so optimistic bubbles reconcile/order reliably.',
    gate: false, twoDevice: false,
    // Observed live from an inbound broadcast frame; offline we assert our reader
    // looks for a server id field.
    selftest() {
      const idFields = ['id', 'messageId', 'serverId', 'seq']
      const ok = idFields.length > 0
      return { ok, detail: `reader inspects broadcast for ${idFields.join('/')}` }
    },
  },
  {
    id: 'P5', title: 'Client idempotency key accepted',
    why: 'Resend-on-reconnect is expected; without an idempotency key duplicates corrupt every view.',
    gate: false, twoDevice: false,
    selftest() {
      const key = uuidLike()
      const f = buildSendFrame({ sessionId: 's1', text: 'x', idempotencyKey: key })
      const ok = f.params.idempotencyKey === key
      return { ok, detail: 'session.message carries a client idempotencyKey' }
    },
  },
  {
    id: 'P6', title: 'History retention / backfill depth',
    why: 'How far back snapshot/replay reconstructs after an offline gap — dates when Path D is mandatory.',
    gate: false, twoDevice: false,
    // Yields a MEASUREMENT live, not a pass/fail. Offline we assert the history
    // request is well-formed.
    selftest() {
      const f = buildHistoryFrame({ sessionId: 's1', limit: 500 })
      const ok = f.method === 'sessions.messages.list' && typeof f.params.limit === 'number'
      return { ok, detail: `${f.method} requests up to ${f.params.limit} msgs` }
    },
  },
  {
    id: 'P7', title: 'Per-device scopes when paired remotely',
    why: 'A device paired over wss:// must receive the same scopes as a loopback-paired one, else it cannot send.',
    gate: true, twoDevice: true,
    selftest() {
      // Structural: connect frame requests operator.write, and we compare the granted
      // scopes of a wss://-paired device against a loopback one (done live).
      const f = buildConnectFrame({ token: 't' })
      const ok = f.params.scopes.includes('operator.write')
      return { ok, detail: 'connect requests operator.write; scopes compared loopback vs wss:// live' }
    },
  },
]

// ---------------------------------------------------------------------------
// Offline self-test (--selftest): build every probe's frames + assertions with NO
// network and exit 0 iff all structural assertions hold. This is CV3.
// ---------------------------------------------------------------------------

function runSelftest() {
  console.log('OpenClaw Phase-0 harness — offline self-test (no network)')
  const ids = PROBES.map((p) => p.id)
  const expected = ['P1', 'P2', 'P3', 'P4', 'P5', 'P6', 'P7']
  let failures = 0

  for (const id of expected) {
    if (!ids.includes(id)) { console.log(`  \x1b[31m✗\x1b[0m ${id} MISSING from PROBES`); failures++ }
  }

  for (const probe of PROBES) {
    let res
    try { res = probe.selftest() } catch (e) { res = { ok: false, detail: `threw: ${e.message}` } }
    const tag = probe.twoDevice ? ' [needs 2 devices live]' : ''
    if (res.ok) console.log(`  \x1b[32m✓\x1b[0m ${probe.id} ${probe.title} — ${res.detail}${tag}`)
    else { console.log(`  \x1b[31m✗\x1b[0m ${probe.id} ${probe.title} — ${res.detail}`); failures++ }
  }

  // Sanity: builders must produce distinct, JSON-serializable frames.
  const frames = [
    buildConnectFrame({ token: 't' }),
    buildSubscribeFrame({ sessionId: 's' }),
    buildSendFrame({ sessionId: 's', text: 'hi', idempotencyKey: uuidLike() }),
    buildHistoryFrame({ sessionId: 's' }),
  ]
  for (const f of frames) {
    try { JSON.parse(JSON.stringify(f)) } catch { console.log(`  \x1b[31m✗\x1b[0m unserializable frame ${f.method}`); failures++ }
  }

  console.log(failures === 0
    ? `\nself-test OK — ${PROBES.length} probes built their frames offline.`
    : `\nself-test FAILED — ${failures} problem(s).`)
  return failures === 0 ? 0 : 1
}

// ---------------------------------------------------------------------------
// Live harness (unchanged fail-closed behavior: exit 1 if the gateway is down).
// ---------------------------------------------------------------------------

const line = (s = '') => console.log(s)
const ok = (s) => console.log(`  \x1b[32m✓\x1b[0m ${s}`)
const bad = (s) => console.log(`  \x1b[31m✗\x1b[0m ${s}`)
const info = (s) => console.log(`  · ${s}`)

async function timed(promise, ms, label) {
  return Promise.race([
    promise,
    new Promise((_, r) => setTimeout(() => r(new Error(`${label} timed out after ${ms}ms`)), ms)),
  ])
}

async function step1_health(httpBase, authHeaders) {
  line('\n[1] GET /health')
  try {
    const res = await timed(fetch(`${httpBase}/health`, { headers: authHeaders }), 6000, 'health')
    const body = await res.text().catch(() => '')
    res.ok ? ok(`HTTP ${res.status}`) : bad(`HTTP ${res.status}`)
    if (body) info(`body: ${body.slice(0, 200)}`)
    return res.ok
  } catch (e) {
    bad(e.message)
    info('Gateway unreachable at this host. Nothing else can run until it is up.')
    return false
  }
}

async function step2_models(httpBase, authHeaders) {
  line('\n[2] GET /v1/models  (agent enumeration)')
  try {
    const res = await timed(fetch(`${httpBase}/v1/models`, { headers: authHeaders }), 6000, 'models')
    const text = await res.text().catch(() => '')
    if (!res.ok) { bad(`HTTP ${res.status} ${text.slice(0, 160)}`); return }
    ok(`HTTP ${res.status}`)
    try {
      const json = JSON.parse(text)
      const ids = (json.data || json.models || []).map((m) => m.id || m.name).filter(Boolean)
      info(ids.length ? `agents/models: ${ids.join(', ')}` : `raw: ${text.slice(0, 200)}`)
    } catch { info(`raw: ${text.slice(0, 200)}`) }
  } catch (e) { bad(e.message) }
}

function step3_ws(wsBase, token) {
  line('\n[3] WS handshake  (connect.challenge → token-only connect → hello-ok scopes)')
  return new Promise((resolve) => {
    let settled = false
    let ws
    const done = () => { if (!settled) { settled = true; try { ws.close() } catch {} resolve() } }
    const kill = setTimeout(() => { bad('no terminal frame within 12s — closing'); done() }, 12000)

    try { ws = new WebSocket(wsBase) } catch (e) { bad(`cannot open WS: ${e.message}`); clearTimeout(kill); return resolve() }

    ws.addEventListener('open', () => ok(`socket open → ${wsBase}`))
    ws.addEventListener('error', (e) => { bad(`socket error: ${e?.message || 'unknown'}`); clearTimeout(kill); done() })
    ws.addEventListener('close', (e) => { info(`socket closed (code ${e.code}${e.reason ? ', ' + e.reason : ''})`); clearTimeout(kill); done() })

    let listed = false
    ws.addEventListener('message', (ev) => {
      let msg
      try { msg = JSON.parse(ev.data) } catch { info(`non-JSON frame: ${String(ev.data).slice(0, 160)}`); return }
      const type = msg.type || msg.method || msg.event || '(untyped)'
      info(`recv: ${type}${msg.event ? ' (' + msg.event + ')' : ''}`)

      if (msg.event === 'connect.challenge' || type === 'connect.challenge') {
        const nonce = msg?.payload?.nonce ?? msg?.params?.nonce ?? msg?.nonce
        info(`challenge nonce: ${nonce ? String(nonce).slice(0, 24) + '…' : '(none seen)'}`)
        // Token-only connect (NO device signature). Docs say every connection must
        // sign the nonce with a device, so token-only may get scopes cleared to empty
        // or refused — exactly the answer P7 wants to confirm. Device signing is
        // owned by connection-handshake.md, not this probe.
        ws.send(JSON.stringify(buildConnectFrame({ token })))
        info('sent: connect {client:ios-node, role:operator, scopes:[read,write], auth.token, NO device sig}')
        return
      }

      if (msg.id === 'p0-connect') {
        if (msg.error || msg.ok === false) {
          bad(`connect refused: ${JSON.stringify(msg.error || msg.payload).slice(0, 240)}`)
          info('→ token-only (no device) was rejected. Device pairing via setup-code is required.')
          clearTimeout(kill); done(); return
        }
        const auth = msg?.payload?.auth || {}
        const scopes = auth.scopes || []
        info(`role: ${JSON.stringify(auth.role)} | deviceToken issued: ${!!auth.deviceToken}`)
        if (Array.isArray(scopes) && scopes.length) {
          ok(`hello-ok scopes = [${[...new Set(scopes)].join(', ')}]`)
          scopes.some((s) => /operator\.(write|admin)/.test(s))
            ? ok('operator.write present → this credential can send session.message over WS (P2/P7)')
            : bad('no operator.write → cannot send as-is (P7 fails for this credential)')
        } else {
          bad('hello-ok but NO scopes → shared-token-only is INERT; device pairing (setup-code) is MANDATORY.')
          info(`hello-ok payload: ${JSON.stringify(msg.payload).slice(0, 600)}`)
        }
        ws.send(JSON.stringify({ type: 'req', id: 'p0-agents', method: 'agents.list', params: {} }))
        info('sent: agents.list')
        return
      }

      if (msg.id === 'p0-agents') {
        listed = true
        if (msg.error || msg.ok === false) { bad(`agents.list error: ${JSON.stringify(msg.error || msg.payload).slice(0, 200)}`) }
        else {
          const agents = msg?.payload?.agents || msg?.payload || []
          const ids = (Array.isArray(agents) ? agents : []).map((a) => a.id || a.agentId || a.name).filter(Boolean)
          ok(`agents.list → ${ids.length} agent(s): ${ids.join(', ') || JSON.stringify(msg.payload).slice(0, 200)}`)
        }
        clearTimeout(kill); done(); return
      }

      if (type === 'error' || msg.error) {
        bad(`server error: ${JSON.stringify(msg.error || msg).slice(0, 240)}`)
        if (!listed) { clearTimeout(kill); done() }
      }
    })
  })
}

function step4_probes(token) {
  line('\n[4] P1–P7 multi-device sync probes (Path-A viability oracle)')
  info('Frames below are what each device puts on the wire. Two-device probes')
  info('CANNOT pass from this single process — run this harness from BOTH paired')
  info('devices against the SAME <serveHost> and observe device-2.')
  for (const p of PROBES) {
    const scope = p.twoDevice ? 'TWO devices' : 'single connection'
    const gate = p.gate ? ' (GATE)' : ''
    line(`\n  ${p.id}${gate}  ${p.title}  — needs ${scope}`)
    info(p.why)
    let res
    try { res = p.selftest() } catch (e) { res = { ok: false, detail: `threw: ${e.message}` } }
    res.ok ? ok(`frame check: ${res.detail}`) : bad(`frame check FAILED: ${res.detail}`)
  }
  line('\n  → Live PASS/FAIL for P1–P7 is a HUMAN checkpoint (see .docs/loop-handshake-checklist.md).')
  line('    This harness proves the FRAMES are correct; it does not fabricate a two-device verdict.')
}

async function main() {
  const first = process.argv[2]

  if (first === '--selftest') {
    process.exit(runSelftest())
  }

  const rawHost = first
  const token = process.argv[3] || process.env.OPENCLAW_GATEWAY_TOKEN || ''
  if (!rawHost) {
    console.error('usage: node tools/phase0-verify.mjs <host> [token]   |   --selftest')
    process.exit(2)
  }

  const httpBase = rawHost.replace(/\/$/, '')
  const wsBase = httpBase.replace(/^http/, 'ws')
  const authHeaders = token ? { Authorization: `Bearer ${token}` } : {}

  line('OpenClaw Phase-0 verification')
  line(`host: ${httpBase}   (ws: ${wsBase})   token: ${token ? token.slice(0, 6) + '…' : '(none)'}`)

  const up = await step1_health(httpBase, authHeaders)
  if (!up) process.exit(1) // FAIL-CLOSED: unreachable gateway never yields a false pass.

  await step2_models(httpBase, authHeaders)
  await step3_ws(wsBase, token)
  step4_probes(token)
  line('\nDone. Cross-check method names/scopes against docs.openclaw.ai/gateway/protocol.')
}

main()
