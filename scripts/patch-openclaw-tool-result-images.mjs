#!/usr/bin/env node
/**
 * Hotfix the well-known OpenClaw long-session "(see attached image)" tool-result bug.
 *
 * On OpenAI-compatible providers (DeepSeek via OpenRouter), aggregate tool-result
 * truncation can empty fresh tool text; older converters then emit the media
 * placeholder even when no image payload exists. 2026.7.2-beta.7 partially fixed
 * the openai-completions path (hasMediaPayload + "(no output)"), but related
 * husks remain:
 *   1) extractToolResultBlockText treats type:"image" as media-only without
 *      requiring a payload (skips stringify of husk/metadata blocks)
 *   2) Anthropic / transport converters still fall back to
 *      mediaPlaceholder ?? "(see attached image)" when text is empty
 *   3) RECOVERY_MIN_KEEP_CHARS=0 lets aggregate truncation wipe trailing
 *      (fresh) tool results under prompt pressure
 *
 * This script patches /app in-place (idempotent). Safe to run from the
 * container entrypoint before gateway start.
 *
 * Usage:
 *   node scripts/patch-openclaw-tool-result-images.mjs [--root /app] [--dry-run]
 */
import fs from "node:fs";
import path from "node:path";

const args = process.argv.slice(2);
let root = "/app";
let dryRun = false;
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--root") root = args[++i] ?? root;
  else if (args[i] === "--dry-run") dryRun = true;
}

const MARK = "identyclaw-tool-result-images-patch-v1";

/** @type {{file: string, label: string, apply: (text: string) => string | null}[]} */
const patches = [
  {
    file: "node_modules/@openclaw/ai/src/providers/tool-result-text.ts",
    label: "src extractToolResultBlockText hasMediaPayload",
    apply(text) {
      if (text.includes(MARK)) return null;
      const from =
        'if (typeof record.type === "string" && MEDIA_ONLY_TOOL_RESULT_TYPES.has(record.type)) {\n    return undefined;\n  }';
      const to =
        `if (typeof record.type === "string" && MEDIA_ONLY_TOOL_RESULT_TYPES.has(record.type) && hasMediaPayload(record)) {\n    // ${MARK}\n    return undefined;\n  }`;
      if (!text.includes(from)) return null;
      return text.replace(from, to);
    },
  },
  {
    file: "node_modules/@openclaw/ai/dist/tool-result-text-CTpIRbYd.mjs",
    label: "dist extractToolResultBlockText hasMediaPayload",
    apply(text) {
      if (text.includes(MARK)) return null;
      // Minified / bundled variant
      const patterns = [
        [
          'if (typeof record.type === "string" && MEDIA_ONLY_TOOL_RESULT_TYPES.has(record.type)) return;',
          `if (typeof record.type === "string" && MEDIA_ONLY_TOOL_RESULT_TYPES.has(record.type) && hasMediaPayload(record)) return; /* ${MARK} */`,
        ],
        [
          "if (typeof record.type === \"string\" && MEDIA_ONLY_TOOL_RESULT_TYPES.has(record.type)) return;",
          `if (typeof record.type === \"string\" && MEDIA_ONLY_TOOL_RESULT_TYPES.has(record.type) && hasMediaPayload(record)) return; /* ${MARK} */`,
        ],
      ];
      for (const [from, to] of patterns) {
        if (text.includes(from)) return text.replace(from, to);
      }
      return null;
    },
  },
  {
    file: "node_modules/@openclaw/ai/src/providers/anthropic.ts",
    label: "src anthropic empty tool fallback",
    apply(text) {
      if (text.includes(`${MARK}-anthropic`)) return null;
      const from =
        'blocks.unshift({ type: "text" as const, text: mediaPlaceholder ?? "(see attached image)" });';
      const to =
        `blocks.unshift({ type: "text" as const, text: mediaPlaceholder ?? "(no output)" }); /* ${MARK}-anthropic */`;
      if (!text.includes(from)) return null;
      return text.replace(from, to);
    },
  },
  {
    file: "node_modules/@openclaw/ai/src/transports/anthropic-transport-stream.ts",
    label: "src anthropic transport empty tool fallback",
    apply(text) {
      if (text.includes(`${MARK}-anthropic-transport`)) return null;
      const from =
        'blocks.unshift({ type: "text", text: mediaPlaceholder ?? "(see attached image)" });';
      const to =
        `blocks.unshift({ type: "text", text: mediaPlaceholder ?? "(no output)" }); /* ${MARK}-anthropic-transport */`;
      if (!text.includes(from)) return null;
      return text.replace(from, to);
    },
  },
];

function patchSeeAttachedFallback(text, tag) {
  if (text.includes(tag)) return null;
  let next = text;
  let changed = false;
  // 2026.7+ mediaPlaceholder form
  const modernFrom = 'text: mediaPlaceholder ?? "(see attached image)"';
  const modernTo = `text: mediaPlaceholder ?? "(no output)" /* ${tag} */`;
  if (next.includes(modernFrom)) {
    next = next.replaceAll(modernFrom, modernTo);
    changed = true;
  }
  // 2026.6.x openai-completions: empty tool text always becomes image placeholder
  // (hasImages is computed but unused — the long-session bug path).
  const ocFrom =
    'sanitizeSurrogates(textResult.length > 0 ? textResult : "(see attached image)")';
  const ocTo = `sanitizeSurrogates(textResult.length > 0 ? textResult : (hasImages ? "(see attached image)" : "(no output)")) /* ${tag}-oc */`;
  if (next.includes(ocFrom) && !next.includes(`${tag}-oc`)) {
    next = next.replaceAll(ocFrom, ocTo);
    changed = true;
  }
  // 2026.6.x openai-responses / shared: empty text → placeholder with no image check
  const orFrom =
    'sanitizeSurrogates(hasText ? textResult : "(see attached image)")';
  const orTo = `sanitizeSurrogates(hasText ? textResult : "(no output)") /* ${tag}-or */`;
  if (next.includes(orFrom) && !next.includes(`${tag}-or`)) {
    next = next.replaceAll(orFrom, orTo);
    changed = true;
  }
  // 2026.6.x openai-transport-stream: textResult || placeholder (images already branched)
  const otFrom =
    'sanitizeTransportPayloadText(textResult || "(see attached image)")';
  const otTo = `sanitizeTransportPayloadText(textResult || "(no output)") /* ${tag}-ot */`;
  if (next.includes(otFrom) && !next.includes(`${tag}-ot`)) {
    next = next.replaceAll(otFrom, otTo);
    changed = true;
  }
  // 2026.6.x anthropic / provider-stream: hard-coded placeholder when no text block
  const hardFrom = 'text: "(see attached image)"';
  const hardTo = `text: "(no output)" /* ${tag}-hard */`;
  if (next.includes(hardFrom) && !next.includes(`${tag}-hard`)) {
    next = next.replaceAll(hardFrom, hardTo);
    changed = true;
  }
  return changed ? next : null;
}

function patchRecoveryMinKeep(text) {
  if (text.includes(`${MARK}-recovery`)) return null;
  const from = "const RECOVERY_MIN_KEEP_CHARS = 0;";
  const to = `const RECOVERY_MIN_KEEP_CHARS = 2000; /* ${MARK}-recovery */`;
  if (!text.includes(from)) return null;
  return text.replace(from, to);
}

function walkJs(dir, out = []) {
  if (!fs.existsSync(dir)) return out;
  for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, ent.name);
    if (ent.isDirectory()) {
      if (ent.name === "node_modules" && !dir.endsWith("@openclaw")) continue;
      walkJs(p, out);
    } else if (/\.(js|mjs|ts)$/.test(ent.name) && !ent.name.includes(".test.")) {
      out.push(p);
    }
  }
  return out;
}

let changed = 0;
let skipped = 0;

for (const spec of patches) {
  const full = path.join(root, spec.file);
  if (!fs.existsSync(full)) {
    skipped++;
    continue;
  }
  const before = fs.readFileSync(full, "utf8");
  const after = spec.apply(before);
  if (!after || after === before) {
    skipped++;
    continue;
  }
  console.log(`patch ${spec.label}: ${spec.file}`);
  if (!dryRun) fs.writeFileSync(full, after);
  changed++;
}

// Bundled dist copies of anthropic fallback + recovery keep
for (const full of walkJs(path.join(root, "dist")).concat(
  walkJs(path.join(root, "node_modules/@openclaw/ai/dist")),
)) {
  const rel = path.relative(root, full);
  let text = fs.readFileSync(full, "utf8");
  let next = text;
  if (
    text.includes('"(see attached image)"') &&
    (text.includes("mediaPlaceholder") ||
      text.includes("textResult") ||
      text.includes("hasText") ||
      text.includes('type: "text"'))
  ) {
    const patched = patchSeeAttachedFallback(text, `${MARK}-fallback`);
    if (patched) next = patched;
  }
  if (next.includes("const RECOVERY_MIN_KEEP_CHARS = 0;")) {
    const patched = patchRecoveryMinKeep(next);
    if (patched) next = patched;
  }
  // bundled tool-result-text early return (hash filename varies)
  if (
    rel.includes("tool-result-text") &&
    next.includes("MEDIA_ONLY_TOOL_RESULT_TYPES.has(record.type)) return;") &&
    !next.includes(MARK)
  ) {
    next = next.replace(
      "MEDIA_ONLY_TOOL_RESULT_TYPES.has(record.type)) return;",
      `MEDIA_ONLY_TOOL_RESULT_TYPES.has(record.type) && hasMediaPayload(record)) return; /* ${MARK} */`,
    );
  }
  if (next !== text) {
    console.log(`patch scan: ${rel}`);
    if (!dryRun) fs.writeFileSync(full, next);
    changed++;
  } else {
    skipped++;
  }
}

console.log(
  dryRun
    ? `dry-run complete (would change ${changed} files, skip ${skipped})`
    : `patched ${changed} files (skipped ${skipped})`,
);
process.exit(0);
