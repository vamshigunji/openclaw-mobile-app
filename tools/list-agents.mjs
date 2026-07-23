// One-off: enumerate agents + sessions on a live gateway (uses saved deviceToken).
import crypto from 'node:crypto'
import fs from 'node:fs'
const norm = v => typeof v==='string'?v.trim().replace(/[A-Z]/g,c=>String.fromCharCode(c.charCodeAt(0)+32)):''
const payloadV3 = p => ['v3',p.deviceId,p.clientId,p.clientMode,p.role,p.scopes.join(','),String(p.signedAtMs),p.token??'',p.nonce,norm(p.platform),norm(p.deviceFamily)].join('|')
const idPath = new URL('./.phase0-device.json', import.meta.url)
const pems = JSON.parse(fs.readFileSync(idPath,'utf8'))
const priv = crypto.createPrivateKey(pems.privateKeyPem)
const der = crypto.createPublicKey(pems.publicKeyPem).export({format:'der',type:'spki'})
const raw = der.subarray(der.length-32)
const deviceId = crypto.createHash('sha256').update(raw).digest('hex')
const host = process.argv[2]; const token = pems.deviceToken
const ws = new WebSocket(host.replace(/\/$/,'').replace(/^http/,'ws'))
const scopes = ['operator.read','operator.write']
const timer = setTimeout(()=>{console.log('[timeout]');process.exit(0)},20000)
ws.addEventListener('message', ev=>{
  const m = JSON.parse(ev.data)
  if (m.event==='connect.challenge'||m.type==='connect.challenge'){
    const nonce=m?.payload?.nonce??m?.nonce, signedAtMs=Date.now()
    const pl=payloadV3({deviceId,clientId:'openclaw-ios',clientMode:'node',role:'operator',scopes,signedAtMs,token,nonce,platform:'ios',deviceFamily:undefined})
    ws.send(JSON.stringify({type:'req',id:'c',method:'connect',params:{minProtocol:4,maxProtocol:4,client:{id:'openclaw-ios',mode:'node',version:'0.1.0',platform:'ios'},role:'operator',scopes,auth:{token},device:{id:deviceId,publicKey:raw.toString('base64url'),signature:crypto.sign(null,Buffer.from(pl),priv).toString('base64url'),signedAt:signedAtMs,nonce}}}))
    return
  }
  if (m.id==='c'){ if(m.error){console.log('connect refused',JSON.stringify(m.error));process.exit(1)}
    ws.send(JSON.stringify({type:'req',id:'a',method:'agents.list',params:{}})) ; return }
  if (m.id==='a'){ console.log('=== agents.list ===\n'+JSON.stringify(m.payload,null,2))
    ws.send(JSON.stringify({type:'req',id:'s',method:'sessions.list',params:{includeLastMessage:false}})); return }
  if (m.id==='s'){ const p=m.payload; const sess=p?.sessions??p??[]
    console.log('\n=== sessions.list ('+(Array.isArray(sess)?sess.length:'?')+') ===')
    console.log(JSON.stringify(p,null,2).slice(0,1500)); clearTimeout(timer); ws.close(); process.exit(0) }
})
ws.addEventListener('error',e=>{console.log('ws error',e.message);process.exit(1)})
