"""
jev_hook — LiteLLM pre-call hook.
Quando model == "jev-router", pergunta ao Jev (TypeSafe, via OpenRouter) qual candidato
de router.yaml deve atender a request e reescreve data["model"].
Sem OPENROUTER_API_KEY ou em falha: escolhe o candidato elegível mais barato.
"""
from __future__ import annotations

import json
import logging
import os
import re
from pathlib import Path
from typing import Any

import httpx
import yaml
from litellm.integrations.custom_logger import CustomLogger

ROUTER_YAML = Path(os.environ.get("OUTE_ROUTER_YAML", "/app/router.yaml"))
OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"
JEV_MODEL = os.environ.get("OUTE_JEV_MODEL", "typesafe/jev-latest")
TRIGGER = "jev-router"
log = logging.getLogger("oute.jev_router")
MAX_CHARS_PER_MSG = 600
MAX_MSGS = 12


def _load_policy() -> dict[str, Any]:
    with ROUTER_YAML.open() as f:
        return yaml.safe_load(f)


def _summarize(data: dict[str, Any]) -> dict[str, Any]:
    msgs = data.get("messages") or []
    has_image = any(
        isinstance(m.get("content"), list)
        and any(p.get("type") in ("image_url", "input_image") for p in m["content"] if isinstance(p, dict))
        for m in msgs
    )
    lines = []
    for m in msgs[-MAX_MSGS:]:
        c = m.get("content")
        if isinstance(c, list):
            c = " ".join(p.get("text", "") for p in c if isinstance(p, dict))
        c = re.sub(r"\s+", " ", str(c or ""))[:MAX_CHARS_PER_MSG]
        lines.append(f"{m.get('role','?')}: {c}")
    return {
        "needs_tools": bool(data.get("tools") or data.get("functions")),
        "needs_vision": has_image,
        "max_tokens": data.get("max_tokens") or 0,
        "approx_input_chars": sum(len(json.dumps(m, ensure_ascii=False)) for m in msgs),
        "transcript": "\n".join(lines),
    }


def _eligible(cands: list[dict], s: dict[str, Any]) -> list[dict]:
    out = []
    for c in cands:
        if s["needs_tools"] and not c.get("tools", False):
            continue
        if s["needs_vision"] and not c.get("vision", False):
            continue
        if s["max_tokens"] and c.get("max_output", 0) < s["max_tokens"]:
            continue
        out.append(c)
    return out


def _cheapest(cands: list[dict]) -> str:
    return min(cands, key=lambda c: c.get("cost_in", 0) + c.get("cost_out", 0))["name"]


async def _ask_jev(cands: list[dict], s: dict[str, Any]) -> str | None:
    key = os.environ.get("OPENROUTER_API_KEY")
    if not key:
        return None
    names = [c["name"] for c in cands]
    catalog = "\n".join(
        f"- {c['name']}: {c['desc']} (in ${c.get('cost_in',0)}/M, out ${c.get('cost_out',0)}/M)" for c in cands
    )
    prompt = (
        "Você é um roteador de modelos. Escolha UM candidato para atender a tarefa abaixo, "
        "otimizando qualidade suficiente ao menor custo. Responda apenas JSON: {\"model\": \"<name>\"}.\n\n"
        f"Candidatos:\n{catalog}\n\n"
        f"Sinais: tools={s['needs_tools']} vision={s['needs_vision']} "
        f"max_tokens={s['max_tokens']} input_chars≈{s['approx_input_chars']}\n\n"
        f"Transcript (resumido):\n{s['transcript']}"
    )
    body = {
        "model": JEV_MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "response_format": {"type": "json_object"},
        "max_tokens": 50,
        "temperature": 0,
    }
    try:
        async with httpx.AsyncClient(timeout=8.0) as cli:
            r = await cli.post(
                OPENROUTER_URL,
                headers={"Authorization": f"Bearer {key}", "X-Title": "oute-agent jev-router"},
                json=body,
            )
            r.raise_for_status()
            content = r.json()["choices"][0]["message"]["content"]
            choice = json.loads(content).get("model")
            return choice if choice in names else None
    except Exception as e:  # noqa: BLE001
        log.warning("[jev-router] jev falhou (%s: %s); usando fallback", type(e).__name__, e)
        return None


class JevRouterHandler(CustomLogger):
    async def async_pre_call_hook(self, user_api_key_dict, cache, data: dict, call_type: str):
        if data.get("model") != TRIGGER:
            return data
        policy = _load_policy()
        s = _summarize(data)
        cands = _eligible(policy["candidates"], s) or policy["candidates"]
        via = "jev"
        chosen = await _ask_jev(cands, s)
        if not chosen:
            via = "cheapest"
            chosen = _cheapest(cands) or policy.get("fallback")
        log.warning("[jev-router] chosen=%s via=%s tools=%s vision=%s in_chars=%s",
                    chosen, via, s["needs_tools"], s["needs_vision"], s["approx_input_chars"])
        data["model"] = chosen
        data.setdefault("metadata", {})["oute_router"] = {"chosen": chosen, "signals": {k: v for k, v in s.items() if k != "transcript"}}
        return data


handler = JevRouterHandler()
