# Concierge inbox heartbeat (LLM periodic email replies)

Enable LLM-driven inbox polling so the concierge reads inbound mail and sends
direct replies per `EMAIL.md` and `AGENTS.md` → Inbound email (concierge).

## Primary command (recommended)

```bash
./identyclaw.sh enable-inbox-check <agent-id> [interval]
```

Examples:

```bash
./identyclaw.sh enable-inbox-check agent-l 1h
./identyclaw.sh enable-inbox-check agent-a 30m
```

Then restart the agent:

```bash
./identyclaw.sh restart <agent-id>
```

## What enable-inbox-check configures

- Adds or updates the `inbox-check` task in `workspace/HEARTBEAT.md`
- Sets `agents.defaults.heartbeat.every` in `openclaw.json` to the same interval
- Persists the interval in `secrets/inbox-heartbeat.interval` (re-applied on bootstrap/restart/rebuild)

Default interval when omitted: `1h`.

## Concierge duty during heartbeat

On each inbox-check tick the agent should:

1. Read `EMAIL.md`
2. Run `sh scripts/himalaya-inbox.sh 10`
3. For each new in-scope message: `memory_search` / `identyclaw_get_resource` first
4. Reply via `scripts/himalaya-send.sh` — do not stop at an internal summary
5. Skip `IDENTYCLAW_HOLA_PROBE:*` (deterministic responder handles those)
6. Reply `HEARTBEAT_OK` when nothing needs attention

## Environment alternative (before bootstrap/restart)

Per-agent:

```bash
AGENT_L_ENABLE_INBOX_HEARTBEAT=1
AGENT_L_INBOX_HEARTBEAT_INTERVAL=1h
```

Global:

```bash
IDENTYCLAW_ENABLE_INBOX_HEARTBEAT=1
IDENTYCLAW_INBOX_HEARTBEAT_INTERVAL=1h
```

## Related (not the same as inbox heartbeat)

- `./identyclaw.sh enable-mail-responder` — deterministic HOLA probe replies (cron/timer)
- `EMAIL.md` — full concierge email SOP
