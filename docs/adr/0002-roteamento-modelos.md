# ADR-02 — Seleção de agente e modelo por sessão

Status: proposto · 2026-09-30 (#215, gate de `arch` do Bardi) · substitui o roteamento Jev + OpenRouter de 2026-09-23 a 2026-09-26 (ver **Histórico**)

## Decisão
O **Claude Code é o agente principal** e o **Codex é a reserva**, os dois por assinatura. Cada sessão (`oute-task`, `oute-swarm spawn`) abre com o modelo Claude da **fase** da tarefa, escolhido por uma tabela fixa em `config/`, sem o Bardi escolher na mão. **Pi, jev-router, LiteLLM e OpenRouter saem do stack** (#217, #218): sem o Pi, o router não tem cliente, e as quedas da rodada `swarm-0929-2356` (modelo servido chamando ferramenta inexistente ou recusando o schema, sem fallback) mostraram que o custo de manter o roteamento não compensa.

### Ordem de precedência
1. **`--model` / `--agent` explícitos** vencem tudo. `--agent codex` força o Codex.
2. **Exceção por label de tipo** na issue, antes da fase:
   - `kaizen` → Haiku (issue de lição, de qualquer origem; hoje elas carregam `aidlc:spec` e cairiam no Opus);
   - `docs` → Haiku (doc que não é ADR: README, `AGENTS.md`, `CONTEXT.md`, guias). ADR segue a fase dele (`arch`).
3. **Fase**, pelo label `aidlc:<fase>` da issue (tabela abaixo).
4. **Jev**, só quando não há label de fase: sessão avulsa sem issue, ou issue sem `aidlc:<fase>`. O Jev classifica a fase pelo texto da tarefa e a tabela dá o modelo. Confiança < 0,6 ou falha do Jev → Sonnet.

### Tabela fase → modelo
| fase | Claude | reserva (Codex) |
|---|---|---|
| `strat` `intent` `arch` `spec` | `claude-opus-5-5` | `gpt-6-astra`, esforço `high` |
| `build` `qa` `design` `plan` `ship` `iter` | `claude-sonnet-5-5` | `gpt-6-sol`, esforço `high` |
| `ops` `ctx` `learn` | `claude-haiku-4-5-20251001` | `gpt-6-luna`, esforço `medium` |

- A tabela é indexada só por fase do ADR-07. `kaizen` e `docs` não são fases: entram como exceção (acima), com a reserva da linha do Haiku.
- `ship` e `iter` ficam no Sonnet: release/deploy e reescrita do que já existe não descem para o Haiku.
- **Ids exatos, sem alias** (`opus`, `sonnet`): a troca de versão é uma mudança visível na tabela, não um efeito colateral de upgrade do CLI. Todo id da tabela precisa existir no CLI instalado; o check é a #220 (checklist da `oute-aidlc-ship-release` ou nível 0 da #52).
- A série `gpt-5.x` do Codex fica fora (marcada como antiga pelo próprio CLI).
- O `"model": "opus"` do `~/.claude/settings.json` continua como padrão **fora do seletor** (Claude aberto na mão, sem `oute-task`).
- A tabela vive em `config/` (sem release: `git pull` + `oute down/up`).

### Reserva (Codex)
A sessão abre no Codex, na linha da mesma fase, em dois gatilhos:
- **`indisponivel`:** o Claude falha ao abrir (erro, auth);
- **`cota`:** qualquer janela da assinatura do Claude ≥ 90% (medição na #55).

### Fable 5.1 fora da tabela
O `claude-fable-5-1` (um nível acima do Opus, 2,5× o preço dele na API) não entra em nenhuma linha. As fases do Opus são conversa com gate humano, onde o ganho do Fable (tarefa longa e autônoma) pesa pouco, e o consumo maior aproximaria o gatilho de cota. Uso só por `--model claude-fable-5-1`. Reavaliar com o consumo de cota das fases do Opus medido no agent-studio.

### Jev direto na TypeSafe
- O Jev (`jev-1.13.0`) é chamado **direto na API da TypeSafe** (`POST https://api.typesafe.ai/v1/systemone`, primitivo `choice` → opção + confiança). Sem OpenRouter. US$ 0,042/M tokens de entrada, saída grátis.
- Só o texto da tarefa vai ao Jev. Nenhum token de assinatura passa por proxy.
- Chave da TypeSafe no vault (pasta `oute-agent`) → `agent_env`.
- Skill da TypeSafe (`typesafe-ai/skills`): nada de `claude plugin install`/`npx skills add` (nada do marketplace). Fork revisado e pinado em `addons/skills/`, ou só referência no build.

### Telemetria (ADR-04, ADR-08)
Cada escolha gera um evento com: fase, origem da escolha (`manual`/`label`/`jev`), confiança do Jev, agente, modelo, esforço e motivo da reserva (`indisponivel`/`cota`). Vai ao bucket e ao agent-studio.

### Fora
- **Revisão cruzada** (auditoria de um PR pelo outro provedor): descartada.
- Mudar o comportamento do ai-memory: ele usa provedor próprio (`AI_MEMORY_LLM_PROVIDER`) e não depende do router.

Implementação: #219 (seletor), com #217 (Pi), #218 (router) e #55 (cota).

## Histórico

### Roteamento Jev + OpenRouter (2026-09-23 a 2026-09-30)
Vigorou para clientes OpenAI-compatible (na prática, só o Pi); Claude Code e Codex sempre ficaram fora, por assinatura. Sai com o Pi (#217, #218).

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
