# Fidelidade do P1 (Haiku): pedido-merge.md × p1-audit-457.md

**Veredito: fiel com ressalvas.** Números, achados, CI e o critério que falta batem com o original e com as fontes primárias.
Mas o artefato transforma "decisão deixada ao Bardi" em recomendação (⭐ na opção 2, "Recomendação (auditoria): não mergear agora"), e 3 citações `arquivo:linha` apontam para a linha errada.

## Contagens
- Fatos do original: 23. Mantidos: 14. Perdidos: 5. Mudou de sentido: 4. Inventados: 1.
- Afirmações do artefato conferidas: 24. Fonte confere: 18. Fonte não confere: 4. Sem fonte: 2.

## Defeitos

| # | tipo | artefato | original / fonte |
|---|---|---|---|
| 1 | mudou de sentido | "2. ⭐ Ensaiar uma rodada com o Codex antes de mergear" e "Recomendação (auditoria): não mergear agora" | audit:4 "merge NÃO feito … (decisão do Bardi, deixada para ele)"; audit:37 "não mergeado, por ordem da condução da rodada … Fica aberto para o Bardi". p3:12 dá as duas opções sem preferência. A auditoria registra que não fez o merge, mas não recomenda nenhuma das duas opções. |
| 2 | mudou de sentido | "Decisão declarada no PR: aceitável, mas o Bardi deve confirmar" | O "aceitável" é julgamento do auditor (audit:31, "SHOULD-FIX (julgamento)"). O PR só lista o item em "Decisões a conferir". O rótulo "(julgamento)" também se perdeu. |
| 3 | mudou de sentido (leve) | "testes da `main` (watch, sessoes, eventos, seletor, agente, prompts) passam sem edição … exceto 8 + 1 casos" | audit:13: watch/sessoes/eventos/seletor passam (54/120/69/43). As falhas 8 + 1 só aparecem quando `agente` e `prompts` rodam com o `tests/lib/swarm.sh` da `main`. O artefato deixa de fora essa condição e os números. |
| 4 | mudou de sentido (leve) | "Teste da renderização: `cmp` da saída de abertura … id e caminho normalizados" (cita audit:11) | O artefato mistura duas provas. audit:11 fala em renderizar o `swarm.md` com as mesmas substituições. O "`cmp` da saída de abertura, id e caminho normalizados" vem do corpo do PR. |
| 5 | inventado | O limite do `dispatcher_pane` aparece em "Para conferir depois (não bloqueia)" | Na auditoria, o `dispatcher_pane` faz parte do achado 1 (UNCERTAIN), que segura o merge (audit:30). No PR ele está em "## Falta". Nenhuma das duas fontes diz que "não bloqueia". |
| 6 | fonte não confere | "A issue #213 lista três estados: `idle`, `done` e `blocked` (p1-issue213.md:20)" | A linha 20 é o critério "o `watch` chega à coordenadora nos dois agentes". Os três estados aparecem no comentário de 2026-09-30 da issue (`gh issue view 213`). O fato é verdadeiro, mas a citação não. |
| 7 | fonte não confere | "dispatcher_pane … (p1-audit-457.md:35; limite conhecido do head)" | audit:35 são os contras (ensaio e falta de teste do `herdr agent list`). O limite está no "## Falta" do PR e, como dúvida, em audit:30. |
| 8 | fonte não confere | "Recomendação (auditoria): não mergear agora. Fundo: p1-audit-457.md" | Ver defeito 1: a auditoria não recomenda nenhuma das opções. |
| 9 | fonte não confere | "Decisão declarada no PR: aceitável" (cita p1-pr457.json) | O PR não diz "aceitável". |
| 10 | perdido | — | "Trust gate: livre" (audit:5). |
| 11 | perdido | — | "Reaproveitado do head: nada (primeira auditoria)" (audit:7). |
| 12 | perdido | — | Os testes do head rodaram em ambiente `env -i` (audit:12). |
| 13 | perdido | — | O link do relatório completo (p3:12, comentário 5976361202 do PR) e a nota de que o relatório não substitui a decisão do Bardi (audit:39). |
| 14 | perdido (detalhe) | Spec: "abertura com `--agent codex`"; superfície: "Só com o dispatcher `idle`/`done`" | Ficaram de fora "`agent=` no `meta`" (audit:23) e "campo achado e vazio" (audit:20). |

Sem fonte (2): a explicação da opção 1 ("o risco é descobrir defeito no ensaio") e "main na época; PR aberto de propósito". A segunda bate com p3:5.

## As 5 afirmações principais, conferidas na fonte primária
1. **CI verde no head 4b2cb9e:** `gh pr view 457` mostra o head `4b2cb9e69e4f…` e os checks `checks`, `CodeRabbit` e `SonarCloud Code Analysis` em SUCCESS. Confere.
2. **A entrega só ocorre com `idle`/`done` e campo vazio; `blocked` adia:** `refs/spike/pr457:docker/oute-swarm:790-791` (`idle|done) ;;` / `*) w_dlv_wait "dispatcher ocupado"`) e `:795` (campo com texto adia). Confere. O `tell` aceita `blocked` (`:428`), o que bate com o PR.
3. **A issue pedia `blocked` também:** o comentário de 2026-09-30 da #213 traz "parado (`idle`/`done`/`blocked`)". O fato confere, mas a citação no artefato aponta a linha errada (defeito 6).
4. **O prompt do Codex não usa `Monitor`/`run_in_background`:** em `refs/spike/pr457:docker/swarm.md:56,59`, as duas palavras só aparecem dentro de `@@CL@@…@@/CL@@`, e o trecho `@@CX@@` usa `nohup … &`. Confere, por leitura (não re-renderizei).
5. **Não há subagente em `swarm.md`/`swarm-worker.md`; sobram ocorrências nos addons:** o `git grep` no ref devolve só `addons/skills/oute-aidlc-arch-deepen/SKILL.md` e `oute-aidlc-design-modules/DESIGN-IT-TWICE.md`. Confere.

## Decisão
A decisão pedida é a mesma da p3:12: mergear e ensaiar depois, ou ensaiar antes. O problema é que o artefato marca uma das opções como recomendada e atribui essa recomendação à auditoria. Sobre o estado atual: o PR #457 já está **MERGED** (2026-10-04T09:15:38Z, merge `e83eb5e`). O artefato não menciona isso e apresenta a decisão como pendente. Ele diz "main na época", então parece escrito do ponto de vista da data da auditoria. Hoje a decisão está obsoleta.

## O que não consegui conferir
- Não refiz o `cmp` do prompt do Claude (base × head) nem as contagens de casos dos testes (91/36/176/…). As duas coisas vêm só da auditoria e do PR.
- Não conferi se o gate do SonarCloud passou exatamente no commit do head; vi só a conclusão SUCCESS do check.
- O artefato não cita nenhuma referência `arquivo:linha` de código; todas apontam para os arquivos de `in/`, e foram essas que conferi.
