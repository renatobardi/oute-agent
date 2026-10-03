# AGENTS.md — repositório oute-agent

Instruções para agentes (Claude Code, Codex) trabalhando **neste repositório**. As regras gerais (worktree por sessão, canal de aprovação, escopo de memória, issues) vêm das notas globais do container; aqui só o que é específico do oute-agent. Contexto e decisões: `CONTEXT.md`.

## O que é
Runtime em container para agentes de código (herdr + Claude Code, o principal, + Codex, a reserva; os dois por assinatura, com o modelo da sessão escolhido pela fase, ADR-02), memória compartilhada (ai-memory), storage no OCI e observabilidade (bucket OCI + agent-studio, ADR-08). Roda no `oute-server` (Oracle Cloud, arm64) e no Mac (Apple Silicon).

## Mapa do repo
- `docker/`: `Dockerfile`, `compose.yaml`, `entrypoint.sh` e os comandos do container (`oute-propose`, `oute-inbox`, `oute-emit` (eventos operacionais ao bucket e ao agent-studio, ADR-04 e ADR-08), `oute-agents-install` (claude/codex no home, com auto-update, #195; entrada conferida por sha256, #199), `oute-task`, `oute-select` (seletor de modelo por sessão, ADR-02, #219; chama o Jev na TypeSafe, #257), `oute-sonar` (lê do SonarCloud o gate, as issues e os hotspots de um PR ou da `main`; só GET, #226), `oute-quota` (lê a cota das assinaturas Claude e Codex, só GET e sem tocar na credencial, ADR-02, #346), `oute-regression` + `regression/` (nível 1 de regressão dos agentes: tarefas headless em Haiku, sob demanda, com dublês do canal de aprovação; evento `oute.regression.run`, #366), `oute-swarm` + `swarm.md`/`swarm-worker.md`, `comandos.md` (guia do `oute help`) + `oute-container`, `agent-wrap.sh`, `agent-notes.md`, `codex_config.py`). `docker/agent-studio/`: o agent-studio (ADR-08; Python, vai na imagem, serviço próprio no compose, só no oute-server).
- `addons/<tipo>/`: addons (ADR-06). Hoje só `addons/skills/oute-*` (skill de fluxo: `oute-aidlc-<fase>-<id>`, ADR-07) (`SKILL.md` com `name` = pasta). Montado read-only em `/opt/oute/addons`; o `docker/addons-link` (chamado pelo entrypoint) cria os links em `~/.claude/skills` e `~/.agents/skills`. Skill entra com `git pull` + `oute down/up`, sem release.
- `tests/`: testes em bash puro (`tests/*.test.sh`), rodados pelo workflow `pr` em todo PR. `tests/lib/`: apoio compartilhado entre os testes:
  - geral: `check.sh` (contagem dos casos: `check`/`ok`/`bad`/`jqe`/`die`/`has_pty`, casos vindos de Python, resumo e código de saída; e a conferência do `$OUT`: `has`/`hasnt` com regex, `has_line`/`hasnt_str` sem regex, sendo que conferência de outro alvo leva outro nome no teste, #246), `pycheck.py` (o `check` dos trechos em Python) e `check-lint.py` (acha `check` com condição fora dele; rodado pelo `tests/check-lib.test.sh`);
  - compose: `compose-config.sh` (wrapper de `docker compose config` com variáveis fictícias e profiles, usado por `tests/compose-config.test.sh` e `tests/agent-studio-auth.test.sh`);
  - regra: o `check` só conta o comando que recebe; condição composta vai inteira para dentro dele (`check "…" bash -c '[ … ] && grep …' _ …`) ou em `check`s próprios, nunca `check "…" [ … ] && …` (#285).
  - seletor de modelo (#219, #257, #313): `fake-gh-issue.sh` (o `gh issue view <n> --json labels` falso: labels por issue, `gh` fora do ar e `gh` que não responde), chamado pelo `gh` falso de cada teste; `typesafe.sh` + `fake-typesafe.py` (a TypeSafe falsa do Jev, com TLS: acerto, confiança baixa, erro, sem resposta; chave e certificado gerados na hora, pelo `openssl`, e leitura do que chegou). Teste que abre sessão chama `ts_off` no começo, para nunca usar a chave de verdade;
  - cota (#346): `fake-quota.py` (os endpoints de cota falsos do Claude e do Codex, com TLS, de qualquer método, com o que chegou em `requests.jsonl`), usado pelo `tests/oute-quota.test.sh`; certificado gerado na hora, pelo `openssl`;
  - entrypoint (#365): `fake-ai-memory.sh` (o `ai-memory` dublê: escreve `mcp_servers`, `hooks.state` com `trusted_hash` e hooks do Claude como o real, idempotente, com `.bak` ou sem, `FAKE_AI_MEMORY_BAK=0`), usado pelo `tests/entrypoint-config.test.sh` (a `setup_agents` e a `setup_ssh` reais, extraídas do `docker/entrypoint.sh`, em `HOME` temporário);
  - OTLP: `otlp.sh` + `otlp-receiver.py` (receptor OTLP falso e leitura do que chegou), `otlp-send.py` (envio de lotes), `otlp-pb-decode.py` e `otlp-pb-metrics.py` (leitura do protobuf recebido), `otlp_json.py` (peças para montar lotes de exemplo);
  - collector: `otelcol.sh` (binário fixado do `otelcol-contrib`; ambiente e config do collector de teste, `jqp` sobre o config impresso, subida do S3 falso e do collector, `otelcol_tally`/`wait_all` dos aceitos × recebidos, cenário do `kill -9` e o log no fim; conferido pelo `tests/otelcol-lib.test.sh`) e `fakes3.py` (S3 falso);
  - agent-studio: `agent-studio.sh` (venv, sobe e derruba o app, `post`/`code`/`hdr`/`data`/`enc`/`usd`, preços de exemplo, bloco de um serviço do compose, `studio_oute_up` = o `agent_studio_up` do `scripts/oute` num ambiente só do teste) + `agent-studio-run.py` (app com falha injetada), `surreal.sh` (SurrealDB fixado), `html-data.py` (HTML → JSON dos `data-*`) e `studio_asgi.py` (chama o app pelo ASGI; store e SurrealDB de mentira).
  - preços do agent-studio (#339): `fake-price-sources.py` (models.dev e OpenRouter falsos, com TLS: ok, 500, redirecionamento, sem resposta, grande demais, lixo; com o que chegou em `requests.jsonl`) + `price-sources.sh` (sobe a falsa, gera o certificado na hora pelo `openssl` e põe em `SSL_CERT_FILE`; `ps_off` tira URLs e certificado do ambiente) e `price_json.py` (corpos de exemplo no formato das duas fontes).
- `scripts/oute`: CLI do **host** (up/down/pull/approve/watch…). `scripts/release`: bump de versão + tag. `scripts/models-check`: confere os ids e esforços da tabela do seletor contra os CLIs instalados, sem chamar modelo (#220; roda no container, item do passo 6 da `oute-aidlc-ship-release`).
- `config/otel/`: pipelines do collector (`collector.yaml` = bucket; `agent-studio.yaml` = agent-studio; `none.yaml` = pipeline extra desligado). `config/agent-studio/`: preços e alertas do agent-studio. `config/select/models.toml`: tabela fase → modelo do seletor (ADR-02), montada read-only em `/opt/oute/select` (no `agent`) e em `/etc/oute/select` (no `agent-studio`, que confere os preços desses modelos, #339); entra com `git pull` + `oute down/up`.
- `.github/ISSUE_TEMPLATE/aidlc.md`: template de issue (AI-DLC).
- `VERSION`, `CHANGELOG.md` (Keep a Changelog, seção `[Unreleased]`), `README.md`.

## Regras
- **Entrega por PR.** Release (`scripts/release x.y.z` + tag) e deploy nos hosts são do Bardi.
- **Precisa de release:** mudança na imagem (Dockerfile, entrypoint, arquivos copiados). **Não precisa:** `scripts/oute`, `config/`, `docker/compose.yaml`, que entram com `git pull` (+ `oute down/up`).
- Toda mudança visível entra no changelog por **fragmento** (#121): o PR cria `changelog.d/<issue>-<slug>.md` com a subseção (`### Added`, `Changed`, `Deprecated`, `Removed`, `Fixed` ou `Security`) e a entrada, e **não edita o `CHANGELOG.md`**. Formato em `changelog.d/README.md`; conferir com `scripts/changelog check`. O `scripts/release` junta os fragmentos na seção da versão e os apaga no commit de release. Linha que já estava no `[Unreleased]` (PR aberto antes da #121) fica onde está e entra na mesma seção.
- `scripts/oute` roda também no **bash 3.2 do macOS**: nada de `mapfile`, `timeout`, `${var,,}`; array vazio com `set -u` só como `${a[@]+"${a[@]}"}`.
- Configs dos agentes (`~/.codex/config.toml`, `~/.claude/settings.json`, notas) só com edição **estrutural** (tomlkit, jq, bloco gerenciado). Nunca `sed` em arquivo que outra ferramenta também escreve.
- Scripts executáveis com modo `100755` (o CI recusa sem).
- **Apoio de teste compartilhado mora em `tests/lib/`:** função, dublê ou trecho usado por mais de um `tests/*.test.sh` fica lá (e no mapa do repo acima), nunca copiado. Quem precisa de um trecho embutido em outro teste move o trecho para `tests/lib/` e troca no teste de origem **no mesmo PR** (nada de segunda cópia, nem de lib nova com a cópia antiga ainda no lugar).
- **Workflows de CI (`.github/workflows/`) só pelo Bardi.** O `GH_TOKEN` dos agentes não tem o escopo `workflow`, de propósito: agente nenhum cria ou altera CI (o GitHub recusa o push e, na API, responde 404). O agente deixa o arquivo pronto e publica no PR um link para o editor web já preenchido (`https://github.com/<dono>/<repo>/new/<branch>?filename=<caminho>&value=<conteúdo url-encoded>`); o Bardi commita pela interface web. O resto do PR segue normal, com o workflow no `## Falta` até entrar. Não peça o escopo `workflow` para contornar, e o canal de aprovação também não serve (o host não tem credencial do GitHub). Workflow disparado só em `pull_request` é validado por um PR descartável (commit vazio, fechado sem merge).
- **Quando o CI roda** (#122): o workflow `pr` só em `pull_request`; o `image` só em tag `v*` (e manual, por `workflow_dispatch`). Push na `main` não roda workflow nenhum: o estado de CI de uma mudança se confere no PR (`gh pr checks <n>`), não no commit da `main`.
- **Canal de aprovação e restart do `agent`:** script proposto pode rodar `oute down`/`up`/`restart` (#210, com o `scripts/oute` do host atualizado: o resultado fica no host e é entregue quando o container volta). A sessão que propôs morre junto com o container: o `oute-inbox --wait` dela não volta; quem continua lê o resultado depois (`oute-inbox <id>`). Um pedido assim por vez, e por último na fila.
- **Nunca** publicar porta de container em `0.0.0.0`. Segredos só pelo Vaultwarden, lidos pelo host. Nada de BW_* no container. Segredo de serviço (só um serviço usa, ou dá escrita em algo que o Bardi lê para decidir) vai na pasta `oute-services` do vault e nunca chega ao `agent` (ADR-01, adendo #256; `secrets/README.md`).
- Telemetria no bucket `oute-observability` **nunca é apagada**. Ferramenta nova só entra se mandar consumo ao bucket + agent-studio (ADR-08 §11).
- Comportamento do **ai-memory** não muda sem decisão explícita do Bardi. Servidor e cliente sempre na mesma versão.
- Mudanças no host oute-server (usuários, sudoers, nginx, firewall, systemd) são do repo `renatobardi/lab`, não daqui.

## Fluxo AI-DLC (ADR-07)
Todo trabalho segue as fases do ADR-07. Cada fase tem um **gate humano** do Bardi: agente não fecha fase com gate. Issue nova pelo template `aidlc` e com o label `aidlc:<fase>`; ao mudar de fase, troque o label.

| Fase | Primitivos e skills |
|---|---|
| `strat` | `oute-aidlc-strat-opportunity`, `oute-aidlc-strat-research`, `oute-aidlc-strat-wayfinder` |
| `intent` | `oute-aidlc-intent-grill` (base: `oute-aidlc-intent-grilling`) |
| `spec` | issue pelo template `aidlc`, `oute-aidlc-spec-issue` |
| `arch` | `docs/adr/`, `CONTEXT.md`, `oute-aidlc-arch-grill`, `oute-aidlc-arch-deepen` |
| `design` | `oute-aidlc-design-modules`, `oute-aidlc-design-prototype` |
| `plan` | `oute-swarm` §1 (triagem + ok do Bardi), `oute-aidlc-plan-tickets`, `oute-aidlc-plan-triage`, `oute-aidlc-plan-refactor` |
| `build` | `oute-task`, worker do swarm, `oute-aidlc-build-implement`, `oute-aidlc-build-tdd`, `oute-aidlc-build-conflicts` |
| `qa` | `oute-aidlc-qa-pr-audit` (chama `oute-aidlc-qa-security-audit`), `tests/`, CI `pr` |
| `ship` | `oute-aidlc-ship-release` (checklist antes da release), `scripts/release` + deploy nos hosts (Bardi), `oute-aidlc-ship-verify` (pós-deploy pelo canal de aprovação) |
| `ops` | telemetria ADR-04 e ADR-08 (bucket + agent-studio, as duas fontes que a `ops-observe` lê), canal de aprovação, `oute-aidlc-ops-observe`, `oute-aidlc-ops-diagnose` |
| `learn` | `oute-swarm` §4.1 (kaizen, por rodada), `oute-aidlc-learn-insights` (fecha o ciclo: insights entre rodadas e fontes → lições e melhorias), `oute-aidlc-learn-feedback` |
| `iter` | `oute-aidlc-iter-roadmap` (abre o próximo ciclo: foco, issues e limpeza do backlog), issues de fim de sessão |
| `ctx` | `CONTEXT.md`, `AGENTS.md`, ai-memory, `oute-aidlc-ctx-router`, `oute-aidlc-ctx-domain`, `oute-aidlc-ctx-setup`, `oute-aidlc-ctx-sync` (confere os resumos contra os ADRs) |

Skill de fluxo nova entra nesta tabela no mesmo PR. Por onde começar: `oute-aidlc-ctx-router`. Utilitária: `oute-skill-writing` (escrever e editar skills).

## Validar antes do PR
- `bash -n` em todo script alterado.
- `docker compose config` (gate no CI pelo teste `tests/compose-config.test.sh`, não no container).
- Linker de addons: `tests/addons-link.test.sh`.
- Collector: `otelcol-contrib validate --config=config/otel/collector.yaml --config=config/otel/agent-studio.yaml` (os dois pipelines juntos, como no host com o agent-studio ligado).
- Script do host: pensar no caminho do Mac (bash 3.2, sem `timeout`, Docker Desktop).
- **SonarCloud é gate do PR** (#192): o check `SonarCloud Code Analysis` do head (`gh pr checks <n>`) faz parte do "CI verde", que só vale com ele concluído com sucesso; pendente não é verde. O motivo de um gate reprovado (condição, issues, hotspots) sai de `oute-sonar pr <n>` (#226; saída 1 = gate reprovado; precisa de `SONAR_TOKEN`). **Agente nunca chama endpoint de escrita do SonarCloud** (aceitar issue, marcar hotspot, mudar gate ou configuração): o `oute-sonar` só faz `GET`, e o agente propõe a justificativa no PR; a decisão é do Bardi, na UI. O que costuma derrubar a nota de segurança no código novo:
  - credencial literal, inclusive em teste (gerar aleatória);
  - dado vindo do cliente em log ou em resposta de erro;
  - SQL ou comando montado com entrada (usar parâmetros);
  - download sem checksum;
  - dependência sem versão travada;
  - `npm install` sem `--ignore-scripts`;
  - `http://` literal em arquivo novo, inclusive em teste, mesmo para nome de serviço interno do compose (o teste compara com a linha do `docker/compose.yaml` ou monta o endereço de partes: esquema, serviço e porta).
- **Exceção do `http://` interno:** `http://` para nome de serviço do compose na rede `oute` (só docker interno, ex.: `http://agent-studio:8430`) não se corrige no código: o agente declara o achado no corpo do PR e a `oute-aidlc-qa-pr-audit` o trata como não bloqueante. Não vale para host externo. Alcance: a linha que já existe em config (`docker/compose.yaml`, `config/`); em arquivo novo o literal não se repete (item da lista acima). Se o gate reprovar mesmo assim, o agente corrige (#295).
- Gate reprovado fora da exceção: o agente corrige. Dispensar o gate ou marcar achado no SonarCloud (falso positivo, aceito) é só do Bardi, registrado no PR.

## Agent skills

### Issue tracker

GitHub Issues de `renatobardi/oute-agent`, via `gh`. See `docs/agents/issue-tracker.md`.

### Triage labels

Defaults, exceto ready-for-agent → `ready` (label já existente). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` na raiz. See `docs/agents/domain.md`.
