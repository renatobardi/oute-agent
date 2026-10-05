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
from urllib.parse import parse_qs, quote, urlencode

import jinja2
from fastapi import Request
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import HTMLResponse, RedirectResponse
from starlette.staticfiles import StaticFiles
from starlette.datastructures import QueryParams

from . import (acoes as acoes_mod, alert_text, conversations as conv_mod, dashboard as dash_mod, etapas as etapas_mod, names as names_mod, prices as prices_mod, proposals as prop_mod, repo as repo_mod,
               sessions as sess_mod, tabela as tabela_mod, tools as tools_mod, tz as tz_mod, usage as usage_mod)
from . import alerts as alerts_mod
from . import loading as loading_mod
from . import marcar as marcar_mod
from . import usage_charts as charts_mod

detail_log = logging.getLogger("agent_studio_detail")

HERE = os.path.dirname(os.path.abspath(__file__))
HOME = "/"
CONVERSAS = "/conversas"
SESSOES = "/sessoes"
FERRAMENTA = "/ferramenta"
CONVERSA_LOGS = "/conversa/logs"
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
    env.globals["fragment"] = loading_mod.render_fragment(None, [])
    env.globals["loading_target"] = None
    env.globals["loading_shell"] = False
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
    views = loading_mod.Views()
    screens = {}
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
        target = getattr(request.state, "block", None)
        found = []
        ctx.update(fragment=loading_mod.render_fragment(target, found), loading_target=target,
                   loading_slot=lambda n, shape, anchor="": slot(request, n, shape, anchor))
        html = env.get_template(name).render(**ctx, alerts_shown=shown, alerts=alerts_new, alerts_old=alerts_old,
                                             decisions=decisions_new, decisions_old=decisions_old,
                                             authed=shown or bool(auth.reader(request)))
        if target is not None:
            if not found:
                return error(request, 404, "Bloco não encontrado.")
            title = re.search(r"<title>(.*?)</title>", html, re.S)
            html = "".join(found)
            if target in ("resumo", "filtros", "conteudo") and title:
                html += '<template data-document-title>' + title.group(1) + '</template>'
        return HTMLResponse(html, status_code=status, headers={**HEADERS, **(headers or {})})

    def table_states(q, *tables):
        """O pedido da URL para cada tabela da tela (#529), ou `ValueError` (400) com a mensagem para a tela: parâmetro de
        ordem, direção, filtro, página ou tamanho fora da lista fixa. Roda antes de qualquer leitura."""
        tabela_mod.check_params(q, tables)
        return [tabela_mod.parse(t, q) for t in tables]

    def table_ctx(q, path, *tabs):
        """`tabs` = (tabela, pedido, linhas) -> as `View`s e os campos escondidos que o formulário do período leva (ordem,
        direção, tamanho e filtros: a página volta à primeira)."""
        q = QueryParams([(k, v) for k, v in q.multi_items() if k not in ("view", "full")])
        tables = [t for t, _, _ in tabs]
        return [tabela_mod.apply(t, st, rows, tabela_mod.foreign_pairs(q, [t], lambda k, v: k == "custo" and v != "efetivo"), path) for t, st, rows in tabs], tabela_mod.own_pairs(q, tables)

    def error(request, status, message):
        if hasattr(request.state, "block") or hasattr(request.state, "inline_block"):
            html = env.get_template("loading_error.html").render(message=message,
                retry=request.url.path + "?" + request.url.query, full_url=full_url(request), expired=status == 410,
                row=getattr(request.state, "inline_block", "") == "tabela",
                reopen=getattr(request.state, "screen_path", request.url.path) + "?" + urlencode(loading_mod.pairs(request.query_params)))
            return HTMLResponse(html, status_code=status, headers=HEADERS)
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
            if request.query_params.get("full") == "1" and not is_htmx(request):
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
            view = getattr(request.state, "view", None)
            if view is not None:
                return await run_in_threadpool(view.read, what, fn, args), None
            return await run_in_threadpool(fn, *args), None
        except Exception as e:  # noqa: BLE001 — leitura que falhou: 500
            tel.warn("web-failed", "tela: %s falhou, respondi 500: %s", what, type(e).__name__, level=logging.ERROR)
            detail_log.exception("tela: %s falhou", what)
            return None, error(request, 500, "A consulta falhou. A causa está no log do agent-studio.")

    def full_url(request):
        path = getattr(request.state, "screen_path", request.url.path)
        path = path if path in loading_mod.SCREENS else HOME
        return path + "?" + urlencode([*loading_mod.pairs(request.query_params), ("full", "1")])

    def slot(request, name, shape, anchor=""):
        path = getattr(request.state, "screen_path", request.url.path)
        url = loading_mod.block_url(path, name, loading_mod.pairs(request.query_params),
                                    getattr(request.state, "view_id", ""))
        from markupsafe import Markup
        return Markup(env.get_template("loading_slot.html").render(nome=name, forma=shape, url=url, anchor=anchor,
                                                                  full_url=full_url(request)))

    def validate_screen(path, q):
        # Mesmas regras das rotas completas, antes de abrir a primeira leitura.
        if path in ("/", CONVERSAS, SESSOES, "/uso", "/ferramentas", FERRAMENTA, "/rodadas"):
            screen_window(q)
        tables = {CONVERSAS: (conv_mod.TABLE,), SESSOES: (sess_mod.TABLE, sess_mod.LOOSE),
                  "/uso": (usage_mod.ROLE_TABLE, usage_mod.PHASE_TABLE),
                  "/pedidos": (prop_mod.PENDING_TABLE, prop_mod.RECENT_TABLE), "/rodadas": (etapas_mod.TABLE,)}
        if path in tables:
            table_states(q, *tables[path])
        if path in ("/conversa", "/sessao", "/pedido", "/rodada", "/ciclo", CONVERSA_LOGS) and not q.get("id"):
            raise ValueError("Falta o id.")
        if path == "/ciclo" and not etapas_mod.CYCLE_ID.match(q["id"]):
            raise ValueError("O id do ciclo tem de ser <dono>/<repo>#<número>.")
        if path == FERRAMENTA and (not q.get("nome") or len(q["nome"]) > 200):
            raise ValueError("informe o nome da ferramenta")
        if path == "/conversa/span" and (not q.get("trace") or not q.get("span")):
            raise ValueError("Faltam trace e span.")
        if path == CONVERSA_LOGS:
            try:
                offset = int(q.get("offset", "0"))
            except ValueError:
                offset = -1
            if not 0 <= offset < 2**31:
                raise ValueError("Parâmetros inválidos (id e offset).")

    def request_window(request):
        view = getattr(request.state, "view", None)
        return view.window if view is not None and view.window is not None else screen_window(request.query_params)

    def shell_info(path, request):
        title, nav, detail, blocks = loading_mod.SCREENS[path]
        back = "/" + nav
        if nav in ("conversas", "sessoes"):
            group = "Telemetria"
        elif nav in ("uso", "ferramentas", "precos"):
            group = "Análise"
        else:
            group = "Governança"
        label = "Uso" if nav == "uso" else title
        crumbs = [(group, None), (label, None)] if path != "/" else [(title, None)]
        ident = request.query_params.get("id", "")
        if detail:
            parent = {"conversas": "Conversas", "sessoes": "Sessões", "pedidos": "Pedidos", "rodadas": "Rodadas", "ferramentas": "Ferramentas"}[nav]
            label = names_mod.friendly(ident) if path == "/conversa" else ident or title
            crumbs = [(parent, back), (label, None)]
        if path == CONVERSA_LOGS:
            back = "/conversa?id=" + quote(ident, safe="") + ("&erros=1" if request.query_params.get("erros") == "1" else "")
            crumbs = [("Conversas", CONVERSAS), (names_mod.friendly(ident), back), ("Logs", None)]
        return {"titulo": title, "nav": nav, "detail": detail, "blocos": blocks, "back": back, "crumbs": crumbs,
                "shell_path": path, "id": ident}

    def screen(path):
        def register(fn):
            screens[path] = fn

            @app.get(path)
            async def shell(request: Request):
                if path in (CONVERSA_LOGS, "/conversa/span") and is_htmx(request):
                    request.state.screen_path = path
                    request.state.inline_block = "tabela" if path == CONVERSA_LOGS else "faixa"
                    return await fn(request)
                if request.query_params.get("full") == "1":
                    return await fn(request)
                if (denied := await gate(request)) is not None:
                    return denied
                try:
                    validate_screen(path, request.query_params)
                except ValueError as exc:
                    return error(request, 400, str(exc))
                request.state.screen_path = path
                fixed_window = screen_window(request.query_params) if path in ("/", CONVERSAS, SESSOES, "/uso", "/ferramentas", FERRAMENTA, "/rodadas") else None
                request.state.view_id = views.open(path, loading_mod.pairs(request.query_params), fixed_window)
                return page(request, "loading.html", **shell_info(path, request),
                            full_url=full_url(request), loading_shell=True)
            return fn
        return register

    @app.get("/bloco/{screen_name:path}/{block}")
    async def block_screen(request: Request, screen_name: str, block: str):
        # Cada trecho exige login, mesmo quando aberto diretamente por link.
        request.state.block = block
        path = "/" if screen_name == "dashboard" else "/" + screen_name
        request.state.screen_path = path
        if not auth.reader(request):
            return HTMLResponse("", 401, headers={**HEADERS, "HX-Redirect": "/login?next=" + quote(full_url(request), safe="")})
        if path not in screens:
            return error(request, 404, "Tela não encontrada.")
        names = {n for n, _ in loading_mod.SCREENS[path][3]}
        if not loading_mod.SCREENS[path][2]:
            names.update(("alertas", "decisoes"))
        price_block = path == "/precos" and re.fullmatch(r"preco-\d{1,4}-(grafico|vigente|historico)", block, re.ASCII)
        step_block = path == "/rodada" and re.fullmatch(r"etapa-\d{1,4}", block, re.ASCII)
        if block not in names and not price_block and not step_block:
            return error(request, 404, "Bloco não encontrado.")
        try:
            validate_screen(path, request.query_params)
        except ValueError as exc:
            return error(request, 400, str(exc))
        request.state.view_id = request.query_params.get("view", "")
        request.state.view = views.find(request.state.view_id, path, loading_mod.pairs(request.query_params))
        if request.state.view_id and request.state.view is None:
            return error(request, 410, "Este carregamento expirou. Reabra a tela para carregar os blocos.")
        if block == "alertas":
            request.state.alerts = await active_alerts()
            return page(request, "base.html")
        if block == "decisoes":
            request.state.decisions = await pending_decisions()
            return page(request, "base.html")
        return await screens[path](request)

    @app.get("/rodada/bloco/{block}")
    async def round_block(request: Request, block: str):
        # O cookie de marcação da #510 tem Path=/rodada: esta rota mantém seu escopo.
        return await block_screen(request, "rodada", block)

    # ------------------------------------------------ dashboard (#469): só leitura
    @screen("/")
    async def dashboard(request: Request):
        if (denied := await gate(request)) is not None:
            return denied
        q = request.query_params
        try:
            from_ns, to_ns = request_window(request)
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
        records, state_read = None, None
        if getattr(request.state, "block", None) in (None, "insights"):
            if not hasattr(request.state, "decisions"):
                request.state.decisions = await pending_decisions()
            records, state_read = await proposal_state(request, "pedidos pendentes", prop_mod.pending)
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

    @screen("/ferramentas")
    async def tools_screen(request: Request):
        if (denied := await gate(request)) is not None:
            return denied
        q = request.query_params
        try:
            from_ns, to_ns = request_window(request)
        except ValueError as e:
            return error(request, 400, str(e))
        host, agent, repo = q.get("host", ""), q.get("agent", ""), q.get("repo", "")
        data, failed = await read(request, "ferramentas", store.tools, from_ns, to_ns, config.tz, repo_mod.parse(repo),
                                  host or None, agent or None)
        if failed:
            return failed
        return page(request, "tools.html", **data, host=host, agent=agent, repo=repo, from_ns=from_ns, to_ns=to_ns,
                    windows=WINDOWS, link_qs=tools_qs(q, from_ns, to_ns, host, agent, repo), **period(q, from_ns, to_ns, config.tz))

    @screen(FERRAMENTA)
    async def tool_screen(request: Request):
        if (denied := await gate(request)) is not None:
            return denied
        q = request.query_params
        try:
            from_ns, to_ns = request_window(request)
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
    @screen(CONVERSAS)
    async def conversations(request: Request):
        if (denied := await gate(request)) is not None:
            return denied
        q = request.query_params
        try:
            from_ns, to_ns = request_window(request)
        except ValueError as e:
            return error(request, 400, str(e))
        try:
            (st,) = table_states(q, conv_mod.TABLE)
        except ValueError as e:
            return error(request, 400, str(e))
        repo = q.get("repo", "")
        data, failed = await read(request, "lista de conversas", store.conversations, from_ns, to_ns, config.prices,
                                  "", "", repo_mod.parse(repo), cost_mode(q) == "efetivo", None)
        if failed:
            return failed
        (t,), keep = table_ctx(q, CONVERSAS, (conv_mod.TABLE, st, data["conversations"]))
        return page(request, "conversations.html", t=t, keep=keep, repos=data["repos"], from_ns=from_ns, to_ns=to_ns, repo=repo,
                    windows=WINDOWS, **period(q, from_ns, to_ns, config.tz))

    @screen("/conversa")
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

    @screen(CONVERSA_LOGS)
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
        return page(request, "log_rows.html" if is_htmx(request) and not hasattr(request.state, "block") else "logs.html", **data, id=session_id, offset=offset,
                    errors_only=errors_only)

    @screen("/conversa/span")
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
        return page(request, "span_detail.html" if is_htmx(request) and not hasattr(request.state, "block") else "span.html", span=data)

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

    @screen(SESSOES)
    async def sessions(request: Request):
        if (denied := await gate(request)) is not None:
            return denied
        q = request.query_params
        try:
            from_ns, to_ns = request_window(request)
        except ValueError as e:
            return error(request, 400, str(e))
        try:
            st, st_loose = table_states(q, sess_mod.TABLE, sess_mod.LOOSE)
        except ValueError as e:
            return error(request, 400, str(e))
        repo = q.get("repo", "")
        data, failed = await read(request, "lista de sessões", store.sessions, from_ns, to_ns, config.prices,
                                  "", "", repo_mod.parse(repo), cost_mode(q) == "efetivo", None)
        if failed:
            return failed
        state = await with_state(data["sessions"])   # o estado antes da tabela: ele é uma coluna de filtro
        (ts, tl), keep = table_ctx(q, SESSOES, (sess_mod.TABLE, st, data["sessions"]), (sess_mod.LOOSE, st_loose, data["loose"]))
        return page(request, "sessions.html", ts=ts, tl=tl, keep=keep, repos=data["repos"], state_read=state, from_ns=from_ns, to_ns=to_ns,
                    repo=repo, windows=WINDOWS, **period(q, from_ns, to_ns, config.tz))

    @screen("/sessao")
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
    @screen("/uso")
    async def usage(request: Request):
        if (denied := await gate(request)) is not None:
            return denied
        q = request.query_params
        try:
            from_ns, to_ns = request_window(request)
        except ValueError as e:
            return error(request, 400, str(e))
        try:
            st_role, st_phase = table_states(q, usage_mod.ROLE_TABLE, usage_mod.PHASE_TABLE)
        except ValueError as e:
            return error(request, 400, str(e))
        repo = q.get("repo", "")
        data, failed = await read(request, "uso", store.usage, from_ns, to_ns, config.prices, config.tz, repo_mod.parse(repo),
                                  cost_mode(q) == "efetivo")
        if failed:
            return failed
        repos = []
        if getattr(request.state, "block", None) in (None, "filtros"):
            repos, failed = await read(request, "repositórios do uso", store.repos, from_ns, to_ns)
            if failed:
                return failed

        def by_cost(rows):
            # o que mais custou primeiro (real + estimado); empate pela ordem da API
            return sorted(rows, key=lambda r: -((r["cost"]["real_usd"] or 0) + (r["cost"]["estimated_usd"] or 0)))
        by_role, by_phase = by_cost(data["by_role"]), by_cost(data["by_phase"])
        (t_role, t_phase), keep = table_ctx(q, "/uso", (usage_mod.ROLE_TABLE, st_role, by_role), (usage_mod.PHASE_TABLE, st_phase, by_phase))
        return page(request, "usage.html", totals=data["totals"], t_role=t_role, t_phase=t_phase, keep=keep, charts=charts_mod.build(data, by_role, by_phase),
                    from_ns=from_ns, to_ns=to_ns, windows=WINDOWS, repo=repo, repos=repos,
                    **period(q, from_ns, to_ns, config.tz))

    # ------------------------------------------------ pedidos do canal de aprovação (#208): só leitura
    async def proposal_state(request, what, fn, *args):
        """Leitura do estado dos pedidos no SurrealDB -> (valor, lido): `True` = lido; `False` = a leitura falhou
        (a causa só no stderr); `None` = este processo não tem SurrealDB."""
        if surreal is None:
            return None, None
        try:
            view = getattr(request.state, "view", None)
            if view is not None:
                return await run_in_threadpool(view.read, what, fn, (surreal, *args)), True
            return await run_in_threadpool(fn, surreal, *args), True
        except Exception as e:  # noqa: BLE001 — quem chama decide o que a página mostra sem o estado
            tel.warn("web-state-failed", "tela: %s (SurrealDB) falhou: %s", what, type(e).__name__,
                     level=logging.ERROR)
            detail_log.exception("tela: %s falhou", what)
            return None, False

    @screen("/pedidos")
    async def proposals(request: Request):
        if (denied := await gate(request)) is not None:
            return denied
        try:
            st_pending, st_recent = table_states(request.query_params, prop_mod.PENDING_TABLE, prop_mod.RECENT_TABLE)
        except ValueError as e:
            return error(request, 400, str(e))
        data, state_read = await proposal_state(request, "lista de pedidos", prop_mod.listing, tabela_mod.ALL, tabela_mod.ALL)
        if not state_read:
            # a lista é o estado: sem o SurrealDB não há o que mostrar
            if state_read is None:
                return error(request, 503, "Este agent-studio está sem SurrealDB: não há estado dos pedidos.")
            return error(request, 503, "O estado dos pedidos (SurrealDB) não pôde ser lido. A causa está no log do "
                                       "agent-studio.")
        (tp, td), _ = table_ctx(request.query_params, "/pedidos", (prop_mod.PENDING_TABLE, st_pending, data["pending"]),
                                (prop_mod.RECENT_TABLE, st_recent, data["recent"]))
        return page(request, "proposals.html", tp=tp, td=td)

    @screen("/pedido")
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
        record, state_read = await proposal_state(request, "estado do pedido", prop_mod.state, proposal_id)
        if ev is None and record is None:
            return error(request, 404, "Pedido não encontrado.")
        return page(request, "proposal.html", p=prop_mod.merged(proposal_id, ev, record), state_read=state_read)

    # ------------------------------------------------ rodadas (#507): as etapas que o dispatcher publica; só leitura
    def round_url(r, now_ns):
        """Aonde a linha da rodada leva (#601): com etapa, à página da rodada; sem etapa, às sessões dela, na janela que vai
        do primeiro evento ao fechamento (rodada sem fechamento: até agora), limitada ao máximo da tela."""
        if r["steps"]:
            return "/rodada?id=" + quote(r["round"], safe="")
        to_ns = max(r["closed_ns"] or now_ns, r["start_ns"]) + 1_000_000_000
        from_ns = max(r["start_ns"], to_ns - MAX_HOURS * 3_600_000_000_000)
        return SESSOES + "?" + urlencode({"from": iso_utc(from_ns), "to": iso_utc(to_ns), "f_round": r["round"]})

    @screen("/rodadas")
    async def rounds(request: Request):
        """O histórico das rodadas (#601): toda rodada com evento de abertura na janela, com ou sem etapa publicada."""
        if (denied := await gate(request)) is not None:
            return denied
        q = request.query_params
        try:
            from_ns, to_ns = request_window(request)
            (st,) = table_states(q, etapas_mod.TABLE)
        except ValueError as e:
            return error(request, 400, str(e))
        rows, failed = await read(request, "lista de rodadas", store.read,
                                  lambda con: etapas_mod.listing(con, from_ns, to_ns, tabela_mod.ALL))
        if failed:
            return failed
        states, state_read = await proposal_state(request, "estado das rodadas", etapas_mod.round_states, [r["round"] for r in rows])
        now_ns = time.time_ns()
        for r in etapas_mod.with_state(rows, states):
            r["url"] = round_url(r, now_ns)
        (t,), keep = table_ctx(q, "/rodadas", (etapas_mod.TABLE, st, rows))
        return page(request, "rodadas.html", t=t, keep=keep, state_read=state_read, from_ns=from_ns, to_ns=to_ns, windows=WINDOWS,
                    **period(q, from_ns, to_ns, config.tz))

    def round_data(rnd):
        data = etapas_mod.load(store, surreal, rnd)
        if data is not None:
            etapas_mod.render(data["steps"])
            acoes_mod.collect(surreal, data)
        return data

    @screen("/rodada")
    async def round_page(request: Request):
        """Página da rodada: `/rodada?id=<rodada>`, com a barra de etapas e o texto de cada etapa."""
        if (denied := await gate(request)) is not None:
            return denied
        rnd = request.query_params.get("id", "")
        if not rnd:
            return error(request, 400, "Falta o id da rodada.")
        data, failed = await read(request, "rodada", round_data, rnd)
        if failed:
            return failed
        if data is None:
            return error(request, 404, "Rodada não encontrada.")
        if data["state_error"]:
            tel.warn("web-state-failed", "tela: estado das etapas (SurrealDB) falhou, segui com o DuckDB: %s",
                     data["state_error"], level=logging.ERROR)
        if data["acoes_error"]:
            tel.warn("web-state-failed", "tela: estado das ações (SurrealDB) falhou, segui sem ele: %s", data["acoes_error"],
                     level=logging.ERROR)
        # a marcação (#510): `enabled` = há credencial de marcação; `active` = este navegador tem o cookie dela (só então o formulário leva o `csrf`)
        mark = {"enabled": auth.mark, "active": auth.marker(request), "round": rnd, "csrf": auth.mark_csrf if auth.marker(request) else "",
                "read": data["acoes_read"]}
        return page(request, "rodada.html", r=data, bar=etapas_mod.bar(data["steps"]), state_read=data["state_read"], mark=mark)

    @screen("/ciclo")
    async def cycle_page(request: Request):
        """Página do ciclo (#509): `/ciclo?id=<dono>/<repo>#<n>`, o resumo do ciclo e as rodadas dele, com o link de cada uma."""
        if (denied := await gate(request)) is not None:
            return denied
        cycle = request.query_params.get("id", "")
        if not cycle:
            return error(request, 400, "Falta o id do ciclo.")
        if not etapas_mod.CYCLE_ID.match(cycle):
            return error(request, 400, "O id do ciclo tem de ser <dono>/<repo>#<número>.")   # nada do cliente na resposta
        data, failed = await read(request, "ciclo", etapas_mod.load_cycle, store, surreal, cycle)
        if failed:
            return failed
        if data is None:
            return error(request, 404, "Ciclo não encontrado.")
        if data["state_error"]:
            tel.warn("web-state-failed", "tela: estado do ciclo (SurrealDB) falhou, segui com o DuckDB: %s",
                     data["state_error"], level=logging.ERROR)
        if data["summary"] is not None:
            etapas_mod.render([data["summary"]])
        return page(request, "ciclo.html", c=data, state_read=data["state_read"])

    # ------------------------------------------------ marcar ação (#510): a única escrita do navegador além do login; só com a credencial de marcação
    if auth.mark:
        marcar_mod.mount(app, store, auth, tel, surreal, page, error, gate, safe_next, HEADERS)

    # ------------------------------------------------ preços (#340): só leitura
    @screen("/precos")
    async def prices(request: Request):
        if (denied := await gate(request)) is not None:
            return denied
        at_ns = time.time_ns()
        data, failed = await read(request, "preços", store.read, lambda con: prices_mod.view(con, config.fixed, at_ns))
        if failed:
            return failed
        return page(request, "prices.html", **prices_mod.decorate(data, at_ns))
