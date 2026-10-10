# AGENTS.md — repositório oute-agent

Instruções para agentes (Claude Code, Codex) trabalhando **neste repositório**. As regras gerais (worktree por sessão, canal de aprovação, escopo de memória, issues) vêm das notas globais do container; aqui só o que é específico do oute-agent. Contexto e decisões: `CONTEXT.md`. Texto que o agente escreve ao Bardi segue `docs/pt-controlado.md` (pt-BR, fonte que ele abre, recomendação rotulada; #478).

## O que é
Runtime em container para agentes de código (herdr + Claude Code, o principal, + Codex, a reserva; os dois por assinatura, com o modelo da sessão escolhido pela fase, ADR-02), memória compartilhada (ai-memory), storage no OCI e observabilidade (bucket OCI + agent-studio, ADR-08). Roda no `oute-server` (Oracle Cloud, arm64) e no Mac (Apple Silicon).

## Mapa do repo
O mapa detalhado (comandos do `docker/`, agent-studio, `tests/lib/`, `scripts/`, `tray/`, `config/`) fica em **`docs/mapa-repo.md`**, lido sob demanda: abra-o quando precisar saber onde algo mora ou qual teste cobre um arquivo. PR que cria comando, pasta ou teste novo atualiza o mapa lá. Resumo: `docker/` (imagem, comandos do container, agent-studio, prompts do swarm), `addons/skills/` (skills de fluxo, ADR-06 e ADR-07), `tests/` (bash puro, `*.test.sh`, apoio em `tests/lib/`), `scripts/` (CLI do host, release), `config/`, `tray/` (tray do Mac), `docs/` e `changelog.d/`.

## Regras
- **Entrega por PR.** Release (`scripts/release x.y.z` + tag) e deploy nos hosts são do Bardi.
- **Precisa de release:** mudança na imagem (Dockerfile, entrypoint, arquivos copiados). **Não precisa:** `scripts/oute`, `config/`, `docker/compose.yaml`, que entram com `git pull` (+ `oute down/up`).
- Toda mudança visível entra no changelog por **fragmento** (#121): o PR cria `changelog.d/<issue>-<slug>.md` com a subseção (`### Added`, `Changed`, `Deprecated`, `Removed`, `Fixed` ou `Security`) e a entrada, e **não edita o `CHANGELOG.md`**. Formato em `changelog.d/README.md`; conferir com `scripts/changelog check`. O `scripts/release` junta os fragmentos na seção da versão e os apaga no commit de release. Linha que já estava no `[Unreleased]` (PR aberto antes da #121) fica onde está e entra na mesma seção.
- `scripts/oute` roda também no **bash 3.2 do macOS**: nada de `mapfile`, `timeout`, `${var,,}`; array vazio com `set -u` só como `${a[@]+"${a[@]}"}`.
- Configs dos agentes (`~/.codex/config.toml`, `~/.claude/settings.json`, notas) só com edição **estrutural** (tomlkit, jq, bloco gerenciado). Nunca `sed` em arquivo que outra ferramenta também escreve.
- Scripts executáveis com modo `100755` (o CI recusa sem).
- **Teto de tamanho dos prompts fixos (#753).** `AGENTS.md`, `docker/agent-notes.md`, `docker/swarm-worker.md`, `docker/swarm.md` e cada `docker/swarm/*.md` têm teto em bytes em `docs/prompts-teto.md`, conferido por `tests/prompts-teto.test.sh`: PR que passa do teto falha. **Regra nova nesses arquivos entra tirando ou fundindo outra**, ou vira checagem em teste ou script (#652). Subir um teto é decisão do Bardi, no PR, com o motivo.
- **Apoio de teste compartilhado mora em `tests/lib/`:** função, dublê ou trecho usado por mais de um `tests/*.test.sh` fica lá (e no mapa do repo, `docs/mapa-repo.md`), nunca copiado. Quem precisa de um trecho embutido em outro teste move o trecho para `tests/lib/` e troca no teste de origem **no mesmo PR** (nada de segunda cópia, nem de lib nova com a cópia antiga ainda no lugar). **Teste que todo PR de uma área estende** (ex.: o `oute-swarm`) é dividido por tema, `tests/<nome>-<tema>.test.sh` com o apoio em `tests/lib/<nome>.sh`, para duas sessões que acrescentam caso em temas diferentes não editarem o mesmo trecho e não conflitarem no merge (#425; o laço `tests/*.test.sh` do CI já pega os arquivos).
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
  - `http://` literal em arquivo novo, inclusive em teste, mesmo para nome de serviço interno do compose (o teste compara com a linha do `docker/compose.yaml` ou monta o endereço de partes: esquema, serviço e porta);
  - condicional aninhada (`if` dentro de `if`, ou ternário dentro de ternário), regra S3358: separar em variável intermediária ou em `if`/`elif`.
- **Arquivo de teste de shell que o PR altera** (`tests/*.test.sh`, `tests/lib/`): o SonarCloud analisa o arquivo inteiro como código novo, então uma issue em função antiga dele pode reprovar o gate. Depois do push, o worker roda `oute-sonar pr <n>` e corrige o que aparecer **no arquivo que ele tocou**. Arquivo que o PR não tocou não se reescreve, e o gate não se muda.
- **Função de shell nova** (em `docker/`, `scripts/` e `tests/`): parâmetro posicional vai para uma variável `local` (`local x="$1"`) e a função termina com `return` explícito (`return 0`, ou `return $?` quando devolve o status do último comando). Regras SonarCloud: S7679 ("Assign this positional parameter to a local variable") e S7682 ("Add an explicit return statement at the end of the function"). Só vale para função nova; não reescrever as existentes. Exemplo mínimo:
  ```bash
  foo_new() {
    local input="$1"
    # corpo
    return 0
  }
  ```
- **Exceção do `http://` interno:** `http://` para nome de serviço do compose na rede `oute` (só docker interno, ex.: `http://agent-studio:8430`) não se corrige no código: o agente declara o achado no corpo do PR e a `oute-aidlc-qa-pr-audit` o trata como não bloqueante. Não vale para host externo. Alcance: a linha que já existe em config (`docker/compose.yaml`, `config/`); em arquivo novo o literal não se repete (item da lista acima). Se o gate reprovar mesmo assim, o agente corrige (#295).
- Gate reprovado fora da exceção: o agente corrige. Dispensar o gate ou marcar achado no SonarCloud (falso positivo, aceito) é só do Bardi, registrado no PR.

## Agent skills

### Issue tracker

GitHub Issues de `renatobardi/oute-agent`, via `gh`. See `docs/agents/issue-tracker.md`.

### Triage labels

Defaults, exceto ready-for-agent → `ready` (label já existente). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` na raiz. See `docs/agents/domain.md`.
