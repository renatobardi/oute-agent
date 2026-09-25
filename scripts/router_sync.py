#!/usr/bin/env python3
"""
router_sync — consulta o OpenRouter e gera a config do jev-router a partir de config/litellm/policy.yaml.

Elegibilidade (em ordem de autoridade):
  1. GET /api/v1/models/user com a key do oute-agent → reflete guardrail/privacidade da key (se o endpoint existir);
  2. senão: GET /api/v1/models/{id}/endpoints e filtra por providers_allow do policy.yaml.
Um modelo só é elegível se tiver >=1 endpoint em provedor permitido e não casar exclude_patterns.

Uso: python3 scripts/router_sync.py [--dry-run] [--check-guardrail]   (OPENROUTER_API_KEY no ambiente; recomendado)

Divergência policy.yaml × guardrail (#16): com OPENROUTER_MGMT_KEY (Management API key, vault `oute-admin`,
nunca no container dos agentes) compara `providers_allow` com o `allowed_providers` do guardrail nomeado em
`policy.yaml: guardrail`. No sync normal só avisa; `--check-guardrail` faz só a checagem e sai 2 se divergir.
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
MGMT = os.environ.get("OPENROUTER_MGMT_KEY", "")
CHECK_ONLY = "--check-guardrail" in sys.argv


def get(path: str, auth: bool = False, key: str | None = None):
    req = urllib.request.Request(API + path, headers={"User-Agent": "oute-agent/router-sync"})
    tok = key if key is not None else (KEY if auth else "")
    if tok:
        req.add_header("Authorization", f"Bearer {tok}")
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


PRESET_PREFIX = "oute-"


def preset_config(prof: dict) -> dict:
    """Config do preset de um perfil (mesmo formato de uma request de chat)."""
    provider: dict = {"data_collection": "deny", "zdr": True}   # reforço do guardrail p/ uso fora do container
    if prof["sort"]:
        provider["sort"] = {"by": prof["sort"], "partition": "none"}
    cfg = {"model": prof["models"][0], "provider": provider}
    if len(prof["models"]) > 1:
        cfg["models"] = prof["models"]
    return cfg


def publish_preset(name: str, cfg: dict) -> str:
    """Cria/atualiza @preset/oute-<name> só se mudou (cada POST vira nova versão no OpenRouter)."""
    slug = PRESET_PREFIX + name
    cur = get(f"/presets/{slug}", auth=True)
    now = ((cur.get("data") or {}).get("designated_version") or {}).get("config") or {}
    if all(now.get(k) == v for k, v in cfg.items()) and set(now) >= set(cfg):
        return "igual"
    body = json.dumps({**cfg, "messages": [{"role": "user", "content": "x"}]}).encode()
    req = urllib.request.Request(
        f"{API}/presets/{slug}/chat/completions", data=body, method="POST",
        headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json",
                 "User-Agent": "oute-agent/router-sync"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            v = ((json.load(r).get("data") or {}).get("designated_version") or {}).get("version")
            return f"publicado v{v}"
    except urllib.error.HTTPError as e:
        print(f"preset {slug}: HTTP {e.code} {e.read()[:200]!r}", file=sys.stderr)
    except Exception as e:  # noqa: BLE001
        print(f"preset {slug}: {type(e).__name__}: {e}", file=sys.stderr)
    return "FALHOU"


def check_guardrail(policy: dict) -> int:
    """#16: policy.yaml (espelho) × guardrail real. 0 = igual, 2 = divergente, 1 = não deu para checar."""
    name = policy.get("guardrail")
    if not name:
        print("guardrail: policy.yaml sem `guardrail:` — divergência não verificada", file=sys.stderr)
        return 1
    if not MGMT:
        print("guardrail: sem OPENROUTER_MGMT_KEY (vault oute-admin) — divergência não verificada", file=sys.stderr)
        return 1
    r = get("/guardrails?limit=100", key=MGMT)
    if "data" not in r:
        print(f"guardrail: GET /guardrails falhou ({r.get('_error')}) — divergência não verificada", file=sys.stderr)
        return 1
    g = next((x for x in r["data"] if x.get("name") == name), None)
    if g is None:
        print(f"DIVERGÊNCIA guardrail: '{name}' não existe no OpenRouter "
              f"(existentes: {[x.get('name') for x in r['data']]})", file=sys.stderr)
        return 2
    local = {s.lower() for s in policy["providers_allow"]}
    remote = {s.lower() for s in (g.get("allowed_providers") or [])}
    problems = []
    if not remote:
        problems.append("guardrail sem allowed_providers (libera todos os provedores)")
    if local - remote:
        problems.append(f"só no policy.yaml (o guardrail bloqueia): {sorted(local - remote)}")
    if remote - local:
        problems.append(f"só no guardrail (o policy.yaml não usa): {sorted(remote - local)}")
    ign = {s.lower() for s in (g.get("ignored_providers") or [])} & local
    if ign:
        problems.append(f"no policy.yaml mas ignorados pelo guardrail: {sorted(ign)}")
    zdr = [k for k in ("enforce_zdr", "enforce_zdr_other") if g.get(k) is False]
    if zdr:
        problems.append(f"ZDR desligado no guardrail ({', '.join(zdr)}); o projeto assume ZDR")
    if problems:
        print(f"DIVERGÊNCIA policy.yaml × guardrail '{name}':", file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        print("  → alinhe config/litellm/policy.yaml ao guardrail (ele é a fonte de verdade) ou o guardrail no painel",
              file=sys.stderr)
        return 2
    print(f"guardrail '{name}': policy.yaml alinhado ({len(local)} provedores)")
    return 0


def main() -> int:
    policy = yaml.safe_load((CFG / "policy.yaml").read_text())
    gstatus = check_guardrail(policy)
    if CHECK_ONLY:
        return gstatus
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

    # --- resolve perfis: por padrão (em ordem), o modelo elegível mais novo; até `limit`
    limit = min(int(policy.get("max_models_per_profile", 3)), 3)  # OpenRouter: `models` <= 3
    chosen, report = [], []
    for c in policy["candidates"]:
        req = c.get("requires", {})
        picked: list[dict] = []
        for pat in c["prefer"]:
            hits = sorted(
                (m for mid, m in eligible.items()
                 if fnmatch.fnmatch(mid, pat)
                 and m not in picked
                 and (not req.get("tools") or m["tools"])
                 and (not req.get("vision") or m["vision"])
                 and m["context"] >= req.get("min_context", 0)),
                key=lambda m: -m["created"])
            if hits:
                picked.append(hits[0])        # 1 por padrão: o mais novo -> perfil mistura famílias
            if len(picked) >= limit:
                break
        if picked:
            head = picked[0]
            chosen.append({"role": c["name"], "desc": c["desc"], "sort": c.get("sort"),
                           "models": picked, "primary": head})
            report.append(f"  {c['name']:<13} sort={str(c.get('sort')):<10} " +
                          ", ".join(f"{m['id']} (${m['cost_in']}/${m['cost_out']})" for m in picked))
        else:
            report.append(f"  {c['name']:<13} -> (NENHUM elegível para {c['prefer']})")

    rm = policy.get("router_model")
    router_ok = probe_router(rm)
    print("Perfis:\n" + "\n".join(report))
    print(f"Roteador {rm}: {'ok (Decisions API respondeu)' if router_ok else 'FALHOU na Decisions API — hook cai no fallback'}")
    if not chosen:
        print("ERRO: nenhum candidato elegível", file=sys.stderr)
        return 1
    fb = policy.get("fallback")
    if fb not in {c["role"] for c in chosen}:
        fb = chosen[0]["role"]

    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%MZ")
    hdr = f"# GERADO por scripts/router_sync.py em {stamp} — não editar; edite policy.yaml e rode `oute router-sync`.\n"

    def rng(ms, k):
        v = [m[k] for m in ms]
        return min(v), max(v)

    router = {"fallback": fb, "candidates": []}
    for c in chosen:
        ms = c["models"]
        cin, cout = rng(ms, "cost_in"), rng(ms, "cost_out")
        router["candidates"].append({
            "name": c["role"],
            "desc": c["desc"],
            "sort": c["sort"],
            "models": [m["id"] for m in ms],
            # capacidades = o que TODOS os modelos do perfil garantem (fallback não pode perder tool/vision)
            "tools": all(m["tools"] for m in ms),
            "vision": all(m["vision"] for m in ms),
            "context": min(m["context"] for m in ms),
            "max_output": min(m["max_output"] or 0 for m in ms),
            "cost_in": cin[0], "cost_out": cout[0],
            "cost_range": f"in ${cin[0]}-{cin[1]}/M, out ${cout[0]}-{cout[1]}/M",
        })

    # --- presets no OpenRouter (@preset/oute-<perfil>): perfil utilizável fora do container
    presets_ok: dict[str, bool] = {}
    if not DRY and KEY and "--no-presets" not in sys.argv:
        print("\nPresets:")
        for r in router["candidates"]:
            st = publish_preset(r["name"], preset_config(r))
            presets_ok[r["name"]] = st != "FALHOU"
            if presets_ok[r["name"]]:
                r["preset"] = f"@preset/{PRESET_PREFIX}{r['name']}"
            print(f"  @preset/{PRESET_PREFIX}{r['name']:<13} {st}")

    def target(role: str, primary: str) -> str:
        # com preset: LiteLLM manda "@preset/oute-x" pro OpenRouter (models+sort ficam no preset)
        return f"openrouter/@preset/{PRESET_PREFIX}{role}" if presets_ok.get(role) else f"openrouter/{primary}"

    fb_model = next(c["primary"]["id"] for c in chosen if c["role"] == fb)
    ml = [{"model_name": "jev-router",
           "litellm_params": {"model": target(fb, fb_model), "api_key": "os.environ/OPENROUTER_API_KEY"}}]
    ml += [{"model_name": c["role"],
            "litellm_params": {"model": target(c["role"], c["primary"]["id"]), "api_key": "os.environ/OPENROUTER_API_KEY"}}
           for c in chosen]
    litellm = {
        "model_list": ml,
        "litellm_settings": {"callbacks": ["jev_hook.handler", "otel"],  # otel -> otel-collector (#13)
                              "drop_params": True, "num_retries": 2, "request_timeout": 600},
        "general_settings": {"master_key": "os.environ/LITELLM_MASTER_KEY"},
    }
    pi = [{"id": "jev-router", "name": "Jev router (auto)", "contextWindow": 200000, "maxTokens": 32000}] + [
        {"id": r["name"], "name": f"{r['name']} ({len(r['models'])} modelos, {r['sort'] or 'ordem'})",
         "contextWindow": r["context"] or 128000, "maxTokens": min(r["max_output"] or 32000, 64000)}
        for r in router["candidates"]]
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
