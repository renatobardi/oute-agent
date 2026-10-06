"""DuckDB do agent-studio: um escritor só, uma transação por requisição (ADR-08 §3 e §4).

Tabelas nativas num arquivo `.duckdb`. Colunas fixas + JSON; `time` é a hora do fato (timeUnixNano), nunca a de
chegada (`received_at` fica à parte). A chave de dedupe é a PRIMARY KEY: reenvio do mesmo registro não vira linha
nova.
"""
import ctypes
import importlib.util
import os
import re
import sys
import threading
import time

import duckdb

# O DuckDB procura o `pandas` no disco a cada execute; sem ele instalado (o studio não o usa), isso era ~17% do tempo com
# o GIL no flamegraph (#570). O sentinela faz a busca falhar na hora; instalado de verdade, nada muda.
if importlib.util.find_spec("pandas") is None:
    sys.modules["pandas"] = None

from . import (acks as acks_mod, alerts as alerts_mod, conversations as conv_mod, dashboard as dash_mod, decisions as decisions_mod, marks as marks_mod, prices as prices_mod, proposals as prop_mod,
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
READ_DEADLINE_S = 50   # prazo de cada leitura fora da trava (#570), abaixo do corte de 60 s do nginx
READ_SLOTS = 2         # leituras ao mesmo tempo (memória do DuckDB); a terceira espera a vez, sem prender a ingestão
TS_UTC = "(make_timestamp_ns(?::BIGINT) AT TIME ZONE 'UTC')"


def name_thread(label):
    """Nome da thread no Python (`py-spy dump`) e no kernel (`top -H`, 15 caracteres): todas eram `python` (#570)."""
    threading.current_thread().name = label
    if sys.platform.startswith("linux"):
        try:
            ctypes.CDLL(None).prctl(15, label.encode()[:15], 0, 0, 0)  # PR_SET_NAME
        except (OSError, AttributeError):
            pass  # só o nome no Python


def _base(typ):
    return typ.split()[0]  # "VARCHAR PRIMARY KEY" -> "VARCHAR"


def _sql(table, cols):
    names = [c for c, _ in cols]
    plain = [(c, _base(t)) for c, t in cols if c not in DERIVED]
    # uma instrução por lote, as colunas em listas (`unnest`): o `executemany` fazia uma execução por linha (~1,3 ms)
    # e segurava a trava do escritor (#570). Os JSON entram como texto e voltam a JSON na seleção; a hora vem do ns.
    unnest = ", ".join(f"unnest(?::{t if t != 'JSON' else 'VARCHAR'}[]) AS {c}" for c, t in plain)
    select = ", ".join(f"(make_timestamp_ns({DERIVED[c]}::BIGINT) AT TIME ZONE 'UTC')" if c in DERIVED
                       else f"{c}::JSON" if t == "JSON" else c for c, t in [(c, _base(t)) for c, t in cols])
    return {
        "create": f"CREATE TABLE IF NOT EXISTS {table} ({', '.join(f'{c} {t}' for c, t in cols)})",
        # chaves que já existem, com a lista inteira num parâmetro só
        "existing": f"SELECT dedupe_key FROM {table} WHERE list_contains(?::VARCHAR[], dedupe_key)",
        "insert": f"INSERT OR IGNORE INTO {table} ({', '.join(names)}) SELECT {select} FROM (SELECT {unnest})",
        "columns": names,
        "plain": [c for c, _ in plain],  # as do `insert`, na ordem das listas: as derivadas saem do ns na seleção
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


# Configuração do DuckDB (#570). O app não configurava nada: o `memory_limit` padrão é 80% da memória do container
# (4,7 GiB de 6g), que somado ao heap do Python cabe mal no limite; e o `checkpoint_threshold` padrão (16 MiB) faz um
# checkpoint a cada poucos minutos, que é o que deixa o COMMIT lento (medido: 17 de 400 lotes acima de 200 ms com 16 MiB,
# 2 com 256 MB; no disco do oute-server eram 6 a 7 s). Com 256 MB, no volume de produção, é cerca de um por dia; o custo
# é reler até 256 MB de WAL depois de uma queda.
DUCKDB_DEFAULTS = {"memory_limit": "3GB", "threads": "2", "checkpoint_threshold": "256MB"}
DUCKDB_ENV = {"memory_limit": "AGENT_STUDIO_DUCKDB_MEMORY", "threads": "AGENT_STUDIO_DUCKDB_THREADS",
              "checkpoint_threshold": "AGENT_STUDIO_DUCKDB_CHECKPOINT"}
_SIZE = re.compile(r"[1-9]\d*(MB|GB|MiB|GiB)\Z")
_THREADS = re.compile(r"([1-9]|[1-5]\d|6[0-4])\Z")


def settings_from_env(env):
    """As variáveis `AGENT_STUDIO_DUCKDB_*` que vieram com valor, como {configuração: valor}. Sem elas, valem os padrões."""
    return {name: env[var] for name, var in DUCKDB_ENV.items() if env.get(var)}


def duckdb_settings(settings):
    """Os padrões com o que veio por cima. O valor vai no texto do `SET` (ele não aceita parâmetro), então só passa o
    que casa com o formato: tamanho com unidade, e de 1 a 64 threads."""
    unknown = set(settings or {}) - set(DUCKDB_DEFAULTS)
    if unknown:
        raise ValueError(f"configuração desconhecida do DuckDB: {sorted(unknown)}")
    out = {**DUCKDB_DEFAULTS, **(settings or {})}
    for name, value in out.items():
        if not isinstance(value, str) or not (_THREADS if name == "threads" else _SIZE).match(value):
            raise ValueError(f"{name} fora do formato: use um tamanho como 3GB ou 256MB (threads: de 1 a 64)")
    return out


class BackupBusy(RuntimeError):
    """Já há uma cópia de segurança em andamento."""


BACKUP_FILE = re.compile(r"agent-studio-\d{8}T\d{6}Z\.duckdb(\.wal)?\Z")


class Store:
    def __init__(self, path, settings=None):
        self.path = path
        applied = duckdb_settings(settings)  # valor fora do formato para aqui, antes de abrir o arquivo
        self.con = duckdb.connect(path)
        for name, value in applied.items():
            self.con.execute(f"SET {name} = '{value}'" if name != "threads" else f"SET threads = {value}")
        # a hora é sempre UTC, qualquer que seja o TZ do container (a imagem usa America/Sao_Paulo)
        self.con.execute("SET TimeZone = 'UTC'")
        self.lock = threading.Lock()
        self._dash_lock = threading.Lock()
        self._read_slots = threading.BoundedSemaphore(READ_SLOTS)
        # quanto vale o resultado do tray e dos alertas (#570): 0 = sempre refaz; o app liga com AGENT_STUDIO_READ_TTL_S
        self.read_ttl = 0.0
        self._cache, self._cache_lock = {}, threading.Lock()
        self._backup_lock = threading.Lock()
        # tempo por fase (#570): `obs(fase, segundos, rótulo=None)`; o app liga na telemetria, sem ela não faz nada
        self.obs = lambda phase, seconds, label=None: None
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
            acks_mod.create(self.con)    # acks de alerta e de decisão pendente (#537): só de acréscimo, escrita só pela rota

    def close(self):
        with self.lock:
            self.con.close()

    def write(self, batch, before_commit=None):
        """batch = {tabela: [linhas]}. Tudo numa transação: ou grava tudo, ou nada (e levanta a exceção).

        before_commit: chamado depois dos INSERTs e antes do COMMIT (o SurrealDB, #187); se levantar, rollback.
        Devolve {tabela: (gravadas, repetidas)}."""
        result = {}
        t = time.monotonic()
        with self.lock:
            t = self._lap("lock_wait", t)
            name_thread("studio-write")
            self.con.execute("BEGIN TRANSACTION")
            try:
                for table, rows in batch.items():
                    result[table] = self._insert(table, rows)
                t = time.monotonic()
                if before_commit:
                    before_commit()
                    t = self._lap("surreal", t)
                self.con.execute("COMMIT")
                self._lap("commit", t)
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
        t = time.monotonic()
        seen = {k for (k,) in self.con.execute(sql["existing"], [keys]).fetchall()}
        t = self._lap("existing", t, table)
        new = [uniq[k] for k in keys if k not in seen]
        if new:
            self.con.execute(sql["insert"], [[r.get(c) for r in new] for c in sql["plain"]])
            self._lap("insert", t, table)
        return len(new), len(rows) - len(new)

    def ping(self):
        """Leitura mínima no DuckDB, num cursor próprio e sem ocupar vaga de leitura: é a do `/readyz` (#570), que não
        pode esperar atrás de duas consultas longas."""
        cur = self.con.cursor()
        try:
            cur.execute("SELECT 1").fetchone()
        finally:
            cur.close()

    def _cached(self, key, fn):
        """Resultado de `fn()` por `read_ttl` s. Uma chamada só o refaz: as outras esperam e recebem o mesmo (o tray, a
        barra de alertas de cada tela e o `/v1/alerts` pediam a mesma conta ao mesmo tempo)."""
        if self.read_ttl <= 0:
            return fn()
        with self._cache_lock:
            hit = self._cache.get(key)
            if hit and time.monotonic() - hit[0] < self.read_ttl:
                return hit[1]
            value = fn()
            self._cache[key] = (time.monotonic(), value)
            return value

    def _copy(self, dest):
        """Cópia consistente do banco em `dest`, com a trava da cópia já tomada. O `COPY FROM DATABASE` lê um retrato num
        cursor próprio: a ingestão segue gravando enquanto ele roda (medido: pior gravação de 68 ms durante a cópia)."""
        if os.path.exists(dest):
            raise FileExistsError(dest)
        if "'" in dest:
            raise ValueError("caminho com aspa")
        t = time.monotonic()
        name_thread("studio-backup")
        cur = self.con.cursor()
        attached = False
        try:
            db = cur.execute("SELECT current_database()").fetchone()[0]
            cur.execute(f"ATTACH '{dest}' AS bak")
            attached = True
            cur.execute(f'COPY FROM DATABASE "{db}" TO bak')
            rows = {table: cur.execute(f"SELECT count(*) FROM bak.{table}").fetchone()[0] for table in TABLES}
            cur.execute("CHECKPOINT bak")
        except BaseException:
            if attached:
                cur.execute("DETACH bak")
                attached = False
            for leftover in (dest, dest + ".wal"):
                if os.path.exists(leftover):
                    os.remove(leftover)
            raise
        finally:
            if attached:
                cur.execute("DETACH bak")
            cur.close()
        self._lap("backup", t)
        return rows

    def backup(self, dest):
        """Cópia de segurança em `dest` (#570), uma por vez (`BackupBusy`). Devolve as linhas por tabela."""
        if not self._backup_lock.acquire(blocking=False):
            raise BackupBusy("cópia em andamento")
        try:
            return self._copy(dest)
        finally:
            self._backup_lock.release()

    def backup_dir(self, directory):
        """Cópia nova em `directory` (criada se preciso), tirando antes as cópias antigas de lá: o `oute studio backup`
        leva a nova ao bucket, a pasta não acumula. Devolve nome, tamanho, tempo e linhas."""
        if not self._backup_lock.acquire(blocking=False):
            raise BackupBusy("cópia em andamento")
        try:
            os.makedirs(directory, exist_ok=True)
            for old in os.listdir(directory):
                if BACKUP_FILE.match(old):
                    os.remove(os.path.join(directory, old))
            name = time.strftime("agent-studio-%Y%m%dT%H%M%SZ.duckdb", time.gmtime())
            t = time.monotonic()
            rows = self._copy(os.path.join(directory, name))
            return {"file": name, "bytes": os.path.getsize(os.path.join(directory, name)),
                    "seconds": round(time.monotonic() - t, 3), "rows": rows}
        finally:
            self._backup_lock.release()

    def _lap(self, phase, since, label=None):
        """Reporta o tempo desde `since` e devolve o instante de agora, para a fase seguinte."""
        now = time.monotonic()
        self.obs(phase, now - since, label)
        return now

    def read_free(self, fn, label="read"):
        """`fn(cursor)` num cursor próprio, **fora da trava do escritor** (#570): a leitura lenta não segura a ingestão
        (o collector desistia em 30 s e reenviava o lote) e a ingestão não segura a leitura. O DuckDB lê o estado
        confirmado enquanto outra conexão grava. No máximo `READ_SLOTS` por vez; passado `READ_DEADLINE_S`, a consulta
        é interrompida e a chamada levanta. `label` nomeia a thread (`studio-<label>`) e a fase reportada."""
        t = time.monotonic()
        with self._read_slots:
            t = self._lap("read_wait", t, label)
            name_thread(f"studio-{label}")
            cur = self.con.cursor()
            timer = threading.Timer(READ_DEADLINE_S, cur.interrupt)
            timer.start()
            try:
                return fn(cur)
            finally:
                timer.cancel()
                cur.close()
                self._lap("read", t, label)

    def usage(self, from_ns, to_ns, prices, tz=tz_mod.UTC, repo=None, effective=False):
        """Leitura do `/v1/usage` (#203), fora da trava do escritor (#570). `repo` (#528) e `effective` (#531, custo
        efetivo) só a tela `/uso` passa; o `GET /v1/usage` não tem os parâmetros."""
        return self.read_free(lambda con: usage_mod.usage(con, from_ns, to_ns, prices, tz, repo, effective), "usage")

    def repos(self, from_ns, to_ns):
        """Os repositórios com fato na janela (#528), para o filtro das telas; fora da trava do escritor (#570)."""
        return self.read_free(lambda con: repo_mod.options(con, from_ns, to_ns), "repos")

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
        """Leitura do `/v1/alerts` (#204), fora da trava do escritor (#570)."""
        return self._cached(("alerts",), lambda: self.read_free(lambda con: alerts_mod.evaluate(con, at_ns, cfg), "alerts"))

    def tray(self, at_ns, prices, cfg, tz=tz_mod.UTC):
        """Leitura do `/v1/tray` (#205): os blocos do DuckDB numa passada só, fora da trava do escritor (#570)."""
        return self._cached(("tray", getattr(tz, "key", str(tz))),
                            lambda: self.read_free(lambda con: tray_mod.snapshot(con, at_ns, prices, cfg, tz), "tray"))

    def decisions(self, at_ns, cfg):
        """Decisões pendentes do Bardi (#386): o bloco do tray e o topo das telas, fora da trava do escritor (#570)."""
        return self.read_free(lambda con: decisions_mod.pending(con, at_ns, cfg), "decisions")

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
