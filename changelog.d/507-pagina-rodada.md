### Added
- **Página da rodada no agent-studio, fatia 1** (#507). O dispatcher escreve o resumo de fechamento num arquivo, um revisor de outro modelo confere, e o Bardi lê na tela `/rodada?id=` (barra de etapas, Markdown restrito sempre escapado, aviso fixo quando a etapa sai `reprovado` ou `sem-revisor`), com a lista `/rodadas` e o JSON `GET /v1/rodada?id=`.
  - `oute-swarm step review` e `oute-swarm step publish`: teto de 32 KiB (recusa sem cortar), recusa de texto com segredo, trava do `publish` pelo sha256 do veredito, evento `oute.swarm.step.published` com o texto no corpo.
  - Par de modelos do revisor em `config/select/models.toml` (`[[reviewer]]`), conferido pelo `scripts/models-check`; prompt fixo em `docker/step-review.md`.
  - `oute-emit run [--attr k=v]… -- <comando>`: roda o agente headless do revisor com o ambiente de telemetria do `~/.oute_env`, para o consumo dele chegar ao bucket e ao agent-studio.
  - `etapa` no SurrealDB (a revisão mais alta vence); `oute studio rebuild-state` remonta e imprime `etapas=`.
  - `docker/swarm.md` §4.3: o fechamento vai pela página; na aba só a decisão, as opções e o link. **Precisa de release** (`docker/oute-swarm`, `docker/oute-emit`, `docker/swarm.md`, `docker/step-review.md` e o agent-studio vão na imagem).
