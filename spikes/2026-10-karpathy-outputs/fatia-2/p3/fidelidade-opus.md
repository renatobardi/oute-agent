# Fidelidade do P3 (spike #458), artefatos Sonnet: revisão Opus

Original: resumo do ciclo no comentário 5976459420 da #437 (criado em 2026-10-04T04:11:37Z). Lista de fatos do original (47): data e hora; as 2 rodadas; as 10 issues; 11 merges; kaizen #450/#451; #452 pelo PR #456; #457 aberto de propósito; checklist 0.7.35 e seus 7 itens; ação 1 (id do pedido, sem deploy, `main` em `5109c44`); ação 2 (primeira vez do teste de fumaça #430, se falhar por defeito do teste a imagem não sai, reverter `1a5e470` e republicar a tag); ação 3 (`oute update` nos dois hosts, condição do `frentes-engenharia`, depois `ship-verify`); ação 4 (auditoria sem crítico, caminho Claude provado por teste, falta rodada curta com `--agent codex`, 2 opções, link do relatório); ação 5 (ler, OpenRouter, funciona, US$ 0,0015, modelo, consolidação escreve direto, decidir se liga); ação 6 (#435, muda o ai-memory); ordem 1 a 6; 3 itens de conferência pós-deploy; 5 linhas de "Seguem abertas"; 3 observações.

## 1. `p3-texto.md`

**Veredito: fiel com ressalvas.** Os 47 fatos estão todos lá, com o mesmo sentido, e as duas opções do #457 vêm sem recomendação. A ressalva está na tabela "Conferência" do fim: ela afirma sobre o diagrama coisas que o SVG não tem.

Contagens: fatos do original 47; mantidos 47; perdidos 0; mudou de sentido 0; inventados 0. Afirmações do artefato conferidas: 30 (os 47 fatos agrupados por item, mais as 19 linhas da tabela "Conferência"); fonte confere 27; fonte não confere 3; sem fonte 0.

| Tipo | Trecho do artefato | Original ou fonte |
|---|---|---|
| fonte não confere | Tabela: "Data e hora 2026-10-04 01h10 … \| D: título e `<desc>`" | O `<title>` e o `<desc>` do SVG não têm data nem hora, e o diagrama inteiro também não. |
| fonte não confere | Tabela: "Ação 4: PR #457, #213, auditoria, caminho padrão, ensaio `--agent codex`, duas opções, link do relatório \| D: caixa #457" | A caixa #457 do SVG só tem "Dispatcher com Codex" e as opções A/B. Faltam a auditoria, o caminho padrão, "rodada curta" e o link. |
| fonte não confere | Tabela: "#213 com PR #457 aberto de propósito \| D: caixa #457" | O SVG não diz "aberto de propósito". |
| nota (não é defeito) | "O teste prova o caminho padrão (Claude) igual ao de antes." | "caminho padrão (Claude) provado igual por teste". O "ao de antes" interpreta o original, mas é a leitura natural. |
| nota (ordem) | A seção "Decisão do Bardi" vem antes de "Ações, na ordem". | No original, as decisões são as ações 4 a 6, depois de release, CI e deploy. A lista de ações mantém a numeração, então o sentido não muda, mas a ênfase muda. |

## 2. `p3-diagrama.svg`

**Veredito: fiel com ressalvas.** A cadeia release → CI `image` → deploy → verificação, as 3 decisões e todos os itens abertos estão lá. Não há seta inventada: o próprio diagrama diz que as decisões não dependem da cadeia. Ressalvas: a caixa #457 perde a base da decisão, a caixa #429 perde "funciona"/"ler o spike", não há data, os crases de Markdown aparecem literais e um texto pode sair da caixa.

Escopo considerado: o que a tarefa pedia (ações 1 a 6, ordem, conferência pós-deploy, abertas), ou seja, 29 fatos. O "Feito" e as observações ficaram fora por escolha declarada e não contam como perdidos.

Contagens: fatos no escopo 29; mantidos 24; perdidos 5 (1 deles parcial); mudou de sentido 0; inventados 0. Afirmações do artefato: 22; fonte confere 22; fonte não confere 0; sem fonte 0.

(a) **Setas que o original não declara:** nenhuma. Há só 3 setas (1→2→3→4), e o título diz "a seta mostra a ordem do original". O original numera as ações "na ordem" e diz "Depois, `oute-aidlc-ship-verify`". A tag que o CI usa sai da release, então a seta 1→2 também é real. Há duas simplificações. A caixa 4 junta o `ship-verify` (fim da ação 3) com a seção "Para conferir depois do deploy", o que é uma junção razoável. O ramo de falha do CI (reverter e republicar) aparece como texto, sem seta própria. Nenhuma das duas inventa fato.

(b) **Itens perdidos no escopo:**

| Tipo | Trecho do artefato | Original |
|---|---|---|
| perdido | Caixa "PR #457 (#213)": só "Dispatcher com Codex" e as opções A/B | "auditoria sem achado crítico" |
| perdido | idem | "caminho padrão (Claude) provado igual por teste" |
| perdido (parcial) | "Opção B: ensaiar antes (`--agent codex`)" | "falta o ensaio de uma rodada curta com `--agent codex`" (perdeu "falta" e "rodada curta") |
| perdido | Não há link do relatório. | https://github.com/renatobardi/oute-agent/pull/457#issuecomment-5976361202 |
| perdido | "Ligar o LLM do ai-memory pelo OpenRouter?" | "**Ler** o spike … **funciona** … e decidir se liga" |

A data e a hora (01h10, "validar de manhã") também não aparecem. Isso é menor, porque o diagrama vai dentro da página, que tem a data.

(d) **Problemas que o leitor veria:**
- Os crases de Markdown saem literais no SVG: "`oute watch`", "`main`", "`(ship)`", "`openai/gpt-oss-120b`;", "`--agent codex`". O leitor vê os acentos graves.
- Texto que pode sair da caixa: estimei a largura com as métricas da Arial a 13px. "consolidação escreve direto." ocupa uns 171 px num espaço de 178 px (caixa de 190, começando 12 px dentro). Com uma fonte sans mais larga (DejaVu, o padrão no Linux), passa uns 10% e cruza a borda direita. As linhas largas das caixas de 600 px (até uns 460 de 586 px) têm folga.
- Tema: o SVG não tem retângulo de fundo. No escuro, os títulos soltos ("Cadeia do Bardi…", "3 decisões…") ficam `#e6edf5`. Se o SVG for aberto à parte num visualizador de fundo claro com o sistema em modo escuro (ou o contrário), esses títulos somem. Dentro das caixas, o contraste é bom nos dois temas.

## 3. `p3-pagina.html`

**Veredito: fiel com ressalvas.** A página tem o mesmo conteúdo do texto, sem perder nem inventar nada contra ele ou contra o original (47/47). As ressalvas vêm do SVG embutido (crases literais, ilegível no celular, mesmas perdas da caixa #457) e da ordem decisão-antes-da-ação, igual à do texto.

Contagens: fatos do original 47; mantidos 47; perdidos 0; mudou de sentido 0; inventados 0. Afirmações do artefato: 30; fonte confere 30; fonte não confere 0; sem fonte 0.

(c) **Contra o texto:** nada perdido nem inventado. A página não traz a tabela "Conferência", então não herda as 3 afirmações erradas dela. "(guardado só neste navegador)" descreve o próprio script e está correto.

(d) **Problemas que o leitor veria:**
- No celular, o SVG fica ilegível. Com `svg{width:100%}` num `main` de 720 px, numa tela de 375 px o viewBox de 640 vira uns 343 px (escala 0,54), e o texto de 13px cai para uns 7px. O diagrama precisaria de outro layout, ou de rolagem, abaixo de uns 500 px. O resto da página quebra bem: o `code` tem `overflow-wrap:anywhere` (o id longo do pedido quebra), o padding é de 16px e não há largura fixa fora do SVG.
- Os crases literais dentro do SVG (como acima).
- O `<style>` do SVG inline vale para o documento inteiro (`.b .k .o .t .s .m .a .ah`). Hoje nenhuma classe da página colide, então não quebra nada, mas é frágil.
- Contraste: `--mut` `#4a5a6c` sobre `#fff` e sobre `#fff4dc` dá uns 6:1, e no escuro `#a5b4c4` sobre `#10161e` também passa. Não há `data-theme` para forçar o tema, só `prefers-color-scheme`. Isso não quebra para o leitor.
- JS sem `localStorage`: o `getItem` e o `setItem` estão em `try/catch`. Se o `localStorage` não estiver definido, o `ReferenceError` cai no `catch`. As caixas de marcar funcionam e só não persistem. Não quebra.

## Reconferência das 5 afirmações principais contra a fonte primária (gh/git, só leitura)

1. As 10 issues da rodada `swarm-1003-2048` estão fechadas: as 10 aparecem CLOSED, todas antes de 04:11Z (a última, #434, às 02:20Z). Confere.
2. "#452 mergeada (PR #456)" e "a `main` em `5109c44`": o PR #456 entrou às 03:27Z, e `5109c44` é o merge dele (#452) e está contido na tag `v0.7.35`. Confere.
3. "Reverter `1a5e470`": o commit existe ("Update image build and push steps in workflow", só `.github/workflows/image.yml`), o que bate com a ligação do teste de fumaça no workflow `image`. O teste em si veio pelo `6e415e0` (#430, PR #441). Confere.
4. "#457 aberto, à espera de decisão", com o relatório no link: o comentário 5976361202 existe (04:01Z). O PR #457 estava aberto quando o resumo foi escrito, mas **foi mergeado depois, às 09:15Z**. Os três artefatos refletem o original e avisam "não foi remedido", então isso não é infidelidade, mas o leitor de hoje vê uma decisão que já foi tomada.
5. "Seguem abertas" (#213, #435, #428, #448, #455, #368, #348, #7): todas aparecem OPEN. Confere.

## O que não consegui conferir

- O conteúdo do relatório do #457 e do spike #429 (US$ 0,0015, `openai/gpt-oss-120b`, "consolidação escreve direto"): conferi só que existem. Os números vêm do original.
- Os itens do checklist 0.7.35 (14 fragmentos, CI verde nos 14 PRs, `agent-pins`, `models-check`), as 11 merges, os 15 handoffs cancelados, as abas `r15`, a redução de 12% do #434 e a existência do pedido `20261004-041119-…` no canal: não remedi nada disso.
- A renderização real: não há navegador headless nem PIL no container. A sobra de texto na caixa e a ilegibilidade no celular são estimativas por métricas de fonte e pela escala do viewBox.
