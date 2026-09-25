"""
jev_hook — LiteLLM pre-call hook.
Seleção em 2 etapas quando model == "jev-router":
  1) Jev (Decisions API) escolhe o PERFIL de router.yaml pela tarefa (fallback: perfil mais barato);
  2) o OpenRouter escolhe o MODELO: a request segue com `models` = todos os modelos do perfil e
     `provider.sort = {by, partition: "none"}` (ordena endpoints de todos os modelos ao vivo, com fallback).
Também aplica ao pedir um perfil direto (model == "coder", "reasoning", ...).
Com presets publicados pelo router-sync, o LiteLLM já manda "@preset/oute-<perfil>" e o hook não injeta nada.

A/B (#15) — OUTE_AB_MODE: off (só Jev) | split (sorteio por conversa) | auto (só openrouter/auto).
Braço "auto": openrouter/auto restrito (plugin auto-router, allowed_models) ao MESMO pool que o Jev teria
(modelos dos perfis elegíveis p/ a request: tools/vision/max_tokens) + ZDR/data_collection deny.
O sorteio é estável por conversa (hash da 1ª mensagem do usuário): um loop de agente não troca de braço no meio.
Cada request leva `oute.ab_arm` no span jev.decision -> comparação no Langfuse (custo, latência, modelo).
"""
from __future__ import annotations

import asyncio
import hashlib
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
AB_MODE = os.environ.get("OUTE_AB_MODE", "off").strip().lower()
AB_AUTO_SHARE = float(os.environ.get("OUTE_AB_AUTO_SHARE", "0.5"))
AUTO_MODEL = "or-auto"          # model_name no config.yaml gerado -> openrouter/openrouter/auto
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


def _client_agent(data: dict[str, Any]) -> str:
    """Qual agente chamou o router (pi, …): header X-Oute-Agent que cada cliente manda (Pi: models.json)."""
    req = data.get("proxy_server_request") or {}
    headers = {str(k).lower(): v for k, v in (req.get("headers") or {}).items()}
    raw = str(headers.get("x-oute-agent") or "")
    return re.sub(r"[^a-z0-9_-]", "", raw.lower())[:32] or "unknown"


def _conversation_key(data: dict[str, Any]) -> str:
    """Estável entre turnos da mesma conversa: 1ª mensagem do usuário (+ system, se houver)."""
    msgs = data.get("messages") or []
    first = next((m for m in msgs if m.get("role") == "user"), {})
    sysm = next((m for m in msgs if m.get("role") == "system"), {})
    raw = json.dumps([sysm.get("content"), first.get("content")], ensure_ascii=False, default=str)
    return hashlib.sha256(raw.encode()).hexdigest()


def _ab_arm(data: dict[str, Any]) -> str:
    if AB_MODE == "auto":
        return "auto"
    if AB_MODE == "split":
        bucket = int(_conversation_key(data)[:8], 16) / 0xFFFFFFFF
        return "auto" if bucket < AB_AUTO_SHARE else "jev"
    return "jev"


def _route_auto(data: dict[str, Any], cands: list[dict]) -> list[str]:
    """openrouter/auto limitado ao mesmo pool de modelos que o Jev poderia escolher."""
    pool = list(dict.fromkeys(m for c in cands for m in (c.get("models") or [])))
    extra = dict(data.get("extra_body") or {})
    extra["plugins"] = [{"id": "auto-router", "allowed_models": pool}]
    extra["provider"] = {**(extra.get("provider") or {}), "zdr": True, "data_collection": "deny"}
    extra["session_id"] = _conversation_key(data)[:32]      # stickiness do auto-router por conversa
    data["extra_body"] = extra
    data["model"] = AUTO_MODEL
    return pool


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


# Span próprio "jev.decision" (o LiteLLM não repassa metadata customizada pros spans dele).
# Emitido no sucesso, com o id da geração do OpenRouter (gen-...) pra correlacionar com o Broadcast (fase 2).
_tracer: Any = None


def _get_tracer():
    global _tracer
    if _tracer is None:
        _tracer = False
        ep = os.environ.get("OTEL_ENDPOINT")
        if ep:
            try:
                from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
                from opentelemetry.sdk.resources import Resource
                from opentelemetry.sdk.trace import TracerProvider
                from opentelemetry.sdk.trace.export import BatchSpanProcessor
                tp = TracerProvider(resource=Resource.create({
                    "service.name": os.environ.get("OTEL_SERVICE_NAME", "jev-router"), "service.namespace": "oute-agent",
                    "deployment.environment": "production"}))
                tp.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(endpoint=ep, insecure=True)))
                _tracer = tp.get_tracer("oute.jev_router")
            except Exception as e:  # noqa: BLE001
                log.warning("[jev-router] span de decisão desligado (%s: %s)", type(e).__name__, e)
    return _tracer or None


def _ns(t) -> int | None:
    try:
        return int(t.timestamp() * 1e9)
    except Exception:  # noqa: BLE001
        return None


def _apply_profile(data: dict, prof: dict) -> None:
    """Roteamento do OpenRouter dentro do perfil: lista de modelos + sort ao vivo.
    Se o perfil tem @preset publicado, o preset já carrega models/sort/provider -> nada a injetar."""
    if prof.get("preset"):
        return
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


_bg_tasks: set = set()   # referência forte: task sem referência pode ser coletada antes de terminar
GENERATION_URL = os.environ.get("OUTE_GENERATION_URL", "https://openrouter.ai/api/v1/generation")


async def _fetch_generation(gen_id: str) -> dict:
    """Modelo real, provedor e custo vêm do OpenRouter (com preset o proxy só vê '@preset/...').
    A geração leva alguns segundos pra ficar consultável -> retries curtos."""
    key = os.environ.get("OPENROUTER_API_KEY")
    if not key or not gen_id:
        return {}
    async with httpx.AsyncClient(timeout=10.0) as cli:
        for wait in (2, 4, 8, 16):
            await asyncio.sleep(wait)
            try:
                r = await cli.get(GENERATION_URL, params={"id": gen_id}, headers={"Authorization": f"Bearer {key}"})
                if r.status_code == 200:
                    return r.json().get("data") or {}
                if r.status_code != 404:
                    log.warning("[jev-router] generation %s: http %s", gen_id, r.status_code)
                    return {}
            except Exception as e:  # noqa: BLE001
                log.warning("[jev-router] generation %s falhou (%s)", gen_id, type(e).__name__)
    return {}


async def _emit_decision(attrs: dict, gen_id: str | None, start_ns, end_ns) -> None:
    g = await _fetch_generation(gen_id) if gen_id else {}
    if g:
        attrs.update({
            "langfuse.observation.type": "generation",
            "gen_ai.response.model": g.get("model"),
            "gen_ai.provider.name": g.get("provider_name"),
            "gen_ai.usage.cost": g.get("total_cost"),
            "gen_ai.usage.input_tokens": g.get("native_tokens_prompt") or g.get("tokens_prompt"),
            "gen_ai.usage.output_tokens": g.get("native_tokens_completion") or g.get("tokens_completion"),
            "gen_ai.response.finish_reasons": g.get("finish_reason"),
            "oute.provider": g.get("provider_name"),
            "oute.served_model": g.get("model"),
            "oute.cost_usd": g.get("total_cost"),
            "oute.latency_ms": g.get("latency"),
            "oute.generation_ms": g.get("generation_time"),
            "oute.cache_discount": g.get("cache_discount"),
        })
    log.warning("[jev-router] served agent=%s profile=%s via=%s model=%s provider=%s cost=%s gen=%s",
                attrs.get("oute.agent"), attrs.get("oute.profile"), attrs.get("oute.via"), g.get("model", "?"),
                g.get("provider_name", "?"), g.get("total_cost", "?"), gen_id)
    tracer = _get_tracer()
    if tracer:
        span = tracer.start_span("jev.decision", start_time=start_ns,
                                 attributes={k: v for k, v in attrs.items() if v is not None})
        span.end(end_time=end_ns)


class JevRouterHandler(CustomLogger):
    async def async_pre_call_hook(self, user_api_key_dict, cache, data: dict, call_type: str):
        policy = _load_policy()
        profiles = {c["name"]: c for c in policy["candidates"]}
        requested = data.get("model")
        agent = _client_agent(data)

        if requested in profiles:            # perfil pedido direto (ex.: /model coder no Pi)
            _apply_profile(data, profiles[requested])
            prof = profiles[requested]
            data.setdefault("metadata", {})["oute_router"] = {"agent": agent,
                "profile": requested, "via": "direct", "preset": prof.get("preset"), "sort": prof.get("sort"),
                "models": prof.get("models", []), "signals": {}}
            return data
        if requested != TRIGGER:
            return data

        s = _summarize(data)
        cands = _eligible(policy["candidates"], s) or policy["candidates"]
        arm = _ab_arm(data)
        if arm == "auto":
            pool = _route_auto(data, cands)
            log.warning("[jev-router] ab=auto pool=%s tools=%s vision=%s in_chars=%s",
                        ",".join(pool), s["needs_tools"], s["needs_vision"], s["approx_input_chars"])
            data.setdefault("metadata", {})["oute_router"] = {"agent": agent,
                "profile": "auto", "via": "openrouter-auto", "arm": "auto", "preset": None, "sort": None,
                "models": pool, "signals": {k: v for k, v in s.items() if k != "transcript"},
            }
            return data
        via = "jev"
        chosen = await _ask_jev(cands, s)
        if not chosen:
            via = "cheapest"
            chosen = _cheapest(cands) or policy.get("fallback")
        prof = profiles[chosen]
        data["model"] = chosen
        _apply_profile(data, prof)
        log.warning("[jev-router] chosen=%s via=%s preset=%s sort=%s models=%s tools=%s vision=%s in_chars=%s",
                    chosen, via, prof.get("preset", "-"), prof.get("sort"), ",".join(prof.get("models", [])),
                    s["needs_tools"], s["needs_vision"], s["approx_input_chars"])
        data.setdefault("metadata", {})["oute_router"] = {"agent": agent,
            "profile": chosen, "via": via, "arm": "jev", "preset": prof.get("preset"), "sort": prof.get("sort"),
            "models": prof.get("models", []),
            "signals": {k: v for k, v in s.items() if k != "transcript"},
        }
        return data

    async def async_log_success_event(self, kwargs, response_obj, start_time, end_time):
        try:
            meta = ((kwargs.get("litellm_params") or {}).get("metadata") or {}).get("oute_router")
            if not meta:
                return
            gen_id = getattr(response_obj, "id", None)
            usage = getattr(response_obj, "usage", None)
            sig = meta.get("signals") or {}
            attrs = {
                "langfuse.trace.name": ("ab-auto" if meta.get("arm") == "auto" else f"jev:{meta.get('profile')}"),
                "oute.agent": meta.get("agent"),
                "oute.ab_arm": meta.get("arm"), "oute.ab_mode": AB_MODE,
                "oute.profile": meta.get("profile"), "oute.via": meta.get("via"),
                "oute.preset": meta.get("preset"), "oute.sort": meta.get("sort"),
                "oute.models": ",".join(meta.get("models") or []),
                "oute.needs_tools": sig.get("needs_tools"), "oute.needs_vision": sig.get("needs_vision"),
                "oute.input_chars": sig.get("approx_input_chars"),
                "gen_ai.system": "openrouter", "gen_ai.response.id": gen_id,
                "gen_ai.request.model": meta.get("preset") or meta.get("profile"),
                "gen_ai.usage.input_tokens": getattr(usage, "prompt_tokens", None),
                "gen_ai.usage.output_tokens": getattr(usage, "completion_tokens", None),
            }
            # não segura a resposta: consulta o OpenRouter e emite o span em background
            t = asyncio.get_running_loop().create_task(_emit_decision(attrs, gen_id, _ns(start_time), _ns(end_time)))
            _bg_tasks.add(t)
            t.add_done_callback(_bg_tasks.discard)
        except Exception as e:  # noqa: BLE001
            log.warning("[jev-router] log_success falhou (%s: %s)", type(e).__name__, e)


handler = JevRouterHandler()
