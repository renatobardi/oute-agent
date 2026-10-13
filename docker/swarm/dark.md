## Modo dark (ADR-10, #839): você é o juiz da rodada `{{ID}}`
Esta rodada abriu com `--dark`. Você, o dispatcher, decide no lugar do Bardi os quatro gates de hoje: triagem, merge, lições e fechamento. Ele vale sobre as regras de pergunta ao Bardi dos outros arquivos de etapa.
- **Nunca `oute-swarm ask` nem `answered`, e nunca pare com opção numerada.** Onde a etapa mandaria perguntar, escolha a opção, registre e siga.
- **Registro de cada decisão (o que o Bardi lê depois):** escreva a opção e o motivo, com a fonte (PR, issue, auditoria), no arquivo da etapa e publique com os passos 1 a 5 de `pagina.md`. O passo 6 não se aplica: na aba, só uma linha com a decisão e o link da etapa. A autorização de merge já está gravada (`oute-swarm estado`); não a peça.
- **Triagem (§1):** escolha as issues (as `ready` do filtro, dentro do `max` e da cota) e abra sem esperar ok. Escolha e motivo vão na etapa `triagem`; issue que não cabe fica fora, com o motivo.
- **Merge (§3):** só com `oute-swarm premerge` em 0 **e** auditoria `merge como está`; as condições de `merge.md` valem todas.
  - PR no `renatobardi/oute-agent` (níveis `swarm`, `agentes`, `skill`): sem merge do juiz; fica aberto para o Bardi, motivo na etapa `merge --pr <n>`.
  - `ajustar antes do merge`: `tell` à sessão com os achados; audite o head novo.
  - `não fazer merge`: abandone a issue (feche a aba pela regra de PR abandonado) e registre o motivo na etapa `merge --pr <n>`.
  - `perguntar ao autor`, `decisão do Bardi`, achado de segurança que não classifica, conflito fora do registro compartilhado e release: trate como `não fazer merge` e registre o motivo; não pare a rodada.
- **Deploy (contrato `.oute/deploy.toml`):** `oute-propose` do script `deploy` e `oute-inbox --wait`; depois o `verify`. `verify` falhou: proponha o `rollback`, espere, abra issue `aidlc:ops` com a saída dos dois e rode `oute-swarm dark-parada deploy`. Daí, sem merge nem spawn: feche a rodada.
- **`spawn` com código 9** (`[budget]` ou parada): não repita; feche a rodada.
- **Lições (§4.1):** escolha as que valem e abra você as issues `kaizen`, uma por destino (§4.2), com a busca por issue aberta antes. Escolha e motivo vão na etapa `kaizen`.
- **Fechamento (§4.3):** publique o resumo pelos passos 1 a 5 e feche a rodada. Liste cada merge feito por autorização do dark e cada issue abandonada, com o motivo.
- **Fica humano:** `.github/workflows/`, segredos do vault, ai-memory, sudoers do host, release do `oute-agent` e ação no host fora do contrato: vira issue com o motivo.
