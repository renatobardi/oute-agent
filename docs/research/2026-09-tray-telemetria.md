# Pesquisa: tray no Mac + telemetria sem perda (fila, banco, retenção do Langfuse)

Fase `strat` (AI-DLC, ADR-07) · 2026-09-27 · autor: agente (Claude), a pedido do Bardi · **as decisões são do Bardi**.

## 1. Pergunta e escopo

Pedido (literal): *"quero ter um tray no mac para monitorar todas acoes que estao acontecendo no oute-agent, independente de qual local (server, mac, etc). nao quero criar novo item de monitoria, geracao de log, quero evoluir o atual, subindo um db para salvar tudo, sem ter perda de nenhum dado. o Langfuse soh salva 30 dias, quero passar a salvar tudo nele. Pensei em nao salvar direto no banco tudo que loga, pensei em postar em uma fila (pensei no rabbitmq), algo nessa linha"*

Reformulado em cinco perguntas:
1. De onde vem o limite de 30 dias do Langfuse e o que custa passar a guardar tudo nele?
2. Onde, hoje, dá para perder dado entre a fonte e o destino, e o que o próprio OTel Collector já oferece para fechar isso?
3. Uma fila (RabbitMQ ou outra) agrega algo além da fila persistente do collector?
4. Que banco guarda "tudo" de forma consultável: o bucket OCI basta como fonte da verdade, com um banco derivado?
5. Como fazer o tray no Mac e de onde ele lê os eventos de todos os hosts?

Fora do escopo: implementar qualquer coisa, mudar ADR, mexer no host.

> As respostas do Bardi a esta nota estão na §5.1: o Langfuse sai e entra o oute-agent-studio (SurrealDB + DuckDB), e o RabbitMQ fica de fora.

## 2. Estado atual (fonte: o repo)

### 2.1 Fontes e caminho

| Fonte | Sinal | Caminho | Onde está no repo |
|---|---|---|---|
| Claude Code | logs (com prompt, resposta e tools), métricas, traces | OTLP http/protobuf → `otel-collector:4318` | `docker/compose.yaml:31-48` |
| Codex | logs, traces | OTLP (bloco `[otel]` do `config.toml`, via `docker/codex_config.py`) | `docs/adr/0004-observabilidade.md:124-133` |
| Pi | só via jev-router (header `X-Oute-Agent`) | — | `docs/adr/0004-observabilidade.md:46` |
| jev-router (LiteLLM + span `jev.decision`) | traces | OTLP gRPC → `otel-collector:4317` | `docker/compose.yaml:94-97` |
| `oute-emit` (swarm, canal de aprovação, `oute-task`) | logs (eventos operacionais) | OTLP/HTTP JSON, timeout 2 s, sem spool | `docker/oute-emit:9-10,107-128`; ADR-04 `:58-106` |
| `oute approve` (host) | via `docker exec oute-agent oute-emit canal <id>` | — | ADR-04 `:63,80` |

Tudo entra num **collector por host** (`otel/opentelemetry-collector-contrib:0.161.0`, sem porta publicada; `docker/compose.yaml:151-177`), que manda:
- **Bucket OCI `oute-observability`** (tudo, com conteúdo, `otlp_json` + gzip, partição `otel/<sinal>/host=/instance=/year=/month=/day=/hour=`): `config/otel/collector.yaml:52-91`, pipelines `:97-109`.
- **Langfuse Cloud (EU, plano Hobby)**, só **traces** e só **metadados** (allowlist `keep_matching_keys`): `config/otel/langfuse.yaml:22-71`; decisão em ADR-04 `:7`.

Cada host (oute-server e Mac) roda sua própria stack e seu próprio collector; os **dois pontos em comum** entre hosts hoje são o bucket e o Langfuse. O bucket já tem `host=oute-mac/` e `host=oute-server/` nos três sinais. Volume medido em 2026-09-27 com `rclone size`: **1.022 objetos, 14,1 MiB (gzip)** desde a fase 1 (~24/09). O volume é pequeno.

Recursos do oute-server (medidos por `ssh oute-server`, só leitura): aarch64, **4 vCPU, 23 GiB de RAM (~12 GiB disponíveis), disco de 45 GB com 22 GB livres**. O Mac e o oute-server já estão na mesma **tailnet** (Tailscale; `README.md:49`, `oute-server.*.ts.net`).

### 2.2 Onde dá para perder dado hoje

| # | Ponto | Por quê | Referência |
|---|---|---|---|
| P1 | **Lote de 5 min em memória** no processor `batch/archive` | O processor `batch` guarda até 5 min na RAM antes de exportar. Se o collector morrer (OOM, `kill`, queda do host), o lote some. | `config/otel/collector.yaml:47-50` |
| P2 | **Fila de envio só em memória** | `sending_queue: {enabled: true}` sem `storage`. Pela doc do collector, a fila em memória se perde se o processo cai [2][3]. | `config/otel/collector.yaml:64,77,90` |
| P3 | **Retry desiste em 5 min** | Não há `retry_on_failure` configurado; o default é `max_elapsed_time: 300s`. Se o OCI ficar fora (ou recusar, como no caso do 501 do checksum) por mais de 5 min, o lote é descartado [2][3]. | idem |
| P4 | **Fila cheia descarta** | O default é `block_on_overflow: false` e `queue_size: 1000`. Com a fila cheia, o dado novo é descartado antes de chegar ao retry [2]. | idem |
| P5 | **SDKs das fontes não persistem** | O `BatchSpanProcessor` do SDK OTel descarta spans quando a fila (padrão 2048) enche [5]; a spec do exporter OTLP exige retry com backoff em erro transitório, mas não persistência [4]. Se o collector estiver fora (por exemplo, no `oute down/up`), o que a fonte não conseguir entregar se perde. As transcrições locais (`~/.claude/projects`, `~/.codex/sessions`) continuam existindo, mas não são reenviadas. | ADR-04 `:113` |
| P6 | **`oute-emit` best-effort, sem spool** | Decisão explícita: timeout de 2 s, sempre rc 0, sem reenvio. O backfill é único e só cobre o que é anterior ao corte, então um evento ao vivo perdido não volta (a fonte local, `log` da rodada e `approve.log`, fica como primária). | ADR-04 `:64-65`; `docker/oute-emit:10` |
| P7 | **`memory_limiter`** | Com 256 MiB, recusa dado em pico. Cabe ao cliente refazer o envio, e o SDK não persiste. | `config/otel/collector.yaml:16-19` |
| P8 | **Langfuse: janela de 30 dias** | O Hobby mostra 30 dias (ver §3.1). O Langfuse **nunca foi a fonte da verdade** (só metadados), então isso não é perda: o bucket tem tudo. | ADR-04 `:112` |
| P9 | **Bucket em Archive depois de 90 dias** | O ADR-03 põe o `oute-observability` em Infrequent aos 30 d e em Archive aos 90 d. Objeto em Archive precisa de *restore* (até 1 h) antes de ser lido [16]. Não há perda, mas **um banco derivado ou um replay de dado antigo passa a exigir restore**. | `docs/adr/0003-storage-oci.md:28` |

Observação: o `docker compose down` para o container com SIGTERM; em parada limpa, o collector tenta esvaziar batch e fila. **Não conferi** se o prazo padrão de parada do Docker (10 s) basta para esvaziar um lote grande ao OCI. Vale testar antes de concluir que o `oute down/up` é seguro.

### 2.3 Regras fixas que qualquer proposta respeita
- Telemetria no bucket `oute-observability` **nunca é apagada**; se crescer, a alavanca é tiering (ADR-04 `:9`; `AGENTS.md`).
- **Porta de entrada única = OTel Collector**; os destinos são trocáveis (ADR-04 `:10`). Isso casa com o "evoluir o atual" do pedido.
- Ferramenta nova só entra se mandar consumo ao bucket + Langfuse (ADR-04 `:13`). O adendo #124 restringe a regra a **consumo de modelo** (`:61`). Um banco ou uma fila não geram consumo de modelo, mas o Bardi pode querer confirmar a leitura.
- Langfuse recebe **só metadados** (ADR-04 `:7`), por governança: é SaaS na UE. Conteúdo só no bucket.
- A **saída do script do host nunca vai** para a telemetria (ADR-04 `:60`).
- Nunca publicar porta em `0.0.0.0`; segredos só via Vaultwarden lido no host, nada de `BW_*` no container (`AGENTS.md`).
- oute-server = Oracle Cloud **arm64**; Mac = Apple Silicon com Docker Desktop; `scripts/oute` roda no bash 3.2 do macOS.
- Mudança no **host** (nginx, firewall, systemd, Tailscale) é do repo `lab`. `config/` e `docker/compose.yaml` entram com `git pull` + `oute down/up`, **sem release**; mudança na imagem precisa de release.
- ai-memory não muda sem decisão explícita.

## 3. Achados por pergunta

### 3.1 Retenção do Langfuse
- O repo usa **Langfuse Cloud, região EU, plano Hobby** (ADR-04 `:7`; `LANGFUSE_HOST` padrão `https://cloud.langfuse.com` em `docker/compose.yaml:173`).
- Os 30 dias são a **janela de acesso do plano**: "Hobby: 30 days, Core: 90 days, Pro and Enterprise: 3 years" [1]. A tabela de preços: Hobby grátis (50k unidades/mês, 30 dias), Core US$ 29/mês (100k, 90 dias), Pro US$ 199/mês (100k, 3 anos), Enterprise US$ 2.499/mês; unidade extra a US$ 8/100k [6].
- A doc diz que, sem política de retenção, **o Langfuse não apaga os eventos**: "Without a retention policy, Langfuse does not automatically delete event data" [1]. **Não achei** fonte primária que diga se um upgrade devolve o acesso a dados mais velhos que a janela do Hobby. Só o suporte responde isso.
- **Self-hosted**: "data is stored indefinitely by default" [1]. A *política* de retenção (apagar depois de N dias) é recurso **Enterprise** no self-host [1][7]. Como o Bardi quer guardar tudo, o recurso pago é justamente o que ele **não** precisa. O resto do produto é MIT e sem limite de uso [7].
- **Arquitetura do self-host (hoje v4; imagem `langfuse/langfuse-worker:4.46`, arm64 + amd64, conferida no Docker Hub em 2026-09-27)** [8][9]: web + worker + Postgres + ClickHouse + Redis/Valkey + blob S3. A ingestão já tem fila e blob: "All traces are received in batches by the Langfuse Web container and immediately written to S3. Only a reference is persisted in Redis for queueing. Afterwards, the Langfuse Worker will pick up the traces from S3 and ingest them into Clickhouse." [8]
- **Recursos**: a doc de docker compose pede "at least 4 cores and 16 GiB of memory" e ~100 GiB de disco, e diz que o compose "lacks high-availability, scaling capabilities, and backup functionality" [10]. Os mínimos por componente somam ~11 vCPU e ~21,5 GiB (web 2/4, worker 2/4, Postgres 2/4, Redis 1/1,5, ClickHouse 2/8) [11]. **O oute-server tem 4 vCPU e ~12 GiB livres e 22 GB de disco livre**: um Langfuse self-host ali competiria com os agentes e ficaria abaixo do mínimo da doc. O blob poderia ser o próprio OCI S3-compat, o que tira o MinIO da conta.
- **Endpoint OTLP** `/api/public/otel`: HTTP/JSON e HTTP/protobuf, **sem gRPC**, **só traces** na doc [12]. Logs e métricas (onde estão os prompts do Claude e os eventos operacionais) não entram no Langfuse por esse caminho. "Salvar tudo no Langfuse" cobre, então, só os traces.
- **Replay**: o `awss3receiver` do contrib lê do bucket por faixa de tempo, usando o mesmo formato de partição do `awss3exporter`, e reexporta [13]. Dá para reinjetar o histórico do bucket num Langfuse self-host (ou em qualquer banco) passando pelo mesmo `transform/metadata_only`. O receiver é **alpha** [14]. Objetos em Archive precisam de restore antes (P9).

### 3.2 Não perder dado: o que o collector já oferece
- **Fila persistente**: `sending_queue.storage: file_storage/<nome>`. Nesse modo "There is no in-memory queue", e "If the collector instance is killed while having some items in the persistent queue, on restart the items will be picked and the exporting is continued" [2]. A página de resiliência descreve isso como WAL em disco [3]. `file_storage` é **beta** [14].
- **Retry sem desistir**: `retry_on_failure.max_elapsed_time: 0` ("the retries are never stopped") [2]. Com fila persistente e retry infinito, uma queda longa do OCI ou do Langfuse vira atraso, não perda, enquanto houver disco.
- **Fila cheia**: `block_on_overflow: true` faz o collector segurar o chamador em vez de descartar [2]. Isso empurra a pressão para o SDK da fonte, que descarta quando a fila dele enche (P5) [5]. O ganho real vem de dimensionar `queue_size` com `sizer: bytes` para o disco disponível.
- **Batch dentro da fila**: o `sending_queue` tem `batch` próprio (`flush_timeout`, `min_size`, `max_size`) [2]. Trocar o processor `batch/archive` (memória, P1) pelo batch da fila persistente tira os 5 min de RAM do caminho. Tem de ser medido: com `flush_timeout: 5m` o lote se forma a partir da fila, que já está em disco.
- **Limites** declarados pela própria doc: ainda há perda "if the disk fails or runs out of space, or if the endpoint remains unavailable beyond the retry limits" [3]. O que nunca chegou ao collector (P5, P6) fica de fora.
- **O que a doc diz de fila externa**: "Use a message queue for critical data paths requiring high durability, especially across network boundaries… systems like Kafka", **"if the operational overhead is acceptable"** [3].

**Conclusão da 3.2:** `file_storage` + `retry_on_failure.max_elapsed_time: 0` + batch na fila fecham P1 a P4 **sem componente novo**. É só config e um volume para o diretório da fila, ou seja, `config/otel/` e `docker/compose.yaml`, **sem release**. P5 e P6 ficam na fonte e nenhuma fila atrás do collector os resolve.

### 3.3 Fila: RabbitMQ × alternativas (componentes do collector-contrib v0.161.0)

| Opção | Exporter OTel | Receiver OTel (consumir de volta) | Observação |
|---|---|---|---|
| **RabbitMQ** | `rabbitmqexporter` **alpha** [14]; AMQP 0.9.1, *publisher confirms* [15a]; `retry_on_failure` **desligado por padrão**; o factory usa só `WithRetry`, **sem `sending_queue`**, então não tem fila persistente do lado do collector [15a][15b] | **não existe**. O `rabbitmqreceiver` é **scraper de métricas do próprio RabbitMQ** (Management Plugin), não consome OTLP [15c] | o consumidor da fila teria de ser código nosso. Para não perder, a doc do RabbitMQ exige três coisas juntas: confirms, filas duráveis/quorum e ack do consumidor [17]. Os **streams** do RabbitMQ permitem replay e vários consumidores [18]. Imagem oficial multi-arch (arm64). |
| **Kafka / Redpanda** | `kafkaexporter` **beta** (core + contrib) [14] | `kafkareceiver` **beta** [14] | é o único par exporter/receiver OTel de primeira linha. Log com replay por offset. É a opção que a doc do collector cita [3]. É a mais pesada de operar para um lab de uma pessoa. |
| **NATS JetStream** | **não existe** no contrib (404 em v0.161.0) | **não existe** | persistência com at-least-once e replay por sequência ou tempo [19]; binário leve, mas precisaria de código nosso nos dois lados. |
| **Redis Streams** | **não existe** no contrib | **não existe** | idem. |
| Pulsar | `pulsarexporter` alpha [14] | — | fora de escala para o caso. |

**O que a fila agregaria de verdade** (além da fila persistente do collector):
1. **Fan-out com replay** (streams do RabbitMQ, Kafka, JetStream): vários consumidores independentes (banco, tray, Langfuse) lendo o mesmo fluxo, cada um no seu ritmo. Isso é útil para o tray ao vivo.
2. **Fronteira entre hosts**: um broker central no oute-server receberia do Mac e do servidor. Um **collector central** com `otlp` receiver faz o mesmo papel, com fila persistente dos dois lados (o collector do host guarda enquanto o central está fora).

**O que a fila não resolve:** P5 e P6 (perda antes do collector), nem o "salvar tudo", que o bucket já faz. Com RabbitMQ especificamente, o próprio trecho collector → broker fica **mais fraco** que o `awss3` atual: sem fila persistente no exporter, e com retry desligado por padrão. Além disso, **não há receiver** OTel para tirar os dados de lá.

### 3.4 Banco para "salvar tudo"
- O bucket **já é** o arquivo permanente, que nunca apaga (ADR-04 `:9`), e já junta os hosts (partição `host=`). Pelas regras do projeto, ele é a fonte da verdade natural. Um banco derivado pode ser reconstruído do bucket a qualquer momento (§3.1, replay), então **não precisa de backup próprio nem de garantia de "nunca perder"**.
- **DuckDB sobre o bucket**: lê S3-compatível com endpoint próprio e `URL_STYLE path` [20], suporta partição Hive (`hive_partitioning = true`) [21] e lê JSON. Com 14 MiB até agora, uma consulta direta sobre `otlp_json.gz` no bucket funciona **sem servidor nenhum**, inclusive no Mac. O custo fica em requests ao OCI (franquia de 50 mil por mês, ADR-03 `:14`), por isso vale um cache local.
- **ClickHouse**: a função `s3()` lê globs de S3, detecta gzip e formato [22]. O `clickhouseexporter` do contrib é **beta** para traces e logs [14]. É o motor que o próprio Langfuse usa. Consultas rápidas, mas é mais um serviço de estado (≥ 8 GiB no perfil do Langfuse [11]).
- **Postgres/Timescale**: sem exporter OTel no contrib para gravar direto. Precisaria de código nosso ou de ETL a partir do bucket.
- **Latência**: o bucket recebe lotes de 5 min (`collector.yaml:48`), e o ADR avisa que a partição é pela **hora de chegada** (ADR-04 `:65`). Um banco derivado só do bucket vê as coisas com ~5 a 10 min de atraso. Para um tray "ao vivo", o banco precisaria de um caminho quente separado: um segundo exporter no collector, direto ao banco ou a um collector central.

### 3.5 Tray no Mac
- **SwiftUI `MenuBarExtra`** (macOS 13+): "A scene that renders itself as a persistent control in the system menu bar"; tem o estilo *window* para conteúdo rico, e o app só de menu bar costuma esconder o ícone do Dock [23]. É um app nativo: exige Xcode, assinatura e um projeto Swift novo, fora do padrão bash do repo.
- **SwiftBar** (MIT, macOS 12+, Apple Silicon): plugin = **qualquer executável**; o intervalo vai no nome do arquivo (`x.1m.sh`), e há **plugins de streaming** (`~~~`) para fluxo contínuo [24]. É o que mais combina com o repo (bash/python, entra como addon ou script). O xbar tem o mesmo modelo (não pesquisado a fundo).
- **Tauri/Electron**: tray com UI web. Não pesquisado a fundo: é peso de toolchain para um indicador.
- **De onde o tray lê** (cada caminho com seu custo):
  - **Bucket/DuckDB**: sem serviço novo e cobre os dois hosts, mas com atraso de 5 a 10 min. Precisa de credencial S3 no Mac (hoje fica em `~/.oute/agent.env`, gerado do vault pelo `oute up`).
  - **Langfuse API**: já existe e junta os hosts pelo `environment`, mas só tem traces e metadados. Logs, eventos operacionais (swarm, canal, `oute-task`) e métricas não estão lá. Se continuar no Cloud, conta nas 50k unidades.
  - **Banco ou collector central no oute-server via Tailscale**: é ao vivo, mas é serviço novo. A porta ficaria no IP da tailnet (`100.x`) ou só em `127.0.0.1` com túnel SSH; **nunca em `0.0.0.0`**. Um bind no IP Tailscale do host ou uma regra de firewall é mudança de host, então é do repo `lab`.
  - **Pedidos pendentes do canal**: o tray pode mostrar pedidos pendentes (evento `oute.canal.proposed` sem `decided`). Aprovar **fora do container** continua sendo regra (ADR-01 `:122`). O tray pode abrir o `oute watch oute-server` num terminal, mas **não deveria aprovar sozinho** sem uma decisão explícita.

## 4. Opções de arquitetura

### Opção A: endurecer o collector e usar o bucket como banco (sem fila, sem Langfuse self-host)
- **Muda:** `file_storage` + volume no collector; `retry_on_failure.max_elapsed_time: 0`; batch na `sending_queue` no lugar do processor `batch/archive`; `queue_size` em bytes. O mesmo vale para o `otlphttp/langfuse`. Tray em SwiftBar lendo o bucket com DuckDB (cache local) e o Langfuse API para consumo.
- **Perda:** fecha P1 a P4; P5 e P6 continuam (ver §6).
- **Custo operacional:** quase zero (um volume Docker a mais por host).
- **Release:** **não**; só `config/otel/*.yaml`, `docker/compose.yaml` e um script/addon do tray.
- **Langfuse:** continua Cloud Hobby com 30 dias; o histórico longo fica no bucket (via DuckDB).
- **Conflitos:** nenhum. Rever o lifecycle para Archive aos 90 d (P9) se o DuckDB tiver de ler tudo.
- **Limite:** o tray tem atraso de 5 a 10 min. "Tudo no Langfuse" não é atendido.

### Opção B: A + collector central no oute-server + banco consultável (ClickHouse ou DuckDB materializado) + tray ao vivo
- **Muda:** tudo de A. Cada collector (Mac e oute-server) ganha um exporter `otlphttp` com fila persistente para um **collector central** no oute-server, exposto só no IP Tailscale. O central grava num banco (ex.: `clickhouseexporter`, beta) e serve o tray. O bucket continua sendo a fonte da verdade, e o banco pode ser reconstruído dele com o `awss3receiver`.
- **Perda:** igual a A no caminho do bucket; o caminho quente tem fila persistente dos dois lados.
- **Custo:** um serviço de estado a mais no oute-server (ClickHouse ≥ 8 GiB no perfil do Langfuse [11]) e o bind na tailnet (repo `lab`).
- **Release:** não, se tudo for config e compose; sim, se o tray ou um serviço entrar na imagem.
- **Conflitos:** o banco guarda **conteúdo**? Hoje conteúdo só vai ao bucket; isso seria uma decisão nova. Porta só na tailnet.
- **Fila externa:** desnecessária aqui; o collector central faz o papel de fronteira entre hosts. Se o Bardi quiser fan-out com replay, **Kafka/Redpanda** é o único broker com exporter **e** receiver OTel (beta). RabbitMQ exigiria um consumidor nosso e ficaria mais fraco no trecho de ida (§3.3).

### Opção C: Langfuse self-host como "banco de tudo" (atende literalmente "salvar tudo nele")
- **Muda:** Langfuse v4 self-host (web, worker, Postgres, ClickHouse, Redis, blob no OCI S3) no lugar do Cloud. O collector aponta `LANGFUSE_HOST` para ele, com fila persistente. Replay do histórico do bucket com o `awss3receiver` (traces). A fila interna já existe (Redis + S3) [8]: **não precisa de RabbitMQ**.
- **Perda:** a retenção fica infinita por padrão [1]. P1 a P4 fecham com a parte A.
- **Custo:** alto para o oute-server (a doc pede 4 vCPU/16 GiB; o host tem 4 vCPU e ~12 GiB livres [10][11]). A doc chama o compose de sem HA e sem backup [10], então **o Langfuse vira um banco a administrar** (backup do Postgres e do ClickHouse), mesmo tendo o bucket como fonte da verdade. Opções: VM OCI dedicada (arm64, fora do free tier atual) ou o Mac (não fica sempre ligado).
- **Release:** não (compose e config), mas é stack grande nova.
- **Conflitos:** "Langfuse só metadados" nasceu da governança do SaaS na UE. Self-hosted em São Paulo, o motivo muda, e o Bardi decide se o conteúdo passa a ir. Só traces entram pelo OTLP [12]: logs (prompts do Claude, eventos operacionais) seguem fora do Langfuse, então "tudo nele" continua parcial.

**Recomendação do agente (a decisão é do Bardi):** começar por **A**, que é barata, sem release e fecha a perda real (P1 a P4), com o tray em SwiftBar. Evoluir para **B** se o atraso de 5 a 10 min incomodar. Tratar **C** como decisão separada, de custo e hardware. **RabbitMQ não se paga aqui:** não há receiver OTel, o exporter é alpha, não tem fila persistente e vem com retry desligado, e o problema de durabilidade se resolve no próprio collector. Se um dia houver necessidade real de broker, a doc aponta Kafka/Redpanda [3][14].

## 5. Perguntas em aberto (decisões do Bardi)
1. **Langfuse:** continuar no Cloud Hobby (30 dias, histórico longo no bucket), pagar Core ou Pro (90 dias ou 3 anos; confirmar com o suporte se o upgrade reabre dado antigo) ou migrar para self-host?
2. Se self-host: **onde roda** (oute-server não cabe no mínimo da doc; VM OCI dedicada? custo?) e **quem faz o backup** do Postgres/ClickHouse?
3. Com Langfuse self-hosted, o **conteúdo** (prompts e respostas) passa a ir para ele, ou a allowlist de metadados continua?
4. O tray precisa ser **ao vivo** (segundos: Opção B) ou atraso de 5 a 10 min serve (Opção A)?
5. O banco consultável guarda **conteúdo** ou só metadados? Ele fica no oute-server, no Mac ou é só DuckDB local sobre o bucket?
6. **Lifecycle do bucket** (Archive aos 90 d, ADR-03): manter, mesmo que ler dado antigo passe a exigir restore, ou parar em Infrequent?
7. Rever a decisão "`oute-emit` sem spool" (P6) agora que o objetivo é "nenhuma perda", ou aceitar que a fonte local é a primária?
8. O tray só **mostra**, ou também **age** (ex.: abrir o `oute watch` para um pedido pendente)? Aprovar pelo tray mexe na fronteira do canal (ADR-01).
9. Acesso do Mac ao oute-server para o caminho quente: **bind no IP Tailscale** (mudança no `lab`) ou túnel SSH?
10. A regra "ferramenta nova só entra com consumo ao bucket + Langfuse" vale para banco e fila (que não consomem modelo)? A leitura do adendo #124 diz que não.

### 5.1 Respostas do Bardi (2026-09-27)
Direção decidida sobre esta nota. O detalhe de cada ponto vai para os tickets e ADRs seguintes.

- **Langfuse sai.** Em seu lugar entra o **oute-agent-studio**, que cobre as capacidades do Langfuse que usamos hoje. O studio usa **SurrealDB** para o que ele faz bem (dado do app, relações, estado) e **DuckDB** para o que ele faz bem (análise colunar sobre o volume de telemetria). Isso substitui partes do ADR-04 e a regra do `AGENTS.md` que cita o Langfuse, então precisa de ADR novo.
- **Atraso dos logs:** não precisa ser ao vivo, mas 5 min é muito; o alvo é 1 a 2 min. O caminho para o banco sai do lote de 5 min do bucket e pode ficar em segundos.
- **Tray no Mac (oute-agent-tray):** mostra **e age**. Uma capacidade futura, o **watch**, chama a API do studio de forma síncrona para disparar a ação. Aprovar fora do host muda o ADR-01 e exige API só na tailnet (nunca em `0.0.0.0`), autenticação e registro de quem aprovou.
- **Guardar tudo**, com conteúdo (prompts e respostas).
- **Bucket:** deixa de ser o lugar de onde se lê. **Fica** como arquivo frio e backup fora do host. A regra "telemetria no bucket nunca é apagada" continua valendo.
- **Logs assíncronos e sem perda:** o envio nunca bloqueia a fonte. A fila é um **buffer em disco em cada host**, que é o collector local com `file_storage` e retry sem limite, porque um broker central não protege o Mac sem rede. Dali o dado segue para a ingestão do studio (DB, em segundos) e para o bucket (lote maior). O `oute-emit` ganha um spool local para quando o collector estiver fora. **RabbitMQ fica de fora**; um broker só volta à mesa se aparecerem vários consumidores independentes.

```
agentes / oute-emit ──(assíncrono)──▶ collector local (fila em disco)
                                        ├─▶ ingestão do studio ──▶ SurrealDB + DuckDB   (segundos)
                                        └─▶ bucket (lote maior, arquivo frio)
tray/watch ──(síncrono)──▶ API do studio ──▶ ação
```

Próximo passo: mapa de decisões (`oute-aidlc-strat-wayfinder`) com as frentes collector sem perda, ingestão + bancos, studio, tray e watch.

## 6. O que não foi verificado
- Se o `docker compose down` (10 s de prazo) basta para o collector esvaziar o lote ao OCI.
- O comportamento real do batch da `sending_queue` com `flush_timeout` longo sobre `file_storage` (medir antes de adotar).
- Se o upgrade de plano no Langfuse Cloud reabre dados mais velhos que a janela do Hobby.
- Consumo real de RAM/CPU de um Langfuse v4 mínimo em arm64 (a doc não traz números por arquitetura).
- Consumo de requests do OCI com o DuckDB lendo o bucket direto (existe a franquia de 50 mil por mês).

## 7. Referências
1. Langfuse, *Data Retention*: https://langfuse.com/docs/administration/data-retention (acesso 2026-09-27)
2. OpenTelemetry Collector, *Exporter Helper README* (main): https://github.com/open-telemetry/opentelemetry-collector/blob/main/exporter/exporterhelper/README.md (acesso 2026-09-27)
3. OpenTelemetry, *Collector resiliency*: https://opentelemetry.io/docs/collector/resiliency/ (acesso 2026-09-27)
4. OpenTelemetry Specification, *OTLP Exporter: Retry* (erros transitórios com backoff exponencial, sem persistência exigida): https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/protocol/exporter.md
5. OpenTelemetry Specification, *Trace SDK: Batching processor* (`maxQueueSize`, padrão 2048, "spans are dropped"): https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/trace/sdk.md
6. Langfuse, *Pricing*: https://langfuse.com/pricing (acesso 2026-09-27)
7. Langfuse, *Self-host pricing* (OSS × Enterprise): https://langfuse.com/pricing-self-host
8. Langfuse, *Self-hosting overview* (arquitetura e fluxo de ingestão): https://langfuse.com/self-hosting
9. Docker Hub, `langfuse/langfuse-worker` tags (4.46.0, amd64 + arm64, 2026-09-25): https://hub.docker.com/r/langfuse/langfuse-worker
10. Langfuse, *Docker Compose deployment*: https://langfuse.com/self-hosting/deployment/docker-compose
11. Langfuse, *Scaling* (mínimos por componente): https://langfuse.com/self-hosting/configuration/scaling
12. Langfuse, *OpenTelemetry integration* (`/api/public/otel`): https://langfuse.com/integrations/native/opentelemetry
13. collector-contrib v0.161.0, `receiver/awss3receiver/README.md`: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/v0.161.0/receiver/awss3receiver
14. collector-contrib v0.161.0, `metadata.yaml` de cada componente (estabilidade: `kafkaexporter`/`kafkareceiver` beta; `rabbitmqexporter` alpha; `pulsarexporter` alpha; `awss3exporter`/`awss3receiver` alpha; `clickhouseexporter` beta traces/logs; `extension/storage/filestorage` beta; `natsexporter`, `natsreceiver`, `redisstreamexporter`, `redisstreamreceiver` inexistentes): https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/v0.161.0
15. collector-contrib v0.161.0, RabbitMQ: (a) `exporter/rabbitmqexporter/README.md` e `internal/publisher/publisher.go` (confirms); (b) `exporter/rabbitmqexporter/factory.go` (só `WithRetry`, sem queue); (c) `receiver/rabbitmqreceiver/README.md` (scraper do Management Plugin): https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/v0.161.0/exporter/rabbitmqexporter
16. Oracle, *Object Storage storage tiers* e *Restoring objects from Archive*: https://docs.oracle.com/en-us/iaas/Content/Object/Concepts/understandingstoragetiers.htm · https://docs.oracle.com/en-us/iaas/Content/Object/Tasks/managingobjects_topic-To_restore_objects_from_Archive_Storage.htm
17. RabbitMQ, *Reliability Guide*: https://www.rabbitmq.com/docs/reliability
18. RabbitMQ, *Streams*: https://www.rabbitmq.com/docs/streams
19. NATS, *JetStream*: https://docs.nats.io/nats-concepts/jetstream
20. DuckDB, *S3 API support* (httpfs; `ENDPOINT`, `URL_STYLE`): https://duckdb.org/docs/current/core_extensions/httpfs/s3api.html
21. DuckDB, *Hive partitioning*: https://duckdb.org/docs/current/data/partitioning/hive_partitioning.html
22. ClickHouse, *s3 table function*: https://clickhouse.com/docs/sql-reference/table-functions/s3
23. Apple, *MenuBarExtra* (SwiftUI, macOS 13.0+): https://developer.apple.com/documentation/swiftui/menubarextra
24. SwiftBar (README): https://github.com/swiftbar/SwiftBar
