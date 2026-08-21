#!/usr/bin/env python3
"""Patch openclaw.json + session stores so nested OpenRouter model ids stay on OpenRouter.

Usage:
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
    path = Path(__file__).resolve().parent / "lib-openclaw-model-routing.py"
    spec = importlib.util.spec_from_file_location("lib_openclaw_model_routing", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("json_path")
    parser.add_argument("--primary", required=True)
    parser.add_argument("--fallback-1", required=True)
    parser.add_argument("--fallback-2", required=True)
    parser.add_argument("--agent-timeout", type=int, default=600)
    parser.add_argument("--provider-timeout", type=int, default=240)
    parser.add_argument("--thinking", default="off")
    args = parser.parse_args()
    path = Path(args.json_path)
    if not path.is_file():
        sys.stderr.write(f"missing {path}\n")
        return 1
    lib = _load_lib()
    counts = lib.patch_openclaw_json_file(
        path,
        primary=args.primary,
        fallback_1=args.fallback_1,
        fallback_2=args.fallback_2,
        agent_timeout=args.agent_timeout,
        provider_timeout=args.provider_timeout,
        thinking_default=args.thinking,
    )
    sys.stdout.write(json.dumps(counts) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
