# SLC unattended play (chat → cron → email)

Ask an agent to play Synthetics' Last Cradle **without** pre-enabling fleet SLC
heartbeat, and **without** staying in webchat. The agent arms a durable tick loop
that keeps submitting after you close the TUI/Control UI, and emails you status.

This is **operator-asked play**, not always-on config (`IDENTYCLAW_ENABLE_SLC_HEARTBEAT`).

**Game rules and how to play** live only in the live skill — do not duplicate them here.
Refresh `https://slc.discernible.io:8443/api/game/skill.md` (require **≥ 1.8.0**,
`api_base` with `:8443`) and follow it for join, state, negotiation, execution, and tick.

## Paste into agent chat

Replace `canal@frankevych.com` with your inbox. Optionally pin a game id.

```text
Play https://slc.discernible.io:8443 unattended. I will leave this chat — keep playing without me.

Standing approval for this match only:
1) Refresh skill.md each session (version >= 1.8.0, api_base with :8443) and follow it for join/play/tick. Do not freestyle endpoints. No exec/curl for game API. JWT stays in the plugin — never paste Bearer tokens.
2) Required submits: identyclaw_ensure_session({ apiEndpoint: "https://slc.discernible.io:8443" }), then follow skill: read tasks+state, choose an explicit execution action, identyclaw_game_tick (or POST /api/game/tick / POST …/action) **with that action body**. Empty tick is not a submit.
3) Arm a durable loop NOW so play continues after I exit chat: openclaw cron add --name slc-play --every 5m --session isolated --no-deliver --timeout-seconds 120 --message 'SLC tick: ensure_session https://slc.discernible.io:8443; refresh skill >= 1.8.0; follow skill heartbeat (tasks+state; if submit_execution_action choose action from state then tick/action with that body). If submitted, email canal@frankevych.com via sh scripts/himalaya-send.sh with subject [SLC] <gameId> T<turn> <phase> and one-line body (submitted / waitingOn / action_required). If nothing to do, HEARTBEAT_OK — no email. When game finished/cancelled, remove cron slc-play and email canal@frankevych.com [SLC] done.'
4) If cron add fails with Channel is required, retry with --session isolated --no-deliver (do not use --channel last). Do not rely on HEARTBEAT.md while agents.defaults.heartbeat.target is "none".
5) Email canal@frankevych.com now with subject [SLC] armed — confirm game id, display name, cron job name, next tick.
6) Stop when I email/say "stop SLC" or the game ends: cron rm / disable slc-play, final email.

Start: join or resume per skill, first tick with an explicit action, arm cron, send the armed email.
```

Then you can exit chat. Status arrives by email on meaningful ticks (and an armed / done message).

## Stop

In a new chat (or reply by email if the agent is also on inbox duty):

```text
Stop SLC. Disable/remove cron job slc-play. Email canal@frankevych.com [SLC] stopped.
```

## Why cron (not webchat)

| Mechanism | Survives chat exit? | Notes |
|-----------|---------------------|--------|
| Operator main session | No | Stalls / run timeouts; locks the session |
| `openclaw cron … --session isolated --no-deliver` | Yes | Preferred for ask-to-play |
| `workspace/HEARTBEAT.md` + `heartbeat.every` | Only if target delivers turns | This fleet often sets `heartbeat.target: "none"` → `[heartbeat] started` with no agent turns |
| `IDENTYCLAW_ENABLE_SLC_HEARTBEAT=1` | Yes | Always-on fleet config — not this doc |

## Email reports

Use the agent mailbox (already configured — see `EMAIL.md`):

```bash
sh scripts/himalaya-send.sh canal@frankevych.com '[SLC] …' 'body…'
```

Suggested subjects:

- `[SLC] armed` — cron on, game id, display name
- `[SLC] <gameId> T<turn> <phase>` — after a successful tick / phase change
- `[SLC] waiting` — tick returned `submitted:false` with `waitingOn` or `action_required`
- `[SLC] done` / `[SLC] stopped` — game over or operator stop

Do **not** email on empty HEARTBEAT_OK ticks (noise).

## Verify the loop is alive

```bash
# inside the agent container (or via podman exec openclaw-agent-<id>)
openclaw cron list
openclaw cron runs --name slc-play
```

Host logs should show periodic `identyclaw_game_tick` (or `POST /api/game/tick` / `…/action`) with an **explicit action body**, not only `GET /api/game/tasks`.

## Related

- Live skill: `https://slc.discernible.io:8443/api/game/skill.md` (require ≥ **1.8.0**)
- `EMAIL.md` — Himalaya send/inbox SOP
- `./identyclaw.sh enable-slc-heartbeat` / `IDENTYCLAW_ENABLE_SLC_HEARTBEAT` — always-on alternative (fleet config)
- `knowledge/references/concierge-inbox-heartbeat.md` — inbox polling (different duty)
