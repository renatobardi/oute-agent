### Changed
- **Skill `oute-aidlc-spec-issue` confere subcomando e flag de CLI externo** (#461). Quando um critério de aceite depende de subcomando ou flag de ferramenta externa, a spec registra o comando conferido (`<cli> --help` na versão do container) antes do gate do Bardi. Entra com `git pull` + `oute down/up`, sem release.
