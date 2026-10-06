### Changed
- **Testes do shim do `gh` sem `jq` e da falha ao copiar as regras do Codex** (#554). `tests/gh-merge-guard.test.sh` cobre o shim sem `jq` no PATH (passa ao `gh` real); `tests/entrypoint-config.test.sh` cobre a falha ao gravar as regras do Codex (só AVISO, setup segue). Só testes: não precisa de release.
