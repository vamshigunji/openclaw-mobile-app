#!/usr/bin/env node
// Phase-0 round-trip probe: signed connect → capture deviceToken →
// session.message to an agent → print every inbound frame (streamed reply).
// Usage: node tools/phase0-roundtrip.mjs <host> [--pair <bootstrapToken>] [--send "text"] [--session <id>]
import crypto from 'node:crypto'
import fs from 'node:fs'

const norm = v => typeof v === 'string' ? v.trim().replace(/[A-Z]/g, c => String.fromCharCode(c.charCodeAt(0) + 32)) : ''
const payloadV3 = p => ['v3', p.deviceId, p.clientId, p.clientMode, p.role, p.scopes.join(','), String(p.signedAtMs), p.token ?? '', p.nonce, norm(p.platform), norm(p.deviceFamily)].join('|')

const idPath = new URL('./.phase0-device.json', import.meta.url)
const pems = JSON.parse(fs.readFileSync(idPath, 'utf8'))
const priv = crypto.createPrivateKey(pems.privateKeyPem)
const pub = crypto.createPublicKey(pems.publicKeyPem)
const der = pub.export({ format: 'der', type: 'spki' })
const raw = der.subarray(der.length - 32)
const deviceId = crypto.createHash('sha256').update(raw).digest('hex')

const host = process.argv[2]
const args = process.argv.slice(3)
const flag = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined }
const bootstrapToken = flag('--pair')
const text = flag('--send') ?? 'Hello from the phase-0 probe! Reply with one short sentence.'
const sessionId = flag('--session') ?? 'main'
const savedToken = pems.deviceToken

if (!host) { console.error('usage: phase0-roundtrip.mjs <host> [--pair <bootstrapToken>] [--send "text"] [--session <id>]'); process.exit(2) }

const wsBase = host.replace(/\/$/, '').replace(/^http/, 'ws')
const token = savedToken && !bootstrapToken ? savedToken : undefined
console.log(`auth: ${token ? 'deviceToken(saved)' : bootstrapToken ? 'bootstrapToken' : 'NONE'}   device: ${deviceId.slice(0, 12)}…   session: ${sessionId}`)

const ws = new WebSocket(wsBase)
const scopes = ['operator.read', 'operator.write']
let sent = false
const idem = crypto.randomUUID()

const timer = setTimeout(() => { console.log('\n[timeout 90s] closing'); ws.close(); process.exit(0) }, 90000)

ws.addEventListener('open', () => console.log('socket open'))
ws.addEventListener('error', (e) => { console.log(`ws error: ${e.message}`); process.exit(1) })
ws.addEventListener('close', (e) => { console.log(`closed ${e.code} ${e.reason || ''}`); clearTimeout(timer); process.exit(0) })

ws.addEventListener('message', (ev) => {
  let msg; try { msg = JSON.parse(ev.data) } catch { console.log(`non-JSON: ${String(ev.data).slice(0, 200)}`); return }

  if (msg.event === 'connect.challenge' || msg.type === 'connect.challenge') {
    const nonce = msg?.payload?.nonce ?? msg?.params?.nonce ?? msg?.nonce
    const signedAtMs = Date.now()
    const sigToken = token ?? bootstrapToken ?? ''
    const payload = payloadV3({ deviceId, clientId: 'openclaw-ios', clientMode: 'node', role: 'operator', scopes, signedAtMs, token: sigToken, nonce, platform: 'ios', deviceFamily: undefined })
    const device = {
      id: deviceId, publicKey: raw.toString('base64url'),
      signature: crypto.sign(null, Buffer.from(payload, 'utf8'), priv).toString('base64url'),
      signedAt: signedAtMs, nonce,
    }
    ws.send(JSON.stringify({
      type: 'req', id: 'rt-connect', method: 'connect',
      params: {
        minProtocol: 4, maxProtocol: 4,
        client: { id: 'openclaw-ios', mode: 'node', version: '0.1.0', platform: 'ios' },
        role: 'operator', scopes, caps: [], commands: [], permissions: {},
        auth: token ? { token } : bootstrapToken ? { bootstrapToken } : {},
        device, locale: 'en-US', userAgent: 'phase0-roundtrip/0.1',
      },
    }))
    return
  }

  if (msg.id === 'rt-connect') {
    if (msg.error || msg.ok === false) { console.log(`connect refused: ${JSON.stringify(msg.error ?? msg.payload).slice(0, 300)}`); ws.close(); return }
    const auth = msg?.payload?.auth ?? {}
    console.log(`hello-ok  scopes=[${(auth.scopes ?? []).join(',')}]  deviceToken=${auth.deviceToken ? 'ISSUED' : 'none'}`)
    if (auth.deviceToken) {
      pems.deviceToken = auth.deviceToken
      fs.writeFileSync(idPath, JSON.stringify(pems, null, 2), { mode: 0o600 })
      console.log('deviceToken saved to tools/.phase0-device.json')
    }
    // subscribe first so we see the fan-in of our own send + the agent reply
    ws.send(JSON.stringify({ type: 'req', id: 'rt-sub', method: 'sessions.subscribe', params: {} }))
    return
  }

  if (msg.id === 'rt-sub') {
    console.log(`subscribe → ${msg.error ? 'ERR ' + JSON.stringify(msg.error).slice(0, 200) : 'ok ' + JSON.stringify(msg.payload ?? {}).slice(0, 200)}`)
    if (!sent) {
      sent = true
      console.log(`sending session.message: "${text}"  (idem ${idem.slice(0, 8)}…)`)
      ws.send(JSON.stringify({
        type: 'req', id: 'rt-send', method: 'chat.send',
        params: { sessionKey: sessionId, message: text, idempotencyKey: idem },
      }))
    }
    return
  }

  if (msg.id === 'rt-send') {
    console.log(`send ack → ${msg.error ? 'ERR ' + JSON.stringify(msg.error).slice(0, 300) : 'ok ' + JSON.stringify(msg.payload ?? {}).slice(0, 300)}`)
    return
  }

  // Everything else: the live event stream — this is the P3/P4 live oracle.
  const kind = msg.event ?? msg.method ?? msg.type
  console.log(`\n▸ event ${kind}: ${JSON.stringify(msg.payload ?? msg.params ?? msg).slice(0, 500)}`)
})
