"""`python -m agent_studio.replay <logs|traces|metrics>`: reenvia um objeto do bucket à ingestão (ADR-08 §7, #159).

Lê um `otlp_json.gz` (o objeto que o collector gravou no bucket; JSON puro também vale) do stdin e faz POST na
ingestão do próprio serviço, em 127.0.0.1, pelo mesmo caminho do collector: a dedupe é a da ingestão e o DuckDB
segue com um escritor só. Roda dentro do container do agent-studio (`docker exec -i`), que já tem a credencial de
ingestão no ambiente (`AGENT_STUDIO_INGEST_TOKEN`); ela nunca vem de argumento nem vai a log ou saída.

- Lote acima de 64 MB (o teto da ingestão) é partido por `resource*` (e, se um resource sozinho passa do teto, por
  `scope*`); parte que continua grande demais conta como falha.
- 503 = espera (`Retry-After`, senão 5 s) e repete, até `AGENT_STUDIO_REPLAY_TRIES` vezes (60); acabadas as
  tentativas, a parte falhou. 400 (ou qualquer outro 4xx) = conta, segue com as outras partes e sai ≠ 0.
- Reenviar já remonta o SurrealDB: a ingestão deriva o estado de todas as linhas do lote, inclusive das repetidas.
- Costuras para os testes (valor fora delas = o padrão): `AGENT_STUDIO_REPLAY_WAIT` (espera entre tentativas, 0 =
  sem esperar), `AGENT_STUDIO_REPLAY_TRIES` e `AGENT_STUDIO_REPLAY_MAX_BYTES` (teto da parte, nunca acima de 64 MB).
- Saída (stdout), uma linha: `written=<n> duplicate=<n> failed=<n>` (failed = partes que não entraram). O resto, o
  que for dito ao humano, vai ao stderr, sem nada que veio do objeto ou da resposta. Sai 0 só com `failed=0`;
  1 = alguma parte falhou; 2 = uso errado ou objeto que não é OTLP JSON.
"""
import gzip
import json
import os
import sys
import time
import urllib.error
import urllib.request
import zlib

from .app import MAX_BODY

SIGNALS = {"logs": "resourceLogs", "traces": "resourceSpans", "metrics": "resourceMetrics"}
SCOPES = {"logs": "scopeLogs", "traces": "scopeSpans", "metrics": "scopeMetrics"}
SCHEME = "http"  # loopback do próprio container: a ingestão não tem TLS (o nginx da tailnet é de outro caminho)
HOST = "127.0.0.1"
DEFAULT_WAIT = 5.0
MAX_WAIT = 60.0


class ReplayError(Exception):
    """O objeto não é replayable (não é OTLP JSON); o motivo vai ao stderr."""


def read_batch(raw):
    """bytes do stdin -> o dict do OTLP JSON; gzip ou JSON puro."""
    try:
        if raw[:2] == b"\x1f\x8b":
            d = zlib.decompressobj(16 + zlib.MAX_WBITS)
            raw = d.decompress(raw)
        batch = json.loads(raw)
    except (OSError, EOFError, zlib.error, ValueError) as e:  # gzip.BadGzipFile é OSError; JSON ruim é ValueError
        raise ReplayError(f"objeto ilegível ({type(e).__name__})") from None
    if not isinstance(batch, dict):
        raise ReplayError("objeto não é OTLP JSON")
    return batch


def _size(batch):
    return len(json.dumps(batch, separators=(",", ":"), ensure_ascii=False).encode())


def split(batch, signal, limit=MAX_BODY):
    """O lote em partes de no máximo `limit` bytes (JSON compacto), por `resource*`; um resource que sozinho passa do
    teto parte por `scope*`. Parte que não cabe nem assim sai mesmo (a ingestão responde 413 e ela conta como falha)."""
    key, scope = SIGNALS[signal], SCOPES[signal]
    rest = {k: v for k, v in batch.items() if k != key}
    resources = batch.get(key)
    if not isinstance(resources, list) or _size(batch) <= limit:
        return [batch]
    parts, cur, cur_size = [], [], 0
    base = _size({**rest, key: []})

    def flush():
        nonlocal cur, cur_size
        if cur:
            parts.append({**rest, key: cur})
            cur, cur_size = [], 0

    for res in resources:
        size = _size(res) + 1
        if base + size > limit:
            flush()
            parts.extend(_split_scopes(res, rest, key, scope, limit))
            continue
        if base + cur_size + size > limit:
            flush()
        cur.append(res)
        cur_size += size
    flush()
    return parts


def _split_scopes(res, rest, key, scope, limit):
    scopes = res.get(scope)
    head = {k: v for k, v in res.items() if k != scope}
    if not isinstance(scopes, list) or len(scopes) < 2:
        return [{**rest, key: [res]}]
    out, cur = [], []
    for sc in scopes:
        trial = [*cur, sc]
        if cur and _size({**rest, key: [{**head, scope: trial}]}) > limit:
            out.append({**rest, key: [{**head, scope: cur}]})
            cur = [sc]
        else:
            cur = trial
    if cur:
        out.append({**rest, key: [{**head, scope: cur}]})
    return out


def _url(signal):
    return f"{SCHEME}://{HOST}:{os.environ.get('AGENT_STUDIO_PORT', '8430')}/v1/{signal}"


def _token():
    return os.environ.get("AGENT_STUDIO_INGEST_TOKEN", "") or os.environ.get("AGENT_STUDIO_TOKEN", "")


def post(signal, batch, token, tries, wait_default):
    """POST de uma parte. -> (gravados, repetidos) ou None se falhou (o motivo já foi ao stderr)."""
    body = gzip.compress(json.dumps(batch, separators=(",", ":"), ensure_ascii=False).encode())
    for attempt in range(1, tries + 1):
        req = urllib.request.Request(_url(signal), data=body, method="POST", headers={
            "Authorization": f"Bearer {token}", "Content-Type": "application/json", "Content-Encoding": "gzip"})
        wait = None
        try:
            with urllib.request.urlopen(req, timeout=300) as r:
                return int(r.headers.get("X-Agent-Studio-Written", 0)), int(r.headers.get("X-Agent-Studio-Duplicate", 0))
        except urllib.error.HTTPError as e:
            if e.code != 503:
                print(f"replay: a ingestão recusou uma parte do lote (HTTP {e.code}); sigo com as outras", file=sys.stderr)
                return None
            try:
                wait = float(e.headers.get("Retry-After", ""))
            except ValueError:
                wait = wait_default
        except (OSError, ValueError) as e:  # serviço fora, conexão cortada
            print(f"replay: ingestão sem resposta ({type(e).__name__})", file=sys.stderr)
            wait = wait_default
        if attempt < tries:
            print(f"replay: ingestão indisponível; espero e repito ({attempt}/{tries})", file=sys.stderr)
            time.sleep(min(max(wait, 0), MAX_WAIT) if wait_default else 0)
    print(f"replay: ingestão indisponível depois de {tries} tentativas; a parte não entrou", file=sys.stderr)
    return None


def replay(signal, raw, token, tries=60, wait_default=DEFAULT_WAIT, limit=MAX_BODY):
    """-> (gravados, repetidos, partes que falharam)."""
    written = duplicate = failed = 0
    for part in split(read_batch(raw), signal, limit):
        got = post(signal, part, token, tries, wait_default)
        if got is None:
            failed += 1
        else:
            written += got[0]
            duplicate += got[1]
    return written, duplicate, failed


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1 or argv[0] not in SIGNALS:
        print("uso: python -m agent_studio.replay <logs|traces|metrics>  (objeto .json.gz no stdin)", file=sys.stderr)
        return 2
    token = _token()
    if not token:
        print("replay: AGENT_STUDIO_INGEST_TOKEN vazio no ambiente do serviço", file=sys.stderr)
        return 2
    try:
        written, duplicate, failed = replay(
            argv[0], sys.stdin.buffer.read(), token,
            tries=int(os.environ.get("AGENT_STUDIO_REPLAY_TRIES", "60")),
            wait_default=float(os.environ.get("AGENT_STUDIO_REPLAY_WAIT", DEFAULT_WAIT)),
            limit=min(int(os.environ.get("AGENT_STUDIO_REPLAY_MAX_BYTES", MAX_BODY)), MAX_BODY))
    except ReplayError as e:
        print(f"replay: {e}", file=sys.stderr)
        return 2
    print(f"written={written} duplicate={duplicate} failed={failed}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
