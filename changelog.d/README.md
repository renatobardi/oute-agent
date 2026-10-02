# changelog.d: fragmentos do CHANGELOG (#121)

Cada PR com mudança visível cria **um arquivo aqui** e não edita o `CHANGELOG.md`. Dois PRs criam arquivos diferentes, então um merge não deixa o outro em conflito.

## Nome

`changelog.d/<issue>-<slug>.md`: número da issue, hífen e um slug em minúsculas (`a-z`, `0-9`, `.`, `_`, `-`). Ex.: `121-changelog-fragmentos.md`. Segundo PR da mesma issue: outro slug.

## Conteúdo

A subseção e a entrada, como sairiam no `CHANGELOG.md`:

```markdown
### Fixed
- **Título curto da mudança** (#123). O que mudou, para quem usa. **Precisa de release** (o arquivo X vai na imagem).
```

- Subseções aceitas: `### Added`, `### Changed`, `### Deprecated`, `### Removed`, `### Fixed`, `### Security`.
- A entrada começa com `- ` e leva o número da issue; subitens com recuo, como no `CHANGELOG.md`.
- Um fragmento pode ter mais de uma subseção, cada uma com a sua entrada.
- Nada de título `#` ou `##`, nem texto antes da primeira subseção.

Conferir: `scripts/changelog check` (sai diferente de 0 e diz o arquivo e a linha; com tudo certo, imprime a seção que a release montaria). O `tests/release-changelog.test.sh` roda isso em todo PR.

## Na release

O `scripts/release x.y.z` junta os fragmentos na seção `## [x.y.z] - <data>`, agrupados por subseção na ordem acima e, dentro dela, por número da issue; apaga os fragmentos no mesmo commit. O que ainda estiver escrito direto no `[Unreleased]` entra na mesma seção, antes dos fragmentos. Este README fica.
