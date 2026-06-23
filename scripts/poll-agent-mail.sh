#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "$ROOT/scripts/lib.sh"

id="${1:-}"
if ! is_valid_agent_id "$id"; then
  echo "usage: $0 agent-{letter}" >&2
  exit 1
fi

load_env
container="openclaw-${id}"
agent_dir="$(agent_home "$id")"
log_file="${agent_dir}/cron/email-poll.log"

mkdir -p "${agent_dir}/cron"

if ! podman ps --format '{{.Names}}' | grep -qx "${container}"; then
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
