---
name: oute-aidlc-ship-release
description: Checklist de release do oute-agent antes do Bardi rodar scripts/release. Use quando pedirem para preparar ou conferir uma release, perguntarem se o que entrou na main precisa de release ou qual versão usar.
---

# oute-aidlc-ship-release

Fase: `ship` (AI-DLC, ADR-07) · Outcome: release conferida, com versão proposta e o comando pronto · Gate: o Bardi roda `scripts/release`, faz o push da tag e o deploy.

Você **confere e propõe**; a release é do Bardi. Nada aqui roda `scripts/release`, cria tag, faz push na `main` nem edita `VERSION` (quem muda `VERSION` e fecha o `[Unreleased]` é o `scripts/release`). Correção que o checklist achar vira PR à parte, pelo fluxo normal.

Trabalhe numa worktree própria, na `main` atualizada (`git fetch --tags origin`, `git switch --detach origin/main`). Os passos são em ordem; cada um termina num item do relatório (passo 6).

## 1. Ponto de partida

- `LAST="$(git describe --tags --abbrev=0 origin/main)"` é a última release; `VERSION` tem que ser igual a `LAST` sem o `v`. Diferente: pare e reporte (release pela metade ou `VERSION` editado à mão).
- `git log --oneline "$LAST"..origin/main` lista o que entra. Vazio: não há release a fazer; reporte e pare.

Feito quando: `LAST`, `VERSION` e a lista de commits estão anotados.

## 2. Precisa de release?

Precisa quando algum arquivo que **entra na imagem** mudou desde `LAST`:

```bash
git diff --name-only "$LAST"..origin/main
```

- **Entra na imagem:** `docker/Dockerfile` e todo arquivo de um `COPY` dele (leia os `COPY` do `Dockerfile` da `main`, não uma lista de memória: hoje `docker/entrypoint.sh`, `docker/addons-link`, `docker/oute-*`, `docker/*.md` copiados, `docker/agent-wrap.sh`, `docker/shims/`, `docker/codex_config.py`, `scripts/oute-secrets.sh`, `config/ssh/sshd_config`).
- **Não entra (só `git pull` + `oute down/up`):** `scripts/oute`, `config/` (fora o `sshd_config`), `docker/compose.yaml`, `addons/`, `tests/`, `docs/`, `.github/`, `README.md`, `AGENTS.md`, `CONTEXT.md`.

Feito quando: cada arquivo do diff está num dos dois grupos e a resposta é **sim** (com os arquivos que obrigam) ou **não**.

Resposta **não**: o deploy é `git pull` + `oute down/up` nos hosts, sem versão nova. Pule para o passo 6 (sem os passos 4 e 5) e recomende isso.

## 3. CHANGELOG `[Unreleased]`

Leia a seção `[Unreleased]` do `CHANGELOG.md` da `main` e cruze com os commits do passo 1:

- **Cobertura:** todo commit com mudança visível (tudo que não é só teste, CI ou texto interno) tem uma entrada. Mapeie pelo número do PR/issue no assunto do commit (`(#n)`). Commit sem entrada é achado.
- **Coerência:** entrada que diz "precisa de release" tem arquivo de imagem no diff, e vice-versa; entrada que diz "sem release" não cita arquivo de imagem.
- **Forma:** Keep a Changelog, subseções `### Added`, `### Changed`, `### Fixed` (e `Removed`/`Security` se houver), cada entrada com o número da issue.
- **Nada fora do lugar:** nenhuma entrada do período caiu dentro de uma seção já lançada (`## [x.y.z]`).

Feito quando: cada commit do passo 1 está marcado como "com entrada", "sem entrada (achado)" ou "sem mudança visível".

## 4. Versão proposta

Siga o padrão das últimas seções do `CHANGELOG.md`: o normal é subir o **patch** (`0.7.24` → `0.7.25`). Proponha outro salto só com motivo escrito (quebra de compatibilidade da imagem, do `.env` ou do `scripts/oute`) e deixe a escolha para o Bardi. Confira que a tag não existe: `git rev-parse -q --verify "refs/tags/v<nova>"` sem saída.

Feito quando: há uma versão proposta e a tag dela está livre.

## 5. Pré-condições do `scripts/release`

O script recusa sem estas; confira antes, na `main`:

- scripts executáveis: `bash scripts/exec-files | while read -r f; do [[ "$(git ls-files -s -- "$f" | cut -d' ' -f1)" == 100755 ]] || echo "$f"; done` sem saída;
- `grep -q '^## \[Unreleased\]' CHANGELOG.md`;
- CI `pr` verde no último commit da `main` (`gh run list --branch main --limit 5`).

Feito quando: as três estão ok ou o que falhou está no relatório.

## 6. Relatório para o Bardi

Uma mensagem, nesta ordem:

1. **Precisa de release:** sim/não, com os arquivos que decidem.
2. **Versão:** `LAST` → proposta (e o motivo, se não for patch).
3. **CHANGELOG:** ok, ou a lista de achados (commit sem entrada, entrada incoerente, fora do lugar), com a correção sugerida. Achado bloqueia a release até virar PR mergeado: diga isso.
4. **Pré-condições:** ok ou o que falhou.
5. **Comandos do Bardi** (no checkout da `main`, no Mac ou no oute-server):
   ```bash
   scripts/release <nova> && git push && git push origin v<nova>
   ```
   Depois do CI `image` da tag terminar (Actions → image), em cada host: `oute update`.
   Sem release: em cada host, `git pull` + `oute down` + `oute up`.
6. **Próximo passo:** depois do deploy, `oute-aidlc-ship-verify` em cada host.

Pare aqui. Não rode os comandos do item 5.
