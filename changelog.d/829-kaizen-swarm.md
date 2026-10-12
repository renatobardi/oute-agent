### Added
- **`oute-swarm pr-comment`: comentário de PR só com as referências conferidas** (#829). O dispatcher publica o relatório de auditoria com `oute-swarm pr-comment <pr> --body-file <arquivo>`: o comando roda o `oute-refcheck` e só então comenta. Referência quebrada ou que não abre não comenta (saída 1). **Precisa de release** (`docker/oute-swarm` e `docker/swarm/auditoria.md` vão na imagem).

### Changed
- **Pedido de release pelo canal leva o sha da `main` conferido** (#829). A skill `oute-aidlc-ship-release` ganha o passo 8: o script do pedido confere o `origin/main` do host contra o sha do relatório e para sem alterar nada se for outro. Sem release (`addons/`).
- **Testes em paralelo, com a duração de cada um** (#829). `tests/run-all.sh` roda os `tests/*.test.sh` em paralelo (até `nproc`) e mostra quanto dura cada teste; o workflow `pr` passa a chamá-lo quando o Bardi aplicar o arquivo do PR. Sem release (`tests/`, `.github/`).
