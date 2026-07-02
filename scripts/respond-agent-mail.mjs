#!/usr/bin/env node
/**
 * Inbound HOLA email responder (runs inside an agent container).
 *
 * Polls INBOX for IDENTYCLAW_HOLA_PROBE messages, verifies each inbound HOLA via
 * the IdentyClaw API, and replies per the collaboration contract:
 *   - verified probe  → HOLA_RESPONSE with our signed HOLA
 *   - invalid probe   → HOLA_RESPONSE rejection (no HOLA line)
 *
 * This is the receiving-side capability that lets peers test against us over email,
 * the same way we probe them. Wire it into a heartbeat/cron (see respond-agent-mail.sh).
 *
 * Usage:
 *   node scripts/respond-agent-mail.mjs \
 *     --ext-dir /home/node/.openclaw/extensions/identyclaw-a2a \
 *     --creds /home/node/.openclaw/secrets/near-credentials/<id>.json \
 *     --from-email agent-a@identyclaw.com --from-name "Agent A" \
 *     [--api-base <url>] [--probe-id <id>] [--state <path>] [--dry-run]
 */
import { resolve } from "node:path";
import { createMailHolaContext, respondToHolaProbes } from "./lib-mail-responder.mjs";

function arg(name, fallback = "") {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : fallback;
}

const extDir = resolve(arg("--ext-dir", ""));
const credPath = resolve(arg("--creds", ""));
const fromEmail = String(arg("--from-email", "")).trim();
const fromName = String(arg("--from-name", "IdentyClaw Agent")).trim();
const apiBaseArg = arg("--api-base", "");
const probeId = arg("--probe-id", "");
const statePath = arg("--state", "/home/node/.openclaw/cron/mail-responder-state.json");
const dryRun = process.argv.includes("--dry-run");

if (!extDir || !credPath || !fromEmail) {
  process.stderr.write(
    "usage: respond-agent-mail.mjs --ext-dir <a2a> --creds <near.json> --from-email <addr> " +
      "[--from-name <name>] [--api-base <url>] [--probe-id <id>] [--state <path>] [--dry-run]\n",
  );
  process.exit(2);
}

const ctx = await createMailHolaContext({ extDir, credPath, apiBaseArg, fromName, fromEmail });

const { actions, handledCount } = await respondToHolaProbes(ctx, {
  probeId,
  statePath,
  dryRun,
  logger: (a) => {
    const status = a.replied
      ? `replied ${a.responseSubject}`
      : a.replyError
        ? `reply-failed ${a.replyError}`
        : "no-reply (no sender address)";
    process.stdout.write(
      `[mail-responder] probe=${a.probeId}:${a.variant} from=${a.senderEmail || "?"} ` +
        `verified=${a.verified}${a.inboundHola ? "" : " (no-hola)"} → ${status}\n`,
    );
  },
});

process.stdout.write(
  `[mail-responder] ${actions.length} probe(s) seen, ${handledCount} replied${dryRun ? " (dry-run)" : ""}\n`,
);
process.exit(0);
