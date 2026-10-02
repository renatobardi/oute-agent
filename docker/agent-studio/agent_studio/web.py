"""Tela do agent-studio (ADR-08 §9): login por token que vira cookie, lista de conversas e detalhe (#206), as
sessões do `oute-task` com as conversas de cada uma (#207), os pedidos do canal de aprovação e os alertas do
pipeline no topo das páginas (#208).

HTML gerado no servidor (Jinja2, sempre com autoescape) + htmx servido daqui mesmo (`/static`): sem SPA, sem build
de front-end e sem CDN. Só leitura.

- Sem cookie nem `Bearer`: página redireciona para o `/login` (303); pedido do htmx recebe 401 com `HX-Redirect`.
- `POST /login` com o token errado = 401; certo = cookie (`auth.py`) e volta para onde ia. `POST /logout` apaga.
- O conteúdo das conversas (prompts, saídas de tool) é dado não confiável: autoescape em tudo e uma CSP que só
  aceita script e estilo deste servidor.
- Sessões: os fatos vêm do DuckDB e o estado da sessão (repo, estado, rodada) do SurrealDB. SurrealDB fora não
  derruba a página: ela sai só com o DuckDB e um aviso.
- Pedidos: o estado vem do SurrealDB e o script do DuckDB (`proposals.py`). O script é dado não confiável, sempre
  escapado. Nenhuma ação: aprovar e recusar continuam no `oute approve` (ADR-01); aqui não há botão nem rota
  para isso.
- Alertas: os do `alerts.evaluate` (#204), calculados a cada página; aqui só o texto de cada um.
"""
import logging
import os
import time
from datetime import datetime, timezone
from urllib.parse import parse_qs, quote

import jinja2
from fastapi import Request
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import HTMLResponse, RedirectResponse
from starlette.staticfiles import StaticFiles

from . import alerts as alerts_mod, conversations as conv_mod, proposals as prop_mod, sessions as sess_mod

detail_log = logging.getLogger("agent_studio_detail")

HERE = os.path.dirname(os.path.abspath(__file__))
HOME = "/conversas"
MAX_LOGIN_BODY = 4096
# janelas oferecidas na lista (horas -> rótulo); a URL aceita também from/to, como o /v1/usage
WINDOWS = (("24", "24 horas"), ("168", "7 dias"), ("720", "30 dias"), ("8784", "366 dias"))
HEADERS = {
    "Content-Security-Policy": "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; "
                               "connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "same-origin",
    "Cache-Control": "no-store",
}


# ------------------------------------------------ formatação (filtros dos templates)
def _ts(ns):
    if ns is None:
        return "—"
    return datetime.fromtimestamp(ns // 1_000_000_000, timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


def _br(text):
    # 1,234.5 -> 1.234,5
    return text.translate(str.maketrans(",.", ".,"))


def _dur(ns):
    if ns is None:
        return "—"
    s = ns / 1e9
    if s < 1:
        return f"{_br(f'{s * 1000:.0f}')} ms"
    if s < 60:
        return f"{_br(f'{s:.1f}')} s"
    m, s = divmod(int(s), 60)
    h, m = divmod(m, 60)
    return f"{h} h {m:02d} min" if h else f"{m} min {s:02d} s"


def _ms(ms):
    return _dur(None if ms is None else int(ms * 1e6))


def _when(iso):
    # datetime do SurrealDB (`2026-09-29T07:43:00.5Z`) -> `2026-09-29 07:43:00`
    return iso[:19].replace("T", " ") if isinstance(iso, str) and iso else "—"


def _num(n):
    return "—" if n is None else _br(f"{n:,}")


def _usd(v):
    return "—" if v is None else f"US$ {_br(f'{v:,.4f}')}"


def _ago(iso):
    """Datetime do SurrealDB -> idade até agora (`3 min 05 s`)."""
    age = prop_mod.age_seconds(iso, time.time_ns())
    return "—" if age is None else _dur(age * 1_000_000_000)


def _mib(n):
    return f"{_br(f'{n / 2**20:,.1f}')} MiB"


# ------------------------------------------------ alertas (#204): só o texto; quem decide é o `alerts.evaluate`
ALERT_TITLES = {alerts_mod.QUEUE: "Fila do collector acima do limite", alerts_mod.REFUSING: "Destino recusando",
                alerts_mod.NO_DATA: "Host sem dado", alerts_mod.SPOOL: "Spool do oute-emit",
                alerts_mod.QUOTA: "Cota da assinatura"}


def _alert_title(alert):
    return ALERT_TITLES.get(alert["type"], alert["type"])


def _alert_value(alert):
    """Valor e limite do alerta por extenso, pela unidade do `/v1/alerts`. Unidade nova sai crua (`valor unidade`)."""
    v, unit, limit, ev = alert["value"], alert["unit"], alert["limit"], alert["evidence"]
    if v is None:
        return ev.get("note") or "sem valor"
    if unit == "ratio":
        return f"{_br(f'{v * 100:.0f}')}% da fila (limite {_br(f'{limit * 100:.0f}')}%)"
    if unit == "pct":
        return f"{_br(f'{v:g}')}% (limite {_br(f'{limit:g}')}%)"
    if unit == "bytes":
        return f"{_mib(v)} (limite {_mib(limit)})"
    if unit == "seconds":
        return f"há {_dur(int(v * 1e9))} (limite {_dur(int(limit * 1e9))})"
    if unit in ("failed_items", "dropped_events"):
        what = "itens recusados" if unit == "failed_items" else "eventos descartados"
        return f"{_num(round(v))} {what} nos últimos {_br(format(ev.get('window_minutes', 0), 'g'))} min"
    return f"{v} {unit}"


def _env():
    env = jinja2.Environment(loader=jinja2.FileSystemLoader(os.path.join(HERE, "templates")), autoescape=True,
                             undefined=jinja2.StrictUndefined, trim_blocks=True, lstrip_blocks=True)
    env.filters.update(ts=_ts, dur=_dur, ms=_ms, when=_when, num=_num, usd=_usd, ago=_ago,
                       alert_title=_alert_title, alert_value=_alert_value, proposal_path=prop_mod.page_path)
    return env


def safe_next(target):
    """Destino depois do login: só caminho deste servidor (`/…`). Qualquer outra coisa (outro site, `//host`,
    barra invertida, caractere de controle) vira a página inicial."""
    if (not target or not target.startswith("/") or target.startswith("//") or "\\" in target
            or any(ord(c) < 32 or ord(c) == 127 for c in target)):
        return HOME
    return target


def mount(app, store, auth, config, tel, window, surreal=None):
    """Liga as rotas da tela no app. `window(query_params)` é a regra de janela do `/v1/usage` (ValueError = 400).
    `surreal` = cliente do SurrealDB para o estado das sessões (`None` = sem ele: a tela mostra só o DuckDB)."""
    env = _env()
    app.mount("/static", StaticFiles(directory=os.path.join(HERE, "static")), name="static")

    def page(request, name, status=200, headers=None, **ctx):
        # os alertas só existem em página de quem passou pelo `gate` (o login não os mostra)
        shown = hasattr(request.state, "alerts")
        html = env.get_template(name).render(**ctx, alerts_shown=shown, alerts=getattr(request.state, "alerts", None))
        return HTMLResponse(html, status_code=status, headers={**HEADERS, **(headers or {})})

    def error(request, status, message):
        return page(request, "error.html", status, message=message, code=status)

    def is_htmx(request):
        return request.headers.get("hx-request") == "true"

    async def active_alerts():
        """Alertas ativos agora, para o topo das páginas: a avaliação do `/v1/alerts` (`alerts.evaluate`, #204), sem
        regra nenhuma aqui. Falha não derruba a página: `None` vira um aviso no lugar (a causa só no stderr)."""
        try:
            return (await run_in_threadpool(store.alerts, time.time_ns(), config.alerts))["alerts"]
        except Exception as e:  # noqa: BLE001 — os alertas acompanham a página; sem eles, ela sai com o aviso
            tel.warn("web-alerts-failed", "tela: cálculo dos alertas falhou, a página saiu sem eles: %s",
                     type(e).__name__, level=logging.ERROR)
            detail_log.exception("tela: cálculo dos alertas falhou")
            return None

    async def gate(request):
        """`None` se pode ler (e a página leva os alertas); senão a resposta que manda para o login."""
        if auth.reader(request):
            # trecho pedido pelo htmx não leva o topo da página
            if not is_htmx(request):
                request.state.alerts = await active_alerts()
            return None
        target = request.url.path + (f"?{request.url.query}" if request.url.query else "")
        login = "/login?next=" + quote(target, safe="")
        if is_htmx(request):
            # o htmx seguiria um 303 e encaixaria a página de login no meio da tela
            return HTMLResponse("", status_code=401, headers={**HEADERS, "HX-Redirect": login})
        return RedirectResponse(login, status_code=303, headers=HEADERS)

    async def read(request, what, fn, *args):
        """Leitura no DuckDB; falha = página 500 (a causa só no stderr), como a API."""
        try:
            return await run_in_threadpool(fn, *args), None
        except Exception as e:  # noqa: BLE001 — leitura que falhou: 500
            tel.warn("web-failed", "tela: %s falhou, respondi 500: %s", what, type(e).__name__, level=logging.ERROR)
            detail_log.exception("tela: %s falhou", what)
            return None, error(request, 500, "A consulta falhou. A causa está no log do agent-studio.")

    # ------------------------------------------------ login
    @app.get("/")
    async def root():
        return RedirectResponse(HOME, status_code=303, headers=HEADERS)

    @app.get("/login")
    async def login_form(request: Request):
        target = safe_next(request.query_params.get("next"))
        if auth.reader(request):
            return RedirectResponse(target, status_code=303, headers=HEADERS)
        return page(request, "login.html", next=target, failed=False)

    @app.post("/login")
    async def login(request: Request):
        body = b""
        async for chunk in request.stream():
            body += chunk
            if len(body) > MAX_LOGIN_BODY:
                return error(request, 413, "Pedido grande demais.")
        form = parse_qs(body.decode("utf-8", "replace"), keep_blank_values=True)
        target = safe_next((form.get("next") or [""])[0])
        if not auth.token((form.get("token") or [""])[0].strip()):
            tel.warn("unauthorized", "recusado: token ausente ou errado (login)")
            return page(request, "login.html", 401, next=target, failed=True)
        resp = RedirectResponse(target, status_code=303, headers=HEADERS)
        auth.set_cookie(resp)
        return resp

    @app.post("/logout")
    async def logout():
        resp = RedirectResponse("/login", status_code=303, headers=HEADERS)
        auth.clear_cookie(resp)
        return resp

    # ------------------------------------------------ conversas
    @app.get("/conversas")
    async def conversations(request: Request):
        if (denied := await gate(request)) is not None:
            return denied
        q = request.query_params
        try:
            from_ns, to_ns = window(q)
        except ValueError as e:
            return error(request, 400, str(e))
        host, agent = q.get("host", ""), q.get("agent", "")
        data, failed = await read(request, "lista de conversas", store.conversations, from_ns, to_ns, config.prices,
                                  host, agent)
        if failed:
            return failed
        return page(request, "conversations.html", **data, from_ns=from_ns, to_ns=to_ns, host=host, agent=agent,
                    windows=WINDOWS, hours=q.get("hours", "" if "from" in q else "24"),
                    range={"from": q.get("from", ""), "to": q.get("to", "")}, limit=conv_mod.LIST_LIMIT)

    @app.get("/conversa")
    async def conversation(request: Request):
        if (denied := await gate(request)) is not None:
            return denied
        session_id = request.query_params.get("id", "")
        if not session_id:
            return error(request, 400, "Falta o id da conversa.")
        data, failed = await read(request, "conversa", store.conversation, session_id, config.prices)
        if failed:
            return failed
        if data is None:
            return error(request, 404, "Conversa não encontrada.")
        return page(request, "conversation.html", **data, id=session_id, span_limit=conv_mod.SPAN_LIMIT)

    @app.get("/conversa/logs")
    async def conversation_logs(request: Request):
        """Página seguinte dos logs: linhas da tabela para o htmx; sem htmx, uma página inteira só com elas."""
        if (denied := await gate(request)) is not None:
            return denied
        session_id = request.query_params.get("id", "")
        try:
            offset = int(request.query_params.get("offset", "0"))
        except ValueError:
            offset = -1
        if not session_id or not 0 <= offset < 2**31:
            return error(request, 400, "Parâmetros inválidos (id e offset).")
        data, failed = await read(request, "logs da conversa", store.conversation_logs, session_id, offset)
        if failed:
            return failed
        return page(request, "log_rows.html" if is_htmx(request) else "logs.html", **data, id=session_id, offset=offset)

    @app.get("/conversa/span")
    async def conversation_span(request: Request):
        """Conteúdo de um span (atributos, eventos, links): trecho para o htmx; sem htmx, página inteira."""
        if (denied := await gate(request)) is not None:
            return denied
        trace_id, span_id = request.query_params.get("trace", ""), request.query_params.get("span", "")
        if not trace_id or not span_id:
            return error(request, 400, "Faltam trace e span.")
        data, failed = await read(request, "span", store.span, trace_id, span_id)
        if failed:
            return failed
        if data is None:
            return error(request, 404, "Span não encontrado.")
        return page(request, "span_detail.html" if is_htmx(request) else "span.html", span=data)

    # ------------------------------------------------ sessões (#207)
    async def with_state(sessions):
        """Estado do SurrealDB nas sessões: `True` = lido; `False` = a leitura falhou (a página segue só com o
        DuckDB, com aviso; a causa só no stderr); `None` = este processo não tem SurrealDB."""
        if surreal is None:
            return None
        try:
            await run_in_threadpool(sess_mod.with_state, surreal, sessions)
            return True
        except Exception as e:  # noqa: BLE001 — o estado só enfeita: sem ele, a página sai com o DuckDB
            tel.warn("web-state-failed", "tela: estado das sessões (SurrealDB) falhou, segui sem ele: %s",
                     type(e).__name__, level=logging.ERROR)
            detail_log.exception("tela: estado das sessões falhou")
            return False

    @app.get("/sessoes")
    async def sessions(request: Request):
        if (denied := await gate(request)) is not None:
            return denied
        q = request.query_params
        try:
            from_ns, to_ns = window(q)
        except ValueError as e:
            return error(request, 400, str(e))
        host, agent = q.get("host", ""), q.get("agent", "")
        data, failed = await read(request, "lista de sessões", store.sessions, from_ns, to_ns, config.prices,
                                  host, agent)
        if failed:
            return failed
        state = await with_state(data["sessions"])
        return page(request, "sessions.html", **data, state_read=state, from_ns=from_ns, to_ns=to_ns, host=host,
                    agent=agent, windows=WINDOWS, hours=q.get("hours", "" if "from" in q else "24"),
                    range={"from": q.get("from", ""), "to": q.get("to", "")}, limit=conv_mod.LIST_LIMIT)

    @app.get("/sessao")
    async def session(request: Request):
        if (denied := await gate(request)) is not None:
            return denied
        task_id = request.query_params.get("id", "")
        if not task_id:
            return error(request, 400, "Falta o id da sessão.")
        data, failed = await read(request, "sessão", store.session, task_id, config.prices)
        if failed:
            return failed
        # sessão aberta que ainda não tem conversa nem evento no DuckDB pode existir só no SurrealDB
        data = data or {"session": sess_mod.blank(task_id), "events": [], "events_truncated": False}
        state = await with_state([data["session"]])
        if data["session"]["start_ns"] is None and not data["session"]["state"]:
            return error(request, 404, "Sessão não encontrada.")
        return page(request, "session.html", **data, id=task_id, state_read=state, event_limit=sess_mod.EVENT_LIMIT)

    # ------------------------------------------------ pedidos do canal de aprovação (#208): só leitura
    async def proposal_state(what, fn, *args):
        """Leitura do estado dos pedidos no SurrealDB -> (valor, lido): `True` = lido; `False` = a leitura falhou
        (a causa só no stderr); `None` = este processo não tem SurrealDB."""
        if surreal is None:
            return None, None
        try:
            return await run_in_threadpool(fn, surreal, *args), True
        except Exception as e:  # noqa: BLE001 — quem chama decide o que a página mostra sem o estado
            tel.warn("web-state-failed", "tela: %s (SurrealDB) falhou: %s", what, type(e).__name__,
                     level=logging.ERROR)
            detail_log.exception("tela: %s falhou", what)
            return None, False

    @app.get("/pedidos")
    async def proposals(request: Request):
        if (denied := await gate(request)) is not None:
            return denied
        data, state_read = await proposal_state("lista de pedidos", prop_mod.listing)
        if not state_read:
            # a lista é o estado: sem o SurrealDB não há o que mostrar
            if state_read is None:
                return error(request, 503, "Este agent-studio está sem SurrealDB: não há estado dos pedidos.")
            return error(request, 503, "O estado dos pedidos (SurrealDB) não pôde ser lido. A causa está no log do "
                                       "agent-studio.")
        return page(request, "proposals.html", **data, pending_limit=prop_mod.PENDING_LIMIT)

    @app.get("/pedido")
    async def proposal(request: Request):
        """Página "ver script" de um pedido: `/pedido?id=<oute.canal.id>`, o link que o tray abre (ADR-08 §10)."""
        if (denied := await gate(request)) is not None:
            return denied
        proposal_id = request.query_params.get("id", "")
        if not proposal_id:
            return error(request, 400, "Falta o id do pedido.")
        ev, failed = await read(request, "pedido", store.proposal, proposal_id)
        if failed:
            return failed
        record, state_read = await proposal_state("estado do pedido", prop_mod.state, proposal_id)
        if ev is None and record is None:
            return error(request, 404, "Pedido não encontrado.")
        return page(request, "proposal.html", p=prop_mod.merged(proposal_id, ev, record), state_read=state_read)
