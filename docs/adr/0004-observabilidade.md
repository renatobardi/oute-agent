# ADR-04 — Observabilidade (issues #13, #19)

Status: **aceito · fases 1 e 2 validadas · Claude Code e Codex validados (0.5.4) · identificador do agente `oute.agent` (0.7.2) · origem máquina + instância (0.7.5)** · 2026-09-25 · várias instâncias por host descartado (#22, 2026-09-26) · adendo: eventos operacionais do swarm e do canal (#124, 2026-09-27; `oute-emit` e catálogo; spool #166; reconciliação da `inbox` #167) · sessões (#128) · métrica e evento de cota das assinaturas (#347) · endpoint e origem do `~/.oute_env` quando faltam no ambiente (#250, 2026-10-02) · roteador de modelos fora do stack (#218, 2026-10-02: ver **Histórico: roteador de modelos**) · **substituído em parte pelo ADR-08** (agent-studio, #151): as partes do Langfuse e a regra "sem spool" do adendo #124
Base: `estudos/observabilidade-rascunho.md` (fontes, destinos do Broadcast, opções de painel).

> **Substituído em parte pelo [ADR-08](0008-agent-studio.md)** (#151, 2026-09-29, aceito). O agent-studio (DuckDB + SurrealDB, só no oute-server) substitui o Langfuse como painel e lugar de consulta; o Langfuse foi **desligado em 2026-10-03** (#160), antecipando a semana em paralelo (decisão do Bardi; comparação de 2026-10-01 no ADR-08 §9). Tudo o que este ADR diz sobre o **Langfuse** (painel, allowlist de metadados, `langfuse.yaml`, limites do Hobby, regra "bucket + Langfuse") vale só até o desligamento e está marcado *(substituído: ADR-08)*. A regra de ferramenta nova passa a ser **bucket + agent-studio**. A regra **"sem spool"** do adendo #124 foi substituída pelo spool do `oute-emit` (#138, ADR-08 §2), já descrito abaixo. Origem, `oute.agent`, eventos operacionais, sessões, bucket e fila em disco continuam valendo.

## Decisões (Bardi, 2026-09-24)
- *(substituído: ADR-08, painel = agent-studio)* Painel: **híbrido com Langfuse Cloud (região EU, plano Hobby)**. O conteúdo completo fica só no bucket OCI (São Paulo); o Langfuse recebe **só metadados**. Não há região Langfuse na América do Sul; EU por governança (GDPR); a latência não importa (envio assíncrono em lote).
- **Guardar conteúdo** (prompts/respostas/tools) só no bucket `oute-observability` (compartment `oute-agent`, privado).
- **Retenção do bucket: nada é apagado** (Bardi, 2026-09-24: "não quero apagar nada do que salvamos"). Sem lifecycle de deleção. Se o volume crescer, a alavanca é tiering (Infrequent Access / Archive), nunca delete.
- Porta de entrada única: **OTel Collector** próprio; os destinos são detalhe trocável.
- ~~**Regra (Bardi): nenhuma ferramenta entra no stack se não mandar consumo neste padrão (bucket + Langfuse).**~~ *(substituído: ADR-08 §11)* A regra passa a ser **bucket + agent-studio**.

## Arquitetura
```
Claude Code (logs, métricas, traces) ─┐
Codex (logs, traces)                  ┴─ OTLP (rede docker "oute") ─> otel-collector ─┬─> OCI S3 oute-observability/otel/{traces,metrics,logs}/host=<máquina>/instance=<instância>/  [TUDO, gzip, lote 5 min, sem expiração]
                                             (transform/agent: oute.agent;              └─> Langfuse Cloud (traces)  [allowlist de metadados + allowlist de spans do Codex + uso + metadata.agent/host/instance; Environment = máquina]
                                              resource: host.name, oute.instance)
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
- O agente recebe `OTEL_RESOURCE_ATTRIBUTES`, e o collector reforça tudo com `resource` upsert.
- **Bucket:** `otel/<sinal>/host=<máquina>/instance=<instância>/year=…/hour=…/`. Os objetos anteriores à 0.7.5, sem `host=/instance=`, ficam onde estão (nada é movido nem apagado).
- **Langfuse:** a máquina vira `langfuse.environment` (seletor **Environment** nativo, no topo). Máquina e instância também vão em `metadata.host` e `metadata.instance`. No pipeline do Langfuse, o processor `resource` roda antes do `transform/metadata_only` para que o transform enxergue `host.name`.
- `oute version` mostra a origem.
- **Uma instância por máquina** (decisão 2026-09-26, #22 fechada): sem caso de uso para várias stacks no mesmo host; isolamento real = outro host/LXC; ai-memory por instância dividiria a memória e quebraria o handoff. O atributo `oute.instance` fica no formato (custo zero) para o caso de um dia reabrir com caso concreto.

## Identificador do agente — `oute.agent` (0.7.2, 2026-09-25)
| Agente | Como é identificado | Valor |
|---|---|---|
| Claude Code | collector: `service.name == claude-code` | `claude` |
| Codex | collector: `service.name` casa `^codex` (`codex_exec`, `codex_cli_rs`) | `codex` |

- **Onde aparece:**
  - Bucket: resource `oute.agent` em traces, logs e métricas, e `span.attributes["oute.agent"]` nos traces.
  - Langfuse: `metadata.agent` do trace (`langfuse.trace.metadata.agent`), filtrável; `oute.agent` também passa pela allowlist de resource.
- **Regra para agente novo:** falar OTel direto e acrescentar o `service.name` no `transform/agent`.
- **Valores só de histórico (até 2026-09-30):** `pi` (o Pi saiu na #217) e `router` (o roteador de modelos saiu na #218) deixaram de ser emitidos, e o collector não marca mais `router`. Ficam só nos registros anteriores do bucket (nunca apagados) e do agent-studio; leitor de histórico continua aceitando os dois, e o agent-studio segue somando o custo gravado (ADR-08). O `unknown` que o hook do roteador gravava para cliente sem header também saiu, mas o valor **continua valendo** nos eventos operacionais e nas sessões (`oute-emit`, `oute-task`: "na dúvida, `unknown`", #128). Como eram atribuídos: **Histórico: roteador de modelos**, no fim.

## Adendo 2026-09-27 — eventos operacionais: swarm e canal (#124)
Decisões do grilling de `arch` da #124 (Bardi). **Evento operacional** = fato de um primitivo (rodada do swarm, pedido do canal de aprovação) registrado como log OTel no bucket, com a origem de sempre e `oute.agent`. Não é consumo de modelo. Motivo: as rodadas (`~/.oute/swarm/<id>/`) e o canal (`~/outbox`, `~/inbox`) ficam no volume de cada host, e a `learn` de um host não enxerga o outro.
- **Conteúdo, exceção ao "bucket = tudo":** vai com conteúdo o que o agente escreveu (prompt da sessão, texto do `tell`, script do pedido), texto que já chega ao bucket pelas transcrições dos agentes. A **saída do script executado no host não vai**: seguem só `rc`, duração, tamanho da saída e aprovador. É o único dado que nasce fora do container, e o bucket nunca apaga (um segredo impresso sem querer não teria volta). É a mesma linha do Claude Code, que manda `tool_input` e só `tool_result_size_bytes`.
- **Sinal:** logs OTel, um registro por evento (`oute.swarm.*`, `oute.canal.*`), **só no bucket** (pipeline `logs/archive`); com o ADR-08, também no agent-studio (tabela `logs` e estado derivado no SurrealDB). O Langfuse não recebe: a regra "nenhuma ferramenta entra sem mandar consumo ao bucket + Langfuse" vale para **consumo de modelo**, e o consumo das sessões já vai pelos agentes. Um trace-resumo por rodada no Langfuse pode entrar depois sem mudar o formato.
- **Rodada:** espelha a linha do tempo inteira (abertura, `spawn` com o prompt, `tell`, eventos do `watch`, `close`, rodada fechada). Os eventos do `watch` são **observações** (`oute.swarm.watch.*`): a fonte primária de PR/CI continua sendo o GitHub, mas a hora em que o dispatcher viu mede a reação da rodada.
- **Quem emite:** um primitivo único, `oute-emit`, na imagem. O `oute-propose` emite o pedido proposto; o `oute approve` (host) emite a decisão chamando o `oute-emit` dentro do container (`docker exec`), porque o host não alcança o coletor (sem porta publicada). Com imagem antiga, sem `oute-emit`, o host pula em silêncio.
- **Falha:** best-effort, teto de 2 s por chamada, **com spool local e reenvio** (substitui o "sem spool" original deste adendo: #138, ADR-08 §2; #166, ver "Spool" abaixo): a telemetria nunca faz o primitivo falhar ou travar, e o evento não se perde quando o coletor está fora. A fonte local (`log` da rodada, `approve.log`) continua sendo a primária.
- **Histórico:** backfill único e idempotente por host, com a hora original do evento e `oute.backfill=true`. O bucket particiona pela **hora de chegada** (`hour=`): quem lê filtra pelo `timeUnixNano` do registro, não pelo caminho (vale também para o atraso do lote de 5 min).
- **`oute.agent` = quem causou o evento.** Valor novo **`human`** (o Bardi decidindo um pedido), emitido só por ferramenta do projeto, nunca pelo `transform/agent`. O agente de cada sessão vai em `oute.swarm.session.agent`; pedido sem agente declarado = `unknown`.
- **Sessões:** ver "Sessões (#128)" abaixo.
- Opções descartadas: conteúdo completo no bucket, inclusive a saída do host (vazamento irreversível); emitir no `oute-inbox` ao ler (pedido não lido some, leitura repetida duplica) ou por um vigia residente; traces por rodada (o span só sai quando a rodada fecha, e rodada que não fecha nunca apareceria); `oute.agent` fixo por ferramenta (`swarm`, `canal`), que mistura ferramenta com agente.

### Catálogo e interface do `oute-emit` (#124, implementação)
**Interface.** O `oute-emit` recebe só "aconteceu algo com X" e lê ele mesmo os artefatos locais; o mesmo leitor serve o caminho ao vivo e o backfill.
```
oute-emit canal <id>               fase atual do pedido: proposto (outbox/<id>.sh) ou decidido (inbox/<id>.out)
oute-emit swarm <rodada> <linha>   a linha que o oute-swarm acabou de gravar no log da rodada
oute-emit task <evento> <quem chamou> chave=valor…
                                   sessão do oute-task (#128): opened, reopened ou removed, com os campos passados
oute-emit backfill                 os mesmos leitores sobre o que é anterior ao corte; uma vez por host
oute-emit flush                    só reenvia o spool (#166; o entrypoint chama na subida)
oute-emit reconcile                decided de todo inbox/*.out ainda não enviado (#167; o entrypoint chama na subida)
```
- python3 stdlib; OTLP/HTTP JSON em `${OTEL_EXPORTER_OTLP_ENDPOINT}/v1/logs` (ou `OTEL_EXPORTER_OTLP_LOGS_ENDPOINT`). Resource: `OTEL_RESOURCE_ATTRIBUTES` (origem) + `service.name=oute` + `oute.agent`; o registro repete `oute.agent` e leva `event.name` (também no campo `eventName`). Escopo `oute-emit`.
- **Endpoint e origem fora do ambiente (#250):** o shell do Bash tool do Claude Code não herda as `OTEL_*` do processo do agente (o Codex relê o `~/.oute_env` no shell de login). Quando faltam ou estão vazias no ambiente, o `oute-emit` lê do `~/.oute_env` que o entrypoint grava (`declare -px`): `OTEL_EXPORTER_OTLP_ENDPOINT` e `OTEL_EXPORTER_OTLP_LOGS_ENDPOINT` (o endpoint, como par) e `OTEL_RESOURCE_ATTRIBUTES` (a origem). Variável com valor no ambiente vence, uma a uma: endpoint (qualquer um dos dois) no ambiente = nada de endpoint do arquivo; origem no ambiente = nada de origem do arquivo. O arquivo é só **lido**, nunca `source`, e só essas três chaves saem dele, cada uma só na forma `declare -x CHAVE="…"` (aspas duplas, com `\` antes de `"`, `$`, `` ` `` e do próprio `\`). Linha de uma delas fora dessa forma (inclusive `$'…'`) ou repetida = chave ausente; arquivo ausente, ilegível, acima de 1 MB ou fora de UTF-8 = nada dele. Vale para todo verbo (`canal`, `swarm`, `task`, `flush`, `reconcile`, `backfill`) e para o spool: o evento guardado leva a origem lida na hora, e o `flush` sem `OTEL_*` reenvia pelo endpoint do arquivo. Descartado: o `entrypoint.sh` repassar as variáveis por outro caminho (a #218 edita a mesma linha; o `oute-emit` resolve num lugar só).
- Teto de 2 s por chamada (reenvio do spool + POST do evento novo), sempre sai com 0, nunca escreve no stdout; erro só em stderr com `OUTE_EMIT_DEBUG=1`. Sem endpoint no ambiente **e** no `~/.oute_env` (#250), não faz nada.
- **Coletor:** sem mudança. O `transform/agent` só casa `service.name` `claude-code` e `^codex`, então o `oute.agent` de `service.name=oute` passa intacto; nenhum processor do `logs/archive` descarta registro; o pipeline do Langfuse só tem traces.
- **Chamadores:** `oute-swarm` (toda linha do log da rodada), `oute-propose` (depois do rename atômico) e `oute approve` no host (`docker exec oute-agent oute-emit canal <id>`, sem `-i`, depois de gravar o `.out` e o `approve.log`; saída e erro descartados, imagem antiga = ignora). "Fica pendente" não chama. `oute-task` (#128): na abertura, na reabertura e em cada worktree removida pelo `clean --yes`; é o único chamador que passa os campos em vez de deixar o `oute-emit` ler o artefato, porque no `removed` a worktree (e a marca dela) já não existe.
- **Log da rodada** (`~/.oute/swarm/<rodada>/log`): uma linha por fato, `<hora UTC> <tipo> …`: `abertura <rodada> (…)`, `spawn <slug> <agente>[ kaizen]`, `tell <slug> ok[ (--force, <estado>)| (--wait, <s>s)]` (o `--wait`, #181, espera a sessão parar sem gravar nada; só o resultado vira linha) ou `tell <slug> recusado: <motivo>`, com a mensagem depois de um TAB; `watch [<tipo>] <texto>`; `close <slug>`; `rodada fechada`. O `meta` ganha `agent=` (dispatcher; rodadas antigas sem ele = `claude`) e, na rodada aberta com `--agent` (#212), `workers=` (agente padrão das sessões; o `oute.swarm.session.agent` de cada `spawn` continua sendo o agente real da sessão).
- **Cabeçalho do `.out`** (host): além de `id`, `rc`, `como`, `aprovado`/`recusado`, `sha256`, o executado leva `# duracao: <s> s` e `# saida: <bytes> bytes`. O leitor para na primeira linha em branco: a saída nunca é lida.
- **Backfill:** o entrypoint grava `~/.oute/emit/since` na primeira subida da imagem com `oute-emit` (o corte). O backfill passa o log de cada rodada (e, nas rodadas antigas, `meta`, `spawned` e `fechada` reescritos como linhas do log, sem repetir o que o log já tem) e os pedidos (`outbox/`, `outbox/done/`, `outbox/rejected/`, `inbox/*.out`) pelos mesmos leitores, emite só o anterior ao corte, com a hora original e `oute.backfill=true`, e grava `~/.oute/emit/backfill.done`. Lotes de 200 registros, timeout de 10 s por lote; `backfill.sent` guarda quantos já foram aceitos, e uma nova execução retoma dali sem duplicar. Resumo em stderr: emitidos, linhas não reconhecidas (ex.: `tell-manual`, `tell` antigo sem resultado) e `close` sem hora (o `closed` antigo), pulados. `tell` antigo sai sem corpo.

| Evento | `oute.agent` | Atributos (além de `oute.event.id` e `oute.swarm.round`/`oute.canal.id`) | Corpo |
|---|---|---|---|
| `oute.swarm.round.opened` | dispatcher (`agent=` do `meta`) | `oute.swarm.repo` (nome), `oute.swarm.max`, `oute.swarm.label`, `oute.swarm.round.agent` (agente das sessões, `workers=` do `meta`; ausente na rodada aberta sem `--agent`, #212) | — |
| `oute.swarm.session.spawned` | dispatcher | `oute.swarm.session` (slug), `oute.swarm.issue`, `oute.swarm.session.agent`, `oute.swarm.repo`, `oute.swarm.kaizen` | prompt (`<slug>.prompt`) |
| `oute.swarm.tell` | dispatcher | `oute.swarm.session`, `oute.swarm.tell.result` (`ok`/`recusado`), `oute.swarm.tell.reason`, `oute.swarm.tell.forced` | mensagem |
| `oute.swarm.watch.<tipo>` (`pr`, `ci`, `conflito`, `canal`, `aba`, `sessao`, `aviso`, `rodada`) | dispatcher | `oute.swarm.source=watch` | a linha do evento |
| `oute.swarm.session.closed` | dispatcher | `oute.swarm.session` | — |
| `oute.swarm.round.closed` | dispatcher | — | — |
| `oute.canal.proposed` | `# agente:` do pedido (`desconhecido` → `unknown`) | `oute.canal.title`, `oute.canal.as` (`user`/`root`), `oute.canal.size` (bytes do script) | script (sem o cabeçalho) |
| `oute.task.opened`, `oute.task.reopened` | quem chamou o `oute-task` | `oute.task.id`, `oute.task.repo` (nome), `oute.task.slug`, `oute.task.agent` (`claude`/`codex`/`shell`), `oute.task.base` (branch padrão); em sessão de rodada, `oute.swarm.round` e, no worker, `oute.swarm.session`; no `reopened` que deu id a uma worktree antiga, `oute.task.legacy=true`; a escolha do seletor (ADR-02, #219): `oute.task.phase` (fase do AI-DLC; ausente quando nada deu a fase), `oute.task.origin` (`manual`/`label`/`jev`/`padrao`), `oute.task.model` (id exato), `oute.task.effort` (só no Codex) e `oute.task.confidence` (número de 0 a 1: a confiança do Jev, só quando ele respondeu, com origem `jev` ou, abaixo de 0,6, `padrao`; #257) | **nunca** |
| `oute.task.removed` | quem chamou o `oute-task clean --yes` | `oute.task.id` (ausente em worktree antiga nunca reaberta), `oute.task.repo`, `oute.task.slug`, `oute.task.base`, `oute.task.reason` (`merged`/`empty`/`detached`), `oute.swarm.round`/`oute.swarm.session` se a sessão era de rodada | **nunca** |
| `oute.quota.unknown` | o agente da assinatura lida (`claude`/`codex`) | `oute.quota.reason` (`sem-credencial`, `token-expirado`, `rede`, `timeout`, `http-<código>`, `formato`; texto fora desse padrão vira `formato`), `oute.quota.moment` (`spawn`/`close`/`open`) | **nunca** |
| `oute.canal.decided` | `human` | `oute.canal.decision` (`executado`/`recusado`), `oute.canal.rc`, `oute.canal.duration_s`, `oute.canal.output_bytes`, `oute.canal.approver` (`usuário@host`), `oute.canal.sha256` (12) | **nunca** |

**Métrica de cota das assinaturas (#347, spike #55).** O `oute-emit quota <spawn|close|open>` lê o `oute-quota --json` (ADR-02; teto de 8 s) e manda **métricas** OTLP, pela rota `/v1/metrics` do mesmo coletor (bucket e agent-studio), além do evento `oute.quota.unknown` acima. O `oute-swarm` chama no `spawn` e no `close` (só quando algo foi fechado) e o `oute-task` na abertura e reabertura (`open`), em **segundo plano e sem saída**: a leitura nunca atrasa nem derruba o comando, e `oute-quota` ou `oute-emit` ausente = nada. **Sem coleta periódica** (decisão do gate de 2026-10-02): o ponto é um instantâneo desses momentos.

| métrica | tipo, unidade | atributo do ponto | recurso |
|---|---|---|---|
| `oute.quota.used_pct` | gauge (double), `%`, 0–100 | `oute.quota.window` = `5h` \| `7d` | `oute.agent` = `claude` \| `codex` (a assinatura, não quem chamou), `host.name`, `oute.instance`, `service.name=oute` |
| `oute.quota.reset_in_seconds` | gauge (int), `s` | o mesmo | o mesmo |

- **Os dois pontos de uma janela têm a mesma hora**, e hora do ponto + `reset_in_seconds` = a hora do reset: o alerta de cota usa o par para saber até quando o ponto vale. Leitura de cache (`stale`) leva a hora da leitura (agora − `age_s`), com o reset contado a partir dela.
- **`unknown` não emite ponto** (zero seria mentira): vai o evento `oute.quota.unknown`. Janela com `used_pct` fora de 0–100 ou sem hora de reset é pulada.
- **Recurso:** só a origem do host e o agente; a marca de sessão (`oute.task.*`, `oute.swarm.*`) não entra, porque o instantâneo é do host.
- **Sem spool:** métrica que não chega (coletor fora, 4xx) se perde; o instantâneo seguinte a substitui. O evento `unknown` usa o spool como os demais. O endpoint de métricas deriva do de logs (`…/v1/logs` → `…/v1/metrics`); endpoint de logs fora desse padrão = sem métrica.
- **Alerta:** `quota` do agent-studio (ADR-08 §8), corte de 90% por janela.

Hora do registro (`timeUnixNano`) = a hora do fato (linha do log, `criado:`, `aprovado:`/`recusado:`); no backfill também leva `oute.backfill=true`. Leitor filtra por `timeUnixNano`, não por `hour=`. Agente do `oute-propose`: `OUTE_PROPOSE_AGENT`, senão `CLAUDECODE=1` → `claude`, `CODEX_THREAD_ID` → `codex`, `PI_CODING_AGENT=true` → `pi`, senão `unknown`.

**`oute.event.id` (#165): id fixo por fato**, em todo evento do `oute-emit`. É a chave de deduplicação da ingestão (repetição por timeout, spool, restart ou backfill leva o mesmo id). Regra: os 32 primeiros hex do `sha256` de `tipo do evento ␟ escopo ␟ hora do fato ␟ chave ␟ ocorrência` (`␟` = `\x1f`). Escopo = `swarm/<rodada>` ou `canal/<id do pedido>`. Hora do fato = o texto da hora (linha do log, `criado:`, `aprovado:`/`recusado:`; vazia se o cabeçalho não tem), **nunca** a hora de envio. Chave = o que distingue o fato dentro do escopo: `spawn` e `close` → slug; `tell` → o resto da linha depois da hora e do tipo (slug, resultado, motivo) + TAB + mensagem; `watch` → `[<tipo>] <texto>`; `decided` → decisão (`executado`/`recusado`); abertura, rodada fechada e `proposed` → vazia. A chave sai dos campos, não da linha crua: a linha que o backfill reescreve de `meta`/`spawned`/`fechada` leva o mesmo id da linha do ao vivo. Ocorrência = qual cópia da linha idêntica no log da rodada (1, 2, …): dois `tell` ou `watch` iguais no mesmo segundo são fatos distintos. Ao vivo, o `oute-emit swarm` conta as cópias da linha no log (o `oute-swarm` grava antes de chamar, então é a última); o backfill conta na ordem do log. Canal: ocorrência sempre 1 (o id do pedido já é único). Limite: duas linhas idênticas gravadas ao mesmo tempo por processos diferentes podem sair, ao vivo, com a mesma ocorrência; o backfill não sofre isso.

**Spool (#166): o evento não se perde com o coletor fora**, sem processo residente.
- **Guardar:** POST que falha (coletor fora, timeout, 5xx, 408, 429) grava o envio, como foi montado (resource, registros, `oute.event.id`, hora do fato), num arquivo em `~/.oute/emit/spool/<hora em ns>-<pid>.json`; gravação atômica (temporário + `fsync` + `rename`). Sai com 0 e sem stdout, como antes. Sem endpoint configurado (nem no ambiente, nem no `~/.oute_env`, #250) não há POST e nada vai ao spool. Recusa permanente (outro 4xx) não entra.
- **Reenviar:** toda chamada (`canal`, `swarm`, `backfill`, `flush`) tenta primeiro esvaziar o spool, do mais antigo ao mais novo, em lotes de ~1 MB, dentro do **mesmo teto de 2 s**; o evento novo usa o tempo que sobrar. Se o coletor falha no reenvio (ou o tempo acaba), o evento novo vai direto ao spool, sem nova tentativa. O entrypoint chama `oute-emit flush` em segundo plano na subida (até 12 tentativas, 5 s entre elas, para quando o spool esvazia): a subida não espera.
- **Reenvio = o arquivo como está.** Nunca recalcula o `oute.event.id` nem relê os artefatos: ao vivo, a ocorrência de uma linha idêntica vem da contagem no log da rodada (a última cópia), que muda depois; recalcular daria a uma cópia anterior o id de outra ocorrência e a ingestão não deduplicaria (auditoria do #168). Repetição (timeout depois de aceito, queda entre o POST e a remoção do arquivo) leva o mesmo id e a ingestão deduplica.
- **Concorrência:** trava não bloqueante (`flock` em `spool/.lock`). Quem não pega pula o reenvio e manda só o seu evento; duas chamadas simultâneas nunca reenviam o mesmo arquivo. Só quem tem a trava remove arquivo.
- **Limite:** 50 MB (soma dos arquivos). Cheio = o evento novo é descartado e `~/.oute/emit/spool.dropped` (contador acumulado, nunca zera) sobe 1; o fato segue nos artefatos locais. Arquivo ilegível ou recusado com 4xx sai do spool para `~/.oute/emit/spool.bad/` (não trava a fila, não se perde). Lote de vários arquivos recusado com 4xx é reenviado arquivo por arquivo: só vai para `spool.bad` o que for recusado de novo.
- **Aviso:** todo evento leva `oute.emit.spool.bytes` (tamanho do spool na hora do envio, depois do reenvio) e `oute.emit.spool.dropped` (o contador). O alerta é calculado pelo agent-studio (#150). Com `OUTE_EMIT_DEBUG=1`, uma linha em stderr ao guardar e ao descartar.

**Reconciliação da `inbox` (#167): decisão tomada com o container fora chega ao bucket**, sem spool no host (#138). O `oute approve` grava o `.out` mesmo quando o `docker exec oute-emit canal <id>` falha (container parado, imagem antiga); o `decided` desse pedido sai na próxima subida.
- **Registro:** `~/.oute/emit/decided/<id>`, um arquivo vazio por pedido cujo `oute.canal.decided` já foi **enviado**. Enviado = POST aceito **ou** envio guardado no spool (o spool é a única fila de reenvio). Não conta: sem endpoint (ambiente e `~/.oute_env`), spool cheio (descartado), recusa permanente (4xx). Quem marca: o caminho ao vivo (`oute-emit canal <id>` com `.out`, chamado pelo `oute approve`) e a reconciliação.
- **Subida:** o entrypoint chama `oute-emit reconcile` em segundo plano, antes do laço do `flush` (função `flush_spool`): todo `inbox/*.out` sem registro, com id válido, cabeçalho com `aprovado:`/`recusado:` e decisão **a partir do corte** (`~/.oute/emit/since`) sai como no ao vivo (mesmo leitor, mesma hora do fato, mesmo `oute.event.id`) e é marcado. Mesmo teto de 2 s e mesmas regras do spool: coletor fora = vai para o spool e marca; o laço do `flush` reenvia quando o coletor subir.
- **Corte:** `.out` com decisão anterior ao corte é do backfill, nunca da reconciliação; sem corte gravado, não reconcilia. Os dois são disjuntos pela hora do fato.
- **Saída do host:** o leitor para na primeira linha em branco do `.out`, como no ao vivo; a saída nunca é lida.
- **Duplicata:** a primeira subida depois da release reemite uma vez os `.out` posteriores ao corte que já tinham saído ao vivo antes de existir o registro, e uma corrida entre a subida e um `oute approve` pode mandar o mesmo `decided` duas vezes; nos dois casos o `oute.event.id` é o mesmo e a ingestão deduplica.
- Opções descartadas: spool no host (#138: o host não alcança o coletor e ficaria com um segundo spool); marcar só pelo POST aceito (o spool já garante a entrega, marcar depois obrigaria a reler o spool); registro num arquivo único de linhas (precisaria de trava entre o ao vivo e a subida).

### Sessões (#128, 2026-09-27)
Decisões do grilling de `arch` da #128 (Bardi). Uma **sessão** (worktree + branch do `oute-task`, de rodada ou avulsa) contém uma ou mais **conversas** (`session.id` do agente).
- **Ciclo de vida:** `oute.task.opened` (worktree criada), `oute.task.reopened`, `oute.task.removed` (pelo `clean --yes`, com o motivo: PR mergeado, sem commits, detached). O `oute-task` continua fazendo `exec` do agente, então não há evento de fim de conversa. A sessão mede o ciclo da **entrega**; o tempo de trabalho vem das conversas. Simulação do `clean` não emite. Sem corpo: o prompt já chega pela conversa ou pelo `oute.swarm.session.spawned`.
- **Toda sessão emite**, de rodada ou avulsa. Sessão avulsa = `oute.task.*` sem `oute.swarm.round`.
- **Identidade:** `oute.task.id` = `<repo>-<slug>-<AAAAMMDDhhmmss>` (UTC), gerado na criação da worktree e gravado no git-dir dela, como a marca `oute-swarm-worker`. O `reopened`, o `removed` e o shim, no restore do herdr, leem de lá. `repo + slug` não serve: o slug se repete depois do `clean`.
- **Vínculo com o consumo:** antes do `exec`, o `oute-task` acrescenta ao `OTEL_RESOURCE_ATTRIBUTES` `oute.task.id`, `oute.task.repo`, `oute.task.slug` e, em sessão de rodada, `oute.swarm.round`/`oute.swarm.session`. Toda conversa sai marcada. Vale para Claude Code e para Codex (conferido no `build`, ver "Implementação" abaixo). **Pi fica de fora** (a conversa passava pelo roteador de modelos, que não via o ambiente): #130. Só no bucket; o Langfuse segue a allowlist.
- **`oute.agent` = quem chamou**, pelo ambiente (marcador de sessão do agente, `OUTE_SWARM_*`). `human` só com terminal interativo e nenhum marcador; na dúvida, `unknown`. O agente da sessão vai em `oute.task.agent` (`claude|codex|shell`; `pi` até a #217).
- **Escolha do seletor (ADR-02, #219):** o `opened` e o `reopened` levam a fase, a origem da escolha, o agente que de fato abriu (`oute.task.agent`), o modelo e o esforço, sem evento novo. Como levam o `oute.task.id`, aparecem na página da sessão do agent-studio (`/sessao?id=`). O `shell` e a sessão aberta sem o `oute-select` saem sem esses atributos; o `removed` nunca os leva. A confiança do Jev (#257) vai em `oute.task.confidence`, como número, junto da origem `jev` (ou `padrao`, quando ficou abaixo de 0,6); o texto da tarefa e a chave da TypeSafe nunca entram no evento. O motivo da reserva entra com a fatia dele (#258).
- **Sem backfill:** as sessões passadas já estão no GitHub (branch, PR). Worktree anterior à release ganha id na próxima reabertura, com `oute.task.legacy=true`; se só for removida, o `removed` sai sem `oute.task.id`.
- Opções descartadas: fim de sessão por processo que espera o agente (muda o primitivo e o restore do herdr o contorna) ou por hook de fim do harness (o Pi não tem); emitir só nas avulsas (a remoção das worktrees de rodada ficaria sem registro); id pelo branch (renomeado no meio da sessão, sem o `oute-task` saber); backfill com hora aproximada (dado errado com cara de certo); `oute.agent` = agente da sessão (quebra a regra "quem causou").

#### Implementação (#128, `build`, 2026-10-02)
- **Marca da sessão:** arquivo `<git-dir da worktree>/oute-task`, uma chave por linha: `id`, `repo`, `slug`, em sessão de rodada, `round` e `session`, e a escolha do seletor (#219): `agent`, `model` e `effort`. O `oute-task` grava na criação da worktree (ou na primeira reabertura de uma worktree antiga) e ela some com a worktree. Se a gravação falha, sai um aviso em stderr e a sessão abre sem id: evento sem `oute.task.id`, conversa sem marca.
- **Eventos:** `oute-emit task <opened|reopened|removed> <quem chamou> chave=valor…` (catálogo acima), sem corpo. Hora do fato = a da chamada. `oute.event.id`: escopo `task/<oute.task.id>` (sem id, `task/<repo>-<slug>`) e chave = o motivo; o mesmo fato repetido no mesmo segundo é um evento só. O resource leva só a origem: a marca de sessão que esteja no ambiente de quem chamou é de outra sessão e não entra.
- **`removed`:** emitido depois que o `git worktree remove` deu certo, com o id lido antes. Motivos: `merged` (PR mergeado), `empty` (sem commits além de `origin/<base>`), `detached` (HEAD detached contida em `origin/<base>`). Não leva `oute.task.agent` (o agente é o das aberturas). Worktree removida por fora do `oute-task clean` não emite.
- **Rodada:** no dispatcher, `OUTE_SWARM_ID`; no worker, o `oute-swarm spawn` passa `OUTE_SWARM_ROUND=<rodada>` ao `oute-task`, que usa o slug como `oute.swarm.session`. `spawn` fora de rodada (`avulso`) abre sessão avulsa. Com a rodada no ambiente, vale ela (e a marca é atualizada); sem ambiente (reabertura na mão, restore), vale a que a marca guardou.
- **Marca nas conversas:** antes do `exec` (também no `shell`), `OTEL_RESOURCE_ATTRIBUTES` = o valor atual sem `oute.task.*`/`oute.swarm.*` + `oute.task.id`, `oute.task.repo`, `oute.task.slug` e, em sessão de rodada, `oute.swarm.round`/`oute.swarm.session`. Valores só com `[A-Za-z0-9._-]` (o resto vira `-`).
- **Shim:** toda chamada de `claude`/`codex` de dentro de uma worktree com id refaz a mesma marca (`oute-task --mark`): restore do herdr, `--resume`, `-c`, `-p`. Worktree sem id, checkout principal e fora de repo: sem marca.
- **`oute.agent` (quem chamou), nesta ordem:** `CLAUDECODE=1` → `claude`; `CODEX_THREAD_ID` → `codex`; ambiente do swarm (`OUTE_SWARM_ID`, `OUTE_SWARM_ROUND` ou `OUTE_SWARM_WORKER`) → o agente do dispatcher (`agent=` do `meta` da rodada; sem ele, `claude`); stdin e stdout em terminal → `human`; senão `unknown`.
- **Codex conferido (0.159.2):** um `codex exec` com o exporter OTLP apontado para um receptor local e a marca no ambiente mandou logs e traces com `oute.task.id`, `oute.task.repo` e `oute.task.slug` no resource. Sem lacuna. O marcador de sessão do Codex é `CODEX_THREAD_ID`. A conferência no bucket é a do pós-deploy.
- **Falha:** nada disto muda saída, `exec` ou código do `oute-task`. Sem `oute-emit` na imagem não há evento, mas a marca nas conversas continua. Coletor fora: o evento vai ao spool. Coletor que não responde: até 2 s (teto do `oute-emit`) antes do `exec`.
- **Agente Claude (#250):** o shell do Bash tool do Claude Code não herda as `OTEL_*`; o `oute-emit` lê endpoint e origem do `~/.oute_env` (ver a interface do adendo #124), e o `oute-task` chamado por um agente Claude (o `clean --yes` do fim da rodada) emite como os demais. A marca nas conversas não depende disso.

## Onde cada coisa fica / limites
| Local | Conteúdo | Limite |
|---|---|---|
| Bucket OCI `oute-observability` | tudo (com conteúdo), gzip | free tier 20 GB (todas as camadas somadas); acima ~US$ 0,026/GB·mês; budget US$ 1 com alerta. Sem expiração. |
| Langfuse Cloud Hobby *(substituído: ADR-08)* | só metadados | 50k unidades/mês (trace+observação+score), 30 dias de histórico. 1 interação simples ≈ 14 unidades. |
| Disco de cada host (oute-server e Mac) | fila em disco do collector no volume `oute-otel-queue` (reserva de 4 GB, abaixo); os agentes guardam transcrições no volume home (`~/.claude/projects`, `~/.codex/sessions`); SQLite do ai-memory; logs stdout dos containers | disco de 44 GB, que é o limite real a vigiar. |

**Reserva de disco da fila do collector (#163, decisão do Bardi no #137).** Cada host reserva **4 GB** de disco para a fila: **2 GB de disco por fila de 1 GB** (o arquivo bbolt chega a ~1,7× o limite da fila e não encolhe), com duas filas, a do bucket (#161) e a da ingestão do agent-studio (#155). O `oute up` avisa, sem bloquear a subida, quando o disco livre não comporta os 4 GB descontado o que o volume já ocupa; o `oute status` mostra o tamanho do volume junto da linha de disco. A medida é feita de dentro de um container, porque no Mac o disco que conta é o da VM do Docker Desktop.

## Fase 1 (concluída)
- `otel-collector`: `otel/opentelemetry-collector-contrib:0.161.0` (`OUTE_OTELCOL_VERSION`), sem porta publicada. `config/otel/collector.yaml` (bucket) + `agent-studio.yaml` ou `none.yaml` (2º `--config`; o `langfuse.yaml` saiu em 2026-10-03, #160). Config montada do repo: mudança no pipeline = `git pull` + `oute down/up`, sem release.
- Bucket: exporter `awss3` no endpoint S3-compat da OCI. Partição `host=/instance=/year=/month=/day=/hour=` UTC, `otlp_json` + gzip, lote 5 min. **Exige `AWS_REQUEST_CHECKSUM_CALCULATION=when_required` e `AWS_RESPONSE_CHECKSUM_VALIDATION=when_required`** (senão a OCI responde 501 e o lote é descartado).
- *(substituído: ADR-08)* Langfuse: `otlphttp` → `${LANGFUSE_HOST}/api/public/otel`, Basic auth, `x-langfuse-ingestion-version: 4`. Filter: span events fora (exceto Codex). Transform: **allowlist** (`keep_matching_keys`). O `status.message` do span sai vazio e o `status.code` fica (#149, 2026-10-02): o Langfuse lê dele o `statusMessage` (texto do erro da ferramenta, com caminhos locais), por fora da allowlist de atributos; o `level=ERROR` vem do código. O texto continua no bucket e no agent-studio. Teste: `tests/otelcol-langfuse.test.sh`.

## Fase 2
Era o custo real do roteador de modelos; saiu com ele (#218). Ver **Histórico: roteador de modelos**.

## Claude Code e Codex (#5/#19 — validado 2026-09-24, v0.5.4)
| | logs | metrics | traces | ai-memory |
|---|---|---|---|---|
| Claude Code (`claude-code`) | ✓ | ✓ | ✓ | ✓ |
| Codex (`codex_exec`, `codex_cli_rs`) | ✓ | — | ✓ | ✓ (hooks reaprovados na 0.5.8) |

- **Privacidade conferida:** Input/Output vazios no Langfuse; `user.email`, `organization.id`, `user.account_uuid` do Claude barrados pela allowlist; `statusMessage` vazio (#149).
- **Uso/tokens** mapeados para `gen_ai.usage.*` (Claude: `input/output/cache_read/cache_creation_tokens`; Codex: `codex.turn.token_usage.*`); `session.id` → `langfuse.session.id`.
- **Custo exibido para Claude/Codex = preço de lista da API**, não gasto real (os dois rodam por assinatura).
- **Ruído do Codex:** o Langfuse recebe só uma allowlist de spans do Codex; tudo continua no bucket.

## Pendências menores
- *(substituído: ADR-08)* Limite de eventos do plano Hobby do Langfuse: acompanhar.
- Nova versão do Claude Code/Codex pode renomear atributos: reconferir tokens e `service.name` (mapa do `oute.agent`) depois de upgrade.
- *(substituído: ADR-08)* Tags do Langfuse (`langfuse.trace.tags`) por agente: não aplicado (o agente vai em metadata); reavaliar se o filtro por metadata não bastar.

## Lições
- `pi -p` via `ssh host cmd` trava esperando stdin → o `oute ssh` aloca `-t` quando há terminal.
- Task asyncio em background precisa de referência forte (set) para não ser coletada.
- O Langfuse só soma uso em `gen_ai.usage.*` / `langfuse.observation.usage_details`.
- Para descobrir nomes reais de atributo: baixar os lotes do bucket e rodar `jq` em `.resourceSpans[].scopeSpans[].spans[]`.
- Validar config do collector antes de subir: `otelcol-contrib validate --config=collector.yaml --config=agent-studio.yaml` (com as envs exportadas); `print-config` mostra a expansão de `${env:…}` dentro de strings.

## Riscos / verificar
- Nomes de atributos de conteúdo do Claude Code/Codex variam; a allowlist protege por padrão.
- *(substituído: ADR-08)* `langfuse.environment` precisa casar `^(?!langfuse)[a-z0-9-_]+$` (até 40): o `slug` do `oute` garante; não usar nome de máquina começando com `langfuse`.

## Histórico: roteador de modelos (2026-09-23 a 2026-09-30)
O jev-router (LiteLLM + hook do Jev, na frente do OpenRouter) saiu do stack na #218 (ADR-02, Histórico). **Nada do que ele gravou foi apagado**: os registros seguem no bucket e no agent-studio, que continua lendo `jev.decision` e `oute.agent=router` para o custo passado não sumir do `/v1/usage` (ADR-08). O collector deixou de marcar `oute.agent=router`, porque não há mais quem emita. O que valia enquanto ele existiu:

- **Decisões (Bardi, 2026-09-24):**
  - Fonte da verdade de modelo real, provedor e custo = OpenRouter. O LiteLLM só enxergava o preset.
  - Fase 2 = pull via API, não Broadcast: o hook consultava `GET /api/v1/generation?id=gen-…` e enriquecia o `jev.decision`.
- **Arquitetura:** o jev-router mandava ao collector os spans do LiteLLM (callback `otel`) e um span próprio, o `jev.decision` (trace `jev:<perfil>` no Langfuse), pela mesma entrada OTLP dos agentes.
- **`oute.agent`:**

  | Agente | Como era identificado | Valor |
  |---|---|---|
  | Cliente do jev-router | header **`X-Oute-Agent`** na request ao router; o hook gravava no span `jev.decision` | o valor do header (`pi`) |
  | Cliente do router sem header | o hook | `unknown` (valor sanitizado: `[a-z0-9_-]`, até 32 caracteres) |
  | Demais spans do jev-router (LiteLLM) | collector: `service.name == jev-router` | `router` |

  - O valor do span tinha precedência sobre o do resource. Agente novo que passasse pelo jev-router mandava o header.
  - Log do router: `served agent=<cliente> profile=… model=… cost=…`. Validado (0.7.2): `served agent=pi profile=cheap via=jev model=openai/gpt-oss-20b provider=DeepInfra cost=0.00037435`.
  - O Pi (#217) era o único cliente, identificado pelo header que o entrypoint gravava na config dele.
- **Fase 2 (validada):** no sucesso, o hook agendava em background `GET /api/v1/generation?id=gen-…` (retries 2/4/8/16 s) e emitia o `jev.decision` com modelo servido, provedor, custo US$, tokens nativos, `finish_reason`, latências e o `oute.agent`.
- **Langfuse:** os spans internos do LiteLLM ficavam fora do painel (seguiam no bucket).
- **Pendência que ficou:** o custo das chamadas do próprio Jev (Decisions API) não entrava no span.
- **Lições:** logo depois do `oute up`, o LiteLLM levava ~15–30 s para aceitar conexões (o Pi devolvia `Connection error.` nesse intervalo). Com preset do OpenRouter, o proxy não conhece modelo nem custo: o custo tem que vir do provedor de roteamento.
