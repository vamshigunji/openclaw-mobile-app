#!/usr/bin/env bash
# Publish the local sandbox gateway on a Cloudflare quick tunnel.
#
#   ./sandbox/up.sh        # gateway first
#   ./sandbox/tunnel.sh    # then this, and type 'publish'
#
# THIS EXPOSES THE GATEWAY TO THE PUBLIC INTERNET. It is token-protected and
# pairing-gated, but it is outward-facing and the agent it fronts has exec and
# write tools. Approval is per run and does not carry to the next one.
#
# The `read` below is deliberate, not decoration: an agent running this
# non-interactively hits EOF and aborts before cloudflared is ever invoked.
# Checked by ./sandbox/tunnel.test.sh (T2).
set -euo pipefail

gateway="${OC_GATEWAY:-http://127.0.0.1:18789}"   # overridable so the checks can point it at a dead port
log="${TMPDIR:-/tmp}/oc-tunnel.log"

command -v cloudflared >/dev/null || { echo "cloudflared not found — brew install cloudflared" >&2; exit 1; }
curl -sf -m 2 "$gateway/health" >/dev/null \
  || { echo "gateway not up at $gateway — run ./sandbox/up.sh first" >&2; exit 1; }

echo "About to publish $gateway to the public internet."
read -r -p "Type 'publish' to continue: " ok || ok=""
[ "$ok" = "publish" ] || { echo "aborted" >&2; exit 1; }

: > "$log"
cloudflared tunnel --url "$gateway" 2>&1 | tee "$log" &

# The hostname shows up in cloudflared's banner a few seconds in.
for _ in $(seq 1 30); do
  url=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$log" | head -1) && [ -n "$url" ] && break
  sleep 1
done
[ -n "${url:-}" ] || { echo "no tunnel URL after 30s; see $log" >&2; exit 1; }

echo
echo "Gateway host for the app:  ${url/https:/wss:}"
echo "Verify from outside:       curl $url/health"
echo "Ctrl-C here to take it down, then confirm: curl $url/health  # must fail"
wait
