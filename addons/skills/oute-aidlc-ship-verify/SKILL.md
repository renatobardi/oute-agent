---
name: oute-aidlc-ship-verify
description: Verificação pós-deploy do oute-agent num host (oute-server ou Mac) pelo canal de aprovação: versão, serviços e presença de telemetria. Use quando pedirem para conferir, verificar ou validar um deploy, uma release ou um `oute update`.
---

# oute-aidlc-ship-verify

Fase: `ship` (AI-DLC, ADR-07) · Outcome: deploy verificado em cada host, com evidência · Gate: o Bardi aceita o deploy (ou manda reverter).

Você **só lê**. O deploy (`oute update`, `oute down/up`) é do Bardi; esta skill não reinicia, não puxa imagem, não corrige nada no host. Falha vira relatório e, se for bug, `oute-aidlc-ops-diagnose`.

Três coisas, por host: **versão** (repo e imagem rodando), **serviços** do compose (com `oute-agent-studio` e `oute-surrealdb` no host que liga o profile `agent-studio`, o oute-server; nos outros o script diz que não conferiu) e **presença** de telemetria recente no bucket `oute-observability`. Presença é só "chegou objeto novo nos últimos minutos". Análise do que chegou (volume, erros, Langfuse) é da `oute-aidlc-ops-observe`; se ela não estiver instalada, reporte a presença e pare aí.

## 1. Alvo

- **Versão esperada:** a que o Bardi disse, ou `VERSION` da `main` (`git fetch --tags origin && git show origin/main:VERSION`). Deploy sem release (só `git pull`): a esperada é a mesma `VERSION`.
- **CI da imagem** (só com release): `gh run list --workflow image --limit 5` mostra o run da tag `v<esperada>` concluído com sucesso. Sem isso o host não tem o que puxar: reporte e pare.
- **Host:** o canal de aprovação leva ao host **onde este container roda** (`oute approve` roda nele). Para o outro host, a verificação sai de uma sessão no container de lá; diga ao Bardi qual host ficou sem conferir.

Feito quando: versão esperada, run da imagem e host estão anotados.

## 2. Propor a verificação

O script é `scripts/verify-host.sh`, nesta pasta da skill (no container: `/opt/oute/addons/skills/oute-aidlc-ship-verify/scripts/verify-host.sh`). Leia-o antes de propor: é o que o Bardi vai aprovar. Mande-o sem `--root`, com a versão na frente:

```bash
S=/opt/oute/addons/skills/oute-aidlc-ship-verify/scripts/verify-host.sh
{ printf 'EXPECTED=%q\n' '<esperada>'; cat "$S"; } \
  | OUTE_PROPOSE_AGENT=<claude|codex> oute-propose "ship: verificar deploy v<esperada>"
```

`WINDOW_MIN=<min>` na mesma linha do `EXPECTED` muda a janela da telemetria (padrão 60). Anote o `id` impresso e espere: `oute-inbox --wait <id>` (código 3 = ainda pendente ou expirou: avise o Bardi que o pedido está na fila do `oute approve` e espere de novo).

Feito quando: há um resultado com `# rc:` no inbox, ou o Bardi recusou (rc 126: reporte e pare).

## 3. Ler o resultado

Cada linha é `OK`, `AVISO` ou `FALHA`; a última é o resumo. Código 1 = alguma `FALHA`.

| Item | FALHA quer dizer | Próximo passo sugerido ao Bardi |
|---|---|---|
| repo | checkout do host fora da versão | `git pull --tags` no host (ou `oute update`) |
| imagem rodando | container com a imagem antiga | `oute pull` + `oute down/up` (ou `oute update`) |
| serviço | container parado, ausente ou `unhealthy` | `oute logs <serviço>`; se não for óbvio, `oute-aidlc-ops-diagnose` |
| telemetria | nenhum objeto novo em nenhum sinal na janela | `oute logs otel-collector`; credencial `oci-storage`; `oute-aidlc-ops-diagnose` |

`AVISO` não reprova o deploy, mas vai no relatório: reinício de container, um sinal sem objeto novo (host ocioso naquele sinal), erro de exportação no log do collector, `rclone` ausente.

Feito quando: cada linha `FALHA` e `AVISO` tem uma leitura e um próximo passo.

**Regressão dos agentes (opcional, sem canal):** quando a imagem ou um CLI (claude, codex) mudou, rodar `oute-regression` no container do host verificado (nível 1, #366: tarefas headless em Haiku, ~2 min; não passa pelo canal de aprovação, usa dublês). Saída 0 = verde; 1 = alguma tarefa vermelha (vai no relatório como `FALHA`, com a tarefa); 2 = não rodou (cota ≥ 60% ou sem login: `AVISO`). O resultado também vai ao agent-studio como `oute.regression.run`. Skill sem `oute-regression` na imagem (versão antiga): pule e diga no relatório.

## 4. Relatório

Uma mensagem por host verificado:

1. **Host e versão:** `host=<origem> instance=<instância>`, esperada × repo × imagem.
2. **Veredito:** `deploy verificado` (zero `FALHA`) ou `deploy com falha`.
3. **Achados:** as linhas `FALHA` e `AVISO`, com o próximo passo da tabela.
4. **Evidência:** o `id` do pedido e o resumo do script.
5. **Pendente:** host não verificado (passo 1), análise de telemetria (`oute-aidlc-ops-observe`).

Numa rodada do swarm, o relatório vai para o dispatcher. O que ficar pendente vira issue com `aidlc:ops` ou `aidlc:ship`.
