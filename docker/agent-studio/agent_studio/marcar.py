"""Marcar ação como feita na página da rodada (#510, ADR-08 "Página da rodada e do ciclo", exceção ao §10).

`POST /rodada/acao` é a **única escrita do navegador além do login e do logout**. Ela só grava a marca (uma linha de
`action_marks`, `marks.py`, e o `acao` derivado no SurrealDB): não faz o host rodar nada, não faz merge e não fecha issue (ADR-01
não muda). Só existe com a credencial de marcação configurada (`auth.mark`); sem ela, nem esta rota nem `/marcar` são registradas.

- **Quem pode:** só o cookie de marcação (`auth.marker`). Sem ele: 401 (nem leitura) ou 403 (com a credencial de leitura, em
  cookie ou `Bearer`: o agente a tem e alcança o studio pela rede docker). Depois da credencial, a conferência de `Origin`
  (igual ao `Host`, `https`; `http` só em loopback) e o campo oculto `csrf` (HMAC da credencial): 403 nos dois.
- **Corpo:** `application/x-www-form-urlencoded` de até 4 KB (acima: 413) com só `rodada`, `etapa` (`triagem`, `kaizen`,
  `fechamento` ou `merge:<pr>`), `acao` (o id da linha da seção `## Ações`), `estado` (`feita` ou `pendente`) e `csrf`. Nenhum
  campo de texto livre; campo a mais, a menos, repetido ou fora do formato = 400.
- **Só ação que existe** na revisão vigente da etapa (400 se a rodada, a etapa ou a ação não existe) e **que tem caixa** (ação
  que cita um pedido do canal não tem: 400).
- **2xx só depois do commit:** o `acao` do SurrealDB é gravado dentro da transação do DuckDB, antes do `COMMIT`; qualquer
  falha = 503 e nada fica (como a ingestão). A marca nunca vai ao bucket (D3=1).
- **Nada do cliente em log nem em resposta de erro:** as mensagens são fixas.
"""
import logging
from urllib.parse import parse_qs, quote, urlsplit

from fastapi import Request
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse

from . import acoes as acoes_mod, etapas as etapas_mod, marks, state

detail_log = logging.getLogger("agent_studio_detail")

MAX_BODY = 4096
FIELDS = frozenset({"rodada", "etapa", "acao", "estado", "csrf"})
LOOPBACK = frozenset({"localhost", "127.0.0.1", "::1"})


def origin_ok(request):
    """`Origin` presente e igual ao `Host` do pedido (o navegador manda os dois; outro site não escolhe o `Host` de quem o abre).
    `https` sempre; `http` só em loopback (uso local e testes). Sem `Origin`, recusa."""
    origin, host = request.headers.get("origin", ""), request.headers.get("host", "").lower()
    if not origin or not host:
        return False
    try:
        u = urlsplit(origin)
        hostname = u.hostname
    except ValueError:
        return False
    if u.netloc.lower() != host or u.path or u.query or u.fragment or u.username is not None:
        return False
    return u.scheme == "https" or (u.scheme == "http" and hostname in LOOPBACK)


async def read_form(request):
    """Corpo do formulário (até `MAX_BODY`) -> `{campo: [valores]}`; `"grande"` se passa do teto; `None` se não é formulário."""
    body = b""
    async for chunk in request.stream():
        body += chunk
        if len(body) > MAX_BODY:
            return "grande"
    if request.headers.get("content-type", "").split(";")[0].strip().lower() != "application/x-www-form-urlencoded":
        return None
    try:
        return parse_qs(body.decode("utf-8"), keep_blank_values=True, max_num_fields=20)
    except (UnicodeDecodeError, ValueError):
        return None


def parse_fields(form):
    """O formulário de marcar -> `(rodada, tipo, chave, id da ação, estado, csrf)`, ou `None` se algum campo falta, sobra ou foge
    do formato."""
    if not isinstance(form, dict) or set(form) != FIELDS or any(len(v) != 1 for v in form.values()):
        return None
    rodada, etapa, acao, estado, csrf = (form[k][0] for k in ("rodada", "etapa", "acao", "estado", "csrf"))
    kind, _, key = etapa.partition(":")
    if (not etapas_mod.ROUND_ID.match(rodada) or kind not in etapas_mod.ROUND_KINDS or (kind == "merge") != bool(key)
            or (key and not state.STEP_KEY.match(key)) or not acoes_mod.ID.match(acao) or estado not in marks.STATES):
        return None
    return rodada, kind, key, acao, estado, csrf


def mount(app, store, auth, tel, surreal, page, error, gate, safe_next, headers):
    """Liga `GET/POST /marcar` e `POST /rodada/acao`. Só é chamado com a credencial de marcação configurada."""

    def refuse(status, message):
        return JSONResponse({"message": message}, status_code=status, headers=headers)

    @app.get("/marcar")
    async def mark_form(request: Request):
        if (denied := await gate(request)) is not None:
            return denied
        return page(request, "marcar.html", next=safe_next(request.query_params.get("next")), failed=False, active=auth.marker(request))

    @app.post("/marcar")
    async def mark_login(request: Request):
        """Cola a credencial de marcação uma vez por aparelho: o cookie próprio (`SameSite=Strict`)."""
        if not auth.reader(request):
            return refuse(401, "unauthorized")
        if not origin_ok(request):
            tel.warn("mark-origin", "recusado: origem da entrada de marcação")
            return refuse(403, "forbidden")
        form = await read_form(request)
        if form == "grande":
            return error(request, 413, "Pedido grande demais.")
        form = form or {}
        target = safe_next((form.get("next") or [""])[0])
        if not auth.mark_token_ok((form.get("token") or [""])[0].strip()):
            tel.warn("mark-unauthorized", "recusado: credencial de marcação errada (entrada)")
            return page(request, "marcar.html", 401, next=target, failed=True, active=False)
        resp = RedirectResponse(target, status_code=303, headers=headers)
        auth.set_mark_cookie(resp)
        return resp

    @app.post("/rodada/acao")
    async def mark_action(request: Request):
        # 1. quem: só o cookie de marcação. A credencial de leitura (o agente a tem) é 403; sem nada, 401
        if not auth.marker(request):
            if auth.reader(request):
                tel.warn("mark-forbidden", "recusado: credencial de leitura na marcação")
                return refuse(403, "forbidden")
            tel.warn("mark-unauthorized", "recusado: sem credencial de marcação")
            return refuse(401, "unauthorized")
        # 2. de onde: Origin igual ao Host
        if not origin_ok(request):
            tel.warn("mark-origin", "recusado: Origin da marcação ausente ou diferente do Host")
            return refuse(403, "forbidden")
        # 3. o corpo: teto, formato e campos
        form = await read_form(request)
        if form == "grande":
            tel.warn("mark-too-large", "recusado: marcação com corpo acima de %d bytes", MAX_BODY)
            return refuse(413, "corpo grande demais")
        fields = parse_fields(form)
        if fields is None:
            tel.warn("mark-bad", "recusado: marcação com campos fora do formato")
            return refuse(400, "campos inválidos")
        rodada, kind, key, action_id, estado, csrf = fields
        if not auth.csrf_ok(csrf):
            tel.warn("mark-csrf", "recusado: campo csrf da marcação errado")
            return refuse(403, "forbidden")
        # 4. a ação existe na revisão vigente e tem caixa
        try:
            data = await run_in_threadpool(etapas_mod.load, store, surreal, rodada)
        except Exception as e:  # noqa: BLE001 — a causa só no stderr
            tel.warn("mark-failed", "marcação: leitura da rodada falhou, respondi 503: %s", type(e).__name__, level=logging.ERROR)
            detail_log.exception("marcação: leitura da rodada falhou")
            return JSONResponse({"message": "leitura falhou; tente de novo"}, status_code=503, headers={**headers, "Retry-After": "5"})
        action = find_action(data, kind, key, action_id)
        if action is None or action["pedido"]:
            tel.warn("mark-unknown", "recusado: marcação de ação que não existe ou não tem caixa")
            return refuse(400, "ação inexistente")
        # 5. grava: DuckDB e SurrealDB juntos ou nenhum; 2xx só depois do commit
        def write(con):
            row = marks.append(con, rodada, kind, key, action_id, estado)
            if surreal is not None:
                surreal.apply(state.mark_statements(row))
            return row
        try:
            await run_in_threadpool(store.transact, write)
        except Exception as e:  # noqa: BLE001 — qualquer falha na gravação é retentável
            tel.warn("mark-failed", "marcação: gravação falhou, respondi 503: %s", type(e).__name__, level=logging.ERROR)
            detail_log.exception("marcação: gravação falhou")
            return JSONResponse({"message": "gravação falhou; tente de novo"}, status_code=503, headers={**headers, "Retry-After": "5"})
        # só valores já conferidos acima voltam na resposta
        etapa = kind + (f":{key}" if key else "")
        if "application/json" in request.headers.get("accept", ""):
            return JSONResponse({"rodada": rodada, "etapa": etapa, "acao": action_id, "estado": estado}, headers=headers)
        back = f"/rodada?id={quote(rodada, safe='')}#{etapas_mod.anchor({'kind': kind, 'key': key})}"
        return page(request, "marcado.html", back=back, action=action_id, marked=estado)


def find_action(data, kind, key, action_id):
    """A ação `action_id` da revisão vigente da etapa (`kind`, `key`) de `etapas.load`, ou `None` (rodada, etapa, texto ou ação
    que não existe)."""
    if data is None:
        return None
    step = next((s for s in data["steps"] if s["kind"] == kind and (s["key"] or "") == key), None)
    if step is None or not isinstance(step.get("text"), str):
        return None
    return next((a for a in acoes_mod.extract(etapas_mod.parse(step["text"])) if a["id"] == action_id), None)
