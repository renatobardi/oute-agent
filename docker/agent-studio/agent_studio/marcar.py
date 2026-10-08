"""Marcar ação como feita na página da rodada (#510, ADR-08 "Página da rodada e do ciclo", exceção ao §10).

`POST /rodada/acao`, `POST /ack` (#537, abaixo) e `POST /fase` (#749, no fim) são as **únicas escritas do navegador além do login e do logout**. A primeira só grava a marca (uma linha de
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

**`POST /ack` (#537, ADR-08 §10, adendo do ack):** só reconhece ("visto") um alerta ou uma decisão pendente. Não resolve alerta,
não responde pergunta, não fecha gate, não faz o host rodar nada e não escreve em `action_marks`. A mesma credencial, o mesmo
`Origin` e o mesmo `csrf`; sem a credencial de marcação a rota não existe.

- **Corpo:** os campos `alvo` (32 hex: a referência do item, `acks.py`), `desde` (o `since` que a página mostrou), `visto` (a
  hora em que a página foi montada, ns), `voltar` (caminho deste servidor, para onde o 303 leva) e `csrf`; fora disso = 400.
- **Só item vigente:** o servidor recalcula os alertas e as decisões pendentes e procura o alvo: sem ele, ou sem `since`, 400.
  Com o alvo mas outra ocorrência (formulário antigo: `acks.same` entre o que a página mostrou e o de agora), 409.
- **O servidor calcula tudo:** identidade, versão, hora e prazo (24 h). O navegador não escolhe quem marcou nem o prazo.
- **Repetir não renova:** com um ack ainda válido para a ocorrência, nada é acrescentado e a resposta é a do ack que já vale.
- **2xx só depois do commit**, como acima: falha = 503 e nada fica; tentar de novo não renova ack nenhum.

**`POST /fase` (#749, ADR-08 "Fase da conversa"):** troca a fase de uma conversa (a tela `/fases`). Grava uma linha em `phase_marks` (só
de acréscimo) e reclassifica a conversa: a troca (origem `manual`, confiança alta) vale sobre a classificação automática, também
depois de um `rebuild-state`. Não faz o host rodar nada. A mesma credencial, o mesmo `Origin` e o mesmo `csrf`.

- **Corpo:** `conversa` (o `session.id`, até 128 caracteres de `[A-Za-z0-9._:-]`), `fase` (uma das 12 do ADR-07) e `csrf`.
- **Só conversa que existe** na `conversation_phase` (400 se não); fase fora das 12 = 400.
"""
import logging
import re
import time
from urllib.parse import parse_qs, quote, urlsplit

from fastapi import Request
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse

from . import acks, acoes as acoes_mod, etapas as etapas_mod, marks, phase as phase_mod, state

detail_log = logging.getLogger("agent_studio_detail")

MAX_BODY = 4096
FIELDS = frozenset({"rodada", "etapa", "acao", "estado", "csrf"})
LOOPBACK = frozenset({"localhost", "127.0.0.1", "::1"})
ACK_FIELDS = frozenset({"alvo", "desde", "visto", "voltar", "csrf"})
ACK_SEEN = re.compile(r"^[0-9]{1,20}\Z")
ACK_BACK_MAX = 1024
PHASE_FIELDS = frozenset({"conversa", "fase", "csrf"})
CONV_ID = re.compile(r"^[A-Za-z0-9._:-]{1,128}\Z", re.ASCII)


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


def parse_ack(form):
    """O formulário do ack -> `(alvo, desde, visto em ns, voltar, csrf)`, ou `None` se algum campo falta, sobra ou foge do
    formato."""
    if not isinstance(form, dict) or set(form) != ACK_FIELDS or any(len(v) != 1 for v in form.values()):
        return None
    alvo, desde, visto, voltar, csrf = (form[k][0] for k in ("alvo", "desde", "visto", "voltar", "csrf"))
    if not acks.TARGET.match(alvo) or not acks.SINCE.match(desde) or not ACK_SEEN.match(visto) or len(voltar) > ACK_BACK_MAX:
        return None
    return alvo, desde, int(visto), voltar, csrf


def parse_phase(form):
    """O formulário da troca de fase -> `(conversa, fase, csrf)`, ou `None` se algum campo falta, sobra ou foge do formato."""
    if not isinstance(form, dict) or set(form) != PHASE_FIELDS or any(len(v) != 1 for v in form.values()):
        return None
    conv, fase, csrf = (form[k][0] for k in ("conversa", "fase", "csrf"))
    if not CONV_ID.match(conv) or fase not in phase_mod.PHASES:
        return None
    return conv, fase, csrf


def mount(app, store, auth, tel, surreal, page, error, gate, safe_next, headers, ack_items=None):
    """Liga `GET/POST /marcar`, `POST /rodada/acao` e `POST /ack`. Só é chamado com a credencial de marcação configurada.
    `ack_items()` = os itens vigentes das faixas (`acks.alert_item`/`decision_item`); levanta se a leitura falhar."""

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


    def retry(message):
        return JSONResponse({"message": message}, status_code=503, headers={**headers, "Retry-After": "5"})

    @app.post("/ack")
    async def ack(request: Request):
        # 1. quem: só o cookie de marcação, como no `/rodada/acao`
        if not auth.marker(request):
            if auth.reader(request):
                tel.warn("ack-forbidden", "recusado: credencial de leitura no ack")
                return refuse(403, "forbidden")
            tel.warn("ack-unauthorized", "recusado: sem credencial de marcação no ack")
            return refuse(401, "unauthorized")
        # 2. de onde: Origin igual ao Host
        if not origin_ok(request):
            tel.warn("ack-origin", "recusado: Origin do ack ausente ou diferente do Host")
            return refuse(403, "forbidden")
        # 3. o corpo: teto, formato e campos
        form = await read_form(request)
        if form == "grande":
            tel.warn("ack-too-large", "recusado: ack com corpo acima de %d bytes", MAX_BODY)
            return refuse(413, "corpo grande demais")
        fields = parse_ack(form)
        if fields is None:
            tel.warn("ack-bad", "recusado: ack com campos fora do formato")
            return refuse(400, "campos inválidos")
        target, shown_since, shown_ns, back, csrf = fields
        if not auth.csrf_ok(csrf):
            tel.warn("ack-csrf", "recusado: campo csrf do ack errado")
            return refuse(403, "forbidden")
        # 4. o item existe agora, dá para reconhecer e é a ocorrência que a página mostrou
        try:
            items = await ack_items()
        except Exception as e:  # noqa: BLE001 — a causa só no stderr
            tel.warn("ack-failed", "ack: leitura dos alertas e das decisões falhou, respondi 503: %s", type(e).__name__, level=logging.ERROR)
            detail_log.exception("ack: leitura dos itens falhou")
            return retry("leitura falhou; tente de novo")
        item = next((i for i in items if i["target"] == target and i["since"]), None)
        if item is None:
            tel.warn("ack-unknown", "recusado: ack de item que não está vigente")
            return refuse(400, "item inexistente")
        if shown_ns > time.time_ns() or not acks.same(item["kind"], shown_since, shown_ns, item["since"]):
            tel.warn("ack-stale", "recusado: ack de formulário antigo (a ocorrência mudou)")
            return refuse(409, "a ocorrência mudou; recarregue a página")
        # 5. grava: DuckDB e SurrealDB juntos ou nenhum; 2xx só depois do commit. Ack ainda válido não é renovado
        def write(con):
            row = acks.last(con, target)
            new = row is None or not acks.valid(acks.as_mark(row), item, time.time_ns())
            if new:
                row = acks.append(con, item)
            if surreal is not None:
                surreal.apply(state.ack_statements(row))
            return row, new
        try:
            row, new = await run_in_threadpool(store.transact, write)
        except Exception as e:  # noqa: BLE001 — qualquer falha na gravação é retentável
            tel.warn("ack-failed", "ack: gravação falhou, respondi 503: %s", type(e).__name__, level=logging.ERROR)
            detail_log.exception("ack: gravação falhou")
            return retry("gravação falhou; tente de novo")
        # só valores do servidor voltam na resposta
        if "application/json" in request.headers.get("accept", ""):
            return JSONResponse({"alvo": row["target"], "visto_em": state.iso(row["acked_unix_nano"]),
                                 "vale_ate": state.iso(row["expires_unix_nano"]), "novo": new}, headers=headers)
        return RedirectResponse(safe_next(back), status_code=303, headers=headers)

    @app.post("/fase")
    async def change_phase(request: Request):
        # 1. quem: só o cookie de marcação, como no `/rodada/acao`
        if not auth.marker(request):
            if auth.reader(request):
                tel.warn("phase-forbidden", "recusado: credencial de leitura na troca de fase")
                return refuse(403, "forbidden")
            tel.warn("phase-unauthorized", "recusado: sem credencial de marcação na troca de fase")
            return refuse(401, "unauthorized")
        # 2. de onde: Origin igual ao Host
        if not origin_ok(request):
            tel.warn("phase-origin", "recusado: Origin da troca de fase ausente ou diferente do Host")
            return refuse(403, "forbidden")
        # 3. o corpo: teto, formato e campos
        form = await read_form(request)
        if form == "grande":
            tel.warn("phase-too-large", "recusado: troca de fase com corpo acima de %d bytes", MAX_BODY)
            return refuse(413, "corpo grande demais")
        fields = parse_phase(form)
        if fields is None:
            tel.warn("phase-bad", "recusado: troca de fase com campos fora do formato")
            return refuse(400, "campos inválidos")
        conv, fase, csrf = fields
        if not auth.csrf_ok(csrf):
            tel.warn("phase-csrf", "recusado: campo csrf da troca de fase errado")
            return refuse(403, "forbidden")
        # 4. grava: DuckDB e SurrealDB juntos ou nenhum; 2xx só depois do commit. Só conversa que já tem fase classificada
        def write(con):
            if phase_mod.phase_of(con, conv) is None:
                return None
            res = phase_mod.mark(con, conv, fase, time.time_ns())
            if surreal is not None and res:
                surreal.apply([s for s in state.phase_statements(conv, res["phase"], res["origin"], res["confidence"])])
            return res
        try:
            res = await run_in_threadpool(store.transact, write)
        except Exception as e:  # noqa: BLE001 — qualquer falha na gravação é retentável
            tel.warn("phase-failed", "troca de fase: gravação falhou, respondi 503: %s", type(e).__name__, level=logging.ERROR)
            detail_log.exception("troca de fase: gravação falhou")
            return retry("gravação falhou; tente de novo")
        if res is None:
            tel.warn("phase-unknown", "recusado: troca de fase de conversa que não existe")
            return refuse(400, "conversa inexistente")
        # só valores já conferidos voltam na resposta
        if "application/json" in request.headers.get("accept", ""):
            return JSONResponse({"conversa": conv, "fase": res["phase"], "origem": res["origin"], "confianca": res["confidence"]}, headers=headers)
        return RedirectResponse("/fases?trocada=" + quote(conv, safe=""), status_code=303, headers=headers)


def find_action(data, kind, key, action_id):
    """A ação `action_id` da revisão vigente da etapa (`kind`, `key`) de `etapas.load`, ou `None` (rodada, etapa, texto ou ação
    que não existe)."""
    if data is None:
        return None
    step = next((s for s in data["steps"] if s["kind"] == kind and (s["key"] or "") == key), None)
    if step is None or not isinstance(step.get("text"), str):
        return None
    return next((a for a in acoes_mod.extract(etapas_mod.parse(step["text"])) if a["id"] == action_id), None)
