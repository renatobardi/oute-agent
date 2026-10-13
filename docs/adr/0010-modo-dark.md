# ADR-10 — Modo dark do oute-swarm (rascunho)

Status: **rascunho** · 2026-10-12 · issue #839 (fase `intent`; este ADR fecha com o gate de `arch` do Bardi)

## Contexto
A rodada do `oute-swarm` cobre `plan` → `build` → `qa` → `learn` e para em quatro gates do Bardi: ok da triagem, merge, aplicar no host e escolha das lições (`docker/swarm.md`, "Fases do AI-DLC"). O ADR-07 diz que agente nenhum fecha fase com gate sem o ok explícito. O ADR-01 diz que o container não tem privilégio no host: o agente propõe (`oute-propose`) e o humano roda `oute approve`.

O Bardi quer uma rodada que vai da issue pronta ao deploy verificado sem pergunta (#839). Decisões dele na conversa de 2026-10-12: entrada = issue `ready`; alvo = repos do `/workspace` que não são o `oute-agent`; juiz Opus nos ex-gates, workers pela tabela de fase; ops manual vira pré-requisito da abertura; freios mantidos.

## Decisão (proposta)

| Tema | Decisão | Motivo |
|---|---|---|
| Abertura | `oute-swarm <repo> --dark [--budget N]`. Recusa `oute-agent` como alvo (código 7) e recusa quando falta pré-requisito (código 8, lista o que falta) | `oute down/up` mata a sessão que pediu (#210); ops manual é pré-requisito, não pergunta no meio |
| Pré-requisitos | (a) auto-aprovador ligado no host para a rodada; (b) contrato de deploy no repo alvo; (c) cota de todas as assinaturas abaixo da trava semanal; (d) `GH_TOKEN` com merge no repo | Sem (a) o deploy para no `oute approve`; sem (b) o juiz não sabe deployar; (c) e (d) são as recusas de hoje |
| Juiz | Sessão do dispatcher aberta com `--phase arch` (linha de raciocínio: `claude-opus-5-5`, reserva `gpt-6.1-sol`). Decide triagem, merge, lições e fechamento. Nunca roda `oute-swarm ask`; registra opção e motivo na página da rodada | Decisão 3 do Bardi (#839): juiz de fronteira, workers pela fase |
| Merge | Autorização permanente da rodada gravada na abertura (`oute-swarm estado --autorizacao "modo dark, #839"`), com as condições de hoje: auditoria `merge como está`, CI verde com SonarCloud, `premerge` código 0. `ajustar antes` volta à sessão; `não fazer merge` abandona a issue | Reusa `swarm/merge.md` sem afrouxar nenhuma condição |
| Auto-aprovador | Comando do host `oute approve --dark <rodada>`: fica em laço e roda só pedidos cujo cabeçalho traz `# rodada: <id>` e cujo script é um dos do contrato de deploy (comparado por hash). Pedido fora disso cai na fila manual. `oute-swarm stop <rodada>` desliga o laço | Fronteira nova, estreita: o host decide pelo hash do script, não pelo texto do agente |
| Contrato de deploy | Arquivo `.oute/deploy.toml` no repo alvo: `deploy`, `verify`, `rollback` (caminhos de script no repo), `host` (onde roda). O hash dos três scripts no commit mergeado é o que o auto-aprovador aceita | O repo diz como se deploya; o `oute-agent` não adivinha |
| Falha de deploy | `verify` falhou → `rollback` → issue `aidlc:ops` com a evidência → rodada para de fazer merge e fecha | Freio 6 do Bardi |
| Teto de custo | `--budget` em USD, lido do agent-studio a cada evento; passou, nenhum `spawn` novo | Freio 6 do Bardi |
| O que fica humano | `.github/workflows/`, segredos do vault, ai-memory, sudoers do host, release do `oute-agent` | `AGENTS.md` (escopo `workflow`, ADR-01, regra do ai-memory) |

## Opções descartadas
- **Dispatcher rodando no host.** Ganha privilégio direto, mas quebra a fronteira do ADR-01 para todo o resto da sessão. O auto-aprovador por hash dá o mesmo resultado com superfície menor. (recomendação do autor)
- **Tudo em Opus.** Mais caro e sem ganho medido no `build` (ADR-02, adendo #615 e #409 usam Sonnet no código). Decisão 3 do Bardi.
- **`oute-agent` como alvo desde já.** Exige continuação no host depois do `oute down/up`. Fica para a 2ª entrega.

## Em aberto (decide no gate de `arch`)
1. Formato do contrato: `.oute/deploy.toml` ou seção no `AGENTS.md` do repo alvo.
2. Onde o auto-aprovador roda quando o repo alvo deploya em outro host (o `oute approve` roda no host do container).
3. Fonte do custo para o `--budget`: agent-studio (ADR-08) ou soma do `oute-quota`.
