# KB-only scope (drop-in reference)

Copy these into your **app directory** (not the git checkout):

```text
identyclaw-agents-app/agents/<agent-id>/
```

## 1. AGENTS.md scope block

Bootstrap writes `## Knowledge scope (strict)` into `workspace/AGENTS.md` when
`IDENTYCLAW_KNOWLEDGE_ENABLED=1` (see `_knowledge_scope_agents_block` in
`scripts/lib.sh`). Reference copy: `AGENTS-scope-block.md`.

Place it **outside** the auto-managed `## Product & service knowledge` section
(bootstrap only re-upserts that block and `## Trust & tool tiers`).

## 2. Indexed scope doc

Bootstrap writes `workspace/knowledge/SCOPE.md` from the same source. Reference:
`knowledge-SCOPE.example.md`.

```bash
./identyclaw.sh knowledge-reindex <agent-id>
```

## 3. openclaw.json tool policy

Merge `openclaw-kb-only.patch.json` into `openclaw.json`:

- Replace `OPERATOR_DISCORD_USER_ID` / `OPERATOR_TELEGRAM_USER_ID` with your
  owner ids from `env.local` (`AGENT_*_DISCORD_OWNER_ID`, etc.).
- An empty `{}` operator entry keeps the global tool allowlist for that sender.
- The `"*"` wildcard restricts everyone else to KB read tools only.

Restart:

```bash
./identyclaw.sh restart <agent-id>
```

## Public chat allow list

| Tool | Why |
|------|-----|
| `read` | Read `KNOWLEDGE.md`, workspace docs |
| `group:memory` | `memory_search`, `memory_get` |
| `identyclaw_list_agents` | Public agent registry |
| `identyclaw_list_resources` | Network-published KB |
| `identyclaw_get_resource` | Fetch network resources |
| `identyclaw_verify_hola` | Trust escalation per AGENTS.md |
| `identyclaw_create_hola` | Outbound HOLA lines (e.g. MUNDO probes) |
| `identyclaw_get_nonce` | Fresh nonce before each signed HOLA |

Denied for public senders (invisible to the model): `exec`, `browser`, `write`,
`message`, A2A outbound, webhooks, etc.

## Verify

```bash
./identyclaw.sh ask <agent-id> "What is the capital of France?"
./identyclaw.sh ask <agent-id> "How do I set metadata.webhook_url on my Passport?"
```

The first should refuse; the second should cite `knowledge/` or refuse if docs
are missing.
