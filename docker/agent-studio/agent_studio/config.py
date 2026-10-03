"""Config do agent-studio em `config/agent-studio/config.toml` (ADR-08, #203), montada só leitura no compose:
mudança entra com `git pull` + `oute down/up`, sem release. `[prices]` (#203; `fixed = true` trava o modelo, #339) e `[alerts]` (#204).

Nunca derruba o serviço: arquivo ausente ou inválido = sem preços e alertas com os padrões, com o motivo em `errors`
(vai ao stderr e às respostas do `/v1/usage` e do `/v1/alerts`). Entrada de preço inválida fica de fora (o modelo
aparece sem preço); chave de alerta inválida fica com o padrão. As duas entram em `errors`.

`timezone` (#415): nome IANA do fuso das horas e dos dias que o studio mostra (`America/Sao_Paulo`). Inválido = UTC,
com o motivo em `errors`; ausente = UTC, com aviso só no log (`warnings`). Só a leitura usa: nada gravado muda.
"""
import os
import tomllib
from dataclasses import dataclass, field

from . import tz as tz_mod
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
    tz: object = tz_mod.UTC                        # `ZoneInfo` de exibição (`timezone` do config.toml, #415); padrão UTC
    warnings: list = field(default_factory=list)   # avisos que só vão ao log (fuso ausente), fora de `errors` da API


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
    zone, warnings = _timezone(data, errors)
    raw = data.get("prices", {})
    if not isinstance(raw, dict):
        return Config(alerts=alerts, errors=["[prices] não é tabela", *errors], tz=zone, warnings=warnings)
    prices, fixed = _prices(raw, errors)
    return Config(prices=PriceTable(prices), seed={str(m).lower(): p for m, p in prices.items()},
                  fixed=frozenset(fixed), alerts=alerts, errors=errors, tz=zone, warnings=warnings)


def _timezone(data, errors):
    """(`ZoneInfo`, avisos) do `timezone` do config; inválido vai em `errors` e cai em UTC."""
    if "timezone" not in data:
        return tz_mod.UTC, [f"config sem `timezone`: horas e dias em {tz_mod.DEFAULT}"]
    try:
        return tz_mod.parse(data["timezone"]), []
    except ValueError as e:
        errors.append(f"timezone inválido ({e}): horas e dias em {tz_mod.DEFAULT}")
        return tz_mod.UTC, []


def _fixed(fields):
    """(campos de preço sem a marca, está fixo?) de uma entrada `[prices."x"]`; `fixed` que não é booleano = ValueError."""
    if not isinstance(fields, dict) or "fixed" not in fields:
        return fields, False
    fields = dict(fields)
    marked = fields.pop("fixed")
    if not isinstance(marked, bool):
        raise ValueError("fixed precisa ser true ou false")
    return fields, marked


def _prices(raw, errors):
    """({modelo: ModelPrice}, {modelos fixos}) do `[prices]`; entrada inválida vai em `errors` e fica de fora."""
    prices, fixed = {}, set()
    for model, fields in raw.items():
        try:
            fields, marked = _fixed(fields)
            prices[model] = ModelPrice.parse(fields)
        except ValueError as e:
            errors.append(f"preço inválido para {model}: {e}")
            continue
        if marked:
            fixed.add(str(model).lower())
    return prices, fixed
