#!/bin/bash
#SPDX-License-Identifier: GPL-2.0
#Copyright (C) 2026 Discernible-IO All Rights Reserved.
#
# Re-point active NEAR credentials for this agent:
#   - secrets/near-credentials/.active
#   - .env IDENTYCLAW_* / NEAR_CREDENTIALS_FILE_PATH
#   - openclaw.json plugins.entries.identyclaw-tools.config (accountid, nearPrivateKey)
#
# Usage: sh scripts/idcp-activate-account.sh <account_id>
# Does not restart the gateway — print RESTART_REQUIRED for the operator.

set -euo pipefail

OPENCLAW_HOME="${OPENCLAW_HOME:-/home/node/.openclaw}"
SECRETS_DIR="${IDENTYCLAW_NEAR_CREDENTIALS_DIR:-$OPENCLAW_HOME/secrets/near-credentials}"
ENV_FILE="${IDENTYCLAW_ENV_FILE:-$OPENCLAW_HOME/.env}"
OPENCLAW_JSON="${IDENTYCLAW_OPENCLAW_JSON:-$OPENCLAW_HOME/openclaw.json}"
AGENT_ID="${IDENTYCLAW_AGENT_ID:-}"
if [ -z "$AGENT_ID" ] && [ -f "$(dirname "$0")/.idcp-agent-id" ]; then
  AGENT_ID="$(tr -d '[:space:]' <"$(dirname "$0")/.idcp-agent-id" 2>/dev/null || true)"
fi

account_id="${1:-}"
if [ -z "$account_id" ]; then
  echo "Usage: $0 <account_id>" >&2
  exit 1
fi

cred_file="$SECRETS_DIR/${account_id}.json"
if [ ! -f "$cred_file" ]; then
  echo "ERROR: credentials not found: $cred_file" >&2
  exit 1
fi

mkdir -p "$SECRETS_DIR"
printf '%s\n' "$account_id" >"$SECRETS_DIR/.active"
chmod 600 "$SECRETS_DIR/.active" 2>/dev/null || true

container_cred_path="/home/node/.openclaw/secrets/near-credentials/${account_id}.json"

node -e '
const fs = require("fs");
const path = require("path");

const credFile = process.argv[1];
const envFile = process.argv[2];
const openclawJson = process.argv[3];
const containerCredPath = process.argv[4];

const creds = JSON.parse(fs.readFileSync(credFile, "utf8"));
const accountId = creds.implicit_account_id || creds.account_id || "";
const privateKey = creds.private_key || "";
if (!accountId || !privateKey) {
  console.error("ERROR: credential file missing account id or private_key");
  process.exit(1);
}

const stripPrefixes = [
  "IDENTYCLAW_ACCOUNT_ID=",
  "IDENTYCLAW_NEAR_PRIVATE_KEY=",
  "NEAR_CREDENTIALS_FILE_PATH=",
  "RODIT_NEAR_CREDENTIALS_SOURCE=",
];

let lines = [];
if (fs.existsSync(envFile)) {
  lines = fs.readFileSync(envFile, "utf8").split(/(?<=\n)/).filter((ln) => {
    return !stripPrefixes.some((p) => ln.startsWith(p));
  });
}
lines.push(`IDENTYCLAW_ACCOUNT_ID=${accountId}\n`);
lines.push(`IDENTYCLAW_NEAR_PRIVATE_KEY=${privateKey}\n`);
lines.push("RODIT_NEAR_CREDENTIALS_SOURCE=file\n");
lines.push(`NEAR_CREDENTIALS_FILE_PATH=${containerCredPath}\n`);
fs.mkdirSync(path.dirname(envFile), { recursive: true });
fs.writeFileSync(envFile, lines.join(""), { mode: 0o600 });

if (fs.existsSync(openclawJson)) {
  const data = JSON.parse(fs.readFileSync(openclawJson, "utf8"));
  const plugins = (data.plugins = data.plugins || {});
  const entries = (plugins.entries = plugins.entries || {});
  const entry = (entries["identyclaw-tools"] = entries["identyclaw-tools"] || {});
  const cfg = (entry.config = entry.config || {});
  cfg.accountid = accountId;
  cfg.nearPrivateKey = privateKey;
  fs.writeFileSync(openclawJson, JSON.stringify(data, null, 2) + "\n");
}

console.log(`Activated NEAR account: ${accountId}`);
' "$cred_file" "$ENV_FILE" "$OPENCLAW_JSON" "$container_cred_path"

restart_hint="./identyclaw.sh restart"
if [ -n "$AGENT_ID" ]; then
  restart_hint="./identyclaw.sh restart ${AGENT_ID}"
fi
echo "RESTART_REQUIRED: ${restart_hint}"
echo "Gateway must reload to use the new signing key (Passport token_id is unchanged)."
