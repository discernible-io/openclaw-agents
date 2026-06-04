#!/usr/bin/env bash
set -euo pipefail

id="${1:-}"
if [[ "$id" != "agent-a" && "$id" != "agent-b" ]]; then
  echo "usage: $0 agent-a|agent-b" >&2
  exit 1
fi

container="openclaw-${id}"
agent_dir="$HOME/.openclaw-${id}"
log_file="${agent_dir}/cron/email-poll.log"

mkdir -p "${agent_dir}/cron"

if ! podman ps --format '{{.Names}}' | rg -xq "${container}"; then
  {
    date -u +"[%Y-%m-%dT%H:%M:%SZ] ${id} container not running"
  } >>"${log_file}"
  exit 0
fi

output="$(
  podman exec "${container}" himalaya envelope list --page-size 1 2>&1 \
    | tr '\n' ' ' \
    | sed 's/[[:space:]]\+/ /g'
)"

{
  date -u +"[%Y-%m-%dT%H:%M:%SZ] ${id} polled inbox"
  echo "  ${output}"
} >>"${log_file}"
