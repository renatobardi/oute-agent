"""`python -m agent_studio.backup`: pede ao agent-studio uma cópia de segurança do DuckDB (#570) e imprime a resposta
(nome, tamanho, tempo e linhas, em JSON). Roda dentro do serviço (`docker exec`), fala com `127.0.0.1` e usa a credencial
de ingestão do ambiente (`AGENT_STUDIO_INGEST_TOKEN`); ela nunca vem de argumento nem vai a log ou saída. O
`oute studio backup` chama este módulo e leva o arquivo ao bucket.

`--check`: lê uma cópia no stdin, grava num arquivo temporário, abre só para leitura e imprime as linhas por tabela. Não
toca no banco vivo. O conteúdo do arquivo nunca vai à saída.

Saída: 0 ok; 1 falhou; 2 sem credencial; 3 já há uma cópia em andamento.
"""
import json
import os
import sys
import tempfile
import urllib.error
import urllib.request

TIMEOUT_S = 3600  # a cópia cresce com o banco, que não tem retenção


def _token():
    return os.environ.get("AGENT_STUDIO_INGEST_TOKEN", "") or os.environ.get("AGENT_STUDIO_TOKEN", "")


def request_backup(token):
    url = f"http://127.0.0.1:{os.environ.get('AGENT_STUDIO_PORT', '8430')}/v1/backup"
    req = urllib.request.Request(url, data=b"", method="POST", headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=float(os.environ.get("AGENT_STUDIO_BACKUP_TIMEOUT", TIMEOUT_S))) as r:
            print(json.dumps(json.load(r)))
            return 0
    except urllib.error.HTTPError as e:
        if e.code == 409:
            print("backup: já há uma cópia em andamento", file=sys.stderr)
            return 3
        print(f"backup: o agent-studio respondeu HTTP {e.code}", file=sys.stderr)
    except (OSError, ValueError) as e:
        print(f"backup: agent-studio sem resposta ({type(e).__name__})", file=sys.stderr)
    return 1


def check():
    import duckdb

    from .store import TABLES
    fd, path = tempfile.mkstemp(prefix="agent-studio-check-", suffix=".duckdb")
    try:
        size = 0
        with os.fdopen(fd, "wb") as out:
            while chunk := sys.stdin.buffer.read(1 << 20):
                out.write(chunk)
                size += len(chunk)
        if not size:
            print("backup: a cópia veio vazia", file=sys.stderr)
            return 1
        try:
            con = duckdb.connect(path, read_only=True)
            try:
                rows = {t: con.execute(f"SELECT count(*) FROM {t}").fetchone()[0] for t in TABLES}
            finally:
                con.close()
        except Exception as e:  # noqa: BLE001 — só o tipo: a mensagem do DuckDB pode citar o conteúdo
            print(f"backup: a cópia não abre como banco do agent-studio ({type(e).__name__})", file=sys.stderr)
            return 1
        print(json.dumps({"bytes": size, "rows": rows}))
        return 0
    finally:
        for leftover in (path, path + ".wal"):
            if os.path.exists(leftover):
                os.remove(leftover)


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv == ["--check"]:
        return check()
    if argv:
        print("uso: python -m agent_studio.backup [--check < cópia.duckdb]", file=sys.stderr)
        return 2
    token = _token()
    if not token:
        print("backup: AGENT_STUDIO_INGEST_TOKEN vazio no ambiente do serviço", file=sys.stderr)
        return 2
    return request_backup(token)


if __name__ == "__main__":
    sys.exit(main())
