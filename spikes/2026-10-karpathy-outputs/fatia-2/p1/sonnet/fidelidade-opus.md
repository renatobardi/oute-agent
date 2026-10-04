# Fidelidade do P1 (Sonnet): pedido de merge do PR #457

## Veredito: fiel com ressalvas
Os fatos, números, SHAs e referências `arquivo:linha` conferem com a auditoria e com as fontes primárias, e o merge já feito aparece como fato verificado (e confere). As ressalvas: o artefato recomenda a opção 1, que nem a auditoria nem o resumo do ciclo recomendam (ele avisa que a recomendação é dele); perde a condição da condução ("o merge só valia com o ensaio cumprido"); diz que "falta apenas o ensaio" depois do merge, mas o achado 2 também segue sem decisão.

## Contagens
- Fatos do original (auditoria): 23. Mantidos: 17. Perdidos: 5. Mudou de sentido: 1. Inventados: 0 entre os fatos (as afirmações sem fonte estão abaixo).
- Afirmações do artefato conferidas: ~34. Fonte confere: 30. Fonte não confere: 2. Sem fonte: 2.

## Defeitos
| tipo | artefato | original / fonte |
|---|---|---|
| perdido (condição) | "A recomendação da auditoria é só 'merge NÃO feito' por falta do ensaio" | "**Decisão:** não mergeado, por ordem da condução da rodada (o merge só valia com o ensaio cumprido)". A regra de que o merge dependia do ensaio some, e a opção 1 recomendada vai contra ela |
| sem fonte (recomendação) | "1) fazer merge agora e rodar o ensaio com o Codex depois (recomendada)" | A auditoria não recomenda nada ("decisão do Bardi, deixada para ele"), e o `p3-437-cycle.md` dá as duas opções sem marcar nenhuma. O artefato admite isso ("vem do peso dos fatos… é incerta"), então não esconde nada, mas pede a decisão com uma preferência que o original não tem |
| mudou de sentido | "Se foi você, falta apenas o ensaio (achado 1)." | Achado 2 (SHOULD-FIX): "Aceitável, mas o Bardi deve confirmar". Depois do merge seguem pendentes o ensaio **e** a confirmação das regras `blocked`/campo com texto |
| mudou de sentido | "A auditoria dá 176 para o `prompts` do head e diz que os da `main` falham 1 caso nele; a diferença entre as duas contagens não está explicada. Incerto." | Auditoria: os 8 + 1 falham "com os da main de `agente` e `prompts` **e o `tests/lib/swarm.sh` da main**; … altera também o `tests/lib/swarm.sh` (`opn`), o que explica a diferença". A explicação está na auditoria, e o próprio artefato a cita um item antes |
| fonte não confere | "O CodeRabbit não apareceu nessa saída; não verificado." | `gh pr view 457 --json statusCheckRollup` agora lista `CodeRabbit: SUCCESS` ao lado de `checks` e `SonarCloud Code Analysis`. Provavelmente o filtro da consulta deixou o CodeRabbit de fora |
| sem fonte / obsoleto | "Se quiser `blocked` na entrega: o PR precisa mudar o código e os testes antes do merge." | Isso não está no original. E, com o PR já mergeado (o que o próprio artefato registra), a mudança agora seria um PR novo, não uma mudança "antes do merge" |
| perdido | (ausente) | "Trust gate: livre" |
| perdido | (ausente) | "Reaproveitado do head: nada (primeira auditoria)" |
| perdido | (ausente) | "Mergeável, `CLEAN`" (perdeu o sentido depois do merge) |
| perdido | (ausente) | Prós: "maioria dos ramos de erro testada" |

## Decisão (passo 4)
A pergunta é a mesma do resumo do ciclo (ação 4: "mergear e ensaiar depois, ou ensaiar antes") e as opções também. A auditoria deixa a decisão para o Bardi, sem recomendação. A diferença é que o artefato marca a opção 1 como recomendada. O bloco "Estado atual" reformula bem a decisão diante do merge já feito ("vale só se esse merge não for o que você quer manter").

## As 5 afirmações principais, conferidas na fonte primária
1. PR `MERGED` por `renatobardi` em 2026-10-04T09:15:38Z, commit `e83eb5e`: `gh pr view 457` confere (`mergeCommit e83eb5e37c5f…`, também no `git log` local). O artefato apresenta isso como verificado ("conferido agora"), e está correto.
2. `docker/oute-swarm:789-790@4b2cb9e` aceita só `idle|done`: confere (789 `case "$st" in`, 790 `idle|done) ;;`).
3. `docker/oute-swarm:795@4b2cb9e` adia com o campo com texto: confere (`campo do dispatcher com texto (o Bardi digitando?)`).
4. "A issue lista `idle`, `done` e `blocked`": confere, mas no comentário de 2026-09-30 da #213 (`idle`/`done`/`blocked`), não no corpo da issue (`p1-issue213.md` não lista os estados).
5. Head `4b2cb9e…`, base `5109c44…` e diff de 8 arquivos (+394/−43): confere com `git rev-parse` e `git diff --stat 5109c44 refs/spike/pr457`. O link do relatório (`#issuecomment-5976361202`) existe e é a auditoria.

## O que não consegui conferir
- As contagens de teste (91/36/176/54/120/69/43/38/45, os 8 + 1 que falham), porque não rodei os testes de novo.
- O `cmp` do `swarm.md` renderizado (base × head) e a ausência de `Monitor`/`run_in_background` no prompt do Codex renderizado.
- Que a mudança pede release: confere com o AGENTS.md e com o `(ship)` do corpo do PR, mas não está na auditoria.
