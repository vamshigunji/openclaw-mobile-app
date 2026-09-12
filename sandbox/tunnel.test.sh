#!/usr/bin/env bash
# Checks for tunnel.sh. The one that matters is T2: an agent running the script
# non-interactively must NOT end up publishing the gateway.
#
#   ./sandbox/tunnel.test.sh
#
# T2 stubs cloudflared so the script can reach its approval gate without the real
# binary installed, and fails if the stub was ever invoked.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/tunnel.sh"
fails=0

check() { # name, actual-exit — every case here must refuse
  if [ "$2" -eq 0 ]; then echo "FAIL $1: expected non-zero exit, got 0"; fails=$((fails + 1))
  else echo "ok   $1"; fi
}

[ -x "$script" ] || { echo "FAIL: $script missing or not executable"; exit 1; }

# T1 — no cloudflared on PATH: refuse, and say so.
out=$(PATH=/usr/bin:/bin "$script" </dev/null 2>&1); rc=$?
check "T1 refuses without cloudflared" $rc
case "$out" in *cloudflared*) echo "ok   T1 names cloudflared";;
  *) echo "FAIL T1: message did not mention cloudflared: $out"; fails=$((fails + 1));; esac

# T2 — gateway reachable, cloudflared present, stdin closed: refuse WITHOUT publishing.
stub=$(mktemp -d); sentinel="$stub/PUBLISHED"
printf '#!/bin/sh\ntouch "%s"\n' "$sentinel" > "$stub/cloudflared"
chmod +x "$stub/cloudflared"
PATH="$stub:$PATH" "$script" </dev/null >/dev/null 2>&1; rc=$?
check "T2 refuses non-interactively" $rc
if [ -e "$sentinel" ]; then
  echo "FAIL T2: cloudflared WAS invoked — the approval gate did not hold"; fails=$((fails + 1))
else
  echo "ok   T2 never invoked cloudflared"
fi
rm -rf "$stub"

# T3 — gateway unreachable: refuse before asking for approval.
OC_GATEWAY=http://127.0.0.1:1 "$script" </dev/null >/dev/null 2>&1; rc=$?
check "T3 refuses with gateway down" $rc

[ "$fails" -eq 0 ] && echo "PASS" || echo "$fails check(s) failed"
exit "$fails"
