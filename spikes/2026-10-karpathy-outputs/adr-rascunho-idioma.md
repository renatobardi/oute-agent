# ADR (rascunho) — Idioma e forma da saída, por público

Status: **rascunho do spike #458, não mergeado.** Este arquivo fica só no branch `spike/karpathy-outputs`. Ele vira ADR em `docs/adr/` se o Bardi aprovar, no gate de `arch`, com o número que ele der. As decisões abaixo são **propostas do autor do relatório**; nenhuma é decisão do Bardi.
Base: issue #458 (perguntas 10 a 13) e as três fatias do spike ([`README.md`](README.md)).

## Contexto

- O repo tem dois leitores. O Bardi lê ou aprova em 14 pontos ([`output-contract.md`](output-contract.md)). Os agentes leem prompts, notas e skills em toda sessão.
- Quase tudo está em pt. As exceções são 9 das 30 skills, que estão em inglês (medida da issue #458).
- Trocar o pt por inglês nos prompts reduz os tokens em 13,1% no Sonnet e no Opus, sem cortar conteúdo ([`fatia-1/tokens.tsv`](fatia-1/tokens.tsv)).
- O Bardi pôs duas prioridades (issue #458): no lado máquina, economizar sem perder qualidade; no lado humano, a qualidade da comunicação, sem restrição de custo.
- Nada hoje garante o pt-BR da saída ao Bardi. O sinal é implícito: as notas estão em pt (fatia 2, P4). O único `pt-BR` literal do repo fora do spike é o `lang` de um template (`git grep -n -E "pt-BR" -- docker addons docs CONTEXT.md AGENTS.md README.md config` dá `docker/agent-studio/agent_studio/templates/base.html:2`).

## Decisões propostas

### 1. Um documento, uma língua, uma fonte

**Nenhum documento do repo tem duas versões.** Não há par "fonte e tradução".

Motivo: a conferência de sentido entre dois textos é leitura, sem script. A skill que confere os resumos contra os ADRs diz isso (`addons/skills/oute-aidlc-ctx-sync/SKILL.md:10`: "A comparação é de **sentido**, não de texto: leia e julgue, sem script"). Uma tradução de cada ADR dobraria esse trabalho. Os 7 ADRs somam 173.454 bytes (`wc -c docs/adr/*.md`), e cada mudança num deles pediria a mesma mudança no par.

Quem precisa do texto em outra língua pede a tradução na hora. A tradução é descartável e não vai para o repo.

### 2. A língua de cada documento segue o leitor que decide

| Documento | Língua | Motivo |
|---|---|---|
| ADR (`docs/adr/`) | pt-BR | o Bardi aprova no gate de `arch` |
| `README.md`, `CONTEXT.md`, `CHANGELOG.md`, fragmentos de `changelog.d/` | pt-BR | o Bardi lê |
| Issue, corpo do PR, comentário de auditoria | pt-BR | o Bardi decide por eles (pontos 4, 5 e 7 do contrato) |
| `AGENTS.md` | pt-BR | os dois leem; o ganho em inglês é o menor medido (−9,0%) |
| `docker/comandos.md` | pt-BR | é o guia do `oute help`, lido pelo Bardi |
| Saída do `scripts/oute`, telas, tray e alertas do agent-studio | pt-BR | pontos 11 e 12 do contrato; já estão em pt |
| Comentário e `echo` de script proposto pelo canal | pt-BR | o Bardi lê o script inteiro antes de aprovar (ponto 8) |
| Prompts da imagem (`docker/swarm.md`, `docker/swarm-worker.md`, `docker/agent-notes.md`) | **inglês, depois da prova** | só o agente lê; ver a decisão 4 |
| Skills (`addons/skills/*/SKILL.md`) | **inglês, depois da prova** | só o agente lê; 9 já estão em inglês |
| `tell`, eventos do watch, handoffs, commits | sem mudança | ver [`lado-maquina.md`](lado-maquina.md) |

Regra de borda (pergunta 10): **se o Bardi lê ou aprova o texto, vale o lado humano.** Um texto que os dois leem fica em pt-BR.

### 3. A saída ao Bardi é em pt-BR, por regra escrita

Todo prompt, nota e skill que produz texto para o Bardi diz isso de forma explícita. A regra vale qualquer que seja a língua do prompt. O texto segue o PT controlado ([`pt-controlado.md`](pt-controlado.md)).

Esta regra entra **antes** de qualquer prompt mudar para inglês.

### 4. Prompt só muda de língua com prova

Um prompt, nota ou skill só passa para inglês quando as três condições valem:
1. a regressão cobre as regras do arquivo, e a variante não piora o resultado no modelo mais fraco em uso;
2. um revisor de outro modelo leu a variante regra por regra e não achou regra perdida;
3. a decisão 3 já está no arquivo.

Hoje nenhuma das três vale para nenhum arquivo. A regressão cobre 3 grupos de regra de cerca de 53 (fatia 2, P4).

### 5. O que é contrato não se traduz (pergunta 12)

Ficam como estão, em qualquer língua do texto em volta:
- os 53 labels do repo (`gh label list --limit 200 --json name -q 'length'`), entre eles `aidlc:<fase>`, `ready`, `kaizen` e `spike`;
- os nomes de evento e de atributo `oute.*` (por exemplo `oute.canal.proposed`, `oute.swarm.round.opened`);
- as tabelas do estado do agent-studio: `rodada`, `worker`, `sessao`, `pedido`, `conversa` (`docker/agent-studio/agent_studio/rebuild_state.py:28`);
- as tags do watch: `[sessao]`, `[aba]`, `[pr]`, `[ci]`, `[conflito]`, `[canal]`, `[aviso]` (`docker/swarm.md:56`);
- as marcas de fim de turno e de PR: `PRONTO #N`, `BLOQUEADO #N`, `Closes`, `Refs`, `## Falta`;
- o marcador `<!-- oute-aidlc-qa-pr-audit -->` e as severidades `CRITICAL`, `BLOCKING`, `SHOULD-FIX`, `NIT`, `UNCERTAIN`;
- nomes de comando, de arquivo e de variável.

Mudar um desses é mudança de produção, com teste e com migração. Este ADR não propõe nenhuma.

### 6. Legado: só o que for novo (pergunta 13)

Nada do histórico é traduzido: issues e PRs fechados, commits, o `CHANGELOG.md` e os ADRs aceitos ficam como estão. Um arquivo muda de língua quando um PR da decisão 4 o troca, e de uma vez só, sem versão mista.

## Consequências

- **Não há custo de sincronia entre línguas**, porque não há par.
- **O Bardi revisa prompt em inglês** nos PRs que mexem em `docker/*.md` e nas skills. O corpo do PR continua em pt-BR e explica a mudança.
- **O glossário do `CONTEXT.md` continua em pt.** Os termos dele que são contrato (`pedido`, `rodada`, `sessão`) aparecem em pt dentro do prompt em inglês, em crase. A variante b da fatia 1 fez isso com uma glosa (`fidelity.tsv`, linha do `swarm.md`).
- **A economia do lado máquina chega devagar**, arquivo por arquivo, atrás da regressão.

## Alternativas descartadas

- **Duas línguas com o pt como fonte e tradução automática.** Descartada pela decisão 1: a conferência é leitura, e o Bardi não precisa da tradução.
- **Tudo em inglês.** Descartada: contraria a prioridade do lado humano. O Bardi lê e decide em pt-BR.
- **Tudo em pt, como hoje.** Não é descartada: é o estado atual, e continua valendo enquanto a decisão 4 não for cumprida para algum arquivo.
- **ASD-STE100 a 80% nos prompts.** Descartada por ora: custa 6,5% mais tokens que o inglês direto no Sonnet e no Opus e não mostrou ganho na regressão ([`lado-maquina.md`](lado-maquina.md)).

## Em aberto

- Quem confere que a decisão 3 é cumprida. Hoje nenhuma tarefa da regressão mede a língua da saída.
- Se o `AGENTS.md` do `frentes-engenharia` segue este ADR. O spike só leu aquele repo.
