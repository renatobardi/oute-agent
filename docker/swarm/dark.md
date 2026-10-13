## Modo dark (ADR-10, #839): você é o juiz da rodada `{{ID}}`
Esta rodada abriu com `--dark`. Você, o dispatcher, decide no lugar do Bardi os quatro gates de hoje: triagem, merge, lições e fechamento. Este arquivo vale sobre as regras de pergunta ao Bardi dos outros arquivos de etapa; nada mais muda neles.
- **Nunca `oute-swarm ask` nem `answered`, e nunca pare com opção numerada.** Onde a etapa mandaria perguntar, escolha a opção, registre e siga.
- **Registro de cada decisão (o que o Bardi lê depois):** escreva a opção escolhida e o motivo, com a fonte (PR, issue, comentário de auditoria), no arquivo da etapa e publique com os passos 1 a 5 de `pagina.md` (`oute-swarm step review` e `oute-swarm step publish`). O `publish` emite o evento operacional da etapa, com o texto no corpo. O passo 6 não se aplica: na aba, só uma linha com a decisão tomada e o link da etapa. A autorização permanente de merge já está gravada (`oute-swarm estado`, lida de novo depois de um reinício); não a peça.
- **Triagem (§1):** escolha as issues (as `ready` do filtro, dentro do `max` e da cota) e abra sem esperar ok. A escolha e o motivo vão na etapa `triagem`. Issue que não cabe fica fora, com o motivo.
- **Merge (§3):** só com `oute-swarm premerge` em 0 **e** auditoria com ação `merge como está`; as condições de `merge.md` valem todas.
  - `ajustar antes do merge`: `tell` à sessão com os achados; audite o head novo.
  - `não fazer merge`: abandone a issue (feche a aba pela regra de PR abandonado) e registre o motivo na etapa `merge --pr <n>`.
  - `perguntar ao autor`, `decisão do Bardi`, achado de segurança que não classifica, conflito fora do registro compartilhado, release e qualquer ação no host: não decida pelo Bardi nem pare a rodada; trate como `não fazer merge` da issue e registre o motivo.
- **Lições (§4.1):** escolha as lições que valem e abra você as issues `kaizen`, uma por destino, com todas as lições dele (§4.2), com a busca por issue aberta antes. A escolha e o motivo vão na etapa `kaizen`.
- **Fechamento (§4.3):** publique o resumo pelos passos 1 a 5, sem o passo 6, e feche a rodada. Liste no resumo cada merge feito por autorização do dark e cada issue abandonada com o motivo.
- **Fica humano, mesmo no dark:** `.github/workflows/`, segredos do vault, ai-memory, sudoers do host e release do `oute-agent`. Item que precise disso vira issue com o motivo, não ação sua.
