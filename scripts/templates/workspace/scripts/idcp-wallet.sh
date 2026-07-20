#!/bin/bash
#SPDX-License-Identifier: GPL-2.0
#Copyright (C) 2026 Discernible-IO All Rights Reserved.
#
# Agent workspace wrapper around near-cli-rs (same actions as infra idcp-wallet.sh).
# Canonical creds: $OPENCLAW_HOME/secrets/near-credentials/<id>.json
# Active Passport owner: secrets/near-credentials/.active
# near-cli legacy keychain mirror: ~/.near-credentials/$BLOCKCHAIN_ENV/

VERSION="1.0.0-agents"

MAX_RETRIES=3
RETRY_DELAY=2

OPENCLAW_HOME="${OPENCLAW_HOME:-/home/node/.openclaw}"
# himalaya mounts ~/.config read-only; near-cli must write config elsewhere.
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$OPENCLAW_HOME/xdg-config}"
mkdir -p "$XDG_CONFIG_HOME" 2>/dev/null || true
SECRETS_DIR="${IDENTYCLAW_NEAR_CREDENTIALS_DIR:-$OPENCLAW_HOME/secrets/near-credentials}"
BLOCKCHAIN_ENV="${BLOCKCHAIN_ENV:-mainnet}"
RODITCONTRACTID="${NEAR_CONTRACT_ID:-${IDENTYCLAW_NEAR_CONTRACT_ID:-genaaaa-identyclaw-com.near}}"
ACCOUNTS_JSON="${HOME:-/home/node}/.near-credentials/accounts.json"

if command -v near >/dev/null 2>&1; then
  NEAR_CLI_BIN="$(command -v near)"
elif [ -x "$HOME/.cargo/bin/near" ]; then
  NEAR_CLI_BIN="$HOME/.cargo/bin/near"
else
  NEAR_CLI_BIN=""
fi

NETWORK_CONFIG="${BLOCKCHAIN_ENV}"
if [ "$BLOCKCHAIN_ENV" = "mainnet" ]; then
  NETWORK_CONFIG="mainnet-fastnear"
elif [ "$BLOCKCHAIN_ENV" = "testnet" ]; then
  NETWORK_CONFIG="testnet-fastnear"
fi
if [ -n "${NEAR_NETWORK_CONFIG:-}" ]; then
  NETWORK_CONFIG="$NEAR_NETWORK_CONFIG"
fi

KEYCHAIN_DIR="${HOME:-/home/node}/.near-credentials/${BLOCKCHAIN_ENV}"

require_near_cli() {
  if [ -z "$NEAR_CLI_BIN" ]; then
    echo "WARNING: near is not installed or is not on PATH" >&2
    echo "Rebuild the agent image (near-cli-rs) and ensure 'near' is on PATH." >&2
    return 1
  fi
}

require_network_config() {
  if [ -z "$NETWORK_CONFIG" ]; then
    echo "WARNING: Blockchain network is not configured" >&2
    echo "Set BLOCKCHAIN_ENV to mainnet/testnet or set NEAR_NETWORK_CONFIG." >&2
    return 1
  fi
}

require_rodit_contract() {
  if [ -z "$RODITCONTRACTID" ]; then
    echo "WARNING: RODITCONTRACTID / NEAR_CONTRACT_ID is not configured" >&2
    return 1
  fi
}

mkdir -p "$SECRETS_DIR" "$KEYCHAIN_DIR" 2>/dev/null || true
chmod 700 "$SECRETS_DIR" 2>/dev/null || true

# Sync secrets/near-credentials → near-cli legacy keychain (sign-with-legacy-keychain).
sync_keychain_from_secrets() {
  local src dest account_id
  mkdir -p "$KEYCHAIN_DIR" 2>/dev/null || true
  for src in "$SECRETS_DIR"/*.json; do
    [ -f "$src" ] || continue
    account_id="$(basename "$src" .json)"
    dest="$KEYCHAIN_DIR/${account_id}.json"
    # near-cli accepts gennearaccount-shaped JSON (implicit_account_id + private_key).
    cp -a "$src" "$dest" 2>/dev/null || cp "$src" "$dest"
    chmod 600 "$dest" 2>/dev/null || true
  done
}

# After near genaccount, import keychain file into secrets/.
import_keychain_account_to_secrets() {
  local account_id="$1"
  local src="$KEYCHAIN_DIR/${account_id}.json"
  local dest="$SECRETS_DIR/${account_id}.json"
  if [ ! -f "$src" ]; then
    echo "ERROR: keychain file not found for $account_id ($src)" >&2
    return 1
  fi
  mkdir -p "$SECRETS_DIR" 2>/dev/null || true
  # Normalize to gennearaccount-compatible minimal JSON via node (always available in image).
  node -e '
const fs = require("fs");
const src = process.argv[1];
const dest = process.argv[2];
const data = JSON.parse(fs.readFileSync(src, "utf8"));
const account_id = data.implicit_account_id || data.account_id;
const private_key = data.private_key;
if (!account_id || !private_key) {
  console.error("ERROR: credential file missing implicit_account_id/account_id or private_key");
  process.exit(1);
}
const out = {
  implicit_account_id: account_id,
  account_id,
  private_key,
};
if (data.public_key) out.public_key = data.public_key;
fs.writeFileSync(dest, JSON.stringify(out, null, 2) + "\n", { mode: 0o600 });
' "$src" "$dest" || return 1
  chmod 600 "$dest" 2>/dev/null || true
  echo "$account_id"
}

active_account_id() {
  local active_file="$SECRETS_DIR/.active"
  if [ -f "$active_file" ]; then
    tr -d '[:space:]' <"$active_file"
  fi
}

list_secret_accounts() {
  local f
  for f in "$SECRETS_DIR"/*.json; do
    [ -f "$f" ] || continue
    basename "$f" .json
  done
}

refresh_accounts_json() {
  local accounts_array="["
  local first=true
  local account_id
  for account_id in $(list_secret_accounts); do
    if [ "$first" = true ]; then
      first=false
    else
      accounts_array="$accounts_array,"
    fi
    accounts_array="$accounts_array\n  {\"account_id\":\"$account_id\",\"used_as_signer\":true}"
  done
  accounts_array="$accounts_array\n]"
  mkdir -p "$(dirname "$ACCOUNTS_JSON")" 2>/dev/null || true
  echo -e "$accounts_array" >"$ACCOUNTS_JSON" 2>/dev/null || true
}

validate_account_id() {
  local account="$1"
  if [[ "$account" =~ ^[0-9a-f]{64}$ ]]; then
    echo "Implicit account detected (hex format)"
    return 0
  elif [[ "$account" =~ ^[0-9a-f]+$ ]]; then
    echo "ERROR: Invalid implicit account ID length. Expected 64 hex characters, got ${#account}." >&2
    return 1
  elif [[ "$account" =~ ^[a-z0-9_-]+\.[a-z0-9_-]+$ ]] || [[ "$account" =~ ^[a-z0-9_-]+$ ]]; then
    echo "Named account detected"
    return 0
  else
    echo "ERROR: Invalid account ID format." >&2
    return 1
  fi
}

execute_with_retry() {
  local cmd="$1"
  local attempt=1
  local result
  local exit_code

  while [ $attempt -le $MAX_RETRIES ]; do
    if [ $attempt -gt 1 ]; then
      echo "Retry attempt $attempt of $MAX_RETRIES..."
      sleep $RETRY_DELAY
    fi
    result=$(eval "$cmd" 2>&1)
    exit_code=$?
    if [ $exit_code -eq 0 ]; then
      echo "$result"
      return 0
    fi
    if echo "$result" | grep -q "error while sending payload\|error sending request\|Failed to fetch"; then
      echo "Network error detected on attempt $attempt"
      attempt=$((attempt + 1))
    else
      echo "$result"
      return $exit_code
    fi
  done
  echo "ERROR: Command failed after $MAX_RETRIES attempts" >&2
  echo "$result"
  return 1
}

is_near_amount() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

sync_keychain_from_secrets
refresh_accounts_json

echo "Version $VERSION running on $BLOCKCHAIN_ENV at Smart Contract $RODITCONTRACTID  Get help with: $0 help" >&2

if [ "${1:-}" = "help" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  cat <<EOF
Usage: $0 [account_id] [Options]

Options:
  $0                              List of available accounts (secrets/near-credentials)
  $0 <accountID>                  Lists RODiT ids for the account and its balance
  $0 <accountID> keys             Displays account id + private key (operator only — never paste into chat)
  $0 <accountID> <RODiT Id>       Displays the indicated RODiT
  $0 <funding> <uninit> init      Initializes account with 0.01 NEAR from funding account
  $0 <origin> <dest> <rotid>      Sends RODiT / Passport from origin to destination
  $0 <origin> <dest> <amount>     Sends NEAR from origin to destination
  $0 <origin> <dest> near <amt>   Sends NEAR from origin to destination
  $0 genaccount                   Creates a new uninitialized implicit account

Active Passport owner: $(active_account_id || echo "(none — set via idcp-activate-account.sh)")

Environment:
  OPENCLAW_HOME / IDENTYCLAW_NEAR_CREDENTIALS_DIR
  BLOCKCHAIN_ENV / NEAR_NETWORK_CONFIG / NEAR_CONTRACT_ID
EOF
  exit 0
fi

if [ "${1:-}" = "genaccount" ]; then
  require_near_cli || exit 1
  require_network_config || exit 1
  mkdir -p "$KEYCHAIN_DIR"
  "$NEAR_CLI_BIN" account create-account \
    fund-later \
    use-auto-generation \
    save-to-folder "$KEYCHAIN_DIR" >/tmp/idcp-genaccount.out 2>&1 || {
    cat /tmp/idcp-genaccount.out >&2
    exit 1
  }
  account="$(ls -t "$KEYCHAIN_DIR"/*.json 2>/dev/null | head -n 1 | xargs -I {} basename {} .json)"
  if [ -z "$account" ]; then
    echo "ERROR: Failed to create account" >&2
    cat /tmp/idcp-genaccount.out >&2
    exit 1
  fi
  import_keychain_account_to_secrets "$account" >/dev/null || exit 1
  sync_keychain_from_secrets
  refresh_accounts_json
  echo "Account number:"
  echo "$account"
  echo "The account does not exist in the blockchain as it has no balance. You need to initialize it with at least 0.01 NEAR."
  exit 0
fi

if echo "${3:-}" | grep -qi '^near$' || is_near_amount "${3:-}"; then
  validate_account_id "$1" || exit 1
  validate_account_id "$2" || exit 1
  require_near_cli || exit 1
  require_network_config || exit 1
  sync_keychain_from_secrets

  near_amount="$3"
  if echo "$3" | grep -qi '^near$'; then
    near_amount="$4"
  elif [ -n "${4:-}" ]; then
    echo "ERROR: Unexpected extra argument '$4'." >&2
    exit 1
  fi
  if [ -z "$near_amount" ] || ! is_near_amount "$near_amount"; then
    echo "ERROR: NEAR amount must be a number" >&2
    exit 1
  fi

  echo "Sending $near_amount NEAR from $1 to $2..."
  "$NEAR_CLI_BIN" tokens "$1" send-near "$2" "$near_amount NEAR" \
    network-config "$NETWORK_CONFIG" sign-with-legacy-keychain send
  if [ $? -ne 0 ]; then
    echo "ERROR: Failed to send NEAR" >&2
    exit 1
  fi
  exit 0
fi

if [ -n "${3:-}" ] && [ "$3" != "init" ]; then
  validate_account_id "$1" || exit 1
  validate_account_id "$2" || exit 1
  require_near_cli || exit 1
  require_network_config || exit 1
  require_rodit_contract || exit 1
  sync_keychain_from_secrets
  echo "Sending RODiT $3 from $1 to $2..."
  "$NEAR_CLI_BIN" contract call-function as-transaction "$RODITCONTRACTID" rodit_transfer \
    json-args "{\"receiver_id\": \"$2\", \"token_id\": \"$3\"}" \
    prepaid-gas '30 TeraGas' attached-deposit '0.01 NEAR' \
    sign-as "$1" network-config "$NETWORK_CONFIG" sign-with-legacy-keychain send
  if [ $? -ne 0 ]; then
    echo "ERROR: Failed to send RODiT" >&2
    exit 1
  fi
  exit 0
fi

if [ "${3:-}" = "init" ]; then
  validate_account_id "$1" || exit 1
  validate_account_id "$2" || exit 1
  require_near_cli || exit 1
  require_network_config || exit 1
  sync_keychain_from_secrets
  echo "Initializing with 0.01 NEAR $2"
  "$NEAR_CLI_BIN" tokens "$1" send-near "$2" '0.01 NEAR' \
    network-config "$NETWORK_CONFIG" sign-with-legacy-keychain send
  if [ $? -ne 0 ]; then
    echo "ERROR: Failed to initialize account" >&2
    exit 1
  fi
  echo "Account initialized successfully"
  exit 0
fi

if [ -z "${1:-}" ]; then
  echo "The following is a list of accounts found in secrets/near-credentials:"
  active="$(active_account_id || true)"
  for account_id in $(list_secret_accounts); do
    if [ -n "$active" ] && [ "$account_id" = "$active" ]; then
      echo "$account_id  (active)"
    else
      echo "$account_id"
    fi
  done
  exit 0
fi

if [ -n "${2:-}" ]; then
  if [ "$2" = "keys" ]; then
    key_file="$SECRETS_DIR/$1.json"
    if [ ! -f "$key_file" ]; then
      echo "ERROR: Key file not found for account $1" >&2
      exit 1
    fi
    echo "The contents of the key file (PrivateKey in Base58 account ID in Hex) are:"
    jq -r '.private_key' "$key_file" | cut -d':' -f2
    jq -r '.implicit_account_id // .account_id' "$key_file"
    exit 0
  else
    validate_account_id "$1" || exit 1
    require_near_cli || exit 1
    require_network_config || exit 1
    require_rodit_contract || exit 1
    echo "RODiT Contents"
    cmd="\"$NEAR_CLI_BIN\" contract call-function as-read-only \"$RODITCONTRACTID\" rodit_tokens_for_owner text-args \"{\\\"account_id\\\": \\\"$1\\\"}\" network-config \"$NETWORK_CONFIG\" now"
    raw_output=$(execute_with_retry "$cmd")
    json_output=$(echo "$raw_output" | sed -n '/^\[/,/^\]/p')
    output3=$(echo "$json_output" | jq --arg token_id "$2" '.[] | select(.token_id == $token_id) | {token_id, metadata}' 2>/dev/null)
    if [ -z "$output3" ]; then
      echo "ERROR: RODiT $2 not found for account $1" >&2
      echo "Available RODiTs for this account:"
      echo "$json_output" | jq -r '.[].token_id' 2>/dev/null
      exit 1
    fi
    echo "$output3"
    exit 0
  fi
fi

if [ -n "${1:-}" ]; then
  validate_account_id "$1" || exit 1
  require_near_cli || exit 1
  require_network_config || exit 1
  require_rodit_contract || exit 1

  echo "There is a lag while collecting information from the blockchain"
  echo "The following is a list of RODiT belonging to the input account:"

  cmd="\"$NEAR_CLI_BIN\" contract call-function as-read-only \"$RODITCONTRACTID\" rodit_tokens_for_owner text-args \"{\\\"account_id\\\": \\\"$1\\\"}\" network-config \"$NETWORK_CONFIG\" now"
  output2=$(execute_with_retry "$cmd")
  rodit_fetch_status=$?

  if [ $rodit_fetch_status -ne 0 ]; then
    echo "WARNING: Failed to fetch RODiT tokens after $MAX_RETRIES attempts"
    echo "Continuing to check account balance..."
  else
    filtered_output2=$(echo "$output2" | grep 'token_id' | awk -F'"' '{print $4}')
    if [ -z "$filtered_output2" ]; then
      echo "No RODiT tokens found for this account"
    else
      echo "$filtered_output2"
    fi
  fi

  echo ""
  echo "Checking account balance..."
  cmd2="\"$NEAR_CLI_BIN\" account view-account-summary \"$1\" network-config \"$NETWORK_CONFIG\" now"
  near_state=$(execute_with_retry "$cmd2")
  if [ $? -ne 0 ]; then
    echo "WARNING: Could not fetch account balance"
    echo "The account may not exist in the blockchain as it has no balance."
    echo "You need to initialize it with at least 0.01 NEAR."
  else
    balance=$(echo "$near_state" | grep "Native account balance")
    if [ -z "$balance" ]; then
      echo "The account does not exist in the blockchain as it has no balance. You need to initialize it with at least 0.01 NEAR."
    else
      echo "Account $1"
      echo "Has a '$balance'"
    fi
  fi
fi
