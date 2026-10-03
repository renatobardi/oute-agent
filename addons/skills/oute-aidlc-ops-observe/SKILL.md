---
name: oute-aidlc-ops-observe
description: Lê a telemetria do ADR-04 e do ADR-08 (o agent-studio, pela API de uso e de alertas, e o bucket oute-observability), em modo só leitura, e resume saúde, custo e anomalias por agente e por host, incluindo agente ou host sem telemetria. Use quando pedirem um resumo de uso, custo ou saúde dos agentes, "o que está gastando", "a telemetria está chegando?", ou para conferir a observabilidade depois de um deploy ou upgrade de agente.
---

# oute-aidlc-ops-observe

Fase: `ops` (AI-DLC, ADR-07) · Outcome: resumo de saúde, custo e anomalias por host × agente, com evidência · Gate: Bardi decide o que vira issue.

Você **lê** a telemetria; não muda nada. Nada é escrito no agent-studio nem no bucket (o bucket nunca é apagado, ADR-04), nem em `config/otel` ou `config/agent-studio`. Achado vira proposta de issue, não correção.

## Regras

- **Só leitura, só metadados.** O bucket e o agent-studio guardam conteúdo (prompts, respostas, comandos, `user.email`). Do agent-studio, leia só os agregados do `GET /v1/usage` e do `GET /v1/alerts`, pelo script; não abra a tela nem outra rota. Do bucket, leia só nomes, contagens, datas, tamanhos e as chaves da allowlist do `observe.sh`. Nunca imprima, cite nem copie um valor de conteúdo; não rode `jq` livre sobre os lotes. Precisou de um campo novo: acrescente a chave à allowlist do script, num PR.
- **Segredos só pelo ambiente.** agent-studio: `AGENT_STUDIO_READ_TOKEN`, a **credencial de leitura** (só `GET`), com o endereço em `AGENT_STUDIO_URL` (rede docker no oute-server, vhost da tailnet no Mac; o compose passa). A credencial de ingestão nunca chega ao `agent`: não a procure. Bucket: o remote `oci` do rclone (`RCLONE_CONFIG_OCI_*`), que o entrypoint monta a partir do item `oci-storage`. Não escreva chave em arquivo, comando, issue ou relatório; não passe credencial no argv (o script manda a do agent-studio pelo stdin do `curl`).
- **Faltou credencial no container:** diga qual variável falta e pare naquela fonte (a outra ainda vale). Não procure a credencial em outro lugar. O host (`ssh oute-server`, como `oute-ops`) só serve para leitura; se precisar de algo lá com o usuário dele ou com sudo, é pelo **canal de aprovação** (`oute-propose` → `oute-inbox --wait <id>`), só diagnóstico.

## Passos

1. **Rodar o script** (na pasta desta skill; `--help` mostra as opções):
   ```bash
   "$HOME/.claude/skills/oute-aidlc-ops-observe/observe.sh" all            # Claude
   "$HOME/.agents/skills/oute-aidlc-ops-observe/observe.sh" all            # Codex
   ```
   Padrões: janela de 24 h (`--hours`), base de 7 dias antes dela (`--baseline-days`, `0` = sem base) e metadados das últimas 6 h do bucket (`--content-hours`, `0` = só listagem). `studio` ou `bucket` no lugar de `all` roda uma fonte só. Código ≠ 0 = uma fonte não pôde ser lida: a linha `ERRO` diz qual e por quê (variável ausente, `HTTP 401` = credencial errada, `HTTP 500` ou falha de conexão = agent-studio fora do ar ou inalcançável deste host).
2. **Ler as seções.**
   - agent-studio, por host (`host.name`) × agente (`oute.agent`), pela hora do fato: chamadas ao modelo, spans, erros de span e de log, **custo real** e **custo estimado** em colunas separadas (nunca some as duas num número só sem dizer), chamadas sem preço, tokens, latência p95 (a maior entre os modelos do grupo) e custo médio por dia da base. Depois, custo por modelo.
   - alertas do pipeline (`ALERTA`, os do `GET /v1/alerts` agora: `queue`, `destination_refusing`, `host_no_data`, `spool`, `quota`) e o último dado de cada host no agent-studio. `AVISO config` = entrada inválida no `config/agent-studio/config.toml`.
   - Bucket: último lote por sinal (`traces`, `logs`, `metrics`) × host × instância, com idade e volume na janela; depois, por host × agente (`oute.agent`), spans, spans com erro, logs, logs de erro e custo (`cost_usd` do `api_request` do Claude).
3. **Tratar cada `ANOMALIA`** (o script marca; você confirma):

   | Marca | O que significa | Confira antes de reportar |
   |---|---|---|
   | `sem-telemetria` | havia chamada ou span na base do agent-studio (ou é um sinal do bucket) e nada na janela | host desligado ou agente ocioso? Compare com a outra fonte e com a atividade conhecida (swarm, sessões). Só é falha se houve uso. |
   | `sinal-faltando` | o host mandou algum sinal, mas não os três | Codex não emite `metrics` (ADR-04); Claude sem traces: confira `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA` e `OTEL_TRACES_EXPORTER` no ambiente do agente daquele host (`docker/compose.yaml`) e a versão da imagem. |
   | `agente-sem-telemetria` | agente em `OUTE_AGENTS` deste host sem registro no bucket nas horas lidas | ocioso é normal; se houve uso, é falha. |
   | `sem-oute.agent` | registro sem `oute.agent` | `service.name` novo, fora do `transform/agent` (regra do ADR-04 para agente novo e upgrade). |
   | `erro-alto` | > 5 % de erro (mín. 5): no agent-studio, spans com status de erro sobre todos os spans do host × agente; no bucket, logs de erro sobre os logs | o script só conta; não abra o texto do erro (é conteúdo). Causa → `oute-aidlc-ops-diagnose`. |
   | `custo-alto` | custo **por dia** da janela (real + estimado, ÷ dias da janela = `--hours` ÷ 24) > 3 × a média diária da base (custo da base ÷ dias da base com dado), com mais de US$ 1 na janela. Janela menor que 24 h conta como um dia (o custo dela não é extrapolado). Só com uso na base: sem histórico, leia as colunas de custo | rodada de swarm, modelo mais caro, loop? Veja o custo por modelo. A linha traz o total da janela, o custo por dia e a base por dia. Pico de um dia se dilui em janela longa: na dúvida, rode de novo com `--hours 24`. |
   | `sem-preço` | chamadas sem custo real e sem preço na tabela: ficam fora das duas somas de custo | o modelo citado falta em `config/agent-studio/config.toml` (ou é span sem modelo). Proponha a issue para acrescentar o preço, com a fonte; não edite a tabela. |

   Cada `ALERTA` também entra no relatório, com o host, o valor, o limite e desde quando. `host_no_data` só existe para host sempre ligado (o oute-server); o Mac fechado não alerta.

   Sem marca não quer dizer tudo bem: confira também host que sumiu (só na base ou parado há muito no "último dado por host"), p95 fora do normal, as duas fontes discordando sobre o mesmo host × agente e `(legado)` (lotes do bucket anteriores à 0.7.5, sem `host=`; não é anomalia).
4. **Relatório** na conversa, curto:
   - janela e fontes lidas (e as que falharam, com o motivo);
   - tabela por host × agente: uso, erros, custo real e estimado;
   - alertas do pipeline ativos;
   - anomalias confirmadas, cada uma com a evidência (linha do script, número) e uma hipótese;
   - o que descartou e por quê (ex.: host desligado).
   Use o vocabulário do ADR-04 e do `CONTEXT.md`: **origem** = máquina + instância, agente = `oute.agent`.
5. **Propor issues**, numeradas, uma por problema confirmado (label `observabilidade` e `aidlc:<fase>`; `aidlc:ops` se a correção for operar, `aidlc:spec` se for mudar algo). Só abra a issue com o ok do Bardi. Correção no collector, no compose, no agent-studio ou no host não é desta skill.

## Lembretes de leitura

- **Custo de Claude e Codex é preço de lista da API**, não gasto: os dois rodam por assinatura (ADR-04). **Real** = o valor que veio na chamada (o Claude Code manda no log `api_request`); **estimado** = tokens × a tabela de `config/agent-studio/config.toml` (o Codex inteiro, e o Claude sem o log). `-` na coluna = nenhuma chamada daquele tipo, não zero.
- `oute.agent=pi` e `oute.agent=router` só aparecem em registro até 2026-09-30 (#217, #218): não são agentes esperados, e o script não marca a falta deles.
- O agent-studio agrega pela **hora do fato**, em UTC, e guarda tudo (sem limite de dias); o bucket é o arquivo frio e o backup. O bucket grava em lotes de 5 min por host; sem atividade não há lote. Idade grande sozinha não é falha.
- As duas fontes contam coisas diferentes: o agent-studio conta chamadas ao modelo e spans de todos os hosts; a seção de metadados do bucket lê só as últimas horas (`--content-hours`). Diferença de volume entre elas não é anomalia; host × agente presente numa e ausente na outra, na mesma hora, é.
