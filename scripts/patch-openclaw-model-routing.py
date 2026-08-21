#!/usr/bin/env python3
"""Patch openclaw.json + session stores so nested OpenRouter model ids stay on OpenRouter.

When --primary / --fallback-* are omitted, the chain is read from the JSON itself
(agents.defaults.model). That is the container-entrypoint path: host env.local is
not required at boot.

Usage:
  python3 scripts/patch-openclaw-model-routing.py <openclaw.json>
  python3 scripts/patch-openclaw-model-routing.py <openclaw.json> \\
    --primary openrouter/openai/gpt-5.6-terra \\
    --fallback-1 openrouter/google/gemini-2.5-flash \\
    --fallback-2 openrouter/qwen/qwen3-coder \\
    [--agent-timeout 600] [--provider-timeout 240] [--thinking off]
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path


def _load_lib():
    here = Path(__file__).resolve().parent
    # Host checkout: scripts/lib-….py next to this file.
    # Image: both copied into /opt/identyclaw/.
    for candidate in (
        here / "lib-openclaw-model-routing.py",
        Path("/opt/identyclaw/lib-openclaw-model-routing.py"),
    ):
        if candidate.is_file():
            spec = importlib.util.spec_from_file_location(
                "lib_openclaw_model_routing", candidate
            )
            if spec is None or spec.loader is None:
                continue
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            return mod
    raise RuntimeError("lib-openclaw-model-routing.py not found")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("json_path")
    parser.add_argument("--primary", default="")
    parser.add_argument("--fallback-1", default="")
    parser.add_argument("--fallback-2", default="")
    parser.add_argument("--agent-timeout", type=int, default=None)
    parser.add_argument("--provider-timeout", type=int, default=None)
    parser.add_argument("--thinking", default="")
    args = parser.parse_args()
    path = Path(args.json_path)
    if not path.is_file():
        sys.stderr.write(f"missing {path}\n")
        return 1
    lib = _load_lib()
    try:
        counts = lib.patch_openclaw_json_file(
            path,
            primary=args.primary,
            fallback_1=args.fallback_1,
            fallback_2=args.fallback_2,
            agent_timeout=args.agent_timeout,
            provider_timeout=args.provider_timeout,
            thinking_default=args.thinking,
        )
    except ValueError as e:
        sys.stderr.write(f"{e}\n")
        return 1
    sys.stdout.write(json.dumps(counts) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
