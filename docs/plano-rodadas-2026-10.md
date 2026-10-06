# Plano de rodadas do `oute-swarm` (backlog de 2026-10-06)

**Estado:** proposta (#658). O Bardi decide, na triagem de cada rodada, o que abre. Nada aqui abre sessão sozinho.
**Base:** `main` em `794c979`, `VERSION` 0.7.43. As issues citadas foram lidas em 2026-10-06; o que muda depois disso muda este plano.
**Como usar:** o dispatcher lê a seção da rodada, confere o estado de cada issue (`gh issue view <n>`) e monta a triagem do `docker/swarm.md` §1. O Bardi aplica o label `ready` nas issues da rodada. Este arquivo não substitui a triagem.

## 1. O que a revisão fez

Eram 47 issues abertas. Ficaram 34 (mais as que outras sessões abriram depois).

### Fechadas como entregues ou desnecessárias (4)
| Issue | Motivo | Fonte |
|---|---|---|
| #489 | Épico entregue: as quatro fatias (#506 a #510) estão fechadas e a página da rodada, a do ciclo e a lista de ações existem. | `docker/agent-studio/agent_studio/etapas.py`, `acoes.py`, `marcar.py`@794c979 |
| #577 | Mínimo de 32 caracteres da credencial de marcação entregue. O limite de tentativas era opcional e não foi feito (recomendação do autor: dispensar). | PR #634 (`61255e6`) |
| #598 | Assinatura padrão, reservas e os dois modos entregues. O resto está na #621. | PR #616 (`4f9b433`) |
| #640 | Pedia corrigir o corpo de um PR já mergeado e avaliar sugestões do SonarCloud sem lista de arquivos. O ADR-02 já marca as repetições como "não verificadas". | `docs/adr/0002-roteamento-modelos.md:78`@794c979 |

### Consolidadas (9 fechadas como duplicadas, 6 sobreviventes)
| Sobrevivente | Absorveu | Por que juntar |
|---|---|---|
| #578 (bloco "antes de abrir o PR" do worker) | #579, #580, #631 | As quatro mudam só `docker/swarm-worker.md`. Quatro PRs no mesmo arquivo conflitam entre si. |
| #587 (três ajustes do dispatcher) | #642, #643 | As três mudam só `docker/swarm.md`. |
| #582 (skill de auditoria) | #646 | As duas mudam só `addons/skills/oute-aidlc-qa-pr-audit/SKILL.md`. |
| #592 (sobras do agent-studio) | #590 | Item de doc do ADR-08 sem decisão pendente. |
| #654 (limpeza de rodadas e handoffs, e alerta) | #604 | Mesma raiz: rodada antiga sem o evento de fechamento. |
| #460 (LLM do ai-memory) | #567 | A #567 dependia da #460 e só acrescentava um candidato e uma política de dados. |

### Editadas, sem fechar
- **#460:** perdeu o `blocked` (a #459 e a #458 estão fechadas) e ganhou os critérios do modelo gratuito.
- **#486:** o bloqueio foi reescrito. Falta só a #647. A variante do spike é anterior a regras novas das notas, então a leitura de fidelidade se refaz.
- **#348:** o critério falava em "90%"; o teto é 98% desde a #558.
- **#7:** o gatilho de upstream chegou (Vaultwarden 1.37.4, 2026-10-05). Falta atualizar o cofre, que é do repo `lab` (renatobardi/lab#263).
- **#570, #608, #621:** a parte de código está entregue. Sobra prova pós-release (seção 5).
- **#612, #455, #428:** labels ajustados (`later`; `swarm` e `needs-triage`; `agentes`, `spike` e `seguranca`).
- **#623, #651:** ganharam proposta de critérios, rotulada "recomendação do autor", para o Bardi aceitar ou trocar.

## 2. Regras da triagem que decidem a ordem

Do `docker/swarm.md` §1 (as que mais pesam aqui):
- Issue que muda **regra que todo PR segue** entra sozinha ou como primeiro elo: `AGENTS.md` (seções "Regras" e "Validar antes do PR"), formato do changelog e gates do CI. Aqui são #581 e #645.
- Issues escolhidas na mesma rodada não podem tocar os mesmos arquivos. Registro compartilhado (uma linha de tabela por issue) não conta.
- `blocked`, `later`, `spike` sem `ready` e issue que depende de outra aberta ficam fora. As issues dependentes abaixo trazem a linha `Depende de #<n>` no topo do corpo.
- Mais de 10 sessões por rodada exige aviso.

Do que o repo exige de PR:
- PR que muda `docker/agent-notes.md`, `docker/swarm.md` ou `docker/swarm-worker.md` roda a regressão dos agentes (`oute-regression`). Hoje ela reprova por qualquer tarefa vermelha, e três tarefas do Haiku já falham sem mudança. Por isso a #647 vem antes de todo PR de prompt.
- Mudança na imagem precisa de release; `scripts/oute`, `config/` e `docker/compose.yaml` não.
- Skill e `AGENTS.md` não precisam de release nem de regressão.

## 3. Limite de carga até a #623

A mitigação manual de 2026-10-05 vale até a #623 entrar: **uma sessão de worker por vez por rodada, no máximo duas rodadas com worker ao mesmo tempo**, teste local só dos arquivos tocados e suíte inteira no CI (fonte: [#623](https://github.com/renatobardi/oute-agent/issues/623)). As rodadas abaixo dizem "paralelas" para o que não conflita em arquivo; o dispatcher aplica o limite de carga por cima, com `--max 2` até a #623 ser mergeada. Depois dela, `--max` sobe para 4 (o número de núcleos, `nproc` = 4 medido em 2026-10-05).

## 4. Rodadas

Convenção: **Área** é o que decide conflito. **Release** = precisa de release depois do merge. **Reg.** = regressão obrigatória. **Gate** = o que o Bardi precisa dar antes de abrir.

### Rodada 0: regras comuns (em série, cada uma sozinha)
Comando: `oute-swarm oute-agent --label ready --max 1`.

| Ordem | Issue | Área | Release | Reg. | Gate |
|---|---|---|---|---|---|
| 1 | #581 mapa do repo em sub-itens | `AGENTS.md` (mapa) | não | não | `ready` |
| 2 | #645 `S3358` e `oute-sonar pr` depois do push | `AGENTS.md` ("Validar antes do PR") | não | não | `ready` |

Por que primeiro: a #581 tira o conflito que custou 3 heads e cerca de 11 a 14 minutos de CI por head nas rodadas `swarm-1004-1944` e `swarm-1005-1001` (evidência na própria #581). A #645 muda o que o worker confere antes do PR. Cada merge só vem depois do pedido do Bardi.

Em paralelo, sem sessão de worker: o Bardi decide a spec da #623 (seção 6, pergunta 1).

### Rodada A: base de carga e de regressão
Pré-condição: Rodada 0 mergeada. Comando: `oute-swarm oute-agent --label ready --max 2`, depois `--max 4` com a #623 mergeada.

| Issue | Área | Release | Reg. | Gate |
|---|---|---|---|---|
| #623 itens 1 e 3 (semáforo de teste e aviso de carga no `spawn`) | `tests/lib/`, laço de `tests/*.test.sh`, `docker/oute-swarm` | sim (`docker/oute-swarm`) | não (não muda prompt) | spec aceita |
| #647 regressão contra a linha de base | `docker/oute-regression`, `docker/regression/`, regra de merge em `docker/swarm.md` e `docker/swarm-worker.md` | sim | ela mesma cai na regra antiga: merge vai ao Bardi | já `ready` |
| #582 skill de auditoria | `addons/skills/oute-aidlc-qa-pr-audit/` | não (skill) | não | `ready` |
| #649 mensagem do `oute update` fora da branch padrão | `scripts/oute` (caso `update`) | não | não | já `ready` |
| #537 ack de alerta e de decisão | `agent_studio/` (rota, `ack_marks`), `docs/adr/0008-agent-studio.md` | sim | não | `ready` |

Sobreposição a evitar:
- #623 e #647 não se tocam em arquivo, mas a #623 mexe em `docker/oute-swarm`; a #578 (rodada B) também. Por isso a #578 espera.
- #649 e #518 mudam `scripts/oute`. A #518 fica para a rodada B, depois da #649.
- #537 e #592 mudam o ADR-08. A #592 fica para a rodada B.

Fim da rodada A: o Bardi faz a release (`scripts/release`) e o deploy. Sem ela, a #647 não tem efeito no host e o `(ship)` dela não roda.

### Rodada B: lições de prompt e sobras do studio
Pré-condição: #647 mergeada **e** em release (a regressão já compara com a linha de base). Comando: `oute-swarm oute-agent --label ready --max 4`.

| Issue | Área | Release | Reg. | Gate |
|---|---|---|---|---|
| #578 bloco "antes de abrir o PR" do worker | `docker/swarm-worker.md`, texto do `spawn` em `docker/oute-swarm`, `tests/oute-swarm-prompts-worker.test.sh` | sim | sim | `ready` |
| #587 três ajustes do dispatcher | `docker/swarm.md`, `tests/oute-swarm-prompts-dispatcher.test.sh` | sim | sim | `ready` |
| #650 fila do canal antes de release ou deploy | `docker/agent-notes.md`, skill `oute-aidlc-ship-release`, `tests/oute-swarm-prompts-notas.test.sh` | sim | sim | `ready` |
| #592 sobras do agent-studio (inclui ADR-08) | `agent_studio/prices.py`, `studio.css`, `docs/adr/0008-agent-studio.md` | sim | não | `ready`; depois do merge da #537 |
| #518 `oute update`: nova tentativa em "Address already in use" | `scripts/oute` | não | não | `ready`; depois do merge da #649 |

Cada PR de prompt roda a regressão (13 tarefas em Haiku e em Sonnet). A cota é consumida pela assinatura que a execução usa; a trava de 60% olha só essa assinatura (#598). Se a trava recusar (saída 3), o worker pára e avisa em vez de contornar. Três regressões em paralelo somam cota: o dispatcher abre os PRs de prompt em série se a cota 5h do Claude passar de 60% (`oute-quota`).

### Rodada C: studio, alertas e limpeza
Pré-condição: rodada B mergeada. Comando: `oute-swarm oute-agent --label ready --max 3`.

| Issue | Área | Release | Reg. | Gate |
|---|---|---|---|---|
| #591 tela expira em 120 s; "custo efetivo" com dois sentidos | `agent_studio/loading.py`, `cost.py`, ADR-08, `CONTEXT.md` | sim | não | o Bardi escolhe o nome novo do termo |
| #570 o que falta: `limit_mib` e resposta rápida na ingestão | `config/otel/collector.yaml`, `agent_studio/otlp.py` | não para o collector; sim para o código | não | medir antes (`EXPLAIN ANALYZE` numa cópia) |
| #589 teste `agent-studio-replay` instável | `tests/agent-studio-replay.test.sh`, `agent_studio/replay.py` | não, salvo causa em código | não | `ready` |
| #654 limpeza de rodadas e handoffs, alerta só com sessão viva | `agent_studio/alerts.py`; script do canal de aprovação (ação no host: **sim**) | sim | não | spec aceita; o Bardi aprova a lista antes da limpeza |

A #591 e a #570 podem tocar `docs/adr/0008-agent-studio.md`. O dispatcher confere na triagem e abre uma de cada vez se se tocarem.

### Pós-release: verificação (sessão avulsa, sem rodada)
Depois da release da rodada A e de cada release seguinte, uma sessão avulsa roda `oute-aidlc-ship-verify` e `oute-aidlc-ops-observe` e fecha com comentário:
- **#621:** `oute-task --prefer codex` abre no Codex quando a reserva é pedida.
- **#608:** `GET /v1/usage` mostra agente, modelo, tokens e custo para uma chamada `claude -p` da regressão e para uma do revisor das etapas.
- **#570:** `/`, `/v1/tray` e `/v1/usage` com janela de 24 h respondem abaixo de 60 s, e o tray do Mac volta a ler.
- **#647:** `oute-regression` na `main` sem mudança sai 0.

### Em paralelo e fora do swarm
- **#603 (logs sem `oute.agent`):** investigação só de leitura, com `oute-aidlc-ops-diagnose`, numa sessão avulsa. Não toca arquivo. Gate: o Bardi decide se vira PR.
- **#7:** quando o cofre estiver na 1.37.4 (renatobardi/lab#263), um PR de uma linha em `docker/Dockerfile` (`BW_CLI_VERSION`), com release. Entra na próxima release que já existir; não justifica uma só.

## 5. O que não entra em rodada (e por quê)

| Issue | Fase | O que falta | Quem |
|---|---|---|---|
| #448 tray aprova e recusa direto | `intent` | decisão que muda o ADR-01 e o ADR-08 §10: como provar que a decisão veio do Mac e não de um agente | Bardi |
| #460 LLM do ai-memory | `spec` | avaliação de qualidade em 20 sessões, política de dados do provedor "Stealth", decisão sobre o modelo capaz; ação no host | Bardi lê a avaliação antes de ligar |
| #565 trocar o Jev | `intent` | confirmar a intenção; depois o estudo comparativo e o adendo ao ADR-02 | Bardi |
| #629 GLM (Z.ai) | `arch` | adendo ao ADR-02 e ao ADR-01 (saída de dados à Z.ai) em PR de doc; depois o spike e a spec da fatia (a) | Bardi faz o merge do adendo |
| #651 trava de branch no checkout principal | `intent` | aceitar ou trocar os critérios propostos no comentário | Bardi |
| #652 regra que volta vira checagem | `intent` | critério de quando uma lição vira teste, lint ou hook; lista de candidatas: `rm` com variável, `local` e `return`, Sonar em arquivo tocado | Bardi |
| #653 modelo do dispatcher e do revisor | `intent` | ler `by_role` e `by_phase` da janela no `/v1/usage` e dizer quanto do Opus é dispatcher (análise só de leitura) | sessão avulsa e Bardi |
| #486 notas em inglês enxuto | `build`, `blocked` | #647 e #650 mergeadas; refazer a leitura de fidelidade contra o arquivo atual | depois da rodada B |
| #348 spike de cota | `plan`, `blocked` | pelo menos 3 dias de dado da métrica em produção | sessão avulsa quando houver dado |
| #368 `--resume` e workstream | `build`, `blocked` | teste com tty e decisão do Bardi sobre o padrão do `ai-memory run` | Bardi |
| #428 painel do herdr em `/bin/sh` | `spec` (spike) | segunda ocorrência ou reprodução no Mac | Bardi |
| #455 sessão no cabeçalho do pedido | sem fase | baixa prioridade; muda `docker/oute-swarm`, então só depois das rodadas A e B | Bardi |
| #612 tray como painel | `strat`, `later` | o Bardi usar o menu da #611 e decidir | Bardi |
| #630 Devin | `strat`, `later` | só depois da v1.0 | Bardi |

## 6. Decisões do Bardi, em ordem

1. **#623:** aceitar ou trocar a proposta de spec (semáforo global de teste, aviso de carga no `spawn`, repetição em série de teste de tempo). Sem isso, a rodada A só tem 4 issues e segue com `--max 2`. Recomendação do autor: aceitar os itens 1 e 3 já, e levar os itens 2 e 4 (regra de prompt) para dentro da #578.
2. **`ready`:** aplicar o label nas issues de cada rodada, uma rodada por vez. Recomendação do autor: começar pela rodada 0.
3. **#591:** escolher o nome novo de um dos dois sentidos de "custo efetivo".
4. **#651 e #652:** aceitar ou trocar os critérios, para entrarem na rodada C ou D.
5. **#460 e #565:** decidir em conjunto a política de dados do OpenRouter e se o seletor reusa a `OPENROUTER_API_KEY` do `agent` (`secrets/README.md:33`@794c979).
6. **#448:** manter o Terminal (decisão atual do ADR-08 §10) ou abrir o gate de `arch` para outra via.

## 7. Riscos do plano

- **A regressão pode demorar a ter valor.** A #647 depende de uma linha de base medida; a `docker/regression/` tem 13 tarefas e a medida custa cota. Sem a linha de base, as rodadas B e seguintes de prompt ficam paradas. Plano de contorno: o Bardi aceita merge de PR de prompt com a regressão vermelha só nas três falhas conhecidas do Haiku (`checkout`, `memory`, `segredo`), como fez no PR #625.
- **Rodada C depende de release da B.** Se a B atrasar, a C vira duas rodadas curtas.
- **Número de issues `kaizen` cresce mais rápido que o merge.** A #652 trata a causa. Até lá, o plano consolida lição por arquivo, como na seção 1.
- **Este plano envelhece.** Ele cita o estado de 2026-10-06. Antes de usar, o dispatcher confere `gh issue list --state open` e descarta o que já fechou.
