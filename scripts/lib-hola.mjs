/**
 * HOLA line generation and parsing (Ed25519 + base32 checksum).
 * Same canonical rules as test-webhooks-testhola.mjs and @rodit/hola-client.
 */
import { createRequire } from "node:module";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const HOLA_CHECKSUM_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ";
const BASE32_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
const HOLA_LINE_RE = /HOLA\/[^\s<>"']+/i;

export function loadHolaCrypto(extDir) {
  const require = createRequire(pathToFileURL(join(extDir, "package.json")).href);
  return {
    nacl: require("tweetnacl"),
    bs58: require("bs58"),
  };
}

export function secretKeyBytes(nearPrivateKey, bs58) {
  const body = nearPrivateKey.replace(/^ed25519:/, "").trim();
  const decoded = bs58.decode(body);
  if (decoded.length !== 64 && decoded.length < 32) {
    throw new Error(`Invalid NEAR private key length: ${decoded.length}`);
  }
  return new Uint8Array(decoded);
}

function bytesToBase32(bytes) {
  let bits = 0;
  let value = 0;
  let output = "";
  for (const byte of bytes) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      output += BASE32_ALPHABET[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) output += BASE32_ALPHABET[(value << (5 - bits)) & 31];
  return output;
}

export function computeHolaChecksum(messagePrefix) {
  let sum = 0;
  for (let i = 0; i < messagePrefix.length; i++) sum += messagePrefix.charCodeAt(i);
  return HOLA_CHECKSUM_ALPHABET[sum % 23];
}

export function signMessageWithEd25519(message, secretKey, nacl) {
  const messageBytes = new TextEncoder().encode(message);
  const signatureBytes = nacl.sign.detached(messageBytes, secretKey);
  return bytesToBase32(signatureBytes);
}

export async function fetchHolanonce(client) {
  try {
    const data = await client.request("GET", "/api/holanonce16ts");
    return {
      noncetsHex: data.noncetsHex || "4F9A3C7E2D1B9A4C",
      timestamp: data.timestamp || new Date().toISOString(),
    };
  } catch {
    return { noncetsHex: "4F9A3C7E2D1B9A4C", timestamp: new Date().toISOString() };
  }
}

/**
 * @param {object} opts
 * @param {string} opts.recipientTokenId Passport token_id of intended recipient
 * @param {string} opts.signerTokenId Own passport token_id (signer)
 */
export async function generateValidHola(client, secretKey, crypto, { recipientTokenId, signerTokenId }) {
  const recipient = String(recipientTokenId || "").trim().toUpperCase();
  const signer = String(signerTokenId || "").trim().toLowerCase();
  if (!recipient || !signer) {
    throw new Error("generateValidHola requires recipientTokenId and signerTokenId");
  }
  const { noncetsHex, timestamp } = await fetchHolanonce(client);
  const messageWithoutSigRaw = `HOLA/${recipient}/${signer}/${timestamp}/${noncetsHex.toUpperCase()}/API.IDENTYCLAW.COM/`;
  const messageForSigning = messageWithoutSigRaw.toUpperCase();
  const signature = signMessageWithEd25519(messageForSigning, secretKey, crypto.nacl);
  const checksum = computeHolaChecksum(`${messageForSigning}${signature}/`);
  return `${messageForSigning}${signature}/${checksum}`;
}

export function tamperHolaChecksum(hola) {
  const trimmed = String(hola || "").trim();
  if (trimmed.length < 2) return "HOLA/INVALID";
  const last = trimmed.at(-1);
  const replacement = last === "A" ? "B" : "A";
  return `${trimmed.slice(0, -1)}${replacement}`;
}

export function extractHolaFromText(text) {
  const raw = String(text || "");
  const match = raw.match(HOLA_LINE_RE);
  return match ? match[0].trim() : "";
}

export function buildCollaborationEnvelope({
  messageId,
  fromTokenId,
  toTokenId,
  contactUri,
  hola,
  variant,
  probeId,
}) {
  return {
    schema: "identyclaw.collaboration.v1",
    messageId,
    timestamp: new Date().toISOString(),
    from: { tokenId: fromTokenId },
    to: { tokenId: toTokenId, contactUri },
    hola,
    task: {
      type: "HOLA_PROBE",
      payload: { variant, probeId },
    },
    channelHints: {
      replyVia: "contactUri",
      subjectPrefix: "HOLA_RESPONSE:",
    },
  };
}

export function formatEmailBody(envelope) {
  const json = JSON.stringify(envelope, null, 2);
  return `--- identyclaw.collaboration.v1 ---\n${json}\n\n${envelope.hola}\n`;
}
