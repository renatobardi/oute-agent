"""Agregação de uso (ADR-08 §9, #203): custo real, de lista calculado (#747) e estimado, tokens, erros, p95 e série diária, com
qualquer agrupamento de `day`/`host`/`agent`/`model`/`conversation`/`session`. Tudo pela **hora do fato** (`time_unix_nano`), nunca pela de chegada;
dia no fuso configurado (#415: a meia-noite do fuso, não a do UTC; só a leitura converte). As regras de escopo e de custo estão no `cost.py`.

Papel e fase da conversa (#433, #749): `role` = dispatcher, worker ou standalone (a sessão avulsa), dos eventos `oute.task.opened`/`reopened` da sessão
(`oute.swarm.round`/`oute.swarm.session`) ou, sem eles, do resource da chamada. `phase` = **sempre uma fase do ADR-07**: a da
conversa em `conversation_phase` (o `phase.py` a deriva: abertura, label, skill, papel, ação, Jev ou troca do Bardi), a da abertura da
sessão se a conversa ainda não foi classificada, `build` (a mais provável) se nem isso, e `ops` para o fato sem conversa (ex.: o
LLM do ai-memory). Nunca `desconhecida` nem `interativa`; a chamada nunca some do total.

`aggregate` é a peça reusável (alertas #204, tray #205, tela #206 e #207); `usage` monta a resposta do `/v1/usage`.
"""
from . import phase as phase_mod, rateio, repo as repo_mod, subscription as sub_mod, tz as tz_mod
from .tabela import Col, Table, usage_cols
from .cost import (LOG_SEVERITY_ERROR, MODEL_CALL_PARAMS, MODEL_CALL_SQL, SPAN_STATUS_ERROR,
                   SUBSCRIPTION_EXPR, SUBSCRIPTION_SQL, estimate_cost_usd, window_spans_with_cost)

DAY_NS = 86_400_000_000_000


_TABLE_SUFFIX = {"role": "_papel", "phase": "_fase", "subscription": "_assinatura"}


def _table(kind):
    # as tabelas por papel, por fase e por assinatura (#679) da tela (#529): só a ordem (sem filtro nem página); a de sempre é a do que mais custou
    return Table([Col("name", "text", lambda r: r[kind]), *usage_cols(lambda r: r, detail=False)], default=("cost", "desc"),
                 suffix=_TABLE_SUFFIX[kind], paginate=False)


ROLE_TABLE, PHASE_TABLE, SUBSCRIPTION_TABLE = _table("role"), _table("phase"), _table("subscription")
NO_SUBSCRIPTION = "sem assinatura"  # a chamada que não é de assinatura nenhuma (ex.: o LLM do ai-memory), só na exibição
KEYS = ("day", "host", "agent", "model", "conversation", "session", "role", "phase", "repo", "subscription")
ROLES = ("dispatcher", "worker", "standalone")
# conversation = `session.id` (a conversa do agente, CONTEXT.md), para a tela (#206);
# session = `oute.task.id` (a sessão do `oute-task`), para a tela de sessões (#207)
_COLS = {"host": "host_name", "agent": "oute_agent",
         "model": "model", "conversation": "session_id", "session": "oute_task_id", "role": "role", "phase": "phase",
         "repo": repo_mod.COL, "subscription": SUBSCRIPTION_EXPR}
_PER_SESSION = {"role", "phase"}
# logs não têm modelo: agrupados por modelo, caem no modelo nulo
_LOG_MODEL = {"model": "CAST(NULL AS VARCHAR)"}
_WINDOW = "time_unix_nano >= ? AND time_unix_nano < ?"


def _cols(tz, extra=None):
    """Colunas de agrupamento. `day` = a data local no fuso `tz` (`ZoneInfo`) da hora do fato: o nome vem do `zoneinfo`
    (validado em `tz.parse`) e vai literal no SQL, o ICU do DuckDB faz a conversão, inclusive para dias antigos."""
    return {"day": f"CAST({local_expr(tz)} AS DATE)", **_COLS, **(extra or {})}


def local_expr(tz):
    """A hora do fato (`time_unix_nano`) como TIMESTAMP no fuso `tz`: base do dia aqui e das horas do dashboard (#469)."""
    return f"timezone('{tz.key}', make_timestamp_ns(CAST(time_unix_nano AS BIGINT)) AT TIME ZONE 'UTC')"


# papel e fase da abertura por sessão, dos eventos de abertura (valores fixos no SQL; nada vem de entrada). Fase fora de `[a-z]{2,16}`
# não vale (é só o nome de uma fase do ADR-07); a primeira fase conhecida fica. A fase que vale vem da conversa (`phase.sql_phase`)
_SESSION_INFO = (
    "(SELECT oute_task_id AS task, "
    "CASE WHEN count(*) FILTER (WHERE json_extract_string(attributes, '$.\"oute.swarm.session\"') IS NOT NULL) > 0 "
    "THEN 'worker' WHEN count(oute_swarm_round) > 0 THEN 'dispatcher' ELSE 'standalone' END AS role, "
    "arg_min(phase, time_unix_nano) FILTER (WHERE regexp_full_match(phase, '[a-z]{2,16}')) AS phase "
    "FROM (SELECT *, json_extract_string(attributes, '$.\"oute.task.phase\"') AS phase FROM logs "
    "WHERE event_name IN ('oute.task.opened', 'oute.task.reopened') AND oute_task_id IS NOT NULL) GROUP BY oute_task_id)")
# sem evento da sessão: o papel sai do resource da própria chamada
_SCOPE = (f"(SELECT t.*, COALESCE(i.role, CASE WHEN json_extract_string(t.resource_attributes, "
          "'$.\"oute.swarm.session\"') IS NOT NULL THEN 'worker' WHEN t.oute_swarm_round IS NOT NULL THEN 'dispatcher' "
          f"ELSE 'standalone' END) AS role, {phase_mod.sql_phase()} AS phase "
          f"FROM @TABLE@ t LEFT JOIN {_SESSION_INFO} i ON i.task = t.oute_task_id "
          "LEFT JOIN conversation_phase cp ON cp.conversation = t.session_id)")


def _scope(table, keys):
    """`table` com as colunas `role` e `phase`, só quando alguma chave pede (as outras consultas não pagam a junção)."""
    return _SCOPE.replace("@TABLE@", table) if _PER_SESSION & set(keys) else table


def _query(con, keys, cols, aggs, table, where, params):
    """Linhas como dict; sem chaves, uma linha só (total). `table` = nome ou subconsulta (os parâmetros dela vêm
    antes dos de `where` em `params`)."""
    select = [f"{cols[k]} AS {k}" for k in keys] + aggs
    group = " GROUP BY ALL" if keys else ""
    cur = con.execute(f"SELECT {', '.join(select)} FROM {table} WHERE {where}{group}", params)
    names = [d[0] for d in cur.description]
    return [dict(zip(names, r)) for r in cur.fetchall()]


def _epoch_col(prices):
    """Faixa de preço de cada chamada (#339): quantas trocas de preço (`PriceTable.boundaries`) já tinham acontecido na
    hora do fato. Dentro de uma faixa nenhum preço muda; as horas vão no SQL como inteiros (vêm do nosso banco)."""
    bounds = prices.boundaries()
    if not bounds:
        return "0"
    return f"len(list_filter([{', '.join(str(int(b)) for b in bounds)}]::UBIGINT[], x -> x <= time_unix_nano))"


def _calls(con, keys, from_ns, to_ns, prices, tz, repo=None, sub=None):
    aggs = ["count(*) AS calls", "count(cost_usd) AS calls_real", "sum(cost_usd) AS cost_real"]
    for t in ("input", "output", "cache_read", "cache_creation"):
        aggs.append(f"COALESCE(sum({t}_tokens), 0) AS {t}")
        aggs.append(f"COALESCE(sum({t}_tokens) FILTER (WHERE cost_usd IS NULL), 0) AS est_{t}")
    # custo efetivo (o do span ou o do log `api_request`, #157): a regra está no `cost.spans_with_cost`
    rsql, rparams = sub_mod.scope(repo, sub)
    table, params = window_spans_with_cost(from_ns, to_ns, rsql, rparams)
    # `sub` sempre (não só no pago, #531): a chamada de assinatura sem custo real é custo de lista calculado, não
    # estimado (#747), e a diferença se decide por grupo de assinatura
    # `subname` (#747): qual assinatura, para contar à parte o `claude` sem o log de custo
    extra = {"epoch": _epoch_col(prices), "sub": SUBSCRIPTION_SQL, "subname": SUBSCRIPTION_EXPR}
    return _query(con, (*keys, "epoch", "sub", "subname"), _cols(tz, extra), aggs, _scope(table, keys), MODEL_CALL_SQL,
                  [*params, *MODEL_CALL_PARAMS])


def _p95(con, keys, from_ns, to_ns, tz, repo=None, sub=None):
    rsql, rparams = sub_mod.scope(repo, sub)
    return _query(con, keys, _cols(tz), ["quantile_cont(CAST(duration_ns AS DOUBLE), 0.95) / 1e6 AS p95"], _scope("spans", keys),
                  f"{_WINDOW} AND duration_ns IS NOT NULL AND {MODEL_CALL_SQL}{rsql}", [from_ns, to_ns, *MODEL_CALL_PARAMS, *rparams])


def _spans(con, keys, from_ns, to_ns, tz, repo=None, sub=None):
    """Todos os spans (o denominador da taxa de erro) e os com status de erro."""
    rsql, rparams = sub_mod.scope(repo, sub)
    return _query(con, keys, _cols(tz), ["count(*) AS spans", "count(*) FILTER (WHERE status_code = ?) AS n"], _scope("spans", keys),
                  f"{_WINDOW}{rsql}", [SPAN_STATUS_ERROR, from_ns, to_ns, *rparams])


def _log_errors(con, keys, from_ns, to_ns, tz, repo=None, sub=None):
    rsql, rparams = sub_mod.scope(repo, sub)
    return _query(con, keys, _cols(tz, _LOG_MODEL), ["count(*) AS n"], _scope("logs", keys), f"{_WINDOW} AND severity_number >= ?{rsql}",
                  [from_ns, to_ns, LOG_SEVERITY_ERROR, *rparams])


def _empty():
    return {"calls": 0, "tokens": dict.fromkeys(("input", "output", "cache_read", "cache_creation"), 0),
            "real_usd": None, "listed_usd": None, "estimated_usd": None,
            "real_calls": 0, "listed_calls": 0, "claude_no_log_calls": 0, "estimated_calls": 0, "unpriced_calls": 0,
            "unpriced_models": set(), "no_plan_calls": 0, "spans": 0, "span_errors": 0, "log_errors": 0, "p95": None}


def _add(a, b):
    return b if a is None else a + b


def _list_cost(rec, prices, at_ns):
    """Custo de lista do grupo `rec`: o informado pela fonte mais o calculado pela tabela para o que veio sem custo
    (sem preço = 0). É o peso da chamada no rateio do plano (#748)."""
    total = rec["cost_real"] or 0.0
    if rec["calls"] - rec["calls_real"]:
        est = estimate_cost_usd(rec["est_input"], rec["est_output"], rec["est_cache_read"], rec["est_cache_creation"],
                                prices.lookup(rec["model"], at_ns(rec["epoch"])))
        total += est or 0.0
    return total


def _add_call(a, rec, prices, at_ns, alloc):
    """Soma o grupo de chamadas `rec` (mesmo modelo, faixa de preço, dia e assinatura) no acumulador `a`. `alloc` (`rateio.Alloc`)
    só no custo pago."""
    a["calls"] += rec["calls"]
    for t in a["tokens"]:
        a["tokens"][t] += rec[t]
    if alloc is not None and rec["sub"]:
        # assinatura no custo pago (#748): a parte do valor do plano do dia (fica entre as "com custo": sem cálculo e sem "sem
        # preço"); a soma de `real_calls`, `listed_calls`, `estimated_calls` e `unpriced_calls` segue igual a `calls`
        share = alloc.share(rec["day"], rec["subname"], _list_cost(rec, prices, at_ns), rec["calls"])
        if share is None:
            a["no_plan_calls"] += rec["calls"]  # sem plano naquele dia: conta 0 e é dito na tela
            share = 0.0
        a["real_calls"] += rec["calls"]
        a["real_usd"] = _add(a["real_usd"], share)
        return
    a["real_calls"] += rec["calls_real"]
    if rec["cost_real"] is not None:
        a["real_usd"] = _add(a["real_usd"], rec["cost_real"])
    pending = rec["calls"] - rec["calls_real"]
    if not pending:
        return
    est = estimate_cost_usd(rec["est_input"], rec["est_output"], rec["est_cache_read"], rec["est_cache_creation"],
                            prices.lookup(rec["model"], at_ns(rec["epoch"])))
    if est is None:
        a["unpriced_calls"] += pending
        a["unpriced_models"].add(rec["model"])
    elif rec["sub"]:
        # chamada de assinatura sem custo real (#747): custo de lista calculado pela tabela, sem a marca "estimado ≈"
        a["listed_calls"] += pending
        if rec["subname"] == "claude":
            a["claude_no_log_calls"] += pending  # o Claude Code não mandou o log `api_request` com o custo
        a["listed_usd"] = _add(a["listed_usd"], est)
    else:
        a["estimated_calls"] += pending
        a["estimated_usd"] = _add(a["estimated_usd"], est)


def _price_epochs(prices):
    bounds = prices.boundaries()

    def at_ns(epoch):
        # qualquer hora da faixa serve (nenhum preço muda dentro dela): o início dela; a faixa 0 é "desde sempre"
        return bounds[epoch - 1] if epoch else 0
    return at_ns


def paid_alloc(con, from_ns, to_ns, prices, tz=tz_mod.UTC):
    """O rateio do plano (`rateio.Alloc`, #748) para a janela: o peso de cada (dia, assinatura) vem dos dias **inteiros** que a
    janela toca e de todas as chamadas da assinatura, sem filtro de repositório nem de assinatura."""
    prices = prices.snapshot()
    alloc = rateio.Alloc(rateio.Plan.load(con))
    span = rateio.day_bounds(from_ns, to_ns, tz)
    if span is None:
        return alloc
    at_ns = _price_epochs(prices)
    for rec in _calls(con, ("day", "model"), span[0], span[1], prices, tz):
        if rec["sub"]:
            alloc.add_weight(rec["day"], rec["subname"], _list_cost(rec, prices, at_ns), rec["calls"])
    return alloc


def _fine_keys(keys, alloc):
    """Chaves da leitura fina: as pedidas, o modelo (preço) e, no custo pago, o dia (o rateio é por dia)."""
    fine = keys if "model" in keys else keys + ("model",)
    return fine + ("day",) if alloc is not None and "day" not in fine else fine


def _add_idle(groups, keys, alloc, window, tz, repo, sub):
    """Põe em `groups` o "sem uso" (#748) do custo pago; sem rateio ou com filtro de repositório, nada."""
    if alloc is None or repo is not None:
        return
    for day, name, usd in alloc.idle(window[0], window[1], tz, sub):
        a = groups.setdefault(tuple(_idle_key(k, day, name) for k in keys), _empty())
        a["real_usd"] = _add(a["real_usd"], usd)


def _idle_key(k, day, name):
    if k == "day":
        return day
    return name if k == "subscription" else rateio.NO_USE


def aggregate(con, from_ns, to_ns, prices, keys=("host", "agent", "model"), tz=tz_mod.UTC, p95=True, repo=None, paid=False, sub=None, alloc=None):
    """{tupla das chaves: acumulador} na janela [from_ns, to_ns). O custo estimado é calculado por modelo e
    depois somado; sem `model` nas chaves, o agrupamento fino inclui o modelo e sobe para `keys`. O preço é o que valia
    na **hora do fato** de cada chamada (`PriceTable`, #339): o agrupamento fino também separa as faixas entre trocas.
    `p95=False` pula o p95 (ele não soma entre grupos: quem reagrupa o lê à parte, com `fill_p95`). `repo` (#528) =
    só os fatos desse repositório (`repo.NONE` = os sem repositório); `None` = todos. `sub` (#679) = só as chamadas dessa assinatura (`subscription.py`); `None` = todas.
    Sem custo real, a chamada de assinatura vira **custo de lista calculado** (`listed_*`, #747) e as outras viram estimado (`estimated_*`).
    `paid=True` (#531, custo pago; rateado desde o #748): a chamada de assinatura (`cost.SUBSCRIPTION_SQL`, a regra de `cost.is_subscription`) recebe a sua
    parte do valor do plano do dia (`rateio.py`; entra no `real_*`, sem estimativa), e o dia com plano e sem chamada da assinatura vira um grupo "sem uso"
    (`rateio.NO_USE` em toda chave que não é o dia nem a assinatura; sem ele a soma não fecha com a mensalidade; só sem filtro de repositório); `alloc` = o
    `paid_alloc` já calculado, se quem chama já o tem. Chamadas, tokens, erros e p95 não mudam. Padrão `False` = custo de lista, o que a API e o tray sempre devolvem."""
    keys = tuple(keys)
    if set(keys) - set(KEYS):
        raise ValueError(f"chave inválida: {keys}")
    prices = prices.snapshot()  # uma versão da tabela do começo ao fim, mesmo se a rotina de preços trocar no meio
    at_ns = _price_epochs(prices)
    groups = {} if keys else {(): _empty()}
    alloc = (alloc or paid_alloc(con, from_ns, to_ns, prices, tz)) if paid else None

    def acc(rec):
        return groups.setdefault(tuple(rec[k] for k in keys), _empty())

    fine = _fine_keys(keys, alloc)
    for rec in _calls(con, fine, from_ns, to_ns, prices, tz, repo, sub):
        _add_call(acc(rec), rec, prices, at_ns, alloc)
    _add_idle(groups, keys, alloc, (from_ns, to_ns), tz, repo, sub)
    if p95:
        fill_p95(con, groups, keys, from_ns, to_ns, tz, repo, sub)
    for rec in _spans(con, keys, from_ns, to_ns, tz, repo, sub):
        a = acc(rec)
        a["spans"] += rec["spans"]
        a["span_errors"] += rec["n"]
    for rec in _log_errors(con, keys, from_ns, to_ns, tz, repo, sub):
        if rec["n"]:
            acc(rec)["log_errors"] += rec["n"]
    return groups


def fill_p95(con, groups, keys, from_ns, to_ns, tz=tz_mod.UTC, repo=None, sub=None):
    """Põe em cada grupo de `groups` (as chaves `keys`) o p95 das chamadas dele; consulta sem a junção com os logs de custo."""
    for rec in _p95(con, keys, from_ns, to_ns, tz, repo, sub):
        if rec["p95"] is not None:
            groups.setdefault(tuple(rec[k] for k in keys), _empty())["p95"] = rec["p95"]
    return groups


def merge(into, a):
    """Soma o acumulador `a` em `into` (o `p95` não soma: quem precisa dele o lê à parte)."""
    for k in ("calls", "real_calls", "listed_calls", "claude_no_log_calls", "estimated_calls", "unpriced_calls", "no_plan_calls", "spans", "span_errors", "log_errors"):
        into[k] += a[k]
    for t in into["tokens"]:
        into["tokens"][t] += a["tokens"][t]
    for k in ("real_usd", "listed_usd", "estimated_usd"):
        if a[k] is not None:
            into[k] = a[k] if into[k] is None else into[k] + a[k]
    into["unpriced_models"] |= a["unpriced_models"]
    return into


def regroup(fine, fine_keys, keys):
    """O resultado de `aggregate(fine_keys, p95=False)` reagrupado por `keys` (subconjunto de `fine_keys`): uma leitura
    do DuckDB serve vários cortes (#504: cada `aggregate` refazia a junção com os logs de custo). Sem p95."""
    idx = [fine_keys.index(k) for k in keys]
    out = {} if keys else {(): _empty()}
    for key, a in fine.items():
        merge(out.setdefault(tuple(key[i] for i in idx), _empty()), a)
    return out


def aggregate_p95(con, from_ns, to_ns, tz=tz_mod.UTC, repo=None, sub=None):
    """O p95 (ms) de todas as chamadas da janela, sem a junção com os logs de custo; `None` sem chamada com duração."""
    for rec in _p95(con, (), from_ns, to_ns, tz, repo, sub):
        return rec["p95"]
    return None


def render(key, a, keys):
    """Acumulador -> objeto da resposta (custo real, de lista calculado e estimado sempre separados)."""
    out = {}
    for k, v in zip(keys, key):
        out[k] = v.isoformat() if k == "day" else v
    out.update({
        "calls": a["calls"],
        "spans": a["spans"],  # todos os spans do grupo (chamada ao modelo ou não): o denominador de `errors.spans`
        "tokens": a["tokens"],
        "cost": {
            "real_usd": a["real_usd"],            # custo que veio na chamada (span ou log api_request); null = nenhuma chamada com custo real
            "listed_usd": a["listed_usd"],        # custo de lista calculado (#747): assinatura sem custo real, pela tabela; null = nenhuma
            "estimated_usd": a["estimated_usd"],  # estimado pela tabela (chamada fora das assinaturas); null = nada estimado (ver unpriced_calls)
            "real_calls": a["real_calls"],
            "listed_calls": a["listed_calls"],
            "claude_no_log_calls": a["claude_no_log_calls"],  # parte das listed_calls: chamada do claude sem log de custo, calculada pela tabela (#747)
            "estimated_calls": a["estimated_calls"],
            "unpriced_calls": a["unpriced_calls"],  # sem custo real e sem preço: fora das três somas
            # só no custo pago (#748): chamadas de assinatura sem plano cadastrado no dia (contam 0); na lista a chave não existe
            **({"no_plan_calls": a["no_plan_calls"]} if a["no_plan_calls"] else {}),
        },
        "errors": {"spans": a["span_errors"], "logs": a["log_errors"], "total": a["span_errors"] + a["log_errors"]},
        "latency_p95_ms": None if a["p95"] is None else round(a["p95"], 3),
    })
    return out


def rendered(groups, key):
    """O grupo `key` de um `aggregate` no formato do `render`, sem as chaves; zerado se o grupo não existe."""
    return render((), groups.get(key) or _empty(), ())


def _sorted(groups):
    return sorted(groups.items(), key=lambda kv: tuple((v is not None, v if v is not None else "") for v in kv[0]))


def usage(con, from_ns, to_ns, prices, tz=tz_mod.UTC, repo=None, paid=False, sub=None):
    """Resposta do `/v1/usage`: `totals`, `rows` (host × agente × modelo), `series` (dia × host × agente × modelo;
    o dia é o do fuso `tz`, e `timezone` diz qual) e, por sessão (#433), `by_role` (dispatcher, worker, standalone) e
    `by_phase` (só fases do ADR-07, #749) e, por assinatura (#679), `by_subscription` (`claude`, `zai`,
    `codex`; `null` = chamada sem assinatura, como a do ai-memory): cada uma soma o mesmo que `totals`. `repo` (#528): só a tela `/uso` o
    usa; o `GET /v1/usage` não tem esse parâmetro."""
    fine_keys = ("day", "host", "agent", "model", "role", "phase", "subscription")
    alloc = paid_alloc(con, from_ns, to_ns, prices, tz) if paid else None
    fine = aggregate(con, from_ns, to_ns, prices, fine_keys, tz, p95=False, repo=repo, paid=paid, sub=sub, alloc=alloc)  # a junção com os logs de custo roda uma vez só (#504)

    def cut(keys):
        return fill_p95(con, regroup(fine, fine_keys, keys), keys, from_ns, to_ns, tz, repo, sub)

    total = cut(())[()]
    rows = cut(("host", "agent", "model"))
    series = cut(("day", "host", "agent", "model"))
    by_role = cut(("role",))
    by_phase = cut(("phase",))
    by_subscription = cut(("subscription",))
    out = {
        "timezone": tz.key,
        "totals": render((), total, ()),
        # modelos com chamada sem custo real e sem preço na tabela (null = span sem modelo)
        "unpriced_models": sorted(total["unpriced_models"], key=lambda m: (m is None, m or "")),
        "rows": [render(k, a, ("host", "agent", "model")) for k, a in _sorted(rows)],
        "series": [render(k, a, ("day", "host", "agent", "model")) for k, a in _sorted(series)],
        "by_role": [render(k, a, ("role",)) for k, a in _sorted(by_role)],
        "by_phase": [render(k, a, ("phase",)) for k, a in _sorted(by_phase)],
        "by_subscription": [render(k, a, ("subscription",)) for k, a in _sorted(by_subscription)],
    }
    if alloc is not None:
        # os dias com plano e sem uso (#748), já somados no total; sem filtro de repositório ficam de fora, como no `aggregate`
        idle = alloc.idle(from_ns, to_ns, tz, sub) if repo is None else []
        out["idle"] = [{"day": d.isoformat(), "subscription": name, "usd": usd} for d, name, usd in idle]
    return out
