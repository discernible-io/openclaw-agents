#!/usr/bin/env bash
# Workspace files, email/Himalaya, calendar, concierge, SLC, wallet scripts.
# Sourced from scripts/lib.sh — do not execute directly.

detect_himalaya_arch() {
  local machine
  machine="$(uname -m)"
  case "$machine" in
    x86_64|amd64) echo "x86_64-linux" ;;
    aarch64|arm64) echo "aarch64-linux" ;;
    armv7l) echo "armv7l-linux" ;;
    i686|i386) echo "i686-linux" ;;
    *) echo "ERROR: unsupported CPU for Himalaya binary: $machine" >&2; exit 1 ;;
  esac
}


agent_smtp_settings() {
  local id="$1"
  local port enc
  load_env
  is_valid_agent_id "$id" || { echo "587|start-tls"; return 0; }
  port="$(agent_env_value "$id" SMTP_PORT "")"
  enc="$(agent_env_value "$id" SMTP_ENCRYPTION "")"
  echo "${port:-587}|${enc:-start-tls}"
}


write_himalaya_config() {
  local email="$1"
  local display_name="$2"
  local config_dir="$3"
  local id smtp_port smtp_enc smtp_settings
  id="$(basename "$config_dir")"
  smtp_settings="$(agent_smtp_settings "$id")"
  smtp_port="${smtp_settings%%|*}"
  smtp_enc="${smtp_settings#*|}"
  mkdir -p "$config_dir/.config/himalaya"
  cat >"$config_dir/.config/himalaya/config.toml" <<EOF
[accounts.default]
email = "${email}"
display-name = "${display_name}"
default = true

backend.type = "imap"
backend.host = "imap.migadu.com"
backend.port = 993
backend.encryption.type = "tls"
backend.login = "${email}"
backend.auth.type = "password"
backend.auth.cmd = "/home/node/.openclaw/secrets/imap.sh"

message.send.backend.type = "smtp"
message.send.backend.host = "smtp.migadu.com"
message.send.backend.port = ${smtp_port}
message.send.backend.encryption.type = "${smtp_enc}"
message.send.backend.login = "${email}"
message.send.backend.auth.type = "password"
message.send.backend.auth.cmd = "/home/node/.openclaw/secrets/smtp.sh"

[accounts.default.folder.alias]
inbox = "INBOX"
sent = "Sent"
drafts = "Drafts"
trash = "Trash"
EOF
  chmod 600 "$config_dir/.config/himalaya/config.toml"
}


write_himalaya_send_script() {
  local email="$1"
  local display_name="$2"
  local config_dir="$3"
  mkdir -p "$config_dir/workspace/scripts"
  cat >"$config_dir/workspace/scripts/himalaya-send.sh" <<EOF
#!/bin/sh
# Headless outbound mail via Himalaya (no \$EDITOR). Containers have no editor binary.
# Usage: sh scripts/himalaya-send.sh TO SUBJECT [BODY]
set -eu
TO="\${1:?usage: himalaya-send.sh TO SUBJECT [BODY]}"
SUBJECT="\${2:?usage: himalaya-send.sh TO SUBJECT [BODY]}"
BODY="\${3:-}"

himalaya message send <<MAIL
From: ${display_name} <${email}>
To: \${TO}
Subject: \${SUBJECT}

\${BODY}
MAIL
EOF
  chmod 755 "$config_dir/workspace/scripts/himalaya-send.sh"
}


write_himalaya_delete_script() {
  local config_dir="$1"
  mkdir -p "$config_dir/workspace/scripts"
  cat >"$config_dir/workspace/scripts/himalaya-delete.sh" <<'EOF'
#!/bin/sh
# Delete message(s) by envelope ID, or all INBOX messages with --all.
# Usage: sh scripts/himalaya-delete.sh <ID>...
#        sh scripts/himalaya-delete.sh --all
set -eu

if [ "$#" -eq 1 ] && [ "$1" = "--all" ]; then
  ids=$(himalaya envelope list --folder INBOX --output json | node -e '
    const items = JSON.parse(require("fs").readFileSync(0, "utf8"));
    if (!Array.isArray(items) || items.length === 0) process.exit(0);
    process.stdout.write(items.map((e) => e.id).join(" "));
  ')
  if [ -z "$ids" ]; then
    echo "No messages in INBOX"
    exit 0
  fi
  set -- $ids
fi

if [ "$#" -eq 0 ]; then
  echo "usage: himalaya-delete.sh <ID>... | --all" >&2
  exit 1
fi

himalaya message delete "$@"
EOF
  chmod 755 "$config_dir/workspace/scripts/himalaya-delete.sh"
}


write_himalaya_inbox_script() {
  local config_dir="$1"
  mkdir -p "$config_dir/workspace/scripts"
  cat >"$config_dir/workspace/scripts/himalaya-inbox.sh" <<'EOF'
#!/bin/sh
# List INBOX with sender email addresses (plain table omits addr).
# Usage: sh scripts/himalaya-inbox.sh [PAGE_SIZE]
set -eu
PAGE_SIZE="${1:-10}"
himalaya envelope list --folder INBOX --page-size "$PAGE_SIZE" --output json | node -e '
const rows = JSON.parse(require("fs").readFileSync(0, "utf8"));
if (!Array.isArray(rows) || rows.length === 0) {
  console.log("INBOX is empty");
  process.exit(0);
}
for (const e of rows) {
  const from = e.from?.addr || "?";
  const name = e.from?.name || "";
  console.log(`ID ${e.id}\t${from}\t${name}\t${e.subject}\t${e.date || ""}`);
}
'
EOF
  chmod 755 "$config_dir/workspace/scripts/himalaya-inbox.sh"
}


write_himalaya_read_script() {
  local config_dir="$1"
  mkdir -p "$config_dir/workspace/scripts"
  cat >"$config_dir/workspace/scripts/himalaya-read.sh" <<'EOF'
#!/bin/sh
# Read full message (headers + body). Use for From: address and content.
# Usage: sh scripts/himalaya-read.sh <ID>
set -eu
ID="${1:?usage: himalaya-read.sh <ID>}"
himalaya message read "$ID" --output plain
EOF
  chmod 755 "$config_dir/workspace/scripts/himalaya-read.sh"
}

# Workspace skill overrides bundled /app/skills/himalaya (which omits sender addresses and concierge reply duty).

# Workspace skill overrides bundled /app/skills/himalaya (which omits sender addresses and concierge reply duty).
_himalaya_workspace_skill_markdown() {
  local email="$1"
  local display_name="$2"
  local agent_id="$3"
  cat <<EOF
---
name: himalaya
description: "Migadu/Himalaya email for this Concierge deployment — list, read, reply via workspace scripts."
---

# Email (IdentyClaw Concierge — ${agent_id})

**This overrides the generic Himalaya skill.** Mail is pre-configured — do **not** run \`himalaya account configure\`.

Read **\`EMAIL.md\`** and **\`AGENTS.md\` → Inbound email (concierge)** before any inbox task.

## List inbox (helpers include sender email addresses)

\`\`\`bash
sh scripts/himalaya-inbox.sh 10
\`\`\`

Output columns: \`ID\`, sender **email address**, name, subject, date.

**Never** use plain \`himalaya envelope list\` without \`--output json\` — the default table shows names only, not addresses.

## Read message

\`\`\`bash
sh scripts/himalaya-read.sh <ID>
\`\`\`

The \`From:\` header has the reply address.

## Reply (concierge duty — send, do not summarize internally)

When the operator asks you to check/reply to inbox mail, **that is approval**. Periodic
check requests (hourly, etc.) are **standing approval** — enable the \`inbox-check\` task in
\`workspace/HEARTBEAT.md\` and set \`openclaw.json\` heartbeat interval per **EMAIL.md**.

For each in-scope message:

1. \`sh scripts/himalaya-inbox.sh 10\`
2. \`sh scripts/himalaya-read.sh <ID>\`
3. \`memory_search\` / \`identyclaw_get_resource\` for factual answers
4. \`sh scripts/himalaya-send.sh SENDER "Re: SUBJECT" "BODY"\`

**You must run step 4 and see \`Message successfully sent!\` before reporting a reply as sent.**

**Never:**
- Ask the operator for the sender's email (you have it from steps 1–2)
- Say you will "process internally" instead of emailing the sender
- Use \`himalaya message reply\` / \`message write\` (no \`\$EDITOR\` in this container)
- Use \`himalaya envelope view\` (does not exist)

## Send

\`\`\`bash
sh scripts/himalaya-send.sh recipient@example.com "Subject" "Body"
\`\`\`

**Critical:** \`From:\` must be \`${email}\` (${display_name}). Migadu rejects other senders.

## Delete

\`\`\`bash
himalaya message delete <ID>
\`\`\`
EOF
}


write_himalaya_workspace_skill() {
  local config_dir="$1"
  local email="$2"
  local display_name="$3"
  local agent_id="$4"
  mkdir -p "$config_dir/workspace/skills/himalaya"
  _himalaya_workspace_skill_markdown "$email" "$display_name" "$agent_id" \
    >"$config_dir/workspace/skills/himalaya/SKILL.md"
  chmod 644 "$config_dir/workspace/skills/himalaya/SKILL.md"
}

# SOUL.md defaults warn against email; Concierge agents must reply to inbound mail.

# SOUL.md defaults warn against email; Concierge agents must reply to inbound mail.
patch_soul_concierge_inbound_email() {
  local config_dir="$1"
  local soul="$config_dir/workspace/SOUL.md"
  [[ -f "$soul" ]] || return 0
  python3 - "$soul" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
replacements = [
    (
        "**Earn trust through competence.** Your human gave you access to their stuff. Don't make them regret it. Be careful with external actions (emails, tweets, anything public). Be bold with internal ones (reading, organizing, learning).",
        "**Earn trust through competence.** Your human gave you access to their stuff. Don't make them regret it. Be careful with **unsolicited** external actions (cold email, tweets, anything public). **Inbound email replies are your Concierge job** — see `EMAIL.md`. Be bold with reading, organizing, and learning.",
    ),
    (
        "- When in doubt, ask before acting externally.",
        "- When in doubt about **unsolicited** outbound actions, ask first. Inbound inbox replies requested by the operator are pre-approved (see `EMAIL.md`).",
    ),
]
for old, new in replacements:
    if old in text:
        text = text.replace(old, new, 1)
block = """
## Inbound email (Concierge deployment)

Your inbox is a **concierge channel**. Replying to senders is **in scope** — not a cautious
"external action" to avoid. Use `scripts/himalaya-inbox.sh` / `scripts/himalaya-read.sh`
for sender addresses; **never** ask the operator for an address you can read from the message.
Do not "process internally" when a direct email reply is what the sender expects.
"""
if "## Inbound email (Concierge deployment)" not in text:
    text = text.rstrip() + block + "\n"
path.write_text(text, encoding="utf-8")
PY
}

# Shared EMAIL.md fragment — keep write_agent_email_doc and _sync_agent_email_tooling_in_container aligned.

# Shared EMAIL.md fragment — keep write_agent_email_doc and _sync_agent_email_tooling_in_container aligned.
_email_read_inbox_doc_block() {
  cat <<'EOF'
## Read inbox

**Use the helpers** (recommended — include sender email addresses):

```bash
sh scripts/himalaya-inbox.sh 10          # ID, from-addr, name, subject, date
sh scripts/himalaya-read.sh <ID>         # full message; From: line has reply address
```

Raw Himalaya (same data):

```bash
himalaya envelope list --folder INBOX --page-size 10 --output json   # from.addr in JSON
himalaya message read <ID> --output plain                          # never envelope view
```

**Common mistakes:**
- There is **no** `himalaya envelope view` — use `message read <ID>` or `scripts/himalaya-read.sh`.
- Plain `himalaya envelope list` (table) shows sender **names only**, not email addresses.
- **Never** ask the operator for a sender's email if you have the message ID — read the message.
- `himalaya message reply` / `message write` need `$EDITOR` and **fail** headless — use `scripts/himalaya-send.sh`.
EOF
}


write_agent_email_doc() {
  local email="$1"
  local display_name="$2"
  local config_dir="$3"
  local id smtp_port smtp_settings
  id="$(basename "$config_dir")"
  smtp_settings="$(agent_smtp_settings "$id")"
  smtp_port="${smtp_settings%%|*}"
  mkdir -p "$config_dir/workspace"
  cat >"$config_dir/workspace/EMAIL.md" <<EOF
# Email (Himalaya / Migadu)

- **Account:** \`${email}\` (${display_name})
- **Config:** \`/home/node/.config/himalaya/config.toml\`
- **IMAP/SMTP:** Migadu (\`imap.migadu.com:993\`, \`smtp.migadu.com:${smtp_port}\`)

$(_email_read_inbox_doc_block)

## Delete (move to Trash)

There is **no** \`himalaya envelope delete\` command. Envelope IDs come from
\`envelope list\`, but deletion uses the **message** subcommand:

\`\`\`bash
himalaya message delete <ID>
himalaya message delete 1 2 3
sh scripts/himalaya-delete.sh --all
\`\`\`

Confirm with the user before deleting many messages. \`message delete\` moves
messages to Trash (IMAP \`\\Deleted\`); it does not permanently expunge them.

## Send (headless — required in this container)

There is **no \`\$EDITOR\`** in the gateway container, so \`himalaya message write\` always fails.
Use the helper or raw send:

\`\`\`bash
sh scripts/himalaya-send.sh recipient@example.com "Subject" "Body"
\`\`\`

Or:

\`\`\`bash
himalaya message send <<MAIL
From: ${display_name} <${email}>
To: recipient@example.com
Subject: Your subject

Your body
MAIL
\`\`\`

**Critical:** \`From:\` must be \`${email}\`. Migadu rejects other senders (553 *Sender address rejected*).

## Inbound HOLA probes (reciprocal testing)

Peers verify us over email the same way we verify them: they send an
\`IDENTYCLAW_HOLA_PROBE:{id}:{variant}\` email with a HOLA line, and expect a
\`HOLA_RESPONSE:{id}:{variant}\` reply. This is handled automatically by the
deterministic responder — no LLM action needed:

\`\`\`bash
# On the host (single agent or all):
./identyclaw.sh respond-mail ${id}
# Or run it on a schedule (user systemd timer, default every 5min):
./identyclaw.sh enable-mail-responder
\`\`\`

When a peer drives reciprocal testing via **A2A** (\`IDENTYCLAW_SMOKE inbound email HOLA test\`),
the deterministic A2A HOLA smoke responder signs and sends the probe email (no LLM):

\`\`\`bash
./identyclaw.sh respond-a2a-hola-smoke ${id}
./identyclaw.sh enable-a2a-hola-smoke-responder
\`\`\`

The responder only replies with a signed HOLA when the inbound HOLA verifies; a
tampered probe gets a rejection reply with no credential. If the responder is not
scheduled, inbound email HOLA tests from peers will time out.

## Reply to inbound messages (concierge)

Your inbox is a **concierge channel**. When someone emails you, replying to them
**is in scope** — do not treat IdentyClaw-related mail as "internal only" and skip
a direct reply.

1. \`sh scripts/himalaya-inbox.sh 10\` — list messages with sender **email addresses**
2. \`sh scripts/himalaya-read.sh <ID>\` — read body; copy \`From:\` address for the reply
3. Compose the answer (for product questions: \`memory_search\` / \`identyclaw_get_resource\`
   first, then cite sources in the reply body)
4. \`sh scripts/himalaya-send.sh SENDER "Re: SUBJECT" "BODY"\` — **never** ask the operator
   for the sender's email when you have the message ID

**Operator main session:** when the operator asks you to check the inbox and answer or
reply to received emails, that **is** operator approval — send the replies, then
summarize what you sent.

**Periodic checks (heartbeat):** when the operator asks you to check the inbox on a
schedule (e.g. hourly), you **can** enable recurring checks via OpenClaw heartbeat:

1. Add or update the \`inbox-check\` task in \`workspace/HEARTBEAT.md\` (interval matches
   the requested cadence, default \`1h\`)
2. Set \`agents.defaults.heartbeat.every\` in \`openclaw.json\` to the same interval
3. Run an immediate inbox check now
4. If you changed \`openclaw.json\`, tell the operator: \`./identyclaw.sh restart ${id}\`

**Standing approval:** periodic inbox check requests count as operator approval for
concierge replies in heartbeat/isolated sessions until they say otherwise.

**Host shortcut:** \`./identyclaw.sh enable-inbox-check ${id} [interval]\`

\`enable-mail-responder\` is **only** for deterministic HOLA probe replies — not LLM inbox
review.

**HOLA probes** (\`IDENTYCLAW_HOLA_PROBE:*\`) are handled by the deterministic
responder above — do not duplicate.

**Never** refuse an in-scope inbound email by claiming you will "process it internally".
Searching the KB composes the answer; **sending the email is the concierge service**.
EOF
  chmod 644 "$config_dir/workspace/EMAIL.md"
  write_email_workspace_guidance "$config_dir" "$email" "$id"
}

# Shared markdown for AGENTS.md — concierge must reply to inbound mail, not only search KB.

# Shared markdown for AGENTS.md — concierge must reply to inbound mail, not only search KB.
_concierge_inbound_email_agents_block() {
  cat <<'EOF'
## Inbound email (concierge)

Your **inbox is a concierge channel**. Replying to senders **is in scope** for
IdentyClaw-related mail — do not treat it as "internal only" and skip a direct reply.

- **Operator main session:** when the operator asks you to check the inbox, answer
  received emails, or reply to a sender — that **is** operator approval. Read each
  message, send replies (see `EMAIL.md`), then summarize what you sent.
- **Periodic checks:** when the operator asks for scheduled inbox checks (hourly, etc.),
  enable heartbeat per `EMAIL.md` → Periodic inbox checks. Standing approval for replies
  in heartbeat/isolated sessions until they say otherwise.
- **In-scope inbound mail:** use `memory_search` / `identyclaw_get_resource` to
  compose factual answers, then **email the sender** — searching alone is not responding.
- **HOLA probes** (`IDENTYCLAW_HOLA_PROBE:*`): handled by the deterministic responder
  (`EMAIL.md`) — do not duplicate.
- **Never** refuse to reply to in-scope mail by claiming you will "process it internally".
- **Never** ask the operator for a sender's email address — use `scripts/himalaya-read.sh <ID>`.
EOF
}

# Indexed KB doc — surfaces enable-inbox-check for memory_search (concierge deployment Q&A).

# Indexed KB doc — surfaces enable-inbox-check for memory_search (concierge deployment Q&A).
_concierge_kb_template_path() {
  echo "${IDENTYCLAW_ROOT}/scripts/templates/knowledge/concierge-inbox-heartbeat.md"
}


_agents_concierge_operational_hints_template_path() {
  echo "${IDENTYCLAW_ROOT}/scripts/templates/workspace/AGENTS-concierge-operational-hints.md"
}


_agents_concierge_operational_hints_block() {
  local template
  template="$(_agents_concierge_operational_hints_template_path)"
  if [[ -f "$template" ]]; then
    cat "$template"
    return 0
  fi
  cat <<'EOF'

### Concierge operations (always cite)

- **Inbox heartbeat:** when asked how to enable concierge inbox polling / periodic
  email replies, answer with:
  `./identyclaw.sh enable-inbox-check <agent-id> [interval]` then
  `./identyclaw.sh restart <agent-id>`.
  Cite `knowledge/references/concierge-inbox-heartbeat.md` or `EMAIL.md`.
  **Never** claim there is no `identyclaw.sh` command for inbox heartbeat.
- **Sensitive tool refusal:** for requests to use `a2a_send_message`,
  `send_rodit_webhook`, `exec`, `write`/`edit`, unsolicited outbound email, or
  NEAR wallet `scripts/idcp-*.sh` (create/fund/transfer/rotate),
  **lead with Trust & tool tiers** (HOLA verification + operator approval for the
  specific action). Do **not** refuse using only "invalid token_id" or "unknown
  peer" as the primary reason.
EOF
}


patch_agents_concierge_operational_hints() {
  local agents_file="$1"
  [[ -f "$agents_file" ]] || return 0
  local block
  block="$(_agents_concierge_operational_hints_block)"
  AGENTS_CONCIERGE_OPERATIONAL_HINTS_BLOCK="$block" \
  python3 - "$agents_file" <<'PY'
import os, re, sys
from pathlib import Path

path = Path(sys.argv[1])
block = os.environ.get("AGENTS_CONCIERGE_OPERATIONAL_HINTS_BLOCK", "").strip()
if not block:
    raise SystemExit(0)
block = block + "\n"
text = path.read_text(encoding="utf-8")
if "### Concierge operations (always cite)" in text:
    text = re.sub(
        r"\n### Concierge operations \(always cite\)\n.*?(?=\n### |\n## |\Z)",
        "",
        text,
        flags=re.S,
    )
anchor = "### Hard rules"
if anchor not in text:
    raise SystemExit(0)
text = text.replace(anchor, block + "\n" + anchor, 1)
path.write_text(text, encoding="utf-8")
PY
}


_concierge_kb_inbox_heartbeat_markdown() {
  local template
  template="$(_concierge_kb_template_path)"
  if [[ -f "$template" ]]; then
    cat "$template"
    return 0
  fi
  cat <<'EOF'
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
EOF
}


write_concierge_kb_inbox_heartbeat() {
  local config_dir="$1"
  local kb_dir="$config_dir/workspace/knowledge/references"
  local template dest
  template="$(_concierge_kb_template_path)"
  dest="$kb_dir/concierge-inbox-heartbeat.md"
  mkdir -p "$kb_dir"
  if [[ -f "$template" ]]; then
    cp -f "$template" "$dest"
  else
    _concierge_kb_inbox_heartbeat_markdown >"$dest"
  fi
  chmod 644 "$dest"
  _patch_concierge_kb_scope "$config_dir/workspace/knowledge/SCOPE.md"
}


_patch_concierge_kb_scope() {
  local scope_file="$1"
  [[ -f "$scope_file" ]] || return 0
  python3 - "$scope_file" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
needle = "- Concierge inbox heartbeat (`./identyclaw.sh enable-inbox-check`)"
if needle in text:
    sys.exit(0)
anchor = "- Migadu email / Himalaya skill (when documented here)"
if anchor not in text:
    sys.exit(0)
text = text.replace(
    anchor,
    anchor + "\n" + needle,
    1,
)
path.write_text(text, encoding="utf-8")
PY
}


_write_concierge_kb_inbox_heartbeat_in_container() {
  local container="$1"
  local template tmp
  template="$(_concierge_kb_template_path)"
  [[ -f "$template" ]] || return 1
  tmp="$(mktemp)"
  cp -f "$template" "$tmp"
  podman exec "$container" mkdir -p /home/node/.openclaw/workspace/knowledge/references
  podman cp "$tmp" "$container:/home/node/.openclaw/workspace/knowledge/references/concierge-inbox-heartbeat.md"
  rm -f "$tmp"
  podman exec "$container" chmod 644 /home/node/.openclaw/workspace/knowledge/references/concierge-inbox-heartbeat.md
  podman exec -i "$container" python3 - <<'PY'
import os

workspace = "/home/node/.openclaw/workspace"
scope_path = os.path.join(workspace, "knowledge", "SCOPE.md")
if not os.path.isfile(scope_path):
    raise SystemExit(0)
with open(scope_path, encoding="utf-8") as f:
    scope = f.read()
needle = "- Concierge inbox heartbeat (`./identyclaw.sh enable-inbox-check`)"
anchor = "- Migadu email / Himalaya skill (when documented here)"
if needle not in scope and anchor in scope:
    scope = scope.replace(anchor, anchor + "\n" + needle, 1)
    with open(scope_path, "w", encoding="utf-8") as f:
        f.write(scope)
PY
}


write_email_workspace_guidance() {
  local config_dir="$1"
  local email="$2"
  local agent_id="${3:-$(basename "$config_dir")}"
  local tools="$config_dir/workspace/TOOLS.md"
  local agents="$config_dir/workspace/AGENTS.md"
  local inbound_block refusal_block hints_block
  inbound_block="$(_concierge_inbound_email_agents_block)"
  refusal_block="$(_agents_sensitive_tool_refusal_block)"
  hints_block="$(_agents_concierge_operational_hints_block)"
  [[ -f "$tools" ]] || [[ -f "$agents" ]] || return 0
  CONCIERGE_INBOUND_EMAIL_AGENTS_BLOCK="$inbound_block" \
  AGENTS_SENSITIVE_TOOL_REFUSAL_BLOCK="$refusal_block" \
  AGENTS_CONCIERGE_OPERATIONAL_HINTS_BLOCK="$hints_block" \
  python3 - "$tools" "$agents" "$email" "$agent_id" <<'PY'
import os, re, sys
from pathlib import Path

tools_path, agents_path, email, agent_id = sys.argv[1:5]
inbound_block = os.environ["CONCIERGE_INBOUND_EMAIL_AGENTS_BLOCK"].strip()
tools_block = f"""
## Email ({agent_id})

- **Mail is pre-configured** — read **`EMAIL.md`** before any inbox task.
- **Account:** `{email}` (Migadu / Himalaya). Do **not** ask for IMAP/SMTP/password.
- **List:** `sh scripts/himalaya-inbox.sh 10` (includes sender email; plain `exec`, no `elevated`)
- **Read:** `sh scripts/himalaya-read.sh <ID>` (full message + From: address)
- **Delete:** `himalaya message delete <ID>` (plain `exec`, no `elevated`)
- **Reply:** read message, then `sh scripts/himalaya-send.sh SENDER "Re: SUBJECT" "BODY"`
- **Never** use `envelope view` (does not exist) or ask the operator for a sender address
- **Send:** `sh scripts/himalaya-send.sh RECIPIENT SUBJECT BODY` — arg1 is **To only** (never `{email}`)
- **Do not** pass `elevated: true` on exec — fails in webchat/TUI.
- In-scope inbound mail must get a **direct reply to the sender** — see **Inbound email (concierge)**.
- **Exec / interpreters:** Prefer scripts over large `node -e` / `python -c`. Write `/tmp/foo.js` (or `.py`), then `node /tmp/foo.js` / `python3 /tmp/foo.py`. Stream filters (`head`/`tail`/`wc`/…) and allowlisted `sed` do not need approval.
"""
agents_block = f"""
## Email

- Mail **is already configured** via Himalaya — read **`EMAIL.md`** first on any email task.
- **Account:** `{email}`. Credentials live in the container; **never** ask the operator for them.
- Read/delete/reply via plain `exec` (no `elevated: true`) — `scripts/himalaya-inbox.sh`, `scripts/himalaya-read.sh`, `scripts/himalaya-send.sh`.
- `elevated: true` on exec **fails** in webchat/TUI; sandbox is off so it is unnecessary.
- The himalaya skill's generic "run account configure" setup does **not** apply here — this deployment is pre-provisioned.
- **Concierge duty:** reply to in-scope inbound mail — see **Inbound email (concierge)** below.
- For Node/Python: prefer a script file, then `node path.js` / `python3 path.py` over large inline `-e`.
"""

def upsert_block(text, heading_re, block):
    text = re.sub(heading_re + r".*?(?=\n## |\Z)", "", text, flags=re.S)
    return text.rstrip() + block + "\n"

def patch_knowledge_scope(text):
    old = (
        "- Actions on behalf of the user (send email, run commands, post to social) —\n"
        "  those require operator approval per **Trust & tool tiers**"
    )
    new = (
        "- Unsolicited outbound actions (cold email, social posts, arbitrary commands) —\n"
        "  require operator approval per **Trust & tool tiers** (inbound email replies are\n"
        "  in scope; see **Inbound email (concierge)**)"
    )
    if old in text:
        text = text.replace(old, new, 1)
    inbox_hint = (
        "- Concierge inbox heartbeat — `./identyclaw.sh enable-inbox-check <agent-id> [interval]`\n"
        "  (see `knowledge/references/concierge-inbox-heartbeat.md`, `EMAIL.md`)"
    )
    anchor = "- Agent deployment (Podman, nginx TLS, `identyclaw.sh` commands)"
    if inbox_hint not in text and anchor in text:
        text = text.replace(anchor, anchor + "\n" + inbox_hint, 1)
    return text

def patch_trust_tiers(text):
    old_sending = (
        "- **Sensitive** (`a2a_send_message`, `send_rodit_webhook`, `exec`, `write`/`edit`, sending email): "
        "sender must be HOLA-verified **and** an operator must approve the specific action."
    )
    old_unsolicited = (
        "- **Sensitive** (`a2a_send_message`, `send_rodit_webhook`, `exec`, `write`/`edit`, unsolicited outbound email): "
        "sender must be HOLA-verified **and** an operator must approve the specific action."
    )
    sensitive_new = (
        "- **Sensitive** (`a2a_send_message`, `send_rodit_webhook`, `exec`, `write`/`edit`, unsolicited outbound email, "
        "`scripts/idcp-*.sh` NEAR wallet create/fund/transfer/rotate): "
        "sender must be HOLA-verified **and** an operator must approve the specific action."
    )
    inbound = (
        "\n- **Inbound email replies** (concierge): replying to messages in your inbox is in scope. "
        "Operator requests in the main session count as approval. Periodic inbox check requests "
        "count as standing approval in heartbeat sessions. Use `memory_search` to compose "
        "factual answers, then send via `EMAIL.md` — do not stop at an internal summary."
    )
    if old_sending in text:
        text = text.replace(old_sending, sensitive_new + inbound, 1)
    elif old_unsolicited in text and "`scripts/idcp-" not in text:
        text = text.replace(old_unsolicited, sensitive_new, 1)
    return text

def patch_sensitive_tool_refusal(text):
    block = os.environ.get("AGENTS_SENSITIVE_TOOL_REFUSAL_BLOCK", "").strip()
    if not block:
        return text
    block = block + "\n"
    if "### Sensitive tool requests (refusal wording)" in text:
        text = re.sub(
            r"\n### Sensitive tool requests \(refusal wording\)\n.*?(?=\n### |\n## |\Z)",
            "",
            text,
            flags=re.S,
        )
    anchor = "### Operator approval"
    if anchor not in text:
        return text
    return text.replace(anchor, block + "\n" + anchor, 1)

def patch_concierge_operational_hints(text):
    block = os.environ.get("AGENTS_CONCIERGE_OPERATIONAL_HINTS_BLOCK", "").strip()
    if not block:
        return text
    block = block + "\n"
    if "### Concierge operations (always cite)" in text:
        text = re.sub(
            r"\n### Concierge operations \(always cite\)\n.*?(?=\n### |\n## |\Z)",
            "",
            text,
            flags=re.S,
        )
    anchor = "### Hard rules"
    if anchor not in text:
        return text
    return text.replace(anchor, block + "\n" + anchor, 1)

for path, block, heading in (
    (Path(tools_path), tools_block, r"\n## Email[^\n]*\n"),
    (Path(agents_path), agents_block, r"\n## Email\n"),
):
    if not path.is_file():
        continue
    text = path.read_text(encoding="utf-8")
    text = upsert_block(text, heading, block)
    if path.name == "AGENTS.md":
        text = patch_knowledge_scope(text)
        text = patch_trust_tiers(text)
        text = patch_sensitive_tool_refusal(text)
        text = patch_concierge_operational_hints(text)
        text = upsert_block(text, r"\n## Inbound email \(concierge\)\n", "\n\n" + inbound_block + "\n")
    path.write_text(text, encoding="utf-8")
PY
  write_concierge_kb_inbox_heartbeat "$config_dir"
}


_sync_agent_email_tooling_in_container() {
  local container="$1"
  local email="$2"
  local display_name="$3"
  local agent_id="$4"
  local smtp_port smtp_settings inbound_block refusal_block hints_block
  smtp_settings="$(agent_smtp_settings "$agent_id")"
  smtp_port="${smtp_settings%%|*}"
  inbound_block="$(_concierge_inbound_email_agents_block)"
  refusal_block="$(_agents_sensitive_tool_refusal_block)"
  hints_block="$(_agents_concierge_operational_hints_block)"
  podman exec -i \
    -e CONCIERGE_INBOUND_EMAIL_AGENTS_BLOCK="$inbound_block" \
    -e AGENTS_SENSITIVE_TOOL_REFUSAL_BLOCK="$refusal_block" \
    -e AGENTS_CONCIERGE_OPERATIONAL_HINTS_BLOCK="$hints_block" \
    "$container" python3 - "$email" "$display_name" "$agent_id" "$smtp_port" <<'PY'
import os, re, stat, sys

email, display_name, agent_id, smtp_port = sys.argv[1:5]
inbound_block = os.environ["CONCIERGE_INBOUND_EMAIL_AGENTS_BLOCK"].strip()
workspace = "/home/node/.openclaw/workspace"
scripts_dir = os.path.join(workspace, "scripts")

inbox_script = """#!/bin/sh
# List INBOX with sender email addresses (plain table omits addr).
# Usage: sh scripts/himalaya-inbox.sh [PAGE_SIZE]
set -eu
PAGE_SIZE="${1:-10}"
himalaya envelope list --folder INBOX --page-size "$PAGE_SIZE" --output json | node -e '
const rows = JSON.parse(require("fs").readFileSync(0, "utf8"));
if (!Array.isArray(rows) || rows.length === 0) {
  console.log("INBOX is empty");
  process.exit(0);
}
for (const e of rows) {
  const from = e.from?.addr || "?";
  const name = e.from?.name || "";
  console.log(`ID ${e.id}\\t${from}\\t${name}\\t${e.subject}\\t${e.date || ""}`);
}
'
"""

read_script = """#!/bin/sh
# Read full message (headers + body). Use for From: address and content.
# Usage: sh scripts/himalaya-read.sh <ID>
set -eu
ID="${1:?usage: himalaya-read.sh <ID>}"
himalaya message read "$ID" --output plain
"""

email_doc = f"""# Email (Himalaya / Migadu)

- **Account:** `{email}` ({display_name})
- **Config:** `/home/node/.config/himalaya/config.toml`
- **IMAP/SMTP:** Migadu (`imap.migadu.com:993`, `smtp.migadu.com:{smtp_port}`)

## Read inbox

**Use the helpers** (recommended — include sender email addresses):

```bash
sh scripts/himalaya-inbox.sh 10
sh scripts/himalaya-read.sh <ID>
```

Raw Himalaya (same data):

```bash
himalaya envelope list --folder INBOX --page-size 10 --output json
himalaya message read <ID> --output plain
```

**Common mistakes:**
- No `himalaya envelope view` — use `message read <ID>` or `scripts/himalaya-read.sh`.
- Plain `envelope list` table shows names only, not email addresses.
- Never ask the operator for a sender's email if you have the message ID.
- `himalaya message reply` / `message write` need `$EDITOR` and fail headless — use `scripts/himalaya-send.sh`.

## Delete (move to Trash)

```bash
himalaya message delete <ID>
sh scripts/himalaya-delete.sh --all
```

## Send (headless — required in this container)

```bash
sh scripts/himalaya-send.sh recipient@example.com "Subject" "Body"
```

**Critical:** `From:` must be `{email}`. Migadu rejects other senders (553 *Sender address rejected*).

## Inbound HOLA probes (reciprocal testing)

Handled by `./identyclaw.sh respond-mail {agent_id}` — no LLM action needed.

## Reply to inbound messages (concierge)

Your inbox is a **concierge channel**. When someone emails you, replying to them
**is in scope** — do not treat IdentyClaw-related mail as "internal only" and skip
a direct reply.

1. `sh scripts/himalaya-inbox.sh 10`
2. `sh scripts/himalaya-read.sh <ID>` — note the `From:` address
3. Compose the answer (`memory_search` / `identyclaw_get_resource` for product questions)
4. `sh scripts/himalaya-send.sh SENDER "Re: SUBJECT" "BODY"` — never ask operator for sender email

**Operator main session:** when the operator asks you to check the inbox and answer or
reply to received emails, that **is** operator approval.

**Periodic checks (heartbeat):** when the operator asks you to check the inbox on a
schedule (e.g. hourly), you **can** enable recurring checks via OpenClaw heartbeat:

1. Add or update the `inbox-check` task in `workspace/HEARTBEAT.md` (interval matches
   the requested cadence, default `1h`)
2. Set `agents.defaults.heartbeat.every` in `openclaw.json` to the same interval
3. Run an immediate inbox check now
4. If you changed `openclaw.json`, tell the operator: `./identyclaw.sh restart {agent_id}`

**Standing approval:** periodic inbox check requests count as operator approval for
concierge replies in heartbeat/isolated sessions until they say otherwise.

**Host shortcut:** `./identyclaw.sh enable-inbox-check {agent_id} [interval]`

`enable-mail-responder` is **only** for deterministic HOLA probe replies — not LLM inbox
review.

**Never** refuse in-scope inbound mail by claiming you will "process it internally".
"""

tools_block = f"""
## Email ({agent_id})

- **Mail is pre-configured** — read **`EMAIL.md`** before any inbox task.
- **Account:** `{email}` (Migadu / Himalaya). Do **not** ask for IMAP/SMTP/password.
- **List:** `sh scripts/himalaya-inbox.sh 10` (includes sender email; plain `exec`, no `elevated`)
- **Read:** `sh scripts/himalaya-read.sh <ID>` (full message + From: address)
- **Delete:** `himalaya message delete <ID>` (plain `exec`, no `elevated`)
- **Reply:** read message, then `sh scripts/himalaya-send.sh SENDER "Re: SUBJECT" "BODY"`
- **Never** use `envelope view` (does not exist) or ask the operator for a sender address
- **Send:** `sh scripts/himalaya-send.sh RECIPIENT SUBJECT BODY` — arg1 is **To only** (never `{email}`)
- **Do not** pass `elevated: true` on exec — fails in webchat/TUI.
- In-scope inbound mail must get a **direct reply to the sender** — see **Inbound email (concierge)**.
"""

agents_block = f"""
## Email

- Mail **is already configured** via Himalaya — read **`EMAIL.md`** first on any email task.
- **Account:** `{email}`. Credentials live in the container; **never** ask the operator for them.
- Read/delete/reply via plain `exec` (no `elevated: true`) — `scripts/himalaya-inbox.sh`, `scripts/himalaya-read.sh`, `scripts/himalaya-send.sh`.
- **Concierge duty:** reply to in-scope inbound mail — see **Inbound email (concierge)**.
"""

def upsert_block(text, heading_re, block):
    text = re.sub(heading_re + r".*?(?=\n## |\Z)", "", text, flags=re.S)
    return text.rstrip() + block + "\n"

def patch_knowledge_scope(text):
    old = (
        "- Actions on behalf of the user (send email, run commands, post to social) —\n"
        "  those require operator approval per **Trust & tool tiers**"
    )
    new = (
        "- Unsolicited outbound actions (cold email, social posts, arbitrary commands) —\n"
        "  require operator approval per **Trust & tool tiers** (inbound email replies are\n"
        "  in scope; see **Inbound email (concierge)**)"
    )
    if old in text:
        text = text.replace(old, new, 1)
    inbox_hint = (
        "- Concierge inbox heartbeat — `./identyclaw.sh enable-inbox-check <agent-id> [interval]`\n"
        "  (see `knowledge/references/concierge-inbox-heartbeat.md`, `EMAIL.md`)"
    )
    anchor = "- Agent deployment (Podman, nginx TLS, `identyclaw.sh` commands)"
    if inbox_hint not in text and anchor in text:
        text = text.replace(anchor, anchor + "\n" + inbox_hint, 1)
    return text

def patch_trust_tiers(text):
    old_sending = (
        "- **Sensitive** (`a2a_send_message`, `send_rodit_webhook`, `exec`, `write`/`edit`, sending email): "
        "sender must be HOLA-verified **and** an operator must approve the specific action."
    )
    old_unsolicited = (
        "- **Sensitive** (`a2a_send_message`, `send_rodit_webhook`, `exec`, `write`/`edit`, unsolicited outbound email): "
        "sender must be HOLA-verified **and** an operator must approve the specific action."
    )
    sensitive_new = (
        "- **Sensitive** (`a2a_send_message`, `send_rodit_webhook`, `exec`, `write`/`edit`, unsolicited outbound email, "
        "`scripts/idcp-*.sh` NEAR wallet create/fund/transfer/rotate): "
        "sender must be HOLA-verified **and** an operator must approve the specific action."
    )
    inbound = (
        "\n- **Inbound email replies** (concierge): replying to messages in your inbox is in scope. "
        "Operator requests in the main session count as approval. Periodic inbox check requests "
        "count as standing approval in heartbeat sessions. Use `memory_search` to compose "
        "factual answers, then send via `EMAIL.md` — do not stop at an internal summary."
    )
    if old_sending in text:
        return text.replace(old_sending, sensitive_new + inbound, 1)
    if old_unsolicited in text and "`scripts/idcp-" not in text:
        return text.replace(old_unsolicited, sensitive_new, 1)
    return text

def patch_sensitive_tool_refusal(text):
    block = os.environ.get("AGENTS_SENSITIVE_TOOL_REFUSAL_BLOCK", "").strip()
    if not block:
        return text
    block = block + "\n"
    if "### Sensitive tool requests (refusal wording)" in text:
        text = re.sub(
            r"\n### Sensitive tool requests \(refusal wording\)\n.*?(?=\n### |\n## |\Z)",
            "",
            text,
            flags=re.S,
        )
    anchor = "### Operator approval"
    if anchor not in text:
        return text
    return text.replace(anchor, block + "\n" + anchor, 1)

def patch_concierge_operational_hints(text):
    block = os.environ.get("AGENTS_CONCIERGE_OPERATIONAL_HINTS_BLOCK", "").strip()
    if not block:
        return text
    block = block + "\n"
    if "### Concierge operations (always cite)" in text:
        text = re.sub(
            r"\n### Concierge operations \(always cite\)\n.*?(?=\n### |\n## |\Z)",
            "",
            text,
            flags=re.S,
        )
    anchor = "### Hard rules"
    if anchor not in text:
        return text
    return text.replace(anchor, block + "\n" + anchor, 1)

def write_executable(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    os.chmod(path, stat.S_IRWXU | stat.S_IRGRP | stat.S_IXGRP | stat.S_IROTH | stat.S_IXOTH)

write_executable(os.path.join(scripts_dir, "himalaya-inbox.sh"), inbox_script)
write_executable(os.path.join(scripts_dir, "himalaya-read.sh"), read_script)

skill_dir = os.path.join(workspace, "skills", "himalaya")
os.makedirs(skill_dir, exist_ok=True)
skill_path = os.path.join(skill_dir, "SKILL.md")
skill_doc = f"""---
name: himalaya
description: "Migadu/Himalaya email for this Concierge deployment — list, read, reply via workspace scripts."
---

# Email (IdentyClaw Concierge — {agent_id})

**This overrides the generic Himalaya skill.** Mail is pre-configured — do **not** run `himalaya account configure`.

Read **`EMAIL.md`** and **`AGENTS.md` → Inbound email (concierge)** before any inbox task.

## List inbox (helpers include sender email addresses)

```bash
sh scripts/himalaya-inbox.sh 10
```

**Never** use plain `himalaya envelope list` without `--output json` — the table shows names only.

## Read / reply

```bash
sh scripts/himalaya-read.sh <ID>
sh scripts/himalaya-send.sh SENDER "Re: SUBJECT" "BODY"
```

When the operator asks you to check/reply to inbox mail, **that is approval**. Periodic
check requests (hourly, etc.) are **standing approval** — enable the `inbox-check` task in
`workspace/HEARTBEAT.md` and set `openclaw.json` heartbeat interval per **EMAIL.md**.
Never ask for sender email or "process internally" instead of replying. **Run `sh scripts/himalaya-send.sh` and confirm
`Message successfully sent!` before reporting a reply as sent.**

**Critical:** \`From:\` must be \`{email}\` ({display_name}).
"""
with open(skill_path, "w", encoding="utf-8") as f:
    f.write(skill_doc)
os.chmod(skill_path, 0o644)

soul_path = os.path.join(workspace, "SOUL.md")
if os.path.isfile(soul_path):
    with open(soul_path, encoding="utf-8") as f:
        soul = f.read()
    soul_replacements = [
        (
            "**Earn trust through competence.** Your human gave you access to their stuff. Don't make them regret it. Be careful with external actions (emails, tweets, anything public). Be bold with internal ones (reading, organizing, learning).",
            "**Earn trust through competence.** Your human gave you access to their stuff. Don't make them regret it. Be careful with **unsolicited** external actions (cold email, tweets, anything public). **Inbound email replies are your Concierge job** — see `EMAIL.md`. Be bold with reading, organizing, and learning.",
        ),
        (
            "- When in doubt, ask before acting externally.",
            "- When in doubt about **unsolicited** outbound actions, ask first. Inbound inbox replies requested by the operator are pre-approved (see `EMAIL.md`).",
        ),
    ]
    for old, new in soul_replacements:
        if old in soul:
            soul = soul.replace(old, new, 1)
    if "## Inbound email (Concierge deployment)" not in soul:
        soul = soul.rstrip() + """

## Inbound email (Concierge deployment)

Your inbox is a **concierge channel**. Replying to senders is **in scope** — not a cautious
"external action" to avoid. Use `scripts/himalaya-inbox.sh` / `scripts/himalaya-read.sh`
for sender addresses; **never** ask the operator for an address you can read from the message.
Do not "process internally" when a direct email reply is what the sender expects.
"""
    with open(soul_path, "w", encoding="utf-8") as f:
        f.write(soul)

email_path = os.path.join(workspace, "EMAIL.md")
with open(email_path, "w", encoding="utf-8") as f:
    f.write(email_doc)
os.chmod(email_path, 0o644)

for path, block, heading in (
    (os.path.join(workspace, "TOOLS.md"), tools_block, r"\n## Email[^\n]*\n"),
    (os.path.join(workspace, "AGENTS.md"), agents_block, r"\n## Email\n"),
):
    if not os.path.isfile(path):
        continue
    with open(path, encoding="utf-8") as f:
        text = f.read()
    text = upsert_block(text, heading, block)
    if os.path.basename(path) == "AGENTS.md":
        text = patch_knowledge_scope(text)
        text = patch_trust_tiers(text)
        text = patch_sensitive_tool_refusal(text)
        text = patch_concierge_operational_hints(text)
        text = upsert_block(text, r"\n## Inbound email \(concierge\)\n", "\n\n" + inbound_block + "\n")
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
PY
  _write_concierge_kb_inbox_heartbeat_in_container "$container" || true
}

# Refresh mail helpers on host (when writable) and always inside a running container.


ensure_concierge_inbox_reply_guidance() {
  local id="$1"
  local config_dir="${2:-$(agent_home "$id")}"
  local container mailbox email display_name
  mailbox="$(agent_mailbox "$id")"
  email="${mailbox%%|*}"
  display_name="${mailbox#*|}"
  [[ -n "$email" ]] || return 0
  container="$(agent_container "$id")"
  if podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container"; then
    _sync_agent_email_tooling_in_container "$container" "$email" "$display_name" "$id"
  elif [[ -w "$config_dir/workspace" ]] 2>/dev/null; then
    write_concierge_kb_inbox_heartbeat "$config_dir"
    patch_agents_sensitive_tool_refusal "$config_dir/workspace/AGENTS.md"
    patch_agents_concierge_operational_hints "$config_dir/workspace/AGENTS.md"
  fi
}


agent_mailbox() {
  local id="$1"
  load_env
  is_valid_agent_id "$id" || { echo "unknown agent: $id" >&2; return 1; }
  echo "$(agent_env_value "$id" EMAIL "")|$(agent_env_value "$id" DISPLAY_NAME "$id")"
}


ensure_agent_email_tooling() {
  local id="$1"
  local config_dir="$2"
  local mailbox email display_name
  mailbox="$(agent_mailbox "$id")"
  email="${mailbox%%|*}"
  display_name="${mailbox#*|}"
  write_himalaya_config "$email" "$display_name" "$config_dir"
  write_himalaya_send_script "$email" "$display_name" "$config_dir"
  write_himalaya_delete_script "$config_dir"
  write_himalaya_inbox_script "$config_dir"
  write_himalaya_read_script "$config_dir"
  write_himalaya_workspace_skill "$config_dir" "$email" "$display_name" "$id"
  patch_soul_concierge_inbound_email "$config_dir"
  write_agent_email_doc "$email" "$display_name" "$config_dir"
}

# Install NEAR wallet workspace scripts + skill (near-cli-rs / idcp-wallet).
# Pod mode: workspace is often container-owned (0700) — write via podman exec when host cannot.

# Install NEAR wallet workspace scripts + skill (near-cli-rs / idcp-wallet).
# Pod mode: workspace is often container-owned (0700) — write via podman exec when host cannot.
write_idcp_wallet_scripts() {
  local config_dir="$1"
  local agent_id="${2:-}"
  local container="${3:-}"
  local tpl_scripts skill_src dest_scripts dest_skill
  tpl_scripts="${IDENTYCLAW_ROOT}/scripts/templates/workspace/scripts"
  skill_src="${IDENTYCLAW_ROOT}/scripts/templates/workspace/skills/idcp-wallet/SKILL.md"
  dest_scripts="$config_dir/workspace/scripts"
  dest_skill="$config_dir/workspace/skills/idcp-wallet"

  if [[ ! -w "$config_dir/workspace" && ! -w "$config_dir" ]]; then
    [[ -n "$container" ]] || container="$(agent_container "${agent_id:-${config_dir##*/}}")"
    if [[ -n "$container" ]] && podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container"; then
      podman exec "$container" bash -c 'mkdir -p /home/node/.openclaw/workspace/scripts /home/node/.openclaw/workspace/skills/idcp-wallet' \
        >/dev/null 2>&1 || true
      for f in idcp-wallet.sh idcp-activate-account.sh idcp-rotate-passport.sh; do
        if [[ -f "$tpl_scripts/$f" ]]; then
          podman cp "$tpl_scripts/$f" "${container}:/home/node/.openclaw/workspace/scripts/$f" >/dev/null 2>&1 || true
          podman exec "$container" chmod 755 "/home/node/.openclaw/workspace/scripts/$f" >/dev/null 2>&1 || true
        fi
      done
      if [[ -f "$skill_src" ]]; then
        podman cp "$skill_src" "${container}:/home/node/.openclaw/workspace/skills/idcp-wallet/SKILL.md" >/dev/null 2>&1 || true
        podman exec "$container" chmod 644 /home/node/.openclaw/workspace/skills/idcp-wallet/SKILL.md >/dev/null 2>&1 || true
      fi
      if [[ -n "$agent_id" ]]; then
        podman exec "$container" bash -c "printf '%s\n' '$agent_id' > /home/node/.openclaw/workspace/scripts/.idcp-agent-id && chmod 644 /home/node/.openclaw/workspace/scripts/.idcp-agent-id" \
          >/dev/null 2>&1 || true
      fi
      return 0
    fi
    echo "    (${agent_id:-agent}: skip idcp-wallet workspace sync — host cannot write container-owned state)" >&2
    return 0
  fi

  mkdir -p "$dest_scripts" "$dest_skill"
  for f in idcp-wallet.sh idcp-activate-account.sh idcp-rotate-passport.sh; do
    if [[ -f "$tpl_scripts/$f" ]]; then
      cp "$tpl_scripts/$f" "$dest_scripts/$f"
      chmod 755 "$dest_scripts/$f"
    fi
  done
  if [[ -f "$skill_src" ]]; then
    cp "$skill_src" "$dest_skill/SKILL.md"
    chmod 644 "$dest_skill/SKILL.md"
  fi
  # Stamp agent id into activate script env hint via a tiny wrapper marker file.
  if [[ -n "$agent_id" ]]; then
    printf '%s\n' "$agent_id" >"$dest_scripts/.idcp-agent-id"
    chmod 644 "$dest_scripts/.idcp-agent-id" 2>/dev/null || true
  fi
}


ensure_idcp_wallet_tooling() {
  local id="$1"
  local config_dir="$2"
  local container="${3:-}"
  write_idcp_wallet_scripts "$config_dir" "$id" "$container"
}


write_calendar_tooling() {
  local config_dir="$1"
  local container="${2:-}"
  local tpl_scripts="${IDENTYCLAW_ROOT}/scripts/templates/workspace/scripts"
  local skill_src="${IDENTYCLAW_ROOT}/scripts/templates/workspace/skills/calendar-reminders/SKILL.md"
  local dest_scripts="$config_dir/workspace/scripts"
  local dest_skill="$config_dir/workspace/skills/calendar-reminders"
  local dest_doc="$config_dir/workspace/CALENDAR.md"

  if [[ -n "$container" ]] && ! [[ -w "$config_dir/workspace" ]] 2>/dev/null; then
    if podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container"; then
      podman exec "$container" mkdir -p /home/node/.openclaw/workspace/scripts /home/node/.openclaw/workspace/skills/calendar-reminders /home/node/.openclaw/workspace/calendar
      [[ -f "$tpl_scripts/calendar.sh" ]] && podman cp "$tpl_scripts/calendar.sh" "$container:/home/node/.openclaw/workspace/scripts/calendar.sh" >/dev/null
      [[ -f "$skill_src" ]] && podman cp "$skill_src" "$container:/home/node/.openclaw/workspace/skills/calendar-reminders/SKILL.md" >/dev/null
      podman exec "$container" chmod 755 /home/node/.openclaw/workspace/scripts/calendar.sh >/dev/null 2>&1 || true
      podman exec "$container" chmod 644 /home/node/.openclaw/workspace/skills/calendar-reminders/SKILL.md >/dev/null 2>&1 || true
      _write_calendar_doc_in_container "$container"
      return 0
    fi
    echo "    (skip calendar workspace sync — host cannot write container-owned state)" >&2
    return 0
  fi

  mkdir -p "$dest_scripts" "$dest_skill" "$config_dir/workspace/calendar"
  if [[ -f "$tpl_scripts/calendar.sh" ]]; then
    cp "$tpl_scripts/calendar.sh" "$dest_scripts/calendar.sh"
    chmod 755 "$dest_scripts/calendar.sh"
  fi
  if [[ -f "$skill_src" ]]; then
    cp "$skill_src" "$dest_skill/SKILL.md"
    chmod 644 "$dest_skill/SKILL.md"
  fi
  write_calendar_doc "$config_dir"
}


write_calendar_doc() {
  local config_dir="$1"
  mkdir -p "$config_dir/workspace"
  cat >"$config_dir/workspace/CALENDAR.md" <<'EOF'
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
EOF
  chmod 644 "$config_dir/workspace/CALENDAR.md"
}


_write_calendar_doc_in_container() {
  local container="$1"
  podman exec "$container" python3 - <<'PY'
from pathlib import Path
path = Path("/home/node/.openclaw/workspace/CALENDAR.md")
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text("""# Calendar and reminders

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
""", encoding="utf-8")
path.chmod(0o644)
PY
}


ensure_calendar_skill_enabled() {
  local config_dir="$1"
  local container="${2:-}"
  agent_openclaw_json_exists "$config_dir" "$container" || return 0
  _agent_openclaw_json_python "$config_dir" "$container" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
skills = data.setdefault("skills", {}).setdefault("entries", {})
entry = skills.setdefault("calendar-reminders", {})
if entry.get("enabled") is True:
    raise SystemExit(0)
entry["enabled"] = True
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
path.chmod(0o600)
PY
}


ensure_calendar_reminders() {
  local id="$1"
  local config_dir="$2"
  local container="${3:-}"
  [[ -n "$container" ]] || container="$(agent_container "$id")"
  write_calendar_tooling "$config_dir" "$container"
  ensure_calendar_skill_enabled "$config_dir" "$container"
  ensure_calendar_heartbeat_from_env "$id" "$config_dir"
}


write_agent_identyclaw_doc() {
  local id="$1"
  local config_dir="$2"
  local display_name peers has_a2a=""
  load_env
  display_name="$(agent_display_name "$id")"
  mkdir -p "$config_dir/workspace"
  if agent_has_near_credentials "$config_dir"; then
    has_a2a="yes"
    peers="$(a2a_configured_peer_token_ids)"
  fi
  local own_token_id="" api_base=""
  if [[ "$has_a2a" == "yes" ]]; then
    own_token_id="$(probe_rodit_own_token_id "$config_dir" 2>/dev/null || true)"
    api_base="$(identyclaw_api_base_url_for_config_dir "$config_dir" 2>/dev/null || true)"
  fi
  cat >"$config_dir/workspace/IDENTYCLAW.md" <<EOF
# IdentyClaw identity + A2A peer messaging

This agent uses **two** published integrations. Use the right one for the job:

| Need | Use | Source |
|------|-----|--------|
| HOLA verify, Passport lookup, DID, API cheat sheet | **identyclaw** skill + \`identyclaw_*\` tools | [ClawHub: identyclaw/identyclaw](https://clawhub.ai/identyclaw/identyclaw) |
| Message another OpenClaw agent (tasks, files, multi-turn) | **a2a_*** tools | [ClawHub: @identyclaw/openclaw-a2a-plugin](https://clawhub.ai/plugins/@identyclaw/openclaw-a2a-plugin) |

## IdentyClaw (ClawHub skill + plugin)

- **Skill:** \`identyclaw\` — workflows for JWT login, HOLA create/verify, DID resolution, agent discovery. Read \`SKILL.md\` when handling identity.
- **Plugin:** \`identyclaw-tools\` — typed tools (\`identyclaw_verify_hola\`, \`identyclaw_list_agents\`, …). Passport signing key stays local; never paste keys into chat.
- **API base:** \`${api_base:-Passport subjectuniqueidentifier_url}\` (synced to \`IDENTYCLAW_BASE_URL\` in \`.env\`)
- **Credentials:** \`secrets/near-credentials/*.json\` → synced to \`.env\` as \`IDENTYCLAW_*\` plus \`RODIT_NEAR_CREDENTIALS_SOURCE=file\` and \`NEAR_CREDENTIALS_FILE_PATH\` for \`@rodit/rodit-auth-be\`.
- **Active owner:** \`secrets/near-credentials/.active\` (Passport signing account). Prefer this over the first \`*.json\` when multiple wallets exist.

### Federated APIs (login ≠ shared routes)

Federation shares **Rodit login** only (\`identyclaw_ensure_session({ apiEndpoint })\`). A federated peer may expose **arbitrary** product endpoints — it does **not** inherit home IdentyClaw paths like \`/api/me/identity\`.

1. \`identyclaw_ensure_session({ apiEndpoint: "<peer>" })\`
2. Discover: \`identyclaw_list_resources\` / \`identyclaw_get_resource\` / peer skill.md / OpenAPI
3. Call product routes with \`identyclaw_request({ method, path, apiEndpoint })\`. For SLC: refresh live \`https://slcapi.discernible.io:9443/api/game/skill.md\` (≥ 1.20.1) — no local playbook — then GET tasks+state(+messages), choose an explicit action from state (\`transfer\`|\`invest\`|\`transfer_and_invest\`|\`none\`), then \`identyclaw_game_tick({ apiEndpoint, … })\` or \`POST /api/game/tick\` / \`…/action\` **with that action body**. Empty tick bodies return \`action_required\` — they are not a silent \`none\`.

Keep Passport/HOLA/DID tools on the **home** API (omit \`apiEndpoint\`). A 404 on \`/api/me/identity\` against a federated host is expected when that peer does not implement it — not a login failure.

### NEAR wallet / Passport rotation (workspace scripts)

Sensitive (operator approval + HOLA for chat senders). Prefer **new** implicit accounts; do not reuse retired wallets.

| Need | Command |
|------|---------|
| List accounts | \`bash scripts/idcp-wallet.sh\` |
| Create account | \`bash scripts/idcp-wallet.sh genaccount\` |
| Fund new account (0.01 NEAR) | \`bash scripts/idcp-wallet.sh <funding> <new> init\` |
| Send NEAR | \`bash scripts/idcp-wallet.sh <origin> <dest> near <amount>\` |
| Transfer Passport (0.01 NEAR deposit) | \`bash scripts/idcp-wallet.sh <origin> <dest> <passport_token_id>\` — not ~0.041 NEAR |
| Full rotate + re-point | \`bash scripts/idcp-rotate-passport.sh <passport_token_id>\` |
| Activate only | \`bash scripts/idcp-activate-account.sh <account_id>\` |

After rotate/activate, scripts print \`RESTART_REQUIRED\` — ask the operator to run \`./identyclaw.sh restart ${id}\` (or \`./identyclaw.sh near-activate ${id}\`). Never paste private keys into chat. See workspace skill \`idcp-wallet\`.

### First contact from an unknown agent (HOLA)

1. \`identyclaw_verify_hola\` on the exact inbound HOLA string — trust only when \`verified: true\`.
2. Note \`peerTokenId\` (12-letter Passport ID).
3. \`identyclaw_get_agent_identity\` (or \`identyclaw_list_agents\` + lookup) for DN, \`contactUri\`, traits.
4. **Impersonation guard:** reject if verified \`peerTokenId\` ≠ the ID the entity officially publishes on channels they control.

For outbound HOLA, prefer \`identyclaw_create_hola\` (plugin v1.3.0+) or follow the skill’s HOLA section — fetch a **new** nonce immediately before each HOLA you sign.

## A2A (ClawHub plugin — RODiT JWT)

- **Plugin id:** \`identyclaw-a2a\` — installed from \`${IDENTYCLAW_CLAWHUB_A2A_PLUGIN}\` on bootstrap when Passport credentials exist.
- **Auth:** RODiT / Passport JWT (no static A2A API keys). Outbound login uses \`IDENTYCLAW_*\` env vars; inbound validates \`iss\` + \`aud\` + \`token_id\`.
- **Display name:** ${display_name}
EOF
  if [[ -n "$own_token_id" ]]; then
    cat >>"$config_dir/workspace/IDENTYCLAW.md" <<EOF
- **Passport token_id (this agent):** \`${own_token_id}\` — use as the canonical A2A peer id in \`a2a_send_message\`, \`send_rodit_webhook\`, and \`outbound.agents\`.
EOF
  fi
  if [[ "$has_a2a" == "yes" ]]; then
    local open_p2p_note=""
    if a2a_open_p2p_enabled; then
      open_p2p_note="
- **Open P2P:** inbound accepts any Passport holder via \`POST /api/login\` + \`POST /a2a\`. Outbound peers are registered dynamically from inbound JWT \`rodit_webhookurl\` (no \`A2A_PEER_AGENTS\` required for callbacks)."
    elif a2a_dynamic_peers_from_jwt_enabled; then
      open_p2p_note="
- **Dynamic peers:** outbound URLs resolve from IdentyClaw API \`/full\` \`metadata.webhook_url\` (on-chain fallback), bootstrap + \`resolvePeersByTokenId\`, and inbound JWT \`rodit_webhookurl\` after successful auth (keyed by Passport \`token_id\`)."
    fi
    cat >>"$config_dir/workspace/IDENTYCLAW.md" <<EOF
- **Configured peers (Passport token_id):** ${peers:-none} — \`A2A_PEER_AGENTS\` in env.local; gateway bases from API \`/full\` \`metadata.webhook_url\` (chain fallback) or optional \`A2A_PEER_URLS\` override.${open_p2p_note}

### A2A tools

| Tool | Purpose |
|------|---------|
| \`a2a_get_agents\` | List configured remote agents (Passport \`token_id\` keys) |
| \`a2a_send_message\` | Send message/files to a peer by \`token_id\`; returns \`context_id\` / \`task_id\` |
| \`a2a_get_task\` | Poll long-running peer tasks |
| \`a2a_update_agent_card\` | Update this agent’s public Agent Card |
| \`send_rodit_webhook\` | After a delay (default 10s), sign and POST \`/hooks/wake\` to a peer \`token_id\` from \`outbound.agents\` |

For unknown senders: \`identyclaw_verify_hola\` before trusting chat claims. Open P2P inbound does not replace HOLA for impersonation checks. To message a never-seen peer proactively, use \`identyclaw_list_agents\` (public GET \`/api/agents\` — token_ids only) then \`identyclaw_get_agent_identity\` / authenticated GET \`/api/identity/token/{tokenId}/full\` (session JWT from \`/api/login\` with NEAR creds) for \`metadata.webhook_url\` and \`contactUri\`. On-chain RODiT metadata is a fallback when API lookup fails. They must expose a public Agent Card and accept P2P login.
EOF
  else
    cat >>"$config_dir/workspace/IDENTYCLAW.md" <<'EOF'
- **A2A:** not configured — add `secrets/near-credentials/*.json` and restart to enable peer messaging.
EOF
  fi
  chmod 644 "$config_dir/workspace/IDENTYCLAW.md"
}


_heartbeat_inbox_check_prompt() {
  cat <<'EOF'
Read EMAIL.md. Run sh scripts/himalaya-inbox.sh 10. For each new in-scope message, read and reply per concierge rules (memory_search / identyclaw_get_resource first for factual answers). Skip IDENTYCLAW_HOLA_PROBE messages (handled deterministically). Summarize actions taken. If nothing needs attention, reply HEARTBEAT_OK.
EOF
}


_upsert_heartbeat_task() {
  local heartbeat_file="$1"
  local task_name="$2"
  local interval="$3"
  local prompt="$4"
  local footer_line="${5:-}"
  mkdir -p "$(dirname "$heartbeat_file")"
  HEARTBEAT_TASK_NAME="$task_name" \
  HEARTBEAT_TASK_INTERVAL="$interval" \
  HEARTBEAT_TASK_PROMPT="$prompt" \
  HEARTBEAT_TASK_FOOTER="$footer_line" \
  python3 - "$heartbeat_file" <<'PY'
import os, re, sys
from pathlib import Path

path = Path(sys.argv[1])
name = os.environ["HEARTBEAT_TASK_NAME"]
interval = os.environ["HEARTBEAT_TASK_INTERVAL"]
prompt = os.environ["HEARTBEAT_TASK_PROMPT"]
footer_line = os.environ.get("HEARTBEAT_TASK_FOOTER", "")

content = path.read_text(encoding="utf-8") if path.is_file() else "tasks:\n\n"

task_re = re.compile(
    r"^- name: (?P<name>\S+)\n  interval: (?P<interval>\S+)\n  prompt: \"(?P<prompt>(?:[^\"\\]|\\.)*)\"\n?",
    re.M,
)
tasks: dict[str, tuple[str, str]] = {}
for m in task_re.finditer(content):
    tasks[m.group("name")] = (m.group("interval"), m.group("prompt"))
tasks[name] = (interval, prompt)

footers: list[str] = []
for line in content.splitlines():
    if line.startswith("# ") and line not in footers:
        footers.append(line)
if footer_line and footer_line not in footers:
    footers.append(footer_line)

out = ["tasks:", ""]
for tname, (tint, tprompt) in tasks.items():
    out.append(f"- name: {tname}")
    out.append(f"  interval: {tint}")
    out.append(f'  prompt: "{tprompt}"')
    out.append("")
if footers:
    out.extend(footers)
path.write_text("\n".join(out).rstrip() + "\n", encoding="utf-8")
path.chmod(0o644)
PY
}


_upsert_heartbeat_task_in_container() {
  local container="$1"
  local task_name="$2"
  local interval="$3"
  local prompt="$4"
  local footer_line="${5:-}"
  HEARTBEAT_TASK_NAME="$task_name" \
  HEARTBEAT_TASK_INTERVAL="$interval" \
  HEARTBEAT_TASK_PROMPT="$prompt" \
  HEARTBEAT_TASK_FOOTER="$footer_line" \
  podman exec -i -e HEARTBEAT_TASK_NAME -e HEARTBEAT_TASK_INTERVAL -e HEARTBEAT_TASK_PROMPT -e HEARTBEAT_TASK_FOOTER \
    "$container" python3 <<'PY'
import os, re
from pathlib import Path

path = Path("/home/node/.openclaw/workspace/HEARTBEAT.md")
name = os.environ["HEARTBEAT_TASK_NAME"]
interval = os.environ["HEARTBEAT_TASK_INTERVAL"]
prompt = os.environ["HEARTBEAT_TASK_PROMPT"]
footer_line = os.environ.get("HEARTBEAT_TASK_FOOTER", "")

content = path.read_text(encoding="utf-8") if path.is_file() else "tasks:\n\n"

task_re = re.compile(
    r"^- name: (?P<name>\S+)\n  interval: (?P<interval>\S+)\n  prompt: \"(?P<prompt>(?:[^\"\\]|\\.)*)\"\n?",
    re.M,
)
tasks: dict[str, tuple[str, str]] = {}
for m in task_re.finditer(content):
    tasks[m.group("name")] = (m.group("interval"), m.group("prompt"))
tasks[name] = (interval, prompt)

footers: list[str] = []
for line in content.splitlines():
    if line.startswith("# ") and line not in footers:
        footers.append(line)
if footer_line and footer_line not in footers:
    footers.append(footer_line)

out = ["tasks:", ""]
for tname, (tint, tprompt) in tasks.items():
    out.append(f"- name: {tname}")
    out.append(f"  interval: {tint}")
    out.append(f'  prompt: "{tprompt}"')
    out.append("")
if footers:
    out.extend(footers)
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text("\n".join(out).rstrip() + "\n", encoding="utf-8")
path.chmod(0o644)
PY
}


ensure_heartbeat_config() {
  local config_dir="$1"
  local interval="${2:-1h}"
  local config="$config_dir/openclaw.json"
  [[ -f "$config" ]] || return 0
  python3 - "$config" "$interval" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
interval = sys.argv[2]
data = json.loads(path.read_text(encoding="utf-8"))
agents = data.setdefault("agents", {})
defaults = agents.setdefault("defaults", {})
heartbeat = defaults.setdefault("heartbeat", {})
changed = False
for key, value in {
    "every": interval,
    "target": "none",
    "lightContext": True,
    "isolatedSession": True,
}.items():
    if heartbeat.get(key) != value:
        heartbeat[key] = value
        changed = True
defaults["heartbeat"] = heartbeat
agents["defaults"] = defaults
data["agents"] = agents
if changed:
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    path.chmod(0o600)
PY
}


_ensure_heartbeat_config_in_container() {
  local container="$1"
  local interval="${2:-1h}"
  podman exec -i "$container" python3 - "$interval" <<'PY'
import json, sys
from pathlib import Path

interval = sys.argv[1]
path = Path("/home/node/.openclaw/openclaw.json")
data = json.loads(path.read_text(encoding="utf-8"))
agents = data.setdefault("agents", {})
defaults = agents.setdefault("defaults", {})
heartbeat = defaults.setdefault("heartbeat", {})
changed = False
for key, value in {
    "every": interval,
    "target": "none",
    "lightContext": True,
    "isolatedSession": True,
}.items():
    if heartbeat.get(key) != value:
        heartbeat[key] = value
        changed = True
defaults["heartbeat"] = heartbeat
agents["defaults"] = defaults
data["agents"] = agents
if changed:
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    path.chmod(0o600)
PY
}


write_inbox_heartbeat_doc() {
  local config_dir="$1"
  local interval="${2:-1h}"
  local prompt
  prompt="$(_heartbeat_inbox_check_prompt)"
  _upsert_heartbeat_task \
    "$config_dir/workspace/HEARTBEAT.md" \
    "inbox-check" "$interval" "$prompt" \
    "# Inbox monitoring (periodic) — follow EMAIL.md concierge rules. If nothing needs attention, reply HEARTBEAT_OK."
}


_write_inbox_heartbeat_doc_in_container() {
  local container="$1"
  local interval="${2:-1h}"
  local prompt
  prompt="$(_heartbeat_inbox_check_prompt)"
  _upsert_heartbeat_task_in_container \
    "$container" \
    "inbox-check" "$interval" "$prompt" \
    "# Inbox monitoring (periodic) — follow EMAIL.md concierge rules. If nothing needs attention, reply HEARTBEAT_OK."
}


ensure_inbox_heartbeat_config() {
  ensure_heartbeat_config "$1" "${2:-1h}"
}


_ensure_inbox_heartbeat_config_in_container() {
  _ensure_heartbeat_config_in_container "$1" "${2:-1h}"
}


inbox_heartbeat_interval_for_agent() {
  local id="$1"
  local config_dir="$2"
  local interval="" env_interval="" marker_file="$config_dir/secrets/inbox-heartbeat.interval"
  load_env
  env_interval="$(agent_env_value "$id" INBOX_HEARTBEAT_INTERVAL "")"
  [[ -n "$env_interval" ]] && interval="$env_interval"
  if [[ -z "$interval" ]]; then
    case "$(agent_env_value "$id" ENABLE_INBOX_HEARTBEAT "")" in
      1|true|yes|on) interval="${IDENTYCLAW_INBOX_HEARTBEAT_INTERVAL:-1h}" ;;
    esac
  fi
  if [[ -z "$interval" ]]; then
    case "${IDENTYCLAW_ENABLE_INBOX_HEARTBEAT:-}" in
      1|true|yes|on) interval="${IDENTYCLAW_INBOX_HEARTBEAT_INTERVAL:-1h}" ;;
    esac
  fi
  if [[ -z "$interval" && -f "$marker_file" ]]; then
    interval="$(tr -d '[:space:]' <"$marker_file")"
  fi
  [[ -n "$interval" ]] && echo "$interval"
}


_read_inbox_heartbeat_interval() {
  local id="$1"
  local config_dir="$2"
  local interval container
  interval="$(inbox_heartbeat_interval_for_agent "$id" "$config_dir")"
  [[ -n "$interval" ]] && { echo "$interval"; return 0; }
  container="$(agent_container "$id")"
  if podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container"; then
    interval="$(podman exec "$container" cat /home/node/.openclaw/secrets/inbox-heartbeat.interval 2>/dev/null | tr -d '[:space:]' || true)"
    [[ -n "$interval" ]] && echo "$interval"
  fi
  return 0
}


write_inbox_heartbeat_marker() {
  local config_dir="$1"
  local interval="$2"
  mkdir -p "$config_dir/secrets"
  printf '%s\n' "$interval" >"$config_dir/secrets/inbox-heartbeat.interval"
  chmod 600 "$config_dir/secrets/inbox-heartbeat.interval"
}


_write_inbox_heartbeat_marker_in_container() {
  local container="$1"
  local interval="$2"
  podman exec -i "$container" python3 - "$interval" <<'PY'
import os, sys
from pathlib import Path

interval = sys.argv[1]
path = Path("/home/node/.openclaw/secrets/inbox-heartbeat.interval")
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(interval + "\n", encoding="utf-8")
os.chmod(path, 0o600)
PY
}


_apply_inbox_heartbeat() {
  local id="$1"
  local config_dir="$2"
  local interval="$3"
  local container
  container="$(agent_container "$id")"
  if podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container"; then
    _write_inbox_heartbeat_doc_in_container "$container" "$interval"
    _ensure_inbox_heartbeat_config_in_container "$container" "$interval"
  fi
  if [[ -w "$config_dir/workspace" ]] 2>/dev/null; then
    write_inbox_heartbeat_doc "$config_dir" "$interval"
    ensure_inbox_heartbeat_config "$config_dir" "$interval"
  fi
}


ensure_inbox_heartbeat_from_env() {
  local id="$1"
  local config_dir="$2"
  local interval
  interval="$(_read_inbox_heartbeat_interval "$id" "$config_dir")"
  [[ -n "$interval" ]] || return 0
  _apply_inbox_heartbeat "$id" "$config_dir" "$interval"
}


enable_inbox_heartbeat() {
  local id="$1"
  local interval="${2:-1h}"
  local config_dir container
  config_dir="$(agent_home "$id")"
  container="$(agent_container "$id")"
  if ! [[ -d "$config_dir" ]] && ! podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container"; then
    echo "Run ./identyclaw.sh init first" >&2
    return 1
  fi
  if podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container"; then
    _write_inbox_heartbeat_marker_in_container "$container" "$interval"
    _apply_inbox_heartbeat "$id" "$config_dir" "$interval"
  elif [[ -d "$config_dir" ]]; then
    write_inbox_heartbeat_marker "$config_dir" "$interval"
    write_inbox_heartbeat_doc "$config_dir" "$interval"
    ensure_inbox_heartbeat_config "$config_dir" "$interval"
  fi
}


_heartbeat_calendar_prompt() {
  cat <<'EOF'
Read CALENDAR.md and skills/calendar-reminders/SKILL.md. Run sh scripts/calendar.sh upcoming 24. Summarize unacked events starting soon. If none, reply HEARTBEAT_OK.
EOF
}


ensure_heartbeat_every_at_most() {
  local config_dir="$1"
  local interval="${2:-30m}"
  local config="$config_dir/openclaw.json"
  [[ -f "$config" ]] || return 0
  python3 - "$config" "$interval" <<'PY'
import json, sys
from pathlib import Path

def to_seconds(raw):
    raw = str(raw or "").strip().lower()
    if raw.endswith("ms"):
        return int(raw[:-2]) / 1000
    if raw.endswith("s") and not raw.endswith("ms"):
        return int(raw[:-1])
    if raw.endswith("m"):
        return int(raw[:-1]) * 60
    if raw.endswith("h"):
        return int(raw[:-1]) * 3600
    if raw.endswith("d"):
        return int(raw[:-1]) * 86400
    return 3600

path = Path(sys.argv[1])
interval = sys.argv[2]
data = json.loads(path.read_text(encoding="utf-8"))
heartbeat = data.setdefault("agents", {}).setdefault("defaults", {}).setdefault("heartbeat", {})
current = heartbeat.get("every")
changed = False
if not current or to_seconds(interval) < to_seconds(current):
    heartbeat["every"] = interval
    changed = True
for key, value in {"target": "none", "lightContext": True, "isolatedSession": True}.items():
    if heartbeat.get(key) != value:
        heartbeat[key] = value
        changed = True
if changed:
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    path.chmod(0o600)
PY
}


write_calendar_heartbeat_marker() {
  local config_dir="$1"
  local interval="$2"
  mkdir -p "$config_dir/secrets"
  printf '%s\n' "$interval" >"$config_dir/secrets/calendar-heartbeat.interval"
  chmod 600 "$config_dir/secrets/calendar-heartbeat.interval"
}


_apply_calendar_heartbeat() {
  local id="$1"
  local config_dir="$2"
  local interval="$3"
  local container prompt
  prompt="$(_heartbeat_calendar_prompt)"
  container="$(agent_container "$id")"
  if podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container"; then
    _upsert_heartbeat_task_in_container "$container" "calendar-upcoming" "$interval" "$prompt"
  fi
  if [[ -w "$config_dir/workspace" ]] 2>/dev/null; then
    _upsert_heartbeat_task "$config_dir/workspace/HEARTBEAT.md" "calendar-upcoming" "$interval" "$prompt"
    ensure_heartbeat_every_at_most "$config_dir" "$interval"
  fi
}


_read_calendar_heartbeat_interval() {
  local id="$1"
  local config_dir="$2"
  local interval="" enabled=""
  load_env
  if [[ -f "$config_dir/secrets/calendar-heartbeat.interval" ]]; then
    interval="$(tr -d '\n' <"$config_dir/secrets/calendar-heartbeat.interval")"
  fi
  if is_valid_agent_id "$id"; then
    [[ -z "$interval" ]] && interval="$(agent_env_value "$id" CALENDAR_HEARTBEAT_INTERVAL "")"
    enabled="$(agent_env_value "$id" ENABLE_CALENDAR_HEARTBEAT "")"
  fi
  [[ -z "$interval" ]] && interval="${IDENTYCLAW_CALENDAR_HEARTBEAT_INTERVAL:-}"
  [[ -z "$enabled" ]] && enabled="${IDENTYCLAW_ENABLE_CALENDAR_HEARTBEAT:-0}"
  if [[ -n "$interval" ]]; then
    echo "$interval"
    return 0
  fi
  if [[ "$enabled" == "1" || "$enabled" == "true" ]]; then
    echo "${IDENTYCLAW_CALENDAR_HEARTBEAT_INTERVAL:-30m}"
  fi
}


ensure_calendar_heartbeat_from_env() {
  local id="$1"
  local config_dir="$2"
  local interval
  interval="$(_read_calendar_heartbeat_interval "$id" "$config_dir")"
  [[ -n "$interval" ]] || return 0
  _apply_calendar_heartbeat "$id" "$config_dir" "$interval"
}


enable_calendar_heartbeat() {
  local id="$1"
  local interval="${2:-30m}"
  local config_dir
  config_dir="$(agent_home "$id")"
  [[ -d "$config_dir" ]] || { echo "Run ./identyclaw.sh init first" >&2; return 1; }
  write_calendar_heartbeat_marker "$config_dir" "$interval"
  write_calendar_tooling "$config_dir" "$(agent_container "$id")"
  ensure_calendar_skill_enabled "$config_dir" "$(agent_container "$id")"
  _apply_calendar_heartbeat "$id" "$config_dir" "$interval"
}


_slc_kb_template_path() {
  echo "${IDENTYCLAW_ROOT}/scripts/templates/knowledge/slc-play-unattended.md"
}


write_slc_kb_doc() {
  local config_dir="$1"
  local kb_dir="$config_dir/workspace/knowledge/references"
  local template dest
  template="$(_slc_kb_template_path)"
  dest="$kb_dir/slc-play-unattended.md"
  [[ -f "$template" ]] || return 0
  mkdir -p "$kb_dir"
  cp -f "$template" "$dest"
  chmod 644 "$dest"
  _patch_slc_kb_scope "$config_dir/workspace/knowledge/SCOPE.md"
}


_patch_slc_kb_scope() {
  local scope_file="$1"
  [[ -f "$scope_file" ]] || return 0
  python3 - "$scope_file" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
needle = "- SLC unattended play (`./identyclaw.sh enable-slc-heartbeat`)"
if needle in text:
    sys.exit(0)
for anchor in (
    "- Concierge inbox heartbeat (`./identyclaw.sh enable-inbox-check`)",
    "- Migadu email / Himalaya skill (when documented here)",
):
    if anchor in text:
        text = text.replace(anchor, anchor + "\n" + needle, 1)
        path.write_text(text, encoding="utf-8")
        sys.exit(0)
PY
}


_write_slc_kb_doc_in_container() {
  local container="$1"
  local template tmp
  template="$(_slc_kb_template_path)"
  [[ -f "$template" ]] || return 1
  tmp="$(mktemp)"
  cp -f "$template" "$tmp"
  podman exec "$container" mkdir -p /home/node/.openclaw/workspace/knowledge/references
  podman cp "$tmp" "$container:/home/node/.openclaw/workspace/knowledge/references/slc-play-unattended.md"
  rm -f "$tmp"
  podman exec "$container" chmod 644 /home/node/.openclaw/workspace/knowledge/references/slc-play-unattended.md
  podman exec -i "$container" python3 - <<'PY'
import os

workspace = "/home/node/.openclaw/workspace"
scope_path = os.path.join(workspace, "knowledge", "SCOPE.md")
if not os.path.isfile(scope_path):
    raise SystemExit(0)
with open(scope_path, encoding="utf-8") as f:
    scope = f.read()
needle = "- SLC unattended play (`./identyclaw.sh enable-slc-heartbeat`)"
if needle in scope:
    raise SystemExit(0)
for anchor in (
    "- Concierge inbox heartbeat (`./identyclaw.sh enable-inbox-check`)",
    "- Migadu email / Himalaya skill (when documented here)",
):
    if anchor in scope:
        scope = scope.replace(anchor, anchor + "\n" + needle, 1)
        with open(scope_path, "w", encoding="utf-8") as f:
            f.write(scope)
        break
PY
}

# Remove local SLC playbooks so agents use :9443 skill.md only (fleet ops stay in heartbeat + unattended KB).

# Remove local SLC playbooks so agents use :9443 skill.md only (fleet ops stay in heartbeat + unattended KB).
purge_stale_slc_local_docs() {
  local config_dir="$1"
  rm -f "$config_dir/workspace/SLC.md" \
    "$config_dir/workspace/SLC-STANDING-ORDERS.md"
  rm -rf "$config_dir/workspace/skills/synthetics-last-cradle"
  write_slc_kb_doc "$config_dir"
  _patch_agents_slc_host_pointer "$config_dir/workspace/AGENTS.md"
}


_purge_stale_slc_local_docs_in_container() {
  local container="$1"
  podman exec "$container" sh -c \
    'rm -f /home/node/.openclaw/workspace/SLC.md \
           /home/node/.openclaw/workspace/SLC-STANDING-ORDERS.md; \
     rm -rf /home/node/.openclaw/workspace/skills/synthetics-last-cradle' || true
  _write_slc_kb_doc_in_container "$container" || true
  podman exec -i "$container" python3 - <<'PY'
from pathlib import Path
import re

agents = Path("/home/node/.openclaw/workspace/AGENTS.md")
if not agents.is_file():
    raise SystemExit(0)
block = """## SLC (fleet)

Playbook is only the live host skill: refresh `https://slcapi.discernible.io:9443/api/game/skill.md` (≥ 1.20.1) each session. Unattended loops never create lobbies — resume/join only; settle open deal-log transfers before bare invest. Fleet arming: `knowledge/references/slc-play-unattended.md` or `./identyclaw.sh enable-slc-heartbeat`.
"""
text = agents.read_text(encoding="utf-8")
text = re.sub(
    r"\n## SLC standing orders \(fleet\)\n.*?(?=\n## |\Z)",
    "\n",
    text,
    flags=re.S,
)
text = re.sub(
    r"\n## SLC \(fleet\)\n.*?(?=\n## |\Z)",
    "\n",
    text,
    flags=re.S,
)
if "## SLC active game (operator pin)" in text:
    text = text.replace(
        "## SLC active game (operator pin)",
        block.rstrip() + "\n\n## SLC active game (operator pin)",
        1,
    )
elif "## Heartbeats" in text:
    text = text.replace("## Heartbeats", block.rstrip() + "\n\n## Heartbeats", 1)
else:
    text = text.rstrip() + "\n\n" + block
agents.write_text(text, encoding="utf-8")
PY
}


_patch_agents_slc_host_pointer() {
  local agents_file="$1"
  [[ -f "$agents_file" ]] || return 0
  python3 - "$agents_file" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
block = """## SLC (fleet)

Playbook is only the live host skill: refresh `https://slcapi.discernible.io:9443/api/game/skill.md` (≥ 1.20.1) each session. Unattended loops never create lobbies — resume/join only; settle open deal-log transfers before bare invest. Fleet arming: `knowledge/references/slc-play-unattended.md` or `./identyclaw.sh enable-slc-heartbeat`.
"""
text = path.read_text(encoding="utf-8")
text = re.sub(
    r"\n## SLC standing orders \(fleet\)\n.*?(?=\n## |\Z)",
    "\n",
    text,
    flags=re.S,
)
text = re.sub(
    r"\n## SLC \(fleet\)\n.*?(?=\n## |\Z)",
    "\n",
    text,
    flags=re.S,
)
if "## SLC active game (operator pin)" in text:
    text = text.replace(
        "## SLC active game (operator pin)",
        block.rstrip() + "\n\n## SLC active game (operator pin)",
        1,
    )
elif "## Heartbeats" in text:
    text = text.replace("## Heartbeats", block.rstrip() + "\n\n## Heartbeats", 1)
else:
    text = text.rstrip() + "\n\n" + block
path.write_text(text, encoding="utf-8")
PY
}

# Back-compat aliases used by apply/enable paths.

# Back-compat aliases used by apply/enable paths.
write_slc_workspace_docs() {
  purge_stale_slc_local_docs "$1"
}


_write_slc_workspace_docs_in_container() {
  _purge_stale_slc_local_docs_in_container "$1"
}


_heartbeat_slc_game_prompt() {
  # Single line: HEARTBEAT.md stores prompt in double quotes (no " inside).
  # Unattended must never POST /api/game/games — solo/empty lobbies cancel and burn ~400k tokens/tick.
  # Mechanics only — no invest/trade/AFK strategy. Deal settlement is plumbing for isolated ticks.
  cat <<'EOF'
ensure_session apiEndpoint https://slcapi.discernible.io:9443. Fast idle gate first: GET /api/game/games/mine then GET /api/game/games?status=lobby. NEVER create lobbies (no POST /api/game/games, no slc_create, no empty/solo lobby). Resume only an active mine game (lobby|running); join an open lobby only if agentCount>=1 already seated. If mine has nothing active and no joinable peer lobby: reply HEARTBEAT_OK immediately — do not create, do not open contests, do not refresh skill or explore further. When playing: refresh skill GET /api/game/skill.md auth false responseType text (require >= 1.20.1, api_base with :9443); ignore local SLC.md / cached synthetics-last-cradle. Mechanics only — no standing invest/trade/AFK/max-invest policy. Standing approval while armed: a2a_send_message and game-related email to living co-players; wallet create/fund/transfer/rotate stay gated. GET tasks + state + messages + trades (and inbox if concierge); load durable deal log for this gameId+turn. Peer map: players[].id = game ULID for transfers; players[].roditId = Passport for identity/A2A/email; displayName is label only. Prefer A2A if routable else email+HOLA; advertise Passport once in public message body if unknown. If negotiation_open: GET messages then reply or post (messaging only in negotiation); when you accept a this-turn outbound transfer, persist gameId+turn+toAgentId ULID+amounts to durable workspace memory before the phase ends. If submit_execution_action: reconstruct open commitments from deal log + messages + side channels + trades; if accepted this-turn outbound transfers remain unsettled, submit MUST include them (transfer or transfer_and_invest) — bare invest/none that drops agreed outbound is forbidden; then follow live skill for the rest of the explicit action body (ULID toAgentId; hide/find when actionHints require); empty tick returns action_required (not silent none). Call identyclaw_game_tick or POST /api/game/tick or .../action WITH that action body; clear settled deal-log rows after success. If waitingOn non-empty note displayNames; do not invent peer submits. On view_honors / finished / cancelled / GAME_NOT_FOUND: HEARTBEAT_OK and do not start another game. Ignore cancelled lobby IDs; never bare-GET /api/game/games/{id}. No remote slc_* MCP. Reply HEARTBEAT_OK or one-line summary. Do not loop in operator chat.
EOF
}


write_slc_heartbeat_doc() {
  local config_dir="$1"
  local interval="${2:-10m}"
  local prompt
  prompt="$(_heartbeat_slc_game_prompt)"
  prompt="${prompt//$'\n'/ }"
  _upsert_heartbeat_task \
    "$config_dir/workspace/HEARTBEAT.md" \
    "slc-game" "$interval" "$prompt" \
    "# SLC — never create lobbies; resume/join only; skill >=1.20.1; honor deal log."
}


_write_slc_heartbeat_doc_in_container() {
  local container="$1"
  local interval="${2:-10m}"
  local prompt
  prompt="$(_heartbeat_slc_game_prompt)"
  prompt="${prompt//$'\n'/ }"
  _upsert_heartbeat_task_in_container \
    "$container" \
    "slc-game" "$interval" "$prompt" \
    "# SLC — never create lobbies; resume/join only; skill >=1.20.1; honor deal log."
}


ensure_slc_heartbeat_config() {
  ensure_heartbeat_config "$1" "${2:-10m}"
}


_ensure_slc_heartbeat_config_in_container() {
  _ensure_heartbeat_config_in_container "$1" "${2:-10m}"
}


slc_heartbeat_interval_for_agent() {
  local id="$1"
  local config_dir="$2"
  local interval="" env_interval="" marker_file="$config_dir/secrets/slc-heartbeat.interval"
  load_env
  env_interval="$(agent_env_value "$id" SLC_HEARTBEAT_INTERVAL "")"
  [[ -n "$env_interval" ]] && interval="$env_interval"
  if [[ -z "$interval" ]]; then
    case "$(agent_env_value "$id" ENABLE_SLC_HEARTBEAT "")" in
      1|true|yes|on) interval="${IDENTYCLAW_SLC_HEARTBEAT_INTERVAL:-10m}" ;;
    esac
  fi
  if [[ -z "$interval" ]]; then
    case "${IDENTYCLAW_ENABLE_SLC_HEARTBEAT:-}" in
      1|true|yes|on) interval="${IDENTYCLAW_SLC_HEARTBEAT_INTERVAL:-10m}" ;;
    esac
  fi
  if [[ -z "$interval" && -f "$marker_file" ]]; then
    interval="$(tr -d '[:space:]' <"$marker_file")"
  fi
  [[ -n "$interval" ]] && echo "$interval"
}


_read_slc_heartbeat_interval() {
  local id="$1"
  local config_dir="$2"
  local interval container
  interval="$(slc_heartbeat_interval_for_agent "$id" "$config_dir")"
  [[ -n "$interval" ]] && { echo "$interval"; return 0; }
  container="$(agent_container "$id")"
  if podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container"; then
    interval="$(podman exec "$container" cat /home/node/.openclaw/secrets/slc-heartbeat.interval 2>/dev/null | tr -d '[:space:]' || true)"
    [[ -n "$interval" ]] && echo "$interval"
  fi
  return 0
}


write_slc_heartbeat_marker() {
  local config_dir="$1"
  local interval="$2"
  mkdir -p "$config_dir/secrets"
  printf '%s\n' "$interval" >"$config_dir/secrets/slc-heartbeat.interval"
  chmod 600 "$config_dir/secrets/slc-heartbeat.interval"
}


_write_slc_heartbeat_marker_in_container() {
  local container="$1"
  local interval="$2"
  podman exec -i "$container" python3 - "$interval" <<'PY'
import os, sys
from pathlib import Path

interval = sys.argv[1]
path = Path("/home/node/.openclaw/secrets/slc-heartbeat.interval")
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(interval + "\n", encoding="utf-8")
os.chmod(path, 0o600)
PY
}

# Drop agent-created SLC isolated crons that overlap fleet HEARTBEAT.md slc-game.
# Keeps heartbeat:main / memory-core / non-SLC jobs. Best-effort (gateway must be up).

# Drop agent-created SLC isolated crons that overlap fleet HEARTBEAT.md slc-game.
# Keeps heartbeat:main / memory-core / non-SLC jobs. Best-effort (gateway must be up).
prune_stale_slc_agent_crons() {
  local id="$1"
  local container
  container="$(agent_container "$id")"
  podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container" || return 0
  podman exec "$container" node dist/index.js cron list --json 2>/dev/null | python3 -c '
import json, re, sys
raw = sys.stdin.read()
m = re.search(r"\{[\s\S]*\}\s*$", raw) or re.search(r"\[[\s\S]*\]\s*$", raw)
if not m:
    raise SystemExit(0)
data = json.loads(m.group(0))
jobs = data if isinstance(data, list) else (
    data.get("jobs") or data.get("automations") or data.get("items") or []
)
if isinstance(data, dict) and not jobs:
    for v in data.values():
        if isinstance(v, list):
            jobs = v
            break
pat = re.compile(
    r"(?:^|[\s_\-])slc(?:$|[\s_\-])|synthetics.?last.?cradle|unattended.*game|autonomous.*(?:play|game)",
    re.I,
)
keep = re.compile(r"^(?:heartbeat(?:-main|:main)?|memory-core)", re.I)
for j in jobs:
    jid = j.get("id") or j.get("jobId") or ""
    name = str(j.get("name") or "")
    decl = str(j.get("declaration") or "")
    if not jid:
        continue
    if keep.search(name) or keep.search(decl):
        continue
    blob = f"{name} {decl}"
    if pat.search(blob):
        print(jid)
' 2>/dev/null | while read -r job_id; do
    [[ -n "$job_id" ]] || continue
    echo "==> ${id}: removing overlapping SLC cron ${job_id}"
    podman exec "$container" node dist/index.js cron rm "$job_id" --json >/dev/null 2>&1 || true
  done
}

# Apply OpenClaw tool-result image hotpatch into a running container's /app.
# Returns 0 if already patched / nothing to do, 2 if files changed (caller should
# podman-restart so Node reloads modules), 1 on hard failure.


_apply_slc_heartbeat() {
  local id="$1"
  local config_dir="$2"
  local interval="$3"
  local container
  container="$(agent_container "$id")"
  if podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container"; then
    _write_slc_workspace_docs_in_container "$container"
    _write_slc_heartbeat_doc_in_container "$container" "$interval"
    _ensure_slc_heartbeat_config_in_container "$container" "$interval"
    prune_stale_slc_agent_crons "$id" || true
  fi
  if [[ -w "$config_dir/workspace" ]] 2>/dev/null; then
    write_slc_workspace_docs "$config_dir"
    write_slc_heartbeat_doc "$config_dir" "$interval"
    ensure_slc_heartbeat_config "$config_dir" "$interval"
  fi
}

# Install SLC KB + stub playbooks even when heartbeat is not armed (RAG / refuse stale).

# Install SLC KB + stub playbooks even when heartbeat is not armed (RAG / refuse stale).
ensure_slc_workspace_docs() {
  local id="$1"
  local config_dir="$2"
  local container
  container="$(agent_container "$id")"
  if podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container"; then
    _write_slc_workspace_docs_in_container "$container" || true
  fi
  if [[ -w "$config_dir/workspace" ]] 2>/dev/null; then
    write_slc_workspace_docs "$config_dir" || true
  fi
}


ensure_slc_heartbeat_from_env() {
  local id="$1"
  local config_dir="$2"
  local interval
  ensure_slc_workspace_docs "$id" "$config_dir"
  interval="$(_read_slc_heartbeat_interval "$id" "$config_dir")"
  [[ -n "$interval" ]] || return 0
  _apply_slc_heartbeat "$id" "$config_dir" "$interval"
}


enable_slc_heartbeat() {
  local id="$1"
  local interval="${2:-10m}"
  local config_dir container
  config_dir="$(agent_home "$id")"
  container="$(agent_container "$id")"
  if ! [[ -d "$config_dir" ]] && ! podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container"; then
    echo "Run ./identyclaw.sh init first" >&2
    return 1
  fi
  if podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container"; then
    _write_slc_heartbeat_marker_in_container "$container" "$interval"
    _apply_slc_heartbeat "$id" "$config_dir" "$interval"
  elif [[ -d "$config_dir" ]]; then
    write_slc_heartbeat_marker "$config_dir" "$interval"
    write_slc_workspace_docs "$config_dir"
    write_slc_heartbeat_doc "$config_dir" "$interval"
    ensure_slc_heartbeat_config "$config_dir" "$interval"
  fi
}


write_agent_browser_doc() {
  local config_dir="$1"
  mkdir -p "$config_dir/workspace"
  cat >"$config_dir/workspace/BROWSER.md" <<'EOF'
# Browser tool (pod / container deploy)

This gateway runs Chromium **inside the agent container** (host browser). The isolated **sandbox browser** sidecar is **not** enabled here — do not use `target="sandbox"` or `targetId="sandbox"`.

## Correct usage

1. Omit `target` (defaults to host) or set `target="host"`.
2. Open: `action="open"`, `url="https://…"`, optional `label="my-tab"`.
3. Snapshot: use `action="tabs"` first, then `action="snapshot"` with `targetId` from the tab list (e.g. `t1`) or the same `label`.
4. Profile: default managed profile is `openclaw` (cookies under `browser/openclaw/user-data/`).

## If browser times out on first use

Chromium cold-start can take ~30s. Retry `open`, or run inside the container:

`node /app/openclaw.mjs browser doctor`

EOF
  chmod 644 "$config_dir/workspace/BROWSER.md"
}

# Store Migadu IMAP/SMTP password. Writes on host when secrets/ is writable;
# otherwise falls back to the running container (pod UID ownership).
write_secret_helpers() {
  local id="$1"
  local password="$2"
  local config_dir
  [[ -n "$id" && -n "$password" ]] || {
    echo "write_secret_helpers: missing agent id or password" >&2
    return 1
  }
  config_dir="$(agent_home "$id")"
  if mkdir -p "$config_dir/secrets" 2>/dev/null && [[ -w "$config_dir/secrets" ]]; then
    _write_secret_helpers_host "$config_dir" "$password"
    echo "    (${id}: wrote imap/smtp secrets on host)" >&2
  else
    _write_secret_helpers_in_container "$id" "$password" || return 1
    echo "    (${id}: wrote imap/smtp secrets via container — host secrets/ not writable)" >&2
  fi
}


_write_secret_helpers_host() {
  local config_dir="$1"
  local password="$2"
  mkdir -p "$config_dir/secrets"
  printf '%s\n' "$password" >"$config_dir/secrets/imap.pass"
  cp "$config_dir/secrets/imap.pass" "$config_dir/secrets/smtp.pass"
  cat >"$config_dir/secrets/imap.sh" <<'EOF'
#!/bin/sh
cat /home/node/.openclaw/secrets/imap.pass
EOF
  cp "$config_dir/secrets/imap.sh" "$config_dir/secrets/smtp.sh"
  chmod 700 "$config_dir/secrets"
  chmod 700 "$config_dir/secrets"/*.sh
  chmod 600 "$config_dir/secrets"/*.pass
}


_write_secret_helpers_in_container() {
  local id="$1"
  local password="$2"
  local container
  container="$(agent_container "$id")"
  podman ps --format '{{.Names}}' | grep -qx "$container" || {
    echo "Cannot store mailbox password: host secrets/ not writable and ${container} is not running" >&2
    echo "Run: ./identyclaw.sh restore-host-access ${id}   # then set-password, then start" >&2
    return 1
  }
  podman exec -i "$container" sh -c '
set -e
root=/home/node/.openclaw/secrets
mkdir -p "$root"
chmod 700 "$root"
cat >"$root/imap.pass"
cp "$root/imap.pass" "$root/smtp.pass"
printf "%s\n" "#!/bin/sh" "cat /home/node/.openclaw/secrets/imap.pass" >"$root/imap.sh"
cp "$root/imap.sh" "$root/smtp.sh"
chmod 700 "$root/imap.sh" "$root/smtp.sh"
chmod 600 "$root/imap.pass" "$root/smtp.pass"
' <<<"${password}"
}
