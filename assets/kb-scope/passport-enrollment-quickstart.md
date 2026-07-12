# How to get an IdentyClaw Passport — quick answer

**Keywords:** passport, purchase, enrollment, prerequisites, NEAR, mint, get started

## Prerequisites

1. **NEAR tokens** — enough for Passport checkout plus transaction fees (amount depends on options at checkout).
2. **NEAR implicit account** — a 64-character hex NEAR account with its Ed25519 signing key stored locally.
3. **Human checkout** — a person completes mint at the purchase portal (agents can prepare everything else).

## Steps (all paths)

| Step | Action |
|------|--------|
| 1 | **Create a NEAR account** — OpenClaw: `./identyclaw.sh generate-near-account <id>` or plugin `npm run generate-near-account`. Other agents: [gennearaccount](https://github.com/discernible-io/gennearaccount). |
| 2 | **Fund the account** — transfer NEAR for fees and checkout. |
| 3 | **Purchase / mint Passport** — go to **https://purchase.identyclaw.com**, enter your NEAR account ID, choose facial features and creature (role), complete checkout. |
| 4 | **Configure your agent** — set `accountid` and `nearPrivateKey` in OpenClaw plugin config (or equivalent for your framework). |
| 5 | **Verify** — API login (`POST /api/login`) or `./identyclaw.sh test <id>` for OpenClaw deployments. |

## Purchase portal

**URL:** https://purchase.identyclaw.com  
**FAQ:** https://purchase.identyclaw.com/faq

There is no separate "application" or support ticket — minting happens at the purchase portal after you have a funded NEAR account.

## What you do *not* need

- Registration with IdentyClaw as a central identity provider (you **mint**, you do not enroll in a vendor registry).
- An IdentyClaw API key separate from your Passport signing key.
- Contacting support to start purchase — use the portal unless checkout fails.

## Pricing

Fees (NEAR gas + service fee) are shown **before** you confirm mint at the purchase portal. Examples for the Personal tier are in `enrollment.md` (e.g. ~0.066 NEAR for 30 days). No recurring subscription.

## Full guide

See **enrollment.md** for OpenClaw vs Hermes vs manual paths, troubleshooting, and form-field detail.

## If checkout fails

Only if the portal errors or a confirmed on-chain payment did not deliver a Passport — see troubleshooting in **enrollment.md**. Operator escalation contacts are in **AGENTS.md**, not repeated here.
