"""Config do agent-studio em `config/agent-studio/config.toml` (ADR-08, #203), montada só leitura no compose:
mudança entra com `git pull` + `oute down/up`, sem release. Hoje só `[prices]`; o #204 põe hosts e limites aqui.

Nunca derruba o serviço: arquivo ausente ou inválido = config vazia, com o motivo em `errors` (vai ao stderr e à
resposta do `/v1/usage`). Entrada de preço inválida fica de fora (o modelo aparece sem preço) e entra em `errors`.
"""
import os
import tomllib
from dataclasses import dataclass, field

from .cost import ModelPrice, PriceTable

DEFAULT_PATH = "/etc/oute/agent-studio/config.toml"


@dataclass
class Config:
    prices: PriceTable = field(default_factory=PriceTable)
    errors: list = field(default_factory=list)


def load(path=None):
    path = path or os.environ.get("AGENT_STUDIO_CONFIG", DEFAULT_PATH)
    try:
        with open(path, "rb") as f:
            data = tomllib.load(f)
    except FileNotFoundError:
        return Config(errors=[f"config não encontrada: {path}"])
    except (OSError, tomllib.TOMLDecodeError, UnicodeDecodeError) as e:
        return Config(errors=[f"config inválida ({path}): {type(e).__name__}"])
    errors = []
    raw = data.get("prices", {})
    if not isinstance(raw, dict):
        return Config(errors=["[prices] não é tabela"])
    prices = {}
    for model, fields in raw.items():
        try:
            prices[model] = ModelPrice.parse(fields)
        except ValueError as e:
            errors.append(f"preço inválido para {model}: {e}")
    return Config(prices=PriceTable(prices), errors=errors)
