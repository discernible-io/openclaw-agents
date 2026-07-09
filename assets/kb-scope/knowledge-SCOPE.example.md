Managed automatically as `workspace/knowledge/SCOPE.md` by
`ensure_agent_knowledge_scope_doc` when `IDENTYCLAW_KNOWLEDGE_ENABLED=1`.
Source of truth: `_knowledge_scope_file_content()` in `scripts/lib.sh`.

After changing scope topics in lib.sh, restart the agent and run:

```bash
./identyclaw.sh knowledge-reindex <agent-id>
```
