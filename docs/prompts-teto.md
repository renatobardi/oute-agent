# Teto de tamanho dos prompts fixos (#753)

Todo turno de toda sessão paga o texto destes arquivos, então eles não crescem sem decisão. O teto é em **bytes** (`wc -c`) e o `tests/prompts-teto.test.sh` falha o PR que o passa. Lista e tetos abaixo; o teste lê a tabela.

| Arquivo | Teto (bytes) | Quem carrega |
|---|---|---|
| `AGENTS.md` | 12000 | toda sessão no repo |
| `docker/agent-notes.md` | 11700 | toda sessão (notas globais) |
| `docker/swarm-worker.md` | 15400 | todo worker do swarm |
| `docker/swarm.md` | 7400 | dispatcher, núcleo |
| `docker/swarm/abertura.md` | 6400 | dispatcher, ao abrir sessões |
| `docker/swarm/acompanhamento.md` | 16300 | dispatcher, o tempo todo |
| `docker/swarm/auditoria.md` | 7400 | dispatcher, ao auditar e pedir merge |
| `docker/swarm/casos.md` | 8100 | dispatcher, depois do merge e casos especiais |
| `docker/swarm/fechamento.md` | 6900 | dispatcher, fechamento final |
| `docker/swarm/kaizen.md` | 5800 | dispatcher, retrospectiva e issues kaizen |
| `docker/swarm/merge.md` | 7800 | dispatcher, ao executar o merge |
| `docker/swarm/pagina.md` | 4700 | dispatcher, ao publicar uma etapa na página |
| `docker/swarm/triagem.md` | 12900 | dispatcher, na triagem |

## Regras

- **Prompt fixo novo** (arquivo que entra em toda sessão ou em toda etapa do dispatcher) entra na tabela com o teto no mesmo PR; o teste falha com arquivo de `docker/swarm/` ou prompt fixo fora dela.
- **Regra nova num desses arquivos entra tirando ou fundindo outra**, ou vira checagem em teste ou script (#652). Estourou o teto: enxugue o que já está no arquivo antes de pedir teto maior.
- **Quando a lição vira checagem e quando fica texto (#652).** Vira checagem por máquina a lição que **voltou pela segunda vez** e que um teste ou script decide sem rede e sem token, sobre o diff. Fica texto a primeira ocorrência e o que pede julgamento, token ou PR aberto (o gate do SonarCloud, `oute-sonar pr <n>`). Hoje: `tests/lib/diff-lint.py`, rodado por `tests/diff-lint.test.sh`, reprova em linha ou função **nova** do diff `rm` com variável sem `${VAR:?}` (#539, #578) e função de shell sem `local` no parâmetro posicional ou sem `return` no fim (#501, #585). Dispensa de uma linha de `rm`: `# rm-ok: <motivo>`. No CI, o checkout raso não tem a base do PR e o caso do diff do PR é pulado; a conferência vale nas sessões, que rodam o teste antes do PR.
- **Subir um teto é decisão do Bardi**, no PR, com o motivo escrito no corpo. Descer é livre e deve acompanhar o arquivo: teto folgado deixa o arquivo crescer de novo.
- O texto de um `docs/` lido sob demanda (`docs/mapa-repo.md`, `docs/pt-controlado.md`, ADRs) não entra aqui: ele só custa quando alguém o abre.
