# SLC unattended play (retired template)

Fleet SLC arming is retired. `./identyclaw.sh enable-slc-heartbeat` only **purges** leftover
workspace docs, heartbeat tasks, and agent-created SLC skills/crons.

If you reintroduce game play later:

1. Set `IDENTYCLAW_API_ENDPOINTS` to the live game API base (no hard-coded hosts in this repo).
2. Refresh that host’s `/api/game/skill.md` each session — do not keep a local `SLC.md` playbook.
3. Prefer an explicit operator paste prompt over fleet heartbeat until arming is rebuilt.

## Related

- Purge leftovers: `./identyclaw.sh enable-slc-heartbeat <agent-id>`
- Clean slate (memory/sessions/skills): `./identyclaw.sh factory-reset <agent-id|all>`
