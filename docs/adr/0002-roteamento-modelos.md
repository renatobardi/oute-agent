# ADR-02 — Roteamento de modelos (Jev + OpenRouter + guardrail)

Status: aceito · 2026-09-23 (revisado no mesmo dia: allowlist via hosts neutros; perfis publicados como presets) · 2026-09-25: detecção de divergência com o guardrail (#16), Goose fora, A/B Jev × `openrouter/auto` (#15) — **fica o Jev** · 2026-09-26: presets por papel descartados (#14)

## Decisão
Seleção em **2 etapas** por request, para clientes OpenAI-compatible (hoje o Pi):
1. **Jev** (`typesafe/jev-1.13`, OpenRouter Decisions API `/api/alpha/decisions`) escolhe o **perfil** pela tarefa. Se falhar, vai para o perfil mais barato.
2. **OpenRouter** escolhe o **modelo** dentro do perfil: `models` (≤ 3, limite do OpenRouter) + `provider.sort = {by, partition: "none"}`, que ordena os endpoints de todos os modelos ao vivo e faz fallback.

Cada padrão do perfil contribui com **1 modelo** (o mais novo elegível). Assim os perfis misturam famílias, e o fallback é entre modelos diferentes.

## A/B Jev × `openrouter/auto` (#15, 2026-09-25) — decisão: fica o Jev (Bardi)
- **Infra pronta e desligada:** `OUTE_AB_MODE` no jev-router aceita `off` (padrão, em uso), `split` e `auto`. No `split`, o sorteio é estável por conversa (hash da 1ª mensagem) e a fração vai para o `auto` via `OUTE_AB_AUTO_SHARE`.
- **Braço auto:** modelo `or-auto` (gerado pelo router-sync) → `openrouter/auto` com o plugin `auto-router`. `allowed_models` = o mesmo pool que o Jev teria para aquela request (perfis elegíveis por tools/vision/max_tokens), com ZDR, `data_collection: deny` e `session_id` por conversa.
- **Medição:** o span `jev.decision` carrega `oute.ab_arm` e `oute.ab_mode`; no Langfuse, o trace é `ab-auto` × `jev:<perfil>`. Custo, modelo e provedor vêm do `/generation`.
- **Único dado coletado** (mesmo prompt trivial, "resuma em 1 frase o que é um A/B test", com tools):

  | braço | escolha | modelo servido | custo |
  |---|---|---|---|
  | auto | — | `moonshotai/kimi-k2.6` (BaseTen) | US$ 0,0118 |
  | Jev | perfil `cheap` | `openai/gpt-oss-20b` (DeepInfra) | US$ 0,00036 |

  Ou seja, o `auto` ficou **~33× mais caro** com a mesma qualidade percebida. Ele escolhe pelo uso da comunidade, não por custo. O Jev ainda cobra ~US$ 0,0001 por decisão, fora da conta.
- **Não avaliado:** qualidade em tarefas reais. Opções guardadas para quando voltar ao tema: suíte fixa de ~10 tarefas com julgamento cego do Bardi (recomendada), sinais indiretos do uso real, ou LLM como juiz. Também dá para testar o `auto` com `cost_tier: low`.
- Para retomar: `OUTE_AB_MODE=split` no `.env` do oute-server + `oute down/up`.

## Perfis = presets do OpenRouter (opção A, 2026-09-23)
- O `router-sync` publica cada perfil como **`@preset/oute-<perfil>`** (model, models, `provider: {data_collection: deny, zdr: true, sort}`).
- Publica só quando a config mudou (GET compara → POST de nova versão); `--no-presets` desliga.
- O LiteLLM (`config.yaml`) aponta para `openrouter/@preset/oute-<perfil>`; o `jev_hook` não injeta `extra_body` quando o perfil tem preset. Sem preset (falha na publicação), volta ao modelo primário + `extra_body`.
- Vantagens: config de roteamento versionada e visível no painel do OpenRouter; ZDR/no-training reforçados por request além do guardrail; histórico de versões por perfil.
- O modelo real servido, o provedor e o custo vêm do `jev.decision` enriquecido via `/generation` (ADR-04).
- **Presets por papel (opção B) — descartado (#14 fechada, 2026-09-26).** Papel (reviewer/architect) e perfil (reasoning/coder/cheap) são eixos ortogonais: preset por papel ou fixa modelo (mata o roteamento por tarefa) ou vira matriz papel × perfil. Claude Code/Codex não passam pelo OpenRouter, então system prompt em preset só afetaria o Pi. Persona fica em prompt versionado no repo (`swarm-worker.md`) e, depois, em skills/agents do `oute-agent-plugins`. Se um papel precisar de viés de perfil: header/metadata `x-oute-profile` honrado pelo `jev_hook` — só quando houver caso real.

## Guardrail é a fonte de verdade
- Guardrail "oute-agent guardrail - core" (US$ 15/mês, ZDR para todos os modelos, sem treino). A key do oute-agent no vault está sob ele (`/models/user` → 175 modelos).
- **Política de provedores:** nada direto de criadores 1st-party de terceiros (Moonshot, DeepSeek etc.). Modelos abertos vêm por **hosts neutros**: Fireworks, Together, DeepInfra, Baseten, Groq, Cerebras. Criadores que servem os próprios modelos: xAI, Z.ai, Alibaba, Mistral, MiniMax, Xiaomi. TypeSafe = Jev.
- Anthropic/OpenAI/Google fora do router; Claude Code e Codex seguem por assinatura própria.
- Exclusões: `*:free` (rate limit, retenção/treino), `*:batch` (assíncrono).
- Efeito do ZDR: endpoints do xAI que retêm dados ficam fora, então o Grok hoje não entra em nenhum perfil.

### Detecção de divergência `policy.yaml` × guardrail (#16, 2026-09-25)
- `policy.yaml: guardrail` guarda o nome exato do guardrail.
- O `router-sync` lê o guardrail via **Management API** (`GET /api/v1/guardrails`) e compara:
  - `providers_allow` × `allowed_providers`, nos dois sentidos;
  - provedores do `policy.yaml` que estão em `ignored_providers`;
  - ZDR desligado.
- Sync normal: só avisa (também no log do cron diário). `oute router-sync --check-guardrail`: só checa, não grava nem reinicia nada, e retorna 0 (alinhado), 2 (divergente) ou 1 (não verificado).
- **Credencial:** `OPENROUTER_MGMT_KEY`, na nota `openrouter-mgmt` da pasta **`oute-admin`** do vault. A Management key pode criar chaves e editar guardrails, por isso **nunca vai ao container dos agentes**: só o host a lê, e só para esse GET. Sem ela, o sync avisa que não verificou e segue.
- Validado em 2026-09-25: alinhado (13 provedores).

## Perfis vigentes (sync 2026-09-25)
| perfil | sort | modelos |
|---|---|---|
| reasoning | ordem | glm-5.3, kimi-k2.6, deepseek-v3.2 |
| coder | throughput | glm-5.3, kimi-k2.7-code, qwen3-coder-plus |
| coder-fast | latency | gpt-oss-120b, devstral-2512, qwen3-coder-flash |
| long-context | price | minimax-m3, qwen-plus, qwen3-coder-plus |
| cheap | price | gpt-oss-20b, mistral-small-2603, deepseek-v3.2 |
| vision | price | qwen3-vl-32b, glm-4.6v, llama-4-maverick |

Preferências do Bardi: GLM, Kimi, DeepSeek, Grok. Padrões com `[0-9]` no fim pegam versões "cheias" (sem -flash/-code/-air).

## Catálogo vivo
- `oute router-sync`: `/providers`, `/models`, `/models/user`, `/models/{id}/endpoints` + probe real do Jev → `router.yaml`, `config.yaml` (inclui `or-auto`), `candidates.json`, `catalog.json` (fora do git; fonte = `policy.yaml`) + publicação dos presets + checagem do guardrail.
- Roda em todo `oute up` (se falhar, usa o catálogo anterior) e diariamente às 04:00 (`oute schedule`).
- Imagem usada pelo sync: a mesma do jev-router, LiteLLM fixado por digest (1.103.0).

## Lições da API
- `models` > 3 → HTTP 400.
- `partition` vai dentro de `provider.sort` como objeto `{by, partition}`.
- O LiteLLM repassa `extra_body` para o OpenRouter sem problema (inclusive `plugins` e `session_id` do auto-router).
- O Jev não aparece em `/models` (é Decisions API), então só dá para validar com chamada real.
- Presets: `POST /api/v1/presets/{slug}/chat/completions` salva (não executa); `GET /api/v1/presets/{slug}` lê; uso via `model: "@preset/<slug>"`.
- Guardrails: leitura só com Management API key (`GET /guardrails`, campos `allowed_providers`, `ignored_providers`, `enforce_zdr*`).
- `openrouter/auto`: pelo LiteLLM é `openrouter/openrouter/auto`; o `allowed_models` aceita curingas e sem custo extra de roteamento.
