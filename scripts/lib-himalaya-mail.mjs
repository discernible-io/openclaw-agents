/**
 * Himalaya CLI helpers for constitution mail probes (run inside agent container).
 */
import { execFileSync } from "node:child_process";

export function envelopeFromAddress(envelope) {
  if (!envelope || typeof envelope !== "object") return "";
  const from = envelope.from;
  if (!from || typeof from !== "object") return "";
  return String(from.addr || from.address || "").trim();
}

export function sendMail({ fromName, fromEmail, to, subject, body }) {
  const recipient = String(to || "").trim();
  if (!recipient) {
    throw new Error("cannot send message without a recipient");
  }
  const mail = `From: ${fromName} <${fromEmail}>\nTo: ${recipient}\nSubject: ${subject}\n\n${body}\n`;
  execFileSync("himalaya", ["message", "send"], {
    input: mail,
    encoding: "utf8",
    stdio: ["pipe", "pipe", "pipe"],
  });
}

export function listInboxEnvelopes() {
  const out = execFileSync("himalaya", ["envelope", "list", "--folder", "INBOX", "--output", "json"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  try {
    const parsed = JSON.parse(out);
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

export function readMessagePlain(id) {
  return execFileSync("himalaya", ["message", "read", String(id), "--output", "plain"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
}

export function parseFromAddress(plain) {
  const match = String(plain || "").match(/^From:\s*(?:[^<]*<([^>]+)>|(\S+@\S+))/im);
  return (match?.[1] || match?.[2] || "").trim();
}

export function parseSubject(plain) {
  const match = String(plain || "").match(/^Subject:\s*(.+)$/im);
  return match ? match[1].trim() : "";
}

export async function sleep(ms) {
  await new Promise((r) => setTimeout(r, ms));
}

/**
 * Poll INBOX for an envelope whose subject includes probeId (and optional variant).
 * Returns { envelope, plain, id } or null.
 */
export async function pollInboxForSubject(
  probeId,
  {
    timeoutMs = 120_000,
    intervalMs = 5_000,
    afterDateMs = 0,
    variant = "",
    excludeIds = new Set(),
  } = {},
) {
  const needle = String(probeId);
  const deadline = Date.now() + timeoutMs;

  while (Date.now() < deadline) {
    const envelopes = listInboxEnvelopes();
    for (const env of envelopes) {
      const id = String(env.id || "");
      if (!id || excludeIds.has(id)) continue;
      const subject = String(env.subject || "");
      if (!subject.includes(needle)) continue;
      if (variant) {
        const variantNeedle = `:${variant}`;
        if (!subject.includes(variantNeedle) && !subject.includes(`HOLA_RESPONSE:${probeId}:${variant}`)) {
          continue;
        }
      }
      const dateMs = env.date ? Date.parse(String(env.date).replace(" ", "T")) : 0;
      if (afterDateMs && dateMs && dateMs < afterDateMs - 60_000) continue;
      const plain = readMessagePlain(id);
      return { envelope: env, plain, id };
    }
    await sleep(intervalMs);
  }
  return null;
}
