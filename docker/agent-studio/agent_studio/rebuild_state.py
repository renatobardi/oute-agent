"""`python -m agent_studio.rebuild_state`: remonta o estado do SurrealDB a partir do DuckDB (ADR-08 §7, #345).

Roda como one-off do host (`oute studio rebuild-state`), com o serviço parado: o DuckDB aceita um escritor só e aqui
ele abre só para leitura, então o serviço não pode estar de pé segurando o arquivo. Lê `logs` e `spans` na ordem em
que chegaram (`received_unix_nano`, `time_unix_nano`, `dedupe_key`), em blocos, e aplica o `state.statements` de cada
bloco ao SurrealDB, o mesmo código e o mesmo `UPSERT … MERGE` da ingestão; por isso o estado sai igual ao que ela
gerou. Só acrescenta e atualiza: não apaga nada do SurrealDB (volume perdido = banco vazio; é o caso de uso).
Idempotente: rodar de novo não muda o resultado.

- Ambiente (o do serviço no compose): `AGENT_STUDIO_DB`, `AGENT_STUDIO_SURREAL_URL`, `AGENT_STUDIO_SURREAL_PASS`
  (e, se fugirem do padrão, `AGENT_STUDIO_SURREAL_USER|NS|DB`). Costura para os testes: `AGENT_STUDIO_REBUILD_CHUNK`
  (linhas por bloco, padrão 2000).
- Saída (stdout), cinco linhas; as três primeiras: `antes: rodadas=<n> workers=<n> sessoes=<n> pedidos=<n> conversas=<n> etapas=<n> acoes=<n>`,
  `lidas: logs=<n> spans=<n> marcas=<n>` (marcas = linhas da `action_marks`, #510) e `depois: …` (a contagem do SurrealDB antes e depois).
  Mais uma quarta linha, a do ack (#537): `vistos: marcas=<n> antes=<n> depois=<n>` (linhas da `ack_marks` lidas e os registros do
  `ack` no SurrealDB antes e depois), uma quinta, a dos planos (#746): `planos: linhas=<n> antes=<n> depois=<n>` (linhas da `plan_history` lidas e os registros do
  `plano` no SurrealDB antes e depois), e uma sexta, a da fase (#749): `fases: conversas=<n>` (a classificação refeita em memória e
  gravada no `conversa`). O stderr diz só o tipo do erro, nunca texto de linha do DuckDB nem de resposta do SurrealDB.
- Sai 0 se aplicou tudo; 1 se o DuckDB não abre ou o SurrealDB falha (o que já entrou fica: rodar de novo termina);
  2 se faltar a URL ou a senha do SurrealDB.
"""
import json
import os
import sys

import duckdb

from . import acks, marks, phase, planos, state
from .surreal import Surreal, SurrealError

TABLES = ("rodada", "worker", "sessao", "pedido", "conversa", "etapa", "acao")
COUNT_NAMES = {"rodada": "rodadas", "worker": "workers", "sessao": "sessoes", "pedido": "pedidos",
               "conversa": "conversas", "etapa": "etapas", "acao": "acoes"}
ORDER = "ORDER BY received_unix_nano, time_unix_nano, dedupe_key"
LOGS = ("SELECT time_unix_nano, host_name, oute_instance, oute_agent, oute_subscription, service_name, session_id, oute_task_id, "
        f"event_name, oute_event_id, trace_id, attributes, resource_attributes FROM logs {ORDER}")
SPANS = f"SELECT host_name, oute_instance, oute_agent, oute_subscription, service_name, session_id, oute_task_id FROM spans {ORDER}"


def _json(v):
    return v if isinstance(v, dict) else (json.loads(v) if isinstance(v, str) else {})


def rows(con, table, chunk):
    """Linhas da tabela como `state.statements` as espera (a ingestão: colunas fixas + `_attrs` e `_res` nos logs)."""
    cur = con.execute(LOGS if table == "logs" else SPANS)
    names = [d[0] for d in cur.description]
    while True:
        block = cur.fetchmany(chunk)
        if not block:
            return
        out = []
        for values in block:
            r = dict(zip(names, values))
            if table == "logs":
                r["_attrs"], r["_res"] = _json(r.pop("attributes")), _json(r.pop("resource_attributes"))
            out.append(r)
        yield out


def counts(surreal):
    # SurrealDB 3: SELECT numa tabela que ainda não existe (banco vazio) é erro, não lista vazia
    existing = (surreal.query("INFO FOR DB")[0].get("result") or {}).get("tables") or {}
    out = {}
    for t in TABLES:
        if t not in existing:
            out[t] = 0
            continue
        res = surreal.query(f"SELECT count() FROM {t} GROUP ALL")[0].get("result") or []
        out[t] = int(res[0]["count"]) if res else 0
    return out


def line(label, c):
    return f"{label}: " + " ".join(f"{COUNT_NAMES[t]}={c[t]}" for t in TABLES)


def rebuild(con, surreal, chunk=2000):
    """-> (linhas de logs, de spans e de marcas) lidas; levanta SurrealError se o SurrealDB recusar. As marcas (`action_marks`,
    #510) são a fonte do `acao`, depois de `logs` e `spans`: o replay do bucket não as traz."""
    read = {"logs": 0, "spans": 0}
    for table in ("logs", "spans"):
        for block in rows(con, table, chunk):
            read[table] += len(block)
            surreal.apply(state.statements(table, block))
    marked = 0
    for block in marks.rows(con, chunk):
        marked += len(block)
        surreal.apply([s for row in block for s in state.mark_statements(row)])
    return read["logs"], read["spans"], marked


def rebuild_phases(con, surreal):
    """-> conversas classificadas (#749). Refaz a classificação inteira, em memória, pelo mesmo `phase.compute` do serviço (a fonte
    é o DuckDB: telemetria, `phase_jev` e `phase_marks`; o DuckDB aqui é só leitura) e grava a fase, a origem e a confiança no
    `conversa`. Banco anterior à #749 (sem as tabelas): nada."""
    if not phase.has_tables(con):
        return 0
    result = phase.compute(con)
    surreal.apply([s for conv, r in result.items()
                   for s in state.phase_statements(conv, r["phase"], r["origin"], r["confidence"])])
    return len(result)


def count_acks(surreal):
    """Registros do `ack` no SurrealDB (0 sem a tabela)."""
    existing = (surreal.query("INFO FOR DB")[0].get("result") or {}).get("tables") or {}
    if "ack" not in existing:
        return 0
    res = surreal.query("SELECT count() FROM ack GROUP ALL")[0].get("result") or []
    return int(res[0]["count"]) if res else 0


def rebuild_acks(con, surreal, chunk=2000):
    """-> linhas da `ack_marks` lidas (#537). A fonte do `ack`: o replay do bucket não as traz. O prazo de cada marca vem da
    linha: remontar não renova ack nenhum."""
    read = 0
    for block in acks.rows(con, chunk):
        read += len(block)
        surreal.apply([s for row in block for s in state.ack_statements(row)])
    return read


def count_plans(surreal):
    """Registros do `plano` no SurrealDB (0 sem a tabela)."""
    existing = (surreal.query("INFO FOR DB")[0].get("result") or {}).get("tables") or {}
    if "plano" not in existing:
        return 0
    res = surreal.query("SELECT count() FROM plano GROUP ALL")[0].get("result") or []
    return int(res[0]["count"]) if res else 0


def rebuild_plans(con, surreal, chunk=2000):
    """-> linhas da `plan_history` lidas (#746). A fonte do `plano`: o replay do bucket não as traz."""
    read = 0
    for block in planos.rows(con, chunk):
        read += len(block)
        surreal.apply([s for row in block for s in state.plan_statements(row)])
    return read


def main():
    url = os.environ.get("AGENT_STUDIO_SURREAL_URL", "")
    password = os.environ.get("AGENT_STUDIO_SURREAL_PASS", "")
    if not url or not password:
        print("rebuild-state: AGENT_STUDIO_SURREAL_URL e AGENT_STUDIO_SURREAL_PASS vazios no ambiente do serviço",
              file=sys.stderr)
        return 2
    surreal = Surreal(url, os.environ.get("AGENT_STUDIO_SURREAL_USER", "root"), password,
                      ns=os.environ.get("AGENT_STUDIO_SURREAL_NS", "oute"),
                      db=os.environ.get("AGENT_STUDIO_SURREAL_DB", "studio"), timeout=120.0)
    path = os.environ.get("AGENT_STUDIO_DB", "/data/agent-studio/agent-studio.duckdb")
    try:
        chunk = max(1, int(os.environ.get("AGENT_STUDIO_REBUILD_CHUNK", "2000")))
        con = duckdb.connect(path, read_only=True)
    except (duckdb.Error, ValueError) as e:
        print(f"rebuild-state: não abri o DuckDB ({type(e).__name__}); o serviço está parado?", file=sys.stderr)
        return 1
    try:
        con.execute("SET TimeZone = 'UTC'")
        print(line("antes", counts(surreal)))
        acks_before = count_acks(surreal)
        plans_before = count_plans(surreal)
        logs, spans, marked = rebuild(con, surreal, chunk)
        acked = rebuild_acks(con, surreal, chunk)
        planned = rebuild_plans(con, surreal, chunk)
        phased = rebuild_phases(con, surreal)
        print(f"lidas: logs={logs} spans={spans} marcas={marked}")
        print(line("depois", counts(surreal)))
        print(f"vistos: marcas={acked} antes={acks_before} depois={count_acks(surreal)}")
        print(f"planos: linhas={planned} antes={plans_before} depois={count_plans(surreal)}")
        print(f"fases: conversas={phased}")
    except (SurrealError, duckdb.Error) as e:
        print(f"rebuild-state: falhou ({type(e).__name__}); o que já entrou fica, rode de novo", file=sys.stderr)
        return 1
    finally:
        con.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
