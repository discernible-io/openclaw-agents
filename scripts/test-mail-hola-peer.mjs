#!/usr/bin/env node
/**
 * Email HOLA peer probe: resolve peer contactUri via API, send good/bad HOLA by SMTP,
 * poll inbox for peer reply, verify sender email against Passport contactUri.
 *
 * Usage:
 *   node scripts/test-mail-hola-peer.mjs \
 *     --ext-dir /home/node/.openclaw/extensions/identyclaw-a2a \
 *     --creds /path/to/near-credentials.json \
 *     --peer-token-id bdbfsdcfsnbd \
 *     --from-email archimedes@agenthood.me \
 *     --from-name Andrew \
 *     [--api-base <url>] \
 *     [--poll-seconds 120]
 */
import { resolve } from "node:path";
import {
  applyNearRoditEnv,
  loadRoditAuthBe,
  normalizeApiBaseUrl,
  parseNearCreds,
  resolveRoditApiBaseUrl,
} from "./lib-rodit-env.mjs";
import {
  buildCollaborationEnvelope,
  extractHolaFromText,
  formatEmailBody,
  generateValidHola,
  loadHolaCrypto,
  secretKeyBytes,
  tamperHolaChecksum,
} from "./lib-hola.mjs";
import {
  emailsMatch,
  fetchPeerIdentityFull,
  peerEmailFromIdentity,
  verifyHolaViaApi,
} from "./lib-peer-identity.mjs";
import { parseFromAddress, pollInboxForSubject, sendMail } from "./lib-himalaya-mail.mjs";
import { respondToHolaProbes } from "./lib-mail-responder.mjs";
import { acquireP2pJwtForPeer, fetchJson } from "./lib-rodit-webhook-test.mjs";
import { createTally, reportFinding, reportSkip } from "./lib-test-report.mjs";

function arg(name, fallback = "") {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : fallback;
}

const extDir = resolve(arg("--ext-dir", ""));
const credPath = resolve(arg("--creds", ""));
const peerTokenId = String(arg("--peer-token-id", "")).trim().toLowerCase();
const fromEmail = String(arg("--from-email", "")).trim();
const fromName = String(arg("--from-name", "IdentyClaw Agent")).trim();
const apiBaseArg = arg("--api-base", "");
const peerBase = (arg("--peer-base", "") || "").replace(/\/+$/, "");
const pollSeconds = Math.max(30, Number(arg("--poll-seconds", "120")) || 120);
const skipInbound = process.argv.includes("--skip-inbound");
const requireMailHola =
  process.argv.includes("--require") || process.env.REQUIRE_MAIL_HOLA === "1";

if (!extDir || !credPath || !peerTokenId || !fromEmail) {
  process.stderr.write(
    "usage: test-mail-hola-peer.mjs --ext-dir <a2a> --creds <near.json> --peer-token-id <id> --from-email <addr> [--from-name <name>] [--api-base <url>] [--peer-base <https://peer:port>] [--poll-seconds N] [--skip-inbound] [--require]\n",
  );
  process.exit(2);
}

/** Best-effort helpers can skip; --require / REQUIRE_MAIL_HOLA=1 turns skips into failures. */
function skipOrFail(surface, detail) {
  if (requireMailHola) {
    tally.add(reportFinding(surface, false, `${detail} (REQUIRE_MAIL_HOLA=1)`));
  } else {
    reportSkip(surface, detail);
    tally.addSkip();
  }
}

const nearCreds = parseNearCreds(credPath);
applyNearRoditEnv(nearCreds);
const apiBase = apiBaseArg
  ? normalizeApiBaseUrl(apiBaseArg)
  : await resolveRoditApiBaseUrl({ extDir, credPath });
process.env.IDENTYCLAW_BASE_URL = apiBase;

const { RoditClient } = loadRoditAuthBe(extDir);
const holaCrypto = loadHolaCrypto(extDir);
const secretKey = secretKeyBytes(nearCreds.privateKey, holaCrypto.bs58);

const tally = createTally();

function record(surface, matchesContract, detail = "") {
  tally.add(reportFinding(surface, matchesContract, detail));
}

console.log("Email HOLA peer probe");
console.log(`  API:   ${apiBase}`);
console.log(`  peer:  ${peerTokenId}`);
console.log(`  from:  ${fromEmail}`);
console.log("");

let identity;
let peerEmail = "";
try {
  ({ identity } = await fetchPeerIdentityFull(extDir, credPath, peerTokenId, apiBase));
  peerEmail = peerEmailFromIdentity(identity);
  record(
    "GET /api/identity/token/{peer}/full contactUri email",
    Boolean(peerEmail),
    peerEmail ? peerEmail : "no parseable email in dn.contactUri",
  );
} catch (e) {
  const msg = e instanceof Error ? e.message : String(e);
  record("GET /api/identity/token/{peer}/full contactUri email", false, msg);
  tally.printSummary("Summary");
  process.exit(tally.exitCode());
}

const client = await RoditClient.create({ role: "client" });
const ownConfig = await client.getConfigOwnRodit();
const ownTokenId = String(ownConfig?.own_rodit?.token_id || "").toLowerCase();
if (!ownTokenId) {
  record("own passport token_id", false, "missing from getConfigOwnRodit()");
  tally.printSummary("Summary");
  process.exit(tally.exitCode());
}

const login = await client.login_server();
const jwt = login?.jwt_token;
if (!jwt) {
  record("POST /api/login session JWT", false, login?.error || "login_server failed");
  tally.printSummary("Summary");
  process.exit(tally.exitCode());
}

const goodHola = await generateValidHola(client, secretKey, holaCrypto, {
  recipientTokenId: peerTokenId,
  signerTokenId: ownTokenId,
});
const badHola = tamperHolaChecksum(goodHola);

const goodVerify = await verifyHolaViaApi(apiBase, jwt, goodHola, peerTokenId);
record(
  "POST /api/identity/verify good HOLA (pre-send)",
  goodVerify.status === 200 && goodVerify.payload?.verified === true,
  `HTTP ${goodVerify.status} verified=${goodVerify.payload?.verified} peerTokenId=${goodVerify.payload?.peerTokenId || "—"}`,
);

const badVerify = await verifyHolaViaApi(apiBase, jwt, badHola, peerTokenId);
record(
  "POST /api/identity/verify bad HOLA (pre-send)",
  badVerify.payload?.verified !== true,
  `HTTP ${badVerify.status} verified=${badVerify.payload?.verified}`,
);

const probeId = `hola-mail-${Date.now()}`;
const sendStartedMs = Date.now();

function makeSubject(variant) {
  return `IDENTYCLAW_HOLA_PROBE:${probeId}:${variant}`;
}

async function sendProbe(variant, hola) {
  const envelope = buildCollaborationEnvelope({
    messageId: `${probeId}-${variant}`,
    fromTokenId: ownTokenId,
    toTokenId: peerTokenId,
    contactUri: identity?.dn?.contactUri || `email:${peerEmail.split("@")[1] || "unknown"}:${peerEmail}`,
    hola,
    variant,
    probeId,
  });
  const body = formatEmailBody(envelope);
  try {
    sendMail({
      fromName,
      fromEmail,
      to: peerEmail,
      subject: makeSubject(variant),
      body,
    });
    return true;
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    record(`SMTP send ${variant} HOLA to peer email`, false, msg);
    return false;
  }
}

if (await sendProbe("good", goodHola)) {
  record(`SMTP send good HOLA to ${peerEmail}`, true, `subject=${makeSubject("good")}`);
}
if (await sendProbe("bad", badHola)) {
  record(`SMTP send bad HOLA to ${peerEmail}`, true, `subject=${makeSubject("bad")}`);
}

const consumedReplyIds = new Set();

async function assessReply(variant, expectedVerified) {
  const hit = await pollInboxForSubject(probeId, {
    timeoutMs: pollSeconds * 1000,
    intervalMs: 5_000,
    afterDateMs: sendStartedMs,
    variant,
    excludeIds: consumedReplyIds,
  });
  if (!hit) {
    skipOrFail(
      `INBOX reply for ${variant} HOLA probe`,
      `no message with probeId within ${pollSeconds}s — peer mail responder may not be running (see respond-mail)`,
    );
    return;
  }
  consumedReplyIds.add(hit.id);

  const subject = hit.envelope.subject || "";

  const senderEmail = parseFromAddress(hit.plain);
  record(
    `INBOX reply From for ${variant} HOLA probe`,
    Boolean(senderEmail),
    senderEmail || "no From address",
  );

  const senderMatchesContactUri = emailsMatch(senderEmail, peerEmail);
  record(
    `peer email matches Passport contactUri (${variant} reply)`,
    senderMatchesContactUri,
    senderMatchesContactUri
      ? `${senderEmail} matches API contactUri`
      : `From=${senderEmail || "—"} API contactUri=${peerEmail}`,
  );

  const holaInReply = extractHolaFromText(hit.plain);
  if (!holaInReply) {
    record(
      `HOLA line in ${variant} reply body`,
      expectedVerified === false,
      expectedVerified ? "no HOLA in reply" : "no HOLA in reply (acceptable for bad probe)",
    );
    return;
  }

  const verify = await verifyHolaViaApi(apiBase, jwt, holaInReply, ownTokenId);
  const verified = verify.payload?.verified === true;
  record(
    `POST /api/identity/verify HOLA in ${variant} reply`,
    verified === expectedVerified,
    `HTTP ${verify.status} verified=${verify.payload?.verified} peerTokenId=${verify.payload?.peerTokenId || "—"}`,
  );

  if (expectedVerified && verified) {
    const peerFromHola = String(verify.payload?.peerTokenId || "").toLowerCase();
    record(
      `reply HOLA peerTokenId matches ${peerTokenId}`,
      peerFromHola === peerTokenId,
      `peerTokenId=${peerFromHola || "—"}`,
    );
  }
}

console.log("");
console.log("--- Outbound: we probe peer, peer's responder replies ---");
console.log(`--- Poll INBOX for probeId=${probeId} (up to ${pollSeconds}s per variant) ---`);

await assessReply("good", true);
await assessReply("bad", false);

/**
 * Inbound: just as we probe peers, peers probe us. Drive the live peer (P2P login +
 * A2A message/send) to email US a HOLA probe, then exercise OUR responder against it
 * — verifying we receive, verify the peer's HOLA, and reply per contract.
 */
async function driveLivePeerToEmailUs(inboundProbeId) {
  const jwtPeer = await acquireP2pJwtForPeer(peerBase, extDir.replace(/\/extensions\/.*$/, ""));
  const subject = `IDENTYCLAW_HOLA_PROBE:${inboundProbeId}:good`;
  const msgId = `mail-inbound-${Date.now()}`;
  const instruction =
    `IDENTYCLAW_SMOKE inbound email HOLA test. Do exactly this: ` +
    `(1) call identyclaw_create_hola for recipient token_id "${ownTokenId}". ` +
    `(2) send an email via himalaya to "${fromEmail}" with EXACT subject "${subject}" ` +
    `and the HOLA line in the body. Reply with the subject line you sent.`;
  const a2aUrl = `${peerBase}/a2a`;
  const { status, json, text } = await fetchJson(a2aUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${jwtPeer}` },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: msgId,
      method: "message/send",
      params: { message: { role: "user", parts: [{ kind: "text", text: instruction }], messageId: msgId } },
    }),
  });
  if (status < 200 || status >= 300) {
    throw new Error(`A2A message/send to peer failed: HTTP ${status} ${String(text).slice(0, 200)}`);
  }
  return { subject, status, json };
}

console.log("");
console.log("--- Inbound: peer probes us, our responder replies (reciprocal) ---");
if (skipInbound) {
  skipOrFail("inbound email HOLA (peer → us)", "--skip-inbound");
} else if (!peerBase) {
  skipOrFail("inbound email HOLA (peer → us)", "no --peer-base (peer A2A gateway to drive the probe)");
} else {
  const inboundProbeId = `hola-mail-in-${Date.now()}`;
  const inboundStartedMs = Date.now();
  let driven = false;
  try {
    const drive = await driveLivePeerToEmailUs(inboundProbeId);
    driven = true;
    record(
      "A2A message/send: ask peer to email us a HOLA probe",
      drive.status >= 200 && drive.status < 300,
      `HTTP ${drive.status} subject=${drive.subject}`,
    );
  } catch (e) {
    skipOrFail(
      "A2A message/send: ask peer to email us a HOLA probe",
      e instanceof Error ? e.message : String(e),
    );
  }

  if (driven) {
    const inboundHit = await pollInboxForSubject(inboundProbeId, {
      timeoutMs: pollSeconds * 1000,
      intervalMs: 5_000,
      afterDateMs: inboundStartedMs,
    });
    if (!inboundHit) {
      skipOrFail(
        "INBOX inbound HOLA probe from peer",
        `no probe with ${inboundProbeId} within ${pollSeconds}s — peer may not send by email`,
      );
    } else {
      record("INBOX inbound HOLA probe from peer", true, `subject=${inboundHit.envelope.subject || "—"}`);

      const ctx = { client, jwt, apiBase, ownTokenId, secretKey, holaCrypto, fromName, fromEmail };
      const { actions } = await respondToHolaProbes(ctx, {
        probeId: inboundProbeId,
        afterDateMs: inboundStartedMs,
        statePath: "",
      });
      const action = actions.find((a) => a.probeId === inboundProbeId);
      if (!action) {
        record("our responder handled inbound probe", false, "responder found no matching probe");
      } else {
        record(
          "our responder verified peer HOLA",
          action.verified === true,
          `verified=${action.verified} peerTokenId=${action.peerTokenId || "—"} (HTTP ${action.verifyStatus})`,
        );
        record(
          "inbound HOLA peerTokenId matches peer",
          action.verified && action.peerTokenId === peerTokenId,
          `peerTokenId=${action.peerTokenId || "—"} expected=${peerTokenId}`,
        );
        record(
          "our responder replied to peer",
          action.replied === true,
          action.replied
            ? `sent ${action.responseSubject} to ${action.senderEmail}`
            : action.replyError || "no reply sent",
        );
      }
    }
  }
}

tally.printSummary("Summary");
process.exit(tally.exitCode());
