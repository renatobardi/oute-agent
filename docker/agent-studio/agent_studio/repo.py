"""Filtro de repositório das quatro telas (#528): o `oute.task.repo` que o `oute-task` põe no resource de toda conversa
(ADR-04) e que o shim põe na conversa aberta direto numa pasta de repositório (#599). Conversa aberta fora de repositório
não tem repositório: é a opção "sem repositório". No histórico, o `repo_infer` preenche a coluna pelo `file_path`.

- **Onde mora:** coluna fixa `oute_repo` de `spans` e `logs` (`store.py`), preenchida na ingestão (`otlp.FIXED`) e, no
  histórico, uma vez na subida (`store.migrate`), a partir do JSON `resource_attributes`. A medida que embasa a escolha
  (coluna x JSON a cada consulta) está no comentário de desenho da issue #528.
- **Na URL:** `repo=<nome>`; ausente ou vazio = "Todos"; `repo=(sem)` = "sem repositório". `(sem)` não é nome possível de
  repositório do GitHub, então não colide com nenhum.
- **No SQL:** o valor vai sempre em parâmetro; `COL` é uma constante deste módulo, nunca entrada.
- **Acerto único do histórico (#617, ADR-08 "Filtro de repositório"):** fato sem repositório e com hora do fato antes de
  `LEGACY_CUTOFF` fica com `LEGACY_REPO` na coluna. Não é regra: é um acerto de uma vez, a pedido do Bardi, para o
  relatório não ter histórico "sem repositório"; o valor pode estar errado. Vale na ingestão (`legacy`, chamada pelo
  `otlp.fixed`; o replay passa por ela) e na subida (`apply_legacy`, depois do `repo_infer`), com a mesma data. Só a
  coluna muda: o JSON `resource_attributes` e o bucket ficam como chegaram. Fato com repositório nunca é trocado, e
  fato de depois do corte segue a regra normal.
- **Regressão dos agentes (#803):** fato sem repositório com `oute.task.id` começando por `regression-` fica com
  `LEGACY_REPO` em qualquer hora (a suíte roda em pasta temporária, então a inferência pela pasta não o alcança). Mesmo
  caminho: `legacy` na ingestão (com o `oute.task.id` do fato) e `apply_legacy` na subida, numa transação.
"""
import logging
from datetime import datetime, timezone

log = logging.getLogger("agent_studio")

NONE = "(sem)"
COL = "oute_repo"
JSON_PATH = "$.\"oute.task.repo\""
LEGACY_REPO = "oute-agent"
LEGACY_CUTOFF = datetime(2026, 10, 6, tzinfo=timezone.utc)  # 2026-10-06T00:00:00Z; o fato desta hora em diante fica fora
LEGACY_CUTOFF_NS = int(LEGACY_CUTOFF.timestamp()) * 10**9
LEGACY_TABLES = ("spans", "logs", "metrics")
# conversa da regressão dos agentes (#803): o `oute.task.id` de `docker/oute-regression` começa por `regression-`
REGRESSION_PREFIX = "regression-"
REGRESSION_LIKE = REGRESSION_PREFIX + "%"


def is_regression(task_id):
    """Fato da regressão dos agentes (#803): `oute.task.id` começando por `regression-`."""
    return isinstance(task_id, str) and task_id.startswith(REGRESSION_PREFIX)


def legacy(repo, time_ns, task_id=None):
    """Repositório da coluna na ingestão: sem repositório e com hora do fato antes do corte = `LEGACY_REPO` (#617); sem
    repositório e de conversa da regressão = `LEGACY_REPO` em qualquer hora (#803); o resto sai como entrou."""
    if repo is None and (time_ns < LEGACY_CUTOFF_NS or is_regression(task_id)):
        return LEGACY_REPO
    return repo


def apply_legacy(con):
    """Na subida (#617, #803): grava `LEGACY_REPO` nos fatos sem repositório de antes do corte e nos da regressão dos
    agentes (`oute.task.id` com `regression-`), numa transação só. Rodar de novo não acha linha. Falha = nada muda, um
    aviso no log (só o tipo do erro) e a subida segue. Devolve as linhas alteradas por tabela, ou `None` na falha."""
    rows = dict.fromkeys(LEGACY_TABLES, 0)
    try:
        con.execute("BEGIN TRANSACTION")
        try:
            for table in LEGACY_TABLES:
                n = con.execute(f"UPDATE {table} SET {COL} = ? WHERE {COL} IS NULL AND time_unix_nano < ?",
                                [LEGACY_REPO, LEGACY_CUTOFF_NS]).fetchone()
                m = con.execute(f"UPDATE {table} SET {COL} = ? WHERE {COL} IS NULL AND oute_task_id LIKE ?",
                                [LEGACY_REPO, REGRESSION_LIKE]).fetchone()
                rows[table] = (n[0] if n else 0) + (m[0] if m else 0)
            con.execute("COMMIT")
        except BaseException:
            con.execute("ROLLBACK")
            raise
    except Exception as e:  # noqa: BLE001 (o acerto do histórico nunca derruba a subida)
        log.warning("repo: acerto do histórico falhou (%s); o histórico de antes do corte segue sem repositório", type(e).__name__)
        return None
    if any(rows.values()):
        log.info("repo: histórico sem repositório de antes do corte gravado como %s, linhas: %s", LEGACY_REPO, rows)
    return rows


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
