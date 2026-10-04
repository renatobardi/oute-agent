# Resumo do ciclo, 2026-10-04 01h10 (GMT-3): o Bardi decide e age de manhã

Fonte de tudo: o resumo do dispatcher em https://github.com/renatobardi/oute-agent/issues/437#issuecomment-5976459420 (chamado "o resumo" abaixo). Todo número vem do resumo; eu não o remedi.

## Decisão do Bardi

O Bardi decide três itens. Fonte: o resumo, seção "Ações do Bardi".

1. **PR #457 (#213, dispatcher com Codex).** A auditoria não achou nada crítico. O teste prova o caminho padrão (Claude) igual ao de antes. Falta o ensaio de uma rodada curta com `--agent codex`. Opções:
   1. Fazer merge e ensaiar depois.
   2. Ensaiar antes.
   O resumo não marca recomendação. Relatório: https://github.com/renatobardi/oute-agent/pull/457#issuecomment-5976361202
2. **Spike #429 (LLM do ai-memory pelo OpenRouter).** O Bardi lê o spike e decide se liga. O spike diz que funciona. O custo é ~US$ 0,0015 por sessão (fonte: resumo; não remedido). O modelo é `openai/gpt-oss-120b`. A consolidação escreve direto.
3. **#435 (política de handoffs).** O Bardi decide. A política muda o comportamento do ai-memory.

## Ações do Bardi, na ordem

Fonte: o resumo, seção "Ações do Bardi, na ordem".

1. **Release.** Aprovar no `oute watch` o pedido `20261004-041119-release-v0-7-35-scripts-release-push-da-`.
   - O pedido não faz deploy.
   - O pedido confere que a `main` está em `5109c44`.
2. **CI `image` da tag.** Esta é a primeira vez do teste de fumaça (#430).
   - Se o teste falhar por defeito dele, a imagem não é publicada.
   - Nesse caso, reverter `1a5e470` e republicar a tag.
3. **Deploy.** Rodar `oute update` nos dois hosts. Rodar quando as sessões do `frentes-engenharia` puderem cair. Depois, rodar `oute-aidlc-ship-verify`.
4. **Decidir o PR #457.** Ver "Decisão do Bardi", item 1.
5. **Ler o spike #429 e decidir.** Ver "Decisão do Bardi", item 2.
6. **Decidir a #435.** Ver "Decisão do Bardi", item 3.

## Feito nesta noite

Fonte: o resumo, seção "Feito nesta noite".

- A rodada `swarm-1003-2048` fechou 10 issues do ciclo: #427, #431, #432, #430, #425, #436, #426, #433, #429 e #434.
- A rodada fez 11 merges pela autorização repassada.
- A rodada executou e fez merge do kaizen #450 e do #451.
- A rodada `swarm-1004-0013` fez merge da #452 (PR #456).
- A #213 tem o PR #457 **aberto de propósito**.

O checklist da release 0.7.35 passou em tudo:
- changelog com 14 fragmentos e saída 0;
- pré-condições ok;
- CI verde nos 14 PRs;
- `agent-pins` ok;
- `models-check` com saída 0;
- nenhuma issue órfã;
- nenhum alerta de preço.

## Conferir depois do deploy (`(ship)`)

Fonte: o resumo, seção "Para conferir depois do deploy".

- #433: `/v1/usage` e a tela `/uso` mostram o custo dos dispatchers separado do custo dos workers.
- #426: `oute-sonar` está no PATH do dispatcher.
- #431, #436, #434, #450, #451, #452: o texto novo dos prompts está na imagem.

## Seguem abertas

Fonte: o resumo, seção "Seguem abertas".

- #213: o PR #457 espera decisão.
- #435: espera decisão.
- #428: precisa do Mac.
- #448 e #455: são novas e sem triagem. A #448 é da sessão do Mac.
- #368, #348 e #7: estão bloqueadas.

## Observações

Fonte: o resumo, seção "Observações".

- A consolidação do `swarm-worker.md` (#434) reduziu 12%. A meta era 30%. O PR explica.
- Na limpeza, o dispatcher cancelou 15 handoffs de sessões e rodadas já encerradas.
- A aba do dispatcher `r15` e a aba da sessão da #213 ficaram abertas. Elas esperam a decisão do #457.

## Conferência

Cada item do resumo e onde ele está. T = este texto, D = `p3-diagrama.svg`, P = `p3-pagina.html`.

| Item do resumo | T | D | P |
|---|---|---|---|
| Data e hora 2026-10-04 01h10 (GMT-3), "validar de manhã" | título | título e `<desc>` | cabeçalho |
| Rodada `swarm-1003-2048`, 10 issues (#427 #431 #432 #430 #425 #436 #426 #433 #429 #434) | Feito | não (fora do foco) | Feito |
| 11 merges pela autorização repassada | Feito | não | Feito |
| Kaizen #450 e #451 | Feito | caixa de verificação | Feito |
| Rodada `swarm-1004-0013`, #452 (PR #456) | Feito | caixa de verificação (#452) | Feito |
| #213 com PR #457 aberto de propósito | Feito | caixa #457 | Feito e decisão |
| Checklist 0.7.35 (14 fragmentos, saída 0, pré-condições, CI verde em 14 PRs, `agent-pins`, `models-check` 0, sem issue órfã, sem alerta de preço) | Feito | não | Feito |
| Ação 1: release, pedido `20261004-041119-release-v0-7-35-scripts-release-push-da-`, sem deploy, `main` em `5109c44` | Ações 1 | caixa 1 | Ações |
| Ação 2: CI `image`, teste de fumaça #430, reverter `1a5e470`, republicar a tag | Ações 2 | caixa 2 | Ações |
| Ação 3: `oute update`, dois hosts, `frentes-engenharia`, `oute-aidlc-ship-verify` | Ações 3 | caixas 3 e 4 | Ações |
| Ação 4: PR #457, #213, auditoria, caminho padrão, ensaio `--agent codex`, duas opções, link do relatório | Decisão 1 | caixa #457 | Decisão e Ações |
| Ação 5: spike #429, OpenRouter, US$ 0,0015, `openai/gpt-oss-120b`, consolidação escreve direto | Decisão 2 | caixa #429 | Decisão e Ações |
| Ação 6: #435, muda comportamento do ai-memory | Decisão 3 | caixa #435 | Decisão e Ações |
| Conferir: #433 (`/v1/usage`, `/uso`), #426 (`oute-sonar`), #431 #436 #434 #450 #451 #452 | Conferir | caixa 4 | Conferir |
| Abertas: #213, #435, #428, #448, #455, #368, #348, #7 | Abertas | caixa "Segue aberto" | Abertas |
| Obs.: #434 12% contra meta 30% | Observações | não | Observações |
| Obs.: 15 handoffs cancelados | Observações | não | Observações |
| Obs.: abas `r15` e da sessão da #213 | Observações | não | Observações |

O diagrama só cobre o que o Bardi faz e o que fica aberto, como a tarefa pediu. O resto está no texto e na página.
