---
name: calendar-reminders
description: Local calendar and reminders using workspace JSON plus OpenClaw automations. Use when the user asks to schedule, list, update, cancel, or remind — including Telegram/Discord/email delivery.
---

# Calendar and reminders

This agent stores events in **`workspace/calendar/events.json`** (no Google account required). Precise alerts use OpenClaw **automations** (`cron` tool — same as `openclaw automations`). Heartbeat only sweeps upcoming items; it is not the scheduler.

Read **`CALENDAR.md`** first.

## Store and query (plain exec, no elevated)

```bash
sh scripts/calendar.sh list
sh scripts/calendar.sh upcoming 24
sh scripts/calendar.sh add --title "Standup" --at "2026-08-18T09:00:00Z" --remind 60,10
sh scripts/calendar.sh get <event-id>
sh scripts/calendar.sh ack <event-id>
sh scripts/calendar.sh cancel <event-id>
```

`--at` is ISO-8601. Default timezone is `UTC` unless `CALENDAR.md` or `IDENTYCLAW_CALENDAR_TZ` says otherwise. Reminder offsets are minutes before start (`1440,60,10` = 24h / 1h / 10m).

## Fire reminders (required)

After `calendar.sh add`, create one OpenClaw automation **per reminder offset** with the `cron` / automations tool:

- One-shot: `--at` the reminder instant (start minus offset).
- Recurring events: `--cron` (or `--every`) matching the repeat.
- Delivery: `--announce` plus `--channel telegram|discord` and `--to <chat-or-user-id>` when that channel is enabled; otherwise announce to the current chat, or email via Himalaya if the operator asked for mail.
- Payload: short reminder text with title, start time, and event id. Ask the user to reply `ack` / `got it` (then run `calendar.sh ack <id>`).

Store returned job ids with:

```bash
sh scripts/calendar.sh set-jobs <event-id> job1,job2
```

On cancel, remove those automations, then `calendar.sh cancel`.

Never emulate reminders with `sleep`, polling loops, or heartbeat-only timing.

## Heartbeat

If `HEARTBEAT.md` has `calendar-upcoming`, list the next 24h with `calendar.sh upcoming 24`. Mention anything starting soon that is still unacked. If the store is empty or nothing is due, reply `HEARTBEAT_OK`.

## Google Calendar (optional)

Do **not** invent a Google integration. Only use ClawLink `googlecalendar_*` tools if that plugin is installed and paired. Local `calendar.sh` remains the default.
