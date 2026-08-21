#!/usr/bin/env python3
"""Unit tests for lib-openclaw-model-routing.py (no Podman)."""

from __future__ import annotations

import importlib.util
import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path


def _load_lib():
    path = Path(__file__).resolve().parent / "lib-openclaw-model-routing.py"
    spec = importlib.util.spec_from_file_location("lib_openclaw_model_routing", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


LIB = _load_lib()


class ModelRoutingTests(unittest.TestCase):
    def test_catalog_and_native_plugin_disable(self):
        data = {
            "plugins": {"entries": {"anthropic": {"enabled": True}, "openrouter": {"enabled": True}}},
            "models": {"providers": {}},
        }
        LIB.apply_openclaw_model_routing(
            data,
            primary="openrouter/openai/gpt-5.6-terra",
            fallback_1="openrouter/google/gemini-2.5-flash",
            fallback_2="openrouter/qwen/qwen3-coder",
        )
        models = data["models"]["providers"]["openrouter"]["models"]
        ids = [row["id"] for row in models]
        self.assertEqual(
            ids,
            [
                "openai/gpt-5.6-terra",
                "google/gemini-2.5-flash",
                "qwen/qwen3-coder",
            ],
        )
        self.assertEqual(data["models"]["providers"]["openrouter"]["api"], "openai-completions")
        self.assertEqual(
            data["models"]["providers"]["openrouter"]["baseUrl"],
            "https://openrouter.ai/api/v1",
        )
        # Nested vendors are aliased onto OpenRouter (not disabled).
        openai = data["models"]["providers"]["openai"]
        self.assertEqual(openai["baseUrl"], "https://openrouter.ai/api/v1")
        self.assertEqual(openai["api"], "openai-completions")
        self.assertEqual(openai["models"][0]["id"], "openai/gpt-5.6-terra")
        google = data["models"]["providers"]["google"]
        self.assertEqual(google["baseUrl"], "https://openrouter.ai/api/v1")
        entries = data["plugins"]["entries"]
        self.assertTrue(entries["openrouter"]["enabled"])
        self.assertTrue(entries["openai"]["enabled"])
        self.assertTrue(entries["google"]["enabled"])
        self.assertEqual(
            data["agents"]["defaults"]["model"]["primary"],
            "openrouter/openai/gpt-5.6-terra",
        )

    def test_preserves_sticky_session_params_on_allowlist(self):
        data = {
            "agents": {
                "defaults": {
                    "models": {
                        "openrouter/openai/gpt-5.6-terra": {
                            "params": {"extra_body": {"session_id": "identyclaw"}}
                        },
                        "openrouter/google/gemini-2.5-flash": {
                            "params": {"extra_body": {"session_id": "identyclaw"}}
                        },
                    }
                }
            },
            "plugins": {"entries": {"openrouter": {"enabled": True}}},
            "models": {"providers": {}},
        }
        LIB.apply_openclaw_model_routing(
            data,
            primary="openrouter/openai/gpt-5.6-terra",
            fallback_1="openrouter/google/gemini-2.5-flash",
            fallback_2="openrouter/qwen/qwen3-coder",
        )
        terra = data["agents"]["defaults"]["models"]["openrouter/openai/gpt-5.6-terra"]
        gemini = data["agents"]["defaults"]["models"]["openrouter/google/gemini-2.5-flash"]
        qwen = data["agents"]["defaults"]["models"]["openrouter/qwen/qwen3-coder"]
        self.assertEqual(terra["params"]["extra_body"]["session_id"], "identyclaw")
        self.assertEqual(gemini["params"]["extra_body"]["session_id"], "identyclaw")
        self.assertEqual(qwen, {})

    def test_stale_native_hijack_and_off_chain_deepseek(self):
        allow = [
            "openrouter/openai/gpt-5.6-terra",
            "openrouter/google/gemini-2.5-flash",
            "openrouter/qwen/qwen3-coder",
        ]
        providers = ["openrouter"]
        hijack = {"model": "gpt-5.6-terra", "modelProvider": "openai"}
        self.assertTrue(
            LIB.session_model_is_stale(
                hijack, allow_ids=allow, provider_ids=providers
            )
        )
        deepseek = {
            "model": "deepseek/deepseek-v4-flash",
            "modelProvider": "openrouter",
        }
        self.assertTrue(
            LIB.session_model_is_stale(
                deepseek, allow_ids=allow, provider_ids=providers
            )
        )
        in_chain = {
            "model": "openai/gpt-5.6-terra",
            "modelProvider": "openrouter",
        }
        self.assertFalse(
            LIB.session_model_is_stale(
                in_chain, allow_ids=allow, provider_ids=providers
            )
        )

    def test_repair_sqlite_session_nodes(self):
        allow = [
            "openrouter/anthropic/claude-sonnet-5",
            "openrouter/google/gemini-2.5-flash",
            "openrouter/qwen/qwen3-coder",
        ]
        with tempfile.TemporaryDirectory() as tmp:
            db = Path(tmp) / "openclaw-agent.sqlite"
            conn = sqlite3.connect(str(db))
            conn.execute(
                "CREATE TABLE session_nodes (session_key TEXT PRIMARY KEY, entry_json TEXT)"
            )
            conn.execute(
                "INSERT INTO session_nodes VALUES (?, ?)",
                (
                    "agent:main:telegram:direct:1",
                    json.dumps(
                        {
                            "model": "deepseek/deepseek-v4-flash",
                            "modelProvider": "openrouter",
                            "status": "done",
                        }
                    ),
                ),
            )
            conn.execute(
                "INSERT INTO session_nodes VALUES (?, ?)",
                (
                    "agent:main:cron:keep",
                    json.dumps(
                        {
                            "model": "anthropic/claude-sonnet-5",
                            "modelProvider": "openrouter",
                        }
                    ),
                ),
            )
            conn.commit()
            conn.close()
            n = LIB.repair_session_nodes_sqlite(
                db,
                allow_ids=allow,
                provider_ids=["openrouter"],
                paid_fallback="qwen/qwen3-coder",
                fb2="openrouter/qwen/qwen3-coder",
            )
            self.assertEqual(n, 1)
            conn = sqlite3.connect(str(db))
            rows = {
                k: json.loads(v)
                for k, v in conn.execute(
                    "SELECT session_key, entry_json FROM session_nodes"
                )
            }
            conn.close()
            self.assertNotIn("model", rows["agent:main:telegram:direct:1"])
            self.assertNotIn("modelProvider", rows["agent:main:telegram:direct:1"])
            self.assertEqual(
                rows["agent:main:cron:keep"]["model"], "anthropic/claude-sonnet-5"
            )

    def test_read_chain_from_existing_config(self):
        data = {
            "agents": {
                "defaults": {
                    "model": {
                        "primary": "openrouter/openai/gpt-5.6-terra",
                        "fallbacks": [
                            "openrouter/google/gemini-2.5-flash",
                            "openrouter/qwen/qwen3-coder",
                        ],
                    },
                    "timeoutSeconds": 600,
                    "thinkingDefault": "off",
                }
            },
            "models": {
                "providers": {"openrouter": {"timeoutSeconds": 240}}
            },
        }
        chain = LIB.read_model_chain_from_config(data)
        self.assertEqual(chain["primary"], "openrouter/openai/gpt-5.6-terra")
        self.assertEqual(chain["fallback_1"], "openrouter/google/gemini-2.5-flash")
        self.assertEqual(chain["fallback_2"], "openrouter/qwen/qwen3-coder")

    def test_patch_file_reads_chain_when_args_omitted(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "openclaw.json"
            path.write_text(
                json.dumps(
                    {
                        "agents": {
                            "defaults": {
                                "model": {
                                    "primary": "openrouter/openai/gpt-5.6-terra",
                                    "fallbacks": [
                                        "openrouter/google/gemini-2.5-flash",
                                        "openrouter/qwen/qwen3-coder",
                                    ],
                                }
                            }
                        },
                        "models": {"providers": {}},
                        "plugins": {"entries": {}},
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            counts = LIB.patch_openclaw_json_file(path)
            data = json.loads(path.read_text(encoding="utf-8"))
            ids = [
                m["id"]
                for m in data["models"]["providers"]["openrouter"]["models"]
            ]
            self.assertEqual(ids[0], "openai/gpt-5.6-terra")
            self.assertEqual(
                data["models"]["providers"]["openai"]["baseUrl"],
                "https://openrouter.ai/api/v1",
            )
            self.assertTrue(data["plugins"]["entries"]["openai"]["enabled"])
            self.assertEqual(counts["session_nodes"], 0)


if __name__ == "__main__":
    result = unittest.main(verbosity=2, exit=False)
    sys.exit(0 if result.result.wasSuccessful() else 1)
