## Pedido de merge: PR #457 — dispatcher com Codex e watch que digita

**Decisão do Bardi:** fazer merge do PR #457 ou não.

**Opções:**
1. Mergear agora e ensaiar uma rodada com o Codex depois. A feature funciona por teste; o risco é descobrir defeito no ensaio.
2. ⭐ Ensaiar uma rodada com o Codex antes de mergear. Resolve o achado `UNCERTAIN` e cumpre o critério de aceite da #213.

Recomendação (auditoria): não mergear agora. Fundo: p1-audit-457.md; opções: p3-437-cycle.md.

---

## Estado do PR

**Commit auditado:** `4b2cb9e` (base `5109c44`, main na época; PR aberto de propósito).

**CI:** checks pass, SonarCloud pass (gate OK), CodeRabbit pass. Mergeável, `CLEAN` (p1-audit-457.md:17).

**Testes:**
- Head rodou 91 casos do dispatcher, 36 agente, 176 prompts, 54 watch, 120 sessoes, 69 eventos, 43 seletor, 38 check-lib, 45 parallel-lib; todos rc 0 (p1-audit-457.md:12).
- Contra a `main`: testes da `main` (watch, sessoes, eventos, seletor, agente, prompts) passam sem edição quando rodados contra o código do head, exceto 8 + 1 casos do `--agent codex` (p1-audit-457.md:13). A PR declarou só 2 casos migrados; o resto explicado por mudança no `tests/lib/swarm.sh` (`opn` agora passa `HERDR_PANE_ID`) (p1-pr457.json).

**Caminho padrão (Claude):** byte a byte idêntico ao da `main`. O prompt do dispatcher sem `--agent` e com `--agent claude` sai igual. Teste da renderização: `cmp` da saída de abertura no head e na base, id e caminho normalizados, 0 marcadores `@@` restantes (p1-audit-457.md:11).

---

## Achados da auditoria

### Achado 1 — UNCERTAIN: ensaio com Codex pendente

A entrega do `watch` ao Codex, a fixação do `dispatcher_pane` na abertura e os subagentes do agente da rodada só se confirmam com ensaio real (p1-audit-457.md:30).

**Critério não atendido:** "ensaio de uma rodada curta com o Codex, registrado na issue" (issue #213, p1-issue213.md:23).

**Resolve:** rodar uma rodada curta com `--agent codex`. Precisa de sessão real do Codex no herdr (p1-audit-457.md:24).

---

### Achado 2 — SHOULD-FIX: `blocked` e campo com texto não recebem entrega

O PR recusa entrega quando o dispatcher está `blocked` ou o campo tem texto. O `watch --deliver` adia e a fila persiste (p1-pr457.json).

A issue #213 lista três estados: `idle`, `done` e `blocked` (p1-issue213.md:20). O PR entrega só com `idle`/`done` (p1-pr457.json, p1-audit-457.md:31).

**Decisão declarada no PR:** aceitável, mas o Bardi deve confirmar (p1-audit-457.md:31; p1-pr457.json: "Decisões a conferir").

---

## Superfície sensível

**Arquivos na imagem:** `docker/oute-swarm` e `docker/swarm.md`. O watch `--deliver` digita no campo do dispatcher com estratégia:
- Só com o dispatcher `idle`/`done`.
- Confere o campo antes do Enter.
- Texto dos eventos é dado; o `swarm.md` do Codex documenta isso.

Nenhuma rede, segredo ou privilégio novo (p1-audit-457.md:19-20).

---

## Spec da #213

Atendidos: abertura com `--agent codex`, agente como padrão, `watch` fora do agente sem laço próprio, fechamento 4.3 sem ai-memory com aviso, `swarm.md` sem ferramenta exclusiva do Claude no prompt do Codex, testes em `tests/`, fragmento do changelog (p1-audit-457.md:22-23).

**Não atendido:** ensaio registrado na issue (p1-audit-457.md:24).

**Closes × Refs:** PR usa `Refs #213` com `## Falta`; correto (p1-audit-457.md:25).

---

## Prós e contras

**Prós** (p1-audit-457.md:34):
- Caminho padrão (Claude) provado idêntico por teste; nenhuma mudança no prompt.
- Maioria dos ramos de erro testada (dispatcher ocupado, `blocked`, sem campo, campo com texto, fila longa, evento gigante, watch reiniciado).

**Contras** (p1-audit-457.md:35):
- Ensaio com o Codex pendente.
- Falta teste de `herdr agent list` falhando durante entrega.

---

## Para conferir depois (não bloqueia)

- Se `dispatcher_pane` mudar entre sessões, o watch adia com "nenhum agente no pane …" até reabrir (p1-audit-457.md:35; limite conhecido do head).
- O prompt do Codex não contém `Monitor` nem `run_in_background` (p1-audit-457.md:14).
- Subagentes: `git grep` não achou ocorrência de "subagente" no `swarm.md` ou `swarm-worker.md` do head (p1-pr457.json). Sobraram em addons (skills de `arch-deepen` e `design-modules`), fora do escopo (p1-pr457.json).

