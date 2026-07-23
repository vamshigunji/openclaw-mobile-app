# Research: texting individual agents (Slack-teams model)

*2026-07-22. Sources: live gateway (`agents.list`/`sessions.list`), the `openclaw`
npm package source (authoritative — it IS the gateway), docs.openclaw.ai/concepts/architecture.*

## Direct answer: how many agents

Your gateway right now has **exactly 1 agent**: `main` (Claude Opus 4.8, workspace
`/Users/apple/.openclaw/workspace`, 7 existing sessions under it). The protocol
fully supports N agents on one gateway — you just have one configured.

## The model (verified from source)

**One gateway hosts many agents.** Each agent has its own **workspace** (a
directory / git repo), its own model, its own identity (name, emoji, avatar,
theme), and its own set of **sessions** (conversations). This maps cleanly to
your Slack analogy: **agent = team/channel, session = a thread within it.**

### `agents.list` — the roster (scope `operator.read`, we already have it)
Returns:
```
{
  defaultId: "main",              // the default agent
  mainKey:   "main",              // canonical session key of the default agent
  scope:     "per-sender",        // or "global"
  agents: [{
    id, name?,
    identity?: { name, emoji, avatar, avatarUrl, theme },   // display for the list
    workspace?, workspaceGit?,
    model?: { primary, fallbacks },
    thinkingLevels?, thinkingDefault?, ...
  }]
}
```
The `identity` block (emoji + name + avatar) is exactly what a Slack-style team
list needs — no extra work to make it look good.

### Addressing a specific agent
Session key format is **`agent:<agentId>:<canonicalKey>`**
(e.g. `agent:main:main`, `agent:main:global`). To text an agent you send
`chat.send { sessionKey, message, idempotencyKey, agentId? }` with that agent's
session key. Same for `chat.history { sessionKey }` and per-session subscribe.

### Fan-in still works on one socket
`sessions.subscribe {}` (what the app already uses) streams events for **all**
agents; every inbound `chat`/`session.message` event carries `agentId` +
`sessionKey`, so we route each event to the right agent thread client-side. One
connection, N conversations — no per-agent socket needed. (Our `GatewayConnection`
actor already broadcasts to all subscribers; it just needs the routing key.)

### `sessions.list` — threads within an agent
Scope `operator.read`. Returns per-agent session summaries (id, label,
last-message preview, spawnedBy…). This is the "threads in a channel" layer if we
ever want multiple conversations per agent. Live: `main` has 7 sessions.

## Gap from the current app

The app hardcodes `sessionId = "main"` (→ `agent:main:main`) — one agent, one
thread. To become multi-agent:

1. **Agent roster** — call `agents.list` on connect, render a list (emoji + name +
   model + workspace). With 1 agent it's a single row; with N it's the team switcher.
2. **Per-agent chat** — the chat view takes an `agentId` + its session key instead
   of the hardcoded `"main"`; `send`/`history`/routing key off that.
3. **Event routing** — filter the shared subscribe stream by `agentId`/`sessionKey`
   so each agent's messages land in its own thread (the actor already fans out).
4. **Navigation** — a list screen (agents) → tap → chat screen (that agent). Like
   Slack's sidebar → channel.

None of this needs new protocol work or new scopes — `agents.list` (read) +
`chat.send` (write) are both already granted to the paired device.

## Two ways to actually get multiple agents

The feature is only visible with >1 agent. To create them:
- **Gateway config** — add agents to the OpenClaw config (each with its own
  workspace/model). This is the operator's job on the gateway box.
- **`agents.create` RPC** — exists in the protocol (scope likely `operator.write`
  or `operator.admin` — unverified). Could let the app itself spin up a new agent
  ("+ New team"), but that's a later, bigger decision (write path, workspace
  provisioning).

For v1 of this feature: **list whatever agents exist and text each.** Creating
agents from the app is a separate follow-on.

## Recommended shape (for the brainstorm)

- Agents list screen as the new home (Slack sidebar), chat screen per agent.
- Reuse everything: `GatewayConnection` (one socket), `PairingFlow`, `Theme`.
- Add `agentId` + `sessionKey` to the chat view model; add `AgentSummary` DTO +
  `agents.list` call to the connection.
- Demo mode shows 2-3 fake agents so the list is never empty.

Open questions for the brainstorm: one thread per agent (simple) vs. sessions
list per agent (full Slack threads)? Show workspace/model in the list or keep it
minimal? Create-agent in-app now or defer?

---

## Implementation notes (built + live-verified 2026-07-22)

Shipped the bottom-nav + per-agent chat. Structure:
`RootTabView` (Agents · Settings) → `AgentsListView` (roster from `agents.list`,
WhatsApp-style rows) → tap → `ChatView(agent:)`. One shared `GatewayConnection`
via `AppModel.sync` — all agents on one socket.

**Load-bearing gotcha (LIVE-verified, cost a failed send):** to text agent `<id>`
you MUST send `chat.send { sessionKey: "agent:<id>:main", agentId: "<id>" }`.
- A **bare** sessionKey (`"main"`) with a separate `agentId` is REJECTED:
  `"agentId 'main' does not match session key 'main'"`.
- The full canonical key + matching agentId is accepted (`status: started`).
- Builder: `GatewayWSSyncSource.sessionKey(forAgent:)`; pinned by
  `AgentRosterTests.testCanonicalSessionKeyForAgent`.

**Routing:** subscribe once connection-wide (`sessions.subscribe {}`); every
inbound event carries `payload.agentId`, so each thread filters the shared stream
via `InboundEnvelope.matchesAgent(_:)`. No per-agent socket.

**Roster is never empty:** demo mode → 3 canned agents; real gateway with zero
agents → a `main` fallback row.

**"+" create-agent button (built + live-verified 2026-07-22, approach B):** the
app can't call `agents.create` (operator.admin), so the `+` form compiles
{name, emoji, model, behavior} into a structured instruction, `chat.send`s it to
`main` (which holds admin and runs the create tool in-process), then polls
`agents.list` for the newly-appeared agent (delta detection, not id-guessing) and
drops it into the roster. Live proof: created `coin-flipper` from the form in ~20s.
Honest UX: labeled as a request to main (tens of seconds, non-deterministic;
behavior provisioning may need a retry). Files: `CreateAgentFlow`,
`CreateAgentViewModel`, `CreateAgentView`.

**Not yet built (the layer `agents.list` can't see):** cron-orchestrated
sub-agents (e.g. the LinkedIn team: scout → Writer → Critic) live in
`cron.list` / `tasks.list`, not `agents.list`. A future **Schedules** tab would
surface them. Registered agents (`agents.create`) need `operator.admin`, which the
mobile-paired device does not hold.
