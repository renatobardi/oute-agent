# Fidelidade P2 (Haiku): pedido do canal, volume do SurrealDB

**Veredito: `fiel com ressalvas`, no limite.** Nenhum comando mudou e nenhuma afirmação de segurança é contradita pelo script. Mas o artefato perdeu dois fatos ("o passo 2 falhou" e "sem ler o vault") e mudou o sentido de dois ("pelo menos" virou um valor exato, e "não recria o agent" virou "não toca as variáveis do agent"). Os CUIDADOs tranquilizam em vez de avisar: o do volume não diz que os dados se perdem.

## Contagens
| fatos do original | mantidos | perdidos | mudou de sentido | inventados |
|---|---|---|---|---|
| 18 | 14 | 2 | 2 | 0 |

| afirmações do artefato (RESUMO + CUIDADO + `echo` novo) | fonte confere | fonte não confere | sem fonte |
|---|---|---|---|
| 18 | 15 | 2 | 1 |

A lista dos fatos é a mesma da revisão do Sonnet: título, causa, "SÓ esse volume", sem vault, remontar, DuckDB, agent, lista, parada, agent-studio, remoção, `volume rm`, ramo `else`, conferência do DuckDB, `oute up`, espera e `exit 1`, `rebuild-state` com "pelo menos" e a lista final.

## Conferência pedida
1. **`echo`:**
   - l. 22: o "o passo 2 falhou" saiu.
   - l. 23: o "sem ler o vault" saiu e entrou "oute up lê services.env". O fato novo é verdadeiro (`scripts/oute:188`, `load_services_env`), mas o aviso que o original dava, de que o vault não é aberto, se perdeu.
   - l. 59: o "pelo menos" saiu, e os números viraram valores exatos. Com isso, um resultado certo e maior pode parecer falha.
   - Os outros `echo` dizem o mesmo que o original.
2. **RESUMO e linhas:** as linhas 18-21, 24, 27-28, 31, 35, 37, 40-43 e 45 conferem com o original. Os efeitos estão listados. Mas o "O que muda" não cita a parada do agent-studio nem a remoção do `oute-volume-init`. "Verifica que o volume do DuckDB permanece intacto" (l. 35) exagera: a linha só confere se o volume existe, e uma falha ali não para o script (`&&` com `set -e`).
3. **Ordem e gravidade:** há só 2 CUIDADOs, e nenhum cobre a parada do agent-studio, o `oute up` ou o `rebuild-state`. Os dois começam pelo comando, mas o que vem depois é uma garantia ("a validação garante…"), não um risco. O CUIDADO do `volume rm` não diz que o apagamento é irreversível nem que não há cópia, e esse é o aviso que importa para o [s]/[N]. O RESUMO deixa ver o que é apagado (o volume) e o que fica (o DuckDB).
4. **Segurança falsa:** não achei afirmação que o script contradiga. "Só containers validados podem usá-lo" é verdade: o `docker volume rm` falha se o volume ainda estiver em uso, e o `set -e` para o script. "NÃO muda o DuckDB" confere (`rebuild_state.py`, `read_only=True`). Ainda assim, "nenhum container inesperado será afetado", lido fora do contexto do volume, choca com a parada do `oute-agent-studio` duas linhas antes, que não está na lista validada.

## Defeitos
| tipo | artefato | original / fonte |
|---|---|---|
| perdido | l. 22: "O volume $VOL estava preso por outro container…" | l. 9: "o passo 2 falhou: …" |
| perdido | l. 23: "(oute up lê services.env com a senha nova)" | l. 10: "oute up, sem ler o vault: o services.env já tem a senha nova" |
| mudou de sentido | l. 59: "esperado depois: rodadas=35 …" | l. 44: "esperado em 'depois': pelo menos rodadas=35 …" (piso, não valor exato) |
| mudou de sentido / sem fonte | RESUMO l. 17: "O que NÃO toca: … variáveis do agent" | l. 11: "nem recria o agent (o ambiente dele não mudou)". O original fala de recriar o container, não de variáveis. |
| fonte não confere | RESUMO l. 13: "Verifica que o volume do DuckDB permanece intacto" | l. 35 só confere se o volume existe, e a falha não interrompe o script |
| fonte não confere (gravidade) | l. 44: CUIDADO do `volume rm` só com garantia, sem o risco de perda de dados | l. 31: apagamento sem cópia. O dado só volta pelo `rebuild-state` a partir do DuckDB. |
| omissão | o RESUMO "O que muda" não cita a parada do agent-studio, a remoção do `oute-volume-init`, o ramo "volume já não existe" nem o `exit 1` sem saúde | l. 24, 25-29, 32-34, 41 |

## O que não consegui conferir
- Se o `oute up` recria o `oute-volume-init` e o `agent` (isso depende do compose e do ambiente no host).
- Os números esperados (rodadas=35 …) vêm só do original. Não há fonte para eles.
