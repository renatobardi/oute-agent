# ADR-04 — Observabilidade (issues #13, #19)

Status: **aceito · fases 1 e 2 validadas · Claude Code e Codex validados (0.5.4) · identificador do agente `oute.agent` (0.7.2) · origem máquina + instância (0.7.5)** · 2026-09-25 · várias instâncias por host descartado (#22, 2026-09-26)
Base: `estudos/observabilidade-rascunho.md` (fontes, destinos do Broadcast, opções de painel).

## Decisões (Bardi, 2026-09-24)
- Painel: **híbrido com Langfuse Cloud (região EU, plano Hobby)**. O conteúdo completo fica só no bucket OCI (São Paulo); o Langfuse recebe **só metadados**. Não há região Langfuse na América do Sul; EU por governança (GDPR); a latência não importa (envio assíncrono em lote).
- **Guardar conteúdo** (prompts/respostas/tools) só no bucket `oute-observability` (compartment `oute-agent`, privado).
- **Retenção do bucket: nada é apagado** (Bardi, 2026-09-24: "não quero apagar nada do que salvamos"). Sem lifecycle de deleção. Se o volume crescer, a alavanca é tiering (Infrequent Access / Archive), nunca delete.
- Porta de entrada única: **OTel Collector** próprio; os destinos são detalhe trocável.
- **Fonte da verdade de modelo real, provedor e custo = OpenRouter.** O LiteLLM só enxerga o preset.
- **Fase 2 = pull via API, não Broadcast**: o hook consulta `GET /api/v1/generation?id=gen-…` e enriquece o `jev.decision`.
- **Regra (Bardi): nenhuma ferramenta entra no stack se não mandar consumo neste padrão (bucket + Langfuse).**

## Arquitetura
```
Claude Code (logs, métricas, traces) ─┐
Codex (logs, traces)                  ├─ OTLP (rede docker "oute") ─> otel-collector ─┬─> OCI S3 oute-observability/otel/{traces,metrics,logs}/host=<máquina>/instance=<instância>/  [TUDO, gzip, lote 5 min, sem expiração]
jev-router: spans LiteLLM + jev.decision ┘   (transform/agent: oute.agent;              └─> Langfuse Cloud (traces)  [allowlist de metadados + allowlist de spans do Codex + uso + metadata.agent/host/instance; Environment = máquina]
                                              resource: host.name, oute.instance)
        └─ jev.decision ← GET openrouter.ai/api/v1/generation?id=gen-…  (modelo real, provedor, custo, latência)
```

## Origem — máquina + instância (0.7.5, 2026-09-25)
Decisão (Bardi): a identidade de origem é a dupla **máquina + instância**. A instância (container/stack) só precisa ser única **dentro** da máquina; o mesmo nome de instância em máquinas diferentes não conflita.

| Atributo | Fonte | Exemplo |
|---|---|---|
| `host.name` | `OUTE_HOST` → `OUTE_HOSTNAME` (nome antigo) → hostname da máquina; normalizado `[a-z0-9_-]`, até 40 caracteres | `oute-server`, `oute-mac` |
| `oute.instance` | `OUTE_INSTANCE`, default `oute-agent` | `oute-agent` |
| `deployment.environment` | = `host.name` | `oute-server` |
| `oute.agent` | ver abaixo | `claude` |

- O `oute` resolve os valores no host e os exporta para o compose.
- O agente recebe `OTEL_RESOURCE_ATTRIBUTES`, e o collector reforça tudo com `resource` upsert (vale também para o jev-router e para o Pi via router).
- **Bucket:** `otel/<sinal>/host=<máquina>/instance=<instância>/year=…/hour=…/`. Os objetos anteriores à 0.7.5, sem `host=/instance=`, ficam onde estão (nada é movido nem apagado).
- **Langfuse:** a máquina vira `langfuse.environment` (seletor **Environment** nativo, no topo). Máquina e instância também vão em `metadata.host` e `metadata.instance`. No pipeline do Langfuse, o processor `resource` roda antes do `transform/metadata_only` para que o transform enxergue `host.name`.
- `oute version` mostra a origem.
- **Uma instância por máquina** (decisão 2026-09-26, #22 fechada): sem caso de uso para várias stacks no mesmo host; isolamento real = outro host/LXC; ai-memory por instância dividiria a memória e quebraria o handoff. O atributo `oute.instance` fica no formato (custo zero) para o caso de um dia reabrir com caso concreto.

## Identificador do agente — `oute.agent` (0.7.2, 2026-09-25)
| Agente | Como é identificado | Valor |
|---|---|---|
| Claude Code | collector: `service.name == claude-code` | `claude` |
| Codex | collector: `service.name` casa `^codex` (`codex_exec`, `codex_cli_rs`) | `codex` |
| Pi (e qualquer cliente do jev-router) | header **`X-Oute-Agent`** na request ao router (o Pi o manda via `headers` no `~/.pi/agent/models.json`, gerado pelo entrypoint); o hook grava no span `jev.decision` | `pi` |
| Cliente do router sem header | o hook | `unknown` (valor sanitizado: `[a-z0-9_-]`, até 32 caracteres) |
| Demais spans do jev-router (LiteLLM) | collector: `service.name == jev-router` | `router` |

- **Onde aparece:**
  - Bucket: resource `oute.agent` em traces, logs e métricas, e `span.attributes["oute.agent"]` nos traces.
  - Langfuse: `metadata.agent` do trace (`langfuse.trace.metadata.agent`), filtrável; `oute.agent` também passa pela allowlist de resource.
  - Log do router: `served agent=pi profile=… model=… cost=…`.
- **Regra para agente novo:** se falar OTel direto, acrescentar o `service.name` no `transform/agent`; se passar pelo jev-router, mandar o header `X-Oute-Agent`.
- **Validado (0.7.2):** `served agent=pi profile=cheap via=jev model=openai/gpt-oss-20b provider=DeepInfra cost=0.00037435`.
- **Lição:** logo depois do `oute up`, o LiteLLM leva ~15–30 s para aceitar conexões (o Pi devolve `Connection error.` nesse intervalo).

## Onde cada coisa fica / limites
| Local | Conteúdo | Limite |
|---|---|---|
| Bucket OCI `oute-observability` | tudo (com conteúdo), gzip | free tier 20 GB (todas as camadas somadas); acima ~US$ 0,026/GB·mês; budget US$ 1 com alerta. Sem expiração. |
| Langfuse Cloud Hobby | só metadados | 50k unidades/mês (trace+observação+score), 30 dias de histórico. 1 interação simples ≈ 14 unidades. |
| Disco do oute-server | o collector não persiste nada; os agentes guardam transcrições no volume home (`~/.claude/projects`, `~/.codex/sessions`); SQLite do ai-memory; logs stdout dos containers | disco de 44 GB, que é o limite real a vigiar. |

## Fase 1 (concluída)
- `otel-collector`: `otel/opentelemetry-collector-contrib:0.161.0` (`OUTE_OTELCOL_VERSION`), sem porta publicada. `config/otel/collector.yaml` (bucket) + `langfuse.yaml` ou `none.yaml` (2º `--config`). Config montada do repo: mudança no pipeline = `git pull` + `oute down/up`, sem release.
- Bucket: exporter `awss3` no endpoint S3-compat da OCI. Partição `host=/instance=/year=/month=/day=/hour=` UTC, `otlp_json` + gzip, lote 5 min. **Exige `AWS_REQUEST_CHECKSUM_CALCULATION=when_required` e `AWS_RESPONSE_CHECKSUM_VALIDATION=when_required`** (senão a OCI responde 501 e o lote é descartado).
- Langfuse: `otlphttp` → `${LANGFUSE_HOST}/api/public/otel`, Basic auth, `x-langfuse-ingestion-version: 4`. Filter: spans internos do LiteLLM fora; span events fora (exceto Codex). Transform: **allowlist** (`keep_matching_keys`).
- jev-router: callback `otel` do LiteLLM + **span próprio `jev.decision`**. Trace `jev:<perfil>` no Langfuse.

## Fase 2 (validada)
- No sucesso, o hook agenda em background `GET /api/v1/generation?id=gen-…` (retries 2/4/8/16 s) e emite o `jev.decision` com modelo servido, provedor, custo US$, tokens nativos, `finish_reason`, latências e o `oute.agent`.

## Claude Code e Codex (#5/#19 — validado 2026-09-24, v0.5.4)
| | logs | metrics | traces | ai-memory |
|---|---|---|---|---|
| Claude Code (`claude-code`) | ✓ | ✓ | ✓ | ✓ |
| Codex (`codex_exec`, `codex_cli_rs`) | ✓ | — | ✓ | ✓ (hooks reaprovados na 0.5.8) |

- **Privacidade conferida:** Input/Output vazios no Langfuse; `user.email`, `organization.id`, `user.account_uuid` do Claude barrados pela allowlist.
- **Uso/tokens** mapeados para `gen_ai.usage.*` (Claude: `input/output/cache_read/cache_creation_tokens`; Codex: `codex.turn.token_usage.*`); `session.id` → `langfuse.session.id`.
- **Custo exibido para Claude/Codex = preço de lista da API**, não gasto real (os dois rodam por assinatura).
- **Ruído do Codex:** o Langfuse recebe só uma allowlist de spans do Codex; tudo continua no bucket.

## Pendências menores
- Custo das chamadas do próprio Jev (Decisions API) não entra no span.
- Limite de eventos do plano Hobby do Langfuse: acompanhar.
- Nova versão do Claude Code/Codex pode renomear atributos: reconferir tokens e `service.name` (mapa do `oute.agent`) depois de upgrade.
- Tags do Langfuse (`langfuse.trace.tags`) por agente: não aplicado (o agente vai em metadata); reavaliar se o filtro por metadata não bastar.

## Lições
- `pi -p` via `ssh host cmd` trava esperando stdin → o `oute ssh` aloca `-t` quando há terminal.
- Com preset do OpenRouter, o proxy não conhece modelo/custo: o custo tem que vir do provedor de roteamento.
- Task asyncio em background precisa de referência forte (set) para não ser coletada.
- O Langfuse só soma uso em `gen_ai.usage.*` / `langfuse.observation.usage_details`.
- Para descobrir nomes reais de atributo: baixar os lotes do bucket e rodar `jq` em `.resourceSpans[].scopeSpans[].spans[]`.
- Validar config do collector antes de subir: `otelcol-contrib validate --config=collector.yaml --config=langfuse.yaml` (com as envs exportadas); `print-config` mostra a expansão de `${env:…}` dentro de strings.

## Riscos / verificar
- Nomes de atributos de conteúdo do Claude Code/Codex variam; a allowlist protege por padrão.
- `langfuse.environment` precisa casar `^(?!langfuse)[a-z0-9-_]+$` (até 40): o `slug` do `oute` garante; não usar nome de máquina começando com `langfuse`.
