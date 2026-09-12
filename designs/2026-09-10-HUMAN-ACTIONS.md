# HUMAN ACTIONS — device build + real tunnel validation

Source: `designs/2026-09-11-device-build-and-tunnel-prd.md` §6.
Written 2026-09-12. Ten minutes, one human, one phone, one cable.

An agent cannot do any of this and must never claim it was done. It can claim the
device build *configuration* is correct and the simulator path unregressed — those are
different assertions, and conflating them is how CI stayed green for months while
pairing was broken.

**Before you start, paste your versions here** so a future reader knows what this run proves:

```
Xcode:            ____________________
iOS on device:    ____________________
Date of run:      ____________________
Apple team type:  free personal / paid    (circle one)
```

> If the team is **free personal**, the provisioning profile expires in **7 days** and the
> account is capped at 3 apps with no push entitlement. Everything below stays true only
> until that expiry. Re-run after it lapses; do not treat a passed run as permanent.

---

## Prerequisites (one-time, outside the ten minutes)

- Apple ID added to Xcode → Settings → Accounts
- USB-C cable
- Developer Mode on the phone: Settings → Privacy & Security → Developer Mode → on → reboot

---

## Step 0 — team ID (30s)

Xcode → Settings → Accounts → your Apple ID → the ten-character string in the team list. Or:

```bash
security find-identity -v -p codesigning | grep "Apple Development"
# → "Apple Development: you@example.com (XXXXXXXXXX)"  ← the parenthesised string
```

```bash
echo 'DEVELOPMENT_TEAM = XXXXXXXXXX' > OpenClawMobile/Signing.local.xcconfig
(cd OpenClawMobile && xcodegen generate)
```

That file is gitignored (`.gitignore:24`). It must never be committed.

## Step 1 — gateway up (30s)

```bash
./sandbox/up.sh
curl -s http://127.0.0.1:18789/health     # → {"ok":true,...}
```

## Step 2 — tunnel up (1 min) — REQUIRES YOUR APPROVAL

```bash
./sandbox/tunnel.sh          # type 'publish'; prints wss://<words>.trycloudflare.com
curl -s https://<words>.trycloudflare.com/health    # proves it from the public internet
```

This publishes a gateway whose agent has `exec` and `write` tools to the open internet,
behind one shared token. Approval is per run and does not carry to the next one. An agent
must not run this script; `tunnel.sh` refuses non-interactively, and
`./sandbox/tunnel.test.sh` (T2) is the check that keeps that true.

If `/health` answers through the tunnel but the app later cannot connect, the failure is in
the app or ATS, not reachability. Establishing this line first is what makes the next
failure diagnosable.

## Step 3 — find the phone (15s)

```bash
xcrun devicectl list devices     # copy the Identifier column → $UDID
```

## Step 4 — build and install (3 min, mostly compile)

```bash
UDID=<from step 3>
xcodebuild -project OpenClawMobile/OpenClawMobile.xcodeproj -scheme OpenClawMobile \
  -destination "platform=iOS,id=$UDID" -derivedDataPath /tmp/ocm-dev \
  -allowProvisioningUpdates build

xcrun devicectl device install app --device "$UDID" \
  /tmp/ocm-dev/Build/Products/Debug-iphoneos/OpenClawMobile.app
```

`-allowProvisioningUpdates` lets Xcode register the device and mint a profile without a GUI
round trip.

**Do NOT add `CODE_SIGNING_ALLOWED=NO` to make a signing error go away.** It makes the error
go away and the app permanently unable to pair. Verified 2026-09-12: under that flag
`DeviceAuthTests` fails 6 of 8 with `status=-34018`. If you see those failures, that flag is
set somewhere — find it, do not work around it.

## Step 5 — trust the certificate (30s, human-only, first install only)

On the phone: Settings → General → VPN & Device Management → Developer App → your Apple ID →
**Trust**. Until you do, the app installs but refuses to launch. There is no CLI for this.

## Step 6 — launch and point at the tunnel (1 min)

```bash
xcrun devicectl device process launch --device "$UDID" com.openclaw-gv.mobile
```

Note the bundle ID is `com.openclaw-gv.mobile` — `com.openclaw.mobile` was unavailable.

In the app: Settings → host → `wss://<words>.trycloudflare.com`

**No port.** TLS hosts must not carry `:18789`; `wsURL(host:)` only defaults a port for
plaintext schemes, which is correct — tunnels terminate on 443.

## Step 7 — pair (1 min)

The first connect is refused with `pairing required`. **Do not use `openclaw qr`** — it
embeds the gateway's own address, which inside Docker is a container IP
(`ws://172.17.0.2:18789`) unreachable from anywhere else. The host-first flow is the one
that works:

```bash
docker exec oc openclaw devices list            # find the pending requestId
docker exec oc openclaw devices approve <requestId>
```

The app flips to **Paired** and the roster fills.

This is a *new* identity, distinct from any simulator pairing: the device's default keychain
access group is `TEAMID.com.openclaw-gv.mobile`, the simulator's is ad-hoc. A device already
"paired" in the Simulator will still be refused here. That is correct — expect it.

**The pairing is host-independent.** `deviceToken` is stored under a single global
`gateway.deviceToken` Keychain key with no host in it, and the `oc-data` volume outlives
`docker rm -f oc`. So when the quick tunnel dies and comes back on a new hostname, you
re-point the host in Settings and stay paired. You do not re-pair every run.

## Step 8 — the oracle (2 min)

Type a message on the phone containing a random nonce, e.g. `DEVICE-PROOF-7741`. Then from
the Mac, prove it reached the gateway's own storage — not just the phone's screen:

```bash
export OPENCLAW_GATEWAY_TOKEN=$(cat sandbox/.token)
node tools/rpc-probe.mjs 127.0.0.1:18789 chat.history '{"sessionKey":"agent:main:main"}' \
  | grep DEVICE-PROOF-7741
```

Read back over **loopback** while it was typed over the **tunnel**, from a **different
client**. No app-side state can fake that.

Stronger version: query openclaw's SQLite in place inside the container (`ls /data` to locate
the database first, then `node:sqlite`). A copied `.sqlite` misses rows still in the `-wal` —
that trap was hit on 2026-09-08.

## Step 9 — kill the tunnel

Ctrl-C `tunnel.sh`. Confirm it is actually down:

```bash
curl https://<words>.trycloudflare.com/health    # must now FAIL
```

---

## Pass criteria — all six, or the run did not pass

Tick only what you observed. A12 and A13 need pasted evidence; the rest are observations.

- [ ] **A10** App launched on the physical iPhone from a signed build with a real team ID.
- [ ] **A11** Roster populated over `wss://` through the public hostname.
- [ ] **A12** Pairing approved **and survived force-quit + relaunch.**
      This is the `-34018` regression test and the single most important line in this
      document. Force-quit from the app switcher, relaunch, confirm still Paired.

      ```
      Evidence — paste the roster state after relaunch:


      ```

- [ ] **A13** The nonce typed on the phone was found in gateway-side storage by a separate client.

      ```
      Evidence — paste the nonce and the matching rpc-probe output line:


      ```

- [ ] **A14** Tunnel confirmed stopped (`/health` through the tunnel now fails).
- [ ] **A15** `Signing.local.xcconfig` still untracked; `git status --porcelain` shows no team ID anywhere.

---

## What this run does NOT prove

- Anything about APNs or remote push — deferred, Workstream B, and unavailable on a free team.
- Anything about TestFlight — needs a paid program membership.
- Durability of the hostname. A quick tunnel mints a new one every restart. The named-tunnel
  path is documented end to end in `designs/2026-07-22-stable-tunnel-onepager-guide.md` and
  needs no changes; it is the answer for daily use, not for this ten-minute run.
- That the run stays valid. If the team is free personal, the profile expires in 7 days.
