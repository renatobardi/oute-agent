"""Config do agent-studio em `config/agent-studio/config.toml` (ADR-08, #203), montada só leitura no compose:
mudança entra com `git pull` + `oute down/up`, sem release. `[prices]` (#203) e `[alerts]` (#204).

Nunca derruba o serviço: arquivo ausente ou inválido = sem preços e alertas com os padrões, com o motivo em `errors`
(vai ao stderr e às respostas do `/v1/usage` e do `/v1/alerts`). Entrada de preço inválida fica de fora (o modelo
aparece sem preço); chave de alerta inválida fica com o padrão. As duas entram em `errors`.
"""
import os
import tomllib
from dataclasses import dataclass, field

from .alerts import AlertConfig
from .cost import ModelPrice, PriceTable

DEFAULT_PATH = "/etc/oute/agent-studio/config.toml"


@dataclass
class Config:
    prices: PriceTable = field(default_factory=PriceTable)
    alerts: AlertConfig = field(default_factory=AlertConfig)
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
    alerts, errors = AlertConfig.parse(data.get("alerts", {}))
    raw = data.get("prices", {})
    if not isinstance(raw, dict):
        return Config(alerts=alerts, errors=["[prices] não é tabela", *errors])
    prices = {}
    for model, fields in raw.items():
        try:
            prices[model] = ModelPrice.parse(fields)
        except ValueError as e:
            errors.append(f"preço inválido para {model}: {e}")
    return Config(prices=PriceTable(prices), alerts=alerts, errors=errors)
