# ADR-09 — Idioma: um documento, uma língua; a língua segue o leitor que decide

Status: **aceito** (2026-10-04, #483; decisão do Bardi depois do spike #458). Não substitui nem altera outro ADR.
Base: spike #458 (perguntas 10 a 13 e as três fatias). Rascunho: [adr-rascunho-idioma.md@672df2f](https://github.com/renatobardi/oute-agent/blob/672df2f/spikes/2026-10-karpathy-outputs/adr-rascunho-idioma.md). Medidas: [`fatia-1/tokens.tsv`](https://github.com/renatobardi/oute-agent/blob/672df2f/spikes/2026-10-karpathy-outputs/fatia-1/tokens.tsv) e [`lado-maquina.md`](https://github.com/renatobardi/oute-agent/blob/672df2f/spikes/2026-10-karpathy-outputs/lado-maquina.md).

## Contexto
- O repo tem dois leitores. O Bardi lê ou aprova texto em 14 pontos ([`output-contract.md`](https://github.com/renatobardi/oute-agent/blob/672df2f/spikes/2026-10-karpathy-outputs/output-contract.md)). Os agentes leem prompts, notas e skills em toda sessão.
- Quase tudo está em pt. As exceções são 9 das 30 skills, que estão em inglês (medida da #458).
- Trocar o pt por inglês nos prompts reduz os tokens em 13,1% no Sonnet e no Opus, sem cortar conteúdo (`fatia-1/tokens.tsv`).
- O Bardi pôs duas prioridades (#458): do lado máquina, economizar sem perder qualidade; do lado humano, qualidade da comunicação, sem limite de custo.
- Nada garantia o pt-BR da saída ao Bardi: o sinal era implícito, porque as notas estão em pt. A regra escrita entrou com o `docs/pt-controlado.md` (#478).

## Decisões

### 1. Um documento, uma língua, uma fonte
Nenhum documento do repo tem duas versões. Não há par "fonte e tradução".

Motivo: a conferência de sentido entre dois textos é leitura, sem script (`addons/skills/oute-aidlc-ctx-sync/SKILL.md`: "A comparação é de **sentido**, não de texto"). Uma tradução de cada ADR dobraria esse trabalho. Quem precisa do texto em outra língua pede a tradução na hora. A tradução é descartável e não vai para o repo.

### 2. A língua de cada documento segue o leitor que decide
| Documento | Língua |
|---|---|
| ADR (`docs/adr/`), `README.md`, `CONTEXT.md`, `CHANGELOG.md`, fragmentos de `changelog.d/` | pt-BR |
| Issue, corpo do PR, comentário de auditoria | pt-BR |
| `AGENTS.md`, `docker/comandos.md` | pt-BR |
| Saída do `scripts/oute`, telas, tray e alertas do agent-studio | pt-BR |
| Comentário e `echo` de script proposto pelo canal | pt-BR |
| Prompts da imagem (`docker/swarm.md`, `docker/swarm-worker.md`, `docker/agent-notes.md`) | inglês, **só depois da prova** (decisão 4) |
| Skills (`addons/skills/*/SKILL.md`) | inglês, **só depois da prova** (decisão 4) |

Regra de borda: se o Bardi lê ou aprova o texto, vale o pt-BR. Um texto que os dois leem fica em pt-BR. Até a prova, os prompts e as skills ficam como estão.

### 3. A saída ao Bardi é em pt-BR, por regra escrita
Todo prompt, nota e skill que produz texto para o Bardi diz isso de forma explícita. A regra vale qualquer que seja a língua do prompt. O texto segue o PT controlado (`docs/pt-controlado.md`). Esta regra entra antes de qualquer prompt mudar de língua.

### 4. Prompt só muda de língua com prova
Um prompt, nota ou skill só passa para inglês quando as três condições valem:
1. a regressão cobre as regras do arquivo, e a variante não piora o resultado no modelo mais fraco em uso;
2. um revisor de outro modelo leu a variante regra por regra e não achou regra perdida;
3. a decisão 3 já está no arquivo.

O arquivo muda de uma vez, sem versão mista.

### 5. O que é contrato não se traduz
Fica como está, em qualquer língua do texto em volta:
- os labels do repo (`aidlc:<fase>`, `ready`, `kaizen`, `spike`…);
- os nomes de evento e de atributo `oute.*`;
- as tabelas do estado do agent-studio: `rodada`, `worker`, `sessao`, `pedido`, `conversa`;
- as tags do watch: `[sessao]`, `[aba]`, `[pr]`, `[ci]`, `[conflito]`, `[canal]`, `[aviso]`;
- as marcas de fim de turno e de PR: `PRONTO`, `BLOQUEADO`, `Closes`, `Refs`, `## Falta`;
- o marcador `<!-- oute-aidlc-qa-pr-audit -->` e as severidades `CRITICAL`, `BLOCKING`, `SHOULD-FIX`, `NIT`, `UNCERTAIN`;
- nomes de comando, de arquivo e de variável.

Mudar um desses é mudança de produção, com teste e com migração. Este ADR não propõe nenhuma.

### 6. Legado: só o que for novo
Nada do histórico é traduzido: issues e PRs fechados, commits, o `CHANGELOG.md` e os ADRs aceitos ficam como estão. Este ADR não traduz nenhum arquivo.

## Consequências
- Não há custo de sincronia entre línguas, porque não há par.
- O Bardi revisa prompt em inglês nos PRs que mexem em `docker/*.md` e nas skills. O corpo do PR continua em pt-BR.
- O glossário do `CONTEXT.md` continua em pt. Os termos dele que são contrato (`pedido`, `rodada`, `sessão`) aparecem em pt, entre crases, dentro de prompt em inglês.
- A economia do lado máquina chega devagar, arquivo por arquivo, atrás da regressão.

## Alternativas descartadas
- **Duas línguas, com o pt como fonte e tradução automática.** Descartada pela decisão 1: a conferência é leitura, e o Bardi não precisa da tradução. Foi a ideia inicial; o Bardi a trocou por esta.
- **Tudo em inglês.** Descartada: contraria a prioridade do lado humano.
- **Tudo em pt.** É o estado atual e vale para cada arquivo até a decisão 4 se cumprir nele.
- **ASD-STE100 a 80% nos prompts.** Não recomendada: custa 6,5% mais tokens que o inglês direto no Sonnet e no Opus, sem ganho medido na regressão.

## Em aberto
- Quem confere que a decisão 3 é cumprida. Hoje nenhuma tarefa da regressão mede a língua da saída.
- Se o `AGENTS.md` do `frentes-engenharia` segue este ADR. O spike só leu o `oute-agent`.
