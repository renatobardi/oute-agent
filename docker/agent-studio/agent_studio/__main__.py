"""`python -m agent_studio`: um processo, um worker (o DuckDB aceita um escritor só; ADR-08 §4)."""
import logging
import os
import sys

import uvicorn

from . import config as config_mod, price_sources, prices as prices_mod
from .app import create_app
from .store import Store
from .surreal import Surreal
from . import telemetry

MARK_TOKEN_MIN = 32  # tamanho mínimo da credencial de marcação (#577)


def price_urls():
    """As duas URLs de preço: as fixas do código; o ambiente só as troca para os testes, e só por `https://`."""
    urls = dict(price_sources.DEFAULT_URLS)
    for source, var in ((price_sources.MODELS_DEV, "AGENT_STUDIO_PRICE_URL_MODELS_DEV"),
                        (price_sources.OPENROUTER, "AGENT_STUDIO_PRICE_URL_OPENROUTER")):
        if os.environ.get(var):
            urls[source] = os.environ[var]  # `fetch` recusa o que não for https (E_URL)
    return urls


def main():
    logging.basicConfig(level=os.environ.get("AGENT_STUDIO_LOG_LEVEL", "INFO"),
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s", stream=sys.stderr)
    # duas credenciais (#256, ADR-08 §6). AGENT_STUDIO_TOKEN = nome de antes da #256, aceito como a de ingestão
    token = os.environ.get("AGENT_STUDIO_INGEST_TOKEN", "") or os.environ.get("AGENT_STUDIO_TOKEN", "")
    if not token:
        # sem o item agent-studio no vault o serviço não sobe (o `oute up` já avisa e não liga o profile)
        print("agent-studio: AGENT_STUDIO_INGEST_TOKEN vazio (item agent-studio da pasta oute-services do vault); "
              "não subo", file=sys.stderr)
        return 1
    read_token = os.environ.get("AGENT_STUDIO_READ_TOKEN", "")
    if not read_token or read_token == token:
        read_token = ""
        print("agent-studio: aviso: sem credencial de leitura própria (AGENT_STUDIO_READ_TOKEN vazio ou igual à de "
              "ingestão); uma credencial só para ingestão e leitura (transição da #256)", file=sys.stderr)
    # credencial de marcação (#510): terceira, só do navegador do Bardi (item agent-studio da pasta oute-services). Sem ela, ou igual a
    # outra das duas, a rota `POST /rodada/acao` não existe
    mark_token = os.environ.get("AGENT_STUDIO_MARK_TOKEN", "")
    if mark_token and mark_token in (token, read_token):
        print("agent-studio: aviso: AGENT_STUDIO_MARK_TOKEN igual à de ingestão ou à de leitura; sem marcação de ação "
              "(a credencial de marcação precisa ser própria)", file=sys.stderr)
        mark_token = ""
    if mark_token and len(mark_token) < MARK_TOKEN_MIN:
        # o agente alcança o studio pela rede docker e pode chutar o campo `token` do /marcar (#577): valor curto não vale
        print(f"agent-studio: aviso: AGENT_STUDIO_MARK_TOKEN com menos de {MARK_TOKEN_MIN} caracteres; sem marcação de ação "
              "(a credencial de marcação precisa ser longa)", file=sys.stderr)
        mark_token = ""
    # SurrealDB (#187): o compose sempre passa a URL; sem ela (só nos testes de ingestão), grava só no DuckDB
    surreal = None
    surreal_url = os.environ.get("AGENT_STUDIO_SURREAL_URL", "")
    if surreal_url:
        surreal_pass = os.environ.get("AGENT_STUDIO_SURREAL_PASS", "")
        if not surreal_pass:
            print("agent-studio: AGENT_STUDIO_SURREAL_PASS vazio (item agent-studio do vault); não subo", file=sys.stderr)
            return 1
        surreal = Surreal(surreal_url, os.environ.get("AGENT_STUDIO_SURREAL_USER", "root"), surreal_pass,
                          ns=os.environ.get("AGENT_STUDIO_SURREAL_NS", "oute"),
                          db=os.environ.get("AGENT_STUDIO_SURREAL_DB", "studio"))
    db = os.environ.get("AGENT_STUDIO_DB", "/data/agent-studio/agent-studio.duckdb")
    store = Store(db)
    # quanto vale o resultado do tray e dos alertas (#570); 0 = sempre refaz (o padrão, e o dos testes)
    store.read_ttl = float(os.environ.get("AGENT_STUDIO_READ_TTL_S", "0"))
    tel = telemetry.setup()
    # config/agent-studio/config.toml, montada só leitura (#203): problema nela não impede a subida
    config = config_mod.load()
    for err in config.errors:
        print(f"agent-studio: {err}", file=sys.stderr)
    for warn in config.warnings:
        print(f"agent-studio: aviso: {warn}", file=sys.stderr)
    # preços (#339): a semente do config.toml entra no histórico e o histórico vira a tabela viva; a conferência diária
    # nas fontes públicas só liga com AGENT_STUDIO_PRICE_CHECK=1 (o compose liga; teste e uso local ficam sem rede)
    prices_mod.sync(store, config)
    price_job = None
    if os.environ.get("AGENT_STUDIO_PRICE_CHECK") == "1":
        price_job = prices_mod.Job(lambda: prices_mod.check(store, config, tel, urls=price_urls()),
                                   float(os.environ.get("AGENT_STUDIO_PRICE_INTERVAL", prices_mod.DAY_NS // 10**9)))
    app = create_app(store, token, surreal, tel, on_shutdown=store.close, config=config, read_token=read_token,
                     price_job=price_job, mark_token=mark_token)
    uvicorn.run(app, host=os.environ.get("AGENT_STUDIO_BIND", "0.0.0.0"),
                port=int(os.environ.get("AGENT_STUDIO_PORT", "8430")),
                workers=1, access_log=False, log_config=None)
    return 0


if __name__ == "__main__":
    sys.exit(main())
