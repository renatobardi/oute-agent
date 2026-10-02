"""Tela do agent-studio (ADR-08 §9, #206): login por token que vira cookie, lista de conversas e detalhe.

HTML gerado no servidor (Jinja2, sempre com autoescape) + htmx servido daqui mesmo (`/static`): sem SPA, sem build
de front-end e sem CDN. Só leitura.

- Sem cookie nem `Bearer`: página redireciona para o `/login` (303); pedido do htmx recebe 401 com `HX-Redirect`.
- `POST /login` com o token errado = 401; certo = cookie (`auth.py`) e volta para onde ia. `POST /logout` apaga.
- O conteúdo das conversas (prompts, saídas de tool) é dado não confiável: autoescape em tudo e uma CSP que só
  aceita script e estilo deste servidor.
"""
import logging
import os
from datetime import datetime, timezone
from urllib.parse import parse_qs, quote

import jinja2
from fastapi import Request
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import HTMLResponse, RedirectResponse
from starlette.staticfiles import StaticFiles

from . import conversations as conv_mod

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


def _num(n):
    return "—" if n is None else _br(f"{n:,}")


def _usd(v):
    return "—" if v is None else f"US$ {_br(f'{v:,.4f}')}"


def _env():
    env = jinja2.Environment(loader=jinja2.FileSystemLoader(os.path.join(HERE, "templates")), autoescape=True,
                             undefined=jinja2.StrictUndefined, trim_blocks=True, lstrip_blocks=True)
    env.filters.update(ts=_ts, dur=_dur, num=_num, usd=_usd)
    return env


def safe_next(target):
    """Destino depois do login: só caminho deste servidor (`/…`). Qualquer outra coisa (outro site, `//host`,
    barra invertida, caractere de controle) vira a página inicial."""
    if (not target or not target.startswith("/") or target.startswith("//") or "\\" in target
            or any(ord(c) < 32 or ord(c) == 127 for c in target)):
        return HOME
    return target


def mount(app, store, auth, config, tel, window):
    """Liga as rotas da tela no app. `window(query_params)` é a regra de janela do `/v1/usage` (ValueError = 400)."""
    env = _env()
    app.mount("/static", StaticFiles(directory=os.path.join(HERE, "static")), name="static")

    def page(name, status=200, headers=None, **ctx):
        html = env.get_template(name).render(**ctx)
        return HTMLResponse(html, status_code=status, headers={**HEADERS, **(headers or {})})

    def error(status, message):
        return page("error.html", status, message=message, code=status)

    def is_htmx(request):
        return request.headers.get("hx-request") == "true"

    def gate(request):
        """`None` se pode ler; senão a resposta que manda para o login."""
        if auth.reader(request):
            return None
        target = request.url.path + (f"?{request.url.query}" if request.url.query else "")
        login = "/login?next=" + quote(target, safe="")
        if is_htmx(request):
            # o htmx seguiria um 303 e encaixaria a página de login no meio da tela
            return HTMLResponse("", status_code=401, headers={**HEADERS, "HX-Redirect": login})
        return RedirectResponse(login, status_code=303, headers=HEADERS)

    async def read(what, fn, *args):
        """Leitura no DuckDB; falha = página 500 (a causa só no stderr), como a API."""
        try:
            return await run_in_threadpool(fn, *args), None
        except Exception as e:  # noqa: BLE001 — leitura que falhou: 500
            tel.warn("web-failed", "tela: %s falhou, respondi 500: %s", what, type(e).__name__, level=logging.ERROR)
            detail_log.exception("tela: %s falhou", what)
            return None, error(500, "A consulta falhou. A causa está no log do agent-studio.")

    # ------------------------------------------------ login
    @app.get("/")
    async def root():
        return RedirectResponse(HOME, status_code=303, headers=HEADERS)

    @app.get("/login")
    async def login_form(request: Request):
        target = safe_next(request.query_params.get("next"))
        if auth.reader(request):
            return RedirectResponse(target, status_code=303, headers=HEADERS)
        return page("login.html", next=target, failed=False)

    @app.post("/login")
    async def login(request: Request):
        body = b""
        async for chunk in request.stream():
            body += chunk
            if len(body) > MAX_LOGIN_BODY:
                return error(413, "Pedido grande demais.")
        form = parse_qs(body.decode("utf-8", "replace"), keep_blank_values=True)
        target = safe_next((form.get("next") or [""])[0])
        if not auth.token((form.get("token") or [""])[0].strip()):
            tel.warn("unauthorized", "recusado: token ausente ou errado (login)")
            return page("login.html", 401, next=target, failed=True)
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
        if (denied := gate(request)) is not None:
            return denied
        q = request.query_params
        try:
            from_ns, to_ns = window(q)
        except ValueError as e:
            return error(400, str(e))
        host, agent = q.get("host", ""), q.get("agent", "")
        data, failed = await read("lista de conversas", store.conversations, from_ns, to_ns, config.prices, host, agent)
        if failed:
            return failed
        return page("conversations.html", **data, from_ns=from_ns, to_ns=to_ns, host=host, agent=agent,
                    windows=WINDOWS, hours=q.get("hours", "" if "from" in q else "24"),
                    range={"from": q.get("from", ""), "to": q.get("to", "")}, limit=conv_mod.LIST_LIMIT)

    @app.get("/conversa")
    async def conversation(request: Request):
        if (denied := gate(request)) is not None:
            return denied
        session_id = request.query_params.get("id", "")
        if not session_id:
            return error(400, "Falta o id da conversa.")
        data, failed = await read("conversa", store.conversation, session_id, config.prices)
        if failed:
            return failed
        if data is None:
            return error(404, "Conversa não encontrada.")
        return page("conversation.html", **data, id=session_id, span_limit=conv_mod.SPAN_LIMIT)

    @app.get("/conversa/logs")
    async def conversation_logs(request: Request):
        """Página seguinte dos logs: linhas da tabela para o htmx; sem htmx, uma página inteira só com elas."""
        if (denied := gate(request)) is not None:
            return denied
        session_id = request.query_params.get("id", "")
        try:
            offset = int(request.query_params.get("offset", "0"))
        except ValueError:
            offset = -1
        if not session_id or not 0 <= offset < 2**31:
            return error(400, "Parâmetros inválidos (id e offset).")
        data, failed = await read("logs da conversa", store.conversation_logs, session_id, offset)
        if failed:
            return failed
        return page("log_rows.html" if is_htmx(request) else "logs.html", **data, id=session_id, offset=offset)

    @app.get("/conversa/span")
    async def conversation_span(request: Request):
        """Conteúdo de um span (atributos, eventos, links): trecho para o htmx; sem htmx, página inteira."""
        if (denied := gate(request)) is not None:
            return denied
        trace_id, span_id = request.query_params.get("trace", ""), request.query_params.get("span", "")
        if not trace_id or not span_id:
            return error(400, "Faltam trace e span.")
        data, failed = await read("span", store.span, trace_id, span_id)
        if failed:
            return failed
        if data is None:
            return error(404, "Span não encontrado.")
        return page("span_detail.html" if is_htmx(request) else "span.html", span=data)
