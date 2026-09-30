# ADR-08 — agent-studio: telemetria sem perda num banco próprio (substitui o Langfuse)

Status: **aceito** (2026-09-29, #151; gate de `arch` do Bardi). Substitui, no ADR-04, as partes do **Langfuse** e a regra **"sem spool"** do adendo #124. O ADR-01 não muda.
Base: mapa #135 e as decisões #136 (pipeline sem perda), #137 (medir o collector), #138 (spool do `oute-emit`), #139 (fatos de SurrealDB e DuckDB), #140 (divisão e ingestão), #141 (topologia), #142 (papel do bucket), #143 (inventário do Langfuse), #144 (escopo do v1 e troca), #145 (tray), #146 (watch), #150 (stack). Nota de pesquisa: #135, comentário "Nota de pesquisa completa" (§5.1 = respostas do Bardi).

## Contexto
- O Langfuse Cloud (Hobby) mostra só 30 dias, recebe só metadados (allowlist) e só traces. O único consumidor por API é a `ops-observe` (Metrics API v2, 100 req/dia); o resto é o Bardi na UI (tracing, environment, A/B do Jev, sessions). O custo do Claude e do Codex é inferido pela tabela de preços dele (#143).
- O pedido do Bardi (§5.1): guardar **tudo, com conteúdo**, consultável; nenhum dado perdido; o dado no banco em 1 a 2 min; um tray no Mac que mostre todas as máquinas. Sem broker (RabbitMQ): o buffer em disco por host cobre o caso.
- Pontos de perda medidos no pipeline antigo (#135 §2.2, #137): lote de 5 min em memória, fila de envio só em memória, retry que desiste em 5 min, fila cheia que descarta, SDK das fontes sem persistência, `oute-emit` sem spool.
- O volume é pequeno: ~14 MiB (gzip) no bucket em 4 dias, os dois hosts somados.

## Decisões

### 1. Garantia "sem perda" (#136, #137)
**Todo registro que o collector aceitou (OTLP 2xx) chega a todos os destinos, pelo menos uma vez.**
- **Fronteira:** a garantia começa no collector. O que o SDK de uma fonte (Claude, Codex, jev-router) não entregou enquanto o collector estava fora fica de fora; a mitigação é encurtar a parada (`stop_grace_period: 30s`).
- **Uma fila em disco por destino** (`sending_queue.storage: file_storage`, `sizer: bytes`, **1 GB cada**): bucket e agent-studio não se afetam. Retry sem limite (`retry_on_failure.max_elapsed_time: 0`). Com a fila cheia, o collector recusa dado novo com 503 (retentável para a fonte).
- **Lote formado dentro da fila** (`sending_queue.batch`), sem o processor `batch` em memória: bucket ~5 min (franquia de requests do OCI); agent-studio 5 a 30 s.
- **Disco:** o arquivo da fila (bbolt) chega a ~1,7× o limite e não encolhe: **4 GB reservados por máquina** (2 filas × 2 GB). O `oute up` avisa quando não cabe.
- **Pelo menos uma vez = pode duplicar** (retry, `kill -9` no meio de um PUT, spool, restart). **A ingestão do agent-studio deduplica**; o bucket aceita duplicata (arquivo frio).
- `memory_limiter` fica: a recusa em pico volta à fonte como erro que ela reenvia.
- **Perda aceita, lista fechada:** fonte com o collector fora, fila cheia, disco do host perdido e recusa permanente de todos os destinos. Recusa e fila cheia **nunca são silenciosas**: geram alerta (item 8).

### 2. Spool do `oute-emit` (#138; substitui o "sem spool" do adendo #124 do ADR-04)
- POST que falha (collector fora, timeout de 2 s, 5xx) grava o envio em `~/.oute/emit/spool/` (um arquivo por envio, gravação atômica); o `oute-emit` sai na hora, rc 0 e sem stdout. Nunca bloqueia quem chamou.
- Reenvio sem processo residente: toda chamada esvazia o spool primeiro (mesmo teto de 2 s) e o entrypoint esvazia na subida.
- **`oute.event.id`:** id fixo por fato (tipo + rodada/pedido + hora do fato + chave + ocorrência). O mesmo fato leva o mesmo id ao vivo, no spool e no backfill; é a chave de dedupe da ingestão.
- Limite de **50 MB**; cheio, o evento novo não entra e o contador de descartes sobe (vai em todo evento, para o alerta).
- `oute approve` no host continua **sem spool**: na subida do container, o `oute-emit` reconcilia a `inbox` (o `decided` de todo `.out` não enviado).
- Detalhes de implementação no ADR-04 (adendo #124, "Spool" e "Reconciliação da `inbox`").

### 3. Bancos: DuckDB = telemetria, SurrealDB = estado (#139, #140)
- **DuckDB = toda a telemetria, completa e com conteúdo**: `spans`, `logs` (prompts, respostas, tools, eventos operacionais) e `metrics`. É o volume, para análise. **Tabelas nativas** num arquivo `.duckdb`; sem Parquet no caminho quente.
  - **Colunas fixas:** hora do fato, `host.name`, `oute.instance`, `oute.agent`, `service.name`, `session.id`, `oute.task.id`, `oute.swarm.round`, `event.name` e, conforme a tabela, trace/span id, nome, duração, modelo, tokens, custo e corpo.
  - **O resto em colunas JSON** (atributos de resource e do registro, completos): campo novo não quebra nada.
  - **Hora do fato** (`timeUnixNano`) em toda gravação e consulta, nunca a de chegada: o backlog de um host que ficou offline entra no lugar certo.
- **SurrealDB = estado do sistema**: sessões, rodadas, pedidos (pendente/decidido), aprovações e quem aprovou, com as relações entre eles e a ligação aos ids de trace e de sessão. É o que o tray e a tela consultam. **Derivado**: pode ser remontado a partir do DuckDB ou do bucket. Nada existe só nele.
- **Dedupe (chave por tabela):** `spans` por `trace_id + span_id`; eventos do `oute-emit` por `oute.event.id`; logs dos agentes e métricas por **hash do conteúdo** (hora em ns + origem + registro inteiro). Risco aceito: dois registros idênticos até o nanossegundo viram um. No SurrealDB, id determinístico e `INSERT … IGNORE`.
- **Os dois bancos juntos ou nenhum:** se um dos dois falha, a requisição inteira volta como erro retentável (503) e o collector reenvia; a dedupe dos dois lados absorve a repetição.
- Descartados: extensão `otlp` do DuckDB (0.x, um mantenedor); ingestão a partir do bucket (lote de 5 min, fora do alvo de 1 a 2 min); DuckLake (apaga arquivos, não pode morar no `oute-observability`).

### 4. Ingestão = o próprio agent-studio, um processo só (#140, #150, #185)
- O **agent-studio** é um processo único (ingestão + API), porque o DuckDB aceita **um escritor só**: um caminho de escrita, requisições serializadas.
- Recebe **OTLP/HTTP em JSON** (`POST /v1/logs`, `/v1/traces`, `/v1/metrics`), o mesmo formato do `oute-emit`; sem protobuf. O collector ganha um exporter `otlphttp` (`encoding: json`) com fila em disco própria (#155).
- **2xx só depois do commit.** Cada requisição é gravada numa transação; qualquer falha na gravação responde **503** (retentável) e o collector reenvia. O micro-lote de 5 a 30 s se forma na fila do collector, não na memória do agent-studio.
- **Stack:** Python (mesma linguagem do `oute-emit`); FastAPI; DuckDB embutido (wheel aarch64); SDK do SurrealDB. Tela em HTML gerado no servidor (templates + htmx), **sem SPA e sem build de front-end**.
- **Imagem:** o código e as dependências entram na **imagem do `oute-agent`**; o serviço `agent-studio` do compose usa essa imagem com outro comando. Nenhum workflow novo; mudança no agent-studio precisa de release, como qualquer mudança na imagem.
- **Telemetria própria:** logs e métricas do agent-studio pelo SDK OTel ao collector local, com a origem de sempre (ADR-04) e `service.name` próprio, sem laço (o que ele manda e volta a ele não gera telemetria nova por registro).

### 5. Topologia (#141)
- **Nome: agent-studio** (`agent-studio.oute.pro`). O `studio.oute.pro` é outro app, fora do oute-agent.
- Roda **só no oute-server**, instância central que recebe de todos os hosts. Serviços `agent-studio` e `surrealdb` no **compose do oute-agent**, ligados só no servidor (profile do compose, ativado pelo `oute up`); no Mac não sobem.
- `mem_limit`: ~2 GB (agent-studio) e ~1 GB (SurrealDB; sem ele o cache do RocksDB mede pela RAM do host). SurrealDB **fixado por digest**, RocksDB em volume nomeado, **sem porta publicada**, autenticação ligada. DuckDB em volume nomeado.
- **Como os hosts chegam (padrão do vault):** o agent-studio publica **só em `127.0.0.1`**, nunca `0.0.0.0`. O nginx do oute-server tem o vhost `agent-studio.oute.pro` **só na tailnet** (TLS), com proxy para ele (mudança do repo `lab`). O collector do Mac manda OTLP a esse endereço com token; o do oute-server fala direto pela rede docker `oute`. O mesmo endereço serve a API do tray e a tela.
- **Host offline por dias:** coberto pela fila de 1 GB por destino (alerta aos 50%); o backlog chega com a hora original. O tray mostra "último dado há X" por host.
- Descartado: túnel SSH (cai e precisa de alguém mantendo de pé no Mac).

### 6. Autenticação (#150)
- **Um token só**, do vault (pasta `oute-agent`, item **`agent-studio`**, criado pelo Bardi), para o collector do Mac, o tray, a `ops-observe` e o navegador (cola o token uma vez → cookie). Chega ao `agent.env` pelo `oute up`. O mesmo item leva a senha do root do SurrealDB.
- Sem token ou com token errado = **401**.
- A API é só leitura e os agentes já leem toda a telemetria pelo bucket: esconder a leitura deles não protege nada. **A fronteira real é a tailnet.** Vazou: troca o token no vault e roda `oute up`.

### 7. Bucket = arquivo frio e backup (#142)
- **O bucket fica como está:** recebe tudo direto do collector (lote de 5 min), independente do agent-studio; lifecycle do ADR-03 mantido (Infrequent aos 30 d, Archive aos 90 d); **nunca apagado**.
- **O bucket é o backup.** Sem dump do SurrealDB nem do DuckDB e sem job de backup: o DuckDB é remontado do bucket (script rodado quando precisar) e o SurrealDB, do DuckDB.
- **Toda mudança de estado vira evento** no pipeline. Nada existe só no SurrealDB.

### 8. Alertas do pipeline (#136, #150)
- Cada collector manda as **próprias métricas** (`service.telemetry`: tamanho e capacidade da fila, envios que falharam, dados recusados) ao pipeline; o `oute-emit` põe o tamanho do spool e os descartes em cada evento.
- O agent-studio calcula: **fila > 50%**, **destino recusando**, **host sem dado há muito tempo**, **spool perto de 50 MB**. O tray e o agent-studio mostram. Critérios e limites em "Alertas do pipeline: `GET /v1/alerts` (#204)".
- **Nunca** com base na linha `Exporting failed. Dropping data` do log do collector: ela aparece na parada mesmo sem perda (#137).

### 9. Escopo do v1 e troca do Langfuse (#143, #144)
- **v1 = repor só o que é usado hoje:**
  - consulta agregada para a `ops-observe` (e, por ela, a `learn-insights`): custo, tokens, contagem de erro e p95 de latência por host × agente × modelo, com janela de tempo e série diária, sem limite de requisições;
  - tela mínima: lista de conversas por host/agente, detalhe de uma conversa (árvore de spans), agrupamento por sessão (`session.id`, `oute.task.*`) e o A/B do Jev (por nome do trace).
- **Custo:** **real** quando chega (`cost_usd` do Claude, OpenRouter no `jev.decision`); **estimado**, marcado como tal, por uma tabela de preços pequena para o que não manda (Codex); sem contar duas vezes os tokens do router e do `jev.decision`.
- Fora do v1: scores/evals, prompts, datasets, tags, users, links públicos.
- **Troca:** 1 semana com Langfuse e agent-studio em paralelo. Desliga quando a `ops-observe` roda no agent-studio e os números (custo e contagem por agente) batem com os do Langfuse, com diferença pequena. **Desligar** = remover o pipeline `langfuse.yaml` (fica o `none`) e o item `langfuse` do vault. O histórico do Langfuse **não migra** (o bucket já tem tudo, com mais detalhe).

### 10. Tray no Mac e API só leitura (#145, #146)
- **Tray:** app nativo pequeno em Swift (`MenuBarExtra`), código neste repo, instalado por `oute tray install` (compila no Mac, abre no login; sem App Store nem assinatura).
- Mostra: na barra, nº de pedidos pendentes + nº de alertas; máquinas (ativa/parada, "último dado há X"); pedidos pendentes (título, root/user, agente, idade); custo de hoje (total e por agente, estimado marcado); erros na última hora; alertas; "Abrir o agent-studio"; notificação do macOS de pedido novo.
- Lê a API do agent-studio **a cada 15 s**, num **endpoint que devolve tudo o que o menu mostra numa chamada**, mais uma página "ver script" por pedido.
- **A API do agent-studio é só leitura.** Sem endpoint de ação e sem auditoria nova.
- **Aprovar… / Recusar…** no tray **abrem o Terminal** no `oute approve <id>` daquele pedido (local no Mac, ou `ssh oute-server` para pedido do servidor); o Bardi lê o script e confirma como hoje. O `oute approve` já grava `.out`, `approve.log` e emite `oute.canal.decided`. **O ADR-01 não muda.** Motivo: os agentes rodam em yolo no mesmo servidor e na mesma rede docker do agent-studio; uma API que fizesse o host executar um pedido deixaria um agente aprovar o próprio pedido e virar root no host.
- Nenhuma outra ação no v1. Ação nova entra depois, no mesmo padrão: abrir o Terminal no comando que já existe.

### 11. Regra de ferramenta nova (substitui a do ADR-04)
**Nenhuma ferramenta entra no stack se não mandar consumo ao bucket + agent-studio**, pelo collector, com a origem (`host.name` + `oute.instance`) e `oute.agent` (ADR-04). Enquanto o Langfuse roda em paralelo (item 9), ele continua recebendo o que já recebe, mas não é mais exigência para ferramenta nova.

## Implementação
### Ingestão de logs (#185)
- Código em `docker/agent-studio/agent_studio/` (FastAPI + DuckDB), num venv próprio da imagem (`/opt/agent-studio/venv`, dependências fixadas por hash em `docker/agent-studio/requirements.txt`, geradas do `requirements.in` com `uv pip compile --universal --generate-hashes`).
- Compose: serviço `agent-studio` no profile `agent-studio`, `python -m agent_studio` (um processo, um worker), usuário 10001, `127.0.0.1:${OUTE_AGENT_STUDIO_PORT:-8430}`, `mem_limit` `${OUTE_AGENT_STUDIO_MEM:-2g}`, DuckDB no volume `oute-agent-studio` (`/data/agent-studio/agent-studio.duckdb`).
- **Quem liga:** `OUTE_AGENT_STUDIO=1` no `.env` do checkout do host (só no oute-server). O `oute up` põe o profile em `COMPOSE_PROFILES` quando o `agent.env` tem **`AGENT_STUDIO_TOKEN`** (campo do item `agent-studio` da pasta `oute-agent` do vault); sem ele, avisa e sobe o resto. `down`, `status` e `logs` sempre enxergam o profile. Sem token, o próprio processo recusa subir.
- `POST /v1/logs` (OTLP/HTTP JSON, `gzip` aceito): 401 sem o `Bearer` certo; 415 fora de `application/json`; 400 para corpo que não é OTLP JSON (permanente); 503 com `Retry-After` quando a gravação falha (a transação volta inteira); 200 só depois do `COMMIT`. `GET /healthz` sem token (só `ok`).
- Tabela `logs`: `dedupe_key` (PRIMARY KEY: `ev:<oute.event.id>` ou `h:<sha256>` do conteúdo normalizado: hora, hora observada, resource, escopo, severidade, corpo, atributos, `eventName`, trace/span), `time` (TIMESTAMPTZ em UTC, da hora do fato; sem `timeUnixNano`, a observada pela fonte; sem as duas, a chegada), `time_unix_nano`, `observed_unix_nano`, `host_name`, `oute_instance`, `oute_agent`, `service_name`, `session_id`, `oute_task_id`, `oute_swarm_round` (do registro, senão do resource), `event_name`, `oute_event_id`, `severity_number`, `severity_text`, `body`, `trace_id`, `span_id`, `scope_name`, `resource_attributes` e `attributes` (JSON completo), `received_at`/`received_unix_nano`.

### Spans e métricas (#186)
- `POST /v1/traces` e `POST /v1/metrics`, com as mesmas regras do `/v1/logs` (token, 400/415, 503 com rollback, 2xx só depois do commit). As colunas fixas de origem, agente e sessão (`host_name` … `oute_swarm_round`) são as mesmas nas três tabelas.
- Tabela `spans`: `dedupe_key` = `s:<trace_id>:<span_id>` (ids em minúsculas), `time` = início do span, `end_unix_nano`, `duration_ns`, `trace_id`, `span_id`, `parent_span_id`, `name`, `kind`, `status_code`, `status_message`, `model`, `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_creation_tokens`, `cost_usd`, `attributes`, `resource_attributes`, `events` e `links` (JSON).
  - `model`: `gen_ai.response.model` → `oute.served_model` → `model` → `gen_ai.request.model` → `llm.model_name` (o primeiro presente).
  - Tokens: `gen_ai.usage.*` (jev-router) → nomes do Claude Code (`input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_creation_tokens`) → `codex.turn.token_usage.*` (Codex: entrada não cacheada, saída, cacheada).
  - `cost_usd` só o **custo real**: `oute.cost_usd` (OpenRouter no `jev.decision`) → `cost_usd` (Claude Code) → `gen_ai.usage.cost`. O estimado (Codex) e a regra de não contar duas vezes router × `jev.decision` ficam na consulta (#156).
- Tabela `metrics`: uma linha por ponto; `dedupe_key` = `h:<sha256>` (hora em ns + início + resource + escopo + nome, tipo e unidade da métrica + atributos + ponto inteiro), `metric_name`, `metric_type` (`gauge`, `sum`, `histogram`, `exponential_histogram`, `summary`), `unit`, `value` (gauge/sum: o valor; histogram/summary: a soma), `count`, `is_monotonic`, `aggregation_temporality`, `start_unix_nano`, `attributes` (do ponto), `resource_attributes` e `point` (o ponto inteiro sem os atributos: buckets, quantis…). As métricas do próprio collector (#162) entram como qualquer outra.

### SurrealDB: estado derivado (#187)
- Serviço `surrealdb` no mesmo profile `agent-studio`, `surrealdb/surrealdb:v3.3.0` **fixado por digest** (`OUTE_SURREALDB_IMAGE` troca), usuário 10001 (o `volume-init` dá o dono do volume `oute-surrealdb`), `rocksdb:///data/surrealdb`, `mem_limit` `${OUTE_SURREALDB_MEM:-1g}`, **sem porta publicada**, autenticação ligada (root com `AGENT_STUDIO_SURREAL_PASS`, campo do mesmo item `agent-studio` do vault). O `oute up` só liga o profile com os dois campos; sem um deles, avisa qual falta.
- Cliente: HTTP `/rpc` do SurrealDB com python3 stdlib (sem o SDK: uma dependência a menos), valores sempre em variáveis, namespace `oute`, banco `studio` (criados na primeira escrita). Cada requisição vira **uma transação** no SurrealDB, feita depois dos INSERTs e **antes do COMMIT do DuckDB**: se o SurrealDB falha, o DuckDB faz rollback e a resposta é 503. Requisição sem nada a derivar (ex.: métricas) não depende do SurrealDB.
- Registros (id = o do fato; toda escrita é `UPSERT … MERGE` com valores do próprio fato, então reenvio e ordem não mudam o resultado; o estado inicial só entra se não houver estado, `state ?? …`):
  - `pedido:<oute.canal.id>`: `proposed` → título, como, agente, tamanho, `proposed_at`, estado `pendente`; `decided` → estado `decidido`, decisão, rc, duração, bytes de saída, aprovador, sha256, `decided_at`, `decided_by` (`human`). Um `decided` que chega antes do `proposed` continua decidido. A saída do host nunca chega aqui (o evento não a tem).
  - `rodada:<oute.swarm.round>`: abertura (repo, max, label, coordenadora, `opened_at`, `aberta`) e rodada fechada (`fechada`, `closed_at`).
  - `worker:[<rodada>, <slug>]`: spawn (issue, agente, repo, kaizen, `spawned_at`, `aberta`, link `rodada`) e close (`fechada`, `closed_at`); link `sessao` quando a sessão do `oute-task` da rodada aparece.
  - `sessao:<oute.task.id>`: `oute.task.opened`/`reopened`/`removed` (repo, slug, agente, legado, horas, `removida` com o motivo em `oute.task.reason`), links `rodada` e `worker` quando o evento traz `oute.swarm.round`/`oute.swarm.session`. `removed` sem `oute.task.id` fica só no DuckDB. O `oute-emit` ainda não emite `oute.task.*` (#128): a derivação segue os nomes do ADR-04.
  - `conversa:<session.id>`: de todo log ou span com `session.id`; agente, máquina, instância, serviço e link `sessao` pelo `oute.task.id` do resource. Os traces da conversa ficam no DuckDB (`spans.session_id`).
  - Cada registro guarda o `oute.event.id` dos eventos que o formaram (`proposed_event`, `decided_event`…), a chave da linha no DuckDB.

### Telemetria própria (#188)
- SDK OTel (`opentelemetry-sdk` + exporter OTLP/HTTP protobuf) ao `otel-collector` local (`http://otel-collector:4318`), com a origem de sempre (`OTEL_RESOURCE_ATTRIBUTES`: `host.name`, `oute.instance`, `deployment.environment`) e `service.name=agent-studio`. **Sem `oute.agent`**: o agent-studio não é agente, e o ADR-04 descarta `oute.agent` fixo por ferramenta.
- **Métricas** (a cada 60 s): `agent_studio.requests` (por sinal e `http.response.status_code`), `agent_studio.records.written` e `agent_studio.records.duplicate` (por sinal), `agent_studio.write.duration` (histograma, por sinal e resultado `ok`/`error`; DuckDB + SurrealDB).
- **Logs:** só aviso e erro saem como log OTel: requisição recusada (token, `Content-Type`, corpo inválido ou grande demais) e gravação que falhou (503). Cada tipo sai no máximo uma vez por minuto (`AGENT_STUDIO_LOG_EVERY`), e o seguinte diz quantos foram suprimidos. O log de sucesso por requisição fica só no stderr do container. Erros do próprio SDK (collector fora) também ficam no stderr.
- **Sem laço:** quando a telemetria do agent-studio volta a ele pela ingestão (#155), gravar é só somar contadores; nenhum registro novo nasce por registro recebido. Com a ingestão falhando, os avisos têm teto por minuto.
- Na parada (SIGTERM), o lifespan do app exporta o que ficou no lote e fecha o DuckDB antes de o processo sair.

### Collector → agent-studio no oute-server (#189)
- `config/otel/agent-studio.yaml`, mesclado sobre o `collector.yaml` como o `langfuse.yaml`: o `oute up` exporta `OUTE_OTEL_STUDIO=agent-studio` só quando liga o profile `agent-studio` (`OUTE_AGENT_STUDIO=1` e o item do vault); senão, `none` e o collector não muda.
- Três `otlp_http` (`studio_traces`, `studio_metrics`, `studio_logs`) para `http://agent-studio:8430` na rede `oute`, `encoding: json`, gzip, `Authorization: Bearer ${AGENT_STUDIO_TOKEN}` (o compose passa o token ao collector).
- Sem perda como o bucket: fila em disco na mesma `file_storage/queue` (arquivo próprio por exporter), `sizer: bytes`, logs 600 / traces 300 / metrics 100 MB, `block_on_overflow: false`, retry sem prazo. Lote na fila com `flush_timeout: 10s`, em bytes (1 a 8 MB de protobuf), para o corpo JSON ficar abaixo dos 64 MB da ingestão (acima disso seria 400, que não é retentado).
- Pipelines `traces|metrics|logs/studio` com os processors do bucket (`memory_limiter`, `transform/agent`, `resource`), sem filtro. As métricas do collector (#162) passam a trazer também a fila dos três exporters. Teste `tests/otelcol-studio.test.sh`.

### Collector → agent-studio nos outros hosts (#190)
- Mesmo `agent-studio.yaml`, com o destino em `AGENT_STUDIO_URL`, escolhido pelo `oute up`: no host com `OUTE_AGENT_STUDIO=1`, `http://agent-studio:8430` (rede `oute`); nos outros (Mac), `https://agent-studio.oute.pro`, o vhost só na tailnet (lab#244), com o mesmo token. `OUTE_AGENT_STUDIO_URL` no `.env` troca o vhost.
- Sem `AGENT_STUDIO_TOKEN` no `agent.env`, o pipeline não liga (`none`, a fila não enche de 401) e o `oute up` avisa. Mesma fila em disco, retry e lote: sem tailnet, o dado espera na fila e chega com a hora do fato quando a rede volta.

### Consulta agregada de uso: `GET /v1/usage` (#203)
- **Só leitura**, com o mesmo token (`Authorization: Bearer`); sem ele ou errado = **401**. Outro método = 405.
- **Janela** `[from, to)`, sempre pela **hora do fato** (`time_unix_nano`; nos spans, o início): `from` e `to` juntos em ISO 8601 (`2026-09-29` ou `2026-09-29T12:00:00Z`; sem fuso = UTC), **ou** `hours` (padrão 24, até 8784) terminando agora. Janela inválida, `from` sem `to`, `from >= to` ou `from`/`to` junto com `hours` = **400**. Leitura que falha = **500** (causa só no stderr).
- **Resposta:** `from`, `to`, `time`, `prices` (`models` carregados e `errors` da config), `totals`, `unpriced_models`, `rows` (host × agente × modelo) e `series` (dia UTC × host × agente × modelo). Cada grupo:
  `calls`; `tokens` {`input`, `output`, `cache_read`, `cache_creation`}; `cost` {`real_usd`, `estimated_usd`, `real_calls`, `estimated_calls`, `unpriced_calls`}; `errors` {`spans`, `logs`, `total`}; `latency_p95_ms`.
- **Chamada ao modelo** = span `claude_code.llm_request`, `session_task.turn` (Codex) ou `jev.decision`. Tokens, custo, `calls` e p95 saem só delas.
- **Sem contar duas vezes:** spans do LiteLLM (`oute.agent=router`) ficam fora das somas; o `jev.decision` conta uma vez (dedupe por trace + span), mesmo quando chega sem o `oute.agent` do cliente.
- **Custo real** (`real_usd`) = soma do `cost_usd` dos spans; `null` quando nenhuma chamada do grupo trouxe custo. **Estimado** (`estimated_usd`) = tabela de preços sobre os tokens das chamadas **sem** custo real; `null` quando não há o que estimar. **Modelo sem preço nunca vira zero**: a chamada entra em `unpriced_calls` (fora das duas somas) e o modelo em `unpriced_models`. `real_calls + estimated_calls + unpriced_calls = calls`.
- **Erros** = spans com status de erro (qualquer span, inclusive os do LiteLLM: o `jev.decision` só nasce de chamada que deu certo) + logs com severidade ERROR ou acima (sem modelo: grupo com `model` nulo).
- **p95** = quantil 0,95 (interpolado) da duração das chamadas ao modelo do grupo, em ms; `null` sem chamada.
- **Tabela de preços:** `config/agent-studio/config.toml`, seção `[prices."<modelo>"]` com `input`, `output`, `cache_read`, `cache_creation` em USD por 1M tokens (`input`/`output` obrigatórios; cache ausente = preço de `input`). A pasta é montada **só leitura** em `/etc/oute/agent-studio` (`AGENT_STUDIO_CONFIG`); preço novo entra com `git pull` + `oute down/up`, sem release. Busca sem diferenciar maiúsculas e, sem entrada exata, sem o prefixo do provedor. Config ausente ou inválida não impede a subida: sem estimado, motivo no stderr e em `prices.errors`; entrada inválida fica de fora (o modelo aparece sem preço). O #204 põe hosts e limites no mesmo arquivo.
- **Reuso:** regras e preço em `agent_studio/cost.py` (puro), leitura da config em `config.py`, agregação em `usage.aggregate(con, from_ns, to_ns, prices, keys)` com qualquer combinação de `day`/`host`/`agent`/`model` (o custo estimado é calculado por modelo e depois somado). Alertas (#204), tray (#205) e tela (#206) usam essas peças.
- Teste: `tests/agent-studio-usage.test.sh` (DuckDB de exemplo montado pela ingestão).

### Alertas do pipeline: `GET /v1/alerts` (#204)
- **Só leitura**, com o mesmo token do `/v1/usage` (sem ele ou errado = **401**; outro método = 405). `at` (ISO 8601, opcional) avalia numa hora passada; padrão = agora. `at` inválido = **400**; leitura que falha = **500** (causa só no stderr).
- **Sem estado:** cada consulta calcula do DuckDB, pela **hora do fato**. O alerta liga quando o dado mostra o problema e desliga sozinho quando o dado seguinte não mostra mais. "Desde quando" volta no máximo `lookback_hours` (24).
- **Critérios** (tipo no JSON):
  - `queue` (**fila > 50%**): último `otelcol_exporter_queue_size` ÷ `otelcol_exporter_queue_capacity` do mesmo ponto, por host, instância e exporter (#162) acima de `queue_max_ratio` (0,5). Desde = início da sequência final de pontos acima.
  - `destination_refusing` (**destino recusando**): `otelcol_exporter_send_failed_{spans,metric_points,log_records}` de um exporter subiu nos últimos `refused_window_minutes` (15). Contador acumulado: diferença entre pontos seguidos; valor menor ou `start` diferente = reinício do collector, conta desde o zero; o primeiro ponto lido só conta se o contador começou dentro da janela lida. Valor = quanto subiu na janela; desde = primeira subida da sequência (subidas a até 15 min uma da outra).
  - `host_no_data` (**host sem dado**): só os hosts de `always_on_hosts` (hoje `oute-server`), sem nenhum registro (log, span ou métrica) há mais de `no_data_minutes` (30). Valor = segundos sem dado (`null` se o host nunca mandou nada); desde = o último registro.
  - `spool` (**spool perto de 50 MB**): no último evento do `oute-emit` do host, `oute.emit.spool.bytes` acima de `spool_max_bytes` (40 MiB), **ou** `oute.emit.spool.dropped` subiu entre dois eventos seguidos nos últimos `spool_dropped_window_minutes` (60; os eventos são esparsos). O contador do spool nunca zera: sem evento anterior lido, o valor não é subida.
  - `quota` (**cota**, previsto para a #55, **desligado**): com `quota_enabled = true`, último ponto de `quota_metric` (nome provisório `oute.quota.used_pct`, a #55 fixa) por host, agente e atributos em `quota_max_pct` (90) ou acima.
- **Host parado** = sem registro há mais de `no_data_minutes`. Host parado não liga `queue`, `destination_refusing`, `spool` nem `quota` (valor velho): o **Mac fechado não alerta** e aparece só em `hosts` com o último dado; o host sempre ligado parado alerta só `host_no_data`.
- **Nunca** a linha `Exporting failed. Dropping data` do log do collector (§8, #137): nenhum alerta lê o corpo de log.
- **Resposta:** `at`, `time`, `alerts`, `hosts`, `checks` (tipo → ligado) e `config.errors`. Cada alerta: `type`, `host`, `instance`, `value`, `unit` (`ratio`, `failed_items`, `seconds`, `bytes`, `dropped_events`, `pct`), `limit` (0 nos que ligam com qualquer subida), `since` e `evidence` (métrica ou atributo, exporter, pontos, evento com `event_name`/`event_id`). `hosts`: todo host com dado mais os sempre ligados, com `always_on`, `last_data` e `idle_seconds` (o "último dado há X" do Mac).
- **Config:** seção `[alerts]` do `config/agent-studio/config.toml` (o mesmo arquivo dos preços, montado só leitura: muda com `git pull` + `oute down/up`, sem release). Os padrões do código são os valores do arquivo do repo; chave desconhecida ou valor inválido fica com o padrão e vai a `config.errors`; arquivo ausente = todos os padrões.
- **Reuso:** `agent_studio/alerts.py` (`evaluate(con, at_ns, cfg)`, `AlertConfig.parse`), para o tray (#205) e a tela (#208).
- Teste: `tests/agent-studio-alerts.test.sh` (DuckDB de exemplo montado pela ingestão; cada alerta liga e desliga, o Mac parado não alerta).

## Opções consideradas
- **Pagar um plano maior do Langfuse (Core, Pro):** resolve a janela, não o "tudo com conteúdo" (governança: SaaS na UE só recebe metadados) nem a consulta sem limite. Descartado.
- **Langfuse self-hosted:** guarda sem prazo, mas traz ClickHouse, Postgres, Redis e S3 para operar, e continua só com traces. Fora do mapa.
- **Broker central (RabbitMQ, NATS, Kafka):** só agrega com vários consumidores independentes; a fila em disco do collector em cada host cobre o buffer. Fora do mapa.
- **Ler direto do bucket (DuckDB sobre `otlp_json` no OCI):** lote de 5 min, Archive aos 90 d, `httpfs` no OCI não testado (501 de checksum). Serve só para remontar o banco.
- **Só DuckDB, sem SurrealDB:** o estado (pedido pendente → decidido, rodada → sessões) é relação e atualização, que o DuckDB faz mal com um escritor só e tabelas de fato. SurrealDB derivado mantém o DuckDB só com fatos.
- **API com ação (aprovar pelo tray assinando com chave do Mac):** muda o ADR-01 e cria uma peça sensível; volta como melhoria se abrir o Terminal incomodar no uso.

## Consequências
- O agent-studio passa a ser um serviço com estado no oute-server: disco (DuckDB + RocksDB) e memória (~3 GB somados) a vigiar. O banco não tem backup próprio: perdido, é remontado do bucket.
- O dado de um host só chega ao agent-studio depois do vhost na tailnet (repo `lab`) e do exporter no collector (#155). Até lá, o bucket continua completo.
- Toda mudança no agent-studio precisa de release (vai na imagem do `oute-agent`).
- O SurrealDB é BSL: uso interno ok (#139); não redistribuímos.
- A `ops-observe` e a `learn-insights` trocam a Metrics API do Langfuse pela consulta do agent-studio (quando o v1 estiver pronto).
- Duplicata é normal no bucket (pelo menos uma vez); quem lê o bucket diretamente deduplica pelas mesmas chaves.

## Plano de construção (#147)
Issues em ordem, cada uma com seu PR: ADR (#151); collector sem perda (#152: fila em disco #161, métricas do collector #162, reserva de disco #163); spool do `oute-emit` (#153: #165, #166, #167); ingestão (#154: logs #185, spans e métricas #186, SurrealDB #187, telemetria própria #188); collector → agent-studio (#155: oute-server pela rede docker #189, Mac pela tailnet #190, depois do vhost no `lab`); API e tela v1 (#156); `ops-observe` e `learn-insights` no agent-studio (#157); tray e `oute approve <id>` (#158); remontagem a partir do bucket (#159); desligar o Langfuse (#160).
