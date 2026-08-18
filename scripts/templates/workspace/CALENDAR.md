# Calendar and reminders

Events live in `workspace/calendar/events.json` (local JSON — no Google login required).
Precise alerts use OpenClaw **automations** (`cron` tool). Heartbeat only sweeps the next day.

## Operator setup

```bash
./identyclaw.sh set-telegram-token <agent-id>   # optional delivery channel
./identyclaw.sh set-discord-token <agent-id>    # optional delivery channel
./identyclaw.sh enable-calendar-check <agent-id> 30m
./identyclaw.sh restart <agent-id>
```

## Agent SOP

1. Read this file and `skills/calendar-reminders/SKILL.md`.
2. Create/list/cancel with `sh scripts/calendar.sh …` (plain `exec`, no `elevated`).
3. After `add`, create one automation per reminder offset and `calendar.sh set-jobs`.
4. Deliver via Telegram or Discord when those channels are enabled; otherwise the current chat or email.
5. On heartbeat task `calendar-upcoming`: `sh scripts/calendar.sh upcoming 24`. Empty → `HEARTBEAT_OK`.

Do not use `sleep` or polling loops as a reminder clock.

Optional Google Calendar: only if ClawLink `googlecalendar_*` tools are installed and paired.
