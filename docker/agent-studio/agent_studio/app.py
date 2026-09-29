"""API do agent-studio: recebe OTLP/HTTP JSON do collector e grava no DuckDB (ADR-08 §4 e §6).

- `Authorization: Bearer <token>` (item `agent-studio` do vault); sem token ou com token errado = 401.
- 2xx só depois do commit. Qualquer falha na gravação = 503 (retentável): o collector guarda na fila em disco e
  reenvia, e a dedupe absorve a repetição.
- Corpo que não é OTLP JSON = 400 (permanente: reenviar não mudaria nada).
- Com SurrealDB: o estado derivado é gravado antes do COMMIT do DuckDB; SurrealDB fora = 503 e nada no DuckDB.
"""
import contextlib
import gzip
import hmac
import json
import logging
import time
import zlib

from fastapi import FastAPI, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import JSONResponse, PlainTextResponse

from . import otlp, state, telemetry

log = logging.getLogger("agent_studio")

MAX_BODY = 64 * 1024 * 1024  # depois de descomprimir; lote do collector fica muito abaixo disso

# sinal -> (função que monta as linhas, tabela)
SIGNALS = {
    "logs": (otlp.log_rows, "logs"),
    "traces": (otlp.span_rows, "spans"),
    "metrics": (otlp.metric_rows, "metrics"),
}


def _decompress(body, encoding):
    encoding = (encoding or "").strip().lower()
    if encoding in ("", "identity"):
        out = body
    elif encoding == "gzip":
        d = zlib.decompressobj(16 + zlib.MAX_WBITS)
        out = d.decompress(body, MAX_BODY + 1)
    elif encoding == "deflate":
        d = zlib.decompressobj()
        out = d.decompress(body, MAX_BODY + 1)
    else:
        raise otlp.BadPayload(f"Content-Encoding não suportado: {encoding}")
    if len(out) > MAX_BODY:
        raise OverflowError
    return out


def create_app(store, token, surreal=None, tel=None, on_shutdown=None):
    if not token:
        raise ValueError("token vazio")
    expected = f"Bearer {token}".encode()
    tel = tel or telemetry.Noop()

    # na parada: o uvicorn reenvia o SIGTERM a si mesmo depois de parar, então o que vem depois do uvicorn.run não
    # roda; exportar o resto da telemetria e fechar o DuckDB fica aqui
    @contextlib.asynccontextmanager
    async def lifespan(_app):
        yield
        tel.shutdown()
        if on_shutdown:
            on_shutdown()

    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan)

    def authorized(request):
        got = request.headers.get("authorization", "").encode()
        return hmac.compare_digest(got, expected)

    async def ingest(signal, request):
        resp = await _ingest(signal, request)
        tel.request(signal, resp.status_code)
        return resp

    async def _ingest(signal, request):
        if not authorized(request):
            tel.warn("unauthorized", "recusado: token ausente ou errado (%s)", signal)
            return JSONResponse({"message": "unauthorized"}, status_code=401)
        ctype = request.headers.get("content-type", "").split(";")[0].strip().lower()
        if ctype != "application/json":
            tel.warn("content-type", "recusado: %s com Content-Type %s (só OTLP/HTTP JSON)", signal, ctype or "vazio")
            return JSONResponse({"message": "só OTLP/HTTP JSON (application/json)"}, status_code=415)
        received_ns = time.time_ns()
        try:
            raw = _decompress(await request.body(), request.headers.get("content-encoding"))
            payload = json.loads(raw)
            build, table = SIGNALS[signal]
            rows = build(payload, received_ns)
        except OverflowError:
            tel.warn("too-large", "recusado: %s com corpo acima de %d bytes", signal, MAX_BODY)
            return JSONResponse({"message": "corpo grande demais"}, status_code=413)
        except (otlp.BadPayload, ValueError, zlib.error, gzip.BadGzipFile, AttributeError, TypeError) as e:
            tel.warn("bad-payload", "recusado: %s inválido (%s)", signal, e)
            return JSONResponse({"message": f"OTLP JSON inválido: {e}"}, status_code=400)
        # estado derivado no SurrealDB dentro da transação do DuckDB: os dois bancos juntos ou nenhum (#187)
        stmts = state.statements(table, rows) if surreal else []
        before_commit = (lambda: surreal.apply(stmts)) if stmts else None
        t0 = time.monotonic()
        try:
            written = await run_in_threadpool(store.write, {table: rows}, before_commit)
        except Exception as e:  # noqa: BLE001 — qualquer falha na gravação é retentável
            tel.written(signal, 0, 0, time.monotonic() - t0, ok=False)
            tel.warn("write-failed", "gravação falhou, respondi 503 (%s, %d registros): %s", signal, len(rows), e,
                     level=logging.ERROR)
            return JSONResponse({"message": "gravação falhou; reenvie"}, status_code=503, headers={"Retry-After": "5"})
        n, dup = written[table]
        tel.written(signal, n, dup, time.monotonic() - t0, ok=True)
        # só no stderr (INFO não sai como log OTel: seria um registro novo por requisição, em laço)
        log.info("%s: %d gravados, %d repetidos", signal, n, dup)
        return JSONResponse({})

    @app.post("/v1/logs")
    async def v1_logs(request: Request):
        return await ingest("logs", request)

    @app.post("/v1/traces")
    async def v1_traces(request: Request):
        return await ingest("traces", request)

    @app.post("/v1/metrics")
    async def v1_metrics(request: Request):
        return await ingest("metrics", request)

    @app.get("/healthz")
    async def healthz():
        return PlainTextResponse("ok")

    return app
