"""Config do agent-studio em `config/agent-studio/config.toml` (ADR-08, #203), montada só leitura no compose:
mudança entra com `git pull` + `oute down/up`, sem release. `[prices]` (#203; `fixed = true` trava o modelo, #339) e `[alerts]` (#204).

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
    prices: PriceTable = field(default_factory=PriceTable)  # a tabela viva: começa pelo config.toml, o histórico a troca (#339)
    seed: dict = field(default_factory=dict)       # {modelo: ModelPrice} do config.toml: a semente do histórico
    fixed: frozenset = frozenset()                 # modelos com `fixed = true`: a fonte nunca os troca
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
    prices, fixed = {}, set()
    for model, fields in raw.items():
        try:
            if isinstance(fields, dict) and "fixed" in fields:
                fields = dict(fields)
                if not isinstance(fields.pop("fixed"), bool):
                    raise ValueError("fixed precisa ser true ou false")
                if raw[model]["fixed"]:
                    fixed.add(str(model).lower())
            prices[model] = ModelPrice.parse(fields)
        except ValueError as e:
            fixed.discard(str(model).lower())
            errors.append(f"preço inválido para {model}: {e}")
    return Config(prices=PriceTable(prices), seed={str(m).lower(): p for m, p in prices.items()},
                  fixed=frozenset(fixed), alerts=alerts, errors=errors)
