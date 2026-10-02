"""DuckDB do agent-studio: um escritor só, uma transação por requisição (ADR-08 §3 e §4).

Tabelas nativas num arquivo `.duckdb`. Colunas fixas + JSON; `time` é a hora do fato (timeUnixNano), nunca a de
chegada (`received_at` fica à parte). A chave de dedupe é a PRIMARY KEY: reenvio do mesmo registro não vira linha
nova.
"""
import threading

import duckdb

from . import (alerts as alerts_mod, conversations as conv_mod, proposals as prop_mod, sessions as sess_mod,
               tray as tray_mod, usage as usage_mod)

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


class Store:
    def __init__(self, path):
        self.path = path
        self.con = duckdb.connect(path)
        # a hora é sempre UTC, qualquer que seja o TZ do container (a imagem usa America/Sao_Paulo)
        self.con.execute("SET TimeZone = 'UTC'")
        self.lock = threading.Lock()
        with self.lock:
            for sql in SQL.values():
                self.con.execute(sql["create"])

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

    def usage(self, from_ns, to_ns, prices):
        """Leitura do `/v1/usage` (#203), sob a trava do escritor: uma conexão só, leitura e escrita em fila."""
        with self.lock:
            return usage_mod.usage(self.con, from_ns, to_ns, prices)

    def alerts(self, at_ns, cfg):
        """Leitura do `/v1/alerts` (#204), sob a mesma trava."""
        with self.lock:
            return alerts_mod.evaluate(self.con, at_ns, cfg)

    def tray(self, at_ns, prices, cfg):
        """Leitura do `/v1/tray` (#205), sob a mesma trava: os blocos do DuckDB numa passada só."""
        with self.lock:
            return tray_mod.snapshot(self.con, at_ns, prices, cfg)

    # leituras da tela (#206), sob a mesma trava
    def conversations(self, from_ns, to_ns, prices, host=None, agent=None):
        with self.lock:
            return conv_mod.listing(self.con, from_ns, to_ns, prices, host, agent)

    def conversation(self, session_id, prices):
        with self.lock:
            return conv_mod.detail(self.con, session_id, prices)

    def conversation_logs(self, session_id, offset):
        with self.lock:
            return conv_mod.logs(self.con, session_id, offset)

    def span(self, trace_id, span_id):
        with self.lock:
            return conv_mod.span(self.con, trace_id, span_id)

    # leituras da tela de sessões (#207), sob a mesma trava
    def sessions(self, from_ns, to_ns, prices, host=None, agent=None):
        with self.lock:
            return sess_mod.listing(self.con, from_ns, to_ns, prices, host, agent)

    def session(self, task_id, prices):
        with self.lock:
            return sess_mod.detail(self.con, task_id, prices)

    # leitura da página do pedido (#208), sob a mesma trava
    def proposal(self, proposal_id):
        with self.lock:
            return prop_mod.event(self.con, proposal_id)
