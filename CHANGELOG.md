# Changelog

Formato: [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/). Versionamento: [SemVer](https://semver.org/lang/pt-BR/).

## [Unreleased]

### Added
- **Skill `oute-aidlc-qa-security-audit`** (#106, fase `qa`). Auditoria de segurança de um diff, só por leitura: segue cada dado não confiável até o sink e cobre shell e quoting, segredos, portas/binds/rede/TLS, arquivos e caminhos, canal de aprovação, supply chain em runtime e instruções de agente em addons, com cenário concreto por achado e escala própria (alto/médio/baixo/incerto). Complementa a `oute-aidlc-qa-pr-audit` sem repetir o trust gate de mudança hostil nem a supply chain declarada (passos 4 e 5 dela), que a chama no checklist de segurança e converte os achados. Sem release (addon entra com `git pull` + `oute down/up`).
- **Skill `oute-aidlc-strat-opportunity`** (#110, ADR-07): tema → oportunidade e viabilidade (evidência citada, encaixe nos ADRs, alternativas com "não fazer") → parecer com gate do Bardi (`seguir`/`pesquisar mais`/`arquivar`) → issue pelo template `aidlc`, `aidlc:intent`, com a Intenção (problema, público, critério de sucesso) preenchida; critérios de aceite ficam para a `spec`. Linha `strat` do `AGENTS.md` e do `oute-aidlc-ctx-router`. Sem release (addon entra com `git pull` + `oute down/up`).
- **Skill `oute-aidlc-ops-observe`** (#108, fase `ops`). Lê, só leitura e só metadados, o Langfuse (API v2 de métricas; a legada responde 410) e o bucket `oute-observability` (listagem + allowlist de chaves no `jq`) e resume saúde, custo e anomalias por host × agente: `sem-telemetria`, `sinal-faltando`, `agente-sem-telemetria`, `sem-oute.agent`, `agente-unknown`, `erro-alto`, `custo-alto`. Script `observe.sh` na pasta da skill; segredos só pelo ambiente. `AGENTS.md` e `oute-aidlc-ctx-router` citam a skill na fase `ops`. Sem release (addon entra com `git pull` + `oute down/up`).
- **Fase `ship`: skills `oute-aidlc-ship-release` e `oute-aidlc-ship-verify`** (#107). `ship-release` é o checklist antes do `scripts/release` (precisa de release pelos `COPY` do `Dockerfile`, cobertura do `[Unreleased]`, versão proposta, pré-condições) e entrega o comando ao Bardi; `ship-verify` propõe pelo canal de aprovação o `verify-host.sh` (só leitura, bash 3.2): versão do repo e da imagem rodando, serviços do compose e presença de telemetria recente no bucket `oute-observability`, com `OK`/`AVISO`/`FALHA`. Teste `tests/ship-verify.test.sh`. Linha `ship` do `AGENTS.md` e do `oute-aidlc-ctx-router`. Sem release (addons entram com `git pull` + `oute down/up`).

## [0.7.25] - 2026-09-27

### Added
- **Skills de engenharia do Matt Pocock como `oute-aidlc-*`** (#105, ADR-06 adendo). Fork sem procedência, só no container: `strat-research`, `strat-wayfinder`, `intent-grilling`, `intent-grill`, `spec-issue`, `arch-grill`, `arch-deepen`, `design-modules`, `design-prototype`, `plan-refactor`, `plan-triage`, `plan-tickets`, `build-implement`, `build-tdd`, `build-conflicts`, `ops-diagnose`, `learn-feedback`, `ctx-domain`, `ctx-setup`, a utilitária `oute-skill-writing` e o roteador novo `oute-aidlc-ctx-router` (mapa das 12 fases). Referências entre skills renomeadas; `build-implement` faz autorrevisão (Spec + Standards) no lugar do `code-review`; handoff só pelo ai-memory; plano B sem subagente (Pi). `AGENTS.md` (Fluxo AI-DLC) e `docs/agents/` com os nomes novos. Sem release (addons entram com `git pull` + `oute down/up`).
- **AI-DLC (ADR-07).** Todo trabalho segue 12 fases, com abreviações `strat` `intent` `spec` `arch` `design` `plan` `build` `qa` `ship` `ops` `learn` `iter` e a faixa transversal `ctx`; cada fase tem contribuição da IA, gate humano (Bardi) e outcome. Skill de fluxo = `oute-aidlc-<fase>-<id>` (ADR-06, adendo), abrindo com a linha `Fase · Outcome · Gate`. `AGENTS.md` ganha a seção "Fluxo AI-DLC" (primitivos e skills por fase) e o `CONTEXT.md`, os termos AI-DLC, fase, gate humano e outcome. Template de issue `.github/ISSUE_TEMPLATE/aidlc.md` (Intenção, Contexto, Critérios de aceite, Fora de escopo) e labels `aidlc:<fase>`.

### Changed
- **`oute-pr-audit`: opção numerada com o número do PR vale como pedido de merge** (#98, passo 13, "o quê"). A escolha, pelo Bardi, de uma opção numerada que traz o PR e a ação de merge (ex.: `1. mergear #94 (squash) no head 5bfec3e`) é pedido explícito para aquele PR e só para o head citado; se o head mudou desde a opção, o pedido não vale e a pergunta é refeita com o head novo. Alinha a skill ao `swarm.md` §3 (#96). Sem release: a skill entra com `git pull` + `oute down/up`.
- **Swarm: fechamento cancela handoff de coordenadora de rodada já fechada** (#99, `swarm.md` §4.3). Depois do resumo final, a coordenadora cancela também os handoffs que coordenadoras de rodadas anteriores deixaram ao terminar (inclusive ela mesma), identificados pelo `summary` que cita "coordenadora da rodada `<id>`", com `<id>` diferente da rodada atual, e só quando o `oute-swarm list` mostra a rodada sem nenhuma aba aberta. Handoff de rodada com aba aberta, de rodada fora do `oute-swarm list` ou não identificável fica e vai numa nota do resumo. Antes, só os handoffs das worktrees removidas eram cancelados, e o da coordenadora sobrava para a sessão seguinte do projeto (no fechamento da `swarm-0926-2359` apareceu o da `swarm-0926-2252`). O `swarm.md` entra na imagem: **precisa de release**.
- **`oute-pr-audit` → `oute-aidlc-qa-pr-audit`** (ADR-07). Marcadores dos comentários migram para `<!-- oute-aidlc-qa-pr-audit -->` e `<!-- oute-aidlc-qa-pr-audit:merge -->`; a skill de segurança citada passa a `oute-aidlc-qa-security-audit`. Sem release (addon entra com `git pull` + `oute down/up`).
- **Swarm e notas globais citam as fases** (`swarm.md`: triagem `plan`, sessões `build`, auditoria `qa`, kaizen `learn`, issue kaizen com `aidlc:spec`; `swarm-worker.md`: fase `build`). `agent-notes.md` corrige a fonte canônica: são os ADRs em `docs/adr/` do repo, não o Project do claude.ai. `swarm.md`, `swarm-worker.md` e `agent-notes.md` entram na imagem: **precisa de release**.

## [0.7.24] - 2026-09-27

### Changed
- **Swarm: a confirmação de ação irreversível vai na opção numerada** (#96, `swarm.md` §3). A opção que leva a merge, `oute-swarm close … --yes`, `oute-task clean --yes` ou `tell` que manda aplicar no host já traz PR(s), estratégia e head curto (ou a aba/comando), ex.: `1. mergear #94 (squash) no head 5bfec3e e depois #95 (squash) no head e6bbdc4`, e a resposta do Bardi a ela é a confirmação. Antes de executar, a coordenadora confere head, base e estado de cada PR e da aba; se algo mudou, refaz a pergunta. Pedido livre ("pode mergear") recebe a opção completa e espera a escolha. O eco de uma linha na hora da ação fica só como registro: a regra anterior ("só execute se não houver mensagem nova do Bardi") prometia uma pausa que não existe, e na rodada `swarm-0926-2359` o eco e o merge saíram no mesmo turno. O `swarm.md` entra na imagem: **precisa de release**.
- **Coordenadora do swarm confirma em uma linha antes de ação irreversível** (#78, `swarm.md` §3). Antes de merge, `oute-swarm close … --yes`, `oute-task clean --yes` ou `tell` que manda aplicar no host, ela ecoa numa linha o que vai fazer (PR, estratégia, head: `vou mergear o #75 (squash) no head a1db228`) e só executa se não houver mensagem nova do Bardi. Se a correção dele chegar durante ou depois da ação, ela para, diz o que já foi feito e o que dá para desfazer e pede a decisão, sem desfazer nada sozinha. Opção de merge sempre com o número do PR no texto (`1. mergear #75`). Na rodada `swarm-0926-2039`, um "2" seguido de "na vdd queria a 3" virou merge do #75 com a decisão já trocada. O `swarm.md` entra na imagem: **precisa de release**.

### Fixed
- **Storage: `rclone mount` não morre mais com o terminal** (`scripts/oute`). O `--daemon` do rclone ficava no grupo de processos e na sessão do terminal que rodou o `oute up`/`oute update`: um Ctrl+C ou o fechamento do terminal matava o mount, e o `/data/shared` do container ficava `Transport endpoint is not connected` até um `oute down/up` (visto no oute-server em 2026-09-26). No Linux o mount sobe com `setsid -w`, em sessão própria; no macOS, sem `setsid(1)`, segue como antes. E o `oute up`/`sync-shared` reconhece um mount morto (listado, mas o `ls` dá `Transport endpoint is not connected`, ou `Device not configured` no macOS), desmonta, monta de novo e avisa que um container já de pé precisa de `oute restart`; outro erro do `ls` (bucket fora do ar) não derruba um mount vivo. Sem release: `scripts/oute` entra com `git pull`.
- **`addons-link`: avisos de falha completos** (#87). Quando o `rm` do link de uma skill recusada falha, sai `[oute] addons: AVISO: não consegui remover o link de skill recusada <link>: <motivo>` (antes: nenhum aviso, e o erro do `rm` sem prefixo), com código 0. O aviso de falha do `ln -s` passa a trazer o motivo (a mensagem do `ln`). No teste (`tests/addons-link.test.sh`), o `snapshot` falha quando o `find` falha ou o caminho não existe, em vez de devolver uma saída parcial que a comparação "mesmo estado" aceitava; 3 casos novos (rm falho, ln falho, snapshot de caminho inexistente). O linker entra na imagem: **precisa de release**.

## [0.7.23] - 2026-09-26

### Added
- **Retrospectiva kaizen no fechamento da rodada** (#86, parte da #54, `swarm.md` §4). Com os PRs da triagem resolvidos (confirmado com o Bardi), a coordenadora lê o log da rodada e o `gh` (auditorias, commits pós-auditoria, CI vermelho) e lista lições numeradas: fato + evidência, regra proposta, nível (`repo`/`swarm`/`agentes`/`skill`) + arquivo e sugestão (`issue` | `issue+sessão`). Só é lição o que tem evidência e regra concreta, sem duplicar regra existente nem issue `kaizen` aberta; flake de infra, decisão do Bardi e estilo ficam fora, e "sem lições" vale. O Bardi escolhe por número (`1 sessão, 2 issue, 3 descarta`); para cada escolhida, issue com label `kaizen` (criado se faltar) no repo do nível (`repo` = repo alvo; demais = oute-agent), com Contexto/Mudança/Critérios de aceite/Fora de escopo, e, se `sessão`, `oute-swarm spawn … --repo <destino> --kaizen` com o acompanhamento normal (repo fora do `/workspace`: só a issue, com aviso). O fechamento final (`close --all`, `oute-task clean`, handoffs) espera os PRs kaizen, e o resumo traz lição → issue → PR com **precisa de release** nos níveis `swarm`/`agentes`. Sem kaizen do kaizen. `comandos.md` menciona a retrospectiva. O `swarm.md` e o `comandos.md` entram na imagem: **precisa de release**.
- **`oute-swarm spawn --repo <repo> --kaizen` e `watch` multi-repo** (#85, parte da #54). A coordenadora abre sessão num repo do `/workspace` diferente do da rodada (`--repo`: nome ou caminho; inexistente falha com `repo não encontrado`), e `--kaizen` marca a sessão kaizen, que não conta no `--max`. O registro da rodada (`spawned`) grava o repo e o tipo de cada sessão; linhas antigas, sem os campos, valem como repo da rodada. O `watch` consulta PRs/CI de cada repo distinto das sessões e casa PR ↔ sessão por repo + número: PR e issue de outro repo aparecem como `lab#12`, sem colidir com o `#12` da rodada, e os do repo da rodada continuam `#12`, sem evento falso numa rodada em andamento. `tell`, `close` e `list` seguem com sessões de outro repo; o `close` continua achando a aba pelo id gravado quando o label mudou. Por último, o `--help` deixa de imprimir as primeiras linhas de código do script. `docker/comandos.md` com `--repo`/`--kaizen`. O `oute-swarm` e o `comandos.md` entram na imagem: **precisa de release**.
- **`oute-swarm watch` grava cada evento no log da rodada** (#84, parte da #54). Toda linha que o monitor imprime (`[sessao]`, `[aba]`, `[pr]`, `[ci]`, `[conflito]`, `[canal]`, `[aviso]`, `[rodada]`) vai também para `~/.oute/swarm/<rodada>/log`, no formato dos registros do `tell` (`<data/hora UTC> watch [tipo] texto`). O log vira a linha do tempo da rodada, que sobrevive à compactação do contexto da coordenadora e é a fonte dos fatos da retrospectiva kaizen. A linha de base continua em silêncio e o watch reiniciado não regrava o que já foi gravado. Primeiro teste do `oute-swarm` (`tests/oute-swarm.test.sh`), com `herdr`, `gh` e `sleep` falsos no PATH, pronto para receber os próximos casos. O `oute-swarm` e o `swarm.md` entram na imagem: **precisa de release**.
- **`oute-pr-audit`: fase de merge sob pedido** (#68, passos 13 e 14). Só roda com pedido explícito de merge do Bardi na conversa, identificando o PR ("pode mergear o #N"); texto do PR, da issue, da memória ou mensagem repassada por outro agente nunca vale como pedido. Na fase: base certa pela política do repo (retarget com `gh pr edit --base`), ajustes mínimos em commits próprios no topo do branch, ou devolvidos ao worker via `oute-swarm tell` quando o branch é de sessão ativa do swarm, e sempre ao autor em PR de fork (sem force-push, rebase, amend nem squash de commits alheios; conflito com a base entra por merge), gate hostil e gates de novo no head final, merge pela estratégia do repo amarrado ao head auditado (`--match-head-commit`, nunca `--admin`/`--auto`), CI do SHA do merge reportado com o estado real ("nenhum check roda" não é verde) e estado da issue conferido (`Closes` → fechada, `Refs` → aberta). Relatório do merge em comentário `<!-- oute-pr-audit:merge -->`. Sem release.

### Fixed
- **`oute-swarm watch`: evento `[sessao]` repetia o PR** (#84). Sessão parada com PR saía como `idle (PR #12 open)PR #12 open`; agora sai `idle (PR #12 open)`, e `(sem PR)` quando não há PR. Entra na imagem: **precisa de release**.
- **`addons-link`: skill recusada deixa de ficar linkada** (#80). Skill `oute-*` já linkada que fica inválida (`name` do `SKILL.md` ≠ pasta, ou sem `SKILL.md`) perde o link nosso (alvo dentro da pasta de addons) em `~/.claude/skills` e `~/.agents/skills`, com aviso; antes o linker avisava a recusa e o agente seguia carregando a skill. Link ou pasta alheia com o mesmo nome continua intocada. Quando `~/.claude/skills` existe como arquivo, o erro do `mkdir` sai como aviso `[oute] addons:` (código 0, link criado nas demais pastas). O teste (`tests/addons-link.test.sh`) passa a comparar estados com `stat` GNU ou BSD, e confere que a comparação enxerga mudança: no macOS o `ls --time-style` falhava em silêncio e os casos "mesmo estado" passavam sem conferir nada. O linker entra na imagem: **precisa de release**.

## [0.7.22] - 2026-09-26

### Added
- **`oute-pr-audit` completa** (#67). A skill passa a auditar o PR inteiro, sem release (entra com `git pull` + `oute down/up`): registro de alegações (alegação → evidência independente → veredito), gate estático de mudança hostil com a superfície sensível do oute-agent (Dockerfile, entrypoint, compose/portas, CLI do host, canal de aprovação, workflows, segredos, telemetria, addons), supply chain/CI (typosquatting, pin, lockfile, permissões de workflow, secrets, actions sem pin), gates do `AGENTS.md` da base rodados numa worktree própria e sem segredos (declarando o que não rodou; pendente ou pulado nunca é aprovado; teste que falha na base e passa no head), eixo Standards (regra citada, violação dura × julgamento, slop bar como bloqueio, code smells do code-review do Matt Pocock com atribuição), checklist funcional (compõe a `oute-security-audit` pelo nome, com checklist inline de plano B), severidade CRITICAL/BLOCKING/SHOULD-FIX/NIT/UNCERTAIN, gate de dúvida e vários PRs um por vez. O relatório único traz as seções Spec e Standards separadas.
- **Coordenadora do swarm audita o PR antes de pedir merge** (#69, `swarm.md` §3). Usa a skill `oute-pr-audit` quando ela está disponível; sem addons, segue o plano B inline, só leitura: `Closes`/`Refs` × critérios de aceite + `## Falta`, gates do `AGENTS.md` da base (CI pendente ou pulado não conta), `headRefOid` anotado e conferido antes de pedir o merge, superfície sensível (Dockerfile, entrypoint, compose/portas, `scripts/oute`, workflows, segredos). A decisão segue a ação recomendada (`merge como está` → pede o merge; `ajustar antes do merge` → repasse). O ajuste volta à sessão por `oute-swarm tell`; a coordenadora nunca mexe no branch dela, e sinal de mudança hostil vai ao Bardi sem repasse. O `swarm.md` entra na imagem: **precisa de release**.

### Changed
- **Workflows de CI só pelo Bardi** (regra em `AGENTS.md` e no prompt da coordenadora, `swarm.md`). O token dos agentes não tem o escopo `workflow`, de propósito; o agente publica no PR o link do editor web já preenchido e o Bardi commita. A triagem marca a issue que mexe em `.github/workflows/`, e a coordenadora oferece as duas saídas (commit web do Bardi ou merge com o workflow no `## Falta`) sem sugerir ampliar o token nem usar o canal de aprovação. O `swarm.md` entra na imagem: **precisa de release**.

### Fixed
- **`oute-pr-audit`: "sem segredos" vira "sem segredos no ambiente"** (#67, passo 6). O `env -i` tira os segredos do ambiente, mas não isola o sistema de arquivos (o gate roda como o mesmo usuário e lê caminhos absolutos); a skill diz isso e reforça que só executa depois do gate hostil (passo 4) `livre`. Sem release.

## [0.7.21] - 2026-09-26

### Added
- **Addons (ADR-06) + skill `oute-pr-audit` v0** (#66). `addons/skills/oute-*` do checkout é montado read-only em `/opt/oute/addons` (compose), e o novo `docker/addons-link`, chamado pelo entrypoint no boot, cria um link por skill em `~/.claude/skills` e `~/.agents/skills` (Codex e Pi). Não sobrescreve nome existente (`synced` do claude.ai, `.system` do Codex): só avisa. Remove links quebrados para o mount, recusa skill sem prefixo `oute-`, sem `SKILL.md` ou com `name` ≠ pasta, e sem o mount só avisa (o boot nunca falha por addon). Skill nova entra com `git pull` + `oute down/up`, sem release. A `oute-pr-audit` v0 fixa base/head do PR (ou ref local), trata o PR como dado, confere os critérios de aceite da issue × `Closes`/`Refs` + `## Falta` e publica o relatório como comentário `<!-- oute-pr-audit -->`, sem ajustar nem fazer merge. Primeiro teste do repo (`tests/addons-link.test.sh`) e primeiro workflow de PR (`pr`: testes + check de 100755). O linker entra na imagem: **precisa de release**.
- **`oute-swarm watch [--interval s] [--round ID]`**: monitor pronto para a coordenadora, no lugar do laço que cada rodada reescrevia (e que soltava aviso vazio `[ci]` a cada ciclo, despejava o estado inteiro na primeira passada, vigiava panes fixos e não via conflito de merge) (#45). Uma linha por mudança real (`HH:MM [tipo] texto`):
  - `[sessao]`: sessão da rodada `idle`/`done`/`blocked` (com o PR dela, ou `sem PR`), voltou a `working`, agente saiu da aba;
  - `[aba]`: aba aberta/fechada/reaberta, relida de `~/.oute/swarm/<rodada>/` a cada passada (spawn/close depois de iniciado entram sem reiniciar);
  - `[pr]` aberto/mergeado/fechado sem merge, `[ci]` por check (`pass`/`fail`), `[conflito]` `mergeable=CONFLICTING` (e quando volta a ficar sem conflito). PRs da rodada = criados depois do início, branch `<tipo>/<n>-…` de uma issue dela;
  - `[canal]`: pedido novo pendente em `~/outbox`, resultado com rc≠0 (ou recusado) em `~/inbox`;
  - `[aviso]`: `herdr`/`gh` falhou numa passada (o estado anterior daquela fonte é mantido, sem evento falso) e quando volta.
  - Estado normalizado em `~/.oute/swarm/<rodada>/watch.state`: a primeira passada da rodada só grava a linha de base; um watch reiniciado (monitor expirou) compara com o último estado salvo. Um watch por rodada: o mais novo assume e o antigo sai. Default a cada 60 s (mínimo 10).
  - `oute-swarm close --all --yes` grava `~/.oute/swarm/<rodada>/fechada` quando não sobra aba aberta, e o watch sai sozinho.
- `swarm.md` §3: a coordenadora roda `oute-swarm watch --round <rodada>` como monitor e o reinicia ao expirar; `comandos.md` com o subcomando.

### Changed
- **Sem sessão do Vaultwarden em cache no host** (#21). `~/.oute/bw_session` era uma chave viva para o cofre inteiro (todos os projetos + `oute-admin`), em disco o tempo todo e dentro dos backups. Agora `~/.oute/agent.env` é o cache do host, e o vault só é aberto com a master password digitada. A sessão fica só no processo e é trancada (`bw lock`) logo em seguida, inclusive em erro/Ctrl+C.
  - `oute up` com `agent.env` presente **não pede senha** e não toca no vault. `oute up --refresh-secrets` e o novo `oute secrets refresh` releem a pasta `oute-agent` e regravam `agent.env` (sem `agent.env`, o `up` também lê o vault).
  - `oute pull`, `sync-shared`/`storage` e `router-sync` (inclusive o cron das 04:00) usam só o ambiente ou `agent.env`, sem vault e sem tty. Faltou a variável: `… ausente em ~/.oute/agent.env; rode: oute secrets refresh`.
  - O `router-sync` normal não busca mais a `OPENROUTER_MGMT_KEY` (só avisa que o guardrail não foi verificado). `oute router-sync --check-guardrail` lê a pasta `oute-admin` com a senha e tranca.
  - `oute oci-bootstrap` abre a sessão na hora (senha), passa ao container por env, relê `agent.env` com a mesma sessão (pega o item `oci-storage` recém-criado; não no `DRY_RUN=1`) e tranca no fim.
  - `oute-secrets`: não grava nem reaproveita sessão em disco; `export`/`get` trancam a sessão que abriram (sessão recebida do chamador, como no `oci-bootstrap`, fica com ele); não imprime mais `BW_SESSION`; novo `oute-secrets session`. `lock` = `bw lock` + apaga o `bw_session` legado. Sem tty (cron), recusa na hora em vez de falhar abrindo `/dev/tty`.
  - Migração: o primeiro `oute up` apaga o `~/.oute/bw_session` que tiver sobrado (e tranca o `bw`). `~/.oute/bwcli` continua (vault cifrado + login por API key; sem a master password não abre).
  - `comandos.md`, `README.md`, `secrets/README.md`: quando a senha é pedida. O `oute` do host já funciona com `git pull`; a imagem só leva o `comandos.md` e o `oute-secrets` novos na próxima release (o `oci-bootstrap` funciona com o `oute-secrets` da imagem atual).

### Fixed
- Sessão **restaurada pelo herdr** volta a rodar na **própria worktree**, não no checkout principal (#40). O restore relança o agente no cwd salvo do shell do pane, que nas abas do `oute-task`/`oute-swarm` é o checkout principal, e o agente retomava a sessão ali. Agora o shim, num resume com id (`claude --resume`/`-r <id>`, `claude --resume=<id>`, `codex resume <id>`, `pi --session <id>`), lê o cwd da sessão no transcript (`~/.claude/projects/*/<id>.jsonl`, `~/.codex/sessions/**/rollout-*<id>.jsonl`, `~/.pi/agent/sessions/*/*_<id>*.jsonl`) e faz `cd` para ele antes do `exec`, para todas as sessões, não só as do swarm. Só troca de diretório se o cwd está em `/workspace/.worktrees/` (`OUTE_WORKTREES`), ainda existe e é worktree do mesmo repo do diretório atual; senão retoma como antes e avisa em stderr (`oute: a sessão … era de … (motivo); retomando em …`). A marca do swarm (#39) passa a valer também quando a sessão é retomada de dentro da worktree.
- Shim: `pi --session <id>` passa direto, como os outros resumes (antes caía no prompt de worktree quando aberto do checkout principal).

## [0.7.20] - 2026-09-26

### Fixed
- `oute-swarm tell` no **Codex e no Pi**, validado ao vivo (codex-cli 0.157.0, pi 0.87.1, herdr 0.9.1) nos casos do #37 (#38):
  - Codex: o `tell` nunca conseguia limpar o campo sujo. O placeholder `Ask Codex to do anything` vem `ESC[2m ESC[48;2;…m texto` e o filtro só tirava o texto esmaecido até o próximo `ESC`, então o campo vazio parecia ter texto. Agora o esmaecido sai até o reset (`0`/`22`), sem confundir `38;2;r;g;b` com SGR 2. A animação braille do composer vazio (e o spinner do Pi) também sai.
  - Pi: com o agente trabalhando, a régua de cima vira `── ⠦ Working ──` e o campo não era achado. Régua com rótulo agora conta.
  - Diálogos: o herdr mostra o Codex como `idle` nos diálogos de confiar na pasta/hooks e no command center, e o `tell` digitava ali. No teste, o texto escolheu uma opção do diálogo de confiança; na tela de hooks, `t` = "trust all". O Pi mostra `done` com o seletor `/model` aberto. Agora `field_text` não vê campo nesses casos (opção numerada/dicas de seleção após o `›` no Codex; `Enter to select`/`to cancel` entre as réguas no Pi), e o `tell` confere o campo **antes** de digitar: sem campo, recusa com `campo de entrada … não encontrado na tela` e nada é digitado.
  - `ctrl+c` limpa o campo sem interromper nem sair no Codex e no Pi (sem troca de tecla por agente).
- Sessão do Claude do swarm **restaurada pelo herdr** continua sem sugestão de prompt (#39). O restore relança `claude --resume <id>` num shell novo, no cwd salvo do pane, sem a env que o `oute-task` tinha dado (`OUTE_SWARM_WORKER` → `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false`). Agora o `oute-task` grava a marca `oute-swarm-worker` no git-dir da worktree (some com a worktree), e o shim do `claude`, num `--resume`/`-r <id>`, acha o cwd da sessão no transcript (`~/.claude/projects/*/<id>.jsonl`) e, se a worktree tem a marca, exporta a env. Sessões sem a marca (fora do swarm) não mudam; um valor já definido no ambiente prevalece.
- Shim: `--resume=<id>` passa direto, como `--resume <id>` (antes caía no prompt de worktree).

## [0.7.19] - 2026-09-26

### Changed
- `swarm-worker.md`: antes do merge do PR, o canal de aprovação serve só para **diagnóstico e dry-run** (`--dry-run`, `--check`, leitura); aplicar mudança no host só **depois do merge**, quando a coordenadora ou o Bardi pedir. Se a issue exige aplicar, a sessão termina com `PRONTO #n: <url> — aplicar no host depois do merge` e espera. Antes uma sessão aplicou no oute-server a partir do branch, antes do merge (#23).
- `swarm.md` §3: a coordenadora só repassa "pode aplicar no host" (via `oute-swarm tell`) depois de confirmar o merge do PR; a aba dessa sessão só fecha depois de aplicado (#23).
- **`oute-swarm tell` só envia com segurança** (#28). Antes digitava e dava Enter às cegas: numa sessão ociosa do Claude Code, o campo mostra a sugestão do próximo prompt (ex.: `faz o merge do #238`), e um Enter na hora errada a submetia.
  - Recusa sessão ocupada: consulta `herdr agent list` e só segue com o agente do pane em `idle`/`done`/`blocked`; `working`/`unknown` → `sessão … ocupada (<estado>); tente depois`. `--force` (só a pedido do Bardi) pula essa checagem.
  - Confere o campo antes do Enter: depois do `send-text`, lê o pane (`herdr pane read --format ansi`, descartando o texto esmaecido de sugestão/placeholder) e só manda Enter se o campo de entrada contém exatamente a mensagem. Se não bater e a sessão estiver pronta, limpa com um `ctrl+c` e tenta uma vez; senão sai com erro mostrando o que leu, sem Enter. Com a sessão `blocked`/`working` não limpa (`ctrl+c` interromperia ou responderia o diálogo).
  - A mensagem vai numa linha só (quebras de linha e controles viram espaço: um `\n` no `send-text` seria um Enter sem conferência) e com no máximo 800 caracteres com o prefixo; acima disso o Claude Code mostra `[Pasted text #n]` e o campo não dá para conferir.
  - `~/.oute/swarm/<rodada>/log` registra o resultado: `ok` (com `--force, <estado>` quando forçado) ou `recusado: <motivo>`.
- Sessões do Claude abertas pelo `oute-swarm spawn` saem **sem sugestão de prompt**: o `spawn` passa `OUTE_SWARM_WORKER=1` ao `oute-task`, que exporta `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false` (só para o agente `claude`; um valor já definido no ambiente prevalece). Sessão restaurada pelo herdr (ex.: depois de `oute update`) pode voltar a ter a sugestão; a conferência do `tell` continua valendo (#28).
- `comandos.md` e `swarm.md` §3: `tell … [--force]`, sessão parada, mensagem de uma linha, o que fazer quando o `tell` recusa (#28).

### Fixed
- `oute-swarm tell` saía com código 2 e sem mensagem quando achava a aba pelo label (o caso normal), então nunca funcionou desde a 0.7.16: chamava `herdr pane list --tab`, que não existe no herdr 0.9.1. Agora lê `herdr pane list` e filtra por `tab_id` no jq, preferindo o pane com agente. O id de pane gravado no spawn só entra como fallback se ainda existir. Toda falha sai com mensagem em stderr: `herdr pane list falhou: …`, resposta que não é JSON, `pane da aba … não encontrado; nada enviado`. (#34)

## [0.7.18] - 2026-09-26

### Changed
- `swarm-worker.md`: o PR da sessão usa `Closes #n` só se cumpre todos os critérios de aceite da issue; senão `Refs #n` + seção `## Falta` com o que ficou de fora. Antes todo PR levava `Closes`, e o merge de uma entrega parcial fechava a issue.
- `swarm.md`: antes de pedir merge, a coordenadora confere `Closes`/`Refs` contra os critérios e pede ajuste via `oute-swarm tell`; no resumo da rodada, issue com PR `Refs` aparece como **parcial**, com o que falta. Sem flag `--partial` no `spawn`.

### Fixed
- `oute-task clean` passa a considerar worktrees em **detached HEAD** (sessões que voltaram a `origin/<base>` depois do merge, com o branch do PR já apagado). Limpa e contida em `origin/<base>` → `remover` (com `--yes`, só `git worktree remove`, sem `branch -D`); com mudanças locais ou commits fora de `origin/<base>` → `mantém` com o motivo. Worktrees com branch: sem mudança. Antes elas nem eram listadas e a coordenadora removia à mão (#26).
- `oute-swarm close` tentava fechar abas já fechadas pelo id gravado no spawn (stale) e respondia `falhou fechar … feche manualmente`; `close --all` listava de novo as abas já fechadas. Agora o id gravado só é usado se ainda existir em `herdr tab list`; senão `já fechada: #n slug`, exit 0. Fechamentos (e abas constatadas fechadas com `--yes`) ficam em `~/.oute/swarm/<rodada>/closed` (o `spawned` segue como histórico): `close` os ignora, `close --all` sem pendentes imprime `nada a fechar`, `tell` recusa com `aba … já fechada` e `list` marca `(fechada)`. `close <slug>` de fora da rodada agora dá erro. (#27)

## [0.7.17] - 2026-09-26

### Changed
- `oute-task clean --yes` também avança o checkout principal de cada repo até `origin/<branch padrão>`, só por fast-forward, só se ele estiver na branch padrão e sem mudança local rastreada. Sem `--yes` mostra `atualizar …`. Antes a `main` local ficava para trás depois de cada merge.
- Notas dos agentes (`agent-notes.md`): `git pull --ff-only` no checkout principal, na branch padrão e sem mudança local, é permitido sem perguntar.

## [0.7.16] - 2026-09-26

### Added
- **`oute-swarm tell <n>-<slug> "<mensagem>"`**: a coordenadora repassa à sessão uma decisão/instrução explícita do Bardi (`herdr pane send-text` + `send-keys enter`), com o prefixo `[coordenadora <rodada>, repassando o Bardi]`. Acha o pane pela aba (label `#n slug` → `herdr pane list --tab`, preferindo o pane com agente), com fallback no id gravado. Registro em `~/.oute/swarm/<rodada>/log`. Antes o Bardi tinha que ir até o pane e digitar.

### Changed
- `swarm.md`: a coordenadora só usa `tell` para repassar o Bardi — nunca decide pela sessão nem responde sozinha ao que ela perguntou; aprovações continuam só no `oute watch`. Opções de decisão sempre numeradas (1, 2…).

## [0.7.15] - 2026-09-26

### Added
- **`oute-swarm close <n>-<slug>|--all [--yes]`**: fecha a aba do herdr da sessão (encerra o agente). Sem `--yes` só mostra. Acha a aba pelo label `#n slug` via `herdr tab list` (os ids mudam quando o herdr restaura a sessão, ex.: depois de `oute update`), com fallback no id gravado no spawn. Fora da coordenadora usa a rodada mais recente.

### Fixed
- A rodada terminava sem fechar as abas das sessões concluídas (o fechamento só fazia `oute-task clean` + handoffs). Agora a coordenadora fecha a aba de cada sessão quando o PR dela é mergeado e, no fim, `close --all` antes do `clean`.

## [0.7.14] - 2026-09-26

### Added
- **`oute help`**: guia completo em `docker/comandos.md` (receitas rápidas, comandos do host, do container, `oute-swarm`, canal de aprovação, memória, herdr básico). Mesmo arquivo nos dois lugares: no host lê do repo; no container vai na imagem, e `oute help` ali também funciona (os outros `oute …` avisam que rodam no host). `oute -h` continua com o resumo curto.

### Changed
- `oute-swarm`: a coordenadora **reinicia sozinha** o monitor quando ele encerra por timeout e a rodada ainda está aberta; só avisa se o reinício falhar.

### Fixed
- `oute -h` imprimia "up: command not found": o heredoc do uso tinha crases sem escape (virava substituição de comando). Heredoc agora é literal.

## [0.7.13] - 2026-09-26

### Added
- **`oute-swarm <repo> [--max N] [--label L]`**: rodada de sessões paralelas, uma por issue, padronizando o fluxo validado na rodada 1 do lab. Abre uma coordenadora do Claude numa worktree própria (`swarm-MMDD-HHMM`) com o prompt `/usr/local/lib/oute/swarm.md`: triagem (descarta `needs-info`/`ready-for-human`/`later`/`blocked`/`spike`, issues com PR e as que se sobrepõem), **espera o ok do Bardi**, abre as sessões, acompanha agentes e PRs, e fecha com `oute-task clean` + cancelamento dos handoffs órfãos. Merge só quando pedido; host só pelo canal de aprovação. Default `--max 3`, teto 5.
- **`oute-swarm spawn <n>-<slug> "<instrução>"`** (usado pela coordenadora): abre uma aba do herdr (`herdr tab create` + `herdr pane run`) com `oute-task` na worktree da issue e acrescenta as regras padrão da sessão (`swarm-worker.md`: branch `<tipo>/<n>-<slug>`, PR com `Closes #n`, sem merge, fim com `PRONTO`/`BLOQUEADO`). Recusa passar do `--max` da rodada e repetir issue. `oute-swarm list` mostra as abas abertas por rodada. Estado em `~/.oute/swarm/<id>/`.

## [0.7.12] - 2026-09-26

### Changed
- **Auto memory do Claude Code desligada**: `autoMemoryEnabled: false` no `~/.claude/settings.json` (entrypoint, via jq) e `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` no compose. A memória dos agentes é uma só, o ai-memory, compartilhado por Claude, Codex e Pi. Notas já gravadas em `~/.claude/projects/*/memory/` não são apagadas; só deixam de ser carregadas e escritas.

## [0.7.11] - 2026-09-26

## [0.7.10] - 2026-09-26

### Fixed
- `oute-task` pedia usuário/senha do GitHub no `git fetch`, porque o git do shell não tinha o helper de credenciais. Agora o fetch roda sem prompt (`GIT_TERMINAL_PROMPT=0`) e com o helper do `gh`, e o entrypoint grava `credential.https://github.com.helper = !gh auth git-credential` no git global, de forma explícita (`gh auth setup-git` com `GH_TOKEN` no ambiente não garantia isso).
- **Worktree por sessão também para agentes abertos pelo herdr.** Na 0.7.9 a regra era uma função do bash, e o herdr cria e restaura agentes chamando o executável direto, sem passar pelo shell. Agora são **shims** (`claude`, `codex`, `pi`) em `/usr/local/lib/oute/shims`, na frente do PATH (Dockerfile e `.bashrc`, que garante a ordem mesmo com `~/.local/bin`). Passam direto: worktree, fora de repo, headless (`-p`, `exec`), `--resume`/`--continue`, subcomandos, sem terminal, `OUTE_NO_WORKTREE=1`.

### Added
- **`oute update`**: de qualquer diretório, faz `git pull --tags --ff-only` no repo, depois `oute pull`, `down`, `up` e `version`. A segunda etapa roda já com o script atualizado (`exec` depois do pull).

## [0.7.9] - 2026-09-26

### Added
- **Uma sessão de agente = uma worktree + um branch.** `oute-task <slug> [claude|codex|pi|shell]` cria (ou reabre) `/workspace/.worktrees/<repo>-<slug>` com o branch `sessao/<slug>` a partir de `origin/<branch padrão>` e abre o agente dentro. `oute-task list` lista; `oute-task clean [--yes]` remove as já mergeadas (squash detectado via `gh`) ou vazias, preservando mudança local e commit sem PR. No shell interativo do container, digitar `claude`/`codex`/`pi` no **checkout principal** de um repo pergunta o nome da tarefa e abre a sessão numa worktree própria (headless `-p`/`exec` e worktrees passam direto; `OUTE_NO_WORKTREE=1` desliga). A sessão precisa *nascer* na worktree: o Claude devolve o shell ao diretório inicial a cada comando, e o ai-memory registra o diretório de início.
- Notas globais dos agentes: regras de git (nunca editar o checkout principal, renomear o branch para `<tipo>/<issue>-<slug>` antes do push, entrega por PR, merge só quando pedido), issues via `gh`, leitura de `AGENTS.md`/`CONTEXT.md` do repo, nada de segredo em arquivo/issue/saída.
- Repo: `AGENTS.md` (regras específicas do oute-agent), `CLAUDE.md` (`@AGENTS.md`, uma fonte só para os três agentes) e `CONTEXT.md` (resumo dos ADRs; o canônico continua no Project do claude.ai).

## [0.7.8] - 2026-09-26

### Changed
- **Escopo da memória por sessão:** o Claude passa a usar o bridge MCP **session-aware** do ai-memory (`install-mcp --session-aware`), que manda o id da sessão em cada chamada, e o servidor roda com `AI_MEMORY_AUTO_SCOPE__MODE=per_session`. Consultas e gravações sem `workspace`/`project` resolvem para o projeto da **própria sessão**, não para o "ativo" compartilhado (`shared_slot`), que podia ser o de outra sessão em outro repo. Codex e Pi não têm bridge: as notas gerenciadas dos agentes agora pedem `workspace`/`project` explícitos (do `.ai-memory.toml` ou do repo principal) em toda chamada de memória. Depois de um `/clear` no Claude, reabrir a sessão mantém o id exato (limite do Claude Code).

## [0.7.7] - 2026-09-25

### Changed
- **ai-memory 2.4.1** (servidor e cliente juntos; era 2.4.0): log do servidor sem o `reconciliation pass` a cada 30 s, slugs de regra com acentos dobrados (`retenção` → `retencao`), handoff sem rótulos `tool file`, `memory_consolidate` manual corrige job `failed`. **Migração de schema V67, só para frente**: backup do volume `oute-memory` antes de subir.
- Hooks do ai-memory instalados com **`--project-strategy repo-root`**: o projeto da memória passa a ser o repo principal, então subdiretórios e git worktrees caem no mesmo projeto (antes, `basename(cwd)` criava um projeto por worktree ou por `cd subdir`). Para repos em `/workspace/<repo>` o nome não muda; nada existente é movido.

### Added
- **`oute watch [host]`**: atalho de `oute approve --watch`. Com host (ex.: `oute watch oute-server`), abre a espera de aprovação naquele host via `ssh -t` (roda como o usuário do ssh, fora do container).

## [0.7.6] - 2026-09-25

### Added
- **Canal de aprovação** para ações no host: o agente propõe com **`oute-propose "título" [--root]`** (script pela entrada padrão → `~/outbox/`) e lê o resultado com **`oute-inbox [--wait] <id>`**; o humano revisa e executa (ou recusa) no host com **`oute approve [--watch]`** — fora do container, então o agente não aprova a si mesmo. O script é copiado para o host antes de exibido (o que roda = o que foi visto), caracteres de controle neutralizados na tela, `--root` destacado em vermelho, registro em `~/.oute/approve/approve.log`, saída devolvida em `~/inbox/<id>.out` (`# rc:`; recusa = 126). Os agentes aprendem o canal por um bloco gerenciado em `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md` e `~/.pi/agent/AGENTS.md`.

## [0.7.5] - 2026-09-25

### Added
- **Origem da telemetria = máquina + instância.** Todo registro (bucket e Langfuse) leva `host.name` = máquina e `oute.instance` = instância, além de `oute.agent`. A instância só precisa ser única dentro da máquina (#22).
  - `OUTE_HOST` é opcional: sem ele vale o antigo `OUTE_HOSTNAME` e, se nenhum estiver definido, o hostname da máquina.
  - `OUTE_INSTANCE` tem default `oute-agent`.
  - Os dois são normalizados para `[a-z0-9_-]`, até 40 caracteres.
  - Bucket particionado: `otel/<sinal>/host=<máquina>/instance=<instância>/year=…`. Os objetos antigos, sem `host=/instance=`, ficam onde estão; nada é movido nem apagado.
  - No Langfuse, a máquina vira o **Environment** nativo e máquina/instância vão para a metadata do trace.
  - `oute version` mostra a origem.
- **`oute` sem argumento** abre o herdr (sobe a stack antes, se o agent não estiver rodando). **`oute install`** cria o link no PATH (`~/.local/bin`, `/opt/homebrew/bin` ou `/usr/local/bin`, o primeiro que estiver no PATH e for gravável) — no Mac e no oute-server basta digitar `oute`. O script resolve symlinks para achar a raiz do repo. `oute help` mostra o uso; comando desconhecido avisa.

## [0.7.4] - 2026-09-25

### Fixed
- **Entrypoint em loop de restart num home novo** (1ª subida em host novo, visto no Mac, #3): a retenção dos `.bak` do ai-memory fazia `ls` de glob sem match, que sai 2; com `pipefail` + `set -e` o entrypoint morria antes do sshd. No oute-server não aparecia porque os `.bak` já existiam.
- `oute up` para com mensagem clara se a chave pública de `OUTE_SSH_AUTHORIZED_KEYS` (default `~/.ssh/id_ed25519.pub`) não existir — antes o Docker criava um diretório vazio no lugar.
- `oute pull` mostra o erro real do vault (antes dizia só "GHCR_TOKEN ausente", mesmo quando faltava o `bw_client.env`).
- Mac: README com rede alternativa (`OUTE_NET_SUBNET`/`OUTE_NET_GATEWAY`/`OUTE_AGENT_IP`) quando `172.19.0.0/16` já está em uso, e rclone do rclone.org (o do Homebrew não faz `mount` no macOS).
- `oute up`/`pull` falhavam na 0.7.3 com `EACCES ... Bitwarden CLI/data.json.lock`: o `bw` do host roda via `docker run` da imagem, agora com uid 10001, mas o estado em `~/.oute/bwcli` é do usuário do host. O `bw` (e o `oci-bootstrap`) passam a rodar com `--user` do host, `HOME=/tmp` e `BITWARDENCLI_APPDATA_DIR=/bwcli`. Só script do host — a imagem 0.7.3 não muda.

## [0.7.3] - 2026-09-25

### Security
- **Container com uid/gid próprios (10001)** (lab#181). Antes o usuário do container tinha o uid do host (1001 = `ubuntu` no oute-server): tudo que um agente gravava em bind mount virava arquivo do `ubuntu`. Agora o uid é fixo na imagem e não existe no host; `OUTE_UID` sai do `.env`, do compose e do CI (`oute up` avisa se a linha ainda existir). Serviço one-shot **`volume-init`** migra os volumes `oute-home`, `oute-workspace` e `oute-memory` (chown só quando a raiz ainda não é 10001). O entrypoint lê `/run/secrets/agent_env` (0600 do host) via `sudo`.
- **`/data/shared` sem diretório do host gravável** (lab#181): só o mount rclone do bucket vem do host (dono 10001, grupo do usuário do host, umask 002; FUSE de usuário é nosuid/nodev). Sem mount, vira o volume docker `oute-shared` em vez de `~/.oute/shared`.

### Fixed
- **Mac** (#3): `oute` quebrava no bash 3.2 do macOS com array vazio + `set -u` (`rclone mount` sem `--allow-other`, `oute ssh` sem tty) e o `wait_sshd` dependia de `timeout(1)`, que o macOS não tem. A mesma imagem do ghcr serve no Mac, sem rebuild por uid.

## [0.7.2] - 2026-09-25

### Added
- **Identificador do agente na telemetria** (`oute.agent`): o collector marca `claude` (service `claude-code`), `codex` (`codex_*`) e `router` (`jev-router`) no resource de traces, logs e métricas (bucket e Langfuse). No jev-router o hook grava o **cliente real** no span `jev.decision` a partir do header `X-Oute-Agent` — o Pi manda `pi` (header no `models.json`); sem header = `unknown`. No Langfuse vira `metadata.agent` do trace. Log do router: `served agent=… profile=…`.

### Fixed
- `oute pull` travava: sem `bw` nativo no host, o `bw` roda via `docker run` da imagem da versão ATUAL — que ainda não foi baixada (o pull precisa do bw para ler o token do ghcr). Agora usa a imagem local da versão atual ou a mais nova disponível, com `--pull never`.

## [0.7.1] - 2026-09-25

### Security
- Acesso do container ao host como **`oute-ops`** (lab#178): rede `oute` com subnet fixa `172.19.0.0/16` e agent em `172.19.0.5` (o sshd do host só aceita o oute-ops desse IP); chave própria `~/.ssh/oute-ops_ed25519` gerada no boot; `~/.ssh/config.d/oute-host.conf` (incluído no topo do `~/.ssh/config`) faz `ssh oute-server` entrar como oute-ops via gateway `172.19.0.1`. A pública sai no log do boot.

## [0.7.0] - 2026-09-25

### Security
- **Container dos agentes sem acesso ao Vaultwarden** (#6, passo 1). Antes recebia `BW_SESSION` (+ `BW_PASSWORD` se definida), o estado do `bw` (`~/.oute/bwcli`) e a API key (`bw_client`) — com agentes em yolo, qualquer um podia ler o cofre inteiro (segredos de todos os projetos e a pasta `oute-admin`). Agora o `oute up` resolve só a pasta `oute-agent` no host e monta os valores como docker secret (`~/.oute/agent.env`, 0600, read-only em `/run/secrets/agent_env`). Saem do agent: `BW_*`, volume `bwcli`, secret `bw_client`, `extra_hosts` do vault; `BW_SESSION` sai do `.oute_env`; resíduos do bw no volume home são apagados no boot. O `bw` continua na imagem só para o host usar via `docker run`.

### Added
- **A/B Jev × `openrouter/auto`** (#15): `OUTE_AB_MODE=off|split|auto` no jev-router. No `split`, cada conversa (hash da 1ª mensagem) cai num braço de forma estável; o braço `auto` usa `openrouter/auto` com `allowed_models` = mesmo pool de modelos dos perfis elegíveis (tools/vision/max_tokens), ZDR e `data_collection: deny`, `session_id` por conversa. Span `jev.decision` ganha `oute.ab_arm`/`oute.ab_mode`; trace `ab-auto` no Langfuse. `router-sync` gera o modelo `or-auto`.

### Fixed
- `oute router-sync --check-guardrail` reiniciava jev-router e agent; agora só checa e devolve o código (0 alinhado, 2 divergente, 1 não verificado).
- `.gitignore`: `__pycache__/` e `*.pyc` (um `.pyc` entrou por engano na 0.6.1).

## [0.6.1] - 2026-09-25

### Added
- `router-sync` detecta divergência `policy.yaml` × guardrail do OpenRouter (#16): com a Management API key (`OPENROUTER_MGMT_KEY`, pasta `oute-admin` do vault — nunca vai ao container dos agentes) compara `providers_allow` com `allowed_providers`/`ignored_providers` e ZDR do guardrail nomeado em `policy.yaml: guardrail`. Sync normal só avisa; `oute router-sync --check-guardrail` sai 2 se divergir. Sem a key, avisa que não verificou.
- Ponte do Mac (#9): `.githooks/pre-commit` reaplica +x no índice e no disco; `scripts/fix-bridge` (+x, remove `.git/*.lock` órfão se não houver git rodando, ativa `core.hooksPath`); `scripts/exec-files` = lista única dos executáveis; `scripts/release` e o CI recusam script sem modo 100755.

## [0.6.0] - 2026-09-25

### Added
- **Agentes em modo yolo dentro do container por padrão** (`OUTE_AGENT_YOLO=1`): Claude Code com `permissions.defaultMode=bypassPermissions` (+ `skipDangerousModePermissionPrompt`), Codex com `approval_policy="never"` (já tinha `sandbox_mode=danger-full-access`). Merge estrutural, preserva hooks do ai-memory. A fronteira é o container; acesso ao host segue restrito (ver ADR-01).

## [0.5.9] - 2026-09-24

## [0.5.8] - 2026-09-24

### Fixed
- **Codex sem ai-memory desde a 0.5.3/0.5.4** (sem MCP e sem captura de sessões): o entrypoint editava `~/.codex/config.toml` com `sed` apagando intervalos entre marcadores, e a seção `[mcp_servers.ai-memory]` gravada pelo ai-memory caía dentro do intervalo. Agora `docker/codex_config.py` mescla só `sandbox_mode` e `[otel]` via `tomlkit` (pacote `python3-tomlkit`) e preserva o resto; migra os blocos antigos no primeiro boot.
- Backups `.bak-*` que o ai-memory cria a cada boot no `~/.codex`: mantém o mais antigo (original) + os 2 mais recentes.
- Codex só roda hooks com aprovação persistida (`[hooks.state]…trusted_hash` no `config.toml`); o `sed` antigo apagou a aprovação e os hooks pararam em silêncio desde a 0.5.4. Reaprovado via TUI; agora preservado pelo merge estrutural.

## [0.5.7] - 2026-09-24

### Removed
- **Goose** fora do stack (#4): não funciona com o ai-memory (sem hooks, não está nos harnesses suportados). Regra do projeto: agente só entra se atender memória (ai-memory hooks + MCP) e telemetria (bucket + Langfuse). Removidos binário, config do entrypoint e `goose` de `OUTE_AGENTS`.

## [0.5.6] - 2026-09-24

### Changed
- Imagens de terceiros com versão fixa (antes `:latest`/`:main-latest`): LiteLLM por digest (`1.103.0`, o que já rodava — `OUTE_LITELLM_IMAGE`), servidor ai-memory `2.4.0` (`OUTE_AI_MEMORY_VERSION`) e cliente ai-memory no Dockerfile `ARG AI_MEMORY_VERSION=2.4.0` (baixava `releases/latest`). Upgrade passa a ser deliberado.

## [0.5.5] - 2026-09-24

### Changed
- Compose: rotação do stdout dos containers (`json-file`, 10 MB × 3). Telemetria não muda — vai inteira ao bucket, sem expiração.
- CI (#20): actions nas majors Node 24 — `checkout@v7`, `setup-buildx-action@v4`, `login-action@v4`, `build-push-action@v7`. Retenção do ghcr reescrita com `gh api` (o `delete-package-versions@v5`, última versão, ainda é Node 20) e runner fixo em `ubuntu-24.04` (o `ubuntu-latest` migra para 26 em 19/10).

### Fixed
- Langfuse: tokens de Claude Code e Codex apareciam zerados. Atributos crus (`input_tokens`, `cache_read_tokens`, `codex.turn.token_usage.*`) mapeados para `gen_ai.usage.*`; `session_task.turn` do Codex vira generation com modelo; `session.id` → `langfuse.session.id` (aba Sessions) (#19).
- Langfuse: ruído do Codex — allowlist de spans (`codex.exec`, `session_*`, `run_sampling_request`, tools, hooks, `thread/start`, `turn/start`). Antes 1 exec gerava ~7 traces e milhares de spans `fs.*`/`append_items`. Tudo continua no bucket.

### Changed
- `oute pull` aplica retenção local: mantém só a versão atual e a anterior do agent (mesma regra do ghcr) e, sem `OUTE_BUILD_LOCAL=1`, limpa todo o build cache (sobrava 5,5 GB de builds antigos sem uso).

## [0.5.4] - 2026-09-24

### Fixed
- Codex não executava nada no container (`bwrap: No permissions to create a new namespace`): entrypoint grava `sandbox_mode = "danger-full-access"` no topo do `~/.codex/config.toml`. O container já é a fronteira de isolamento; liberar user namespaces enfraqueceria o container inteiro (#5).
- CI: cache de camadas trocado de `type=gha` para registry (`ghcr.io/renatobardi/oute-agent-cache:buildcache`). O cache do Actions é isolado por ref e cada tag é um ref novo — nunca havia hit (build sempre ~5 min).

## [0.5.3] - 2026-09-24

### Added
- Codex exporta **traces** (`[otel.trace_exporter.otlp-http]` → collector) além dos logs (#19). No Langfuse: span events mantidos **só para o Codex** (é onde ele põe modelo/tools), com allowlist de atributos (prompt/saída nunca saem); tokens e conteúdo completos seguem no bucket (logs). Custo do Codex não existe por request (assinatura).

### Security
- `oute pull` faz `docker logout ghcr.io` logo após o pull: o token de leitura não fica em texto puro no `~/.docker/config.json` (só no vault).

## [0.5.2] - 2026-09-24

### Added
- **CI da imagem** (#2): `.github/workflows/image.yml` — na tag `v*` (ou manual) builda arm64 nativo em `ubuntu-24.04-arm`, cache de camadas `type=gha`, push em `ghcr.io/renatobardi/oute-agent:x.y.z`; job de retenção mantém 2 versões no ghcr (#12). Tag precisa bater com `VERSION`.
- `oute pull`: login no ghcr com `GHCR_TOKEN` (vault, item `github`, só `read:packages`) e pull da imagem da versão atual. `oute up` usa a imagem local ou puxa do ghcr (`--no-build`; build local só com `OUTE_BUILD_LOCAL=1`).

### Changed
- Cache do build local: retenção padrão 24h (era 72h — duas gerações completas levaram o disco a 85%).

### Fixed
- Dockerfile: `ARG OUTE_VERSION` movido para o fim (antes do `LABEL`). Declarado no topo, virava env de todos os `RUN` e cada bump de versão refazia a imagem inteira (~7 min).

## [0.5.1] - 2026-09-24

### Fixed
- `oute build`: retenção do cache por idade (`prune -a --filter until=72h`, `OUTE_BUILD_CACHE_TTL`) — teto por tamanho (`--max-used-space`) apagava também o cache recente e o rebuild voltava a 7 min. `oute up` apaga a imagem antiga que ficou solta após recriar o container.

### Changed
- Dieta da imagem, só cortes seguros (#11): dpkg sem man/doc/info e sem traduções além de en/pt; sem cache de pip/npm na imagem (`PIP_NO_CACHE_DIR`, cache mounts do BuildKit pra npm e pipx — rebuild baixa rápido, nada entra na camada); aws-cli sem `examples/`; gcloud sem `.install/.backup`. Nenhuma ferramenta removida.
- `oute build` mantém o cache de build em vez de apagar tudo: rebuild que só muda entrypoint/scripts reaproveita apt/npm/oci-cli (#8). Sem attestation de proveniência (`BUILDX_NO_DEFAULT_ATTESTATIONS=1`). Avisa se faltar `docker-buildx`.

## [0.5.0] - 2026-09-24

### Added
- **Observabilidade, fase 1** (#13, ADR-04): serviço `otel-collector` (OTel Collector contrib, só rede interna). Claude Code (métricas/eventos/traces com conteúdo), Codex (`[otel]` gerenciado no `config.toml`) e jev-router (callback `otel` do LiteLLM) exportam OTLP. Tudo vai pro bucket OCI `oute-observability` (gzip, lotes de 5 min, partição por hora UTC); traces com **só metadados** (allowlist de atributos, sem span events) vão pro Langfuse Cloud quando o vault tem o item `langfuse`.

### Fixed
- `oute-secrets export` sempre faz `bw sync`: item criado no vault depois da sessão em cache (ex.: `langfuse`) passa a ser visto no próximo `up`.
- otel-collector → OCI: `AWS_REQUEST_CHECKSUM_CALCULATION`/`AWS_RESPONSE_CHECKSUM_VALIDATION=when_required` (OCI rejeita `aws-chunked` do SDK AWS v2 com 501).

### Added
- Observabilidade fase 2 (#13): `jev.decision` enriquecido com o que o OpenRouter realmente fez — consulta `GET /api/v1/generation?id=gen-…` em background (retries 2/4/8/16 s) e grava modelo servido, provedor, custo (US$), latência e tokens nativos. Custo aparece no Langfuse (span tipo generation). Sem porta pública (decisão: pull via API em vez de Broadcast).

### Changed
- jev-router emite span próprio `jev.decision` (perfil, via, preset, modelos, sinais, tokens, `gen_ai.response.id` = id da geração no OpenRouter) — o LiteLLM não repassa metadata customizada pros spans dele. Trace nomeado `jev:<perfil>` no Langfuse.
- Langfuse: spans internos do LiteLLM (`auth`, `router`, `self`, `proxy_pre_call`, `raw_gen_ai_request`…) filtrados do painel; continuam no bucket.
- `oute ssh <cmd>` aloca TTY quando há terminal: `pi -p` via ssh não fica mais esperando stdin.
- `oute up` lê o vault uma vez só (`oute-secrets export`) em vez de uma chamada por variável.
- `.oute_env` gerado com `declare -px` (valores citados).
- rclone no host sem `NOTICE: Config file … not found` (`RCLONE_CONFIG=/dev/null`; remote só por env).

## [0.4.0] - 2026-09-23

### Added
- Storage comum no **OCI Object Storage** (#1, ADR-03): `oute oci-bootstrap` provisiona compartment `oute-agent`, buckets `oute-shared` (versionado, versões antigas > 30d apagadas) e `oute-observability` (Infrequent 30d → Archive 90d), usuário de serviço só-S3 com policy de menor privilégio, Customer Secret Key gravada direto no Vaultwarden (`oci-storage`) e budget US$1/mês. Credencial admin fica na pasta `oute-admin` do vault, nunca exportada pro container. `DRY_RUN=1` mostra sem executar.
- `oute up` monta `oci:oute-shared` em `~/.oute/shared` (remote `oci` só por env, sem `rclone.conf`); `oute down` desmonta. Dentro do container, `rclone` já enxerga o remote `oci`.
- `oute storage [ls|lsl|about] [path]`: lista o bucket direto no OCI, sem o mount.

### Changed
- `OCI_KEY_PEM` aceita PEM colado numa linha só (custom field do Vaultwarden perde quebras de linha); é reconstruído.

### Fixed
- `oute up` espera o sshd do container responder (banner SSH, até 60s) antes de retornar; `attach` logo após o `up` não dá mais `Connection reset`.

### Security
- sshd do container publicado só em `127.0.0.1` por padrão (`OUTE_SSH_BIND`); antes ficava em `0.0.0.0:2222`, exposto no IP público do oute-server porque o Docker publica portas por fora do ufw (#17).

## [0.3.0] - 2026-09-23

### Added
- Perfis publicados como **presets do OpenRouter** (`@preset/oute-reasoning`, `@preset/oute-coder`, ...) pelo `router-sync` — só quando mudam (cada publicação é uma versão). Utilizáveis fora do container com a key do OpenRouter. Preset reforça `zdr` + `data_collection: deny`. O LiteLLM passa a mandar o `@preset/...`; se a publicação falhar, volta ao `models`+`provider.sort` injetado pelo hook. `--no-presets` desliga.

## [0.2.0] - 2026-09-23

### Added
- `oute router-sync`: consulta o OpenRouter (`/providers`, `/models`, `/models/user`, `/models/{id}/endpoints`) e gera `router.yaml`, `config.yaml`, `candidates.json` e `catalog.json` a partir de `config/litellm/policy.yaml` (espelho do guardrail: allowlist de provedores, perfis com padrões de modelo). Pi lista os perfis gerados.

- Roteamento em 2 etapas: Jev escolhe o **perfil**; o OpenRouter escolhe o **modelo** dentro dele (`models` = até 3 modelos elegíveis do perfil — limite do OpenRouter, `provider.sort` por perfil, `partition: none`, fallback automático). Perfis também podem ser pedidos direto (`/model coder` no Pi).
- `router-sync` roda em todo `oute up` (se falhar, mantém o último catálogo) e diariamente às 04:00 (crontab do host, instalado pelo próprio `up`).

### Changed
- `oute build` limpa build cache e imagens órfãs ao terminar (pico de disco no oute-server; parte da issue #12).
- Allowlist do guardrail revista: modelos abertos (Kimi, DeepSeek, GLM, Qwen, gpt-oss, Llama) via hosts neutros (Fireworks, Together, DeepInfra, Baseten, Groq, Cerebras); saem Tencent, Sakana, NVIDIA, Meta. Perfis priorizam GLM, Kimi, DeepSeek e Grok; cada padrão contribui com 1 modelo (perfil mistura famílias).
- Arquivos gerados do router (`router.yaml`, `config.yaml`, `candidates.json`, `catalog.json`) saem do git; fonte única é `policy.yaml`.
- Candidatos do router viram **perfis** (`reasoning`, `coder`, `coder-fast`, `long-context`, `cheap`, `vision`) resolvidos pra modelos elegíveis no guardrail; Anthropic/OpenAI/Google/DeepSeek saem (fora da allowlist).

### Added
- Runtime container (Ubuntu 24.04 arm64): herdr, Pi, Claude Code, Codex, Goose, ai-memory, gh, oci, gcloud, aws, firebase-tools, rclone, bw, sshd.
- Compose com 3 serviços: `agent`, `jev-router` (LiteLLM + hook Jev via OpenRouter), `ai-memory`.
- Segredos exclusivamente via Vaultwarden (`oute-secrets`).
- CLI de host `scripts/oute` (build/up/attach/ssh/shell/logs/status/sync-shared/version).
- Versionamento: `VERSION`, `CHANGELOG.md`, `scripts/release`, label OCI na imagem.

- Sessão do Vaultwarden em cache (`~/.oute/bw_session`, 0600) compartilhada host↔container via volume `bwcli`; master password só quando a sessão expira. `oute lock` apaga.

### Fixed
- `oute build` não exige mais `BW_PASSWORD` (só `up`).
- `bw` fixado em 2026.8.0 (2026.9.0 quebra com Vaultwarden 1.37.x, vaultwarden#7750).
- `extra_hosts` para `vault.oute.pro` (vhost só no listener Tailscale; Docker não herda /etc/hosts).
- `OUTE_UID` como build arg (bind mounts em hosts com uid ≠ 1000).
- `useradd -p '*'`: conta sem senha mas não bloqueada (sshd com `UsePAM no` recusava a chave como "invalid user").
- ai-memory roda com `OUTE_UID` (volume compartilhado) e aceita `Host: ai-memory` (`AI_MEMORY_ALLOWED_HOSTS`).
- `oute ssh cmd` roda em login shell (carrega `~/.oute_env`); `oute logs` sem follow, `oute follow` com.
- Jev chamado pela Decisions API do OpenRouter (`/api/alpha/decisions`, `typesafe/jev-1.13`) — chat completions dava 400.
- `~/.oute_env` carregado via `.profile` (o `.bashrc` retorna cedo em shell não-interativo).
- Hook loga `chosen=… via=jev|cheapest` e o motivo quando o Jev falha.
- Locales en_US/pt_BR gerados na imagem.
- Pi: pacote `@earendil-works/pi-coding-agent` (o `@mariozechner/*` está deprecated, parado em 0.73); provider `oute` em `~/.pi/agent/models.json` apontando pro jev-router, default `jev-router` forçado no `settings.json` (merge). `OPENAI_API_KEY` não é mais exportada globalmente (fazia o Pi cair no provider openai).
- Host key do sshd persistida em `~/.oute/ssh` (volume `oute-home`); `oute down` não invalida mais o `known_hosts`.
- `oute` usa o `bw` da imagem quando o host não tem node; `oute-secrets` não refaz `config server` logado e erra claro em `get`.
