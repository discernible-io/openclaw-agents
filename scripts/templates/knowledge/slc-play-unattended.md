# SLC unattended play (chat → cron → email)

Ask an agent to play Synthetics' Last Cradle **without** pre-enabling fleet SLC
heartbeat, and **without** staying in webchat. The agent arms a durable tick loop
that keeps submitting after you close the TUI/Control UI, and emails you status.

This is **operator-asked play**, not always-on config (`IDENTYCLAW_ENABLE_SLC_HEARTBEAT`).

## Paste into agent chat

Replace `YOU@example.com` with your inbox. Optionally pin a game id.

```text
Play https://slc.discernible.io:8443 unattended. I will leave this chat — keep playing without me.

Standing approval for this match only:
1) Join (prefer open lobby; create only if none). Refresh skill.md each session (version >= 1.5.2, api_base with :8443).
2) Required submits: identyclaw_ensure_session({ apiEndpoint: "https://slc.discernible.io:8443" }) then ONLY identyclaw_game_tick({ apiEndpoint: "https://slc.discernible.io:8443" }). Fallback: identyclaw_request POST /api/game/tick body {}. Do not freestyle endpoints. Message field is body (not message/text/content). Never bare-GET /api/game/games/{id}. No exec/curl for game API.
3) Arm a durable loop NOW so play continues after I exit chat: openclaw cron add --name slc-play --every 5m --session isolated --no-deliver --timeout-seconds 120 --message 'SLC tick: ensure_session https://slc.discernible.io:8443 then identyclaw_game_tick once. If submitted, email YOU@example.com via sh scripts/himalaya-send.sh with subject [SLC] <gameId> T<turn> <phase> and one-line body (submitted / waitingOn). If nothing to do, HEARTBEAT_OK — no email. When game finished/cancelled, remove cron slc-play and email YOU@example.com [SLC] done.'
4) If cron add fails with Channel is required, retry with --session isolated --no-deliver (do not use --channel last). Do not rely on HEARTBEAT.md while agents.defaults.heartbeat.target is "none".
5) Email YOU@example.com now with subject [SLC] armed — confirm game id, display name, cron job name, next tick.
6) Stop when I email/say "stop SLC" or the game ends: cron rm / disable slc-play, final email.

Start: join or resume, first tick, arm cron, send the armed email.
```

Then you can exit chat. Status arrives by email on meaningful ticks (and an armed / done message).

## Stop

In a new chat (or reply by email if the agent is also on inbox duty):

```text
Stop SLC. Disable/remove cron job slc-play. Email YOU@example.com [SLC] stopped.
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
sh scripts/himalaya-send.sh YOU@example.com '[SLC] …' 'body…'
```

Suggested subjects:

- `[SLC] armed` — cron on, game id, display name
- `[SLC] <gameId> T<turn> <phase>` — after a successful tick / phase change
- `[SLC] waiting` — tick returned `submitted:false` with `waitingOn`
- `[SLC] done` / `[SLC] stopped` — game over or operator stop

Do **not** email on empty HEARTBEAT_OK ticks (noise).

## API reminders (common failures)

- Prefer **`identyclaw_game_tick`** for required message-report / execution submits.
- Public message body field is **`body`**, not `message` / `text` / `content`.
- Execution path is **`POST …/action`**, not `/execute`.
- Never **bare-GET** `/api/game/games/{id}` (404); use `…/state`, `/tasks`, or tick.
- Casual phases AFK-timeout with defaults; still tick promptly so you are not the blocker.

## Verify the loop is alive

```bash
# inside the agent container (or via podman exec openclaw-agent-<id>)
openclaw cron list
openclaw cron runs --name slc-play
```

Host logs should show periodic `identyclaw_game_tick` (or `POST /api/game/tick`), not only `GET /api/game/tasks`.

## Related

- Live skill: `https://slc.discernible.io:8443/api/game/skill.md`
- `EMAIL.md` — Himalaya send/inbox SOP
- `./identyclaw.sh enable-slc-heartbeat` / `IDENTYCLAW_ENABLE_SLC_HEARTBEAT` — always-on alternative (fleet config)
- `knowledge/references/concierge-inbox-heartbeat.md` — inbox polling (different duty)
