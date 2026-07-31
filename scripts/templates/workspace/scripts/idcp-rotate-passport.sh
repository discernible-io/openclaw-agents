#!/bin/bash
#SPDX-License-Identifier: GPL-2.0
#Copyright (C) 2026 Discernible-IO All Rights Reserved.
#
# Rotate IdentyClaw Passport to a new NEAR implicit account:
#   1. create destination (genaccount) unless provided
#   2. fund destination with 0.01 NEAR from active owner
#   3. rodit_transfer Passport token_id
#   4. activate new account (re-point .active + .env + plugin config)
#
# Usage:
#   sh scripts/idcp-rotate-passport.sh <passport_token_id> [destination_account_id]
#
# Sensitive: requires operator approval. Do not reuse retired accounts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WALLET="${SCRIPT_DIR}/idcp-wallet.sh"
ACTIVATE="${SCRIPT_DIR}/idcp-activate-account.sh"
# Prefer bash: /bin/sh is dash in the agent image and rejects [[ / regex.
run_wallet() { bash "$WALLET" "$@"; }
run_activate() { bash "$ACTIVATE" "$@"; }

OPENCLAW_HOME="${OPENCLAW_HOME:-/home/node/.openclaw}"
SECRETS_DIR="${IDENTYCLAW_NEAR_CREDENTIALS_DIR:-$OPENCLAW_HOME/secrets/near-credentials}"

passport_id="${1:-}"
dest_account="${2:-}"

if [ -z "$passport_id" ]; then
  echo "Usage: $0 <passport_token_id> [destination_account_id]" >&2
  exit 1
fi

if ! [[ "$passport_id" =~ ^[a-z]{12}$ ]]; then
  echo "ERROR: passport_token_id must be a 12-letter IdentyClaw Passport id" >&2
  exit 1
fi

active_file="$SECRETS_DIR/.active"
if [ ! -f "$active_file" ]; then
  # Fall back to sole credential file
  count="$(find "$SECRETS_DIR" -maxdepth 1 -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${count:-0}" = "1" ]; then
    sole="$(basename "$(find "$SECRETS_DIR" -maxdepth 1 -name '*.json' -type f | head -1)" .json)"
    printf '%s\n' "$sole" >"$active_file"
  else
    echo "ERROR: no active account (.active). Run: sh scripts/idcp-activate-account.sh <account_id>" >&2
    exit 1
  fi
fi

origin="$(tr -d '[:space:]' <"$active_file")"
if [ -z "$origin" ] || [ ! -f "$SECRETS_DIR/${origin}.json" ]; then
  echo "ERROR: active account '$origin' has no credentials file" >&2
  exit 1
fi

if [ -z "$dest_account" ]; then
  echo "==> Creating new implicit account (not for reuse of retired wallets)..."
  dest_account="$(run_wallet genaccount | awk '/^[0-9a-f]{64}$/{print; exit}')"
  if [ -z "$dest_account" ]; then
    echo "ERROR: genaccount did not return an account id" >&2
    exit 1
  fi
  echo "    New account: $dest_account"
else
  if [ ! -f "$SECRETS_DIR/${dest_account}.json" ]; then
    echo "ERROR: destination credentials not found: $SECRETS_DIR/${dest_account}.json" >&2
    exit 1
  fi
fi

if [ "$origin" = "$dest_account" ]; then
  echo "ERROR: origin and destination must differ" >&2
  exit 1
fi

echo "==> Funding $dest_account with 0.01 NEAR from $origin..."
run_wallet "$origin" "$dest_account" init

echo "==> Transferring Passport $passport_id from $origin to $dest_account..."
run_wallet "$origin" "$dest_account" "$passport_id"

echo "==> Re-pointing active credentials to $dest_account..."
run_activate "$dest_account"

echo ""
echo "Passport $passport_id now owned by $dest_account (previous owner $origin left inactive)."
echo "Do not reuse $origin for new Passports."
