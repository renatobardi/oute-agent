# Rascunho do PT controlado (insumo da fatia 2 do spike #458)

Adaptado dos limites do post do Karpathy (ASD-STE100) para o pt-BR. Vale para o texto que o **Bardi** lê. Rascunho de
trabalho: o `pt-controlado.md` final é da fatia 3.

1. **A decisão vem primeiro.** A primeira linha diz o que o Bardi decide. As opções vêm numeradas, com a recomendação marcada.
2. **Frase de instrução: até 20 palavras. Frase descritiva: até 25.** Fecha a frase antes de abrir outra ideia.
3. **Uma ideia por frase. Uma instrução por frase.**
4. **Parágrafo: até 6 frases, um assunto só.**
5. **Voz ativa, sujeito explícito.** "O teste falha", não "é observada uma falha".
6. **Sem gerúndio progressivo e sem tempo composto sem necessidade.** "O script roda", não "está rodando"; "falhou", não "tinha falhado".
7. **Grupo nominal: até 3 palavras seguidas.** Quebre "relatório de auditoria de segurança do PR" em duas frases ou em lista.
8. **Uma palavra, um sentido.** Use sempre o mesmo termo para o mesmo conceito (dicionário abaixo). Não varie por estilo.
9. **Lista vertical** quando a frase teria 3 ou mais itens ou condições.
10. **Aviso de risco: comando primeiro, risco depois.** Formato: `CUIDADO: <o que fazer, claro>. <o que pode dar errado>.` Use onde a ação apaga, para ou não se desfaz.
11. **Toda afirmação sobre o estado do repo ou do fluxo cita a fonte:** `arquivo:linha` com o commit (`@abc1234`), `#N`, link de comentário ou o comando que reproduz. Sem fonte = escreva "não verificado".
12. **Todo número traz a origem** (comando ou fonte) ou a palavra "não medido". Nunca estimativa sem rótulo.
13. **Não corte artigos nem faça texto telegráfico.** Frase curta, mas completa.
14. **Fato primeiro, incerteza depois.** Diga o que é certo; marque o que é incerto como "incerto" e diga o que resolve.
15. **Contrato fica em crase e sem tradução:** comandos, labels, nomes de evento, `PRONTO #N`, `Closes`/`Refs`, `## Falta`.

## Dicionário inicial (termo aprovado × termo a evitar)
| Use | Evite |
|---|---|
| pedido (do canal de aprovação) | solicitação, requisição, job |
| fazer merge | mergear, mesclar, integrar |
| rodar (um comando, um teste) | executar, disparar, rolar |
| aprovar | autorizar, dar o ok (quando for o `oute approve`) |
| achado (da auditoria) | problema, issue (issue = só o item do GitHub) |
| critério de aceite | requisito, condição de pronto |
| falha | erro (quando o teste falha), problema |
| rodada, sessão, worker, dispatcher | variações ("ciclo" é outra coisa: iter → learn) |
