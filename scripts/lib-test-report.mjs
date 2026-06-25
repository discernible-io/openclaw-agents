/**
 * Constitution-aligned test stdout (findings-first; outcomes are only passed / not-passed).
 *
 * - `surface` — what was probed (HTTP method, path, input shape).
 * - `detail` — observed facts (status, body fields, receipts, errors).
 * - `matchesContract` — internal: did observation match the stack contract for this case?
 *
 * Do not label lines with expectation jargon ("rejected", "accepted", "expected").
 * See test-constitution.md and ../docs/docs/test-constitution.md.
 */

export function reportFinding(surface, matchesContract, detail = "") {
  const outcome = matchesContract ? "passed" : "not-passed";
  const line = detail ? `${outcome}  ${surface} — ${detail}` : `${outcome}  ${surface}`;
  process.stdout.write(`${line}\n`);
  return matchesContract;
}

export function reportSkip(surface, detail = "") {
  const line = detail ? `skipped  ${surface} — ${detail}` : `skipped  ${surface}`;
  process.stdout.write(`${line}\n`);
}

export function formatSummary({ passed, notPassed, skipped = 0 }) {
  const parts = [`${passed} passed`];
  if (notPassed > 0) parts.push(`${notPassed} not-passed`);
  if (skipped > 0) parts.push(`${skipped} skipped`);
  return parts.join(", ");
}

export function createTally() {
  let passed = 0;
  let notPassed = 0;
  let skipped = 0;

  return {
    add(matchesContract) {
      if (matchesContract) passed += 1;
      else notPassed += 1;
    },
    addSkip() {
      skipped += 1;
    },
    counts() {
      return { passed, notPassed, skipped };
    },
    exitCode() {
      return notPassed > 0 ? 1 : 0;
    },
    printSummary(prefix = "Summary") {
      const { passed: p, notPassed: np, skipped: sk } = this.counts();
      process.stdout.write(`\n--- ${prefix}: ${formatSummary({ passed: p, notPassed: np, skipped: sk })} ---\n`);
    },
  };
}

/** Run one probe; probeFn returns { matchesContract, detail? } or throws (prefix message with `skip:` to skip). */
export async function runProbe(tally, surface, probeFn) {
  try {
    const result = await probeFn();
    tally.add(reportFinding(surface, result.matchesContract, result.detail || ""));
    return result.matchesContract;
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    if (msg.startsWith("skip:")) {
      reportSkip(surface, msg.slice(5).trim());
      tally.addSkip();
      return null;
    }
    tally.add(reportFinding(surface, false, msg));
    return false;
  }
}
