---
name: oute-aidlc-ship-release
description: Checklist de release do oute-agent antes do Bardi rodar scripts/release. Use quando pedirem para preparar ou conferir uma release, perguntarem se o que entrou na main precisa de release ou qual versão usar.
---

# oute-aidlc-ship-release

Fase: `ship` (AI-DLC, ADR-07) · Outcome: release conferida, com versão proposta e o comando pronto · Gate: o Bardi roda `scripts/release`, faz o push da tag e o deploy.

Você **confere e propõe**; a release é do Bardi. Nada aqui roda `scripts/release`, cria tag, faz push na `main` nem edita `VERSION` (quem muda `VERSION`, monta a seção da versão no `CHANGELOG.md` e apaga os fragmentos de `changelog.d/` é o `scripts/release`). Correção que o checklist achar vira PR à parte, pelo fluxo normal.

Trabalhe numa worktree própria, na `main` atualizada (`git fetch --tags origin`, `git switch --detach origin/main`). Os passos são em ordem; cada um termina num item do relatório (passo 7).

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

Resposta **não**: o deploy é `git pull` + `oute down/up` nos hosts, sem versão nova. Pule para o passo 7 (sem os passos 4 a 6, salvo a tabela do seletor do passo 6, que vale também para mudança só de config) e recomende isso.

## 3. CHANGELOG: fragmentos de `changelog.d/`

As entradas da release vêm dos fragmentos `changelog.d/<issue>-<slug>.md` da `main` (#121), mais o que ainda estiver escrito direto no `[Unreleased]` do `CHANGELOG.md` (PR aberto antes da #121). O `scripts/release` junta tudo na seção da versão, por subseção, e apaga os fragmentos. Veja o que ele montaria:

```bash
scripts/changelog check
```

Saída diferente de 0 (fragmento inválido: o arquivo e a linha vêm na mensagem) é achado que **bloqueia** a release: o `scripts/release` para no mesmo ponto. Com saída 0, cruze a seção impressa com os commits do passo 1:

- **Cobertura:** todo commit com mudança visível (tudo que não é só teste, CI ou texto interno) tem uma entrada. Mapeie pelo número do PR/issue no assunto do commit (`(#n)`). Commit sem entrada é achado.
- **Coerência:** entrada que diz "precisa de release" tem arquivo de imagem no diff, e vice-versa; entrada que diz "sem release" não cita arquivo de imagem.
- **Forma:** cada entrada na subseção certa (`### Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`; o `check` já recusa as outras) e com o número da issue.
- **Nada fora do lugar:** nenhuma entrada do período caiu dentro de uma seção já lançada (`## [x.y.z]`): `git diff "$LAST"..origin/main -- CHANGELOG.md` só mexe no `[Unreleased]`, ou sai vazio.

Feito quando: cada commit do passo 1 está marcado como "com entrada", "sem entrada (achado)" ou "sem mudança visível".

## 4. Versão proposta

Siga o padrão das últimas seções do `CHANGELOG.md`: o normal é subir o **patch** (`0.7.24` → `0.7.25`). Proponha outro salto só com motivo escrito (quebra de compatibilidade da imagem, do `.env` ou do `scripts/oute`) e deixe a escolha para o Bardi. Confira que a tag não existe: `git rev-parse -q --verify "refs/tags/v<nova>"` sem saída.

Feito quando: há uma versão proposta e a tag dela está livre.

## 5. Pré-condições do `scripts/release`

O script recusa sem estas; confira antes, na `main`:

- scripts executáveis: `bash scripts/exec-files | while read -r f; do [[ "$(git ls-files -s -- "$f" | cut -d' ' -f1)" == 100755 ]] || echo "$f"; done` sem saída;
- `grep -q '^## \[Unreleased\]' CHANGELOG.md`;
- `scripts/changelog check` sai 0 (passo 3).

À parte (o script não confere): CI `pr` verde no PR de cada commit do passo 1 (`gh pr checks <n>`).

Feito quando: as três pré-condições e o CI dos PRs estão ok ou o que falhou está no relatório.

## 6. Versões fixas de claude e codex e tabela do seletor

A reserva de claude/codex na imagem tem versão fixa e sha256 em `ARG`s do `docker/Dockerfile` (#200, #199, adendo do ADR-01). O build recusa sha256 errado, e versão que o npm ainda não serve derruba o CI `image` e deixa a tag sem imagem (foi o que aconteceu na `v0.7.26`). Confira na `main`:

```bash
scripts/agent-pins
```

- Linha `DIFERENTE` (sha256 que não bate com o publicado, versão fora do npm): achado que **bloqueia** a release até um PR corrigir os `ARG`s.
- Tudo `ok`: a release pode sair com essas versões. A última linha mostra as mais recentes; se estiverem à frente, diga quanto e proponha (não exija) um PR de bump antes da tag, com os `ARG`s de `scripts/agent-pins --print`. Escolha uma versão publicada no npm há pelo menos 1 hora (a data vem no comentário do `--print`).
- A cópia no home não depende disso (se atualiza sozinha); só a reserva e a primeira instalação do home usam essas versões.

**Tabela do seletor** (#220, ADR-02): todo id de modelo e esforço de `config/select/models.toml` tem que existir no CLI instalado, senão a sessão abre com outro modelo ou cai na reserva sem ninguém ver. Rode no container `agent` (é onde estão o `claude` e o `codex` instalados), na `main`, com ou sem release:

```bash
scripts/models-check
```

Não chama modelo: lê o binário do `claude`, o `~/.codex/models_cache.json` e os labels do repo. Uma linha por conferência; o código de saída resume:

- **1, linha `FALTA`** (`FALTA <id> (<agente>)`, `FALTA <id> esforço <e> (codex)`, `FALTA linha da fase <fase> (tabela)`, `FALTA label <label> (repo)`): achado que **bloqueia** a release, e também o deploy só de config, até um PR corrigir a tabela ou o CLI ser atualizado (`oute-agents-install`).
- **3, linha `desconhecido`** (cache do Codex ausente ou com mais de 7 dias, binário do `claude` não encontrado, `gh` sem resposta): não foi conferido, e não vale como ok. O aviso em stderr diz a causa; o cache o Codex renova ao abrir. Sem conseguir conferir, vai ao relatório como pendência, para o Bardi decidir.
- **0:** tudo `ok`.

Feito quando: `scripts/agent-pins` saiu 0, ou o que deu `DIFERENTE` está no relatório como bloqueio; e `scripts/models-check` saiu 0, ou cada `FALTA` (bloqueio) e cada `desconhecido` (pendência) está no relatório.

## 7. Relatório para o Bardi

Uma mensagem, nesta ordem:

1. **Precisa de release:** sim/não, com os arquivos que decidem.
2. **Versão:** `LAST` → proposta (e o motivo, se não for patch).
3. **CHANGELOG:** ok, ou a lista de achados (fragmento inválido, commit sem entrada, entrada incoerente, fora do lugar), com a correção sugerida. Achado bloqueia a release até virar PR mergeado: diga isso.
4. **Pré-condições:** ok ou o que falhou.
5. **Versões de claude/codex:** as dos `ARG`s, `ok` ou o `DIFERENTE` (bloqueio), e as mais recentes, se estiverem à frente. **Tabela do seletor:** `ok`, cada `FALTA` (bloqueio) ou cada `desconhecido` (pendência, com a causa).
6. **Comandos do Bardi** (no checkout da `main`, no Mac ou no oute-server):
   ```bash
   scripts/release <nova> && git push && git push origin v<nova>
   ```
   Depois do CI `image` da tag terminar (Actions → image), em cada host: `oute update`.
   Sem release: em cada host, `git pull` + `oute down` + `oute up`.
7. **Próximo passo:** depois do deploy, `oute-aidlc-ship-verify` em cada host.

Pare aqui. Não rode os comandos do item 6.
