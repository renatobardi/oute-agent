"""Histórico de preços e rotina diária de conferência (#339, ADR-08, adendo "Preços").

**Três tabelas no DuckDB, só de acréscimo** (nunca `UPDATE` nem `DELETE`; a rotina não escreve em mais nada):
- `price_history`: uma linha por mudança de preço de um modelo (USD por 1M tokens nos quatro eixos), com a origem
  (`config` | `fontes`) e o início da vigência (ns UTC). O preço de uma chamada é o da linha vigente **na hora do
  fato** (`cost.PriceTable`); chamada antiga não é recalculada.
- `price_runs`: uma linha por fonte a cada conferência (`ok` ou o código da falha, `price_sources.E_*`).
- `price_checks`: uma linha por modelo conferido a cada conferência, com o resultado (`STATUSES`) e o detalhe em
  JSON. Os alertas de preço (`price_alerts.py`) leem a conferência mais recente; por isso um problema "fica até
  resolver": some quando a conferência seguinte não o repete.

**Semente** (`seed`, na subida): o `config.toml` dá a primeira linha dos modelos que ainda não têm nenhuma. Modelo com
`fixed = true` no `config.toml` é a trava manual: a fonte nunca o troca (só gera alerta) e o preço do arquivo vale
sempre (editar o arquivo acrescenta uma linha `config`). Modelo sem a marca: depois da semente, o preço do arquivo
deixa de valer (o histórico manda).

**Conferência** (`check`, na subida e uma vez por dia): confere os modelos da tabela do seletor mais todo modelo
com chamada nos últimos 30 dias. Só troca o preço quando **as duas fontes concordam** (`agree`); fonte fora do ar,
divergência ou modelo que uma das fontes não tem deixam o preço como está.
"""
import json
import logging
import os
import re
import threading
import time
import tomllib
from dataclasses import astuple

from . import cost as cost_mod, price_sources as src
from .alerts import iso

log = logging.getLogger("agent_studio")
detail_log = logging.getLogger("agent_studio_detail")

DAY_NS = 86_400_000_000_000
IN_USE_DAYS = 30
ORIGIN_CONFIG, ORIGIN_SOURCES = "config", "fontes"
DEFAULT_SELECT_TABLE = "/etc/oute/select/models.toml"
_MODEL_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,99}$")

# resultado de um modelo numa conferência
EQUAL, CHANGED, NEW = "igual", "trocado", "novo"
DIVERGE, FIXED_DIFFERS, NO_SOURCE, SOURCE_DOWN = "diverge", "fixo_difere", "sem_fonte", "fonte_fora"
STATUSES = (EQUAL, CHANGED, NEW, DIVERGE, FIXED_DIFFERS, NO_SOURCE, SOURCE_DOWN)

SCHEMA = (
    """CREATE TABLE IF NOT EXISTS price_history (
        model VARCHAR NOT NULL, input DOUBLE NOT NULL, output DOUBLE NOT NULL, cache_read DOUBLE NOT NULL,
        cache_creation DOUBLE NOT NULL, origin VARCHAR NOT NULL, start_unix_nano UBIGINT NOT NULL,
        PRIMARY KEY (model, start_unix_nano))""",
    """CREATE TABLE IF NOT EXISTS price_runs (
        checked_unix_nano UBIGINT NOT NULL, source VARCHAR NOT NULL, ok BOOLEAN NOT NULL, reason VARCHAR,
        PRIMARY KEY (checked_unix_nano, source))""",
    """CREATE TABLE IF NOT EXISTS price_checks (
        checked_unix_nano UBIGINT NOT NULL, model VARCHAR NOT NULL, status VARCHAR NOT NULL, detail JSON,
        PRIMARY KEY (checked_unix_nano, model))""",
)


def create(con):
    for sql in SCHEMA:
        con.execute(sql)


def _rows(con, sql, params=()):
    cur = con.execute(sql, list(params))
    names = [d[0] for d in cur.description]
    return [dict(zip(names, r)) for r in cur.fetchall()]


def _price(row):
    return cost_mod.ModelPrice(row["input"], row["output"], row["cache_read"], row["cache_creation"])


def history_rows(con):
    """Todas as linhas do histórico, por modelo e início."""
    return _rows(con, "SELECT * FROM price_history ORDER BY model, start_unix_nano")


def load_table(con):
    """`PriceTable` com o histórico inteiro do banco."""
    by = {}
    for r in history_rows(con):
        by.setdefault(r["model"], []).append((r["start_unix_nano"], _price(r)))
    return cost_mod.PriceTable(by)


def _insert(con, model, price, origin, start_ns):
    """Acrescenta uma linha; `False` se já há linha do modelo nessa hora (a linha antiga nunca é reescrita)."""
    n = con.execute("INSERT OR IGNORE INTO price_history VALUES (?, ?, ?, ?, ?, ?, ?) RETURNING 1",
                    [model, price.input, price.output, price.cache_read, price.cache_creation, origin, start_ns])
    return n.fetchone() is not None


def same(a, b):
    """Dois `ModelPrice` iguais nos quatro eixos (tolerância de arredondamento, 1e-9 relativo)."""
    return all(abs(x - y) <= 1e-9 * max(1.0, abs(x), abs(y)) for x, y in zip(astuple(a), astuple(b)))


def seed(con, config_prices, fixed, now_ns):
    """Semente da subida: linha `config` para o modelo sem histórico; para o fixo, também quando o preço do arquivo
    mudou (a trava manual vale). Devolve quantas linhas entraram. `config_prices` = {modelo (minúsculo): ModelPrice}."""
    table = load_table(con)
    added = 0
    for model, price in sorted(config_prices.items()):
        model = model.lower()
        current = table.lookup(model) if model in table.models() else None
        if current is None or (model in fixed and not same(current, price)):
            added += _insert(con, model, price, ORIGIN_CONFIG, now_ns)
    return added


def sync(store, config, now_ns=None):
    """Na subida: semeia o histórico e põe o histórico na tabela viva (`config.prices`). Se o banco falhar, a tabela
    do `config.toml` continua valendo (a subida não cai) e a falha vai ao stderr."""
    try:
        now = time.time_ns() if now_ns is None else now_ns
        store.transact(lambda con: seed(con, config.seed, config.fixed, now))
        config.prices.replace(store.read(load_table))
    except Exception as e:  # noqa: BLE001 — o histórico de preços nunca derruba a subida
        log.error("preços: semente do histórico falhou, valem os preços do config.toml: %s", type(e).__name__)
        detail_log.exception("preços: semente do histórico falhou")


# ---------------------------------------------------------------- o que conferir
def select_models(path):
    """Ids de modelo da tabela do seletor (`config/select/models.toml`, ADR-02): `[default]`, `[[line]]` e
    `[[exception]]`, colunas `claude` e `codex`. Arquivo ausente ou inválido = conjunto vazio (e o motivo)."""
    try:
        with open(path, "rb") as f:
            data = tomllib.load(f)
    except (OSError, tomllib.TOMLDecodeError, UnicodeDecodeError) as e:
        return set(), type(e).__name__
    entries = [data.get("default"), *(data.get("line") or []), *(data.get("exception") or [])]
    found = set()
    for entry in entries:
        if isinstance(entry, dict):
            for col in ("claude", "codex"):
                v = entry.get(col)
                if isinstance(v, str) and _MODEL_NAME.match(v):
                    found.add(v.lower())
    return found, None


def models_in_use(con, now_ns):
    """{modelo: chamadas sem custo real} dos últimos `IN_USE_DAYS` dias (span de chamada ao modelo, pela hora do
    fato). A segunda parte é o que precisa de preço (o custo real não precisa). Nome fora de `[A-Za-z0-9._:/-]` ou
    com mais de 100 caracteres fica de fora (nada de texto livre indo a busca ou a alerta)."""
    table, params = cost_mod.window_spans_with_cost(max(now_ns - IN_USE_DAYS * DAY_NS, 0), now_ns + 1)
    rows = _rows(con, f"SELECT model, count(*) - count(cost_usd) AS pending FROM {table} "
                      f"WHERE {cost_mod.MODEL_CALL_SQL} AND model IS NOT NULL GROUP BY model",
                 [*params, *cost_mod.MODEL_CALL_PARAMS])
    return {r["model"].lower(): r["pending"] for r in rows if _MODEL_NAME.match(r["model"])}


def targets(table, selector, in_use):
    """{modelo canônico: precisa de preço agora (chamada sem custo real)}: a tabela do seletor mais os modelos em
    uso. O canônico é a chave que a tabela de preços já usa (sem caixa e sem o prefixo do provedor)."""
    out = {}
    for model, pending in [(m, 0) for m in sorted(selector)] + sorted(in_use.items()):
        key = table.key(model) or (model.rsplit("/", 1)[1] if "/" in model else model)
        out[key] = out.get(key, 0) + pending
    return {k: v > 0 for k, v in out.items()}


# ---------------------------------------------------------------- regras de troca
def agree(a, b):
    """Duas leituras parciais ({campo: USD/1M}, sempre com `input` e `output`) -> `(ModelPrice, [])` se concordam, ou
    `(None, [campos que divergem])`. `input` e `output` têm de ser iguais. Cache: presente nas duas = igual; só numa
    fonte = vale a que tem (a outra não contradiz); em nenhuma = o preço de `input` (como no `config.toml`)."""
    bad, vals = [], {}
    for f in src.FIELDS:
        x, y = a.get(f), b.get(f)
        if x is not None and y is not None and abs(x - y) > 1e-9 * max(1.0, abs(x), abs(y)):
            bad.append(f)
        vals[f] = x if x is not None else y
    if bad:
        return None, bad
    for f in ("cache_read", "cache_creation"):
        if vals[f] is None:
            vals[f] = vals["input"]
    return cost_mod.ModelPrice(**vals), []


def _price_dict(p):
    return dict(zip(src.FIELDS, astuple(p)))


def decide(model, current, fixed, reads):
    """Resultado de um modelo: `(status, detalhe, preço novo ou None)`.

    `current` = `ModelPrice` vigente (ou `None`); `fixed` = trava do `config.toml`; `reads` = {fonte: parcial | None
    (a fonte não tem o modelo) | `src.E_*` (a fonte falhou)}. O preço novo só existe quando as duas fontes concordam
    e o valor é novo (modelo sem preço ou preço diferente do vigente) e o modelo não é fixo."""
    down = sorted(s for s, r in reads.items() if isinstance(r, str))
    if down:
        return SOURCE_DOWN, {"sources": down}, None
    missing = sorted(s for s, r in reads.items() if r is None)
    if missing:
        return NO_SOURCE, {"missing": missing}, None
    agreed, bad = agree(reads[src.MODELS_DEV], reads[src.OPENROUTER])
    if agreed is None:
        return DIVERGE, {"fields": {f: {s: reads[s].get(f) for s in src.SOURCES} for f in bad}}, None
    if current is None:
        return NEW, {"new": _price_dict(agreed)}, agreed
    if same(current, agreed):
        return EQUAL, {}, None
    if fixed:
        return FIXED_DIFFERS, {"fixed": _price_dict(current), "sources": _price_dict(agreed)}, None
    return CHANGED, {"old": _price_dict(current), "new": _price_dict(agreed)}, agreed


def reads_for(model, results):
    """{fonte: parcial | None | código de falha} do modelo, pelo mapeamento de id (`price_sources.source_ids`).
    Modelo sem regra de id vale como "a fonte não tem"."""
    ids = src.source_ids(model)
    out = {}
    for source, (state, payload) in results.items():
        out[source] = payload if state == "err" else (payload.get(ids.get(source)) if ids.get(source) else None)
    return out


def apply(con, now_ns, wanted, results, fixed):
    """Grava uma conferência (numa transação do chamador): a linha de cada fonte, o resultado de cada modelo e as
    linhas novas do histórico. `wanted` = `targets(...)`; `results` = {fonte: ("ok", leitura) | ("err", código)}.
    Devolve `[(modelo, status)]` do que gravou."""
    table = load_table(con)
    for source, (state, payload) in results.items():
        con.execute("INSERT INTO price_runs VALUES (?, ?, ?, ?)",
                    [now_ns, source, state == "ok", None if state == "ok" else payload])
    out = []
    for model, needs_price in sorted(wanted.items()):
        current = table.lookup(model) if model in table.models() else None
        status, info, new = decide(model, current, model in fixed, reads_for(model, results))
        if new is not None:
            _insert(con, model, new, ORIGIN_SOURCES, now_ns)
            current = new
        info["unpriced"] = bool(needs_price and current is None)
        con.execute("INSERT INTO price_checks VALUES (?, ?, ?, ?)", [now_ns, model, status, json.dumps(info)])
        out.append((model, status))
    return out


def check(store, config, tel, now_ns=None, urls=None, fetcher=src.fetch, select_path=None):
    """Uma conferência inteira (a rotina do dia). Busca as fontes **sem segurar o banco**, grava numa transação só e
    troca a tabela viva. Nunca levanta: falha (de fonte ou interna) vai à telemetria e ao stderr, e o preço vigente
    continua. Devolve `{"changes": n, "failures": {fonte: código}}`."""
    urls = urls or src.DEFAULT_URLS
    select_path = select_path or os.environ.get("AGENT_STUDIO_SELECT_TABLE", DEFAULT_SELECT_TABLE)
    now = time.time_ns() if now_ns is None else now_ns
    try:
        selector, why = select_models(select_path)
        if why:
            tel.warn("price-select", "preços: tabela do seletor ilegível (%s); confiro só os modelos em uso", why)
        table, used = store.read(lambda con: (load_table(con), models_in_use(con, now)))
        wanted = targets(table, selector, used)
        results = {}
        for source in src.SOURCES:
            try:
                results[source] = ("ok", src.read(source, urls[source], fetcher))
            except src.SourceError as e:
                results[source] = ("err", e.code)
            except Exception:  # noqa: BLE001 — a leitura de terceiro nunca derruba a rotina
                detail_log.exception("preços: leitura de %s falhou", source)
                results[source] = ("err", "interno")
        done = store.transact(lambda con: apply(con, now, wanted, results, config.fixed))
        config.prices.replace(store.read(load_table))
    except Exception as e:  # noqa: BLE001 — a rotina nunca derruba a ingestão nem a API
        tel.price_run(0, {"rotina": "interno"})
        tel.warn("price-check", "preços: a conferência falhou, o preço vigente continua: %s", type(e).__name__,
                 level=logging.ERROR)
        detail_log.exception("preços: a conferência falhou")
        return {"changes": 0, "failures": {"rotina": "interno"}}
    failures = {s: p for s, (state, p) in results.items() if state == "err"}
    changes = sum(1 for _, status in done if status == CHANGED)
    tel.price_run(changes, failures)
    for source, code in failures.items():
        tel.warn(f"price-source-{source}", "preços: a fonte %s falhou (%s); o preço vigente continua", source, code)
    return {"changes": changes, "failures": failures}


class Job:
    """A rotina em segundo plano: uma conferência na subida e outra a cada `interval` segundos (24 h)."""

    def __init__(self, run, interval=DAY_NS // 1_000_000_000):
        self.run, self.interval = run, interval
        self._stop = threading.Event()
        self._thread = None

    def start(self):
        self._thread = threading.Thread(target=self._loop, name="price-check", daemon=True)
        self._thread.start()

    def _loop(self):
        while True:
            try:
                self.run()
            except Exception:  # noqa: BLE001 — `check` já não levanta; isto é só o laço nunca morrer
                detail_log.exception("preços: a rotina levantou")
            if self._stop.wait(self.interval):
                return

    def stop(self):
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=5)


# ---------------------------------------------------------------- GET /v1/prices
def view(con, fixed, at_ns):
    """Resposta do `GET /v1/prices`: por modelo o preço vigente e o histórico (origem e vigência), a trava `fixed` e o
    resultado da última conferência; por fonte a última conferência. Só leitura."""
    last = {r["model"]: r for r in _rows(con, """
        SELECT model, status, checked_unix_nano FROM price_checks
        QUALIFY checked_unix_nano = max(checked_unix_nano) OVER ()""")}
    models = {}
    for r in history_rows(con):
        m = models.setdefault(r["model"], {"model": r["model"], "fixed": r["model"] in fixed, "history": []})
        m["history"].append({**_price_dict(_price(r)), "origin": r["origin"], "since": iso(r["start_unix_nano"])})
    out = []
    for m in sorted(models.values(), key=lambda m: m["model"]):
        m["current"] = m["history"][-1]
        c = last.get(m["model"])
        m["last_check"] = None if c is None else {"status": c["status"], "at": iso(c["checked_unix_nano"])}
        out.append(m)
    sources = []
    for s in src.SOURCES:
        runs = _rows(con, "SELECT checked_unix_nano, ok, reason FROM price_runs WHERE source = ? "
                          "ORDER BY checked_unix_nano DESC LIMIT 1", [s])
        ok = _rows(con, "SELECT max(checked_unix_nano) AS t FROM price_runs WHERE source = ? AND ok", [s])[0]["t"]
        run = runs[0] if runs else None
        sources.append({"source": s, "last_run": run and iso(run["checked_unix_nano"]), "ok": run and run["ok"],
                        "reason": run and run["reason"], "last_ok": iso(ok)})
    return {"at": iso(at_ns), "unit": "USD por 1M tokens", "models": out, "sources": sources}
