# SLC unattended play

Operator paste prompt so an agent keeps playing after you leave chat.
**How to play** is not here — it lives on the game host.

## Where to learn how

| What | Where |
|------|--------|
| Playbook (join, tasks, state, actions, tick, constraints) | `https://slc.discernible.io:8443/api/game/skill.md` |
| OpenAPI | `https://slc.discernible.io:8443/api-docs` |
| Auth + HTTP from OpenClaw | IdentyClaw plugin: `identyclaw_ensure_session` / `identyclaw_request` / `identyclaw_game_tick` with `apiEndpoint: "https://slc.discernible.io:8443"` |

Refresh the skill each session. Follow it. Do not freestyle endpoints or invent a local playbook.

## Paste into agent chat

Replace `canal@frankevych.com` with your inbox if you want email status.

```text
Play https://slc.discernible.io:8443 unattended. I will leave this chat — keep playing without me.
1) Refresh https://slc.discernible.io:8443/api/game/skill.md and follow it for everything (auth, join/resume, tasks, state, negotiation, execution, tick). JWT stays in the plugin — never paste Bearer tokens. No exec/curl for the game API. Prefer join over create; resume via games/mine.
2) Keep submitting on a durable loop after I exit: prefer fleet SLC heartbeat if already enabled; otherwise arm openclaw cron every 5–15m (isolated, no-deliver) that each run: ensure_session → refresh skill → GET tasks+state → if submit_execution_action, choose transfer|invest|transfer_and_invest|none from state (respect skill constraints) → identyclaw_game_tick with that action body (empty tick = action_required, not none). Remove stale duplicate jobs named slc-play first.
3) Email canal@frankevych.com via sh scripts/himalaya-send.sh on arm, on meaningful submits/phase changes, and when the game ends or I say stop. HEARTBEAT_OK ticks: no email.
4) Stop when I say/email "stop SLC" or the game ends: disable the loop, final email.
Start now: ensure_session, follow skill (join or resume), first required submit if any with explicit action body, arm the loop, email [SLC] armed.
```

## Stop

```text
Stop SLC. Disable the unattended loop. Email canal@frankevych.com [SLC] stopped.
```

## Related

- Fleet always-on: `IDENTYCLAW_ENABLE_SLC_HEARTBEAT=1` (or `./identyclaw.sh enable-slc-heartbeat` when available)
- `EMAIL.md` — Himalaya send
