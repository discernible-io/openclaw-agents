/**
 * Minimal Agent Card schema checks for constitution discovery smoke.
 * Does not validate RODiT auth — wiring and A2A v0.3 advertisement only.
 */

const EXPECTED_PROTOCOL_VERSION = "0.3.0";

/**
 * @param {unknown} card
 * @param {{ expectedProtocolVersion?: string }} [opts]
 * @returns {{ ok: boolean, errors: string[] }}
 */
export function validateAgentCard(card, opts = {}) {
  const expectedVersion = opts.expectedProtocolVersion || EXPECTED_PROTOCOL_VERSION;
  const errors = [];

  if (!card || typeof card !== "object") {
    return { ok: false, errors: ["agent card is not an object"] };
  }

  const c = /** @type {Record<string, unknown>} */ (card);

  if (typeof c.protocolVersion !== "string" || !c.protocolVersion.trim()) {
    errors.push("missing protocolVersion");
  } else if (c.protocolVersion !== expectedVersion) {
    errors.push(`protocolVersion=${c.protocolVersion} (expected ${expectedVersion})`);
  }

  if (typeof c.url !== "string" || !/^https?:\/\//i.test(c.url)) {
    errors.push("missing or invalid url");
  }

  const capabilities = c.capabilities;
  if (!capabilities || typeof capabilities !== "object") {
    errors.push("missing capabilities object");
  }

  const skills = c.skills;
  if (!Array.isArray(skills) || skills.length === 0) {
    errors.push("skills must be a non-empty array");
  } else {
    for (let i = 0; i < skills.length; i++) {
      const skill = skills[i];
      if (!skill || typeof skill !== "object") {
        errors.push(`skills[${i}] is not an object`);
        continue;
      }
      const s = /** @type {Record<string, unknown>} */ (skill);
      if (typeof s.id !== "string" || !s.id.trim()) {
        errors.push(`skills[${i}].id missing`);
      }
      if (typeof s.name !== "string" || !s.name.trim()) {
        errors.push(`skills[${i}].name missing`);
      }
    }
  }

  return { ok: errors.length === 0, errors };
}
