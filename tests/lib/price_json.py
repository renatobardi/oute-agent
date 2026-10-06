"""Corpos de exemplo das fontes de preço (#339) no formato real, para os testes: `models_dev({id: preço})` e
`openrouter({id: preço}, ids)` (`ids` = {modelo: id no OpenRouter} onde o id difere do padrão `provedor/modelo`), com o preço em USD por 1M tokens (`{"input", "output", "cache_read", "cache_creation"}`);
o OpenRouter sai em USD por token, como texto. Uso: PYTHONPATH=tests/lib."""
import json
from decimal import Decimal

PROVIDERS = (("claude-", "anthropic"), ("gpt-", "openai"), ("glm-", "zai"))
ROUTER = {"zai": "z-ai"}  # o prefixo do OpenRouter, onde difere do provedor do models.dev (#679)


def models_dev(prices, extra=None):
    out = {"anthropic": {"models": {}}, "openai": {"models": {}}, **(extra or {})}
    for model, p in prices.items():
        provider = next(pv for pre, pv in PROVIDERS if model.startswith(pre))
        cost = {"input": p["input"], "output": p["output"]}
        if "cache_read" in p: cost["cache_read"] = p["cache_read"]
        if "cache_creation" in p: cost["cache_write"] = p["cache_creation"]
        out.setdefault(provider, {"models": {}})["models"][model] = {"id": model, "cost": cost}
    return json.dumps(out)


def per_token(x):
    return format(Decimal(repr(x)) / 1_000_000, "f")


def openrouter(prices, ids=None):
    data = []
    for model, p in prices.items():
        provider = next(pv for pre, pv in PROVIDERS if model.startswith(pre))
        pricing = {"prompt": per_token(p["input"]), "completion": per_token(p["output"])}
        if "cache_read" in p: pricing["input_cache_read"] = per_token(p["cache_read"])
        if "cache_creation" in p: pricing["input_cache_write"] = per_token(p["cache_creation"])
        data.append({"id": (ids or {}).get(model, f"{ROUTER.get(provider, provider)}/{model}"), "pricing": pricing})
    return json.dumps({"data": data})
