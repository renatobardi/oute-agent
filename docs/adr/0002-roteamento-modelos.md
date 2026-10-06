# ADR-02 — Seleção de agente e modelo por sessão

Status: aceito · 2026-09-30 (#215, gate de `arch` do Bardi, PR #221) · substitui o roteamento anterior, de 2026-09-23 a 2026-09-30 (ver **Histórico**) · adendo 2026-10-02: precedência da rodada, reserva do Sonnet em `gpt-6.1-sol` e seletor em fatias (gate de `spec` do Bardi, ciclo #233) · adendo 2026-10-03: como o Jev é chamado (fatia 2, #257) · adendo 2026-10-03: a reserva `indisponivel` (fatia 3a, #258) · adendo 2026-10-03: a reserva `cota` (fatia 3b, #355) · adendo 2026-10-03: exceção por label `spike` → Sonnet (gate de `spec` do Bardi, #379) · adendo 2026-10-03: `kaizen` não vence fase de código (gate de `spec` do Bardi, #409) · adendo 2026-10-05: Sonnet nas fases `ops`, `ctx`, `learn` e nas exceções `kaizen`, `docs` (decisão do Bardi, #615) · adendo 2026-10-05: assinatura padrão e reservas, dois modos de escolher a reserva (#598, gate de `spec` do Bardi)

## Decisão
O **Claude Code é o agente principal** e o **Codex é a reserva**, os dois por assinatura. Cada sessão (`oute-task`, `oute-swarm spawn`) abre com o modelo Claude da **fase** da tarefa, escolhido por uma tabela fixa em `config/`, sem o Bardi escolher na mão. **O Pi e o roteador de modelos (ver Histórico) saem do stack** (#217, #218): sem o Pi, o router não tem cliente, e as quedas da rodada `swarm-0929-2356` (modelo servido chamando ferramenta inexistente ou recusando o schema, sem fallback) mostraram que o custo de manter o roteamento não compensa.

### Ordem de precedência
1. **`--model` / `--agent` explícitos** vencem tudo, dados na sessão ou na abertura da rodada (`oute-swarm <repo> --agent`, #212). `--agent codex` força o Codex. Escolha explícita não cai na reserva: só avisa. O `claude` posicional que o shim passa ao `oute-task` não conta como explícito.
2. **Exceção por label de tipo** na issue, antes da fase, em ordem de precedência:
   - `spike` → Sonnet (investigação com relatório e análise; amostra pequena #379: três spikes em Sonnet fecharam na primeira, Haiku precisou de três correções de contagem);
   - `kaizen` → Sonnet (issue de lição, de qualquer origem; hoje elas carregam `aidlc:spec` e cairiam no Opus), **salvo** com label de fase que mexe em código (`build`, `qa`, `design`, `plan`, `ship`, `iter`): aí vale a fase (adendo #409, abaixo). Sem label de fase, ou com `strat`, `intent`, `arch`, `spec`, `ops`, `ctx` ou `learn`, segue Sonnet;
   - `docs` → Sonnet (doc que não é ADR: README, `AGENTS.md`, `CONTEXT.md`, guias). ADR segue a fase dele (`arch`).
3. **Fase**, pelo label `aidlc:<fase>` da issue (tabela abaixo).
4. **Jev**, só quando não há label de fase e há texto da tarefa: sessão avulsa sem issue, ou issue sem `aidlc:<fase>`. O Jev classifica a fase pelo texto da tarefa e a tabela dá o modelo. Confiança < 0,6 ou falha do Jev (erro, tempo esgotado) → Sonnet.
5. **Padrão Sonnet** quando nada acima decide: sem label e sem texto da tarefa (sessão aberta na mão), sem a chave da TypeSafe, ou `gh` fora do ar. O seletor avisa e nunca bloqueia a abertura.

### Tabela fase → modelo
| fase | Claude | reserva (Codex) |
|---|---|---|
| `strat` `intent` `arch` `spec` | `claude-opus-5-5` | `gpt-6-astra`, esforço `high` |
| `build` `qa` `design` `plan` `ship` `iter` | `claude-sonnet-5-5` | `gpt-6.1-sol`, esforço `high` |
| `ops` `ctx` `learn` | `claude-sonnet-5-5` | `gpt-6-luna`, esforço `medium` |

- A tabela é indexada só por fase do ADR-07. `kaizen` e `docs` não são fases: entram como exceção (acima), com a reserva `gpt-6-luna`, esforço `medium`.
- `ship` e `iter` ficam no Sonnet: release/deploy e reescrita do que já existe não descem para o Haiku.
- **Ids exatos, sem alias** (`opus`, `sonnet`): a troca de versão é uma mudança visível na tabela, não um efeito colateral de upgrade do CLI. Todo id da tabela precisa existir no CLI instalado; o check é a #220 (checklist da `oute-aidlc-ship-release` ou nível 0 da #52).
- A série `gpt-5.x` do Codex fica fora (marcada como antiga pelo próprio CLI).
- **Reserva do Sonnet em `gpt-6.1-sol`** (adendo 2026-10-02): o Codex 0.159 marca `gpt-6-sol`, o id original desta linha, como geração anterior.
- **`claude-sonnet-5-5`** existe no Claude Code ≥ 2.1.287 (padrão do Sonnet na API), mas até 2026-10-02 as sessões rodavam `claude-sonnet-5`. A prova de que a assinatura serve o id é a sessão do pós-deploy da #219, além do check da #220.
- O `"model": "opus"` do `~/.claude/settings.json` continua como padrão **fora do seletor** (Claude aberto na mão, sem `oute-task`).
- A tabela vive em `config/` (sem release: `git pull` + `oute down/up`).

### Reserva (Codex)
A sessão abre no Codex, na linha da mesma fase, em dois gatilhos:
- **`indisponivel`:** `claude auth status` sai com código ≠ 0, ou o `claude` não existe (adendo 2026-10-03, #258: ver abaixo);
- **`cota`:** qualquer janela da assinatura do Claude ≥ 98% (medição na #55; era 90%, #558).

**Fonte da cota (#55, #346):** o comando `oute-quota [--json]` da imagem (bash + `curl` + `jq`), que lê só por `GET https` o uso das duas assinaturas: Claude em `api.anthropic.com/api/oauth/usage`, Codex em `chatgpt.com/backend-api/wham/usage`, com o token que já está no arquivo de credencial do agente (`~/.claude/.credentials.json`, `~/.codex/auth.json`). **Nunca escreve nem renova a credencial:** o refresh token do Claude rotaciona (medido no spike), então quem renovasse invalidaria o do `claude`; token expirado vira `unknown` (`token-expirado`) até o próprio agente renovar. Janelas `5h` e `7d`, `used_pct` de 0 a 100; cache de 120 s (o endpoint do Claude dá 429 em rajada) e, com 429, rede ou timeout, o cache de até 30 min volta com `stale:true`. O seletor (#258) consome o `--json` e aplica a regra; o `oute-quota` só lê.

**`indisponivel`, como foi implementado (fatia 3a, #258):** a checagem mora no `oute-select`, o resolvedor único do `oute-task` e do `spawn`. Sem `--agent`, `--model` nem `--phase`, quando a sessão abriria no Claude, ele roda `claude auth status` (saída descartada, teto de 5 s): código ≠ 0 ou `claude` ausente → `agent: codex`, modelo e esforço da mesma linha, e o campo novo `reserve: "indisponivel"` (senão `""`; o nome evita "fallback", do glossário). "Falha ao abrir" saiu do gatilho: o `oute-task` faz `exec` do agente e não vê a falha. O `auth status` que não responde no teto não troca de agente (aviso, abre no Claude). `--agent`/`--model` explícitos e a `--phase` fixa do dispatcher não caem na reserva: só avisam em stderr, com `reserve` vazio (dispatcher no Codex é a #213). Com o Codex também fora (`codex login status` ≠ 0 ou ausente): aviso "Claude e Codex indisponíveis", abre no Claude e o código é 0. O `oute-task` abre `codex -m <id> -c model_reasoning_effort=<e>`, grava o agente na marca (o restore reabre no Codex) e manda `reserve` no `oute.task.opened`/`reopened` (`oute.task.reserve`); o `spawn` grava no `spawned` e no log o agente que de fato abriu. O gatilho `cota` entrou na fatia 3b (#355, abaixo).

**`cota`, como foi implementado (fatia 3b, #355; regras do relatório do spike #55):** com o Claude disponível (`auth status` ok ou sem resposta no teto) e sem `--agent`, `--model` nem `--phase`, o `oute-select` lê `oute-quota --json` (teto de 3 s; o que passar disso é leitura que falhou). O corte vem do `max_pct` do JSON (98, `OUTE_QUOTA_MAX_PCT`; era 90 até a #558), **por janela**: qualquer janela do Claude (`5h` ou `7d`) ≥ 98% → `agent: codex`, mesma linha da fase, `reserve: "cota"`, e o aviso diz a janela, o % e a hora do reset (a da `7d` pode ser de dias). **Exceção, só para a janela de 5 h:** se ela é a única ≥ 98%, está abaixo de 100% e reseta em menos de `reset_grace_s` (1200 s, 20 min), a sessão só avisa e abre no Claude (a sessão `build` mediana dura 11 min; a `7d` nunca tem exceção, o veto dela dura dias). Cota do Claude `unknown` (ou `oute-quota` ausente, sem resposta ou com saída inválida) → só aviso, abre no Claude: cota desconhecida não troca. Claude ≥ 98% e Codex também ≥ 98% em alguma janela → aviso claro e abre no Claude. Codex `unknown` com o Claude esgotado → troca, com aviso (o `codex` renova o token ao abrir). `--agent`/`--model`/`--phase` não leem a cota nem caem na reserva. Com `claude auth status` falhando, vale o `indisponivel` e a cota não é lida. O revalidar do 20 min após duas semanas de snapshots reais continua em aberto (relatório do #55).

Cota desconhecida (leitura falhou) não troca de agente: abre no Claude e avisa. Os dois esgotados: aviso claro, nunca bloqueio em silêncio.

### Adendo 2026-10-05 — assinatura padrão e reservas (#598)
Gate de `spec` do Bardi em 2026-10-05 ([comentário na #598](https://github.com/renatobardi/oute-agent/issues/598#issuecomment-5997023390)). Ter mais de uma assinatura serve para **alternar entre elas e não parar o trabalho esperando**; nenhum comando recusa ou adia trabalho porque a cota de **outra** assinatura está alta. O motivo: em 2026-10-05 a linha de base da #484 não rodou porque o `oute-regression` olhou a janela de 5 h do Codex (91%), consumida por outra rodada, e a suíte roda só no Claude ([auditoria do PR #597, achado 2](https://github.com/renatobardi/oute-agent/pull/597#issuecomment-5996350646)).

- **Padrão e reservas.** A tabela (`config/select/models.toml`) lista as assinaturas em `[[subscription]]`: uma tem `default = true` (hoje o `claude`); as outras são **reservas** (hoje o `codex`). Cada linha de fase tem uma coluna de modelo por assinatura. Toda sessão abre na padrão enquanto ela está disponível e com todas as janelas abaixo do teto (98%, #558). O teto e o limite de 60% da regressão não mudam.
- **Dois modos de escolher a reserva** (campo `[select] reserve_mode`, valor inicial `mais-livre`): `mais-livre` abre na reserva disponível com **mais cota livre** (cota livre = 100 − a janela mais cheia da assinatura: 5 h a 91% e 7 d a 39% = 9% livre); `ordem` abre na **primeira reserva da tabela** que está disponível e abaixo do teto (a 2ª ganha mesmo com menos folga que a 3ª). Entre candidatas abaixo do teto, a padrão vem antes das reservas.
- **Todas no teto:** abre na que tem mais cota livre, a padrão incluída, com aviso, nos dois modos. O seletor nunca recusa abrir por cota.
- **Cota desconhecida** (leitura falhou, ou o `oute-quota` não lê aquela assinatura): a assinatura fica por último entre as reservas, e o aviso diz que a cota não foi lida. Na assinatura de partida, a cota desconhecida só avisa e abre nela (como antes).
- **Reserva pedida e cheia.** O `oute-select --prefer <assinatura>` pede uma assinatura que não é a padrão sem ser escolha explícita: com ela no teto, vale a mesma regra e a sessão pode voltar para a padrão. **Escolha explícita** do Bardi (`--agent`, `--model` no `oute-task` ou no `spawn`, `--phase`) continua mandando: só avisa, não troca, e a cota nem é lida. Nenhum chamador usa `--prefer` ainda (quem abre a rodada numa reserva é do `oute-swarm`, fora desta fatia).
- **Registro.** O JSON do seletor ganha `reserve_from` (a assinatura de onde a sessão saiu) **só quando há reserva**; `reserve` segue `cota` ou `indisponivel`, e o `agent` é o de destino. O `oute-task` leva os dois ao evento (`oute.task.reserve`, `oute.task.reserve_from`). Sem reserva, a saída é a de antes da #598.
- **`oute-regression`:** a trava de cota (limite de 60%, inalterado) conta só as janelas da assinatura que a execução usa: o Claude, mais o Codex quando se pede `--codex`. A mensagem de recusa diz a assinatura e a janela.
- **`scripts/models-check`** confere a tabela: uma assinatura padrão só, uma coluna de modelo de cada assinatura em toda linha, nomes únicos e `reserve_mode` válido. Só `claude` e `codex` têm conferência dos ids; o id de outra assinatura fica `desconhecido`.

**O que uma assinatura nova precisa para entrar** (cada uma é issue própria, depois da #598; Devin, Kimi, GLM, Grok e Groq foram citados e não entram aqui):
1. o agente roda no container e abre sessão pelo `oute-task` e pelo herdr;
2. leitura da cota dela no `oute-quota` (só leitura, sem tocar na credencial);
3. linha de modelo por fase na tabela (e o autor dela em `[[reviewer]]`), conferida pelo `scripts/models-check`;
4. consumo no bucket e no agent-studio (ADR-08 §11: sem isso a ferramenta não entra), com preço cadastrado;
5. notas do agente, hooks do ai-memory e canal de aprovação funcionando nela;
6. passa na regressão de agentes (#484) antes de virar reserva.
Com 1 a 6 prontos, entrar é cadastro: um `[[subscription]]` e uma coluna na tabela, sem código novo no `oute-select`.

### Adendo 2026-10-03 — `kaizen` não vence fase de código (#409)
Gate de `spec` do Bardi (opção 1, delegado à sessão de upstream, ciclo #233): a exceção `kaizen` só vale quando a issue **não** tem label de fase que mexe em código. Com `aidlc:build`, `qa`, `design`, `plan`, `ship` ou `iter`, vale a fase (Sonnet). `spike` (#379) continua vencendo as demais exceções, e `docs` não muda. Na tabela, a exceção `kaizen` leva `unless_phases` com essas fases; o `oute-select` pula a exceção quando a issue tem uma delas, e o `scripts/models-check` confere que cada fase listada é do ADR-07.

**Evidência (amostra única):** na rodada `swarm-1003-1210`, a #230 (`kaizen` + `aidlc:build`, `scripts/oute`) abriu em Haiku e o PR #362 precisou de 3 auditorias e 2 ajustes: 1º head com validação que aceitava o que o critério manda recusar, variáveis mortas, nenhum teste do caminho `oute up` e corpo com "13 testes, todos verdes"; 2º head só com os prefixos `/16`, `/17` e `/24`; 3º head corrigido. As outras sete sessões da rodada (Sonnet, label de fase) tiveram no máximo um ajuste. **Ressalva:** é uma sessão só, e Sonnet versus Haiku não foi medido de forma controlada; a decisão é política (código vence o label de tipo) e se revê com mais rodadas.

### Adendo 2026-10-05 — Sonnet no lugar do Haiku automático (#615)
Decisão do Bardi por segurança: `ops`, `ctx`, `learn`, `kaizen` e `docs` passam a usar `claude-sonnet-5-5`. O seletor mantém a escolha explícita de Haiku por `--model claude-haiku-4-5-20251001`.

Os comentários da #484 relatam duas rodadas, com três repetições por tarefa e modelo, e descrevem falhas do Haiku em `checkout`, `memory` e `segredo` e aprovação do Sonnet. Esses números e resultados históricos não têm registros reproduzíveis versionados neste repositório e ficam **não verificados** nesta decisão. Fontes do relato: [rodada 1](https://github.com/renatobardi/oute-agent/issues/484#issuecomment-5997065952) e [rodada 2](https://github.com/renatobardi/oute-agent/issues/484#issuecomment-5998479095). A regressão local deste PR verifica somente os graders falsos e não revalida essas rodadas históricas.

A reserva dessas fases e exceções permanece `gpt-6-luna`, esforço `medium`. A #615 manda registrar o modelo pequeno no PR e não trocá-lo sem evidência.

A regra da #481 continua valendo para a escolha explícita de Haiku: a redação final passa a um subagente Sonnet. A regressão mantém Haiku como modelo de teste explícito. As falhas reais de `checkout`, `memory` e `segredo` continuam registradas na #484. Esta decisão não reforça as notas nem muda os critérios que reprovam essas tarefas.

### Sessão do dispatcher
A sessão que coordena uma rodada do swarm (o dispatcher) abre na fase **`plan`** fixa, sem Jev: triagem e acompanhamento são planejamento, e o `swarm.md` inteiro não é texto de tarefa para classificar.

### Fable 5.1 fora da tabela
O `claude-fable-5-1` (um nível acima do Opus, 2,5× o preço dele na API) não entra em nenhuma linha. As fases do Opus são conversa com gate humano, onde o ganho do Fable (tarefa longa e autônoma) pesa pouco, e o consumo maior aproximaria o gatilho de cota. Uso só por `--model claude-fable-5-1`. Reavaliar com o consumo de cota das fases do Opus medido no agent-studio.

### Jev direto na TypeSafe
- O Jev (`jev-1.13.0`) é chamado **direto na API da TypeSafe** (`POST https://api.typesafe.ai/v1/systemone`, primitivo `choice` → opção + confiança), sem intermediário. US$ 0,042/M tokens de entrada, saída grátis.
- Só o texto da tarefa vai ao Jev, e só por `https://` (#313). Nenhum token de assinatura passa por proxy.
- Chave da TypeSafe no vault (pasta `oute-agent`, item `typesafe`, campo `OUTE_TYPESAFE_API_KEY`) → `agent_env`. É opcional: o `oute up` não a exige, e sem ela o seletor não chama o Jev (gate de `spec`, 2026-10-02).
- Skill da TypeSafe (`typesafe-ai/skills`): nada de `claude plugin install`/`npx skills add` (nada do marketplace). Fork revisado e pinado em `addons/skills/`, ou só referência no build.

### Plugin herdr não chama LLM (#218, gate de `spec` do Bardi, 2026-10-02)
Plugin herdr **não chama API de LLM**; quem fala com modelo é o agente da sessão (Claude/Codex, por assinatura). A única chamada fora das assinaturas é o Jev na TypeSafe, feita pelo seletor (acima). Substitui a regra anterior, que só permitia chamada a LLM pelo roteador de modelos (Histórico).

### Telemetria (ADR-04, ADR-08)
Cada escolha vai como atributos do `oute.task.opened` (sem evento novo): fase, origem da escolha (`manual`/`label`/`jev`/`padrao`), confiança do Jev, agente, modelo, esforço e motivo da reserva (`indisponivel`/`cota`). Vai ao bucket e ao agent-studio. O `oute.swarm.session.spawned` grava o agente que de fato abriu, e a rodada aberta com `--agent` leva `oute.swarm.round.agent` (#212).

### Fora
- **Revisão cruzada** (auditoria de um PR pelo outro provedor): descartada.
- Mudar o comportamento do ai-memory: ele usa provedor próprio (`AI_MEMORY_LLM_PROVIDER`) e não depende do router.

### Como o seletor decide (fatia 1, #219)
- **Tabela:** `config/select/models.toml`, montada só leitura no `agent` em `/opt/oute/select`. Uma linha por grupo de fases, as exceções por label e o padrão.
- **`oute-select`** é o resolvedor único: `oute-select --json` devolve `phase`, `origin`, `agent`, `model`, `effort` e `reason` sem abrir sessão. O `oute-task` e o `oute-swarm spawn` chamam o mesmo comando, e a triagem do dispatcher também.
- **Issue da sessão:** o número no começo do slug (`<n>-…`), lido com `gh issue view <n> --json labels` no repo da sessão. Slug sem número é sessão sem issue.
- **Escolha explícita (`manual`):** `--agent`/`--model` no `oute-task` e no `spawn`, o agente da rodada, o `codex` posicional e o `--model`/`-m` nos argumentos do agente. O que a escolha explícita não disse vem da linha que a issue daria: `--agent codex` abre o modelo e o esforço do Codex da fase; `--model` sem `--agent` abre no agente da coluna em que o id está (fora da tabela, pelo prefixo do id).
- **Fase fixa do dispatcher:** `plan`, com origem `padrao` (nenhum label decidiu).
- **Nunca bloqueia:** `gh` fora do ar, issue sem label de fase, fase fora da tabela ou sessão sem issue dão o padrão (Sonnet), com aviso. Tabela ausente ou inválida, ou `oute-select` falhando: a sessão abre sem `--model`, no modelo padrão do agente, com aviso. Só argumento inválido (`--agent`/`--model`) recusa a abertura.
- **Abertura:** `claude --model <id>` ou `codex -m <id> -c model_reasoning_effort=<e>`. A marca da sessão guarda agente, modelo e esforço, e o shim os repõe quando a conversa é retomada (restore do herdr, `--resume`, `codex resume`) sem modelo na linha de comando.

### Como o Jev é chamado (fatia 2, #257)
- **Quem chama:** só o `oute-select`, em processo (sem `curl`, sem intermediário), e só quando se sabe que não há label de fase: sessão sem issue, ou issue lida pelo `gh` sem `aidlc:<fase>` da tabela. Com o `gh` fora do ar, com a fase fixa do dispatcher, com exceção por label ou com `--model`, o Jev não é chamado. `--agent codex` sem `--model` chama: a fase escolhe a linha do Codex, e a origem segue `manual`.
- **Texto da tarefa:** o prompt com que a sessão abre. No `oute-task`, o último argumento do agente, se é posicional (o anterior é `--`, ou nenhum argumento antes dele é opção sem `=`, que pode ser a dona de um ou de vários valores; #313), não é opção e tem mais de uma palavra; no `oute-swarm spawn`, a instrução, sem as regras do worker. Vai ao `oute-select` pelo stdin (`--text-file -`), cortado em 16 000 caracteres. Sessão aberta na mão (sem prompt) não tem texto: Sonnet, sem chamada.
- **Pedido:** `POST` ao `/v1/systemone` com `state` = o texto, `model` = `jev-1.13.0` (id exato, como os da tabela) e uma pergunta `choice` cujas opções são as fases da tabela, cada uma com uma linha do que a fase faz. Nada do repo, da issue ou do ambiente entra no pedido.
- **Resposta:** a fase (`choice`) e a confiança (`confidence`, 0 a 1). Confiança ≥ 0,6: origem `jev` e a linha da fase. Abaixo disso: padrão Sonnet, origem `padrao`, com a confiança registrada.
- **Teto de 3 s** para a chamada inteira (DNS, conexão e resposta). Tempo esgotado, erro HTTP (inclusive 401 e 429), redirecionamento (não seguido: levaria a chave a outro endereço), resposta fora do formato ou fase que não está na tabela: padrão Sonnet, com aviso, sem nova tentativa. A abertura nunca espera mais que isso nem é bloqueada.
- **Chave:** `OUTE_TYPESAFE_API_KEY` no ambiente (o prefixo `OUTE_` é o que a leva aos logins, pela allowlist do `entrypoint.sh`). Vai só no cabeçalho `Authorization` da chamada: nunca em argumento de processo, aviso, log ou evento. Sem ela: padrão Sonnet, com aviso, sem chamada.
- **Saída do `oute-select`:** o campo novo `confidence` (a do Jev sempre que ele respondeu; senão vazio) e a origem `jev`. O motivo diz a fase e a confiança.
- **Skill da TypeSafe:** não foi usada. O seletor fala HTTP direto, com o formato lido da documentação da API (`docs.typesafe.ai/api.md`, `primitives/choice.md`, 2026-10-03); nada entrou em `addons/skills/`.
- **Limite conhecido:** a triagem do dispatcher (`oute-select --issue <n>`, sem texto) mostra `padrao` para uma issue sem label de fase que o `spawn`, com a instrução, pode abrir pela fase do Jev. Reabrir na mão (sem prompt) uma sessão que o Jev classificou resolve de novo, sem texto, e a marca passa ao padrão; o restore do herdr não é afetado (usa a marca).

Implementação, em fatias (adendo 2026-10-02):
1. #219: tabela em `config/`, label de tipo e de fase, `oute-select`, padrão Sonnet;
2. #257: Jev direto na TypeSafe;
3. #258: reserva no Codex pelo gatilho `indisponivel` (fatia 3a); #355: o gatilho `cota` (fatia 3b), sobre o `oute-quota` (#346).

Junto: #212 (`--agent` da rodada), #214 (dispatcher), #220 (check dos ids da tabela). Feitos: #217 (Pi) e #218 (router). O gatilho `indisponivel` não depende da cota; só o `cota` depende.

## Histórico

### Roteamento Jev + OpenRouter (2026-09-23 a 2026-09-30)
Vigorou para clientes OpenAI-compatible (na prática, só o Pi); Claude Code e Codex sempre ficaram fora, por assinatura. Saiu com o Pi (#217, #218): o serviço `jev-router` (LiteLLM + hook do Jev), `config/litellm/`, o `oute router-sync` e a key do OpenRouter não existem mais no repo.

- **Duas etapas por request:** o **Jev** (`typesafe/jev-1.13`, Decisions API do OpenRouter `/api/alpha/decisions`) escolhia o **perfil** pela tarefa (falha → perfil mais barato); o **OpenRouter** escolhia o **modelo** dentro do perfil (`models` ≤ 3 + `provider.sort = {by, partition: "none"}`, com fallback entre endpoints). Cada padrão do perfil contribuía com 1 modelo, para o fallback ser entre famílias diferentes.
- **Perfis** (`reasoning`, `coder`, `coder-fast`, `long-context`, `cheap`, `vision`) publicados como presets `@preset/oute-<perfil>` (ZDR, `data_collection: deny`). Presets por papel (reviewer/architect) foram descartados em 2026-09-26 (#14): papel e perfil são eixos ortogonais; persona fica em prompt versionado.
- **Guardrail do OpenRouter como fonte de verdade** (US$ 15/mês, ZDR, sem treino), espelhado em `config/litellm/policy.yaml` e checado por `oute router-sync --check-guardrail` com a Management key, que só o host lia (#16). Modelos abertos só por hosts neutros; nada de criadores 1st-party de terceiros; `*:free` e `*:batch` fora.
- **Catálogo vivo:** `oute router-sync` em todo `oute up` e diariamente às 04:00, gerando `router.yaml`, `config.yaml`, `candidates.json` e `catalog.json` fora do git. LiteLLM fixado por digest (1.103.0).
- **Lições da API:** `models` > 3 → HTTP 400; `partition` vai dentro de `provider.sort`; o Jev não aparece em `/models` (só dá para validar com chamada real); presets salvam por `POST /api/v1/presets/{slug}/chat/completions` e são usados via `model: "@preset/<slug>"`; guardrails só se leem com Management key.
- **Por que saiu:** na rodada `swarm-0929-2356`, a sessão Pi da #203 caiu duas vezes por erro do modelo servido (Groq chamando ferramenta inexistente; Moonshot recusando o schema das ferramentas do Pi), sem fallback útil; ajustes no guardrail custaram 8 dry-runs do `router-sync`, e o `oute up` do #211 gravou um roteamento degradado.

### A/B Jev × `openrouter/auto` (#15, 2026-09-25) — ficou o Jev
- Infra: `OUTE_AB_MODE` no jev-router (`off`, `split`, `auto`), sorteio estável por conversa, fração por `OUTE_AB_AUTO_SHARE`. O braço `auto` usava `openrouter/auto` com `allowed_models` = o pool que o Jev teria.
- Medição pelo span `jev.decision` (`oute.ab_arm`, `oute.ab_mode`), com custo, modelo e provedor vindos do `/generation`.
- Único dado coletado (mesmo prompt trivial, com tools):

  | braço | escolha | modelo servido | custo |
  |---|---|---|---|
  | auto | — | `moonshotai/kimi-k2.6` (BaseTen) | US$ 0,0118 |
  | Jev | perfil `cheap` | `openai/gpt-oss-20b` (DeepInfra) | US$ 0,00036 |

  O `auto` saiu ~33× mais caro com a mesma qualidade percebida: escolhe pelo uso da comunidade, não por custo. Qualidade em tarefas reais nunca foi avaliada.
- Decisão do Bardi: ficou o Jev. O tema acabou com a saída do OpenRouter.
