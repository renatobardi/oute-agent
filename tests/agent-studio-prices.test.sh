#!/usr/bin/env bash
# Testes da revalidação diária dos preços do agent-studio (#339, ADR-08 adendo "Preços"): histórico de preços (só de
# acréscimo), semente e trava `fixed` do config.toml, busca em models.dev e OpenRouter (fontes falsas com TLS: só https,
# sem credencial, tempo e tamanho máximos, JSON validado), mapeamento de id, regra "só troca quando as duas fontes
# concordam", preço da hora do fato (chamada antes e depois da troca), os cinco alertas, `GET /v1/prices`, o tray,
# a telemetria e a falha da rotina que nunca derruba a ingestão. A parte 1 roda em Python direto, com relógio fixado;
# a parte 2 sobe o app de verdade e confere pela API. Sem Docker e sem rede de verdade.
# Uso: tests/agent-studio-prices.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/agent-studio.sh"
. "$ROOT/tests/lib/price-sources.sh"
trap 'studio_stop; ps_stop; rm -rf "$TMP"' EXIT
studio_init
ps_off
ps_start "$TMP/ps" || die "as fontes de preço falsas não subiram"

# ================================================================ parte 1: Python direto (relógio fixado)
export ROOT PS_DIR
PYTHONPATH="$ROOT/tests/lib:$ROOT/docker/agent-studio" "$STUDIO_PY" - "$TMP" > "$TMP/py.out" 2> "$TMP/py.err" <<'PY'
import json, os, sys, threading, time, tomllib
from functools import partial
from pycheck import check
from price_json import models_dev, openrouter
from otlp_json import kv, rs, span
from agent_studio import (alert_text, alerts as A, config as CF, conversations as CV, cost as C, otlp,
                          price_alerts as PA, price_sources as S, prices as P, store as ST, telemetry, usage as U)

tmp, root, ps = sys.argv[1], os.environ["ROOT"], os.environ["PS_DIR"]
URLS = {S.MODELS_DEV: os.environ["AGENT_STUDIO_PRICE_URL_MODELS_DEV"], S.OPENROUTER: os.environ["AGENT_STUDIO_PRICE_URL_OPENROUTER"]}
DAY = P.DAY_NS
T0 = 1_760_000_000 * 10**9          # 2025-10-09T08:53:20Z
T1, T2, T3, T4, T5 = (T0 + i * DAY for i in range(1, 6))
HOUR = 3600 * 10**9
fast = partial(S.fetch, timeout=2)


def serve(md=None, orr=None, ids=None, md_mode=None, or_mode=None):
    for name, body, mode in (("models.dev", None if md is None else models_dev(md), md_mode),
                             ("openrouter", None if orr is None else openrouter(orr, ids), or_mode)):
        for ext in ("body", "mode"):
            try: os.remove(f"{ps}/{name}.{ext}")
            except OSError: pass
        if body is not None: open(f"{ps}/{name}.body", "w").write(body)
        if mode: open(f"{ps}/{name}.mode", "w").write(mode)


def requests():
    try: return [json.loads(l) for l in open(f"{ps}/requests.jsonl")]
    except OSError: return []


def raises(fn, code):
    try: fn()
    except S.SourceError as e: return e.code == code
    except Exception: return False
    return False


class Rec(telemetry.Noop):
    def __init__(self): self.runs, self.warns = [], []
    def price_run(self, changes, failures): self.runs.append((changes, dict(failures)))
    def warn(self, kind, msg, *a, level=0): self.warns.append((kind, msg % a))


# ---------------------------------------------------------------- mapeamento de id (explícito e testado)
EXPECTED = {
    "claude-opus-5-5": ("anthropic", "anthropic/claude-opus-5.5"),
    "claude-sonnet-5-5": ("anthropic", "anthropic/claude-sonnet-5.5"),
    "claude-sonnet-5": ("anthropic", "anthropic/claude-sonnet-5"),
    "claude-haiku-4-5-20251001": ("anthropic", "anthropic/claude-haiku-4.5"),
    "claude-fable-5-1": ("anthropic", "anthropic/claude-fable-5.1"),
    "gpt-5": ("openai", "openai/gpt-5"), "gpt-5-codex": ("openai", "openai/gpt-5-codex"),
    "gpt-5.1": ("openai", "openai/gpt-5.1"), "gpt-5.1-codex-mini": ("openai", "openai/gpt-5.1-codex-mini"),
    "gpt-5-nano": ("openai", "openai/gpt-5-nano"), "gpt-6-astra": ("openai", "openai/gpt-6-astra"),
    "gpt-6.1-sol": ("openai", "openai/gpt-6.1-sol"), "gpt-6-luna": ("openai", "openai/gpt-6-luna"),
}
for model, (provider, or_id) in EXPECTED.items():
    ids = S.source_ids(model)
    check(f"mapeamento {model}: models.dev {provider}/{model}, OpenRouter {or_id}",
          ids == {S.MODELS_DEV: (provider, model.lower()), S.OPENROUTER: or_id})
check("mapeamento: prefixo do provedor e caixa não mudam o id (OpenAI/GPT-5-Codex)",
      S.source_ids("OpenAI/GPT-5-Codex") == S.source_ids("gpt-5-codex"))
check("mapeamento: modelo sem regra não tem fonte (nunca adivinha)", S.source_ids("llama-3-70b") == {} and S.source_ids("") == {} and S.source_ids(None) == {})
sel, _ = P.select_models(f"{root}/config/select/models.toml")
cfg_models = set(tomllib.load(open(f"{root}/config/agent-studio/config.toml", "rb"))["prices"])
check("mapeamento: todo modelo da tabela do seletor e do config.toml do repo tem id nas duas fontes",
      all(set(S.source_ids(m)) == {S.MODELS_DEV, S.OPENROUTER} for m in sel | cfg_models))
check("seletor: a tabela do repo dá os 6 ids Claude/Codex esperados",
      sel == {"claude-sonnet-5-5", "gpt-6.1-sol", "claude-opus-5-5", "gpt-6-astra", "claude-haiku-4-5-20251001", "gpt-6-luna"})
check("seletor: arquivo ausente = conjunto vazio com o motivo", P.select_models(f"{tmp}/nao-existe.toml") == (set(), "FileNotFoundError"))

# ---------------------------------------------------------------- leitura e validação do JSON de terceiro
md = S.parse_models_dev(json.loads(models_dev({"claude-opus-5-5": {"input": 4, "output": 20, "cache_read": 0.2, "cache_creation": 5},
                                               "gpt-5": {"input": 1.25, "output": 10}})))
check("models.dev: lê input, output, cache_read e cache_write (como cache_creation)",
      md[("anthropic", "claude-opus-5-5")] == {"input": 4.0, "output": 20.0, "cache_read": 0.2, "cache_creation": 5.0})
check("models.dev: cache ausente fica de fora (a regra de concordância trata)", md[("openai", "gpt-5")] == {"input": 1.25, "output": 10.0})
orp = S.parse_openrouter(json.loads(openrouter({"claude-opus-5-5": {"input": 4, "output": 20, "cache_read": 0.2, "cache_creation": 5}},
                                               {"claude-opus-5-5": "anthropic/claude-opus-5.5"})))
check("OpenRouter: USD por token em texto vira USD por 1M sem erro de ponto flutuante",
      orp["anthropic/claude-opus-5.5"] == {"input": 4.0, "output": 20.0, "cache_read": 0.2, "cache_creation": 5.0})
tiers = {"anthropic": {"models": {"claude-x": {"cost": {"input": 1, "output": 2, "tiers": [{"input": 9, "output": 9}]}}}},
         "openai": {"models": {"gpt-y": {"cost": {"input": 1, "output": -2}}, "gpt-z": {"cost": {"input": float("nan") if False else 1e9, "output": 1}},
                               "gpt-w": {"cost": {"input": True, "output": 1}}, "gpt-v": {"cost": "grátis"}, "gpt-ok": {"cost": {"input": 1, "output": 2}}}}}
parsed = S.parse_models_dev(tiers)
check("models.dev: só o preço base (faixas de contexto ignoradas)", parsed[("anthropic", "claude-x")] == {"input": 1.0, "output": 2.0})
check("models.dev: preço negativo, absurdo, booleano ou texto deixa o modelo de fora", set(parsed) == {("anthropic", "claude-x"), ("openai", "gpt-ok")})
check("OpenRouter: preço -1 (dinâmico), texto e id que não é texto deixam o modelo de fora",
      list(S.parse_openrouter({"data": [{"id": "openai/a", "pricing": {"prompt": "-1", "completion": "-1"}},
                                        {"id": "openai/b", "pricing": {"prompt": "abc", "completion": "1"}},
                                        {"id": 7, "pricing": {"prompt": "1", "completion": "1"}}, "x",
                                        {"id": "openai/c", "pricing": {"prompt": "0.000001", "completion": "0.000002"}}]})) == ["openai/c"])
check("models.dev: raiz que não é objeto = formato", raises(lambda: S.parse_models_dev([]), "formato"))
check("models.dev: sem o provedor esperado (formato mudou) = formato", raises(lambda: S.parse_models_dev({"anthropic": {"models": {}}}), "formato"))
check("models.dev: nenhum preço válido = formato", raises(lambda: S.parse_models_dev({"anthropic": {"models": {}}, "openai": {"models": {}}}), "formato"))
check("OpenRouter: sem a lista `data` = formato", raises(lambda: S.parse_openrouter({"models": []}), "formato"))
check("OpenRouter: lista sem nenhum preço válido = formato", raises(lambda: S.parse_openrouter({"data": []}), "formato"))
check("JSON: NaN é recusado", raises(lambda: S.load_json(b'{"a": NaN}'), "json"))
check("JSON: UTF-8 inválido é recusado", raises(lambda: S.load_json(b"\xff\xfe"), "json"))
check("JSON: aninhamento fundo demais é recusado (sem derrubar)", raises(lambda: S.load_json(b"[" * 100000), "json"))

# ---------------------------------------------------------------- busca: só https, sem credencial, limites
good = {"claude-opus-5-5": {"input": 4, "output": 20, "cache_read": 0.2, "cache_creation": 5}}
serve(good, good, {"claude-opus-5-5": "anthropic/claude-opus-5.5"})
body = S.fetch(URLS[S.MODELS_DEV], timeout=2)
check("busca: https com certificado válido devolve o corpo", isinstance(body, bytes) and b"claude-opus-5-5" in body)
reqs = requests()
check("busca: GET, sem Authorization e sem Cookie", reqs and all(r["method"] == "GET" and r["auth"] == "" and r["cookie"] == "" for r in reqs))
before = len(requests())
check("busca: URL que não é https:// nunca chega à rede (código url)", raises(lambda: S.fetch("http" + "://127.0.0.1:1/x"), "url") and len(requests()) == before)
check("busca: URL com credencial embutida é recusada", raises(lambda: S.fetch("https://u:p@127.0.0.1:1/x"), "url"))
check("busca: outro esquema (ftp) é recusado", raises(lambda: S.fetch("ftp" + "://127.0.0.1/x"), "url"))
check("busca: porta fechada = rede", raises(lambda: S.fetch("https://127.0.0.1:1/x", timeout=2), "rede"))
saved = os.environ.get("SSL_CERT_FILE")
os.environ["SSL_CERT_FILE"] = f"{tmp}/nao-existe.pem"
check("busca: certificado que o sistema não confia = rede (o TLS é conferido)", raises(lambda: S.fetch(URLS[S.MODELS_DEV], timeout=2), "rede"))
os.environ["SSL_CERT_FILE"] = saved
for mode, code in (("500", "http"), ("redirect", "redirecionamento"), ("big", "tamanho"), ("bigstream", "tamanho")):
    serve(good, good, md_mode=mode)
    check(f"busca: resposta {mode} = {code}", raises(lambda: S.fetch(URLS[S.MODELS_DEV], timeout=5), code))
serve(good, good, md_mode="hang")
open(f"{ps}/hang", "w").write("20")
t = time.monotonic()
check("busca: fonte que não responde estoura o tempo (código tempo, sem esperar os 20 s)", raises(lambda: S.fetch(URLS[S.MODELS_DEV], timeout=1), "tempo") and time.monotonic() - t < 10)
serve(good, good)
check("busca: corpo acima do máximo = tamanho (máximo pequeno)", raises(lambda: S.fetch(URLS[S.MODELS_DEV], max_bytes=10, timeout=2), "tamanho"))
check("busca: o tempo total (prazo) também vale", raises(lambda: S.fetch(URLS[S.MODELS_DEV], timeout=2, deadline=-1), "tempo"))
serve(good, good, md_mode="lixo")
check("leitura: 200 que não é JSON = json", raises(lambda: S.read(S.MODELS_DEV, URLS[S.MODELS_DEV], fast), "json"))
open(f"{ps}/models.dev.mode", "w").write("ok"); open(f"{ps}/models.dev.body", "w").write('{"novo": true}')
check("leitura: JSON fora do formato = formato", raises(lambda: S.read(S.MODELS_DEV, URLS[S.MODELS_DEV], fast), "formato"))

# ---------------------------------------------------------------- regras de troca
P4 = {"input": 4.0, "output": 20.0, "cache_read": 0.2, "cache_creation": 5.0}
cur = C.ModelPrice(4.0, 20.0, 0.2, 5.0)
D = S.MODELS_DEV, S.OPENROUTER
check("concordância: tudo igual = o preço", P.agree(P4, dict(P4))[0] == cur)
check("concordância: input diferente = diverge em input", P.agree(P4, {**P4, "input": 5.0}) == (None, ["input"]))
check("concordância: cache só numa fonte vale o dela (a outra não contradiz)", P.agree({"input": 2.0, "output": 9.0}, {"input": 2.0, "output": 9.0, "cache_read": 0.5})[0] == C.ModelPrice(2.0, 9.0, 0.5, 2.0))
check("concordância: sem cache em nenhuma = preço de input", P.agree({"input": 3.0, "output": 9.0}, {"input": 3.0, "output": 9.0})[0] == C.ModelPrice(3.0, 9.0, 3.0, 3.0))
check("concordância: dois campos divergentes são listados", P.agree(P4, {**P4, "output": 21.0, "cache_read": 0.3})[1] == ["output", "cache_read"])
st_, info, new = P.decide("m", cur, False, {D[0]: dict(P4), D[1]: {**P4, "input": 5.0, "output": 25.0}})
check("decide: fontes divergem = diverge, sem preço novo", st_ == P.DIVERGE and new is None and set(info["fields"]) == {"input", "output"})
st_, info, new = P.decide("m", cur, False, {D[0]: {**P4, "input": 5.0}, D[1]: {**P4, "input": 5.0}})
check("decide: duas fontes concordam em valor novo = trocado", st_ == P.CHANGED and new.input == 5.0 and info["old"]["input"] == 4.0)
check("decide: duas fontes concordam no vigente = igual", P.decide("m", cur, False, {D[0]: dict(P4), D[1]: dict(P4)}) == (P.EQUAL, {}, None))
st_, info, new = P.decide("m", cur, True, {D[0]: {**P4, "input": 5.0}, D[1]: {**P4, "input": 5.0}})
check("decide: modelo fixo nunca troca (fixo_difere, com os dois valores)", st_ == P.FIXED_DIFFERS and new is None and info["fixed"]["input"] == 4.0 and info["sources"]["input"] == 5.0)
check("decide: fonte fora do ar = fonte_fora, preço fica", P.decide("m", cur, False, {D[0]: dict(P4), D[1]: "http"})[::2] == (P.SOURCE_DOWN, None))
check("decide: uma fonte sem o modelo = sem_fonte, preço fica", P.decide("m", cur, False, {D[0]: dict(P4), D[1]: None})[::2] == (P.NO_SOURCE, None))
check("decide: modelo sem preço e fontes concordam = novo", P.decide("m", None, False, {D[0]: dict(P4), D[1]: dict(P4)})[0] == P.NEW)
check("decide: modelo sem preço e fontes divergem = diverge, continua sem preço", P.decide("m", None, False, {D[0]: dict(P4), D[1]: {**P4, "input": 9.0}})[::2] == (P.DIVERGE, None))

# ---------------------------------------------------------------- tabela de preços por hora
tbl = C.PriceTable({"m": [(100, C.ModelPrice(1, 1, 1, 1)), (200, C.ModelPrice(2, 2, 2, 2))], "solto": C.ModelPrice(5, 5, 5, 5)})
check("tabela: antes da primeira linha vale a primeira", tbl.lookup("m", 50).input == 1)
check("tabela: na hora exata da linha vale a nova (>=)", tbl.lookup("m", 200).input == 2 and tbl.lookup("m", 199).input == 1)
check("tabela: sem hora, o preço vigente (o mais novo)", tbl.lookup("m").input == 2)
check("tabela: prefixo do provedor e caixa", tbl.lookup("OpenAI/M", 150).input == 1)
check("tabela: ModelPrice solto vale desde sempre e não gera troca", tbl.lookup("solto", 0).input == 5 and tbl.boundaries() == [200])
check("tabela: replace troca tudo e o snapshot não vê a troca", (lambda s: (tbl.replace(C.PriceTable({"n": C.ModelPrice(7, 7, 7, 7)})), s.lookup("m", 0) is not None and tbl.lookup("m") is None)[1])(tbl.snapshot()))


# ---------------------------------------------------------------- config: semente e trava
def mkstore(name, toml, selector=None):
    cpath = f"{tmp}/{name}.toml"
    open(cpath, "w").write(toml)
    spath = f"{tmp}/{name}-select.toml"
    open(spath, "w").write(selector or '[default]\nclaude = "claude-opus-5-5"\ncodex = "gpt-6-luna"\n')
    return ST.Store(f"{tmp}/{name}.duckdb"), CF.load(cpath), spath


CONFIG = """
[prices."gpt-5-codex"]
input = 1.25
output = 10.0
cache_read = 0.125
[prices."claude-sonnet-5"]
fixed = true
input = 3.0
output = 15.0
[prices."claude-opus-5-5"]
input = 4.0
output = 20.0
cache_read = 0.2
cache_creation = 5.0
[prices."gpt-4-velho"]
input = 30.0
output = 60.0
"""
st, cfg, sel_path = mkstore("main", CONFIG)
check("config: fixed = true marca o modelo, e a marca não vira campo de preço", cfg.fixed == {"claude-sonnet-5"} and cfg.seed["claude-sonnet-5"] == C.ModelPrice(3.0, 15.0, 3.0, 3.0) and cfg.errors == [])
open(f"{tmp}/bad.toml", "w").write('[prices."x"]\nfixed = "sim"\ninput = 1\noutput = 1\n[prices."y"]\ninput = 1\noutput = 1\n')
bad = CF.load(f"{tmp}/bad.toml")
check("config: fixed que não é booleano = erro, modelo de fora e sem a trava", bad.fixed == frozenset() and "x" not in bad.seed and "y" in bad.seed and any("fixed" in e for e in bad.errors))
P.sync(st, cfg, now_ns=T0)
rows0 = st.read(P.history_rows)
check("semente: cada modelo do config.toml ganha uma linha `config` na subida", [(r["model"], r["origin"], r["start_unix_nano"]) for r in rows0] == [
    ("claude-opus-5-5", "config", T0), ("claude-sonnet-5", "config", T0), ("gpt-4-velho", "config", T0), ("gpt-5-codex", "config", T0)])
check("semente: a tabela viva passa a ser o histórico", cfg.prices.lookup("gpt-5-codex").input == 1.25 and len(cfg.prices) == 4)
P.sync(st, cfg, now_ns=T0 + HOUR)
check("semente: segunda subida não repete a linha (só quem não tem linha)", len(st.read(P.history_rows)) == 4)
st2, cfg2, _ = mkstore("edit", CONFIG)
P.sync(st2, cfg2, now_ns=T0)
cfg_edit = CF.load(f"{tmp}/edit.toml")
cfg_edit.seed["gpt-5-codex"] = C.ModelPrice(9.0, 9.0, 9.0, 9.0)       # arquivo editado depois da semente
cfg_edit.seed["claude-sonnet-5"] = C.ModelPrice(4.0, 15.0, 4.0, 4.0)  # o fixo editado
P.sync(st2, cfg_edit, now_ns=T0 + HOUR)
h = {(r["model"], r["start_unix_nano"]): r for r in st2.read(P.history_rows)}
check("semente: editar preço de modelo sem a marca não o muda (o histórico manda)", cfg_edit.prices.lookup("gpt-5-codex").input == 1.25 and ("gpt-5-codex", T0 + HOUR) not in h)
check("trava: editar o preço de um modelo fixo acrescenta uma linha `config`, sem reescrever a antiga",
      h[("claude-sonnet-5", T0 + HOUR)]["origin"] == "config" and h[("claude-sonnet-5", T0 + HOUR)]["input"] == 4.0
      and h[("claude-sonnet-5", T0)]["input"] == 3.0 and cfg_edit.prices.lookup("claude-sonnet-5").input == 4.0)
st2.close()

# ---------------------------------------------------------------- chamadas e a hora do fato
def payload(calls):
    """calls = [(hora ns, modelo, tokens de entrada, custo real ou None, conversa)] -> resourceSpans de Codex/Claude."""
    spans = []
    for t, model, tokens, real, conv in calls:
        attrs = {"model": model, "codex.turn.token_usage.non_cached_input_tokens": tokens}
        if real is not None: attrs["cost_usd"] = real
        spans.append(span("session_task.turn", t / 1e9, 1, attrs))
    return {"resourceSpans": [rs({"host.name": "oute-server", "service.name": "codex_exec", "oute.agent": "codex",
                                  "session.id": "conv-1"}, spans)]}


def ingest(calls):
    st.write({"spans": otlp.span_rows(payload(calls), T5)})


MI = 1_000_000
ingest([(T1 - HOUR, "gpt-5-codex", MI, None, "c"),            # antes da troca (T1)
        (T1 + HOUR, "gpt-5-codex", MI, None, "c"),            # depois
        (T0 - 2 * DAY, "gpt-9-sem-fonte", 1000, None, "c"),   # em uso, sem preço e sem fonte
        (T0 - 3 * DAY, "claude-sonnet-5", 10, None, "c"),     # em uso (fixo)
        (T0 - 3 * DAY, "claude-opus-5-5", 10, 0.5, "c"),      # em uso só com custo real
        (T0 - 3 * DAY, "claude-semprecusto", 10, 0.5, "c"),   # em uso só com custo real e sem preço: não alerta
        (T0 - 40 * DAY, "gpt-4-velho", 10, None, "c"),        # fora dos 30 dias: não é conferido
        (T1 - HOUR, "OpenAI/GPT-5-Codex", 10, None, "c"),     # prefixo e caixa: é o mesmo gpt-5-codex
        (T0 - DAY, "Nome Com Espaço", 10, None, "c")])         # nome fora do padrão: nem é buscado
rows_before = {t: st.read(lambda con, t=t: con.execute(f"SELECT count(*) FROM {t}").fetchone()[0]) for t in ("spans", "logs", "metrics")}
other_before = st.read(lambda con: con.execute("SELECT sha256(string_agg(dedupe_key, ',' ORDER BY dedupe_key)) FROM spans").fetchone()[0])

ALL = {"claude-opus-5-5": {"input": 4, "output": 20, "cache_read": 0.2, "cache_creation": 5},
       "claude-sonnet-5": {"input": 2, "output": 10},                              # fixo no config em 3/15: as fontes concordam em outro
       "gpt-5-codex": {"input": 1.5, "output": 10, "cache_read": 0.125},           # config 1.25: as fontes concordam em 1.5
       "gpt-6-luna": {"input": 0.1, "output": 0.5, "cache_read": 0.01, "cache_creation": 0.125}}  # só no seletor: modelo novo
OR_IDS = {"claude-opus-5-5": "anthropic/claude-opus-5.5", "claude-sonnet-5": "anthropic/claude-sonnet-5"}
OR_OPUS_DIFF = {**ALL, "claude-opus-5-5": {"input": 5, "output": 25, "cache_read": 0.2, "cache_creation": 5}}
serve(ALL, OR_OPUS_DIFF, OR_IDS)
tel = Rec()
out = P.check(st, cfg, tel, now_ns=T1, urls=URLS, fetcher=fast, select_path=sel_path)
check("conferência: sem falha, uma troca (gpt-5-codex)", out == {"changes": 1, "failures": {}})
checks = {r["model"]: r for r in st.read(lambda con: P._rows(con, "SELECT * FROM price_checks WHERE checked_unix_nano = ?", [T1]))}
check("modelos conferidos: seletor + em uso nos 30 dias (e só esses; o nome fora do padrão e o de 40 dias ficam de fora)",
      set(checks) == {"claude-opus-5-5", "claude-sonnet-5", "gpt-5-codex", "gpt-6-luna", "gpt-9-sem-fonte", "claude-semprecusto"})
check("conferência: o mesmo modelo com prefixo e caixa é conferido uma vez só (chave da tabela)", "openai/gpt-5-codex" not in checks)
check("resultado por modelo: trocado, novo, diverge, fixo_difere, sem_fonte", {m: r["status"] for m, r in checks.items()} == {
    "gpt-5-codex": "trocado", "gpt-6-luna": "novo", "claude-opus-5-5": "diverge", "claude-sonnet-5": "fixo_difere",
    "gpt-9-sem-fonte": "sem_fonte", "claude-semprecusto": "sem_fonte"})
hist = st.read(P.history_rows)
by_model = {}
for r in hist: by_model.setdefault(r["model"], []).append(r)
check("troca: gpt-5-codex ganha uma linha `fontes` na hora da conferência e a de config segue intacta",
      [(r["origin"], r["start_unix_nano"], r["input"]) for r in by_model["gpt-5-codex"]] == [("config", T0, 1.25), ("fontes", T1, 1.5)])
check("modelo novo no seletor: primeira linha `fontes`", [(r["origin"], r["input"]) for r in by_model["gpt-6-luna"]] == [("fontes", 0.1)])
check("divergência, trava e modelo sem fonte não mudam o preço", len(by_model["claude-opus-5-5"]) == 1 and len(by_model["claude-sonnet-5"]) == 1 and "gpt-9-sem-fonte" not in by_model)
check("tabela viva já troca depois da conferência", cfg.prices.lookup("gpt-5-codex").input == 1.5 and cfg.prices.lookup("gpt-6-luna").input == 0.1)
check("telemetria: uma conferência, uma troca, nenhuma falha", tel.runs == [(1, {})])
snapshot_1 = [dict(r) for r in hist]

# preço da hora do fato: chamada antes e depois da troca
agg = lambda lo, hi: st.usage(lo, hi, cfg.prices)["rows"]
codex = lambda rows: next(r for r in rows if r["model"] == "gpt-5-codex")["cost"]
check("hora do fato: a chamada de antes da troca fica com o preço da época (1,25)", abs(codex(agg(T1 - 2 * HOUR, T1))["estimated_usd"] - 1.25) < 1e-9)
check("hora do fato: a chamada de depois da troca usa o preço novo (1,50)", abs(codex(agg(T1, T1 + 2 * HOUR))["estimated_usd"] - 1.5) < 1e-9)
both = st.usage(T1 - 2 * HOUR, T1 + 2 * HOUR, cfg.prices)
total = both["totals"]["cost"]["estimated_usd"]
check("hora do fato: numa janela só que atravessa a troca, cada chamada pelo seu preço (1,25 + 1,50 + as 10 de prefixo)",
      abs(total - (1.25 + 1.5 + 10 * 1.25 / 1e6 + 0)) < 1e-6 and both["totals"]["cost"]["estimated_calls"] == 3)
check("hora do fato: chamada anterior não é recalculada com o preço novo (soma por faixa, não pelo preço vigente)", abs(total - 3 * 1.5) > 0.1)
conv = st.conversation("conv-1", cfg.prices)
costs = {(s["time_unix_nano"], s["cost"]) for s in conv["spans"] if s["model"] == "gpt-5-codex" and s["input_tokens"] == MI}
check("hora do fato: o detalhe da conversa usa o mesmo preço por chamada", costs == {(T1 - HOUR, 1.25), (T1 + HOUR, 1.5)})
check("modelo em uso sem preço nunca vira zero (gpt-9-sem-fonte fica em unpriced_models)", "gpt-9-sem-fonte" in st.usage(T0 - 3 * DAY, T5, cfg.prices)["unpriced_models"])

# alertas
acfg = A.AlertConfig()
def alerts_at(at):
    return [a for a in st.alerts(at, acfg)["alerts"] if a["type"] in A.PRICE_TYPES]
al = alerts_at(T1 + HOUR)
by_type = {}
for a in al: by_type.setdefault(a["type"], []).append(a)
changed = by_type.get("price_changed", [])
check("alerta preço trocado: informativo, um por campo que mudou, com modelo, campo, valor antigo e novo (o cache_creation sem valor nas fontes acompanha o input)",
      [(a["evidence"]["model"], a["evidence"]["field"], a["evidence"]["old"], a["evidence"]["new"], a["evidence"]["level"], a["since"]) for a in changed]
      == [("gpt-5-codex", "input", 1.25, 1.5, "info", A.iso(T1)), ("gpt-5-codex", "cache_creation", 1.25, 1.5, "info", A.iso(T1))])
check("alerta preço trocado: o modelo novo (primeira linha) não alerta troca", all(a["evidence"]["model"] != "gpt-6-luna" for a in changed))
check("alerta fontes divergem: modelo, campos e o valor de cada fonte", len(by_type.get("price_sources_diverge", [])) == 1 and
      by_type["price_sources_diverge"][0]["evidence"]["fields"] == {"input": {"models.dev": 4.0, "openrouter": 5.0}, "output": {"models.dev": 20.0, "openrouter": 25.0}}
      and by_type["price_sources_diverge"][0]["evidence"]["level"] == "problem")
check("alerta preço fixo difere da fonte: o fixo e o das fontes", len(by_type.get("price_fixed_differs", [])) == 1
      and by_type["price_fixed_differs"][0]["evidence"]["fixed"]["input"] == 3.0 and by_type["price_fixed_differs"][0]["evidence"]["sources"]["input"] == 2.0)
check("alerta modelo em uso sem preço: só o que tem chamada sem custo real (o de custo real não alerta)",
      [a["evidence"]["model"] for a in by_type.get("price_model_unpriced", [])] == ["gpt-9-sem-fonte"])
check("alerta fonte fora do ar: nenhum (as duas responderam)", "price_source_down" not in by_type)
check("alertas de preço entram no pipeline com título e texto prontos (tray e tela)",
      all(alert_text.title(a) != a["type"] and alert_text.text(a) for a in al) and "gpt-5-codex · input: US$ 1,25 → US$ 1,5 por 1M tokens" == alert_text.text(changed[0]))
check("alerta preço trocado some sozinho em 7 dias (6 dias: liga; 8 dias: some)", len([a for a in alerts_at(T1 + 6 * DAY) if a["type"] == "price_changed"]) == 2 and not [a for a in alerts_at(T1 + 8 * DAY) if a["type"] == "price_changed"])
check("alertas de problema ficam até a conferência seguinte (8 dias depois seguem ligados)", {"price_sources_diverge", "price_fixed_differs", "price_model_unpriced"} <= {a["type"] for a in alerts_at(T1 + 8 * DAY)})
check("alertas de preço aparecem em `checks` e na ordem de exibição", all(t in st.alerts(T1, acfg)["checks"] for t in A.PRICE_TYPES))

# resolvem na conferência seguinte
SONNET_FIXO = {"claude-sonnet-5": {"input": 3, "output": 15}}
serve({**ALL, **SONNET_FIXO}, {**ALL, **SONNET_FIXO}, OR_IDS)
tel2 = Rec()
out = P.check(st, cfg, tel2, now_ns=T2, urls=URLS, fetcher=fast, select_path=sel_path)
types2 = {a["type"] for a in alerts_at(T2 + HOUR)}
check("conferência seguinte, tudo igual: nenhuma linha nova e nenhuma troca", out["changes"] == 0 and len(st.read(P.history_rows)) == len(snapshot_1))
check("a divergência some quando as fontes passam a concordar (opus: igual)", "price_sources_diverge" not in types2 and cfg.prices.lookup("claude-opus-5-5").input == 4.0)
check("o alerta de preço fixo some quando as fontes concordam com o fixo", "price_fixed_differs" not in types2)
check("o sem preço segue enquanto o modelo segue sem preço (sem_fonte)", "price_model_unpriced" in types2)

# nunca apaga nem reescreve
now_hist = st.read(P.history_rows)
check("histórico só de acréscimo: toda linha de antes segue igual depois das conferências", all(r in now_hist for r in snapshot_1))
check("a rotina só escreve nas tabelas de preço: spans, logs e metrics intactos",
      all(st.read(lambda con, t=t: con.execute(f"SELECT count(*) FROM {t}").fetchone()[0]) == n for t, n in rows_before.items())
      and st.read(lambda con: con.execute("SELECT sha256(string_agg(dedupe_key, ',' ORDER BY dedupe_key)) FROM spans").fetchone()[0]) == other_before)
check("a rotina só escreve nas tabelas de preço: as únicas tabelas do banco são as da ingestão e as de preço",
      {r[0] for r in st.read(lambda con: con.execute("SELECT table_name FROM information_schema.tables WHERE table_schema = 'main'").fetchall())}
      == {"logs", "spans", "metrics", "price_history", "price_runs", "price_checks"})

# fonte fora do ar e as falhas
serve(ALL, ALL, OR_IDS, or_mode="500")
serve({**ALL, "gpt-5-codex": {"input": 2.0, "output": 10, "cache_read": 0.125}}, ALL, OR_IDS, or_mode="500")
tel3 = Rec()
out = P.check(st, cfg, tel3, now_ns=T3, urls=URLS, fetcher=fast, select_path=sel_path)
check("fonte fora do ar: o preço vigente fica (mesmo com a outra fonte mostrando valor novo)", out == {"changes": 0, "failures": {"openrouter": "http"}} and cfg.prices.lookup("gpt-5-codex").input == 1.5)
check("fonte fora do ar: telemetria com a falha da fonte e o código", tel3.runs == [(0, {"openrouter": "http"})])
check("fonte fora do ar: resultado por modelo = fonte_fora", {r["status"] for r in st.read(lambda con: P._rows(con, "SELECT status FROM price_checks WHERE checked_unix_nano = ?", [T3]))} == {"fonte_fora"})
check("fonte fora do ar: no 1º dia não alerta (só depois de 2 dias seguidos)", "price_source_down" not in {a["type"] for a in alerts_at(T3 + HOUR)})
out = P.check(st, cfg, Rec(), now_ns=T4, urls=URLS, fetcher=fast, select_path=sel_path)
down = [a for a in alerts_at(T4 + HOUR) if a["type"] == "price_source_down"]
check("fonte fora do ar: no 2º dia seguido alerta, com a fonte, o motivo e o último sucesso", len(down) == 1 and down[0]["value"] == 2 and down[0]["unit"] == "days"
      and down[0]["evidence"]["source"] == "openrouter" and down[0]["evidence"]["reason"] == "http" and down[0]["evidence"]["last_ok"] is not None
      and "2 dias seguidos" in alert_text.text(down[0]))
P.check(st, cfg, Rec(), now_ns=T4 + HOUR, urls=URLS, fetcher=fast, select_path=sel_path)
check("fonte fora do ar: duas conferências no mesmo dia contam um dia só", [a["value"] for a in alerts_at(T4 + 2 * HOUR) if a["type"] == "price_source_down"] == [2])
serve(ALL, ALL, OR_IDS)
P.check(st, cfg, Rec(), now_ns=T5, urls=URLS, fetcher=fast, select_path=sel_path)
check("fonte fora do ar: some quando a fonte volta", "price_source_down" not in {a["type"] for a in alerts_at(T5 + HOUR)})

# as duas fora, JSON inválido, resposta grande demais, falha interna
for i, (what, kw, code) in enumerate((("500", {"md_mode": "500", "or_mode": "500"}, "http"), ("lixo", {"md_mode": "lixo", "or_mode": "lixo"}, "json"),
                       ("grande demais", {"md_mode": "big", "or_mode": "big"}, "tamanho"))):
    serve(ALL, ALL, OR_IDS, **kw)
    t = Rec()
    out = P.check(st, cfg, t, now_ns=T5 + 2 * DAY + i * HOUR, urls=URLS, fetcher=fast, select_path=sel_path)
    check(f"as duas fontes com {what}: nenhuma troca, as duas falhas na telemetria, sem levantar",
          out == {"changes": 0, "failures": {"models.dev": code, "openrouter": code}} and t.runs == [(0, out["failures"])])
serve(ALL, ALL, OR_IDS)
def explode(url):
    raise RuntimeError("segredo-da-fonte")
t = Rec()
out = P.check(st, cfg, t, now_ns=T5 + 2 * DAY + 5 * HOUR, urls=URLS, fetcher=explode, select_path=sel_path)
check("erro inesperado ao ler uma fonte: vira a falha `interno` das duas, sem levantar e sem a causa no aviso",
      out == {"changes": 0, "failures": {"models.dev": "interno", "openrouter": "interno"}} and all("segredo-da-fonte" not in w[1] for w in t.warns))
check("histórico: a mesma (modelo, hora) não entra duas vezes e a linha antiga não é reescrita",
      st.transact(lambda con: (P._insert(con, "gpt-5-codex", C.ModelPrice(7, 7, 7, 7), "fontes", T1), P._insert(con, "m-teste", C.ModelPrice(7, 7, 7, 7), "fontes", T1))) == (False, True)
      and cfg.prices.lookup("gpt-5-codex").input == 1.5 and st.read(lambda con: con.execute("SELECT input FROM price_history WHERE model = 'gpt-5-codex' AND start_unix_nano = ?", [T1]).fetchone()[0]) == 1.5)
class C_:
    def __init__(self): self.adds = []
    def add(self, n, attrs=None): self.adds.append((n, attrs))
tr = object.__new__(telemetry.Telemetry)
tr.c_price_checks, tr.c_price_changes, tr.c_price_failures = C_(), C_(), C_()
tr.price_run(2, {}); tr.price_run(0, {"openrouter": "http"}); tr.price_run(0, {"openrouter": "http", "models.dev": "json"}); tr.price_run(0, {"rotina": "interno"})
check("telemetria real: conferências por resultado (ok, parcial, falha, falha), trocas e falhas por fonte e código",
      [a[1]["result"] for a in tr.c_price_checks.adds] == ["ok", "parcial", "falha", "falha"] and tr.c_price_changes.adds == [(2, None)]
      and [a[1] for a in tr.c_price_failures.adds] == [{"source": "openrouter", "reason": "http"}, {"source": "openrouter", "reason": "http"},
                                                        {"source": "models.dev", "reason": "json"}, {"source": "rotina", "reason": "interno"}])
saved_use = P.models_in_use
P.models_in_use = lambda *a: (_ for _ in ()).throw(RuntimeError("segredo-da-falha"))
t = Rec()
out = P.check(st, cfg, t, now_ns=T5 + 3 * DAY, urls=URLS, fetcher=fast, select_path=sel_path)
P.models_in_use = saved_use
check("falha interna da rotina: não levanta, devolve a falha e a telemetria conta", out == {"changes": 0, "failures": {"rotina": "interno"}} and t.runs == [(0, {"rotina": "interno"})])
check("falha interna: o aviso diz só o tipo do erro (a causa não vai ao texto)", t.warns and all("segredo-da-falha" not in w[1] for w in t.warns) and "RuntimeError" in t.warns[-1][1])
check("falha interna: o preço vigente e o histórico seguem como estavam", cfg.prices.lookup("gpt-5-codex").input == 1.5)
# transação: falha no meio da gravação não deixa meia conferência
saved_apply = P.apply
def half(con, now, wanted, results, fixed):
    saved_apply(con, now, wanted, results, fixed)
    raise RuntimeError("falha depois de gravar")
P.apply = half
n_runs = st.read(lambda con: con.execute("SELECT count(*) FROM price_runs").fetchone()[0])
P.check(st, cfg, Rec(), now_ns=T5 + 4 * DAY, urls=URLS, fetcher=fast, select_path=sel_path)
P.apply = saved_apply
check("falha no meio da gravação: rollback, nenhuma linha de conferência pela metade", st.read(lambda con: con.execute("SELECT count(*) FROM price_runs").fetchone()[0]) == n_runs)
t = Rec()
P.check(st, cfg, t, now_ns=T5 + 5 * DAY, urls=URLS, fetcher=fast, select_path=f"{tmp}/nao-existe.toml")
check("seletor ilegível: avisa e confere só os modelos em uso (a conferência segue)", any(k == "price-select" for k, _ in t.warns) and t.runs == [(0, {})])

# a conferência não segura o banco enquanto espera a fonte; o laço sobrevive a erro
serve(ALL, ALL, OR_IDS, or_mode="hang")
open(f"{ps}/hang", "w").write("3")
th = threading.Thread(target=lambda: P.check(st, cfg, Rec(), now_ns=T5 + 6 * DAY, urls=URLS, fetcher=partial(S.fetch, timeout=1), select_path=sel_path))
th.start(); time.sleep(0.4)
t0 = time.monotonic(); st.read(lambda con: con.execute("SELECT 1").fetchone()); waited = time.monotonic() - t0
check("rotina esperando a fonte: o banco segue livre para a ingestão e a API (< 0,3 s)", waited < 0.3 and th.is_alive())
th.join()
serve(ALL, ALL, OR_IDS)
calls = []
def flaky():
    calls.append(1)
    if len(calls) == 1: raise RuntimeError("erro de laço")
job = P.Job(flaky, interval=0.05)
job.start(); time.sleep(0.5); job.stop()
check("laço diário: roda na subida, sobrevive a erro e repete a cada intervalo", len(calls) >= 3)
n = len(calls); time.sleep(0.2)
check("laço diário: stop() para o laço", len(calls) == n and not job._thread.is_alive())

# GET /v1/prices (a visão), com o histórico de tudo isso
view = st.read(lambda con: P.view(con, cfg.fixed, T5 + HOUR))
vm = {m["model"]: m for m in view["models"]}
check("visão de preços: vigente, histórico, origem e vigência por modelo", vm["gpt-5-codex"]["current"]["input"] == 1.5 and vm["gpt-5-codex"]["current"]["origin"] == "fontes"
      and [h["origin"] for h in vm["gpt-5-codex"]["history"]] == ["config", "fontes"] and vm["gpt-5-codex"]["current"]["since"].endswith("Z"))
check("visão de preços: a trava e a última conferência de cada modelo", vm["claude-sonnet-5"]["fixed"] is True and vm["gpt-5-codex"]["fixed"] is False and vm["gpt-5-codex"]["last_check"]["status"] in P.STATUSES)
check("visão de preços: as duas fontes com a última conferência", {s["source"] for s in view["sources"]} == {"models.dev", "openrouter"} and all(s["last_run"] for s in view["sources"]))
st.close()
PY
check_py_lines "$TMP/py.out"
[[ "$fail" -eq 0 ]] || { echo "--- stderr do trecho em Python ---"; cat "$TMP/py.err"; }

# ================================================================ parte 2: o app de verdade (HTTP)
NOW="$(date +%s)"
cat > "$TMP/config.toml" <<'EOF'
[prices."gpt-5-codex"]
input = 1.25
output = 10.0
cache_read = 0.125
[prices."claude-sonnet-5"]
fixed = true
input = 3.0
output = 15.0
[prices."claude-opus-5-5"]
input = 4.0
output = 20.0
cache_read = 0.2
cache_creation = 5.0
EOF
printf '[default]\nclaude = "claude-opus-5-5"\ncodex = "gpt-6-luna"\n' > "$TMP/select.toml"
PYTHONPATH="$ROOT/tests/lib" python3 - "$TMP" "$NOW" <<'PY'
import json, sys
from price_json import models_dev, openrouter
from otlp_json import kv, rs, span
tmp, now = sys.argv[1], int(sys.argv[2])
res = {"host.name": "oute-server", "service.name": "codex_exec", "oute.agent": "codex"}
def call(model, t, tokens): return span("session_task.turn", t, 1, {"model": model, "codex.turn.token_usage.non_cached_input_tokens": tokens})
# gpt-5-codex: uma chamada antes da conferência da subida (now - 1 h) e outra depois dela (now + 1 h); o sonnet (fixo) e o
# gpt-9 (sem preço e sem fonte) estão em uso
json.dump({"resourceSpans": [rs(res, [call("gpt-5-codex", now - 3600, 1_000_000), call("gpt-5-codex", now + 3600, 1_000_000),
                                      call("claude-sonnet-5", now - 7200, 10), call("gpt-9-sem-fonte", now - 7200, 1000)])]}, open(f"{tmp}/traces.json", "w"))
all_ = {"claude-opus-5-5": {"input": 4, "output": 20, "cache_read": 0.2, "cache_creation": 5},
        "claude-sonnet-5": {"input": 2, "output": 10}, "gpt-5-codex": {"input": 1.5, "output": 10, "cache_read": 0.125},
        "gpt-6-luna": {"input": 0.1, "output": 0.5, "cache_read": 0.01, "cache_creation": 0.125}}
ids = {"claude-opus-5-5": "anthropic/claude-opus-5.5", "claude-sonnet-5": "anthropic/claude-sonnet-5"}
open(f"{tmp}/md.json", "w").write(models_dev(all_))
open(f"{tmp}/or.json", "w").write(openrouter({**all_, "claude-opus-5-5": {**all_["claude-opus-5-5"], "input": 5}}, ids))
PY
ps_body models.dev "$TMP/md.json"; ps_body openrouter "$TMP/or.json"
# 1ª subida, sem conferência: só a ingestão e a semente (ninguém vai à rede sem AGENT_STUDIO_PRICE_CHECK=1)
SENV=(AGENT_STUDIO_CONFIG="$TMP/config.toml" AGENT_STUDIO_SELECT_TABLE="$TMP/select.toml")
ps_reset
studio_start "$TMP/s" "${SENV[@]}" || { cat "$TMP/s/stderr"; die "agent-studio não subiu"; }
check "ingestão: traces = 200" test "$(post traces "$TMP/traces.json")" = 200
get() { curl -s -H "Authorization: Bearer $STUDIO_TOKEN" "$STUDIO_URL$1"; }
check "sem AGENT_STUDIO_PRICE_CHECK a subida não chama fonte nenhuma" test "$(ps_requests)" = 0
OUT="$(get /v1/prices)"
check "GET /v1/prices: a semente do config.toml (3 modelos, origem config)" jqe '(.models | length) == 3 and all(.models[]; .current.origin == "config" and (.history | length) == 1)' <<<"$OUT"
check "GET /v1/prices: o modelo fixo vem marcado" jqe '(.models[] | select(.model == "claude-sonnet-5") | .fixed) == true and (.models[] | select(.model == "gpt-5-codex") | .fixed) == false' <<<"$OUT"
check "GET /v1/prices: unidade e fontes (ainda sem conferência)" jqe '.unit == "USD por 1M tokens" and (.sources | length) == 2 and all(.sources[]; .last_run == null)' <<<"$OUT"
check "GET /v1/prices: sem credencial = 401" test "$(code "$STUDIO_URL/v1/prices")" = 401
check "GET /v1/prices: outro método = 405" test "$(code -X POST -H "Authorization: Bearer $STUDIO_TOKEN" "$STUDIO_URL/v1/prices")" = 405
studio_stop

# 2ª subida, com a conferência ligada: uma conferência na subida
ps_reset
studio_start "$TMP/s" "${SENV[@]}" AGENT_STUDIO_PRICE_CHECK=1 AGENT_STUDIO_PRICE_INTERVAL=3600 || { cat "$TMP/s/stderr"; die "agent-studio não subiu"; }
for _ in $(seq 1 100); do [[ "$(ps_requests)" -ge 2 ]] && break; sleep 0.1; done
for _ in $(seq 1 100); do get /v1/prices | jq -e '.sources[0].last_run != null' >/dev/null 2>&1 && break; sleep 0.1; done
check "conferência na subida: uma busca em cada fonte, GET, sem credencial nem cookie" bash -c 'test "$(jq -s "length" "$1")" = 2 && jq -se "all(.[]; .method == \"GET\" and .auth == \"\" and .cookie == \"\")" "$1" >/dev/null && jq -se "map(.source) | sort == [\"models.dev\", \"openrouter\"]" "$1" >/dev/null' _ "$(ps_log)"
OUT="$(get /v1/prices)"
check "GET /v1/prices: gpt-5-codex trocado pelas duas fontes (config → fontes), com a vigência" jqe '(.models[] | select(.model == "gpt-5-codex")) | .current.input == 1.5 and .current.origin == "fontes" and (.history | map(.origin)) == ["config", "fontes"] and .last_check.status == "trocado"' <<<"$OUT"
check "GET /v1/prices: opus divergiu (preço fica) e o fixo não trocou" jqe '(.models[] | select(.model == "claude-opus-5-5")) | .current.input == 4 and .current.origin == "config" and .last_check.status == "diverge"' <<<"$OUT"
check "GET /v1/prices: sonnet fixo segue em 3 (fixo_difere)" jqe '(.models[] | select(.model == "claude-sonnet-5")) | .current.input == 3 and .fixed == true and .last_check.status == "fixo_difere"' <<<"$OUT"
check "GET /v1/prices: modelo do seletor sem preço entra pelas fontes" jqe '(.models[] | select(.model == "gpt-6-luna")) | .current.origin == "fontes" and .current.input == 0.1 and .current.cache_creation == 0.125' <<<"$OUT"
check "GET /v1/prices: as duas fontes conferidas, ok" jqe 'all(.sources[]; .ok == true and .reason == null and .last_ok != null)' <<<"$OUT"
OUT="$(get /v1/alerts)"
check "GET /v1/alerts: os alertas de preço no pipeline (trocado, divergem, fixo difere, sem preço)" jqe '[.alerts[].type | select(startswith("price_"))] | unique == ["price_changed", "price_fixed_differs", "price_model_unpriced", "price_sources_diverge"]' <<<"$OUT"
check "GET /v1/alerts: o de troca é informativo e os outros são problema" jqe '[.alerts[] | select(.type | startswith("price_")) | {t: .type, l: .evidence.level}] | all(.[]; (.t == "price_changed") == (.l == "info"))' <<<"$OUT"
check "GET /v1/alerts: preço trocado com modelo, campo, antigo e novo" jqe '.alerts[] | select(.type == "price_changed" and .evidence.field == "input") | .evidence | .model == "gpt-5-codex" and .old == 1.25 and .new == 1.5 and .level == "info"' <<<"$OUT"
OUT="$(get /v1/tray)"
check "GET /v1/tray: os alertas de preço aparecem como os demais, com título e texto" jqe '[.alerts[] | select(.type | startswith("price_"))] | length == 5 and all(.[]; (.title | length) > 0 and (.text | length) > 0 and .title != .type)' <<<"$OUT"
check "GET /v1/tray: o título do preço trocado" jqe '.alerts[] | select(.type == "price_changed") | .title == "Preço trocado" and (.text | contains("gpt-5-codex"))' <<<"$OUT"
OUT="$(get "/v1/usage?from=$(date -u -d "@$((NOW - 10800))" +%Y-%m-%dT%H:%M:%SZ)&to=$(date -u -d "@$((NOW + 7200))" +%Y-%m-%dT%H:%M:%SZ)")"
check "GET /v1/usage: a chamada de antes da troca fica em 1,25 e a de depois usa 1,50 (soma 2,75)" jqe "$(usd '.rows[] | select(.model == "gpt-5-codex") | .cost.estimated_usd') == 2750000" <<<"$OUT"
check "GET /v1/usage: modelo sem preço continua sem estimativa (unpriced_models)" jqe '.unpriced_models == ["gpt-9-sem-fonte"]' <<<"$OUT"
check "a conferência não derruba a API: healthz e a ingestão seguem" bash -c 'test "$(curl -s -o /dev/null -w "%{http_code}" "$1/healthz")" = 200' _ "$STUDIO_URL"
studio_stop
check "só https: nenhuma busca saiu por outro esquema e todas foram a GET (log das fontes)" bash -c '! grep -q "\"method\": \"[^G]" "$1"' _ "$(ps_log)"

# fontes fora do ar na subida: a ingestão e a API seguem de pé, o preço vigente fica
ps_mode models.dev 500; ps_mode openrouter lixo
studio_start "$TMP/s" "${SENV[@]}" AGENT_STUDIO_PRICE_CHECK=1 AGENT_STUDIO_PRICE_INTERVAL=3600 || { cat "$TMP/s/stderr"; die "agent-studio não subiu"; }
for _ in $(seq 1 100); do get /v1/prices | jq -e '.sources[] | select(.source == "openrouter") | .ok == false' >/dev/null 2>&1 && break; sleep 0.1; done
OUT="$(get /v1/prices)"
check "fontes fora do ar: motivo por fonte (http e json) e o último sucesso guardado" jqe '(.sources[] | select(.source == "models.dev") | .ok == false and .reason == "http" and .last_ok != null) and (.sources[] | select(.source == "openrouter") | .reason == "json")' <<<"$OUT"
check "fontes fora do ar: o preço vigente continua" jqe '(.models[] | select(.model == "gpt-5-codex") | .current.input) == 1.5' <<<"$OUT"
check "fontes fora do ar: a ingestão segue (200)" test "$(post traces "$TMP/traces.json")" = 200
check "fontes fora do ar: /v1/usage e /v1/alerts seguem (200)" bash -c 'test "$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $2" "$1/v1/usage")" = 200 && test "$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $2" "$1/v1/alerts")" = 200' _ "$STUDIO_URL" "$STUDIO_TOKEN"
check "fontes fora do ar: o log diz a fonte e o código" bash -c 'grep -q "a fonte models.dev falhou (http)" "$1" && grep -q "a fonte openrouter falhou (json)" "$1"' _ "$TMP/s/stderr"
studio_stop

# falha interna da conferência: a ingestão e a API seguem
studio_start "$TMP/s" "${SENV[@]}" AGENT_STUDIO_PRICE_CHECK=1 AGENT_STUDIO_PRICE_INTERVAL=3600 STUDIO_FAIL_PRICE_CHECK=1 || { cat "$TMP/s/stderr"; die "agent-studio não subiu"; }
sleep 0.5
check "falha interna da conferência: a ingestão segue (200)" test "$(post traces "$TMP/traces.json")" = 200
check "falha interna da conferência: GET /v1/prices segue (200)" test "$(code -H "Authorization: Bearer $STUDIO_TOKEN" "$STUDIO_URL/v1/prices")" = 200
check "falha interna da conferência: a causa só no stderr (não na API)" bash -c 'grep -q "falha injetada na conferência" "$1"' _ "$TMP/s/stderr"
studio_stop

# leitura que falha = 500, sem a causa
studio_start "$TMP/s2" "${SENV[@]}" STUDIO_FAIL_PRICES=1 || { cat "$TMP/s2/stderr"; die "agent-studio não subiu"; }
OUT="$(get /v1/prices)"
check "GET /v1/prices: leitura que falha = 500 sem a causa" bash -c 'test "$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $2" "$1/v1/prices")" = 500' _ "$STUDIO_URL" "$STUDIO_TOKEN"
check "GET /v1/prices: a causa não chega à resposta" hasnt_str "falha injetada"
check "GET /v1/prices: a subida com o banco de preços falhando segue de pé (config.toml vale)" test "$(code "$STUDIO_URL/healthz")" = 200
studio_stop

# duas credenciais: leitura lê, ingestão não
READ_TOKEN="leitura-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
studio_start "$TMP/s3" "${SENV[@]}" AGENT_STUDIO_READ_TOKEN="$READ_TOKEN" || { cat "$TMP/s3/stderr"; die "agent-studio não subiu"; }
check "GET /v1/prices: a credencial de leitura lê (200)" test "$(code -H "Authorization: Bearer $READ_TOKEN" "$STUDIO_URL/v1/prices")" = 200
check "GET /v1/prices: a credencial de ingestão não lê (401)" test "$(code -H "Authorization: Bearer $STUDIO_TOKEN" "$STUDIO_URL/v1/prices")" = 401
studio_stop

# o compose: a única saída à internet do agent-studio, ligada e com a tabela do seletor só leitura
CS="$(compose_service agent-studio)"
OUT="$CS"
check "compose: a conferência de preços ligada no agent-studio" has 'AGENT_STUDIO_PRICE_CHECK: "1"'
check "compose: a tabela do seletor montada só leitura" has_line '      - ./config/select:/etc/oute/select:ro'
check "compose: AGENT_STUDIO_SELECT_TABLE aponta o arquivo montado" has_line '      AGENT_STUDIO_SELECT_TABLE: /etc/oute/select/models.toml'
check "código: as duas URLs fixas são https e as únicas do código de preços" bash -c 'cd "$1/docker/agent-studio/agent_studio" && test "$(grep -ho "\"https://[^\"]*\"" price_sources.py | sort -u | wc -l)" = 2 && ! grep -n "http:" price_sources.py prices.py price_alerts.py'  _ "$ROOT"

check_end
