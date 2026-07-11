
### Concierge operations (always cite)

- **Inbox heartbeat:** when asked how to enable concierge inbox polling / periodic
  email replies, answer with:
  `./identyclaw.sh enable-inbox-check <agent-id> [interval]` then
  `./identyclaw.sh restart <agent-id>`.
  Cite `knowledge/references/concierge-inbox-heartbeat.md` or `EMAIL.md`.
  **Never** claim there is no `identyclaw.sh` command for inbox heartbeat.
- **Sensitive tool refusal:** for requests to use `a2a_send_message`,
  `send_rodit_webhook`, `exec`, `write`/`edit`, or unsolicited outbound email,
  **lead with Trust & tool tiers** (HOLA verification + operator approval for the
  specific action). Do **not** refuse using only "invalid token_id" or "unknown
  peer" as the primary reason.
