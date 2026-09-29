"""DuckDB do agent-studio: um escritor só, uma transação por requisição (ADR-08 §3 e §4).

Tabelas nativas num arquivo `.duckdb`. Colunas fixas + JSON; `time` é a hora do fato (timeUnixNano), nunca a de
chegada (`received_at` fica à parte). A chave de dedupe é a PRIMARY KEY: reenvio do mesmo registro não vira linha
nova.
"""
import threading

import duckdb

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


class Store:
    def __init__(self, path):
        self.path = path
        self.con = duckdb.connect(path)
        # a hora é sempre UTC, qualquer que seja o TZ do container (a imagem usa America/Sao_Paulo)
        self.con.execute("SET TimeZone = 'UTC'")
        self.lock = threading.Lock()
        with self.lock:
            for table, cols in TABLES.items():
                self.con.execute(f"CREATE TABLE IF NOT EXISTS {table} ({', '.join(f'{c} {t}' for c, t in cols)})")

    def close(self):
        with self.lock:
            self.con.close()

    def write(self, batch):
        """batch = {tabela: [linhas]}. Tudo numa transação: ou grava tudo, ou nada (e levanta a exceção).

        Devolve {tabela: (gravadas, repetidas)}."""
        result = {}
        with self.lock:
            self.con.execute("BEGIN TRANSACTION")
            try:
                for table, rows in batch.items():
                    result[table] = self._insert(table, rows)
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
        keys = list(uniq)
        seen = set()
        for i in range(0, len(keys), 1000):
            part = keys[i:i + 1000]
            seen.update(k for (k,) in self.con.execute(
                f"SELECT dedupe_key FROM {table} WHERE dedupe_key IN ({', '.join('?' * len(part))})", part).fetchall())
        new = [uniq[k] for k in keys if k not in seen]
        if new:
            cols = [c for c, _ in TABLES[table]]
            vals = ", ".join("(make_timestamp_ns(?::BIGINT) AT TIME ZONE 'UTC')" if c in DERIVED else "?" for c in cols)
            sql = f"INSERT OR IGNORE INTO {table} ({', '.join(cols)}) VALUES ({vals})"
            self.con.executemany(sql, [[r[DERIVED[c]] if c in DERIVED else r.get(c) for c in cols] for r in new])
        return len(new), len(rows) - len(new)
