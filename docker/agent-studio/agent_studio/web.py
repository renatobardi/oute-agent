"""Tela do agent-studio (ADR-08 §9): login por token que vira cookie, lista de conversas e detalhe (#206), as
sessões do `oute-task` com as conversas de cada uma (#207), os pedidos do canal de aprovação e os alertas do
pipeline no topo das páginas (#208) e a página de preços (#340), o uso por papel e por fase (#433) e o Dashboard `/` (#469).

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
- Alertas: os do `alerts.evaluate` (#204), calculados a cada página; aqui só o texto de cada um. O de preço leva
  à `/precos`.
- Preços (#340): `/precos` mostra o `prices.view` (o mesmo do `GET /v1/prices`): vigente e histórico por modelo. Nenhuma
  ação: trocar preço é da conferência diária e do `fixed` do `config.toml`; aqui não há botão nem rota para isso.
"""
import logging
import os
import re
import time
from datetime import datetime, timezone
from urllib.parse import parse_qs, quote

import jinja2
from fastapi import Request
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import HTMLResponse, RedirectResponse
from starlette.staticfiles import StaticFiles

from . import (alert_text, conversations as conv_mod, dashboard as dash_mod, etapas as etapas_mod, names as names_mod, prices as prices_mod, proposals as prop_mod, repo as repo_mod,
               sessions as sess_mod, tools as tools_mod, tz as tz_mod)
from . import alerts as alerts_mod
from . import usage_charts as charts_mod

detail_log = logging.getLogger("agent_studio_detail")

HERE = os.path.dirname(os.path.abspath(__file__))
HOME = "/"
MAX_LOGIN_BODY = 4096
# janelas prontas das quatro telas com período (#527; horas -> rótulo); a URL aceita também from/to, como o /v1/usage, e de/ate no fuso da tela
WINDOWS = (("24", "24 horas"), ("168", "7 dias"), ("720", "30 dias"), ("8784", "366 dias"))
MAX_HOURS = 24 * 366  # janela máxima (ADR-08); app.py usa o mesmo valor em `hours`
INPUT_FORMATS = ("%Y-%m-%dT%H:%M", "%Y-%m-%dT%H:%M:%S")  # o que o <input type="datetime-local"> manda
HEADERS = {
    "Content-Security-Policy": "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; font-src 'self'; "
                               "connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "same-origin",
    "Cache-Control": "no-store",
}


# ------------------------------------------------ formatação (filtros dos templates)
# Horas no fuso configurado (#415): o dado segue em UTC, só a exibição converte. Cada filtro nasce amarrado ao fuso.
def _ts_in(zone):
    def ts(ns):
        if ns is None:
            return "—"
        return tz_mod.local(ns, zone).strftime("%Y-%m-%d %H:%M:%S")
    return ts


_br, _dur, _num = alert_text.br, alert_text.dur, alert_text.num


def _ms(ms):
    return _dur(None if ms is None else int(ms * 1e6))


def _when_in(zone):
    def when(iso):
        # datetime do SurrealDB ou ISO com `Z` (`2026-09-29T07:43:00.5Z`, UTC) -> `2026-09-29 04:43:00` no fuso
        if not isinstance(iso, str) or not iso:
            return "—"
        try:
            then = datetime.strptime(iso[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
        except ValueError:
            return iso[:19].replace("T", " ")
        return then.astimezone(zone).strftime("%Y-%m-%d %H:%M:%S")
    return when


def _usd(v):
    return "—" if v is None else f"US$ {_br(f'{v:,.4f}')}"


def _usdm(v):
    return "—" if v is None else _br(f"{v:g}")


def _usd2(v):
    return "—" if v is None else f"US$ {_br(f'{v:,.2f}')}"


def _pct_in(frac, digits=0):
    return "—" if frac is None else f"{_br(f'{frac * 100:.{digits}f}')}%"


def _calls(n):
    return f"{_num(n)} {'chamada' if n == 1 else 'chamadas'}"


def _compact(n):
    """Contagem curta para rótulo de gráfico: 410k, 1,9M."""
    if n is None:
        return "—"
    if n >= 1_000_000:
        return f"{_br(f'{n / 1e6:.1f}')}M"
    return f"{_br(f'{n / 1e3:.0f}')}k" if n >= 1000 else str(n)


def _ago(iso):
    """Datetime do SurrealDB -> idade até agora (`3 min 05 s`)."""
    age = prop_mod.age_seconds(iso, time.time_ns())
    return "—" if age is None else _dur(age * 1_000_000_000)


def _env(zone=tz_mod.UTC):
    env = jinja2.Environment(loader=jinja2.FileSystemLoader(os.path.join(HERE, "templates")), autoescape=True,
                             undefined=jinja2.StrictUndefined, trim_blocks=True, lstrip_blocks=True)
    env.filters.update(ts=_ts_in(zone), dur=_dur, ms=_ms, when=_when_in(zone), num=_num, usd=_usd, usdm=_usdm, ago=_ago, usd2=_usd2, pct=_pct_in, compact=_compact, calls=_calls,
                       alert_title=alert_text.title, nome=names_mod.friendly, price_alert=lambda a: str(a.get("type", "")).startswith("price_"), alert_value=alert_text.text, proposal_path=prop_mod.page_path)
    env.tests["safe_cmd_id"] = lambda v: isinstance(v, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", v) is not None  # id que cabe num comando sem aspas
    env.globals["custo"] = "lista"  # o padrão de quem renderiza sem a escolha (#531); `page()` põe a da URL
    env.globals["com_custo"], env.globals["custo_nome"] = _com_custo, _custo_nome
    env.globals["repo_none"] = repo_mod.NONE  # o valor de "sem repositório" no filtro (#528)
    env.globals["tzl"] = lambda: tz_mod.label(zone)  # rótulo do fuso nos cabeçalhos (`GMT-3`); vale para o dia de hoje
    return env


def cost_mode(q):
    """`custo=efetivo` na URL = custo efetivo (#531: assinatura conta 0); qualquer outro valor ou ausente = custo de lista."""
    return "efetivo" if q.get("custo") == "efetivo" else "lista"


@jinja2.pass_context
def _com_custo(ctx, url):
    """Link para outra tela levando a escolha do custo (#531): `custo=efetivo` só quando é o efetivo (o padrão é a lista)."""
    if ctx.get("custo") != "efetivo" or "custo=" in url:
        return url
    return url + ("&" if "?" in url else "?") + "custo=efetivo"


@jinja2.pass_context
def _custo_nome(ctx):
    return ctx.get("custo") or "lista"


def local_input(ns, zone):
    """ns -> `2026-10-04T09:30` no fuso da tela, o valor de um <input type="datetime-local">."""
    return tz_mod.local(ns, zone).strftime("%Y-%m-%dT%H:%M")


def parse_local(value, name, zone):
    """`2026-10-04T09:30` (hora local no fuso da tela) -> ns UTC. ValueError = 400, com a mensagem para a tela."""
    for fmt in INPUT_FORMATS:
        try:
            dt = datetime.strptime((value or "").strip(), fmt)
        except ValueError:
            continue
        return int(dt.replace(tzinfo=zone).timestamp()) * 1_000_000_000
    raise ValueError(f"{name} inválido: informe dia e hora (ex.: 2026-10-04T09:30)")


def has_range(q):
    """`de`/`ate` preenchidos: o intervalo no fuso da tela. Os dois em branco (formulário com a janela pronta) não contam."""
    return bool(q.get("de") or q.get("ate"))


def period(q, from_ns, to_ns, zone):
    """Contexto do controle de período (#527): janela pronta ativa ou o intervalo, já no fuso da tela."""
    custom = "from" in q or has_range(q)
    return {"hours": q.get("hours", "" if custom else "24"),
            "range": {"from": local_input(from_ns, zone) if custom else "", "to": local_input(to_ns, zone) if custom else ""}}


def iso_utc(ns):
    return datetime.fromtimestamp(ns // 1_000_000_000, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


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
    env = _env(config.tz)
    app.mount("/static", StaticFiles(directory=os.path.join(HERE, "static")), name="static")

    def screen_window(q):
        """Janela da tela: a do `/v1/usage` (`window`) mais `de`/`ate`, o intervalo no fuso da tela (#527), e o teto de
        8784 h também para from/to. ValueError = 400 com a mensagem na tela. O contrato do `/v1/usage` não muda."""
        if has_range(q):
            # `hours` junto é o do formulário (a janela pronta que estava ativa): de/ate preenchidos valem mais
            if "from" in q or "to" in q:
                raise ValueError("use de/ate ou from/to, só um deles")
            if not q.get("de") or not q.get("ate"):
                raise ValueError("informe o início e o fim do período")
            from_ns, to_ns = parse_local(q["de"], "início", config.tz), parse_local(q["ate"], "fim", config.tz)
            if from_ns >= to_ns:
                raise ValueError("o fim precisa ser depois do início")
        else:
            from_ns, to_ns = window({k: v for k, v in q.items() if k not in ("de", "ate")})
        if to_ns - from_ns > MAX_HOURS * 3_600_000_000_000:
            raise ValueError(f"o período passa do máximo de {MAX_HOURS} h (366 dias)")
        return from_ns, to_ns

    def alert_age(a, now):
        """Idade em segundos do alerta que recolhe por tempo (#524); `None` = nunca recolhe."""
        if a.get("type") not in alerts_mod.BAND_AGING_TYPES or not a.get("since"):
            return None
        return now - datetime.fromisoformat(a["since"].replace("Z", "+00:00")).timestamp()

    def band_split(items, age, now):
        """(recentes, antigos) das faixas da tela (#524): só a apresentação, sem escrita; `None` passa como está."""
        if not items:
            return items, []
        limit = config.alerts.band_recent_hours * 3600
        recent, old = [], []
        for it in items:
            a = age(it, now)
            (old if a is not None and a > limit else recent).append(it)
        return recent, old

    def page(request, name, status=200, headers=None, **ctx):
        # os alertas só existem em página de quem passou pelo `gate` (o login não os mostra)
        ctx.setdefault("custo", cost_mode(request.query_params))  # #531: os links e rótulos do casco leem daqui
        shown = hasattr(request.state, "alerts")
        # o casco (barra lateral e cabeçalho, #467) só aparece para quem entrou; o login e o erro de quem não entrou saem sem ele
        now = time.time()
        alerts_new, alerts_old = band_split(getattr(request.state, "alerts", None), alert_age, now)
        decisions_new, decisions_old = band_split(getattr(request.state, "decisions", None), lambda d, _now: d["age_seconds"], now)
        html = env.get_template(name).render(**ctx, alerts_shown=shown, alerts=alerts_new, alerts_old=alerts_old,
                                             decisions=decisions_new, decisions_old=decisions_old,
                                             authed=shown or bool(auth.reader(request)))
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

    async def pending_decisions():
        """Decisões pendentes do Bardi (#386) para o topo das páginas. Falha não derruba a página: sem o bloco."""
        try:
            return (await run_in_threadpool(store.decisions, time.time_ns(), config.alerts))["pending"]
        except Exception as e:  # noqa: BLE001 — o bloco acompanha a página; sem ele, ela sai igual
            tel.warn("web-decisions-failed", "tela: decisões pendentes falhou, a página saiu sem elas: %s",
                     type(e).__name__, level=logging.ERROR)
            detail_log.exception("tela: decisões pendentes falhou")
            return None

    async def gate(request):
        """`None` se pode ler (e a página leva os alertas); senão a resposta que manda para o login."""
        if auth.reader(request):
            # trecho pedido pelo htmx não leva o topo da página
            if not is_htmx(request):
                request.state.alerts = await active_alerts()
                request.state.decisions = await pending_decisions()
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

    # ------------------------------------------------ dashboard (#469): só leitura
    @app.get("/")
    async def dashboard(request: Request):
        if (denied := await gate(request)) is not None:
            return denied
        q = request.query_params
        try:
            from_ns, to_ns = screen_window(q)
        except ValueError as e:
            return error(request, 400, str(e))
        repo = q.get("repo", "")
        model = q.get("model", "")
        custo = cost_mode(q)
        snap, failed = await read(request, "dashboard", store.dashboard, from_ns, to_ns, config.prices, config.tz,
                                  repo_mod.parse(repo), model or None, custo == "efetivo")
        if failed:
            return failed
        now = time.time_ns()
        # Gate pendente = pedido pendente (SurrealDB) e decisão pendente da rodada (já lida pelo `gate`)
        records, state_read = await proposal_state("pedidos pendentes", prop_mod.pending)
        ages = [a for a in (prop_mod.age_seconds(p.get("proposed_at"), now) for p in (records or {}).get("pending", []))
                if a is not None]
        ages += [d["age_seconds"] for d in getattr(request.state, "decisions", None) or []]
        per = period(q, from_ns, to_ns, config.tz)
        if "from" in q:
            qs = f"from={quote(q['from'], safe='')}&to={quote(q.get('to', ''), safe='')}"
        elif has_range(q):  # o intervalo digitado no fuso da tela vai adiante em UTC, exato
            qs = f"from={quote(iso_utc(from_ns), safe='')}&to={quote(iso_utc(to_ns), safe='')}"
        else:
            qs = f"hours={quote(per['hours'], safe='')}"
        if repo:  # o repositório vai nos links para as outras telas (#528)
            qs += f"&repo={quote(repo, safe='')}"
        if custo == "efetivo":  # #531
            qs += "&custo=efetivo"
        return page(request, "dashboard.html", snap=snap, insights=dash_mod.insights(snap, ages, qs), gates_read=state_read,
                    gates=len(ages), window_qs=qs, repo=repo, custo=custo, repos=snap["repos"], model=model, **per, from_ns=from_ns, to_ns=to_ns, windows=WINDOWS)

    # ------------------------------------------------ ferramentas (#535): só leitura
    def tools_qs(q, from_ns, to_ns, host, agent, repo):
        """Query string que leva a janela e os filtros da tela das ferramentas para a lista de conversas de uma ferramenta."""
        if "from" in q:
            qs = f"from={quote(q['from'], safe='')}&to={quote(q.get('to', ''), safe='')}"
        elif has_range(q):  # o intervalo digitado no fuso da tela vai adiante em UTC, exato
            qs = f"from={quote(iso_utc(from_ns), safe='')}&to={quote(iso_utc(to_ns), safe='')}"
        else:
            qs = f"hours={quote(period(q, from_ns, to_ns, config.tz)['hours'], safe='')}"
        for key, value in (("host", host), ("agent", agent), ("repo", repo)):
            if value:
                qs += f"&{key}={quote(value, safe='')}"
        if cost_mode(q) == "efetivo":  # #531: a escolha do custo atravessa a tela
            qs += "&custo=efetivo"
        return qs

    @app.get("/ferramentas")
    async def tools_screen(request: Request):
        if (denied := await gate(request)) is not None:
            return denied
        q = request.query_params
        try:
            from_ns, to_ns = screen_window(q)
        except ValueError as e:
            return error(request, 400, str(e))
        host, agent, repo = q.get("host", ""), q.get("agent", ""), q.get("repo", "")
        data, failed = await read(request, "ferramentas", store.tools, from_ns, to_ns, config.tz, repo_mod.parse(repo),
                                  host or None, agent or None)
        if failed:
            return failed
        return page(request, "tools.html", **data, host=host, agent=agent, repo=repo, from_ns=from_ns, to_ns=to_ns,
                    windows=WINDOWS, link_qs=tools_qs(q, from_ns, to_ns, host, agent, repo), **period(q, from_ns, to_ns, config.tz))

    @app.get("/ferramenta")
    async def tool_screen(request: Request):
        if (denied := await gate(request)) is not None:
            return denied
        q = request.query_params
        try:
            from_ns, to_ns = screen_window(q)
        except ValueError as e:
            return error(request, 400, str(e))
        name = q.get("nome", "")
        if not name or len(name) > 200:
            return error(request, 400, "informe o nome da ferramenta")
        host, agent, repo = q.get("host", ""), q.get("agent", ""), q.get("repo", "")
        data, failed = await read(request, "conversas da ferramenta", store.tool_conversations, name, from_ns, to_ns,
                                  repo_mod.parse(repo), host or None, agent or None)
        if failed:
            return failed
        return page(request, "tool.html", data=data, tool=name, host=host, agent=agent, repo=repo, from_ns=from_ns, to_ns=to_ns,
                    link_qs=tools_qs(q, from_ns, to_ns, host, agent, repo), limit=tools_mod.CONV_LIMIT)

    # ------------------------------------------------ login
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
            from_ns, to_ns = screen_window(q)
        except ValueError as e:
            return error(request, 400, str(e))
        host, agent, repo = q.get("host", ""), q.get("agent", ""), q.get("repo", "")
        data, failed = await read(request, "lista de conversas", store.conversations, from_ns, to_ns, config.prices,
                                  host, agent, repo_mod.parse(repo), cost_mode(q) == "efetivo")
        if failed:
            return failed
        return page(request, "conversations.html", **data, from_ns=from_ns, to_ns=to_ns, host=host, agent=agent, repo=repo,
                    windows=WINDOWS, **period(q, from_ns, to_ns, config.tz), limit=conv_mod.LIST_LIMIT)

    @app.get("/conversa")
    async def conversation(request: Request):
        if (denied := await gate(request)) is not None:
            return denied
        session_id = request.query_params.get("id", "")
        if not session_id:
            return error(request, 400, "Falta o id da conversa.")
        errors_only = request.query_params.get("erros") == "1"
        data, failed = await read(request, "conversa", store.conversation, session_id, config.prices, errors_only,
                                  cost_mode(request.query_params) == "efetivo")
        if failed:
            return failed
        if data is None:
            return error(request, 404, "Conversa não encontrada.")
        return page(request, "conversation.html", **data, id=session_id, span_limit=conv_mod.SPAN_LIMIT, errors_only=errors_only)

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
        errors_only = request.query_params.get("erros") == "1"
        data, failed = await read(request, "logs da conversa", store.conversation_logs, session_id, offset, errors_only)
        if failed:
            return failed
        return page(request, "log_rows.html" if is_htmx(request) else "logs.html", **data, id=session_id, offset=offset,
                    errors_only=errors_only)

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
            from_ns, to_ns = screen_window(q)
        except ValueError as e:
            return error(request, 400, str(e))
        host, agent, repo = q.get("host", ""), q.get("agent", ""), q.get("repo", "")
        data, failed = await read(request, "lista de sessões", store.sessions, from_ns, to_ns, config.prices,
                                  host, agent, repo_mod.parse(repo), cost_mode(q) == "efetivo")
        if failed:
            return failed
        state = await with_state(data["sessions"])
        return page(request, "sessions.html", **data, state_read=state, from_ns=from_ns, to_ns=to_ns, host=host,
                    agent=agent, repo=repo, windows=WINDOWS, **period(q, from_ns, to_ns, config.tz), limit=conv_mod.LIST_LIMIT)

    @app.get("/sessao")
    async def session(request: Request):
        if (denied := await gate(request)) is not None:
            return denied
        task_id = request.query_params.get("id", "")
        if not task_id:
            return error(request, 400, "Falta o id da sessão.")
        data, failed = await read(request, "sessão", store.session, task_id, config.prices,
                                  cost_mode(request.query_params) == "efetivo")
        if failed:
            return failed
        # sessão aberta que ainda não tem conversa nem evento no DuckDB pode existir só no SurrealDB
        data = data or {"session": sess_mod.blank(task_id), "events": [], "events_truncated": False, "phase": None}
        state = await with_state([data["session"]])
        if data["session"]["start_ns"] is None and not data["session"]["state"]:
            return error(request, 404, "Sessão não encontrada.")
        return page(request, "session.html", **data, id=task_id, state_read=state, event_limit=sess_mod.EVENT_LIMIT)

    # ------------------------------------------------ uso por papel e por fase (#433)
    @app.get("/uso")
    async def usage(request: Request):
        if (denied := await gate(request)) is not None:
            return denied
        q = request.query_params
        try:
            from_ns, to_ns = screen_window(q)
        except ValueError as e:
            return error(request, 400, str(e))
        repo = q.get("repo", "")
        data, failed = await read(request, "uso", store.usage, from_ns, to_ns, config.prices, config.tz, repo_mod.parse(repo),
                                  cost_mode(q) == "efetivo")
        if failed:
            return failed
        repos, failed = await read(request, "repositórios do uso", store.repos, from_ns, to_ns)
        if failed:
            return failed

        def by_cost(rows):
            # o que mais custou primeiro (real + estimado); empate pela ordem da API
            return sorted(rows, key=lambda r: -((r["cost"]["real_usd"] or 0) + (r["cost"]["estimated_usd"] or 0)))
        by_role, by_phase = by_cost(data["by_role"]), by_cost(data["by_phase"])
        return page(request, "usage.html", totals=data["totals"], by_role=by_role, charts=charts_mod.build(data, by_role, by_phase),
                    by_phase=by_phase, from_ns=from_ns, to_ns=to_ns, windows=WINDOWS, repo=repo, repos=repos,
                    **period(q, from_ns, to_ns, config.tz))

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

    # ------------------------------------------------ rodadas (#507): as etapas que o dispatcher publica; só leitura
    @app.get("/rodadas")
    async def rounds(request: Request):
        if (denied := await gate(request)) is not None:
            return denied
        rows, failed = await read(request, "lista de rodadas", store.read, lambda con: etapas_mod.listing(con))
        if failed:
            return failed
        states, state_read = await proposal_state("estado das rodadas", etapas_mod.round_states, [r["round"] for r in rows])
        for r in rows:
            r["state"] = (states or {}).get(r["round"])
        return page(request, "rodadas.html", rounds=rows, state_read=state_read,
                    limit_reached=len(rows) >= etapas_mod.LIST_LIMIT)

    @app.get("/rodada")
    async def round_page(request: Request):
        """Página da rodada: `/rodada?id=<rodada>`, com a barra de etapas e o texto de cada etapa."""
        if (denied := await gate(request)) is not None:
            return denied
        rnd = request.query_params.get("id", "")
        if not rnd:
            return error(request, 400, "Falta o id da rodada.")
        data, failed = await read(request, "rodada", etapas_mod.load, store, surreal, rnd)
        if failed:
            return failed
        if data is None:
            return error(request, 404, "Rodada não encontrada.")
        if data["state_error"]:
            tel.warn("web-state-failed", "tela: estado das etapas (SurrealDB) falhou, segui com o DuckDB: %s",
                     data["state_error"], level=logging.ERROR)
        etapas_mod.render(data["steps"])
        return page(request, "rodada.html", r=data, bar=etapas_mod.bar(data["steps"]), state_read=data["state_read"])

    # ------------------------------------------------ preços (#340): só leitura
    @app.get("/precos")
    async def prices(request: Request):
        if (denied := await gate(request)) is not None:
            return denied
        at_ns = time.time_ns()
        data, failed = await read(request, "preços", store.read, lambda con: prices_mod.view(con, config.fixed, at_ns))
        if failed:
            return failed
        return page(request, "prices.html", **prices_mod.decorate(data, at_ns))
