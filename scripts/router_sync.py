#!/usr/bin/env python3
"""
router_sync — consulta o OpenRouter e gera a config do jev-router a partir de config/litellm/policy.yaml.

Elegibilidade (em ordem de autoridade):
  1. GET /api/v1/models/user com a key do oute-agent → reflete guardrail/privacidade da key (se o endpoint existir);
  2. senão: GET /api/v1/models/{id}/endpoints e filtra por providers_allow do policy.yaml.
Um modelo só é elegível se tiver >=1 endpoint em provedor permitido e não casar exclude_patterns.

Uso: python3 scripts/router_sync.py [--dry-run]   (OPENROUTER_API_KEY no ambiente; recomendado)
Rodado por `oute router-sync` dentro da imagem do LiteLLM (tem pyyaml + rede).
"""
from __future__ import annotations

import datetime as dt
import fnmatch
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
CFG = ROOT / "config" / "litellm"
API = "https://openrouter.ai/api/v1"
KEY = os.environ.get("OPENROUTER_API_KEY", "")
DRY = "--dry-run" in sys.argv


def get(path: str, auth: bool = False):
    req = urllib.request.Request(API + path, headers={"User-Agent": "oute-agent/router-sync"})
    if auth and KEY:
        req.add_header("Authorization", f"Bearer {KEY}")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        return {"_error": e.code}


def per_m(x) -> float:
    try:
        return round(float(x) * 1_000_000, 4)
    except (TypeError, ValueError):
        return 0.0


def probe_router(model: str) -> bool:
    """Jev é modelo da Decisions API (não aparece no catálogo de chat): testa com uma decisão real."""
    if not KEY or not model:
        return False
    body = json.dumps({
        "model": model,
        "state": {"transcript": "user: oi"},
        "questions": {"q": {"type": "choice", "instructions": "escolha a", "criteria": {"a": "a", "b": "b"}}},
    }).encode()
    req = urllib.request.Request(
        "https://openrouter.ai/api/alpha/decisions", data=body, method="POST",
        headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json",
                 "User-Agent": "oute-agent/router-sync"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return "answers" in json.load(r)
    except urllib.error.HTTPError as e:
        print(f"probe {model}: HTTP {e.code} {e.read()[:200]!r}", file=sys.stderr)
    except Exception as e:  # noqa: BLE001
        print(f"probe {model}: {type(e).__name__}: {e}", file=sys.stderr)
    return False


def main() -> int:
    policy = yaml.safe_load((CFG / "policy.yaml").read_text())
    allow = set(policy["providers_allow"])
    excl = policy.get("exclude_patterns", [])

    # --- provedores conhecidos (valida slugs do policy)
    provs = get("/providers")
    if "data" in provs:
        known = {p.get("slug") for p in provs["data"]} | {p.get("name") for p in provs["data"]}
        unknown = sorted(s for s in allow if s not in known)
        if unknown:
            print(f"AVISO: slugs não reconhecidos em providers_allow: {unknown}", file=sys.stderr)

    # --- catálogo público
    models = get("/models").get("data", [])
    if not models:
        print("ERRO: /models vazio", file=sys.stderr)
        return 1
    by_id = {m["id"]: m for m in models}

    # --- visão da key (guardrail) se disponível
    user_ids = None
    if KEY:
        u = get("/models/user", auth=True)
        if "data" in u:
            user_ids = {m["id"] for m in u["data"]}
            print(f"/models/user: {len(user_ids)} modelos visíveis pela key")
        else:
            print(f"/models/user indisponível ({u.get('_error')}); usando filtro local por provedor")

    def excluded(mid: str) -> bool:
        return any(fnmatch.fnmatch(mid, p) for p in excl)

    # só busca endpoints dos modelos que casam algum padrão (evita centenas de chamadas)
    patterns = [p for c in policy["candidates"] for p in c["prefer"]] + [policy.get("router_model", "")]
    wanted = [mid for mid in by_id if not excluded(mid) and any(fnmatch.fnmatch(mid, p) for p in patterns)]

    eligible: dict[str, dict] = {}
    for mid in wanted:
        ep = get(f"/models/{mid}/endpoints").get("data", {})
        eps = []
        for e in ep.get("endpoints", []) or []:
            slug = (e.get("tag") or "").split("/")[0] or (e.get("provider_name") or "").lower()
            if slug in allow or e.get("provider_name") in allow:
                eps.append(e)
        if user_ids is not None and mid not in user_ids:
            continue
        if not eps:
            continue
        m = by_id[mid]
        cheapest = min(eps, key=lambda e: per_m(e["pricing"].get("prompt")) + per_m(e["pricing"].get("completion")))
        params = set(m.get("supported_parameters") or [])
        for e in eps:
            params |= set(e.get("supported_parameters") or [])
        eligible[mid] = {
            "id": mid,
            "name": m.get("name", mid),
            "created": m.get("created", 0),
            "context": max(int(e.get("context_length") or 0) for e in eps) or int(m.get("context_length") or 0),
            "max_output": max(int(e.get("max_completion_tokens") or 0) for e in eps)
                          or int((m.get("top_provider") or {}).get("max_completion_tokens") or 0),
            "tools": "tools" in params,
            "vision": "image" in ((m.get("architecture") or {}).get("input_modalities") or []),
            "cost_in": per_m(cheapest["pricing"].get("prompt")),
            "cost_out": per_m(cheapest["pricing"].get("completion")),
            "providers": sorted({(e.get("tag") or "").split("/")[0] or e.get("provider_name") for e in eps}),
        }

    # --- resolve candidatos
    chosen, report = [], []
    for c in policy["candidates"]:
        req = c.get("requires", {})
        pick = None
        for pat in c["prefer"]:
            hits = [
                m for mid, m in eligible.items()
                if fnmatch.fnmatch(mid, pat)
                and (not req.get("tools") or m["tools"])
                and (not req.get("vision") or m["vision"])
                and m["context"] >= req.get("min_context", 0)
            ]
            if hits:
                pick = max(hits, key=lambda m: m["created"])
                break
        if pick:
            chosen.append({**pick, "role": c["name"], "desc": c["desc"]})
            report.append(f"  {c['name']:<13} -> {pick['id']:<40} in ${pick['cost_in']}/M out ${pick['cost_out']}/M ctx {pick['context']} via {','.join(pick['providers'])}")
        else:
            report.append(f"  {c['name']:<13} -> (NENHUM elegível para {c['prefer']})")

    rm = policy.get("router_model")
    router_ok = probe_router(rm)
    print("Candidatos:\n" + "\n".join(report))
    print(f"Roteador {rm}: {'ok (Decisions API respondeu)' if router_ok else 'FALHOU na Decisions API — hook cai no fallback'}")
    if not chosen:
        print("ERRO: nenhum candidato elegível", file=sys.stderr)
        return 1
    fb = policy.get("fallback")
    if fb not in {c["role"] for c in chosen}:
        fb = chosen[0]["role"]

    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%MZ")
    hdr = f"# GERADO por scripts/router_sync.py em {stamp} — não editar; edite policy.yaml e rode `oute router-sync`.\n"

    router = {"fallback": fb, "candidates": [
        {"name": c["role"], "model": c["id"], "desc": c["desc"], "tools": c["tools"], "vision": c["vision"],
         "max_output": c["max_output"], "context": c["context"], "cost_in": c["cost_in"], "cost_out": c["cost_out"]}
        for c in chosen]}

    fb_model = next(c["id"] for c in chosen if c["role"] == fb)
    ml = [{"model_name": "jev-router",
           "litellm_params": {"model": f"openrouter/{fb_model}", "api_key": "os.environ/OPENROUTER_API_KEY"}}]
    ml += [{"model_name": c["role"],
            "litellm_params": {"model": f"openrouter/{c['id']}", "api_key": "os.environ/OPENROUTER_API_KEY"}}
           for c in chosen]
    litellm = {
        "model_list": ml,
        "litellm_settings": {"callbacks": "jev_hook.handler", "drop_params": True, "num_retries": 2, "request_timeout": 600},
        "general_settings": {"master_key": "os.environ/LITELLM_MASTER_KEY"},
    }
    pi = [{"id": "jev-router", "name": "Jev router (auto)", "contextWindow": 200000, "maxTokens": 32000}] + [
        {"id": c["role"], "name": f"{c['role']} ({c['id']})", "contextWindow": c["context"] or 128000,
         "maxTokens": min(c["max_output"] or 32000, 64000)} for c in chosen]
    catalog = sorted(eligible.values(), key=lambda m: (m["providers"], m["id"]))

    if DRY:
        print("\n--dry-run: nada gravado")
        return 0
    (CFG / "router.yaml").write_text(hdr + yaml.safe_dump(router, sort_keys=False, allow_unicode=True))
    (CFG / "config.yaml").write_text(hdr + yaml.safe_dump(litellm, sort_keys=False, allow_unicode=True))
    (CFG / "candidates.json").write_text(json.dumps(pi, indent=2, ensure_ascii=False) + "\n")
    (CFG / "catalog.json").write_text(json.dumps({"generated": stamp, "providers_allow": sorted(allow),
                                                  "router_model_eligible": router_ok, "models": catalog},
                                                 indent=2, ensure_ascii=False) + "\n")
    print(f"\ngravado: router.yaml, config.yaml, candidates.json, catalog.json ({len(catalog)} modelos elegíveis consultados)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
