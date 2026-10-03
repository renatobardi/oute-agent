# ADR-02 — Seleção de agente e modelo por sessão

Status: aceito · 2026-09-30 (#215, gate de `arch` do Bardi, PR #221) · substitui o roteamento anterior, de 2026-09-23 a 2026-09-30 (ver **Histórico**) · adendo 2026-10-02: precedência da rodada, reserva do Sonnet em `gpt-6.1-sol` e seletor em fatias (gate de `spec` do Bardi, ciclo #233) · adendo 2026-10-03: como o Jev é chamado (fatia 2, #257)

## Decisão
O **Claude Code é o agente principal** e o **Codex é a reserva**, os dois por assinatura. Cada sessão (`oute-task`, `oute-swarm spawn`) abre com o modelo Claude da **fase** da tarefa, escolhido por uma tabela fixa em `config/`, sem o Bardi escolher na mão. **O Pi e o roteador de modelos (ver Histórico) saem do stack** (#217, #218): sem o Pi, o router não tem cliente, e as quedas da rodada `swarm-0929-2356` (modelo servido chamando ferramenta inexistente ou recusando o schema, sem fallback) mostraram que o custo de manter o roteamento não compensa.

### Ordem de precedência
1. **`--model` / `--agent` explícitos** vencem tudo, dados na sessão ou na abertura da rodada (`oute-swarm <repo> --agent`, #212). `--agent codex` força o Codex. Escolha explícita não cai na reserva: só avisa. O `claude` posicional que o shim passa ao `oute-task` não conta como explícito.
2. **Exceção por label de tipo** na issue, antes da fase:
   - `kaizen` → Haiku (issue de lição, de qualquer origem; hoje elas carregam `aidlc:spec` e cairiam no Opus);
   - `docs` → Haiku (doc que não é ADR: README, `AGENTS.md`, `CONTEXT.md`, guias). ADR segue a fase dele (`arch`).
3. **Fase**, pelo label `aidlc:<fase>` da issue (tabela abaixo).
4. **Jev**, só quando não há label de fase e há texto da tarefa: sessão avulsa sem issue, ou issue sem `aidlc:<fase>`. O Jev classifica a fase pelo texto da tarefa e a tabela dá o modelo. Confiança < 0,6 ou falha do Jev (erro, tempo esgotado) → Sonnet.
5. **Padrão Sonnet** quando nada acima decide: sem label e sem texto da tarefa (sessão aberta na mão), sem a chave da TypeSafe, ou `gh` fora do ar. O seletor avisa e nunca bloqueia a abertura.

### Tabela fase → modelo
| fase | Claude | reserva (Codex) |
|---|---|---|
| `strat` `intent` `arch` `spec` | `claude-opus-5-5` | `gpt-6-astra`, esforço `high` |
| `build` `qa` `design` `plan` `ship` `iter` | `claude-sonnet-5-5` | `gpt-6.1-sol`, esforço `high` |
| `ops` `ctx` `learn` | `claude-haiku-4-5-20251001` | `gpt-6-luna`, esforço `medium` |

- A tabela é indexada só por fase do ADR-07. `kaizen` e `docs` não são fases: entram como exceção (acima), com a reserva da linha do Haiku.
- `ship` e `iter` ficam no Sonnet: release/deploy e reescrita do que já existe não descem para o Haiku.
- **Ids exatos, sem alias** (`opus`, `sonnet`): a troca de versão é uma mudança visível na tabela, não um efeito colateral de upgrade do CLI. Todo id da tabela precisa existir no CLI instalado; o check é a #220 (checklist da `oute-aidlc-ship-release` ou nível 0 da #52).
- A série `gpt-5.x` do Codex fica fora (marcada como antiga pelo próprio CLI).
- **Reserva do Sonnet em `gpt-6.1-sol`** (adendo 2026-10-02): o Codex 0.159 marca `gpt-6-sol`, o id original desta linha, como geração anterior.
- **`claude-sonnet-5-5`** existe no Claude Code ≥ 2.1.287 (padrão do Sonnet na API), mas até 2026-10-02 as sessões rodavam `claude-sonnet-5`. A prova de que a assinatura serve o id é a sessão do pós-deploy da #219, além do check da #220.
- O `"model": "opus"` do `~/.claude/settings.json` continua como padrão **fora do seletor** (Claude aberto na mão, sem `oute-task`).
- A tabela vive em `config/` (sem release: `git pull` + `oute down/up`).

### Reserva (Codex)
A sessão abre no Codex, na linha da mesma fase, em dois gatilhos:
- **`indisponivel`:** o Claude falha ao abrir (erro, auth);
- **`cota`:** qualquer janela da assinatura do Claude ≥ 90% (medição na #55).

Cota desconhecida (leitura falhou) não troca de agente: abre no Claude e avisa. Os dois esgotados: aviso claro, nunca bloqueio em silêncio.

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
- **Texto da tarefa:** o prompt com que a sessão abre. No `oute-task`, o último argumento do agente, se é posicional (o anterior não é uma opção que possa ser a dona do valor, ou é `--opção=valor` ou `--`; #313), não é opção e tem mais de uma palavra; no `oute-swarm spawn`, a instrução, sem as regras do worker. Vai ao `oute-select` pelo stdin (`--text-file -`), cortado em 16 000 caracteres. Sessão aberta na mão (sem prompt) não tem texto: Sonnet, sem chamada.
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
3. #258: reserva no Codex (`indisponivel` e `cota`), depois do `oute-quota` que sai do spike #55.

Junto: #212 (`--agent` da rodada), #214 (dispatcher), #220 (check dos ids da tabela). Feitos: #217 (Pi) e #218 (router). O seletor sai sem a reserva: só a fatia 3 depende da cota.

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
