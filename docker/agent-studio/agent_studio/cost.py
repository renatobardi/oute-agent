"""Regras de custo e de escopo do uso (ADR-08 §9, #203): módulo puro, sem I/O e sem banco.

Vale para todo consumidor do uso: o `GET /v1/usage` (via `usage.py`), os alertas (#204), o tray e a tela (#205 a
#207), que reusam este módulo e o `usage.aggregate`. O SQL sai daqui montado, com os valores sempre em parâmetro.

- **Chamada ao modelo** = span `claude_code.llm_request` (Claude Code), `session_task.turn` (Codex) ou
  `jev.decision` (histórico, ver abaixo). Tokens, custo e p95 saem só delas.
- **Histórico até 2026-09-30 (#218):** o jev-router (LiteLLM + OpenRouter) saiu do stack e ninguém mais emite
  `jev.decision` nem `oute.agent=router`. As regras desses registros ficam só para o que já está gravado, para o
  custo passado não sumir do `/v1/usage`:
  - o `jev.decision` (hook do jev-router) traz o custo real do OpenRouter e sempre conta (uma vez: a dedupe da
    ingestão é por trace + span), mesmo se chegou sem o `oute.agent` do cliente;
  - os spans do LiteLLM (`oute.agent=router`) ficam fora das somas, para não contar duas vezes: o `jev.decision`
    da mesma chamada já traz tokens e custo.
- **Custo real** = `cost_usd` do span (OpenRouter no `jev.decision` histórico) ou, sem ele, o do log `api_request`
  de mesmo `request_id` (#157): o span `claude_code.llm_request` chega sem custo, e o Claude Code o manda no log da
  mesma chamada. A unidade segue sendo o span: log sem span não é chamada, log repetido conta uma vez (um custo por
  `request_id`). Tudo na consulta (`spans_with_cost`), sem mudar schema nem ingestão: vale para o que já está
  gravado.
- **Custo estimado** = tabela de preços aplicada aos tokens das chamadas **sem** custo real (Codex; Claude sem log
  `api_request`). Modelo sem preço = **sem estimativa** (`None`), nunca zero.
- **Erros** = spans com status de erro (qualquer span, inclusive os do LiteLLM: o `jev.decision` só nasce de
  chamada que deu certo, então não há duplicata) e logs de severidade ERROR ou acima.
"""
from dataclasses import dataclass

# nomes exatos dos spans que representam uma chamada ao modelo
MODEL_CALL_SPANS = ("claude_code.llm_request", "session_task.turn", "jev.decision")
# histórico até 2026-09-30 (#218): só existem em registro já gravado, ninguém mais emite
ROUTER_AGENT = "router"
DECISION_SPAN = "jev.decision"

# SQL do escopo das somas (nomes sempre como parâmetro: MODEL_CALL_PARAMS, na ordem)
MODEL_CALL_SQL = (f"name IN ({', '.join('?' * len(MODEL_CALL_SPANS))}) "
                  "AND (name = ? OR oute_agent IS DISTINCT FROM ?)")
MODEL_CALL_PARAMS = (*MODEL_CALL_SPANS, DECISION_SPAN, ROUTER_AGENT)

# custo do Claude no log (#157): o span da chamada e o log `api_request` levam o mesmo `request_id`
CLAUDE_CALL_SPAN = "claude_code.llm_request"
API_REQUEST_EVENTS = ("api_request", "claude_code.api_request")  # `event.name` do Claude Code (e com o prefixo)
# o log sai no fim da chamada e o span tem a hora do início: numa janela, os logs são lidos com esta folga de cada
# lado, para a chamada na borda manter o custo (a chamada mais longa do Claude Code fica bem abaixo de 1 h)
LOG_COST_MARGIN_NS = 3_600_000_000_000

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
    """Preço por modelo **e por hora** (#339). Cada modelo tem um histórico `[(início da vigência em ns, ModelPrice)]`:
    o preço de uma chamada é o que valia na hora do fato (`lookup(modelo, at_ns)`); antes da primeira linha do
    modelo vale a primeira (o estimado de chamada antiga nunca fica sem preço só porque a linha nasceu depois).
    Valor `ModelPrice` solto = uma linha só, desde sempre (a tabela do `config.toml`). Sem `at_ns`, o preço vigente.

    Busca sem diferenciar maiúsculas; sem entrada exata, tenta sem o prefixo do provedor (`openai/gpt-5-codex` ->
    `gpt-5-codex`). A tabela viva do serviço é trocada inteira por `replace` (a rotina de preços, #339): quem lê pega
    um `snapshot` e enxerga uma versão só do começo ao fim."""

    def __init__(self, prices=None):
        self._by = self._build(prices)

    @staticmethod
    def _build(prices):
        by = {}
        for m, p in (prices or {}).items():
            hist = [(0, p)] if isinstance(p, ModelPrice) else sorted(p, key=lambda row: row[0])
            if hist:
                by[str(m).lower()] = tuple(hist)
        return by

    def _history(self, model, by=None):
        if not model:
            return None
        by = self._by if by is None else by
        m = model.lower()
        h = by.get(m)
        if h is None and "/" in m:
            h = by.get(m.rsplit("/", 1)[1])
        return h

    def key(self, model):
        """Chave da tabela que o `lookup` acharia para `model` (sem caixa e sem prefixo, se for o caso); `None` se não há."""
        if not model:
            return None
        m = model.lower()
        if m in self._by:
            return m
        if "/" in m and m.rsplit("/", 1)[1] in self._by:
            return m.rsplit("/", 1)[1]
        return None

    def lookup(self, model, at_ns=None):
        h = self._history(model)
        if h is None:
            return None
        if at_ns is None:
            return h[-1][1]
        vigente = h[0][1]
        for start, price in h:
            if start > at_ns:
                break
            vigente = price
        return vigente

    def boundaries(self):
        """Horas (ns) em que algum modelo troca de preço, em ordem: o início de toda linha menos a primeira de cada
        modelo. Entre duas horas seguidas nenhum preço muda, então o estimado se agrupa por faixa."""
        return sorted({start for h in self._by.values() for start, _ in h[1:]})

    def models(self):
        return sorted(self._by)

    def replace(self, other):
        """Troca todo o conteúdo pelo de `other` (uma atribuição só: leitor concorrente vê a versão velha ou a nova)."""
        self._by = other._by

    def snapshot(self):
        """Cópia imutável do estado de agora: o conteúdo é trocado por inteiro, nunca editado."""
        snap = PriceTable()
        snap._by = self._by
        return snap

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


def call_cost(cost_usd, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, price):
    """Custo de UMA chamada ao modelo, pela mesma regra das somas do `usage.aggregate`: `("real", usd)` quando a
    chamada tem custo efetivo (`cost_usd` de `spans_with_cost`); senão `("estimated", usd)` pela tabela; modelo sem preço = `("unpriced", None)`, nunca zero."""
    if cost_usd is not None:
        return "real", cost_usd
    est = estimate_cost_usd(input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, price)
    return ("unpriced", None) if est is None else ("estimated", est)


def spans_with_cost(span_where, span_params, log_where, log_params):
    """(SQL, parâmetros) de uma subconsulta com as colunas de `spans` filtradas por `span_where`, em que `cost_usd` é
    o **custo efetivo**: o do span ou, sem ele, o do log `api_request` de mesmo `request_id` (só no span da chamada
    do Claude). Os logs lidos são os de `log_where`; vários logs do mesmo `request_id` dão um custo só."""
    # junção só por igualdade (hash join): a condição `s.name = ?` dentro do ON, ou a chave como expressão sobre o
    # span, fazia o DuckDB comparar cada span com cada log (quadrático, ~30 s em /uso de 7 d, #504). A chave
    # `_rid` é calculada antes e é nula fora do span da chamada do Claude (nulo não junta).
    sql = ("(SELECT t.* EXCLUDE (_rid) REPLACE (COALESCE(t.cost_usd, l.cost_usd) AS cost_usd) FROM ("
           "SELECT s.*, CASE WHEN s.name = ? THEN json_extract_string(s.attributes, '$.request_id') END AS _rid "
           f"FROM spans s WHERE {span_where}) t LEFT JOIN ("
           "SELECT json_extract_string(attributes, '$.request_id') AS request_id, "
           "max(TRY_CAST(json_extract_string(attributes, '$.cost_usd') AS DOUBLE)) AS cost_usd FROM logs "
           f"WHERE event_name IN ({', '.join('?' * len(API_REQUEST_EVENTS))}) AND {log_where} GROUP BY ALL) l "
           "ON l.request_id = t._rid)")
    return sql, [CLAUDE_CALL_SPAN, *span_params, *API_REQUEST_EVENTS, *log_params]


def window_spans_with_cost(from_ns, to_ns, span_extra="", span_extra_params=()):
    """`spans_with_cost` dos spans que começam em [from_ns, to_ns), com os logs da janela mais a folga. `span_extra` =
    condição a mais sobre os spans (` AND …`, com os parâmetros em `span_extra_params`): o filtro de repositório, #528."""
    return spans_with_cost(f"time_unix_nano >= ? AND time_unix_nano < ?{span_extra}", [from_ns, to_ns, *span_extra_params],
                           "time_unix_nano >= ? AND time_unix_nano < ?",
                           [max(from_ns - LOG_COST_MARGIN_NS, 0), to_ns + LOG_COST_MARGIN_NS])
