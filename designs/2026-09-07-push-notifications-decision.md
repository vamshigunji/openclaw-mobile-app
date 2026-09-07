# Push notifications: cut from v1, and what we ship instead

**Date:** 2026-09-07 · **Kind:** decision record · **Loop item:** P3.1

## Decision

**Remote push (APNs) is cut from v1.** The app ships **local notifications** for run
completion instead, fired only from real gateway terminal events while the app is running or
recently backgrounded.

## Why

Remote push needs three things this project does not have:

1. **A paid Apple Developer account.** APNs keys are issued per team. `project.yml` sets
   `DEVELOPMENT_TEAM: ""` and `CODE_SIGNING_REQUIRED: "NO"` — this app has only ever been
   built for the simulator. No team means no APNs key, no entitlement, and no device token.
2. **A push daemon on the gateway.** `designs/2026-07-23-c9-gateway-daemons-prd.md` specifies
   `device.push.register` and the delivery service. Its status is UNBUILT, and it is gated on
   the same Apple credentials.
3. **A stable delivery address.** The gateway is reached through a Quick Tunnel whose URL
   changes on restart. APNs delivery is outbound from the gateway, so this is survivable, but
   it means the daemon must hold its own credentials rather than reuse the phone's pairing.

Building the client half against a server half that cannot exist, for a transport that cannot
be provisioned, would be untestable code that ships a promise the app cannot keep.

## What ships instead

A local notification when a run finishes, posted from the same terminal signal the chat UI
already trusts: a `chat` event with state `final`, `aborted`, or `error`.

- **Never a timer.** No polling, no guessed completion. If the gateway did not say the run
  ended, nothing fires. `NotificationTests` asserts a delta produces no notification.
- **Foreground and recently-backgrounded only.** iOS suspends the socket seconds after the
  app leaves the foreground. While suspended there is no event to notify from, and the app
  does not pretend otherwise.
- **Permission asked in context**, on the first run that could produce one, not at launch.
  A denial is remembered and never nagged.

## The honest ceiling

If the phone has been backgrounded for more than roughly thirty seconds, a run that finishes
will **not** notify. The user finds out when they next open the app, where the Board's
"Needs you" column and the thread's unread state both show it. That is the real limit of a
foreground-only client and it is stated in the README rather than hidden.

## What would change this

A paid Apple Developer team. With one: an APNs key, the `aps-environment` entitlement,
`device.push.register` on the gateway (C9 M3), and the daemon that calls APNs on run
completion. The client work is small — the account and the daemon are the cost.

Until then, treat any request for "notify me when it's done while my phone is asleep" as
blocked on that account, not on app code.
