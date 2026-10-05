"""Filtro de repositório das quatro telas (#528): o `oute.task.repo` que o `oute-task` põe no resource de toda conversa
(ADR-04). Conversa aberta fora do `oute-task` não tem repositório: é a opção "sem repositório".

- **Onde mora:** coluna fixa `oute_repo` de `spans` e `logs` (`store.py`), preenchida na ingestão (`otlp.FIXED`) e, no
  histórico, uma vez na subida (`store.migrate`), a partir do JSON `resource_attributes`. A medida que embasa a escolha
  (coluna x JSON a cada consulta) está no comentário de desenho da issue #528.
- **Na URL:** `repo=<nome>`; ausente ou vazio = "Todos"; `repo=(sem)` = "sem repositório". `(sem)` não é nome possível de
  repositório do GitHub, então não colide com nenhum.
- **No SQL:** o valor vai sempre em parâmetro; `COL` é uma constante deste módulo, nunca entrada.
"""
NONE = "(sem)"
COL = "oute_repo"
JSON_PATH = "$.\"oute.task.repo\""


def clause(repo, col=None):
    """(SQL, parâmetros) do filtro, para juntar a um `WHERE` já existente (` AND …`). `repo=None` = sem filtro."""
    col = col or COL
    if repo is None:
        return "", []
    if repo == NONE:
        return f" AND {col} IS NULL", []
    return f" AND {col} = ?", [repo]


def options(con, from_ns, to_ns):
    """Os repositórios com algum fato (span ou log) em [from_ns, to_ns), em ordem; fora o "sem repositório", que a tela
    sempre oferece."""
    cur = con.execute(
        f"SELECT {COL} AS r FROM spans WHERE time_unix_nano >= ? AND time_unix_nano < ? AND {COL} IS NOT NULL GROUP BY ALL "
        f"UNION SELECT {COL} FROM logs WHERE time_unix_nano >= ? AND time_unix_nano < ? AND {COL} IS NOT NULL GROUP BY ALL",
        [from_ns, to_ns, from_ns, to_ns])
    return sorted(r for (r,) in cur.fetchall())


def parse(value):
    """Valor da query string -> filtro (`None` = Todos)."""
    return value or None
