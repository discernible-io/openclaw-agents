#!/usr/bin/env node
/**
 * idcp — IdentyClaw Passport helpers for OpenClaw agents (host login path).
 *
 * Per-agent secrets: set IDENTYCLAW_HOME to agents/<id>/ (or IDENTYCLAW_NEAR_CREDENTIALS_DIR).
 * Default app root fallback: sibling ../openclaw-agents-app.
 *
 * Usage:
 *   idcp enroll
 *   idcp ensure_session [--force] [--base URL]
 *   idcp list_sessions
 *   idcp me
 *   idcp request METHOD /api/path [--body JSON]
 *   idcp create_hola [--recipient MUNDO|peerTokenId]
 *   idcp verify_hola --hola 'HOLA/...' [--expected MUNDO]
 */
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import {
  appDir,
  nearCredentialsDir,
  ensureSecretsLayout,
  defaultBaseUrl,
  loadHolaClient,
} from "../src/lib/paths.mjs";
import {
  ensureSession,
  listSessions,
  apiRequest,
  me,
} from "../src/lib/session.mjs";
import { createHolaLine, verifyHolaLine } from "../src/lib/hola.mjs";

function print(obj) {
  console.log(JSON.stringify(obj, null, 2));
}

function usage() {
  console.log(`idcp — IdentyClaw helpers for OpenClaw agents

App dir (IDENTYCLAW_HOME): ${appDir()}
Near credentials: ${nearCredentialsDir()}

Commands:
  enroll                          Create secrets dirs; run gennearaccount if available
  ensure_session [--force] [--base URL]
  list_sessions
  me [--base URL]
  request METHOD /api/path [--body JSON] [--base URL]
  create_hola [--recipient ID] [--base URL]
  verify_hola --hola '...' [--expected MUNDO] [--base URL]
`);
}

function parseArgs(argv) {
  const args = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--force") args.force = true;
    else if (a === "--base" && argv[i + 1]) args.base = argv[++i];
    else if (a === "--body" && argv[i + 1]) args.body = argv[++i];
    else if (a === "--recipient" && argv[i + 1]) args.recipient = argv[++i];
    else if (a === "--hola" && argv[i + 1]) args.hola = argv[++i];
    else if (a === "--expected" && argv[i + 1]) args.expected = argv[++i];
    else if (a === "--credentials" && argv[i + 1]) args.credentials = argv[++i];
    else if (a === "--help" || a === "-h") args.help = true;
    else args._.push(a);
  }
  return args;
}

async function cmdEnroll() {
  ensureSecretsLayout();
  const dir = nearCredentialsDir();
  const existing = fs.existsSync(dir)
    ? fs.readdirSync(dir).filter((f) => f.endsWith(".json"))
    : [];

  if (existing.length > 0) {
    let account_id = null;
    try {
      const raw = JSON.parse(fs.readFileSync(path.join(dir, existing[0]), "utf8"));
      account_id = raw.account_id || raw.implicit_account_id || null;
    } catch {
      /* ignore */
    }
    print({
      ok: true,
      already: true,
      near_credentials_dir: dir,
      files: existing,
      account_id,
      purchase: "https://purchase.identyclaw.com",
      next: "Human: mint Passport at https://purchase.identyclaw.com with account_id, then: idcp ensure_session",
    });
    return;
  }

  const candidates = [
    process.env.GENNEARACCOUNT_BIN,
    "gennearaccount",
    path.join(process.env.HOME || "", "gennearaccount/src/gennearaccount"),
  ].filter(Boolean);

  let ran = null;
  for (const bin of candidates) {
    // Official CLI: `<bin> gennearaccount [DIRECTORY]`
    const gen = spawnSync(bin, ["gennearaccount", dir], { encoding: "utf8" });
    if (gen.error && gen.error.code === "ENOENT") continue;
    ran = { bin, gen };
    break;
  }

  if (!ran) {
    // Fallback: vendored hola-client generator (same JSON shape)
    try {
      const {
        generateNearImplicitAccount,
        writeNearCredentialsFile,
      } = loadHolaClient();
      const account = generateNearImplicitAccount();
      const written = writeNearCredentialsFile(dir, { force: false });
      print({
        ok: true,
        method: "hola-client",
        near_credentials_dir: dir,
        files: [path.basename(written.filePath || written.path || "")],
        account_id: written.implicit_account_id || account.implicit_account_id,
        next_human:
          "Purchase Passport at https://purchase.identyclaw.com with account_id, then: idcp ensure_session && idcp me",
      });
      return;
    } catch (err) {
      print({
        ok: false,
        error: "gennearaccount not found and hola-client fallback failed",
        detail: err.message || String(err),
        near_credentials_dir: dir,
        install:
          "Build ~/gennearaccount (make -C src) or install the .deb, then: idcp enroll",
        purchase: "https://purchase.identyclaw.com",
      });
      process.exit(1);
    }
  }

  if (ran.gen.status !== 0) {
    print({
      ok: false,
      error: `${ran.bin} failed`,
      stderr: ran.gen.stderr,
      stdout: ran.gen.stdout,
    });
    process.exit(1);
  }

  const files = fs.readdirSync(dir).filter((f) => f.endsWith(".json"));
  let account_id = null;
  if (files[0]) {
    try {
      const raw = JSON.parse(fs.readFileSync(path.join(dir, files[0]), "utf8"));
      account_id = raw.account_id || raw.implicit_account_id;
    } catch {
      /* ignore */
    }
  }

  print({
    ok: true,
    method: ran.bin,
    near_credentials_dir: dir,
    files,
    account_id,
    next_human:
      "Purchase Passport at https://purchase.identyclaw.com with account_id, then: idcp ensure_session && idcp me",
  });
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help || args._.length === 0) {
    usage();
    process.exit(args.help ? 0 : 1);
  }

  const cmd = args._[0];
  const baseUrl = args.base || defaultBaseUrl();

  try {
    switch (cmd) {
      case "enroll":
        await cmdEnroll();
        break;
      case "ensure_session":
        print(
          await ensureSession({
            baseUrl,
            force: !!args.force,
            credentialsPath: args.credentials || null,
          })
        );
        break;
      case "list_sessions":
        print(listSessions());
        break;
      case "me":
        print(await me(baseUrl));
        break;
      case "request": {
        const method = args._[1];
        const apiPath = args._[2];
        if (!method || !apiPath) {
          throw new Error("usage: idcp request METHOD /api/path [--body JSON]");
        }
        let body = null;
        if (args.body) body = JSON.parse(args.body);
        print(await apiRequest({ method, path: apiPath, body, baseUrl }));
        break;
      }
      case "create_hola":
        print(
          await createHolaLine({
            recipient: args.recipient || "MUNDO",
            baseUrl,
            credentialsPath: args.credentials || null,
          })
        );
        break;
      case "verify_hola":
        if (!args.hola) throw new Error("--hola required");
        print(
          await verifyHolaLine({
            hola: args.hola,
            expectedRecipient: args.expected || "MUNDO",
            baseUrl,
          })
        );
        break;
      default:
        usage();
        process.exit(1);
    }
  } catch (err) {
    print({ ok: false, error: err.message || String(err) });
    process.exit(1);
  }
}

main();
