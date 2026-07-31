/**
 * Deterministic inbound A2A webhook smoke responder.
 *
 * Constitution inbound webhook tests POST IDENTYCLAW_SMOKE instructions to /a2a.
 * When the LLM is unavailable (missing API key, billing, timeout), peers must still
 * execute send_rodit_webhook — same contract as respond-mail for email HOLA.
 *
 * Inbound tasks are persisted under a2a/inbound/tasks/*.json by identyclaw-a2a.
 */
import { readFileSync, readdirSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";

const WEBHOOK_SMOKE_RE =
  /IDENTYCLAW_SMOKE inbound webhook test\. Call tool send_rodit_webhook exactly once with: peerId="([^"]+)", text="([^"]+)", delaySeconds=(\d+), hookPath="([^"]+)"/;

export function parseWebhookSmokeInstruction(text) {
  const m = String(text || "").match(WEBHOOK_SMOKE_RE);
  if (!m) return null;
  return {
    peerId: m[1].toLowerCase(),
    text: m[2],
    delaySeconds: Number(m[3]) || 0,
    hookPath: m[4] || "hooks/wake",
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

export function extractSmokeFromTask(taskJson) {
  const history = taskJson?.history;
  if (!Array.isArray(history)) return null;
  for (const entry of history) {
    if (entry?.role !== "user" || !Array.isArray(entry.parts)) continue;
    for (const part of entry.parts) {
      if (part?.kind !== "text" || !part.text) continue;
      const parsed = parseWebhookSmokeInstruction(part.text);
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

export function taskAlreadyDelivered(taskJson, marker) {
  const artifacts = taskJson?.artifacts;
  if (!Array.isArray(artifacts)) return false;
  for (const artifact of artifacts) {
    for (const part of artifact?.parts || []) {
      const text = String(part?.text || "");
      if (text.includes(marker) && /"ok"\s*:\s*true/.test(text)) return true;
      if (/send[_-]rodit[_-]webhook/i.test(text) && /"ok"\s*:\s*true/.test(text)) return true;
    }
  }
  return false;
}

function runSendRoditWebhook({ sendScript, credPath, configPath, instruction }) {
  const args = [
    sendScript,
    "--peer",
    instruction.peerId,
    "--text",
    instruction.text,
    "--delay",
    String(instruction.delaySeconds),
    "--path",
    instruction.hookPath,
    "--config",
    configPath,
    "--creds",
    credPath,
  ];
  const result = spawnSync("node", args, {
    encoding: "utf8",
    env: { ...process.env, NEAR_CREDENTIALS_FILE_PATH: credPath },
  });
  const output = `${result.stdout || ""}${result.stderr || ""}`.trim();
  let ok = result.status === 0;
  if (!ok && /"ok"\s*:\s*true/.test(output)) ok = true;
  return { ok, output, status: result.status ?? 1 };
}

/**
 * Scan inbound A2A tasks and execute send_rodit_webhook for pending smoke tests.
 */
export function respondToA2aWebhookSmoke(opts = {}) {
  const {
    tasksDir = "/home/node/.openclaw/a2a/inbound/tasks",
    statePath = "/home/node/.openclaw/cron/a2a-webhook-smoke-state.json",
    sendScript = "/tmp/send-rodit-webhook.mjs",
    credPath = "",
    configPath = "/home/node/.openclaw/openclaw.json",
    dryRun = false,
    logger = () => {},
  } = opts;

  if (!credPath) {
    throw new Error("respondToA2aWebhookSmoke requires credPath");
  }

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

    const extracted = extractSmokeFromTask(taskJson);
    if (!extracted) continue;

    const { taskId, messageId, instruction } = extracted;
    const dedupeKey = messageId || taskId || instruction.text;
    if (state.handled[dedupeKey]) continue;
    if (taskAlreadyDelivered(taskJson, instruction.text)) {
      state.handled[dedupeKey] = { at: new Date().toISOString(), skipped: "artifact-ok" };
      continue;
    }

    let delivered = false;
    let detail = "";
    if (dryRun) {
      detail = "dry-run";
    } else {
      const send = runSendRoditWebhook({ sendScript, credPath, configPath, instruction });
      delivered = send.ok;
      detail = send.output.slice(0, 400) || `exit ${send.status}`;
    }

    if (delivered) {
      state.handled[dedupeKey] = {
        at: new Date().toISOString(),
        peerId: instruction.peerId,
        text: instruction.text,
      };
      handledCount += 1;
    }

    const action = {
      taskId,
      messageId,
      peerId: instruction.peerId,
      marker: instruction.text,
      delivered,
      detail,
    };
    actions.push(action);
    logger(action);
  }

  if (!dryRun) saveState(statePath, state);
  return { actions, handledCount };
}
