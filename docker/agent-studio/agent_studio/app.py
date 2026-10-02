"""API do agent-studio: recebe OTLP/HTTP JSON do collector e grava no DuckDB (ADR-08 §4 e §6), e serve a
consulta agregada de uso (`GET /v1/usage`, ADR-08 §9, #203), os alertas do pipeline (`GET /v1/alerts`, ADR-08 §8,
#204) e a tela (`web.py`, #206).

- `Authorization: Bearer <token>` (item `agent-studio` do vault); sem token ou com token errado = 401.
- 2xx só depois do commit. Qualquer falha na gravação = 503 (retentável): o collector guarda na fila em disco e
  reenvia, e a dedupe absorve a repetição.
- Corpo que não é OTLP JSON = 400 (permanente: reenviar não mudaria nada).
- Com SurrealDB: o estado derivado é gravado antes do COMMIT do DuckDB; SurrealDB fora = 503 e nada no DuckDB.
- `GET /v1/usage`: só leitura, mesmo token; janela inválida = 400; leitura que falha = 500.
- `GET /v1/alerts`: só leitura, mesmo token; `at` inválido = 400; leitura que falha = 500.
- Leitura (`GET /v1/usage`, `GET /v1/alerts` e as páginas) aceita o `Bearer` ou o cookie do login (#206); a
  ingestão, só o `Bearer`.
"""
import contextlib
import gzip
import json
import logging
import time
import zlib
from datetime import datetime, timezone

from fastapi import FastAPI, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import JSONResponse, PlainTextResponse

from . import auth as auth_mod, config as config_mod, otlp, state, telemetry, web

log = logging.getLogger("agent_studio")
detail = logging.getLogger("agent_studio_detail")

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


def create_app(store, token, surreal=None, tel=None, on_shutdown=None, config=None):
    auth = auth_mod.Auth(token)
    tel = tel or telemetry.Noop()
    config = config or config_mod.Config()

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
        return auth.bearer(request)

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
            # nada do que o cliente mandou vai ao log (injeção em log): só o sinal, que é nosso
            tel.warn("content-type", "recusado: %s com Content-Type que não é application/json", signal)
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
            tel.warn("bad-payload", "recusado: %s inválido (%s)", signal, type(e).__name__)
            return JSONResponse({"message": "OTLP JSON inválido"}, status_code=400)
        # estado derivado no SurrealDB dentro da transação do DuckDB: os dois bancos juntos ou nenhum (#187)
        stmts = state.statements(table, rows) if surreal else []
        before_commit = (lambda: surreal.apply(stmts)) if stmts else None
        t0 = time.monotonic()
        try:
            written = await run_in_threadpool(store.write, {table: rows}, before_commit)
        except Exception as e:  # noqa: BLE001 — qualquer falha na gravação é retentável
            tel.written(signal, 0, 0, time.monotonic() - t0, ok=False)
            tel.warn("write-failed", "gravação falhou, respondi 503 (%s, %d registros): %s", signal, len(rows),
                     type(e).__name__, level=logging.ERROR)
            # a causa (DuckDB, SurrealDB) só no stderr: logger fora da árvore agent_studio, sem o handler OTel
            detail.exception("gravação falhou (%s)", signal)
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

    # ------------------------------------------------ consulta agregada de uso (#203)
    @app.get("/v1/usage")
    async def v1_usage(request: Request):
        """Uso por host × agente × modelo, com janela e série diária (ADR-08 §9, contrato na seção #203)."""
        if not auth.reader(request):
            tel.warn("unauthorized", "recusado: token ausente ou errado (usage)")
            return JSONResponse({"message": "unauthorized"}, status_code=401)
        try:
            from_ns, to_ns = _window(request.query_params)
        except ValueError as e:
            return JSONResponse({"message": str(e)}, status_code=400)
        try:
            result = await run_in_threadpool(store.usage, from_ns, to_ns, config.prices)
        except Exception as e:  # noqa: BLE001 — leitura que falhou: 500, a causa só no stderr
            tel.warn("usage-failed", "consulta de uso falhou, respondi 500: %s", type(e).__name__, level=logging.ERROR)
            detail.exception("consulta de uso falhou")
            return JSONResponse({"message": "consulta falhou"}, status_code=500)
        return JSONResponse({
            "from": _iso(from_ns), "to": _iso(to_ns), "time": "hora do fato (UTC)",
            "prices": {"models": len(config.prices), "errors": config.errors},
            **result,
        })

    # ------------------------------------------------ alertas do pipeline (#204)
    @app.get("/v1/alerts")
    async def v1_alerts(request: Request):
        """Alertas ativos e último dado de cada host (ADR-08 §8, contrato na seção #204)."""
        if not auth.reader(request):
            tel.warn("unauthorized", "recusado: token ausente ou errado (alerts)")
            return JSONResponse({"message": "unauthorized"}, status_code=401)
        try:
            at_ns = _parse_time(request.query_params["at"], "at") if "at" in request.query_params else time.time_ns()
        except ValueError as e:
            return JSONResponse({"message": str(e)}, status_code=400)
        try:
            result = await run_in_threadpool(store.alerts, at_ns, config.alerts)
        except Exception as e:  # noqa: BLE001 — leitura que falhou: 500, a causa só no stderr
            tel.warn("alerts-failed", "consulta de alertas falhou, respondi 500: %s", type(e).__name__,
                     level=logging.ERROR)
            detail.exception("consulta de alertas falhou")
            return JSONResponse({"message": "consulta falhou"}, status_code=500)
        return JSONResponse({"at": _iso(at_ns), "time": "hora do fato (UTC)", **result,
                             "config": {"errors": config.errors}})

    # ------------------------------------------------ tela: login e conversas (#206)
    web.mount(app, store, auth, config, tel, _window)

    return app


MAX_HOURS = 24 * 366


def _parse_time(value, name):
    """ISO 8601 (`2026-09-29`, `2026-09-29T12:00:00Z`, com offset); sem fuso = UTC. -> ns desde a época."""
    try:
        dt = datetime.fromisoformat(value.strip())
    except (ValueError, AttributeError):
        raise ValueError(f"{name} inválido: use ISO 8601 (ex.: 2026-09-29T00:00:00Z)") from None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    ns = int(dt.timestamp()) * 1_000_000_000 + dt.microsecond * 1000
    if not 0 <= ns < 2**63:
        # a hora do fato é UBIGINT em ns: antes de 1970 ou além de 2262 não existe no banco
        raise ValueError(f"{name} fora do intervalo (1970 a 2262)")
    return ns


def _window(args):
    """Janela [from, to): `from` e `to` juntos, ou `hours` (padrão 24) até agora. ValueError = 400."""
    if "from" in args or "to" in args:
        if "hours" in args:
            raise ValueError("use from/to ou hours, não os dois")
        if "from" not in args or "to" not in args:
            raise ValueError("from e to vão juntos")
        from_ns, to_ns = _parse_time(args["from"], "from"), _parse_time(args["to"], "to")
        if from_ns >= to_ns:
            raise ValueError("from precisa ser antes de to")
        return from_ns, to_ns
    try:
        hours = float(args.get("hours", "24"))
    except ValueError:
        raise ValueError("hours inválido") from None
    if not 0 < hours <= MAX_HOURS:
        raise ValueError(f"hours precisa estar entre 0 e {MAX_HOURS}")
    to_ns = time.time_ns()
    return to_ns - int(hours * 3_600_000_000_000), to_ns


def _iso(ns):
    return datetime.fromtimestamp(ns // 1_000_000_000, timezone.utc).isoformat().replace("+00:00", "Z")
