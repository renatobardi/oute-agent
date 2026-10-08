"""O Jev na TypeSafe, chamado pelo agent-studio para classificar a fase de uma conversa (#749, ADR-02 adendo, ADR-08 "Fase da conversa").

O mesmo primitivo `choice` que o `oute-select` usa na abertura (ADR-02, #257), agora para o texto do **primeiro pedido** de uma
conversa avulsa. Regras:

- **Só `https://`** (`ENDPOINT_RE`): endereço de outro esquema = o Jev não é chamado (o texto e a chave iriam em claro). Sem
  redirecionamento, sem proxy do ambiente, com verificação do certificado (o `opener` do `price_sources`).
- **Teto de tempo** (`TIMEOUT_S`, 3 s) para a chamada inteira, inclusive o DNS: uma thread a limita. Falha, tempo esgotado ou
  resposta fora do formato = `JevError`, e a conversa fica onde estava (no passo 5, ação, com baixa confiança).
- **A chave** (`AGENT_STUDIO_JEV_KEY`, a `OUTE_TYPESAFE_API_KEY` do vault) só existe no cabeçalho: nunca em log, aviso ou evento.
  Sem chave, não há chamada.
- **Só o texto e as fases saem** (`TEXT_MAX` caracteres). O texto nunca vai a log; o erro diz só o tipo.
- **Segredo colado no pedido não sai** (`secret_kind`): se o texto bater com padrão de chave, token, senha, chave privada ou
  endereço com usuário e senha, a chamada não é feita e só o **tipo** do padrão é registrado (nunca o trecho). A conversa fica
  no passo da ação e não é perguntada de novo (o texto não muda).
- **Consumo** (ADR-08 §11): cada chamada vai ao `tel.jev` (contador e duração por resultado), que sai pelo coletor como o resto
  da telemetria do agent-studio.
"""
import json
import re
import threading
import time
import urllib.error
import urllib.request

from . import phase as phase_mod, price_sources

DEFAULT_URL = "https://api.typesafe.ai/v1/systemone"
ENDPOINT_RE = re.compile(r"https://[A-Za-z0-9.-]+(:[0-9]+)?(/[!-~]*)?\Z")   # sem usuário, espaço ou caractere de controle
MODEL = "jev-1.13.0"
TIMEOUT_S = 3.0
TEXT_MAX = 16000
REPLY_MAX = 1 << 20
INSTRUCTIONS = "Em que fase do ciclo de entrega de software esta tarefa está?"
HINTS = {
    "strat": "estratégia: oportunidade, pesquisa, comparar caminhos antes de decidir o que fazer",
    "intent": "intenção: entender e questionar o pedido, o problema e o resultado esperado",
    "spec": "especificação: escrever a issue com critérios de aceite e o que fica fora",
    "arch": "arquitetura: decisão estrutural, ADR, limites entre componentes",
    "design": "design: interface de módulos, protótipo descartável, desenho da solução",
    "plan": "planejamento: quebrar o trabalho em issues, triagem, dependências, riscos",
    "build": "construção: escrever ou alterar código, testes e a documentação da mudança; corrigir bug",
    "qa": "qualidade: revisar ou auditar um pull request, rodar gates e analisar o resultado",
    "ship": "entrega: preparar a release, checklist, deploy e verificação depois do deploy",
    "ops": "operação: ler telemetria, conferir saúde e custo, diagnosticar anomalia em produção",
    "learn": "aprendizado: analisar uso, custo, incidentes e rodadas para tirar lições",
    "iter": "iteração: sintetizar o aprendizado em roadmap e próximo ciclo, limpar o backlog",
}


# padrões de segredo colado no pedido: só classes simples e repetições limitadas (sem quantificador aninhado)
SECRET_PATTERNS = (
    ("chave-privada", re.compile(r"-----BEGIN [A-Z ]{0,24}PRIVATE KEY-----")),
    ("chave-api", re.compile(r"\bsk-[A-Za-z0-9_-]{20,}")),
    ("token-github", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})")),
    ("chave-aws", re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b")),
    ("token-slack", re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}")),
    ("chave-google", re.compile(r"\bAIza[A-Za-z0-9_-]{35}\b")),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}")),
    ("bearer", re.compile(r"\bBearer\s+[A-Za-z0-9._~+/=-]{20,}", re.IGNORECASE)),
    ("url-com-senha", re.compile(r"\b[a-z][a-z0-9+.-]{1,15}://[^\s/:@]{1,64}:[^\s/@]{1,64}@")),
    ("atribuicao", re.compile(r"\b[\w.-]{0,32}(?:api[_-]?key|secret|token|passw(?:or)?d|senha)[\w.-]{0,16}\s{0,3}[:=]\s{0,3}[\"']?[^\s\"']{8,}",
                              re.IGNORECASE)),
)


def secret_kind(text):
    """O tipo do primeiro padrão de segredo que o texto contém (`chave-api`, `token-github`, `senha`…), ou `None`. Nunca devolve o trecho."""
    for kind, pattern in SECRET_PATTERNS:
        if pattern.search(text):
            return kind
    return None


class JevError(Exception):
    """Falha da chamada; a mensagem é fixa (nunca texto de resposta, de pedido ou a chave)."""


class JevSecret(JevError):
    """O texto parece ter segredo: não saiu. `kind` = o tipo do padrão; nunca o trecho."""

    def __init__(self, kind):
        super().__init__(f"texto com segredo ({kind}); não enviado")
        self.kind = kind


def usable(url, key):
    """A chamada só sai com chave e endereço `https://`."""
    return bool(key) and bool(ENDPOINT_RE.match(url or ""))


def classify(text, url, key, timeout=TIMEOUT_S):
    """`(fase, confiança)` do Jev para o texto; `JevError` em qualquer falha. Vai só o texto (cortado) e as fases."""
    if not usable(url, key):
        raise JevError("sem chave ou endereço sem https")
    kind = secret_kind(text)
    if kind:
        raise JevSecret(kind)
    body = {"state": text[:TEXT_MAX], "model": MODEL,
            "questions": {"fase": {"type": "choice", "instructions": INSTRUCTIONS,
                                   "criteria": {p: HINTS[p] for p in phase_mod.PHASES}}}}
    got = {}

    def call():
        try:
            req = urllib.request.Request(url, data=json.dumps(body, ensure_ascii=False).encode(), method="POST",
                                         headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
            with price_sources._opener().open(req, timeout=timeout) as r:
                got["raw"] = r.read(REPLY_MAX + 1)
        except urllib.error.HTTPError as e:
            got["err"] = f"HTTP {e.code}"
        except Exception as e:  # noqa: BLE001 — o motivo sai pelo tipo, sem a mensagem
            slow = isinstance(e, TimeoutError) or isinstance(getattr(e, "reason", None), TimeoutError)
            got["err"] = f"sem resposta em {timeout:g} s" if slow else f"falha de rede ({type(e).__name__})"

    t = threading.Thread(target=call, daemon=True)
    t.start()
    t.join(timeout)
    if t.is_alive() or not got:
        raise JevError(f"sem resposta em {timeout:g} s")
    if "err" in got:
        raise JevError(got["err"])
    raw = got["raw"]
    try:
        if len(raw) > REPLY_MAX:
            raise ValueError
        ans = json.loads(raw)["answers"]["fase"]
        phase, conf = ans["choice"], ans["confidence"]
        if phase not in phase_mod.PHASES or isinstance(conf, bool) or not isinstance(conf, (int, float)) or not 0 <= conf <= 1:
            raise ValueError
    except (ValueError, KeyError, TypeError):
        raise JevError("resposta inválida") from None
    return phase, float(conf)


def call_pending(store, now_ns, url, key, tel, limit=20, backoff=None, clock=time.monotonic):
    """Chama o Jev para as conversas paradas que o classificador deixou sem resposta (no máximo `limit` por passada), grava a
    resposta em `phase_jev` e reclassifica a conversa. -> `{conversa: resultado}` das reclassificadas. `backoff` = `{conversa:
    instante da próxima tentativa}` (falha não repete antes de `RETRY_S`)."""
    if not usable(url, key):
        return {}
    backoff = {} if backoff is None else backoff
    wanted = store.read(lambda con: _candidates(con, now_ns))
    prompts = store.read(lambda con: phase_mod.first_prompts(con, [c for c in wanted if backoff.get(c, 0) <= clock()][:limit]))
    out = {}
    for conv, text in prompts.items():
        start = time.monotonic()
        try:
            phase, conf = classify(text, url, key)
        except JevSecret as e:
            tel.jev("segredo", 0.0)
            backoff[conv] = float("inf")   # o texto não muda: não é perguntado de novo
            tel.warn("jev-secret", "jev: o primeiro pedido tem segredo (%s); não enviado", e.kind)
            continue
        except JevError as e:
            tel.jev("erro", time.monotonic() - start)
            backoff[conv] = clock() + RETRY_S
            tel.warn("jev-failed", "jev: a classificação da fase falhou: %s", e)
            continue
        tel.jev("ok", time.monotonic() - start)
        res = store.transact(lambda con, c=conv, p=phase, f=conf: _save(con, c, p, f))
        if res:
            out[conv] = res
    return out


RETRY_S = 600.0


def make_pass(store, tel, url, key, sink):
    """A rotina em segundo plano da fase (#749): põe a classificação em dia e chama o Jev para as conversas paradas que ficaram
    de baixa confiança. `sink` recebe o que o Jev reclassificou (o espelho no SurrealDB)."""
    backoff = {}

    def run():
        store.classify_pending(force=True)
        done = call_pending(store, time.time_ns(), url, key, tel, backoff=backoff)
        if done:
            sink(done)
    return run


def _candidates(con, now_ns):
    """As conversas à espera do Jev: classificadas sem resposta dele, com o passo 6 em aberto e paradas há mais que `IDLE_NS`."""
    rows = con.execute(
        "SELECT c.conversation FROM conversation_phase c LEFT JOIN phase_jev j ON j.conversation = c.conversation "
        "WHERE c.confidence = ? AND c.origin IN ('acao') AND j.conversation IS NULL AND c.facts_unix_nano < ?",
        [phase_mod.LOW, now_ns - phase_mod.IDLE_NS]).fetchall()
    return [r[0] for r in rows]


def _save(con, conversation, phase, confidence):
    now = time.time_ns()
    phase_mod.record_jev(con, conversation, phase, confidence, now)
    return phase_mod.classify(con, now, [conversation]).get(conversation)
