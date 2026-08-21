#!/usr/bin/env python3
"""Keep OpenClaw LLM traffic on the configured OpenRouter (or OpenCode) chain.

OpenClaw 2026.7 rewrites nested OpenRouter refs such as
``openrouter/openai/gpt-5.6-terra`` onto native vendor catalogs (openai /
anthropic / google / deepseek). That sends requests to api.openai.com (etc.)
without those API keys → 401 "LLM request failed".

This module:
  * registers each chain model on ``models.providers.openrouter.models[]``
  * disables native vendor plugins that steal those ids
  * clears sticky session pins that sit outside the configured chain
    (sessions.json *and* OpenClaw 2026.7 sqlite ``session_nodes``)
"""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path
from typing import Any, Iterable, Mapping, MutableMapping, Sequence

NATIVE_LLM_PLUGINS = (
    "openai",
    "anthropic",
    "google",
    "google-gemini",
    "google-gemini-cli",
    "google-vertex",
    "deepseek",
    "qwen",
    "xai",
    "mistral",
    "groq",
    "together",
    "huggingface",
    "nvidia",
)

NATIVE_VENDOR_PROVIDERS = frozenset(NATIVE_LLM_PLUGINS)

SESSION_MODEL_KEYS = (
    "model",
    "modelProvider",
    "modelOverride",
    "modelOverrideSource",
    "modelOverrideFallbackOriginProvider",
    "modelOverrideFallbackOriginModel",
    "providerOverride",
    "fallbackNoticeSelectedModel",
    "fallbackNoticeActiveModel",
)


def model_tail(model_id: str) -> str:
    return model_id.split("/", 1)[1] if "/" in model_id else model_id


def runtime_provider(model_id: str) -> str:
    if "/" not in model_id:
        return ""
    return model_id.split("/", 1)[0]


def openrouter_catalog_id(model_id: str) -> str:
    """OpenRouter payload id: everything after the ``openrouter/`` prefix."""
    if model_id.startswith("openrouter/"):
        return model_id[len("openrouter/") :]
    return model_id


def session_model_is_stale(
    entry: Mapping[str, Any],
    *,
    allow_ids: Iterable[str],
    provider_ids: Iterable[str],
    paid_fallback: str = "",
    fb2: str = "",
) -> bool:
    """Return True when a session pin should be dropped so defaults apply."""
    allow = {str(x) for x in allow_ids if x}
    allow_tails = {model_tail(m) for m in allow}
    providers = {str(p) for p in provider_ids if p}

    model_s = str(entry.get("model") or "")
    override_s = str(entry.get("modelOverride") or "")
    origin_s = str(entry.get("modelOverrideFallbackOriginModel") or "")
    provider_s = str(entry.get("modelProvider") or "")
    provider_override_s = str(entry.get("providerOverride") or "")

    def outside_chain(raw: str) -> bool:
        if not raw:
            return False
        if raw in allow or model_tail(raw) in allow_tails:
            return False
        last = raw.rsplit("/", 1)[-1]
        last_allow = {t.rsplit("/", 1)[-1] for t in allow_tails}
        if last in last_allow:
            return False
        return True

    if paid_fallback and (
        model_s == paid_fallback
        or model_s == fb2
        or model_tail(model_s) == paid_fallback
    ):
        return True
    if model_s.endswith("/auto") or model_tail(model_s) == "auto":
        return True
    if model_s and outside_chain(model_s):
        return True
    if override_s and outside_chain(override_s):
        return True
    if origin_s and (origin_s not in allow or origin_s.endswith("/auto")):
        return True
    if "openrouter" not in providers and model_s.startswith("openrouter/"):
        return True
    # Native vendor hijack: sqlite/CLI reparsed openrouter nested ids.
    if providers and "openrouter" in providers:
        if provider_s and provider_s not in providers:
            return True
        if provider_override_s and provider_override_s not in providers:
            return True
    return False


def repair_session_entry(
    entry: MutableMapping[str, Any],
    *,
    allow_ids: Iterable[str],
    provider_ids: Iterable[str],
    paid_fallback: str = "",
    fb2: str = "",
) -> bool:
    """Drop stale model pins in-place. Returns True if the entry changed."""
    if not session_model_is_stale(
        entry,
        allow_ids=allow_ids,
        provider_ids=provider_ids,
        paid_fallback=paid_fallback,
        fb2=fb2,
    ):
        return False
    changed = False
    for key in SESSION_MODEL_KEYS:
        if key in entry and entry[key] not in (None, "", False):
            entry.pop(key, None)
            changed = True
        elif key in entry and entry[key] is None:
            entry.pop(key, None)
            changed = True
    return changed


def apply_openclaw_model_routing(
    data: MutableMapping[str, Any],
    *,
    primary: str,
    fallback_1: str,
    fallback_2: str,
    agent_timeout: int = 600,
    provider_timeout: int = 240,
    thinking_default: str = "off",
) -> MutableMapping[str, Any]:
    """Mutate openclaw.json so the model chain stays on its runtime provider."""
    allowed_thinking = {
        "off",
        "minimal",
        "low",
        "medium",
        "high",
        "xhigh",
        "adaptive",
        "max",
    }
    thinking = (thinking_default or "off").strip().lower() or "off"
    if thinking not in allowed_thinking:
        thinking = "off"

    fallbacks = [fallback_1, fallback_2]
    allowlist = {primary: {}, fallback_1: {}, fallback_2: {}}
    provider_ids: list[str] = []
    for model in (primary, fallback_1, fallback_2):
        pid = runtime_provider(model)
        if pid and pid not in provider_ids:
            provider_ids.append(pid)
    if not provider_ids:
        provider_ids = ["openrouter"]

    defaults = data.setdefault("agents", {}).setdefault("defaults", {})
    defaults.setdefault("workspace", "/home/node/.openclaw/workspace")
    defaults["models"] = allowlist
    defaults["model"] = {"primary": primary, "fallbacks": fallbacks}
    defaults["timeoutSeconds"] = int(agent_timeout)
    defaults["thinkingDefault"] = thinking

    providers = data.setdefault("models", {}).setdefault("providers", {})
    plugins = data.setdefault("plugins", {}).setdefault("entries", {})
    known_llm_plugins = {"openrouter", "opencode", "opencode-go"}

    for pid in provider_ids:
        slot = providers.setdefault(pid, {})
        slot["timeoutSeconds"] = int(provider_timeout)
    for pid in known_llm_plugins:
        if pid in provider_ids:
            plugins.setdefault(pid, {})["enabled"] = True
        elif pid in plugins:
            plugins[pid]["enabled"] = False

    if "openrouter" in provider_ids:
        openrouter = providers.setdefault("openrouter", {})
        openrouter.setdefault("api", "openai-completions")
        openrouter.setdefault("baseUrl", "https://openrouter.ai/api/v1")
        openrouter["timeoutSeconds"] = int(provider_timeout)
        catalog = []
        seen = set()
        for model in (primary, fallback_1, fallback_2):
            if not model.startswith("openrouter/"):
                continue
            cid = openrouter_catalog_id(model)
            if not cid or cid in seen:
                continue
            seen.add(cid)
            catalog.append(
                {
                    "id": cid,
                    "name": cid,
                    "api": "openai-completions",
                    "input": ["text"],
                    "contextWindow": 200000,
                }
            )
        openrouter["models"] = catalog
        for pid in NATIVE_LLM_PLUGINS:
            if pid in provider_ids:
                continue
            plugins.setdefault(pid, {})["enabled"] = False

    diagnostics = data.get("diagnostics")
    if isinstance(diagnostics, dict):
        for k in ("stuckSessionWarnMs", "stuckSessionAbortMs"):
            diagnostics.pop(k, None)
        cache_trace = diagnostics.get("cacheTrace")
        if isinstance(cache_trace, dict):
            for k in ("includeMessages", "includePrompt", "includeSystem"):
                cache_trace.pop(k, None)

    return data


def repair_sessions_json(
    sessions_path: Path,
    *,
    allow_ids: Sequence[str],
    provider_ids: Sequence[str],
    paid_fallback: str,
    fb2: str,
) -> int:
    if not sessions_path.is_file():
        return 0
    sessions = json.loads(sessions_path.read_text(encoding="utf-8"))
    changed = 0
    if isinstance(sessions, dict):
        for entry in sessions.values():
            if isinstance(entry, dict) and repair_session_entry(
                entry,
                allow_ids=allow_ids,
                provider_ids=provider_ids,
                paid_fallback=paid_fallback,
                fb2=fb2,
            ):
                changed += 1
    if changed:
        sessions_path.write_text(json.dumps(sessions, indent=2) + "\n", encoding="utf-8")
        try:
            sessions_path.chmod(0o600)
        except OSError:
            pass
    return changed


def repair_session_nodes_sqlite(
    sqlite_path: Path,
    *,
    allow_ids: Sequence[str],
    provider_ids: Sequence[str],
    paid_fallback: str,
    fb2: str,
) -> int:
    if not sqlite_path.is_file():
        return 0
    conn = sqlite3.connect(str(sqlite_path), timeout=15)
    try:
        cols = {
            row[1]
            for row in conn.execute("PRAGMA table_info(session_nodes)").fetchall()
        }
        if "entry_json" not in cols or "session_key" not in cols:
            return 0
        changed = 0
        rows = conn.execute(
            "SELECT session_key, entry_json FROM session_nodes"
        ).fetchall()
        for key, raw in rows:
            try:
                entry = json.loads(raw or "{}")
            except json.JSONDecodeError:
                continue
            if not isinstance(entry, dict):
                continue
            if not repair_session_entry(
                entry,
                allow_ids=allow_ids,
                provider_ids=provider_ids,
                paid_fallback=paid_fallback,
                fb2=fb2,
            ):
                continue
            conn.execute(
                "UPDATE session_nodes SET entry_json=? WHERE session_key=?",
                (json.dumps(entry, separators=(",", ":")), key),
            )
            changed += 1
        if changed:
            conn.commit()
        return changed
    finally:
        conn.close()


def repair_session_stores(
    config_dir: Path,
    *,
    primary: str,
    fallback_1: str,
    fallback_2: str,
) -> dict[str, int]:
    allow_ids = [primary, fallback_1, fallback_2]
    provider_ids = []
    for model in allow_ids:
        pid = runtime_provider(model)
        if pid and pid not in provider_ids:
            provider_ids.append(pid)
    paid_fallback = model_tail(fallback_2)
    json_n = repair_sessions_json(
        config_dir / "agents/main/sessions/sessions.json",
        allow_ids=allow_ids,
        provider_ids=provider_ids,
        paid_fallback=paid_fallback,
        fb2=fallback_2,
    )
    sqlite_n = repair_session_nodes_sqlite(
        config_dir / "agents/main/agent/openclaw-agent.sqlite",
        allow_ids=allow_ids,
        provider_ids=provider_ids,
        paid_fallback=paid_fallback,
        fb2=fallback_2,
    )
    return {"sessions_json": json_n, "session_nodes": sqlite_n}


def patch_openclaw_json_file(
    json_path: Path,
    *,
    primary: str,
    fallback_1: str,
    fallback_2: str,
    agent_timeout: int = 600,
    provider_timeout: int = 240,
    thinking_default: str = "off",
) -> dict[str, int]:
    data = json.loads(json_path.read_text(encoding="utf-8"))
    apply_openclaw_model_routing(
        data,
        primary=primary,
        fallback_1=fallback_1,
        fallback_2=fallback_2,
        agent_timeout=agent_timeout,
        provider_timeout=provider_timeout,
        thinking_default=thinking_default,
    )
    json_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    try:
        json_path.chmod(0o600)
    except OSError:
        pass
    return repair_session_stores(
        json_path.parent,
        primary=primary,
        fallback_1=fallback_1,
        fallback_2=fallback_2,
    )
