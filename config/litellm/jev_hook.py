"""
jev_hook — LiteLLM pre-call hook.
Seleção em 2 etapas quando model == "jev-router":
  1) Jev (Decisions API) escolhe o PERFIL de router.yaml pela tarefa (fallback: perfil mais barato);
  2) o OpenRouter escolhe o MODELO: a request segue com `models` = todos os modelos do perfil e
     `provider.sort = {by, partition: "none"}` (ordena endpoints de todos os modelos ao vivo, com fallback).
Também aplica ao pedir um perfil direto (model == "coder", "reasoning", ...).
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
# Jev não é chat: usa a Decisions API (alpha) do OpenRouter. Formato = TypeSafe System One:
# {state, model, questions:{name:{type:"choice", instructions, criteria:{opt:desc}}}} -> {answers:{name:{choice}}}
DECISIONS_URL = os.environ.get("OUTE_DECISIONS_URL", "https://openrouter.ai/api/alpha/decisions")
JEV_MODEL = os.environ.get("OUTE_JEV_MODEL", "typesafe/jev-1.13")
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
    names = {c["name"] for c in cands}
    body = {
        "model": JEV_MODEL,
        "state": {
            "transcript": s["transcript"],
            "signals": {
                "tools": s["needs_tools"],
                "image_input": s["needs_vision"],
                "max_tokens": s["max_tokens"],
                "input_chars": s["approx_input_chars"],
            },
        },
        "questions": {
            "model": {
                "type": "choice",
                "instructions": (
                    "Escolha o único modelo que deve atender esta request. Prefira o mais barato "
                    "que atinja a qualidade necessária; escolha um mais forte só quando a tarefa "
                    "for difícil o bastante para justificar o custo. Todos os listados são elegíveis."
                ),
                "criteria": {
                    c["name"]: f"{c['desc']} Custo {c.get('cost_range', '')}. Modelos: {', '.join(c.get('models', [])[:5])}."
                    for c in cands
                },
            }
        },
    }
    try:
        async with httpx.AsyncClient(timeout=8.0) as cli:
            r = await cli.post(
                DECISIONS_URL,
                headers={"Authorization": f"Bearer {key}", "X-Title": "oute-agent jev-router"},
                json=body,
            )
            if r.status_code != 200:
                log.warning("[jev-router] jev http %s: %s", r.status_code, r.text[:300])
                return None
            choice = r.json()["answers"]["model"]["choice"]
            return choice if choice in names else None
    except Exception as e:  # noqa: BLE001
        log.warning("[jev-router] jev falhou (%s: %s); usando fallback", type(e).__name__, e)
        return None


def _apply_profile(data: dict, prof: dict) -> None:
    """Roteamento do OpenRouter dentro do perfil: lista de modelos + sort ao vivo."""
    models = (prof.get("models") or [])[:3]   # OpenRouter rejeita `models` com mais de 3 itens
    extra = dict(data.get("extra_body") or {})
    if len(models) > 1:
        extra["models"] = models
    sort = prof.get("sort")
    if sort:
        # formato do OpenRouter: provider.sort = {by, partition}; partition "none" ordena entre TODOS os modelos da lista
        extra["provider"] = {**(extra.get("provider") or {}), "sort": {"by": sort, "partition": "none"}}
    if extra:
        data["extra_body"] = extra


class JevRouterHandler(CustomLogger):
    async def async_pre_call_hook(self, user_api_key_dict, cache, data: dict, call_type: str):
        policy = _load_policy()
        profiles = {c["name"]: c for c in policy["candidates"]}
        requested = data.get("model")

        if requested in profiles:            # perfil pedido direto (ex.: /model coder no Pi)
            _apply_profile(data, profiles[requested])
            return data
        if requested != TRIGGER:
            return data

        s = _summarize(data)
        cands = _eligible(policy["candidates"], s) or policy["candidates"]
        via = "jev"
        chosen = await _ask_jev(cands, s)
        if not chosen:
            via = "cheapest"
            chosen = _cheapest(cands) or policy.get("fallback")
        prof = profiles[chosen]
        data["model"] = chosen
        _apply_profile(data, prof)
        log.warning("[jev-router] chosen=%s via=%s sort=%s models=%s tools=%s vision=%s in_chars=%s",
                    chosen, via, prof.get("sort"), ",".join(prof.get("models", [])),
                    s["needs_tools"], s["needs_vision"], s["approx_input_chars"])
        data.setdefault("metadata", {})["oute_router"] = {
            "profile": chosen, "via": via, "sort": prof.get("sort"), "models": prof.get("models", []),
            "signals": {k: v for k, v in s.items() if k != "transcript"},
        }
        return data

    async def async_log_success_event(self, kwargs, response_obj, start_time, end_time):
        # qual modelo o OpenRouter efetivamente usou dentro do perfil
        try:
            meta = ((kwargs.get("litellm_params") or {}).get("metadata") or {}).get("oute_router")
            if meta:
                # response_obj.model vem com o nome do grupo do LiteLLM; o modelo real está no hidden_params/raw
                hp = getattr(response_obj, "_hidden_params", {}) or {}
                real = (hp.get("original_response") or {}) if isinstance(hp.get("original_response"), dict) else {}
                served = real.get("model") or (hp.get("additional_headers") or {}).get("llm_provider-x-model") \
                    or kwargs.get("model") or getattr(response_obj, "model", "?")
                log.warning("[jev-router] served profile=%s model=%s", meta.get("profile"), served)
        except Exception:  # noqa: BLE001
            pass


handler = JevRouterHandler()
