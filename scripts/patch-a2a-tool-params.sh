#!/usr/bin/env bash
# Patch A2A IDC plugin outbound tools:
# 1. zodToJsonSchema(openAi) marks optional fields as required with ["string","null"],
#    so models pass taskId/contextId as "" for new conversations → assertIdentifier fails.
# 2. Models often use snake_case (task_id) while a2a-utils expects camelCase (taskId).
set -euo pipefail

target="${1:?usage: patch-a2a-tool-params.sh <path-to-outbound/tools.js>}"
[[ -f "$target" ]] || exit 0

if grep -q 'normalizeA2AToolParams' "$target" 2>/dev/null; then
  exit 0
fi

python3 - "$target" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

helpers = """function sanitizeA2ASchema(schema) {
    if (!schema || typeof schema !== "object" || !Array.isArray(schema.required)) {
        return schema;
    }
    const props = schema.properties ?? {};
    schema.required = schema.required.filter((key) => {
        const t = props[key]?.type;
        return !(Array.isArray(t) && t.includes("null"));
    });
    return schema;
}
function normalizeA2AToolParams(params) {
    const out = { ...params };
    const aliases = [
        ["agent_id", "agentId"],
        ["context_id", "contextId"],
        ["task_id", "taskId"],
        ["poll_interval", "pollInterval"],
        ["line_start", "lineStart"],
        ["line_end", "lineEnd"],
        ["character_start", "characterStart"],
        ["character_end", "characterEnd"],
        ["artifact_id", "artifactId"],
        ["json_path", "jsonPath"],
    ];
    for (const [snake, camel] of aliases) {
        if (out[snake] !== undefined && out[camel] === undefined) {
            out[camel] = out[snake];
        }
        delete out[snake];
    }
    for (const [key, value] of Object.entries(out)) {
        if (value === "" || value === null) {
            delete out[key];
        }
    }
    return out;
}
"""

marker = "export function createOutboundTools"
if marker not in text:
    sys.stderr.write(f"patch-a2a-tool-params: createOutboundTools not found in {path}\n")
    sys.exit(1)

text = text.replace(marker, helpers + marker, 1)

old_schema = "const { $schema: _, ...jsonSchema } = zodToJsonSchema(def.schema, { target: \"openAi\" });"
new_schema = """const { $schema: _, ...jsonSchema } = zodToJsonSchema(def.schema, { target: "openAi" });
        sanitizeA2ASchema(jsonSchema);"""
if old_schema not in text:
    sys.stderr.write(f"patch-a2a-tool-params: zodToJsonSchema block not found in {path}\n")
    sys.exit(1)
text = text.replace(old_schema, new_schema, 1)

old_exec = "jsonResult(await def.execute(toolParams))"
new_exec = "jsonResult(await def.execute(normalizeA2AToolParams(toolParams)))"
if old_exec not in text:
    sys.stderr.write(f"patch-a2a-tool-params: execute wrapper not found in {path}\n")
    sys.exit(1)
text = text.replace(old_exec, new_exec, 1)

path.write_text(text, encoding="utf-8")
PY
