# Fidelidade P2 (Sonnet): pedido do canal, volume do SurrealDB

**Veredito: `fiel com ressalvas`.** Os 18 fatos do original continuam no artefato e todas as linhas citadas apontam para o comando certo. O RESUMO lista todos os efeitos do script. As ressalvas: o CUIDADO do `rebuild-state` exagera o risco, e o RESUMO não diz que os passos 1 a 4 só rodam se o volume existir.

## Contagens
| fatos do original | mantidos | perdidos | mudou de sentido | inventados |
|---|---|---|---|---|
| 18 | 18 | 0 | 0 | 0 |

| afirmações do artefato (RESUMO + CUIDADO) | fonte confere | fonte não confere | sem fonte |
|---|---|---|---|
| 17 | 15 | 1 | 1 |

Os fatos do original são: o título (rotação, corrige o passo 2), a causa (o `oute-volume-init` parado prendia o volume), "apaga SÓ esse volume", o `oute up` sem ler o vault, a remontagem do estado, "não toca no DuckDB", "não recria o agent", a lista dos containers, a parada se aparecer um container inesperado, a parada do agent-studio (que tolera já estar parado), a parada e remoção dos containers, o `volume rm`, o ramo "já não existe", a conferência do volume do DuckDB, o `oute up`, a espera de 120 s com erro e `exit 1`, o `rebuild-state` com o esperado "pelo menos …" e a lista final.

## Conferência pedida
1. **`echo`:** todos dizem o mesmo que o original. O "em 120 s" acrescentado no ERRO é verdade (60 voltas × `sleep 2`). O "pelo menos" ficou. Nenhum `echo` afirma efeito que o script não tem.
2. **RESUMO, CUIDADO e linhas:** as linhas 15-22, 24, 25-29, 31, 10 e 37, 38-43, 45-47, 11 e 35, e 18-21 (o `case`) conferem com o original. Os efeitos estão todos lá: parar o agent-studio, parar e remover os containers, apagar o volume, o `oute up`, a espera, o `rebuild-state` e a lista. Nenhum efeito foi inventado.
3. **Ordem e gravidade:** os CUIDADOs seguem a ordem de execução. Cada um põe o comando e a linha primeiro e o risco depois. O do volume diz que o apagamento não se desfaz e que não há cópia, o que é o aviso certo para decidir. Sem ler o script, o Bardi vê o que é apagado (o volume do SurrealDB e os dois containers) e o que fica (o volume do DuckDB e o agent).
4. **Segurança falsa:** não há. "NÃO toca no volume do DuckDB" confere: o `rebuild_state.py` abre o DuckDB com `read_only=True`. "Sem ler o vault" também confere: em `scripts/oute:186`, o `oute up` só lê o vault com `--refresh-secrets` ou com o `agent.env` vazio.

## Defeitos
| tipo | artefato | original / fonte |
|---|---|---|
| fonte não confere (o risco está exagerado) | l. 58: "se ele falhar, o volume apagado não volta" | Quem recria o volume é o `oute up` (l. 37), antes do `rebuild-state`. O `rebuild_state.py` só acrescenta, e rodar de novo termina ("o que já entrou fica"). Os dados saem do DuckDB, que não é tocado. |
| omissão no RESUMO (ressalva) | passos 1 a 4 numerados como se sempre rodassem | l. 13 e 32-34: só rodam se o volume existir. O ramo `else` está só no `echo`. |
| sem fonte (o próprio artefato avisa) | l. 16: "os containers apagados vêm de novo pelo `oute up`" | A volta do `oute-surrealdb` é confirmada pela espera de saúde. A do one-off `oute-volume-init` eu não conferi. |
| omissão (ressalva) | o RESUMO não diz que o script sai com `exit 1` quando o SurrealDB não fica saudável, já com o volume apagado | l. 41 |

## O que não consegui conferir
- Se o `oute up` recria o `oute-volume-init` e o `agent` (isso depende do compose e do ambiente no host).
- Que o `rebuild-state` para e sobe o agent-studio de novo (`scripts/oute:464-469`). Nenhum dos textos fala disso, mas é efeito do subcomando, não do script.
- Os números esperados (rodadas=35 …) vêm só do original. Não há fonte para eles.
