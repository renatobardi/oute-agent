"""Fontes públicas de preço (#339, ADR-08, adendo "Preços"): busca e leitura de models.dev e OpenRouter.

É a **única** chamada de saída do agent-studio: duas URLs fixas, só `https://`, `GET` sem credencial, sem cookie e
sem seguir redirecionamento, com tempo e tamanho máximos. O que volta é dado de terceiro: vira JSON validado e só
os números que passam na conferência (finitos, >= 0, abaixo de um teto) chegam ao resto do código; texto da fonte
nunca vai a log, a alerta nem a resposta (só os códigos de falha deste módulo).

- `Source` = nome, URL e leitor. `fetch(url)` devolve o corpo (bytes) ou levanta `SourceError(código)`; `parse_*`
  transformam o JSON em `{id da fonte: PartialPrice}` ou levantam `SourceError("formato")`.
- **Mapeamento de id** (`source_ids`): explícito por família + exceções em `OVERRIDES`; cada fonte tem o seu jeito de
  escrever o mesmo modelo. Modelo sem regra = sem fonte (nunca troca, nunca adivinha por semelhança).
- **Unidade:** models.dev traz USD por 1M tokens; OpenRouter, USD por token (texto). Tudo sai em USD por 1M, por
  `Decimal` (sem erro de ponto flutuante na conversão).
"""
import json
import math
import re
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request
from decimal import Decimal, InvalidOperation

MODELS_DEV, OPENROUTER = "models.dev", "openrouter"
SOURCES = (MODELS_DEV, OPENROUTER)
DEFAULT_URLS = {MODELS_DEV: "https://models.dev/api.json", OPENROUTER: "https://openrouter.ai/api/v1/models"}

MAX_BYTES = 32 * 2**20      # o models.dev tem ~5 MB hoje; acima disto a resposta é recusada sem ler o resto
TIMEOUT_S = 20              # por operação de rede (conexão, leitura)
DEADLINE_S = 60             # a busca inteira de uma fonte
MAX_USD_PER_MTOK = 100_000  # acima disto o número não é preço
FIELDS = ("input", "output", "cache_read", "cache_creation")

# códigos de falha (o único texto que sai de uma falha: nunca o corpo nem a mensagem da fonte)
E_URL, E_NET, E_TIMEOUT, E_HTTP, E_REDIRECT, E_SIZE, E_JSON, E_FORMAT = (
    "url", "rede", "tempo", "http", "redirecionamento", "tamanho", "json", "formato")

# provedor do models.dev e prefixo do OpenRouter, por família de modelo (primeira que casa)
FAMILIES = (("claude-", "anthropic"), ("gpt-", "openai"))
# exceções ao mapeamento por regra: {modelo nosso: {fonte: id na fonte}} (vazio = a regra serve a todos hoje)
OVERRIDES = {}
_DATE_SUFFIX = re.compile(r"-\d{8}$")
_MINOR_SUFFIX = re.compile(r"^(claude-.+?-\d)-(\d)$")


class SourceError(Exception):
    """Falha ao buscar ou ler uma fonte; `args[0]` é um dos códigos `E_*`."""

    @property
    def code(self):
        return self.args[0]


def _provider(model):
    for prefix, provider in FAMILIES:
        if model.startswith(prefix):
            return provider
    return None


def source_ids(model):
    """{fonte: id naquela fonte} do modelo `model` (nosso id, sem prefixo de provedor), ou `{}` se não há regra.

    - models.dev: `(provedor, mesmo id)`: `claude-opus-5-5` -> `("anthropic", "claude-opus-5-5")`.
    - OpenRouter: `provedor/id` com a versão no formato dele: sem a data no fim (`-20251001`) e com ponto entre os
      dois últimos números do Claude (`claude-opus-5-5` -> `anthropic/claude-opus-5.5`); `gpt-*` já usa ponto."""
    m = (model or "").lower()
    if "/" in m:
        m = m.rsplit("/", 1)[1]
    provider = _provider(m)
    if provider is None:
        return {}
    ids = {MODELS_DEV: (provider, m)}
    base = _DATE_SUFFIX.sub("", m)
    base = _MINOR_SUFFIX.sub(r"\1.\2", base) if m.startswith("claude-") else base
    ids[OPENROUTER] = f"{provider}/{base}"
    for source, source_id in OVERRIDES.get(m, {}).items():
        ids[source] = source_id
    return ids


# ---------------------------------------------------------------- busca
class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise SourceError(E_REDIRECT)


def https_only(url):
    """`url` se for `https://` com host; senão ValueError (nunca chega à rede)."""
    parts = urllib.parse.urlsplit(url)
    if parts.scheme != "https" or not parts.hostname or parts.username or parts.password:
        raise ValueError("a URL de preço precisa ser https:// sem credencial")
    return url


def fetch(url, max_bytes=MAX_BYTES, timeout=TIMEOUT_S, deadline=DEADLINE_S):
    """Corpo da resposta (bytes) de `GET url`. Só https, sem credencial, cookie ou redirecionamento; sem proxy do
    ambiente. Falha = `SourceError` com o código (url, rede, tempo, http, redirecionamento, tamanho)."""
    try:
        https_only(url)
    except ValueError:
        raise SourceError(E_URL) from None
    # o opener só conhece https: URL de outro esquema não tem handler (e `https_only` já recusou antes)
    opener = urllib.request.OpenerDirector()
    for handler in (urllib.request.HTTPSHandler(context=ssl.create_default_context()), _NoRedirect(),
                    urllib.request.HTTPDefaultErrorHandler(), urllib.request.HTTPErrorProcessor()):
        opener.add_handler(handler)
    req = urllib.request.Request(url, method="GET", headers={
        "User-Agent": "oute-agent-studio/price-check", "Accept": "application/json", "Accept-Encoding": "identity"})
    end = time.monotonic() + deadline
    try:
        with opener.open(req, timeout=timeout) as resp:
            if resp.status != 200:
                raise SourceError(E_HTTP)
            declared = resp.headers.get("Content-Length")
            if declared and declared.isdigit() and int(declared) > max_bytes:
                raise SourceError(E_SIZE)
            chunks, size = [], 0
            while True:
                chunk = resp.read(min(65536, max_bytes + 1 - size))
                if not chunk:
                    break
                size += len(chunk)
                if size > max_bytes:
                    raise SourceError(E_SIZE)
                if time.monotonic() > end:
                    raise SourceError(E_TIMEOUT)
                chunks.append(chunk)
            return b"".join(chunks)
    except SourceError:
        raise
    except urllib.error.HTTPError:
        raise SourceError(E_HTTP) from None
    except TimeoutError:
        raise SourceError(E_TIMEOUT) from None
    except urllib.error.URLError as e:
        raise SourceError(E_TIMEOUT if isinstance(e.reason, TimeoutError) else E_NET) from None
    except (OSError, ValueError):
        raise SourceError(E_NET) from None


# ---------------------------------------------------------------- leitura (JSON de terceiro = dado)
def _reject_constant(_name):
    raise ValueError("NaN/Infinity não é JSON")


def load_json(body):
    """JSON do corpo; qualquer defeito (UTF-8, sintaxe, NaN, aninhamento fundo demais) = `SourceError(E_JSON)`."""
    try:
        return json.loads(body.decode("utf-8"), parse_constant=_reject_constant)
    except (UnicodeDecodeError, ValueError, RecursionError):
        raise SourceError(E_JSON) from None


def _number(value, per_token):
    """USD por 1M tokens (float) de `value`, ou `None` se não é um número de preço válido (bool, texto fora do
    formato, negativo — o OpenRouter usa -1 para preço dinâmico —, não finito ou acima do teto)."""
    if isinstance(value, bool):
        return None
    try:
        if per_token:
            if not isinstance(value, str):
                return None
            d = Decimal(value.strip()) * 1_000_000
        elif isinstance(value, (int, float)):
            d = Decimal(repr(value))
        else:
            return None
    except InvalidOperation:
        return None
    if not d.is_finite() or d < 0 or d > MAX_USD_PER_MTOK:
        return None
    f = float(round(d, 9))
    return f if math.isfinite(f) else None


def _partial(raw, names, per_token):
    """{campo: USD/1M} dos campos presentes e válidos; `None` se `input` ou `output` falta ou é inválido (sem os dois
    não há preço). Cache ausente fica fora (a regra de concordância trata); cache inválido derruba o modelo."""
    if not isinstance(raw, dict):
        return None
    out = {}
    for field, name in zip(FIELDS, names):
        if name not in raw or raw[name] is None:
            continue
        v = _number(raw[name], per_token)
        if v is None:
            return None
        out[field] = v
    return out if "input" in out and "output" in out else None


def parse_models_dev(data):
    """`{(provedor, id): preço parcial}` do JSON do models.dev (`{provedor: {models: {id: {cost: {...}}}}}`).
    Os provedores das `FAMILIES` precisam existir com `models` (senão o formato mudou: `SourceError(E_FORMAT)`).
    Só o preço base (`cost.input/output/cache_read/cache_write`); faixas de contexto ficam de fora. Modelo sem
    preço válido não entra."""
    if not isinstance(data, dict):
        raise SourceError(E_FORMAT)
    out = {}
    for _, provider in FAMILIES:
        models = (data.get(provider) or {}).get("models") if isinstance(data.get(provider), dict) else None
        if not isinstance(models, dict):
            raise SourceError(E_FORMAT)
        for model_id, entry in models.items():
            price = _partial(entry.get("cost") if isinstance(entry, dict) else None,
                             ("input", "output", "cache_read", "cache_write"), per_token=False)
            if price is not None:
                out[(provider, model_id)] = price
    if not out:
        raise SourceError(E_FORMAT)
    return out


def parse_openrouter(data):
    """`{id: preço parcial}` do JSON do OpenRouter (`{data: [{id, pricing: {prompt, completion, …}}]}`; preço em USD
    por token, como texto). Modelo com preço inválido (ex.: -1) não entra."""
    rows = data.get("data") if isinstance(data, dict) else None
    if not isinstance(rows, list):
        raise SourceError(E_FORMAT)
    out = {}
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get("id"), str):
            continue
        price = _partial(row.get("pricing"), ("prompt", "completion", "input_cache_read", "input_cache_write"),
                         per_token=True)
        if price is not None:
            out[row["id"]] = price
    if not out:
        raise SourceError(E_FORMAT)
    return out


PARSERS = {MODELS_DEV: parse_models_dev, OPENROUTER: parse_openrouter}


def read(source, url, fetcher=fetch):
    """Busca e lê uma fonte: `{id na fonte: preço parcial}`. Levanta `SourceError`."""
    return PARSERS[source](load_json(fetcher(url)))
