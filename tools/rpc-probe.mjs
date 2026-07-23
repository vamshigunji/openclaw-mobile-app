// Generic one-off: connect with saved deviceToken, call a method, print payload.
// usage: node tools/rpc-probe.mjs <host> <method> [jsonParams]
import crypto from 'node:crypto'; import fs from 'node:fs'
const norm=v=>typeof v==='string'?v.trim().replace(/[A-Z]/g,c=>String.fromCharCode(c.charCodeAt(0)+32)):''
const pv3=p=>['v3',p.deviceId,p.clientId,p.clientMode,p.role,p.scopes.join(','),String(p.signedAtMs),p.token??'',p.nonce,norm(p.platform),norm(p.deviceFamily)].join('|')
const pems=JSON.parse(fs.readFileSync(new URL('./.phase0-device.json',import.meta.url),'utf8'))
const priv=crypto.createPrivateKey(pems.privateKeyPem)
const der=crypto.createPublicKey(pems.publicKeyPem).export({format:'der',type:'spki'}); const raw=der.subarray(der.length-32)
const deviceId=crypto.createHash('sha256').update(raw).digest('hex')
const [host,method,paramsStr]=process.argv.slice(2); const token=pems.deviceToken
const params=paramsStr?JSON.parse(paramsStr):{}
const ws=new WebSocket(host.replace(/\/$/,'').replace(/^http/,'ws')); const scopes=['operator.read','operator.write']
const timer=setTimeout(()=>{console.log('[timeout]');process.exit(0)},20000)
ws.addEventListener('message',ev=>{const m=JSON.parse(ev.data)
  if(m.event==='connect.challenge'||m.type==='connect.challenge'){const nonce=m?.payload?.nonce??m?.nonce,signedAtMs=Date.now()
    const pl=pv3({deviceId,clientId:'openclaw-ios',clientMode:'node',role:'operator',scopes,signedAtMs,token,nonce,platform:'ios'})
    ws.send(JSON.stringify({type:'req',id:'c',method:'connect',params:{minProtocol:4,maxProtocol:4,client:{id:'openclaw-ios',mode:'node',version:'0.1.0',platform:'ios'},role:'operator',scopes,auth:{token},device:{id:deviceId,publicKey:raw.toString('base64url'),signature:crypto.sign(null,Buffer.from(pl),priv).toString('base64url'),signedAt:signedAtMs,nonce}}}));return}
  if(m.id==='c'){if(m.error){console.log('refused',JSON.stringify(m.error));process.exit(1)}
    ws.send(JSON.stringify({type:'req',id:'q',method,params}));return}
  if(m.id==='q'){if(m.error)console.log('ERROR',JSON.stringify(m.error,null,2));else console.log(JSON.stringify(m.payload,null,2));clearTimeout(timer);ws.close();process.exit(0)}
})
ws.addEventListener('error',e=>{console.log('ws error',e.message);process.exit(1)})
