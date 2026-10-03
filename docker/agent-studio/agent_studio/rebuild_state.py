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
- Saída (stdout), três linhas: `antes: rodadas=<n> workers=<n> sessoes=<n> pedidos=<n> conversas=<n>`,
  `lidas: logs=<n> spans=<n>` e `depois: …` (a contagem do SurrealDB antes e depois). O stderr diz só o tipo do erro,
  nunca texto de linha do DuckDB nem de resposta do SurrealDB.
- Sai 0 se aplicou tudo; 1 se o DuckDB não abre ou o SurrealDB falha (o que já entrou fica: rodar de novo termina);
  2 se faltar a URL ou a senha do SurrealDB.
"""
import json
import os
import sys

import duckdb

from . import state
from .surreal import Surreal, SurrealError

TABLES = ("rodada", "worker", "sessao", "pedido", "conversa")
COUNT_NAMES = {"rodada": "rodadas", "worker": "workers", "sessao": "sessoes", "pedido": "pedidos",
               "conversa": "conversas"}
ORDER = "ORDER BY received_unix_nano, time_unix_nano, dedupe_key"
LOGS = ("SELECT time_unix_nano, host_name, oute_instance, oute_agent, service_name, session_id, oute_task_id, "
        f"event_name, oute_event_id, trace_id, attributes, resource_attributes FROM logs {ORDER}")
SPANS = f"SELECT host_name, oute_instance, oute_agent, service_name, session_id, oute_task_id FROM spans {ORDER}"


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
    """-> (linhas de logs, linhas de spans) lidas; levanta SurrealError se o SurrealDB recusar."""
    read = {"logs": 0, "spans": 0}
    for table in ("logs", "spans"):
        for block in rows(con, table, chunk):
            read[table] += len(block)
            surreal.apply(state.statements(table, block))
    return read["logs"], read["spans"]


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
        logs, spans = rebuild(con, surreal, chunk)
        print(f"lidas: logs={logs} spans={spans}")
        print(line("depois", counts(surreal)))
    except (SurrealError, duckdb.Error) as e:
        print(f"rebuild-state: falhou ({type(e).__name__}); o que já entrou fica, rode de novo", file=sys.stderr)
        return 1
    finally:
        con.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
