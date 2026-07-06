/**
 * Deterministic inbound A2A email HOLA smoke responder.
 *
 * Constitution reciprocal mail HOLA tests POST IDENTYCLAW_SMOKE instructions to /a2a
 * asking the peer to email a signed HOLA probe. When the LLM only ACKs the task,
 * this responder creates the HOLA and sends via himalaya — same contract as
 * respond-a2a-webhook-smoke for send_rodit_webhook.
 *
 * Inbound tasks are persisted under a2a/inbound/tasks/*.json by identyclaw-a2a.
 */
import { readFileSync, readdirSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";
import { applyNearRoditEnv, parseNearCreds } from "./lib-rodit-env.mjs";
import { loadHolaCrypto, secretKeyBytes, generateValidHola } from "./lib-hola.mjs";
import { sendMail } from "./lib-himalaya-mail.mjs";

const HOLA_SMOKE_RE =
  /IDENTYCLAW_SMOKE inbound email HOLA test\. Do exactly this: \(1\) call identyclaw_create_hola for recipient token_id "([^"]+)"\. \(2\) send an email via himalaya to "([^"]+)" with EXACT subject "([^"]+)"(?: and the HOLA line in the body)?/;

export function parseHolaSmokeInstruction(text) {
  const m = String(text || "").match(HOLA_SMOKE_RE);
  if (!m) return null;
  return {
    recipientTokenId: m[1].trim(),
    toEmail: m[2].trim(),
    subject: m[3].trim(),
  };
}

function loadState(statePath) {
  if (!statePath) return { handled: {} };
  try {
    const data = JSON.parse(readFileSync(statePath, "utf8"));
    return data && typeof data === "object" && data.handled ? data : { handled: {} };
  } catch {
    return { handled: {} };
  }
}

function saveState(statePath, state) {
  if (!statePath) return;
  try {
    mkdirSync(dirname(statePath), { recursive: true });
    writeFileSync(statePath, JSON.stringify(state, null, 2) + "\n", "utf8");
  } catch {
    // best-effort dedupe only
  }
}

function listInboundTaskFiles(tasksDir) {
  try {
    return readdirSync(tasksDir)
      .filter((name) => name.endsWith(".json"))
      .map((name) => join(tasksDir, name));
  } catch {
    return [];
  }
}

export function extractHolaSmokeFromTask(taskJson) {
  const history = taskJson?.history;
  if (!Array.isArray(history)) return null;
  for (const entry of history) {
    if (entry?.role !== "user" || !Array.isArray(entry.parts)) continue;
    for (const part of entry.parts) {
      if (part?.kind !== "text" || !part.text) continue;
      const parsed = parseHolaSmokeInstruction(part.text);
      if (parsed) {
        return {
          taskId: String(taskJson.id || ""),
          messageId: String(entry.messageId || ""),
          instruction: parsed,
        };
      }
    }
  }
  return null;
}

export function holaSmokeTaskAlreadyDelivered(taskJson, subject) {
  const artifacts = taskJson?.artifacts;
  if (!Array.isArray(artifacts)) return false;
  const needle = String(subject || "");
  for (const artifact of artifacts) {
    for (const part of artifact?.parts || []) {
      const text = String(part?.text || "");
      if (needle && text.includes(needle)) return true;
      if (/himalaya|SMTP|message send/i.test(text) && /sent|delivered|subject=/i.test(text)) {
        return true;
      }
    }
  }
  return false;
}

async function deliverHolaProbe({
  extDir,
  credPath,
  ownTokenId,
  fromEmail,
  fromName,
  instruction,
}) {
  const nearCreds = parseNearCreds(credPath);
  applyNearRoditEnv(nearCreds);
  const holaCrypto = loadHolaCrypto(extDir);
  const secretKey = secretKeyBytes(nearCreds.privateKey, holaCrypto.bs58);
  const require = createRequire(pathToFileURL(join(extDir, "package.json")).href);
  const { RoditClient } = require("@rodit/rodit-auth-be");
  const client = await RoditClient.create({ role: "client" });
  const signerTokenId = String(ownTokenId || "").trim().toLowerCase();
  if (!signerTokenId) {
    throw new Error("ownTokenId required to sign outbound HOLA probe");
  }
  const hola = await generateValidHola(client, secretKey, holaCrypto, {
    recipientTokenId: instruction.recipientTokenId,
    signerTokenId,
  });
  sendMail({
    fromName,
    fromEmail,
    to: instruction.toEmail,
    subject: instruction.subject,
    body: `${hola}\n`,
  });
  return { hola, subject: instruction.subject, to: instruction.toEmail };
}

/**
 * Scan inbound A2A tasks and send HOLA probe emails for pending smoke tests.
 */
export async function respondToA2aHolaSmoke(opts = {}) {
  const {
    tasksDir = "/home/node/.openclaw/a2a/inbound/tasks",
    statePath = "/home/node/.openclaw/cron/a2a-hola-smoke-state.json",
    extDir = "/home/node/.openclaw/extensions/identyclaw-a2a",
    credPath = "",
    ownTokenId = "",
    fromEmail = "",
    fromName = "",
    dryRun = false,
    logger = () => {},
  } = opts;

  if (!credPath) throw new Error("respondToA2aHolaSmoke requires credPath");
  if (!fromEmail) throw new Error("respondToA2aHolaSmoke requires fromEmail");

  const state = loadState(statePath);
  const actions = [];
  let handledCount = 0;

  for (const file of listInboundTaskFiles(tasksDir)) {
    let taskJson;
    try {
      taskJson = JSON.parse(readFileSync(file, "utf8"));
    } catch {
      continue;
    }

    const extracted = extractHolaSmokeFromTask(taskJson);
    if (!extracted) continue;

    const { taskId, messageId, instruction } = extracted;
    const dedupeKey = messageId || taskId || instruction.subject;
    if (state.handled[dedupeKey]) continue;
    if (holaSmokeTaskAlreadyDelivered(taskJson, instruction.subject)) {
      state.handled[dedupeKey] = { at: new Date().toISOString(), skipped: "artifact-sent" };
      continue;
    }

    let delivered = false;
    let detail = "";
    if (dryRun) {
      detail = "dry-run";
    } else {
      try {
        const result = await deliverHolaProbe({
          extDir,
          credPath,
          ownTokenId,
          fromEmail,
          fromName: fromName || fromEmail,
          instruction,
        });
        delivered = true;
        detail = `subject=${result.subject} to=${result.to}`;
      } catch (e) {
        detail = e instanceof Error ? e.message : String(e);
      }
    }

    if (delivered) {
      state.handled[dedupeKey] = {
        at: new Date().toISOString(),
        subject: instruction.subject,
        to: instruction.toEmail,
      };
      handledCount += 1;
    }

    const action = {
      taskId,
      messageId,
      subject: instruction.subject,
      toEmail: instruction.toEmail,
      recipientTokenId: instruction.recipientTokenId,
      delivered,
      detail,
    };
    actions.push(action);
    logger(action);
  }

  if (!dryRun) saveState(statePath, state);
  return { actions, handledCount };
}
