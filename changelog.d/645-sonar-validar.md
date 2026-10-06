### Changed
- **`AGENTS.md`, seção "Validar antes do PR": S3358 e `oute-sonar pr` depois do push** (#645). A lista do que derruba a nota do SonarCloud ganhou a condicional aninhada (S3358), e o worker passa a rodar `oute-sonar pr <n>` depois do push e a corrigir as issues do arquivo de teste de shell que o PR tocou, mesmo em função antiga. Só documentação, não precisa de release.
