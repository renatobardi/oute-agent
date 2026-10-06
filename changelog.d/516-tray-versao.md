### Added
- **Tray do Mac diz a versão e se atualiza no `oute update`** (#516). O menu ganha uma linha com a versão e o commit do app instalado. `oute tray sync` reinstala o tray só quando o app está atrás do repo, e o `oute update` chama esse comando no fim, no Mac com o tray instalado. Entra no Mac com `git pull` + `oute tray install`, sem release.
