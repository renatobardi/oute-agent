"""Fase do AI-DLC de toda conversa, por classificação póstuma pelo contexto (#749, ADR-08 "Fase da conversa", ADR-02 adendo).

Toda conversa (`session.id`) tem **uma** fase do ADR-07 (`PHASES`; `ctx` é faixa transversal, não fase). A abertura decide quando
pode; o resto o agent-studio deriva depois do fato, pelos sinais abaixo, **nesta ordem**: o primeiro nível com sinal decide.

1. `abertura`: a fase que o `oute-task` registrou no `oute.task.opened`/`reopened` da sessão (`oute.task.phase`);
2. `label`: a fase de outra sessão da mesma issue (repositório + número no começo do nome da sessão) aberta com origem `label`.
   O agent-studio não chama o GitHub: o label que ele conhece é o que o seletor registrou na abertura de alguma sessão da issue;
3. `skill`: a skill de fluxo `oute-aidlc-<fase>-…` usada na conversa (span/log de ferramenta `Skill`, ou o `file_path` de uma
   leitura do `SKILL.md`); com várias fases, a predominante;
4. `papel`: o dispatcher da rodada é `plan`; o revisor das etapas (`oute.swarm.step` no resource, sem sessão de worker) é `qa`;
5. `acao`: o que a conversa fez, pela tabela `ACTION_RULES` (no ADR-08). Só vale com margem (`STRONG_*`); sem margem, vai ao Jev;
6. `jev`: o texto do primeiro pedido, classificado pelo Jev (`jev.py`); vale com confiança >= `JEV_MIN`.

Sem sinal forte entra a fase mais provável com `confidence = "baixa"` (a ação fraca, depois a resposta fraca do Jev, depois
`DEFAULT_PHASE`). Em todo caso sai `(fase, origem, confiança)`; a troca manual (`manual`, tabela `phase_marks`) vale sobre tudo.

- **O dado bruto não muda.** `conversation_phase` é derivada e se refaz inteira (`compute`); o que não se refaz da telemetria
  são as duas tabelas de acréscimo, `phase_jev` (a resposta do Jev) e `phase_marks` (a troca do Bardi), que o `rebuild-state` lê.
- **O que o classificador lê:** `oute.*` dos eventos de abertura, o resource, o nome da ferramenta, o `file_path`, o nome da skill
  e, nas regras de ação, só **testa** o `full_command` com expressões fixas (nada dele é extraído nem guardado). O texto do primeiro
  pedido só é lido para a conversa que chega ao passo 6 e só sai do agent-studio para a TypeSafe (`jev.py`), nunca para log.
- **No SQL:** valores sempre em parâmetro; fases e regras são constantes deste módulo.
"""
import logging

log = logging.getLogger("agent_studio")

PHASES = ("strat", "intent", "spec", "arch", "design", "plan", "build", "qa", "ship", "ops", "learn", "iter")
DEFAULT_PHASE = "build"        # a mais provável sem nenhum sinal (a maior parte do trabalho é construção)
NO_CONVERSATION_PHASE = "ops"  # consumo que não é de conversa (ex.: o LLM do ai-memory): serviço rodando
ORIGINS = ("abertura", "label", "skill", "papel", "acao", "jev", "manual")
HIGH, LOW = "alta", "baixa"
JEV_MIN = 0.6                  # a confiança mínima do Jev (a mesma do seletor, ADR-02)
IDLE_NS = 10 * 60 * 10**9      # o Jev só é chamado para conversa parada há mais que isto ("póstuma")
STRONG_MIN, STRONG_RATIO = 4, 2   # ação forte: pontos >= STRONG_MIN e >= STRONG_RATIO vezes os da segunda fase
PROMPT_EVENTS = ("user_prompt", "claude_code.user_prompt")
_PHASES_SQL = ", ".join(f"'{p}'" for p in PHASES)
_PHASE_RE = "(" + "|".join(PHASES) + ")"

SCHEMA = (
    """CREATE TABLE IF NOT EXISTS conversation_phase (
        conversation VARCHAR PRIMARY KEY, phase VARCHAR NOT NULL, origin VARCHAR NOT NULL, confidence VARCHAR NOT NULL,
        classified_unix_nano UBIGINT NOT NULL, facts_unix_nano UBIGINT NOT NULL)""",
    """CREATE TABLE IF NOT EXISTS phase_jev (
        conversation VARCHAR PRIMARY KEY, phase VARCHAR NOT NULL, confidence DOUBLE NOT NULL, called_unix_nano UBIGINT NOT NULL)""",
    """CREATE TABLE IF NOT EXISTS phase_marks (
        conversation VARCHAR NOT NULL, phase VARCHAR NOT NULL, marked_unix_nano UBIGINT NOT NULL, marked_by VARCHAR NOT NULL,
        PRIMARY KEY (conversation, marked_unix_nano))""",
)
BY = "human"

# tabela de regras da ação (passo 5): (id, fase, pontos, condição). A condição lê o span `claude_code.tool`: nome da ferramenta,
# `file_path` e o `full_command` (só testado). A primeira que casa vale (a ordem é da mais específica para a mais geral).
_CMD = "json_extract_string(attributes, '$.full_command')"
_TOOL = "json_extract_string(attributes, '$.tool_name')"
_PATH = "json_extract_string(attributes, '$.file_path')"
_EDIT = f"{_TOOL} IN ('Edit', 'Write', 'MultiEdit', 'NotebookEdit')"
ACTION_RULES = (
    ("abriu-pr", "build", 4, f"regexp_matches({_CMD}, '\\bgh pr (create|merge)\\b')"),
    ("commit", "build", 2, f"regexp_matches({_CMD}, '\\bgit commit\\b')"),
    ("editou-adr", "arch", 3, f"{_EDIT} AND regexp_matches({_PATH}, '/docs/adr/')"),
    ("editou", "build", 1, _EDIT),
    ("auditou-pr", "qa", 3, f"regexp_matches({_CMD}, '\\bgh pr (review|comment|diff|checks)\\b|\\boute-sonar\\b')"),
    ("release-deploy", "ship", 4, f"regexp_matches({_CMD}, 'scripts/release|\\bgh release\\b|\\boute (up|down|update)\\b|\\boute-aidlc-ship')"),
    ("telemetria", "ops", 2, f"regexp_matches({_CMD}, '/v1/(usage|alerts|tray)|\\boute-inbox\\b|\\boute-quota\\b|journalctl|ssh oute-server')"),
    ("criou-issue", "spec", 3, f"regexp_matches({_CMD}, '\\bgh issue (create|edit)\\b')"),
    ("pesquisou", "strat", 1, f"{_TOOL} IN ('WebSearch', 'WebFetch')"),
)
_ACTION_CASE = "CASE " + " ".join(f"WHEN {cond} THEN '{rid}'" for rid, _, _, cond in ACTION_RULES) + " END"
_ACTION_PHASE = {rid: (phase, pts) for rid, phase, pts, _ in ACTION_RULES}

# um fato por linha (spans e logs com conversa); `todo` (lista de conversas) restringe, `None` = todas
_FACTS = ("SELECT session_id AS conv, time_unix_nano AS t, oute_task_id AS task, oute_swarm_round AS rnd, resource_attributes AS res FROM spans "
          "WHERE session_id IS NOT NULL{f} UNION ALL "
          "SELECT session_id, time_unix_nano, oute_task_id, oute_swarm_round, resource_attributes FROM logs WHERE session_id IS NOT NULL{f}")
_OPEN_EVENTS = "event_name IN ('oute.task.opened', 'oute.task.reopened') AND oute_task_id IS NOT NULL"


def create(con):
    for sql in SCHEMA:
        con.execute(sql)


def has_tables(con):
    n = con.execute("SELECT count(*) FROM information_schema.tables WHERE table_name IN "
                    "('conversation_phase', 'phase_jev', 'phase_marks')").fetchone()[0]
    return n == 3


def _attr(col, key):
    return f"json_extract_string({col}, '$.\"{key}\"')"


def _rows(con, sql, params=()):
    return con.execute(sql, list(params)).fetchall()


def _filter(todo, col="session_id"):
    """(trecho SQL, parâmetros) que restringe `col` às conversas de `todo`; `None` = sem filtro."""
    if todo is None:
        return "", []
    return f" AND list_contains(?, {col})", [list(todo)]


# ---------------------------------------------------------------- os sinais (um SELECT cada, todas as conversas de uma vez)
def _facts(con, todo):
    f, p = _filter(todo)
    sql = (f"SELECT conv, max(t), arg_min(task, t) FILTER (WHERE task IS NOT NULL), "
           f"count(COALESCE(rnd, {_attr('res', 'oute.swarm.round')})), count({_attr('res', 'oute.swarm.session')}), "
           f"count({_attr('res', 'oute.swarm.step')}) FROM ({_FACTS.format(f=f)}) GROUP BY conv")
    return {c: {"last": last, "task": task, "round": rnd > 0, "worker": ses > 0, "step": stp > 0}
            for c, last, task, rnd, ses, stp in _rows(con, sql, p + p)}


def _openings(con):
    """{id da sessão: {phase, origin, repo, number}} dos eventos de abertura. A primeira fase válida (pela hora do fato) fica."""
    phase, origin = _attr("attributes", "oute.task.phase"), _attr("attributes", "oute.task.origin")
    slug, repo = _attr("attributes", "oute.task.slug"), _attr("attributes", "oute.task.repo")
    sql = (f"SELECT oute_task_id, arg_min({phase}, time_unix_nano) FILTER (WHERE {phase} IN ({_PHASES_SQL})), "
           f"arg_min({origin}, time_unix_nano) FILTER (WHERE {phase} IN ({_PHASES_SQL})), "
           f"any_value({repo}), any_value(regexp_extract({slug}, '^([0-9]+)-', 1)) FROM logs WHERE {_OPEN_EVENTS} GROUP BY oute_task_id")
    return {t: {"phase": ph, "origin": og, "repo": rp, "number": nb or None} for t, ph, og, rp, nb in _rows(con, sql)}


def _labels(openings):
    """{(repositório, número da issue): fase predominante} das sessões abertas com origem `label`."""
    votes = {}
    for o in openings.values():
        if o["origin"] == "label" and o["phase"] and o["repo"] and o["number"]:
            tally = votes.setdefault((o["repo"], o["number"]), {})
            tally[o["phase"]] = tally.get(o["phase"], 0) + 1
    return {k: _top(t)[0] for k, t in votes.items()}


def _skills(con, todo):
    """{conversa: {fase: (usos, primeira hora)}} das skills `oute-aidlc-<fase>-…`: o nome da skill no span/log da ferramenta
    `Skill` ou o `file_path` de uma leitura do SKILL.md."""
    f, p = _filter(todo)
    skill = "json_extract_string(attributes, '$.skill_name')"
    nested = "json_extract_string(json_extract_string(attributes, '$.tool_parameters'), '$.skill_name')"
    expr = f"COALESCE(CASE WHEN {_TOOL} = 'Skill' THEN COALESCE({skill}, {nested}) END, {_PATH})"
    sql = (f"SELECT session_id, regexp_extract({expr}, 'oute-aidlc-{_PHASE_RE}-', 1) AS ph, count(*), min(time_unix_nano) "
           f"FROM (SELECT session_id, attributes, time_unix_nano FROM spans WHERE name = 'claude_code.tool' AND session_id IS NOT NULL{f} "
           f"UNION ALL SELECT session_id, attributes, time_unix_nano FROM logs WHERE event_name IN ('tool_result', 'claude_code.tool_result') "
           f"AND session_id IS NOT NULL{f}) WHERE regexp_matches({expr}, 'oute-aidlc-{_PHASE_RE}-') GROUP BY session_id, ph")
    out = {}
    for conv, ph, n, first in _rows(con, sql, p + p):
        out.setdefault(conv, {})[ph] = (n, first)
    return out


def _actions(con, todo):
    """{conversa: {fase: pontos}} pela tabela `ACTION_RULES`."""
    f, p = _filter(todo)
    sql = (f"SELECT session_id, rule, count(*) FROM (SELECT session_id, {_ACTION_CASE} AS rule FROM spans "
           f"WHERE name = 'claude_code.tool' AND session_id IS NOT NULL{f}) WHERE rule IS NOT NULL GROUP BY session_id, rule")
    out = {}
    for conv, rule, n in _rows(con, sql, p):
        phase, pts = _ACTION_PHASE[rule]
        out.setdefault(conv, {})[phase] = out.get(conv, {}).get(phase, 0) + n * pts
    return out


def _jev(con):
    return {c: (ph, conf) for c, ph, conf in _rows(con, "SELECT conversation, phase, confidence FROM phase_jev")}


def _manual(con):
    return {c: ph for c, ph in _rows(con, "SELECT arg_max(conversation, marked_unix_nano), arg_max(phase, marked_unix_nano) FROM phase_marks "
                                          "GROUP BY conversation")}


def first_prompts(con, convs):
    """{conversa: texto do primeiro pedido} (evento `user_prompt`, atributo `prompt`); só para as conversas pedidas."""
    if not convs:
        return {}
    sql = ("SELECT session_id, arg_min(json_extract_string(attributes, '$.prompt'), time_unix_nano) FROM logs "
           f"WHERE event_name IN ({', '.join('?' for _ in PROMPT_EVENTS)}) AND list_contains(?, session_id) GROUP BY session_id")
    return {c: t for c, t in _rows(con, sql, [*PROMPT_EVENTS, list(convs)]) if isinstance(t, str) and t.strip()}


# ---------------------------------------------------------------- a decisão (pura)
def _top(tally):
    """(chave, empate?) do maior valor de `tally` ({chave: n}); no empate, a menor chave (ordem estável)."""
    best = max(tally.values())
    keys = sorted(k for k, v in tally.items() if v == best)
    return keys[0], len(keys) > 1


def decide(sig):
    """Os sinais de uma conversa -> `{phase, origin, confidence, needs_jev}`. `sig`: manual, opening, label, skills ({fase: (n, t)}),
    dispatcher, reviewer, actions ({fase: pontos}), jev ((fase, confiança) ou None)."""
    out = _decide(sig)
    out.setdefault("needs_jev", False)
    return out


def _decide(sig):
    if sig.get("manual") in PHASES:
        return {"phase": sig["manual"], "origin": "manual", "confidence": HIGH}
    for key, origin in (("opening", "abertura"), ("label", "label")):
        if sig.get(key) in PHASES:
            return {"phase": sig[key], "origin": origin, "confidence": HIGH}
    skills = sig.get("skills") or {}
    if skills:
        phase, tie = _top({p: n for p, (n, _) in skills.items()})
        if tie:   # empate de usos: vale a skill usada primeiro, sem confiança alta
            phase = min((p for p, (n, _) in skills.items() if n == skills[phase][0]), key=lambda p: skills[p][1])
        return {"phase": phase, "origin": "skill", "confidence": LOW if tie else HIGH}
    if sig.get("reviewer"):
        return {"phase": "qa", "origin": "papel", "confidence": HIGH}
    if sig.get("dispatcher"):
        return {"phase": "plan", "origin": "papel", "confidence": HIGH}
    actions = sig.get("actions") or {}
    weak = None
    if actions:
        ranked = sorted(actions.items(), key=lambda kv: (-kv[1], kv[0]))
        first, second = ranked[0], ranked[1][1] if len(ranked) > 1 else 0
        if first[1] >= STRONG_MIN and first[1] >= STRONG_RATIO * second:
            return {"phase": first[0], "origin": "acao", "confidence": HIGH}
        weak = first[0]
    jev = sig.get("jev")
    if jev and jev[1] >= JEV_MIN and jev[0] in PHASES:
        return {"phase": jev[0], "origin": "jev", "confidence": HIGH}
    if weak:
        return {"phase": weak, "origin": "acao", "confidence": LOW, "needs_jev": jev is None}
    if jev and jev[0] in PHASES:
        return {"phase": jev[0], "origin": "jev", "confidence": LOW}
    return {"phase": DEFAULT_PHASE, "origin": "acao", "confidence": LOW, "needs_jev": jev is None}


# ---------------------------------------------------------------- compute / classify
def compute(con, todo=None):
    """Só leitura: `{conversa: {phase, origin, confidence, needs_jev, last}}` das conversas de `todo` (`None` = todas)."""
    facts = _facts(con, todo)
    openings = _openings(con)
    labels = _labels(openings)
    skills, actions = _skills(con, todo), _actions(con, todo)
    jev, manual = _jev(con), _manual(con)
    out = {}
    for conv, f in facts.items():
        o = openings.get(f["task"]) or {}
        sig = {"manual": manual.get(conv), "opening": o.get("phase"),
               "label": labels.get((o.get("repo"), o.get("number"))) if o.get("repo") and o.get("number") else None,
               "skills": skills.get(conv), "reviewer": f["step"] and f["round"] and not f["worker"],
               "dispatcher": f["round"] and not f["worker"] and not f["step"], "actions": actions.get(conv), "jev": jev.get(conv)}
        out[conv] = {**decide(sig), "last": f["last"]}
    return out


def pending(con):
    """As conversas a (re)classificar: sem linha, com fato depois da última classificação, ou com resposta do Jev ou troca
    do Bardi mais nova que a linha."""
    sql = ("SELECT f.conv FROM (SELECT conv, max(t) AS last FROM (" + _FACTS.format(f="") + ") GROUP BY conv) f "
           "LEFT JOIN conversation_phase c ON c.conversation = f.conv "
           "LEFT JOIN phase_jev j ON j.conversation = f.conv "
           "LEFT JOIN (SELECT conversation, max(marked_unix_nano) AS m FROM phase_marks GROUP BY conversation) k ON k.conversation = f.conv "
           "WHERE c.conversation IS NULL OR f.last > c.facts_unix_nano OR COALESCE(j.called_unix_nano, 0) > c.classified_unix_nano "
           "OR COALESCE(k.m, 0) > c.classified_unix_nano")
    return [r[0] for r in _rows(con, sql)]


def classify(con, now_ns, todo=None):
    """Classifica `todo` (padrão: o que `pending` acha) e grava em `conversation_phase`, numa transação do chamador.
    -> `{conversa: resultado}` do que foi gravado (com `needs_jev`)."""
    todo = pending(con) if todo is None else list(todo)
    if not todo:
        return {}
    return save(con, compute(con, todo), now_ns)


def save(con, result, now_ns):
    """Grava o resultado de `compute` em `conversation_phase` (dentro da transação do chamador) e o devolve."""
    for conv, r in result.items():
        con.execute("INSERT OR REPLACE INTO conversation_phase VALUES (?, ?, ?, ?, ?, ?)",
                    [conv, r["phase"], r["origin"], r["confidence"], now_ns, r["last"]])
    return result


def mark(con, conversation, phase, now_ns):
    """Acrescenta a troca do Bardi (`phase_marks`, só de acréscimo; a hora cresce sempre) e reclassifica a conversa.
    -> o resultado da conversa. Quem chama garante a transação e a conversa existente."""
    last = con.execute("SELECT max(marked_unix_nano) FROM phase_marks").fetchone()[0] or 0
    ns = max(now_ns, int(last) + 1)
    con.execute("INSERT INTO phase_marks VALUES (?, ?, ?, ?)", [conversation, phase, ns, BY])
    return classify(con, ns, [conversation]).get(conversation)


def record_jev(con, conversation, phase, confidence, now_ns):
    con.execute("INSERT OR REPLACE INTO phase_jev VALUES (?, ?, ?, ?)", [conversation, phase, float(confidence), now_ns])


def low_confidence(con, limit=200):
    """As conversas de baixa confiança que o Bardi pode trocar, as mais recentes primeiro (a tela `/fases`)."""
    cur = con.execute(
        "SELECT c.conversation, c.phase, c.origin, c.facts_unix_nano, "
        "(SELECT arg_min(oute_agent, time_unix_nano) FROM spans s WHERE s.session_id = c.conversation AND oute_agent IS NOT NULL), "
        "(SELECT arg_min(host_name, time_unix_nano) FROM spans s WHERE s.session_id = c.conversation AND host_name IS NOT NULL), "
        "(SELECT arg_min(oute_repo, time_unix_nano) FROM spans s WHERE s.session_id = c.conversation AND oute_repo IS NOT NULL) "
        "FROM conversation_phase c WHERE c.confidence = ? ORDER BY c.facts_unix_nano DESC LIMIT ?", [LOW, limit])
    keys = ("conversation", "phase", "origin", "last_ns", "agent", "host", "repo")
    return [dict(zip(keys, r)) for r in cur.fetchall()]


def phase_of(con, conversation):
    """`(fase, origem, confiança)` da conversa em `conversation_phase`, ou `None`."""
    row = con.execute("SELECT phase, origin, confidence FROM conversation_phase WHERE conversation = ?", [conversation]).fetchone()
    return tuple(row) if row else None


# ---------------------------------------------------------------- SQL do Uso, do Dashboard e do /v1/usage
def sql_phase(conv_col="t.session_id", task_col="t.oute_task_id", opening="i.phase", joined="cp.phase"):
    """A fase de uma linha de fato para o `usage._SCOPE`: a da conversa classificada; a da abertura da sessão (conversa ainda não
    classificada); `NO_CONVERSATION_PHASE` (fato sem conversa e sem sessão, como o LLM do ai-memory); `DEFAULT_PHASE` (o resto:
    conversa ainda não classificada, ou fato de sessão sem conversa; a mais provável até a próxima passada). Sempre uma fase do ADR-07."""
    op = f"CASE WHEN {opening} IN ({_PHASES_SQL}) THEN {opening} END"
    return (f"COALESCE({joined}, {op}, CASE WHEN {conv_col} IS NULL AND {task_col} IS NULL THEN '{NO_CONVERSATION_PHASE}' "
            f"ELSE '{DEFAULT_PHASE}' END)")
