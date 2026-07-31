/**
 * Deterministic inbound HOLA email responder.
 *
 * This is the receiving-side capability that makes email HOLA tests reciprocal:
 * just as we probe peers, peers probe us — so an agent must poll its inbox,
 * verify inbound HOLA probes, and reply. Same contract the outbound probe expects
 * (subject `HOLA_RESPONSE:{probeId}:{variant}`, reply via contactUri).
 *
 * Trust rule: only reciprocate a signed HOLA when the inbound HOLA verifies.
 * A tampered/invalid probe gets a rejection reply with NO HOLA line.
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { extractHolaFromText, generateValidHola, loadHolaCrypto, secretKeyBytes } from "./lib-hola.mjs";
import {
  envelopeFromAddress,
  listInboxEnvelopes,
  parseFromAddress,
  readMessagePlain,
  sendMail,
} from "./lib-himalaya-mail.mjs";
import { contactUriToEmail, peerEmailFromIdentity, verifyInboundProbeHola } from "./lib-peer-identity.mjs";
import {
  applyNearRoditEnv,
  loadRoditAuthBe,
  normalizeApiBaseUrl,
  parseNearCreds,
  resolveRoditApiBaseUrl,
} from "./lib-rodit-env.mjs";

/**
 * Build the shared context (client, session JWT, own token_id, signing key, crypto)
 * needed to verify inbound HOLA and sign replies. Reused by the responder CLI and
 * the inbound direction of the mail HOLA test.
 */
export async function createMailHolaContext({ extDir, credPath, apiBaseArg = "", fromName, fromEmail }) {
  const nearCreds = parseNearCreds(credPath);
  applyNearRoditEnv(nearCreds);
  const apiBase = apiBaseArg
    ? normalizeApiBaseUrl(apiBaseArg)
    : await resolveRoditApiBaseUrl({ extDir, credPath });
  process.env.IDENTYCLAW_BASE_URL = apiBase;

  const { RoditClient } = loadRoditAuthBe(extDir);
  const holaCrypto = loadHolaCrypto(extDir);
  const secretKey = secretKeyBytes(nearCreds.privateKey, holaCrypto.bs58);

  const client = await RoditClient.create({ role: "client" });
  const ownConfig = await client.getConfigOwnRodit();
  const ownTokenId = String(ownConfig?.own_rodit?.token_id || "").toLowerCase();
  if (!ownTokenId) throw new Error("own passport token_id missing from getConfigOwnRodit()");

  const login = await client.login_server();
  const jwt = login?.jwt_token;
  if (!jwt) throw new Error(login?.error || "login_server failed (no session JWT)");

  return { client, jwt, apiBase, ownTokenId, secretKey, holaCrypto, fromName, fromEmail };
}

const PROBE_SUBJECT_RE = /IDENTYCLAW_HOLA_PROBE:([^\s:]+):([^\s:]+)/i;

export function parseProbeSubject(subject) {
  const m = String(subject || "").match(PROBE_SUBJECT_RE);
  if (!m) return null;
  return { probeId: m[1], variant: m[2] };
}

/** Pull the identyclaw.collaboration.v1 JSON envelope out of a plain message body. */
export function parseEnvelopeJson(plain) {
  const raw = String(plain || "");
  const start = raw.indexOf("{");
  const end = raw.lastIndexOf("}");
  if (start < 0 || end <= start) return null;
  try {
    return JSON.parse(raw.slice(start, end + 1));
  } catch {
    return null;
  }
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
    // best-effort; a failed write only risks a duplicate reply next run
  }
}

function responseSubject(probeId, variant) {
  return `HOLA_RESPONSE:${probeId}:${variant}`;
}

export function mailRejectionOmitsHolaLine(body) {
  return !/HOLA\/[^\s]+/i.test(String(body || ""));
}

/** @internal test helper */
export function buildRejectionMailBody(envelope, reason) {
  return rejectionResponseBody(envelope, reason);
}

function verifiedResponseBody(envelope, hola) {
  const body = {
    schema: "identyclaw.collaboration.v1",
    timestamp: new Date().toISOString(),
    task: { type: "HOLA_RESPONSE", payload: { probeId: envelope.probeId, variant: envelope.variant } },
    inReplyTo: envelope.messageId || null,
    verified: true,
  };
  return `--- identyclaw.collaboration.v1 ---\n${JSON.stringify(body, null, 2)}\n\n${hola}\n`;
}

/**
 * Resolve the SMTP reply recipient for an inbound HOLA probe.
 * Himalaya envelope metadata is preferred when plain body omits headers.
 */
export function resolveReplyRecipientEmail({ plain = "", jsonEnvelope = {}, envelope = null }) {
  const fromHeader = parseFromAddress(plain);
  if (fromHeader) return fromHeader;

  const envAddr = envelopeFromAddress(envelope);
  if (envAddr) return envAddr;

  const fromObj = jsonEnvelope?.from;
  if (fromObj && typeof fromObj === "object") {
    const direct = String(fromObj.email || "").trim();
    if (direct) return direct;
    const fromUri = contactUriToEmail(fromObj.contactUri);
    if (fromUri) return fromUri;
  }

  return "";
}

async function resolveReplyRecipientWithApi(apiBase, jwt, senderTokenId, partial) {
  const existing = resolveReplyRecipientEmail(partial);
  if (existing || !senderTokenId || !apiBase || !jwt) {
    return existing;
  }
  const res = await fetch(
    `${String(apiBase).replace(/\/+$/, "")}/api/identity/token/${encodeURIComponent(senderTokenId)}/full`,
    { headers: { authorization: `Bearer ${jwt}` } },
  );
  if (!res.ok) return "";
  const identity = await res.json().catch(() => null);
  return peerEmailFromIdentity(identity);
}

function rejectionResponseBody(envelope, reason) {
  // Must NOT contain a "HOLA/" line — an unverified sender gets no signed credential back.
  const body = {
    schema: "identyclaw.collaboration.v1",
    timestamp: new Date().toISOString(),
    task: { type: "HOLA_RESPONSE", payload: { probeId: envelope.probeId, variant: envelope.variant } },
    inReplyTo: envelope.messageId || null,
    verified: false,
    reason: String(reason || "verification failed").replace(/HOLA\//gi, "credential "),
  };
  return `--- identyclaw.collaboration.v1 ---\n${JSON.stringify(body, null, 2)}\n`;
}

/**
 * Find inbound HOLA probes in INBOX, verify each, and reply per contract.
 *
 * @param {object} deps client, jwt, apiBase, ownTokenId, secretKey, holaCrypto, fromName, fromEmail
 * @param {object} [opts] probeId, afterDateMs, onlyVariant, excludeIds, statePath, dryRun, logger
 * @returns {Promise<{actions: Array, handledCount: number}>}
 */
export async function respondToHolaProbes(deps, opts = {}) {
  const { client, jwt, apiBase, ownTokenId, secretKey, holaCrypto, fromName, fromEmail } = deps;
  const {
    probeId = "",
    afterDateMs = 0,
    onlyVariant = "",
    excludeIds = new Set(),
    statePath = "",
    dryRun = false,
    logger = () => {},
  } = opts;

  if (!ownTokenId || !fromEmail) {
    throw new Error("respondToHolaProbes requires deps.ownTokenId and deps.fromEmail");
  }

  const state = loadState(statePath);
  const actions = [];
  const envelopes = listInboxEnvelopes();

  for (const env of envelopes) {
    const id = String(env.id || "");
    if (!id || excludeIds.has(id)) continue;

    const subject = String(env.subject || "");
    const parsed = parseProbeSubject(subject);
    if (!parsed) continue;
    if (probeId && parsed.probeId !== probeId) continue;
    if (onlyVariant && parsed.variant !== onlyVariant) continue;

    const dateMs = env.date ? Date.parse(String(env.date).replace(" ", "T")) : 0;
    if (afterDateMs && dateMs && dateMs < afterDateMs - 60_000) continue;

    const dedupeKey = `${parsed.probeId}:${parsed.variant}`;
    if (state.handled[dedupeKey]) {
      excludeIds.add(id);
      continue;
    }

    const plain = readMessagePlain(id);
    const jsonEnvelope = parseEnvelopeJson(plain) || {};
    const senderTokenId = String(jsonEnvelope?.from?.tokenId || "").trim().toLowerCase();
    const senderEmail = await resolveReplyRecipientWithApi(apiBase, jwt, senderTokenId, {
      plain,
      jsonEnvelope,
      envelope: env,
    });
    const inboundHola =
      String(jsonEnvelope?.hola || "").trim() || extractHolaFromText(plain);

    const envelopeMeta = {
      probeId: parsed.probeId,
      variant: parsed.variant,
      messageId: jsonEnvelope?.messageId || `${parsed.probeId}-${parsed.variant}`,
    };

    let verified = false;
    let verifyStatus = 0;
    let peerTokenId = "";
    let acceptedDespiteReplay = false;
    let verifyFailureReasons = [];
    if (inboundHola) {
      const verify = await verifyInboundProbeHola(apiBase, jwt, inboundHola, {
        ownTokenId,
        senderTokenId,
        envelopeToTokenId: String(jsonEnvelope?.to?.tokenId || "").trim().toLowerCase(),
      });
      verifyStatus = verify.status;
      verified = verify.verified === true;
      peerTokenId = verify.peerTokenId;
      acceptedDespiteReplay = verify.acceptedDespiteReplay === true;
      verifyFailureReasons = verify.payload?.failureReasons || [];
    }

    let subjectOut = responseSubject(parsed.probeId, parsed.variant);
    let bodyOut;
    if (verified) {
      const replyHola = await generateValidHola(client, secretKey, holaCrypto, {
        recipientTokenId: senderTokenId || peerTokenId,
        signerTokenId: ownTokenId,
      });
      bodyOut = verifiedResponseBody(envelopeMeta, replyHola);
    } else {
      bodyOut = rejectionResponseBody(
        envelopeMeta,
        inboundHola ? "inbound HOLA did not verify" : "no HOLA line in probe",
      );
    }

    let replied = false;
    let replyError = "";
    if (!senderEmail) {
      replyError = "no reply recipient resolved (From header, envelope, JSON from, or API contactUri)";
    } else if (!dryRun) {
      try {
        sendMail({ fromName, fromEmail, to: senderEmail, subject: subjectOut, body: bodyOut });
        replied = true;
      } catch (e) {
        replyError = e instanceof Error ? e.message : String(e);
      }
    }

    if (replied) {
      state.handled[dedupeKey] = { at: new Date().toISOString(), to: senderEmail, verified };
      excludeIds.add(id);
    }

    const action = {
      id,
      probeId: parsed.probeId,
      variant: parsed.variant,
      senderEmail,
      senderTokenId,
      inboundHola: Boolean(inboundHola),
      verified,
      verifyStatus,
      peerTokenId,
      acceptedDespiteReplay,
      verifyFailureReasons,
      replied,
      replyError,
      responseSubject: subjectOut,
    };
    actions.push(action);
    logger(action);
  }

  if (!dryRun) saveState(statePath, state);
  return { actions, handledCount: actions.filter((a) => a.replied).length };
}
