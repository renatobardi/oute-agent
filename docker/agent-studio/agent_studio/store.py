"""DuckDB do agent-studio: um escritor só, uma transação por requisição (ADR-08 §3 e §4).

Tabelas nativas num arquivo `.duckdb`. Colunas fixas + JSON; `time` é a hora do fato (timeUnixNano), nunca a de
chegada (`received_at` fica à parte). A chave de dedupe é a PRIMARY KEY: reenvio do mesmo registro não vira linha
nova.
"""
import threading
import time

import duckdb

from . import (alerts as alerts_mod, conversations as conv_mod, dashboard as dash_mod, decisions as decisions_mod, marks as marks_mod, prices as prices_mod, proposals as prop_mod,
               repo as repo_mod, repo_infer, sessions as sess_mod, tools as tools_mod, tray as tray_mod, tz as tz_mod, usage as usage_mod)

# (coluna, tipo) de cada tabela; `time`/`received_at` são derivadas dos *_unix_nano na gravação
TABLES = {
    "logs": [
        ("dedupe_key", "VARCHAR PRIMARY KEY"),
        ("time", "TIMESTAMPTZ NOT NULL"),
        ("time_unix_nano", "UBIGINT NOT NULL"),
        ("observed_unix_nano", "UBIGINT"),
        ("host_name", "VARCHAR"),
        ("oute_instance", "VARCHAR"),
        ("oute_agent", "VARCHAR"),
        ("service_name", "VARCHAR"),
        ("session_id", "VARCHAR"),
        ("oute_task_id", "VARCHAR"),
        ("oute_swarm_round", "VARCHAR"),
        ("oute_repo", "VARCHAR"),
        ("event_name", "VARCHAR"),
        ("oute_event_id", "VARCHAR"),
        ("severity_number", "INTEGER"),
        ("severity_text", "VARCHAR"),
        ("body", "VARCHAR"),
        ("trace_id", "VARCHAR"),
        ("span_id", "VARCHAR"),
        ("scope_name", "VARCHAR"),
        ("resource_attributes", "JSON"),
        ("attributes", "JSON"),
        ("received_at", "TIMESTAMPTZ NOT NULL"),
        ("received_unix_nano", "UBIGINT NOT NULL"),
    ],
}
FIXED_COLS = [
    ("host_name", "VARCHAR"),
    ("oute_instance", "VARCHAR"),
    ("oute_agent", "VARCHAR"),
    ("service_name", "VARCHAR"),
    ("session_id", "VARCHAR"),
    ("oute_task_id", "VARCHAR"),
    ("oute_swarm_round", "VARCHAR"),
    ("oute_repo", "VARCHAR"),
]
TABLES["spans"] = [
    ("dedupe_key", "VARCHAR PRIMARY KEY"),  # s:<trace_id>:<span_id>
    ("time", "TIMESTAMPTZ NOT NULL"),       # início do span
    ("time_unix_nano", "UBIGINT NOT NULL"),
    ("end_unix_nano", "UBIGINT"),
    ("duration_ns", "UBIGINT"),
    *FIXED_COLS,
    ("trace_id", "VARCHAR NOT NULL"),
    ("span_id", "VARCHAR NOT NULL"),
    ("parent_span_id", "VARCHAR"),
    ("name", "VARCHAR"),
    ("kind", "INTEGER"),
    ("status_code", "INTEGER"),
    ("status_message", "VARCHAR"),
    ("model", "VARCHAR"),
    ("input_tokens", "BIGINT"),
    ("output_tokens", "BIGINT"),
    ("cache_read_tokens", "BIGINT"),
    ("cache_creation_tokens", "BIGINT"),
    ("cost_usd", "DOUBLE"),
    ("scope_name", "VARCHAR"),
    ("resource_attributes", "JSON"),
    ("attributes", "JSON"),
    ("events", "JSON"),
    ("links", "JSON"),
    ("received_at", "TIMESTAMPTZ NOT NULL"),
    ("received_unix_nano", "UBIGINT NOT NULL"),
]
TABLES["metrics"] = [
    ("dedupe_key", "VARCHAR PRIMARY KEY"),  # h:<sha256> do ponto
    ("time", "TIMESTAMPTZ NOT NULL"),
    ("time_unix_nano", "UBIGINT NOT NULL"),
    ("start_unix_nano", "UBIGINT"),
    *FIXED_COLS,
    ("metric_name", "VARCHAR NOT NULL"),
    ("metric_type", "VARCHAR NOT NULL"),    # gauge | sum | histogram | exponential_histogram | summary
    ("unit", "VARCHAR"),
    ("value", "DOUBLE"),                    # gauge/sum: o valor; histogram/summary: a soma
    ("count", "UBIGINT"),                   # histogram/summary
    ("is_monotonic", "BOOLEAN"),
    ("aggregation_temporality", "INTEGER"),
    ("scope_name", "VARCHAR"),
    ("resource_attributes", "JSON"),
    ("attributes", "JSON"),                 # atributos do ponto
    ("point", "JSON"),                      # ponto inteiro (buckets, quantis…) sem os atributos
    ("received_at", "TIMESTAMPTZ NOT NULL"),
    ("received_unix_nano", "UBIGINT NOT NULL"),
]
DERIVED = {"time": "time_unix_nano", "received_at": "received_unix_nano"}
DASH_DEADLINE_S = 50   # prazo da consulta do Dashboard (abaixo do corte de 60 s do nginx)
DASH_TTL_S = 60        # quanto o resultado da janela vale
TS_UTC = "(make_timestamp_ns(?::BIGINT) AT TIME ZONE 'UTC')"


def _sql(table, cols):
    names = [c for c, _ in cols]
    return {
        "create": f"CREATE TABLE IF NOT EXISTS {table} ({', '.join(f'{c} {t}' for c, t in cols)})",
        # chaves que já existem, com a lista inteira num parâmetro só
        "existing": f"SELECT dedupe_key FROM {table} WHERE list_contains(?::VARCHAR[], dedupe_key)",
        "insert": f"INSERT OR IGNORE INTO {table} ({', '.join(names)}) "
                  f"VALUES ({', '.join(TS_UTC if c in DERIVED else '?' for c in names)})",
        "columns": names,
    }


# todo SQL montado uma vez, só com os nomes deste módulo; os valores vão sempre em parâmetros
SQL = {table: _sql(table, cols) for table, cols in TABLES.items()}


def migrate(con):
    """Banco criado antes do #528: põe a coluna `oute_repo` e a preenche do JSON `resource_attributes`, para o histórico
    aparecer no filtro de repositório como o resto. Numa transação só (ou a coluna e o preenchimento entram, ou nenhum),
    e só nas tabelas que ainda não têm a coluna: depois disso a subida não varre nada."""
    have = {t for (t,) in con.execute("SELECT table_name FROM information_schema.columns WHERE column_name = 'oute_repo'").fetchall()}
    missing = [t for t in TABLES if t not in have]
    if not missing:
        return
    con.execute("BEGIN TRANSACTION")
    try:
        for table in missing:
            con.execute(f"ALTER TABLE {table} ADD COLUMN oute_repo VARCHAR")
            con.execute(f"UPDATE {table} SET oute_repo = NULLIF(json_extract_string(resource_attributes, '{repo_mod.JSON_PATH}'), '') "
                        f"WHERE json_extract_string(resource_attributes, '{repo_mod.JSON_PATH}') IS NOT NULL")
        con.execute("COMMIT")
    except BaseException:
        con.execute("ROLLBACK")
        raise


class Store:
    def __init__(self, path):
        self.path = path
        self.con = duckdb.connect(path)
        # a hora é sempre UTC, qualquer que seja o TZ do container (a imagem usa America/Sao_Paulo)
        self.con.execute("SET TimeZone = 'UTC'")
        self.lock = threading.Lock()
        self._dash_lock = threading.Lock()
        self._dash_cache = {}
        self._dash_refreshing = {}
        with self.lock:
            for sql in SQL.values():
                self.con.execute(sql["create"])
            migrate(self.con)
            repo_infer.apply(self.con)   # histórico da conversa aberta direto numa pasta (#599)
            repo_mod.apply_legacy(self.con)  # acerto único: o que sobrou sem repositório antes do corte (#617)
            prices_mod.create(self.con)  # histórico de preços (#339)
            marks_mod.create(self.con)   # marcas das ações do Bardi (#510): só de acréscimo, escrita só pela rota

    def close(self):
        with self.lock:
            self.con.close()

    def write(self, batch, before_commit=None):
        """batch = {tabela: [linhas]}. Tudo numa transação: ou grava tudo, ou nada (e levanta a exceção).

        before_commit: chamado depois dos INSERTs e antes do COMMIT (o SurrealDB, #187); se levantar, rollback.
        Devolve {tabela: (gravadas, repetidas)}."""
        result = {}
        with self.lock:
            self.con.execute("BEGIN TRANSACTION")
            try:
                for table, rows in batch.items():
                    result[table] = self._insert(table, rows)
                if before_commit:
                    before_commit()
                self.con.execute("COMMIT")
            except BaseException:
                self.con.execute("ROLLBACK")
                raise
        return result

    def _insert(self, table, rows):
        # repetidas dentro do próprio lote: fica a primeira
        uniq = {}
        for r in rows:
            uniq.setdefault(r["dedupe_key"], r)
        if not uniq:
            return 0, len(rows)
        sql = SQL[table]
        keys = list(uniq)
        seen = {k for (k,) in self.con.execute(sql["existing"], [keys]).fetchall()}
        new = [uniq[k] for k in keys if k not in seen]
        if new:
            cols = sql["columns"]
            self.con.executemany(sql["insert"], [[r[DERIVED[c]] if c in DERIVED else r.get(c) for c in cols] for r in new])
        return len(new), len(rows) - len(new)

    def usage(self, from_ns, to_ns, prices, tz=tz_mod.UTC, repo=None, effective=False):
        """Leitura do `/v1/usage` (#203), sob a trava do escritor: uma conexão só, leitura e escrita em fila. `repo`
        (#528) e `effective` (#531, custo efetivo) só a tela `/uso` passa; o `GET /v1/usage` não tem os parâmetros."""
        with self.lock:
            return usage_mod.usage(self.con, from_ns, to_ns, prices, tz, repo, effective)

    def repos(self, from_ns, to_ns):
        """Os repositórios com fato na janela (#528), para o filtro das telas."""
        with self.lock:
            return repo_mod.options(self.con, from_ns, to_ns)

    def dashboard(self, from_ns, to_ns, prices, tz=tz_mod.UTC, repo=None, model=None, effective=False):
        """Leitura do Dashboard (#469). Roda num cursor próprio, **fora da trava do escritor**: a consulta é longa e,
        sob a trava, parava todas as telas e a ingestão (504 em produção, #504). Uma por vez (`_dash_lock`), com
        prazo (`DASH_DEADLINE_S`: passado, a consulta é interrompida e a tela responde 500). Janela que termina agora
        ("últimas N horas") vale por `DASH_TTL_S`; vencida, a tela recebe a última e a conta se refaz em segundo plano. O repositório (#528), o modelo (#532) e o custo efetivo (#531) fazem parte da chave."""
        minute = 60 * 10**9
        tzk = getattr(tz, "key", str(tz))
        live = abs(time.time_ns() - to_ns) < 2 * minute
        key = (("live", to_ns - from_ns, tzk, repo, model, effective) if live
               else (from_ns // minute, to_ns // minute, tzk, repo, model, effective))
        with self._dash_lock:
            hit = self._dash_cache.get(key)
            if hit and time.monotonic() - hit[0] < DASH_TTL_S:
                return hit[1]
            if hit and live:
                if not self._dash_refreshing.get(key):
                    self._dash_refreshing[key] = True
                    threading.Thread(target=self._dash_refresh, args=(key, from_ns, to_ns, prices, tz, repo, model, effective), daemon=True).start()
                return hit[1]
        return self._dash_refresh(key, from_ns, to_ns, prices, tz, repo, model, effective)

    def _dash_refresh(self, key, from_ns, to_ns, prices, tz, repo=None, model=None, effective=False):
        with self._dash_lock:
            try:
                cur = self.con.cursor()
                timer = threading.Timer(DASH_DEADLINE_S, cur.interrupt)
                timer.start()
                try:
                    snap = dash_mod.snapshot(cur, from_ns, to_ns, prices, tz, repo, model, effective)
                    snap["tools"] = tools_mod.top(cur, from_ns, to_ns, repo)  # gráfico das ferramentas (#535)
                finally:
                    timer.cancel()
                    cur.close()
                self._dash_cache = {**self._dash_cache, key: (time.monotonic(), snap)}
                return snap
            finally:
                self._dash_refreshing.pop(key, None)

    def alerts(self, at_ns, cfg):
        """Leitura do `/v1/alerts` (#204), sob a mesma trava."""
        with self.lock:
            return alerts_mod.evaluate(self.con, at_ns, cfg)

    def tray(self, at_ns, prices, cfg, tz=tz_mod.UTC):
        """Leitura do `/v1/tray` (#205), sob a mesma trava: os blocos do DuckDB numa passada só."""
        with self.lock:
            return tray_mod.snapshot(self.con, at_ns, prices, cfg, tz)

    def decisions(self, at_ns, cfg):
        """Decisões pendentes do Bardi (#386), sob a mesma trava: o bloco do tray e o topo das telas."""
        with self.lock:
            return decisions_mod.pending(self.con, at_ns, cfg)

    # leituras da tela (#206), sob a mesma trava
    def conversations(self, from_ns, to_ns, prices, host=None, agent=None, repo=None, effective=False, limit=conv_mod.LIST_LIMIT):
        with self.lock:
            return conv_mod.listing(self.con, from_ns, to_ns, prices, host, agent, limit=limit, repo=repo, effective=effective)

    def tools(self, from_ns, to_ns, tz=tz_mod.UTC, repo=None, host=None, agent=None):
        """Tela Ferramentas (#535), sob a mesma trava."""
        with self.lock:
            return tools_mod.snapshot(self.con, from_ns, to_ns, tz, repo, host, agent)

    def tool_conversations(self, tool, from_ns, to_ns, repo=None, host=None, agent=None, group=None):
        with self.lock:
            return tools_mod.conversations(self.con, tool, from_ns, to_ns, repo, host, agent, group)

    def conversation(self, session_id, prices, errors_only=False, effective=False):
        with self.lock:
            return conv_mod.detail(self.con, session_id, prices, errors_only=errors_only, effective=effective)

    def conversation_logs(self, session_id, offset, errors_only=False):
        with self.lock:
            return conv_mod.logs(self.con, session_id, offset, errors_only=errors_only)

    def span(self, trace_id, span_id):
        with self.lock:
            return conv_mod.span(self.con, trace_id, span_id)

    # leituras da tela de sessões (#207), sob a mesma trava
    def sessions(self, from_ns, to_ns, prices, host=None, agent=None, repo=None, effective=False, limit=conv_mod.LIST_LIMIT):
        with self.lock:
            return sess_mod.listing(self.con, from_ns, to_ns, prices, host, agent, limit=limit, repo=repo, effective=effective)

    def session(self, task_id, prices, effective=False):
        with self.lock:
            return sess_mod.detail(self.con, task_id, prices, effective=effective)

    # leitura da página do pedido (#208), sob a mesma trava
    def proposal(self, proposal_id):
        with self.lock:
            return prop_mod.event(self.con, proposal_id)

    # histórico de preços (#339): a rotina e o `GET /v1/prices`, sob a mesma trava
    def read(self, fn):
        with self.lock:
            return fn(self.con)

    def transact(self, fn):
        """`fn(con)` numa transação: ou grava tudo, ou nada (e levanta a exceção)."""
        with self.lock:
            self.con.execute("BEGIN TRANSACTION")
            try:
                result = fn(self.con)
                self.con.execute("COMMIT")
            except BaseException:
                self.con.execute("ROLLBACK")
                raise
            return result
