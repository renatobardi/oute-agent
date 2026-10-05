"""Marcas das ações do Bardi (#510, ADR-08 "Página da rodada e do ciclo", D3=1): a tabela `action_marks` do DuckDB.

**Só de acréscimo** (nunca `UPDATE` nem `DELETE`) e **escrita só pela rota `POST /rodada/acao`**: a ingestão nunca escreve
nela. Cada marca é uma linha: rodada, etapa (tipo e chave), id da ação, estado (`feita` ou `pendente`), hora do servidor
(`marked_unix_nano`) e quem marcou (`marked_by = human`). O estado de uma ação é o da linha mais nova dela. A marca **não vai ao bucket**
(perda aceita, D3=1): volume do DuckDB perdido = caixas de volta a `pendente`; o `rebuild-state` remonta o SurrealDB só
a partir do que o DuckDB tem.
"""
import time

STATES = ("feita", "pendente")
BY = "human"

SCHEMA = """CREATE TABLE IF NOT EXISTS action_marks (
    rodada VARCHAR NOT NULL, kind VARCHAR NOT NULL, key VARCHAR NOT NULL, action_id VARCHAR NOT NULL,
    state VARCHAR NOT NULL, marked_unix_nano UBIGINT NOT NULL, marked_by VARCHAR NOT NULL,
    PRIMARY KEY (rodada, kind, key, action_id, marked_unix_nano))"""
COLUMNS = ("rodada", "kind", "key", "action_id", "state", "marked_unix_nano", "marked_by")   # `by` é palavra reservada do DuckDB


def create(con):
    con.execute(SCHEMA)


def append(con, rodada, kind, key, action_id, state):
    """Acrescenta a marca (dentro de uma transação do chamador) e devolve a linha como dict. A hora é a do servidor e
    cresce sempre: duas marcas da mesma ação nunca empatam, e a mais nova vence."""
    last = con.execute("SELECT max(marked_unix_nano) FROM action_marks").fetchone()[0] or 0
    ns = max(time.time_ns(), int(last) + 1)
    con.execute("INSERT INTO action_marks (rodada, kind, key, action_id, state, marked_unix_nano, marked_by) VALUES (?, ?, ?, ?, ?, ?, ?)",
                [rodada, kind, key, action_id, state, ns, BY])
    return dict(zip(COLUMNS, (rodada, kind, key, action_id, state, ns, BY)))


def has_table(con):
    return con.execute("SELECT count(*) FROM information_schema.tables WHERE table_name = 'action_marks'").fetchone()[0] > 0


def rows(con, chunk):
    """Todas as marcas, na ordem em que entraram, em blocos (o `rebuild-state`). Sem a tabela (banco anterior à #510): nada."""
    if not has_table(con):
        return
    cur = con.execute(f"SELECT {', '.join(COLUMNS)} FROM action_marks ORDER BY marked_unix_nano")
    while True:
        block = cur.fetchmany(chunk)
        if not block:
            return
        yield [dict(zip(COLUMNS, b)) for b in block]
