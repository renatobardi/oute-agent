# oute — guia de comandos

Dois lugares, dois conjuntos de comandos:
  HOST       Mac ou oute-server, no terminal normal (fora do herdr)
  CONTAINER  dentro do herdr (aba de shell), onde os agentes rodam
`oute help` mostra este guia nos dois lugares.

## Receitas rápidas
  Abrir o ambiente ............ oute                              (host; sobe a stack se preciso e abre o herdr)
  Atualizar p/ versão nova .... oute update                       (host; depois de tag + CI verde)
  Ver versão/origem ........... oute version                      (host)
  Aprovar pedido de agente .... oute watch                        (host; fica esperando)
  Aprovar no server, do Mac ... oute watch oute-server            (host Mac)
  Nova tarefa com agente ...... claude  (no checkout principal)   (container; pergunta o nome e cria worktree)
  Tarefa com nome e prompt .... oute-task 185-alerta claude "…"   (container)
  Rodada paralela de issues ... oute-swarm lab --max 3            (container, dentro do herdr)
  Limpar worktrees mergeadas .. oute-task clean → clean --yes     (container)
  Sair do herdr sem matar ..... prefix+q  (detach)

## HOST — `oute …`
  oute                 sobe a stack se preciso e abre o herdr (attach)
  oute install         cria o link no PATH (chamar `oute` de qualquer lugar)
  oute update          git pull --tags no repo + pull da imagem + down + up + version
  oute version         versão do repo, da imagem rodando e origem (host/instância)
  oute approve         revisa pedidos dos agentes (s = executa, N = recusa, r = relê)
  oute approve --watch fica esperando pedidos novos
  oute watch [host]    = approve --watch; com host, abre a espera nele via ssh
  oute up | down | restart | status
  oute attach          ssh → herdr
  oute ssh [cmd]       ssh no container (com cmd: roda e volta)
  oute shell           docker exec bash no container
  oute logs [svc] | follow [svc]
  oute pull            baixa a imagem da versão atual (ghcr, feita pelo CI)
  oute build           build local (fallback; o normal é o CI)
  oute sync-shared     monta o bucket OCI em ~/.oute/shared
  oute storage [ls|lsl|about] [path]   bucket direto no OCI
  oute lock            apaga a sessão do Vaultwarden (próximo up pede a master password)
  oute router-sync [--dry-run]         regenera o catálogo do jev-router (roda em todo up)
  oute schedule        agenda o router-sync diário (04:00)
  oute oci-bootstrap [DRY_RUN=1]       provisiona compartment/buckets/IAM/budget no OCI

## CONTAINER — sessões e worktrees
Regra: uma sessão de agente = uma worktree + um branch. O checkout principal
(/workspace/<repo>) fica sempre na branch padrão.
  claude | codex | pi               no checkout principal: pergunta o nome da tarefa e abre na worktree
                                    (dentro de worktree, -p/exec, --resume: passa direto)
  oute-task <slug> [claude|codex|pi|shell] ["prompt"]
                                    cria/reabre /workspace/.worktrees/<repo>-<slug>, branch sessao/<slug>
  oute-task -r <repo> <slug> …      idem, de fora do repo
  oute-task list                    worktrees de tarefa abertas
  oute-task clean [--yes]           remove as mergeadas/vazias (sem --yes: só mostra)
  OUTE_NO_WORKTREE=1 claude         desliga a worktree automática (uso raro)

## CONTAINER — rodada paralela (oute-swarm)
  oute-swarm <repo> [--max N] [--label L]
      abre a coordenadora: tria issues → ESPERA SEU OK → abre uma aba por issue →
      acompanha PRs/CI/pedidos → fecha com clean + cancela handoffs órfãos.
      Default --max 3 (teto 5). Merge só quando você pedir.
  oute-swarm spawn <n>-<slug> "instrução" [--agent claude|codex|pi] [--force]
      (a coordenadora usa) abre a aba #n com oute-task; recusa passar do --max
  oute-swarm tell <n>-<slug> "mensagem"
                                    repassa sua decisão à sessão (a coordenadora usa quando você decide)
  oute-swarm close <n>-<slug>|--all [--yes]
                                    fecha a(s) aba(s) da rodada (sem --yes: só mostra); depois oute-task clean
  oute-swarm list                   abas abertas por rodada + worktrees
  Fim de cada sessão: `PRONTO #n: <url do PR>` ou `BLOQUEADO #n: <pergunta>`.

## CONTAINER — canal de aprovação (agente → host)
  oute-propose "título" [--root] <<'SH' … SH   agente propõe script para o host (imprime o id)
  oute-inbox                                  pendentes e resultados
  oute-inbox <id>                             resultado (3 = pendente)
  oute-inbox --wait <id> [s]                  espera o resultado (default 1800 s)
  Quem aprova é você, no host: oute watch. Nunca de dentro do herdr.

## Memória (ai-memory)
  Única memória dos agentes (auto memory do Claude desligada). Projeto = repo principal
  (worktrees e subpastas caem no mesmo). Handoff automático por diretório (cada worktree
  tem o seu, consumido uma vez). Órfãos: peça ao agente memory_handoff_list / _cancel.

## herdr (básico)
  prefix+c nova aba · prefix+v split direita · prefix+- split abaixo · prefix+q detach
  herdr agent list                  estado dos agentes (idle/working/blocked/done)
