---
name: oute-aidlc-ops-observe
description: Lê a telemetria do ADR-04 (Langfuse, só metadados, e o bucket oute-observability), em modo só leitura, e resume saúde, custo e anomalias por agente e por host, incluindo agente ou host sem telemetria. Use quando pedirem um resumo de uso, custo ou saúde dos agentes, "o que está gastando", "a telemetria está chegando?", ou para conferir a observabilidade depois de um deploy ou upgrade de agente.
---

# oute-aidlc-ops-observe

Fase: `ops` (AI-DLC, ADR-07) · Outcome: resumo de saúde, custo e anomalias por host × agente, com evidência · Gate: Bardi decide o que vira issue.

Você **lê** a telemetria; não muda nada. Nada é escrito no Langfuse nem no bucket (o bucket nunca é apagado, ADR-04), nem em `config/otel`. Achado vira proposta de issue, não correção.

## Regras

- **Só leitura, só metadados.** O bucket guarda conteúdo (prompts, respostas, comandos, `user.email`). Leia dele só nomes, contagens, datas, tamanhos e as chaves da allowlist do `observe.sh`. Nunca imprima, cite nem copie um valor de conteúdo; não rode `jq` livre sobre os lotes. Precisou de um campo novo: acrescente a chave à allowlist do script, num PR.
- **Segredos só pelo ambiente.** Langfuse: `LANGFUSE_PUBLIC_KEY`/`LANGFUSE_SECRET_KEY` (e `LANGFUSE_HOST`, padrão `https://cloud.langfuse.com`). Bucket: o remote `oci` do rclone (`RCLONE_CONFIG_OCI_*`), que o entrypoint monta a partir do item `oci-storage`. Não escreva chave em arquivo, comando, issue ou relatório; não passe credencial no argv (o script manda a do Langfuse pelo stdin do `curl`).
- **Faltou credencial no container:** diga qual variável falta e pare naquela fonte (a outra ainda vale). Não procure a credencial em outro lugar. O host (`ssh oute-server`, como `oute-ops`) só serve para leitura; se precisar de algo lá com o usuário dele ou com sudo, é pelo **canal de aprovação** (`oute-propose` → `oute-inbox --wait <id>`), só diagnóstico.
- **Langfuse:** a API legada (`/api/public/traces`, `/api/public/metrics/daily`) responde **410** para a nossa organização. Use `GET /api/public/v2/metrics?query=<json>` (view `observations`), como o script faz.

## Passos

1. **Rodar o script** (na pasta desta skill; `--help` mostra as opções):
   ```bash
   "$HOME/.claude/skills/oute-aidlc-ops-observe/observe.sh" all            # Claude
   "$HOME/.agents/skills/oute-aidlc-ops-observe/observe.sh" all            # Codex e Pi
   ```
   Padrões: janela de 24 h (`--hours`), base de 7 dias antes dela (`--baseline-days`) e metadados das últimas 6 h do bucket (`--content-hours`, `0` = só listagem). `langfuse` ou `bucket` no lugar de `all` roda uma fonte só. Código ≠ 0 = uma fonte não pôde ser lida: a linha `ERRO` diz qual e por quê.
2. **Ler as seções.**
   - Langfuse, por `host` (= `environment`) × agente (`metadata.agent`): observações, erros (`level=ERROR`), custo, tokens, latência p95 e custo médio por dia da base. Depois, custo por modelo.
   - Bucket: último lote por sinal (`traces`, `logs`, `metrics`) × host × instância, com idade e volume na janela; depois, por host × agente (`oute.agent`), spans, spans com erro, logs, logs de erro e custo (`oute.cost_usd` do `jev.decision` + `cost_usd` do `api_request` do Claude).
3. **Tratar cada `ANOMALIA`** (o script marca; você confirma):

   | Marca | O que significa | Confira antes de reportar |
   |---|---|---|
   | `sem-telemetria` | havia dado na base (ou é um sinal do bucket) e nada na janela | host desligado ou agente ocioso? Compare com a outra fonte e com a atividade conhecida (swarm, sessões). Só é falha se houve uso. |
   | `sinal-faltando` | o host mandou algum sinal, mas não os três | Codex não emite `metrics` (ADR-04); Claude sem traces: confira `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA` e `OTEL_TRACES_EXPORTER` no ambiente do agente daquele host (`docker/compose.yaml`) e a versão da imagem. |
   | `agente-sem-telemetria` | agente em `OUTE_AGENTS` deste host sem registro no bucket nas horas lidas | ocioso é normal; se houve uso, é falha (Pi aparece só via router: `jev.decision` com `oute.agent=pi`). |
   | `sem-oute.agent` | registro sem `oute.agent` | `service.name` novo, fora do `transform/agent` (regra do ADR-04 para agente novo e upgrade). |
   | `agente-unknown` | cliente do router sem o header `X-Oute-Agent` | qual cliente chama o router sem o header. |
   | `erro-alto` | > 5 % de erro (mín. 5) | o tipo de erro vem do Langfuse (nome da observação, `statusMessage`) sem abrir conteúdo; causa → `oute-aidlc-ops-diagnose`. |
   | `custo-alto` | custo da janela > 3 × a média diária da base e > US$ 1 (só com uso na base: sem histórico, leia a coluna de custo) | rodada de swarm, modelo mais caro, loop? Veja o custo por modelo. |

   Sem marca não quer dizer tudo bem: confira também host que sumiu (só na base), p95 fora do normal e `(legado)` (lotes anteriores à 0.7.5, sem `host=`; não é anomalia).
4. **Relatório** na conversa, curto:
   - janela e fontes lidas (e as que falharam, com o motivo);
   - tabela por host × agente: uso, erros, custo;
   - anomalias confirmadas, cada uma com a evidência (linha do script, número) e uma hipótese;
   - o que descartou e por quê (ex.: host desligado).
   Use o vocabulário do ADR-04: **origem** = máquina + instância, agente = `oute.agent`.
5. **Propor issues**, numeradas, uma por problema confirmado (label `observabilidade` e `aidlc:<fase>`; `aidlc:ops` se a correção for operar, `aidlc:spec` se for mudar algo). Só abra a issue com o ok do Bardi. Correção no collector, no compose ou no host não é desta skill.

## Lembretes de leitura

- **Custo de Claude e Codex é preço de lista da API**, não gasto real: os dois rodam por assinatura (ADR-04). Gasto real é o do router (OpenRouter: Pi e clientes do jev-router).
- O bucket grava em lotes de 5 min por host; sem atividade não há lote. Idade grande sozinha não é falha.
- O Langfuse só recebe traces (não logs nem metrics) e guarda 30 dias (plano Hobby, 50 mil unidades/mês: vale citar se o volume do mês estiver perto). Horário do bucket e do Langfuse em UTC.
- `environment` no Langfuse = `host.name`. `production` é o environment dos traces anteriores à 0.7.5: aparece na tabela e não gera anomalia.
