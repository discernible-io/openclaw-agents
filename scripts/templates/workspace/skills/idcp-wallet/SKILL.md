---
name: idcp-wallet
description: NEAR wallet helpers for IdentyClaw Passport accounts — create implicit accounts, fund, transfer NEAR/RODiT, and rotate Passport ownership via near-cli-rs workspace scripts.
---

# IdentyClaw NEAR wallet (idcp-wallet)

Use these **workspace scripts** (plain `exec`, no `elevated`) for NEAR account and Passport hygiene. They wrap [near-cli-rs](https://github.com/near/near-cli-rs).

Credentials live in `secrets/near-credentials/<account_id>.json`. The active Passport owner is `secrets/near-credentials/.active`.

## Commands

```bash
# List local accounts (marks active)
bash scripts/idcp-wallet.sh

# Create a new uninitialized implicit account (prefer new accounts; do not reuse retired ones)
bash scripts/idcp-wallet.sh genaccount

# Fund / initialize destination with 0.01 NEAR from funding account
# (separate from RODiT transfer — only for new/uninitialized accounts)
bash scripts/idcp-wallet.sh <funding_account> <new_account> init

# Send NEAR
bash scripts/idcp-wallet.sh <origin> <dest> near 0.05
# or: bash scripts/idcp-wallet.sh <origin> <dest> 0.05

# Transfer Passport / RODiT (token_id is the 12-letter Passport id)
# Attaches exactly 0.01 NEAR deposit — that is the full transfer deposit, not ~0.04
bash scripts/idcp-wallet.sh <origin> <dest> <passport_token_id>

# Account summary (RODiTs + balance)
bash scripts/idcp-wallet.sh <account_id>

# Full Passport rotation (create → fund → transfer → re-point active creds)
bash scripts/idcp-rotate-passport.sh <passport_token_id>
# or with an already-created destination:
bash scripts/idcp-rotate-passport.sh <passport_token_id> <destination_account_id>

# Activate an existing account without transferring (re-point only)
bash scripts/idcp-activate-account.sh <account_id>
```

## After rotation / activate

Scripts update `.active`, `.env` (`IDENTYCLAW_ACCOUNT_ID`, private key, credentials path), and `openclaw.json` plugin config. They print `RESTART_REQUIRED`.

Tell the operator to run:

```bash
./identyclaw.sh restart <agent-id>
```

(or `./identyclaw.sh near-activate <agent-id> [account_id]` which activates then restarts).

Passport **token_id** is unchanged; only the NEAR owner account changes.

## Costs (do not invent higher balances)

| Action | NEAR amount | Notes |
|--------|-------------|--------|
| `init` (fund new account) | **0.01 NEAR** sent to destination | Only to create/initialize an empty implicit account |
| Passport / RODiT `rodit_transfer` | **0.01 NEAR** attached deposit | Contract requirement. This is the transfer cost — **not** ~0.041 NEAR |
| Gas | prepaid in the script; unused gas is refunded | Tiny vs deposit (order of ~0.001–0.003 NEAR at mainnet prices). Do **not** refuse a transfer because balance is “only ~0.02 NEAR” |

Wrong: claiming the sender needs ~0.041 NEAR (0.01 deposit + inflated gas) before transferring.  
Right: if the sender already holds ≥ ~0.02 NEAR and the Passport, run the transfer command with the **0.01 NEAR** deposit the script attaches.

## Policy

- **Sensitive:** create/fund/transfer/rotate/activate require HOLA-verified sender **and** operator approval for the specific action (same bar as outbound `exec`).
- **Never** paste private keys into chat. Do not run `idcp-wallet.sh <id> keys` unless the operator explicitly requests it in the main session.
- **Normally do not reuse** retired accounts — create a fresh implicit account per rotation.

## Environment

- `BLOCKCHAIN_ENV` / `NEAR_NETWORK_CONFIG` (default mainnet → `mainnet-fastnear`)
- `NEAR_CONTRACT_ID` / `IDENTYCLAW_NEAR_CONTRACT_ID` (default `genaaaa-identyclaw-com.near`)
- `OPENCLAW_HOME` (default `/home/node/.openclaw`)
