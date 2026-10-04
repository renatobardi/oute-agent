"""API do agent-studio: recebe OTLP/HTTP JSON do collector e grava no DuckDB (ADR-08 §4 e §6), e serve a
consulta agregada de uso (`GET /v1/usage`, ADR-08 §9, #203), os alertas do pipeline (`GET /v1/alerts`, ADR-08 §8,
#204), o endpoint do tray (`GET /v1/tray`, ADR-08 §10, #205) e a tela (`web.py`, #206, #207 e #208).

- Duas credenciais (`auth.py`, #256): a ingestão (`POST /v1/*`) aceita só o `Bearer` da credencial de ingestão
  (sem ela ou errada = 401; com a de leitura = 403); a leitura aceita só a de leitura.
- 2xx só depois do commit. Qualquer falha na gravação = 503 (retentável): o collector guarda na fila em disco e
  reenvia, e a dedupe absorve a repetição.
- Corpo que não é OTLP JSON = 400 (permanente: reenviar não mudaria nada).
- Com SurrealDB: o estado derivado é gravado antes do COMMIT do DuckDB; SurrealDB fora = 503 e nada no DuckDB.
- `GET /v1/usage`: só leitura, credencial de leitura; janela inválida = 400; leitura que falha = 500.
- `GET /v1/alerts`: só leitura, credencial de leitura; `at` inválido = 400; leitura que falha = 500.
- `GET /v1/prices`: só leitura, credencial de leitura; preço vigente e histórico por modelo (#339); leitura que falha = 500.
- `GET /v1/rodada?id=`: só leitura, credencial de leitura; as etapas publicadas da rodada (#507); sem id = 400, rodada desconhecida =
  404, DuckDB que falha = 500; SurrealDB fora = 200 com `state_read` = `false` (as etapas saem do DuckDB).
- `GET /v1/tray`: só leitura, credencial de leitura; leitura do DuckDB que falha = 500; SurrealDB fora = 200 com
  `proposals.available` = `false` (o resto do menu segue).
- Leitura (`GET /v1/usage`, `GET /v1/alerts`, `GET /v1/tray` e as páginas) aceita o `Bearer` ou o cookie do login
  (#206); a ingestão, só o `Bearer`.
"""
import asyncio
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

from . import (auth as auth_mod, config as config_mod, etapas as etapas_mod, otlp, prices as prices_mod, state, telemetry, tray as tray_mod,
               tz as tz_mod, web)

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


def create_app(store, token, surreal=None, tel=None, on_shutdown=None, config=None, read_token=None, price_job=None):
    """`token` = credencial de ingestão; `read_token` = a de leitura (sem ela, uma só para tudo: transição da #256)."""
    auth = auth_mod.Auth(token, read_token)
    tel = tel or telemetry.Noop()
    config = config or config_mod.Config()

    # na parada: o uvicorn reenvia o SIGTERM a si mesmo depois de parar, então o que vem depois do uvicorn.run não
    # roda; exportar o resto da telemetria e fechar o DuckDB fica aqui
    @contextlib.asynccontextmanager
    async def lifespan(_app):
        if price_job:
            price_job.start()  # a conferência de preços (#339) em segundo plano; falha dela nunca chega aqui
        yield
        if price_job:
            price_job.stop()
        tel.shutdown()
        if on_shutdown:
            on_shutdown()

    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan)

    async def ingest(signal, request):
        resp = await _ingest(signal, request)
        tel.request(signal, resp.status_code)
        return resp

    async def _ingest(signal, request):
        if not auth.ingest(request):
            if auth.split and auth.bearer(request):
                # credencial de leitura na ingestão (#256): quem lê não escreve
                tel.warn("forbidden", "recusado: credencial de leitura na ingestão (%s)", signal)
                return JSONResponse({"message": "forbidden"}, status_code=403)
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
        # quantos entraram e quantos já estavam: o `replay` (#159) soma isso; o collector ignora
        return JSONResponse({}, headers={"X-Agent-Studio-Written": str(n), "X-Agent-Studio-Duplicate": str(dup)})

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
            zone = _zone(request.query_params, config)
        except ValueError as e:
            return JSONResponse({"message": str(e)}, status_code=400)
        try:
            result = await run_in_threadpool(store.usage, from_ns, to_ns, config.prices, zone)
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

    # ------------------------------------------------ preços: vigente e histórico (#339)
    @app.get("/v1/prices")
    async def v1_prices(request: Request):
        """Preço vigente e histórico de cada modelo, com origem e vigência, e a última conferência de cada fonte."""
        if not auth.reader(request):
            tel.warn("unauthorized", "recusado: token ausente ou errado (prices)")
            return JSONResponse({"message": "unauthorized"}, status_code=401)
        at_ns = time.time_ns()
        try:
            result = await run_in_threadpool(store.read, lambda con: prices_mod.view(con, config.fixed, at_ns))
        except Exception as e:  # leitura que falhou: 500, a causa só no stderr
            tel.warn("prices-failed", "consulta de preços falhou, respondi 500: %s", type(e).__name__,
                     level=logging.ERROR)
            detail.exception("consulta de preços falhou")
            return JSONResponse({"message": "consulta falhou"}, status_code=500)
        return JSONResponse({**result, "config": {"errors": config.errors}})

    # ------------------------------------------------ endpoint do tray (#205)
    def _tray_pending(at_ns):
        """Pedidos pendentes do SurrealDB; `None` sem ele ou se a leitura falha (a causa só no stderr): o tray
        segue com o resto do menu e sem o número de pedidos."""
        if surreal is None:
            return None
        try:
            return tray_mod.pending(surreal, at_ns)
        except Exception as e:  # noqa: BLE001 — o estado dos pedidos não derruba o menu inteiro
            tel.warn("tray-state-failed", "tray: pedidos pendentes (SurrealDB) falhou, respondi sem eles: %s",
                     type(e).__name__, level=logging.ERROR)
            detail.exception("tray: pedidos pendentes falhou")
            return None

    @app.get("/v1/tray")
    async def v1_tray(request: Request):
        """Tudo o que o menu do tray mostra, numa chamada (ADR-08 §10, contrato na seção #205)."""
        if not auth.reader(request):
            tel.warn("unauthorized", "recusado: token ausente ou errado (tray)")
            return JSONResponse({"message": "unauthorized"}, status_code=401)
        try:
            zone = _zone(request.query_params, config)
        except ValueError as e:
            return JSONResponse({"message": str(e)}, status_code=400)
        at_ns = time.time_ns()
        try:
            # os dois bancos ao mesmo tempo: o SurrealDB lento não soma ao tempo do DuckDB
            snap, pending = await asyncio.gather(
                run_in_threadpool(store.tray, at_ns, config.prices, config.alerts, zone),
                run_in_threadpool(_tray_pending, at_ns))
        except Exception as e:  # noqa: BLE001 — leitura que falhou: 500, a causa só no stderr
            tel.warn("tray-failed", "consulta do tray falhou, respondi 500: %s", type(e).__name__, level=logging.ERROR)
            detail.exception("consulta do tray falhou")
            return JSONResponse({"message": "consulta falhou"}, status_code=500)
        return JSONResponse(tray_mod.response(at_ns, snap, pending, config.errors, zone))

    # ------------------------------------------------ a rodada em JSON (#507)
    @app.get("/v1/rodada")
    async def v1_rodada(request: Request):
        """As etapas publicadas da rodada (ADR-08, "Página da rodada e do ciclo"); só leitura, credencial de leitura."""
        if not auth.reader(request):
            tel.warn("unauthorized", "recusado: token ausente ou errado (rodada)")
            return JSONResponse({"message": "unauthorized"}, status_code=401)
        rnd = request.query_params.get("id", "")
        if not rnd:
            return JSONResponse({"message": "falta o id da rodada"}, status_code=400)
        try:
            data = await run_in_threadpool(etapas_mod.load, store, surreal, rnd)
        except Exception as e:  # noqa: BLE001 — leitura que falhou: 500, a causa só no stderr
            tel.warn("rodada-failed", "consulta da rodada falhou, respondi 500: %s", type(e).__name__, level=logging.ERROR)
            detail.exception("consulta da rodada falhou")
            return JSONResponse({"message": "consulta falhou"}, status_code=500)
        if data is None:
            return JSONResponse({"message": "rodada não encontrada"}, status_code=404)
        if data["state_error"]:
            tel.warn("rodada-state-failed", "rodada: estado (SurrealDB) falhou, respondi só com o DuckDB: %s",
                     data["state_error"], level=logging.ERROR)
        return JSONResponse(etapas_mod.api(data))

    # ------------------------------------------------ tela: login e conversas (#206), sessões (#207), pedidos e
    # alertas (#208)
    web.mount(app, store, auth, config, tel, _window, surreal)

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


def _zone(args, config):
    """Fuso dos dias: `tz=<IANA>` da consulta ou o do config (`timezone`). ValueError = 400."""
    if "tz" not in args:
        return config.tz
    try:
        return tz_mod.parse(args["tz"])
    except ValueError:
        raise ValueError("tz inválido: use um nome IANA (ex.: America/Sao_Paulo)") from None


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
