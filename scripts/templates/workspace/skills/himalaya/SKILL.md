---
name: himalaya
description: "Migadu/Himalaya email for this Concierge deployment — list, read, reply via workspace scripts."
---

# Email (IdentyClaw Concierge — {{AGENT_ID}})

**This overrides the generic Himalaya skill.** Mail is pre-configured — do **not** run `himalaya account configure`.

Read **`EMAIL.md`** and **`AGENTS.md` → Inbound email (concierge)** before any inbox task.

## List inbox (helpers include sender email addresses)

```bash
sh scripts/himalaya-inbox.sh 10
```

Output columns: `ID`, sender **email address**, name, subject, date.

**Never** use plain `himalaya envelope list` without `--output json` — the default table shows names only, not addresses.

## Read message

```bash
sh scripts/himalaya-read.sh <ID>
```

The `From:` header has the reply address.

## Reply (concierge duty — send, do not summarize internally)

When the operator asks you to check/reply to inbox mail, **that is approval**. Periodic
check requests (hourly, etc.) are **standing approval** — enable the `inbox-check` task in
`workspace/HEARTBEAT.md` and set `openclaw.json` heartbeat interval per **EMAIL.md**.

For each in-scope message:

1. `sh scripts/himalaya-inbox.sh 10`
2. `sh scripts/himalaya-read.sh <ID>`
3. `memory_search` / `identyclaw_get_resource` for factual answers
4. `sh scripts/himalaya-send.sh SENDER "Re: SUBJECT" "BODY"`

**You must run step 4 and see `Message successfully sent!` before reporting a reply as sent.**

**Never:**
- Ask the operator for the sender's email (you have it from steps 1–2)
- Say you will "process internally" instead of emailing the sender
- Use `himalaya message reply` / `message write` (no `$EDITOR` in this container)
- Use `himalaya envelope view` (does not exist)
- Call bare `himalaya message send` with empty stdin, `</dev/null`, or a partial pipe — that **panics** (`mail-parser` index out of bounds). Prefer `scripts/himalaya-send.sh` only.

## Send

```bash
sh scripts/himalaya-send.sh recipient@example.com "Subject" "Body"
```

Success prints `Message successfully sent!`. If you see a `mail-parser` panic, you fed empty/invalid stdin — retry with the helper above; do **not** conclude SMTP is broken. A hang with no output is a connectivity issue (host SMTP pin), not a parser bug.

**Critical:** `From:` must be `{{EMAIL}}` ({{DISPLAY_NAME}}). Migadu rejects other senders.

## Delete

```bash
himalaya message delete <ID>
```
