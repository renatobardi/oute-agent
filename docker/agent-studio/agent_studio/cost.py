"""Regras de custo e de escopo do uso (ADR-08 §9, #203): módulo puro, sem I/O e sem banco.

Vale para todo consumidor do uso: o `GET /v1/usage` (via `usage.py`) e, depois, os alertas (#204), o tray e a
tela (#205, #206), que reusam este módulo e o `usage.aggregate`.

- **Chamada ao modelo** = span `claude_code.llm_request` (Claude Code), `session_task.turn` (Codex) ou
  `jev.decision` (hook do jev-router, com o custo real do OpenRouter). Tokens, custo e p95 saem só delas.
- **Sem contar duas vezes:** os spans do LiteLLM (`oute.agent=router`) ficam fora das somas; o `jev.decision` da
  mesma chamada já traz tokens e custo. O `jev.decision` sempre conta (uma vez: a dedupe da ingestão é por
  trace + span), mesmo se chegar sem o `oute.agent` do cliente.
- **Custo real** = `cost_usd` do span (OpenRouter no `jev.decision`, Claude Code).
- **Custo estimado** = tabela de preços aplicada aos tokens das chamadas **sem** custo real (Codex). Modelo sem
  preço = **sem estimativa** (`None`), nunca zero.
- **Erros** = spans com status de erro (qualquer span, inclusive os do LiteLLM: o `jev.decision` só nasce de
  chamada que deu certo, então não há duplicata) e logs de severidade ERROR ou acima.
"""
from dataclasses import dataclass

# nomes exatos dos spans que representam uma chamada ao modelo
MODEL_CALL_SPANS = ("claude_code.llm_request", "session_task.turn", "jev.decision")
ROUTER_AGENT = "router"
DECISION_SPAN = "jev.decision"

# SQL do escopo das somas (nomes sempre como parâmetro: MODEL_CALL_PARAMS, na ordem)
MODEL_CALL_SQL = (f"name IN ({', '.join('?' * len(MODEL_CALL_SPANS))}) "
                  "AND (name = ? OR oute_agent IS DISTINCT FROM ?)")
MODEL_CALL_PARAMS = (*MODEL_CALL_SPANS, DECISION_SPAN, ROUTER_AGENT)

# status de erro do OTLP (STATUS_CODE_ERROR = 2), como fica na coluna `spans.status_code`
SPAN_STATUS_ERROR = 2
# severidade OTLP ERROR (17) e acima (ERROR2..4, FATAL…)
LOG_SEVERITY_ERROR = 17

# eixos de preço (USD por 1M tokens) = colunas de tokens da tabela `spans`
PRICE_FIELDS = ("input", "output", "cache_read", "cache_creation")


@dataclass(frozen=True)
class ModelPrice:
    """USD por 1M tokens. `input` = entrada não cacheada; `cache_read`/`cache_creation` = leitura/escrita de cache."""

    input: float
    output: float
    cache_read: float
    cache_creation: float

    @classmethod
    def parse(cls, fields):
        """Entrada da tabela (dict) -> ModelPrice. `input` e `output` obrigatórios; cache ausente = preço de
        `input` (estimar para cima, nunca de graça). Campo desconhecido, número negativo ou não número = ValueError."""
        if not isinstance(fields, dict):
            raise ValueError("não é tabela")
        unknown = set(fields) - set(PRICE_FIELDS)
        if unknown:
            raise ValueError(f"campo desconhecido: {', '.join(sorted(unknown))}")
        for f in ("input", "output"):
            if f not in fields:
                raise ValueError(f"falta {f}")
        vals = {}
        for f in PRICE_FIELDS:
            v = fields.get(f, fields["input"])
            if isinstance(v, bool) or not isinstance(v, (int, float)) or v < 0:
                raise ValueError(f"{f} precisa ser número >= 0")
            vals[f] = float(v)
        return cls(**vals)


class PriceTable:
    """Preço por modelo. Busca sem diferenciar maiúsculas; sem entrada exata, tenta sem o prefixo do provedor
    (`openai/gpt-5-codex` -> `gpt-5-codex`)."""

    def __init__(self, prices=None):
        self._by = {str(m).lower(): p for m, p in (prices or {}).items()}

    def lookup(self, model):
        if not model:
            return None
        m = model.lower()
        p = self._by.get(m)
        if p is None and "/" in m:
            p = self._by.get(m.rsplit("/", 1)[1])
        return p

    def __len__(self):
        return len(self._by)


def estimate_cost_usd(input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, price):
    """USD estimado pelos tokens. `price=None` (modelo sem preço) devolve `None`: quem soma não trata como zero."""
    if price is None:
        return None
    return (max(input_tokens or 0, 0) * price.input
            + max(output_tokens or 0, 0) * price.output
            + max(cache_read_tokens or 0, 0) * price.cache_read
            + max(cache_creation_tokens or 0, 0) * price.cache_creation) / 1e6
