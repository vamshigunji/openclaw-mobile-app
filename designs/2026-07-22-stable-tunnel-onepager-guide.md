# Give your gateway a permanent address (10 minutes, free)

*Ships with every TestFlight invite (T5). Quick Tunnels (`…trycloudflare.com`)
die on every restart and take your pairing with them — a named tunnel gives
your gateway ONE stable URL forever, still free, still no open ports.*

## What you need
- Your OpenClaw gateway box (Mac Mini / VPS) with `cloudflared` installed
  (`brew install cloudflared` / `apt install cloudflared`)
- A free Cloudflare account
- A domain added to that Cloudflare account (any cheap domain works — the
  tunnel rides a subdomain like `gw.yourdomain.com`)

## One-time setup (on the gateway box)

```bash
# 1. Log in (opens a browser; pick your domain)
cloudflared tunnel login

# 2. Create the tunnel (the name is yours; "openclaw" is fine)
cloudflared tunnel create openclaw

# 3. Point a subdomain at it
cloudflared tunnel route dns openclaw gw.yourdomain.com
```

Create `~/.cloudflared/config.yml`:

```yaml
tunnel: openclaw
credentials-file: /Users/YOU/.cloudflared/<TUNNEL-ID>.json
ingress:
  - hostname: gw.yourdomain.com
    service: http://localhost:18789
  - service: http_status:404
```

```bash
# 4. Run it — and install it as a service so it survives reboots
cloudflared tunnel run openclaw          # test it works…
sudo cloudflared service install         # …then make it permanent
```

## Verify

```bash
curl https://gw.yourdomain.com/health
# → {"ok":true,"status":"live"}
```

## Re-point the app

1. On the gateway: `openclaw qr` — if the QR still embeds an old
   `trycloudflare.com` URL, update the gateway's configured public URL to
   `wss://gw.yourdomain.com` first (gateway config / `openclaw doctor` will
   point you to it), then re-run `openclaw qr`.
2. In OpenClaw Mobile: Settings → **Scan Setup Code** → approve on the
   gateway when the app shows the approve command. Done — this address never
   changes again, so you will never re-pair because of a tunnel restart.

## Why this matters
- **Pairing survives reboots.** Quick Tunnel hostnames are random; every
  restart used to mean new URL → new setup code → re-approval. Named tunnel =
  never again.
- **Still zero open ports.** `cloudflared` dials out; your gateway stays
  loopback-bound.
- **Still free.** Named tunnels cost nothing; you only pay for your domain.

*Trust note: Cloudflare terminates TLS on any tunnel (quick or named) — this
setup changes reliability, not the trust model. The tunnel runs on YOUR
Cloudflare account; no third party is added.*
