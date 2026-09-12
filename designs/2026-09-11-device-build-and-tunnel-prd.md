# PRD — Physical-device builds, code signing, and real-tunnel validation

Date: 2026-09-11 · Status: proposed · Branch: `dev-suite-board`
Supersedes nothing. Implements Workstream C of `designs/2026-09-10-offline-push-device-loop.md`.

---

## 1. Problem statement

**OpenClaw Mobile has never run on a physical iPhone.** Every build, every test, and all
of the 2026-09-08 live validation ran in the iOS Simulator. Two separate facts make that a
narrower result than it reads as:

1. **The project cannot produce a device build at all.** `OpenClawMobile/project.yml`
   currently sets, at project scope:

   ```yaml
   settings:
     base:
       DEVELOPMENT_TEAM: ""
       CODE_SIGNING_REQUIRED: "NO"
       CODE_SIGN_IDENTITY: "-"
   ```

   Ad-hoc identity `-` with signing not required is a simulator-only configuration. A
   device build against it fails at the signing step; there is no provisioning profile, no
   team, and no mechanism to supply one.

2. **The transport that has been validated is not the transport a phone uses.** All live
   validation to date ran against `ws://127.0.0.1:18789`. That works *only* because the
   Simulator shares the Mac's network stack — `127.0.0.1` on the Simulator is the Mac's
   loopback. A physical iPhone's `127.0.0.1` is the phone itself. The real transport is a
   Cloudflare Tunnel producing a `wss://` URL, and it has never carried a byte of this
   app's traffic.

On 2026-09-08 the `wss://`/TLS *code path* was proved with a local TLS terminator
(`tls.createServer` → `net.connect(18789)` on `localhost:8443`) plus
`xcrun simctl keychain <udid> add-root-cert`. TLSv1.3 handshake, an ESTABLISHED socket
held by the app's own PID, and the nonce `TLSPROOF-84103` in openclaw's SQLite. That is
real, and it closes the question of whether `URLSessionWebSocketTask` speaks `wss://` here.
It does **not** close: a public hostname, a publicly-trusted CA chain, App Transport
Security against a real server, NAT/CDN traversal, a provisioning profile, a device
keychain, or anything a person can hold.

The three unknowns stack: we cannot ship to a phone, and if we could we could not reach a
gateway from it, and if we could do both we have no evidence pairing survives on real
hardware.

### The constraint that makes this non-negotiable

`CODE_SIGNING_ALLOWED=NO` **must never be reintroduced**, on any platform, in any script,
in CI or locally. With signing disabled no entitlements are injected into the binary at
all — including `application-identifier`. Without it the app belongs to no keychain access
group, so **every** `SecItemAdd` fails with `-34018` (`errSecMissingEntitlement`). The
Ed25519 device key is then re-minted on every launch, the gateway sees a new `device.id`
each time, and pairing can never persist. CI was green for months with exactly this bug
present, because the unit suite did not then write to the keychain.
**No longer true (verified 2026-09-12):** `Tests/DeviceAuthTests.swift` gained real
`SecItemAdd` round-trips as DEFECT 2 regression tests after the 2026-09-08 live
validation. Under `CODE_SIGNING_ALLOWED=NO`, 6 of its 8 tests now fail with
`status=-34018` — keychain write, accessibility, and identity-reuse. The suite
catches this today; it did not when this paragraph was first written. Signing is not a packaging
detail in this app; it is load-bearing for the core auth mechanism.

> **Correction to the record.** `CLAUDE.md` and the comment in `.github/workflows/ci.yml`
> both attribute the `-34018` failure to a missing `keychain-access-groups` entitlement.
> `OpenClawMobile/Sources/OpenClawMobile.entitlements` is in fact an empty
> `<plist><dict/></plist>` — there is no `keychain-access-groups` key, and
> `KeychainService.swift` sets no `kSecAttrAccessGroup` (only
> `kSecAttrAccessibleAfterFirstUnlock`). The app uses the *default* access group, which is
> derived from the `application-identifier` entitlement that the signing step injects. The
> conclusion is unchanged and the ban stands; the stated mechanism was wrong. This PRD
> fixes the comments as part of the work.

---

## 2. Goals

- **G1.** `project.yml` produces a signable device build when a team ID is available, and
  an unchanged simulator build when one is not. CI keeps passing with no team configured.
- **G2.** A team ID can be supplied without editing, and without any risk of committing, a
  tracked file.
- **G3.** A one-command script publishes the local sandbox gateway over a Cloudflare quick
  tunnel and prints the `wss://` URL — and does not run itself without explicit approval.
- **G4.** A written, exact, ten-minute device-validation checklist a human can execute,
  ending in a gateway-side oracle (a random nonce typed on the phone, found in openclaw's
  own storage) rather than a screenshot of the app claiming success.
- **G5.** An honest, durable division of labour: what an agent finishes unaided vs. what
  strictly requires a human with an Apple ID and a phone in their hand.

## 3. Non-goals

- **TestFlight and App Store Connect.** Deferred since 2026-07-21; needs a paid program
  membership and an API key. `ci.yml` already has the stub job.
- **APNs / remote push.** Workstream B. Push entitlements are unavailable on a free
  personal team anyway, which is a second reason to keep them separate.
- **A named tunnel and a domain.** Designed below and recommended for durability, but
  quick tunnel is sufficient for validation and needs no purchase.
- **Device UI tests in CI.** GitHub macOS runners have no iPhone attached. Out of scope
  permanently, not just now.
- **Multiple gateways, cockpit/terminal control.** Unrelated.
- **Distributing to anyone else's phone.** One developer, one device.

---

## 4. Signing configuration

### 4.1 What changes in `project.yml`

Delete the three project-scope settings and replace them with SDK-scoped ones plus an
xcconfig reference.

**Remove** from `settings.base`:

```yaml
DEVELOPMENT_TEAM: ""
CODE_SIGNING_REQUIRED: "NO"
CODE_SIGN_IDENTITY: "-"
```

**Add** at project scope:

```yaml
configFiles:
  Debug: Signing.xcconfig
  Release: Signing.xcconfig
settings:
  base:
    SWIFT_VERSION: "5.0"
    MARKETING_VERSION: "0.2.0"
    CURRENT_PROJECT_VERSION: "1"
    CODE_SIGN_STYLE: Automatic
    "CODE_SIGN_IDENTITY[sdk=iphoneos*]": "Apple Development"
```

Notes on each value, since "configure signing" is exactly the hand-waving this document
exists to avoid:

- `CODE_SIGN_STYLE: Automatic` — Xcode manages the profile. Manual profiles would mean
  committing a profile name, and there is nothing to gain.
- `CODE_SIGN_IDENTITY[sdk=iphoneos*]` is **SDK-scoped**. Simulator builds are left alone
  and continue to sign ad-hoc (`-`) with no team, which is why CI is unaffected. This is
  the one line doing the simulator/device split; an unscoped value would break CI.
- `DEVELOPMENT_TEAM` appears **nowhere in `project.yml`**. It arrives only from the
  xcconfig below or from the `xcodebuild` command line.
- `CODE_SIGNING_REQUIRED` is simply gone. Leaving it as `NO` for device builds would
  produce an unsigned `.app` that installs nowhere; setting it `YES` would break the
  simulator path. Xcode's own per-SDK defaults are correct and need no help.

### 4.2 The team-ID injection mechanism

Two files, one tracked and one not.

**`OpenClawMobile/Signing.xcconfig`** — tracked, committed, contains no secrets:

```
// Signing configuration.
//
// Device builds need an Apple Development team. Do NOT put a team ID in this file —
// it is tracked. Put it in Signing.local.xcconfig, which is gitignored:
//
//     echo 'DEVELOPMENT_TEAM = ABCDE12345' > OpenClawMobile/Signing.local.xcconfig
//
// Simulator builds need nothing here: they sign ad-hoc with no team.
// NEVER set CODE_SIGNING_ALLOWED = NO. It strips entitlements, every Keychain write
// fails -34018, and device pairing can never persist. See CLAUDE.md.

#include? "Signing.local.xcconfig"
```

`#include?` (with the question mark) is Xcode's *optional* include: if the file is absent
the build proceeds silently. That is what keeps a fresh clone and CI working with zero
setup.

**`OpenClawMobile/Signing.local.xcconfig`** — never created by the repo, added to
`.gitignore`:

```
DEVELOPMENT_TEAM = ABCDE12345
// Optional, only if the bundle ID collides with an existing registration:
// PRODUCT_BUNDLE_IDENTIFIER = com.yourname.openclawmobile
```

**`.gitignore`** gains, under the Xcode section:

```
# Signing — team ID is personal and must never be committed
OpenClawMobile/Signing.local.xcconfig
```

**Escape hatch for CI or one-off builds**, no file needed — a command-line build setting
outranks both xcconfigs:

```bash
xcodebuild -project OpenClawMobile/OpenClawMobile.xcodeproj -scheme OpenClawMobile \
  -destination "platform=iOS,id=$UDID" \
  DEVELOPMENT_TEAM="$OPENCLAW_TEAM_ID" -allowProvisioningUpdates build
```

**Why an xcconfig and not an environment variable read from `project.yml`.** XcodeGen can
interpolate `${VAR}` from the environment at generate time, but that bakes the team ID
into the generated `project.pbxproj` — which is a **tracked file** (it is in the modified
list right now). One `git add -A` and the team ID is public. The xcconfig is referenced by
path from the pbxproj and read at build time; the ID itself never enters any tracked file.
That property is the whole point.

### 4.3 Consequence: the device gets a different keychain access group

The default keychain access group is the `application-identifier` entitlement. On the
simulator, ad-hoc signing gives `com.openclaw-gv.mobile`. On a device the provisioning
profile gives `TEAMID.com.openclaw-gv.mobile`. These are different groups, so **the device
mints its own Ed25519 identity on first launch and needs its own pairing approval.** This
is correct behaviour, not a defect, and the validation plan in §6 depends on it: the
device's first connect *should* be refused with a fresh `requestId`.

---

## 5. Tunnel design

The phone cannot reach `127.0.0.1:18789`. Something must give the gateway a public
address. The gateway stays loopback-bound in both options below; `cloudflared` dials
outward, so no inbound port is ever opened.

### 5.1 Quick tunnel vs. named tunnel

| | Quick tunnel | Named tunnel + domain |
|---|---|---|
| Command | `cloudflared tunnel --url http://127.0.0.1:18789` | `cloudflared tunnel create` + `route dns` + config file |
| Cloudflare account | not required | required (free) |
| Domain | not required | required (any cheap domain) |
| Hostname | random `https://<words>.trycloudflare.com` | `wss://gw.yourdomain.com`, fixed forever |
| Survives restart | **no** — new hostname each run | yes |
| Effect on pairing | host string changes → app must be re-pointed every session | set once |
| Survives reboot | no | yes, `sudo cloudflared service install` |
| Setup time | ~10 seconds | ~10 minutes, once |
| Cost | free | free + domain |
| Right for | this validation run | anyone actually using the app |

**Decision: quick tunnel for the validation in §6, named tunnel documented as the
durable answer.** The quick tunnel's hostname churn is the single worst property — the
pairing is keyed to the device identity and survives, but the *host setting* in the app
does not, so every tunnel restart is a manual re-point. That is tolerable for one ten-
minute run and intolerable for daily use. `designs/2026-07-22-stable-tunnel-onepager-guide.md`
already documents the named-tunnel path end to end and needs no changes.

TLS is Cloudflare-terminated in **both** cases — the quick tunnel is not a weaker trust
model than the named one, only a less stable address. Both present a publicly-trusted
Cloudflare edge certificate, which is what makes them interesting: unlike the 2026-09-08
self-signed terminator, no trust-store manipulation is needed on the phone.

### 5.2 `sandbox/tunnel.sh` (new, alongside `sandbox/up.sh`)

```bash
#!/usr/bin/env bash
# Publish the local sandbox gateway on a Cloudflare quick tunnel.
#
# THIS EXPOSES THE GATEWAY TO THE PUBLIC INTERNET. It is token-protected and
# pairing-gated, but it is outward-facing. Do not run it without asking.
set -euo pipefail

command -v cloudflared >/dev/null || { echo "brew install cloudflared" >&2; exit 1; }
curl -sf -m 2 http://127.0.0.1:18789/health >/dev/null \
  || { echo "gateway not up — run ./sandbox/up.sh first" >&2; exit 1; }

echo "About to publish http://127.0.0.1:18789 to the public internet."
read -r -p "Type 'publish' to continue: " ok
[ "$ok" = "publish" ] || { echo "aborted"; exit 1; }

cloudflared tunnel --url http://127.0.0.1:18789 2>&1 | tee /tmp/oc-tunnel.log &
# The hostname appears in cloudflared's banner a few seconds in.
for _ in $(seq 1 30); do
  url=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' /tmp/oc-tunnel.log | head -1) && [ -n "$url" ] && break
  sleep 1
done
[ -n "${url:-}" ] || { echo "no tunnel URL after 30s; see /tmp/oc-tunnel.log" >&2; exit 1; }
echo
echo "Gateway host for the app:  ${url/https:/wss:}"
echo "Verify from outside:       curl ${url}/health"
```

**The interactive confirmation is deliberate and is not decoration.** An agent running
this script non-interactively hits the `read` and blocks rather than publishing. The
approval gate lives in the script, not only in a document someone might not read.

### 5.3 Approval requirement

Starting the tunnel is an outward-facing act and requires **explicit human approval in
conversation, per run**. An agent may write `sandbox/tunnel.sh`, lint it, and document it.
An agent may not execute it on its own initiative. Prior approval for one session does not
carry to the next.

---

## 6. Device validation plan — ten minutes, one human, one phone

Prerequisites, all one-time and outside the ten minutes: an Apple ID added to Xcode
(Settings → Accounts), a USB-C cable, and Developer Mode enabled on the phone (Settings →
Privacy & Security → Developer Mode → on → reboot).

Times are wall-clock for a second run; the first run adds ~10 minutes of Apple-account and
Developer-Mode setup.

**Step 0 — team ID (30s).** Xcode → Settings → Accounts → your Apple ID → the Team ID is
the ten-character string in the team list. Or:

```bash
security find-identity -v -p codesigning | grep "Apple Development"
# → "Apple Development: you@example.com (XXXXXXXXXX)"  ← the parenthesised string
echo 'DEVELOPMENT_TEAM = ABCDE12345' > OpenClawMobile/Signing.local.xcconfig
(cd OpenClawMobile && xcodegen generate)
```

**Step 1 — gateway up (30s).**

```bash
./sandbox/up.sh
curl -s http://127.0.0.1:18789/health     # → {"ok":true,...}
```

**Step 2 — tunnel up (1 min). Requires approval.**

```bash
./sandbox/tunnel.sh        # type 'publish'; prints wss://<words>.trycloudflare.com
curl -s https://<words>.trycloudflare.com/health    # proves it from the public internet
```

If `/health` answers through the tunnel but not the app later, the failure is in the app
or ATS, not reachability. Establish this line first — it is what makes the next failure
diagnosable.

**Step 3 — find the phone (15s).**

```bash
xcrun devicectl list devices
# copy the Identifier column for your iPhone → $UDID
```

**Step 4 — build and install (3 min, mostly compile).**

```bash
UDID=<from step 3>
xcodebuild -project OpenClawMobile/OpenClawMobile.xcodeproj -scheme OpenClawMobile \
  -destination "platform=iOS,id=$UDID" -derivedDataPath /tmp/ocm-dev \
  -allowProvisioningUpdates build
xcrun devicectl device install app --device "$UDID" \
  /tmp/ocm-dev/Build/Products/Debug-iphoneos/OpenClawMobile.app
```

`-allowProvisioningUpdates` lets Xcode register the device and mint the profile without a
GUI round trip. Do **not** add `CODE_SIGNING_ALLOWED=NO` to make a signing error go away —
it will make the error go away and the app will then be permanently unable to pair.

**Step 5 — trust the certificate (30s, human-only, first install only).** On the phone:
Settings → General → VPN & Device Management → Developer App → your Apple ID → **Trust**.
Until this is done the app installs but refuses to launch. There is no CLI for it.

**Step 6 — launch and point at the tunnel (1 min).** Launch from the Home screen, or:

```bash
xcrun devicectl device process launch --device "$UDID" com.openclaw-gv.mobile
```

In the app: Settings → host → `wss://<words>.trycloudflare.com` (no port — TLS hosts must
not carry `:18789`; `wsURL(host:)` in `GatewayWSSyncSource.swift:383` only defaults the
port for plaintext schemes, which is the correct behaviour for a tunnel on 443).

**Step 7 — pair (1 min).** The first connect is refused with `pairing required`. Do not
use `openclaw qr` — it embeds the gateway's own address, which inside Docker is the
container IP (`ws://172.17.0.2:18789`) and is unreachable from anywhere else. The
host-first flow is the one that works:

```bash
docker exec oc openclaw devices list          # find the pending requestId
docker exec oc openclaw devices approve <requestId>
```

The app flips to **Paired** and the roster fills. This is a *new* identity, distinct from
any simulator pairing — see §4.3.

**Step 8 — the oracle (2 min).** Type a message on the phone containing a random nonce,
e.g. `DEVICE-PROOF-7741`. Then, from the Mac, prove it reached the gateway's own storage —
not just the phone's screen:

```bash
export OPENCLAW_GATEWAY_TOKEN=$(cat sandbox/.token)
node tools/rpc-probe.mjs 127.0.0.1:18789 chat.history '{"sessionKey":"agent:main:main"}' \
  | grep DEVICE-PROOF-7741
```

Reading it back over **loopback** while it was typed over the **tunnel**, from a
**different client**, is what makes this an oracle: no app-side state can fake it. For a
stronger version, query openclaw's SQLite in place inside the container (`ls /data` to
locate the database first, then `node:sqlite` — a copied `.sqlite` misses rows still in
the `-wal`, which is the trap hit on 2026-09-08).

**Step 9 — kill the tunnel.** Ctrl-C `tunnel.sh`. The gateway is no longer public. Confirm:
`curl https://<words>.trycloudflare.com/health` now fails.

### 6.1 Pass criteria for the run

Every one of these, or the run did not pass:

1. The app launched on a physical iPhone from a signed build with a real team ID.
2. The roster populated over `wss://` through a public hostname.
3. Pairing was approved and **survived a force-quit and relaunch** — this is the
   `-34018` regression test, and it is the single most important line in this document.
4. The nonce typed on the phone was found in gateway-side storage by a separate client.
5. `Signing.local.xcconfig` is untracked; `git status` shows no team ID anywhere.
6. The tunnel was stopped and is confirmed dead.

---

## 7. Agent vs. human

### An agent can complete unaided

- Every `project.yml` edit in §4.1, plus `Signing.xcconfig`, plus the `.gitignore` entry.
- `xcodegen generate` and verifying the generated `pbxproj` contains no team ID
  (`grep DEVELOPMENT_TEAM OpenClawMobile/OpenClawMobile.xcodeproj/project.pbxproj`).
- Proving the simulator path is unregressed: full `xcodebuild test` on the simulator with
  **no** `Signing.local.xcconfig` present. This is the CI-safety proof and it is
  mechanically checkable.
- Proving the device path fails *for the right reason* without a team: a device-destination
  build with no local xcconfig must fail with a signing/provisioning error, not a compile
  error. ("No account for team" / "requires a development team" — both acceptable.)
- Writing `sandbox/tunnel.sh` and shellchecking it.
- Correcting the wrong `keychain-access-groups` mechanism in `CLAUDE.md` and `ci.yml`
  (§1) without weakening the ban.
- Writing the §6 checklist into `designs/2026-09-10-HUMAN-ACTIONS.md`.

### Strictly requires a human

- **An Apple ID and a team ID.** Cannot be obtained programmatically.
- **Approving and running the tunnel** (§5.3).
- **A physical iPhone**, cabled, with Developer Mode on.
- **Trusting the developer certificate** (step 5) — a Settings tap, no CLI equivalent.
- **Typing the nonce and reading the screen** (step 8). An agent can run the read-back
  half; it cannot type on the phone.
- **The relaunch check** (pass criterion 3) — force-quitting via the app switcher.

An agent must not claim device validation. It can claim the device build *configuration*
is correct and that the simulator path is unregressed. Those are different assertions and
conflating them is how CI stayed green for months with pairing broken.

---

## 8. Risks

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R1 | `CODE_SIGNING_ALLOWED=NO` reintroduced to silence a signing error | medium | critical — pairing silently dies, tests stay green | **Resolved 2026-09-12 — no grep needed.** `DeviceAuthTests` fails 6/8 with `-34018` under the flag, so the existing suite is the guard. Verified by a controlled run (control 8/8 green; flagged run 6/8 red). Ban also documented in `CLAUDE.md`, `ci.yml`, README and `Signing.xcconfig`. |
| R2 | Quick-tunnel hostname churns; app points at a dead host | **certain** | low, recurring | Expected. Named tunnel (§5.1) is the fix for real use. App already reports `unreachable` honestly. |
| R3 | Team ID committed via the generated `pbxproj` | low | medium — personal identifier leaked | Exactly why the mechanism is an xcconfig, not XcodeGen env interpolation (§4.2). Verify with `grep` after generating. |
| R4 | Bundle ID `com.openclaw-gv.mobile` already registered to another team | medium on a free personal team | blocks install | `PRODUCT_BUNDLE_IDENTIFIER` override in `Signing.local.xcconfig` (§4.2). |
| R5 | Free personal team: profiles expire after 7 days, 3-app limit, no push entitlement | certain if free team | low now, blocks Workstream B | Re-run step 4 weekly. Paid program needed before APNs — already a non-goal. |
| R6 | ATS blocks the connection | **low** | high if it happens | Cloudflare edge certs meet ATS (TLS 1.2+, forward secrecy, SHA-256). `NSAllowsLocalNetworking: true` is the only current exception and is unrelated. **Never add `NSAllowsArbitraryLoads`** — rejected in eng review 2026-07-21 for a trust product. If a device build hits ATS, the cause is a self-signed host, and the answer is a real tunnel, not a plist exception. |
| R7 | Self-signed cert on a device | low | high | The Simulator trick (`simctl keychain add-root-cert`) has no device equivalent. A device needs a configuration profile *and* a manual toggle in Settings → General → About → Certificate Trust Settings. Avoid entirely by using a real tunnel. |
| R8 | Pairing confusion across transports/identities | medium | medium — burns debug time | §4.3: device and simulator are different keychain groups, so different identities and separate approvals. A device that was "already paired" in the Simulator will still be refused. This is correct; expect it. |
| R9 | `wss://host:18789` typed by hand | medium | low | `wsURL(host:)` already declines to force `:18789` on TLS schemes (fixed 2026-07-21, covered by `WireProtocolTests`). Tunnels terminate on 443. |
| R10 | Device build regresses CI | low | medium | Every signing setting is SDK-scoped or optional-included. Proven by the no-xcconfig simulator test run (§7). |

---

## 9. Acceptance criteria

**Configuration (agent-verifiable, all mechanical):**

- [ ] A1 `project.yml` contains no `DEVELOPMENT_TEAM`, no `CODE_SIGNING_REQUIRED`, and no
      unscoped `CODE_SIGN_IDENTITY`.
- [ ] A2 `OpenClawMobile/Signing.xcconfig` exists, is tracked, contains
      `#include? "Signing.local.xcconfig"`, and contains no team ID.
- [ ] A3 `.gitignore` ignores `OpenClawMobile/Signing.local.xcconfig`.
- [ ] A4 With **no** `Signing.local.xcconfig`: `xcodegen generate` succeeds and the full
      simulator `xcodebuild test` passes, unchanged.
- [ ] A5 With **no** `Signing.local.xcconfig`: a device-destination build fails with a
      provisioning/team error, not a compile error.
- [ ] A6 With a local xcconfig present:
      `grep -c DEVELOPMENT_TEAM OpenClawMobile/OpenClawMobile.xcodeproj/project.pbxproj` is
      `0`, and `git status --porcelain` lists no signing file.
- [x] A7 **Restated 2026-09-12.** The original wording ("appears nowhere except in prose
forbidding it") was already false — 39 occurrences exist, and two loop docs
(`designs/2026-09-06-dev-suite-loop.md`, `designs/2026-09-07-app-completion-loop.md`)
carry *runnable* `xcodebuild … CODE_SIGNING_ALLOWED=NO` commands. The criterion that
matters is behavioural and is met: reintroducing the flag turns the suite red.
- [ ] A8 `sandbox/tunnel.sh` exists, is executable, refuses to run without the typed
      confirmation, and refuses when the gateway is down.
- [ ] A9 The `keychain-access-groups` claim in `CLAUDE.md` and `ci.yml` is corrected to the
      `application-identifier` mechanism, with the ban intact.

**Device (human-executed, none of it agent-claimable):**

- [ ] A10 App launches on a physical iPhone from a signed build.
- [ ] A11 Roster populates over a public `wss://` hostname.
- [ ] A12 Pairing approved via the host-first flow, **and survives force-quit + relaunch**.
- [ ] A13 A nonce typed on the phone is read back from gateway-side storage by a separate
      client.
- [ ] A14 Tunnel confirmed stopped.

---

## 10. Effort

| Work | Who | Estimate |
|---|---|---|
| §4 signing config + xcconfig + gitignore | agent | 30 min |
| A4/A5/A6/A7 verification builds | agent | 30 min (two compiles) |
| `sandbox/tunnel.sh` | agent | 30 min |
| Doc corrections (`CLAUDE.md`, `ci.yml`, README) | agent | 20 min |
| `designs/2026-09-10-HUMAN-ACTIONS.md` | agent | 20 min |
| **Agent subtotal** | | **~2.5 h** |
| Apple ID + Developer Mode + team ID, first time | human | ~10 min, once |
| The §6 loop | human | ~10 min |
| **Human subtotal** | | **~20 min** |
| Named tunnel + domain (optional, durability) | human | ~10 min + domain cost |

---

## 11. Ordered dependencies

```
1. Signing config (§4)         ─┐  agent, blocks everything device
2. A4/A5 verification           ├─ agent, must precede any device attempt
3. tunnel.sh written (§5.2)     │  agent, no execution
4. Doc corrections (§1, A9)    ─┘  agent, independent — can run in parallel with 1–3

5. Human supplies team ID           ← HARD BLOCK, nothing below proceeds without it
6. Human approves the tunnel        ← HARD BLOCK, outward-facing
7. Device build + install (steps 4–5)   depends on 1, 2, 5
8. Tunnel up + reachability (step 2)    depends on 3, 6
9. Point + pair + oracle (steps 6–8)    depends on 7, 8
10. Tunnel down (step 9)                depends on 9

11. Named tunnel + domain           optional; only after 9 proves the flow works
12. TestFlight / APNs               out of scope; both require a paid program
```

Items 1–4 are the entire agent-completable surface and can be finished today. Item 5 is the
wall. Nothing between 7 and 10 can be simulated, reasoned about, or inferred — it is
executed on hardware or it is not done.
