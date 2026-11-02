### Fixed
- **`oute ssh <cmd> <args>` passa os argumentos ao container** (#895). Antes rodava só `<cmd>`: `oute ssh oute-sonar pr 894` mostrava o uso do `oute-sonar`. Agora os argumentos viram uma linha de shell, como no `ssh` comum (pipe funciona; argumento com espaço ou caractere especial vai citado). Entra com `git pull`, sem release.
