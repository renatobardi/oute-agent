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
  oute approve         revisa pedidos dos agentes (s = executa, N ou Enter = deixa pendente, r = recusa)
  oute approve --watch fica esperando pedidos novos
  oute watch [host]    = approve --watch; com host, abre a espera nele via ssh
  oute up | down | restart | status
  oute up --refresh-secrets            relê o Vaultwarden antes de subir (pede a master password)
                                       (no oute-server, com OUTE_AGENT_STUDIO=1 no .env, o up liga também
                                       o agent-studio, se o vault tem o item agent-studio; ADR-08)
  oute secrets refresh                 relê o Vaultwarden, regrava ~/.oute/agent.env e tranca a sessão
                                       (depois: oute restart, se a stack estiver de pé)
  oute attach          ssh → herdr
  oute ssh [cmd]       ssh no container (com cmd: roda e volta)
  oute shell           docker exec bash no container
  oute logs [svc] | follow [svc]
  oute pull            baixa a imagem da versão atual (ghcr, feita pelo CI)
  oute build           build local (fallback; o normal é o CI)
  oute sync-shared     monta o bucket OCI em ~/.oute/shared
  oute storage [ls|lsl|about] [path]   bucket direto no OCI
  oute lock            tranca o Vaultwarden e apaga a sessão em cache das versões antigas
  oute oci-bootstrap [DRY_RUN=1]       provisiona compartment/buckets/IAM/budget no OCI (pede a master password)

  Senha do Vaultwarden: ~/.oute/agent.env é o cache do host. up, pull, sync-shared e storage
  usam só ele, sem senha. A master password só é pedida em secrets refresh, up --refresh-secrets
  (ou up sem agent.env) e oci-bootstrap; a sessão é trancada logo depois, nada fica em disco. Faltou um segredo? oute secrets refresh.

## CONTAINER — sessões e worktrees
Regra: uma sessão de agente = uma worktree + um branch. O checkout principal
(/workspace/<repo>) fica sempre na branch padrão.
  claude | codex                    no checkout principal: pergunta o nome da tarefa e abre na worktree
                                    (dentro de worktree, -p/exec, --resume: passa direto)
  oute-task <slug> [claude|codex|shell] ["prompt"]
                                    cria/reabre /workspace/.worktrees/<repo>-<slug>, branch sessao/<slug>
  oute-task -r <repo> <slug> …      idem, de fora do repo
  oute-task list                    worktrees de tarefa abertas
  oute-task clean [--yes]           remove as mergeadas/vazias e avança (ff) o checkout principal (sem --yes: só mostra)
  OUTE_NO_WORKTREE=1 claude         desliga a worktree automática (uso raro)
  Cada sessão tem um id (oute.task.id, gravado na worktree). Abrir, reabrir e remover (clean --yes) viram
  eventos oute.task.* no bucket e no agent-studio, e as conversas do agente saem marcadas com a sessão (ADR-04).
  oute-agents-install [claude|codex]
                                    instala o agente no home (~/.local/bin), onde ele se atualiza sozinho (claude a
                                    partir da reserva; codex pelo install.sh da versão fixa, conferido por sha256);
                                    a subida já roda em segundo plano (log: ~/.oute/agents-install.log).
                                    Sem ele, vale a cópia de reserva da imagem (/opt/oute/agents). Update: claude
                                    automático, `codex update`. O Pi saiu do stack (#217): `pi` só avisa

## CONTAINER — rodada paralela (oute-swarm)
  oute-swarm <repo> [--max N] [--label L]
      abre o dispatcher: tria issues → ESPERA SEU OK → abre uma aba por issue →
      acompanha PRs/CI/pedidos → retrospectiva kaizen (lições numeradas; você escolhe:
      `1 sessão, 2 issue, 3 descarta`) → issues/sessões kaizen → fecha com clean + cancela handoffs órfãos.
      --max = abas abertas ao mesmo tempo (default 3, teto 5); aba fechada com close libera a vaga.
      Merge só quando você pedir.
  oute-swarm spawn <n>-<slug> "instrução" [--agent claude|codex] [--force] [--repo R] [--kaizen]
      (o dispatcher usa) abre a aba #n com oute-task; recusa passar do --max (abas abertas).
      --repo: issue de outro repo (nome em /workspace ou caminho); --kaizen: sessão kaizen, fora do --max
  oute-swarm tell <n>-<slug> "mensagem" [--force]
                                    repassa sua decisão à sessão (o dispatcher usa quando você decide).
                                    Só com a sessão parada (idle/done/blocked); confere o campo antes do Enter
                                    e recusa se não bater. --force: manda mesmo com a sessão ocupada (só você pede)
  oute-swarm close <n>-<slug>|--all [--yes]
                                    fecha a(s) aba(s) da rodada (sem --yes: só mostra); depois oute-task clean
  oute-swarm watch [--interval s] [--round ID]
                                    (monitor do dispatcher) uma linha por mudança real: sessão, aba, PR, CI,
                                    conflito, pedido pendente/rc≠0 no canal; retoma do último estado; sai no close --all.
                                    Grava no log da rodada; PR/issue de outro repo aparecem como <repo>#n
  oute-swarm list                   abas abertas por rodada + worktrees
  Fim de cada sessão: `PRONTO #n: <url do PR>` ou `BLOQUEADO #n: <pergunta>`.

## CONTAINER — canal de aprovação (agente → host)
  oute-propose "título" [--root] <<'SH' … SH   agente propõe script para o host (imprime o id)
  oute-inbox                                  pendentes e resultados
  oute-inbox <id>                             resultado (3 = pendente)
  oute-inbox --wait <id> [s]                  espera o resultado (default 1800 s)
  Quem aprova é você, no host: oute watch. Nunca de dentro do herdr.

## CONTAINER — eventos operacionais (oute-emit, ADR-04)
  Rodadas do swarm, pedidos do canal e sessões do oute-task vão como logs OTel (oute.swarm.*,
  oute.canal.*, oute.task.*) ao bucket e ao agent-studio (ADR-08), com a origem do host; nada ao
  Langfuse. A saída do script executado no host nunca vai.
  O oute-swarm, o oute-propose, o oute-task e o oute approve chamam sozinhos; falha nunca muda o comando.
  oute-emit canal <id>              emite a fase atual do pedido (proposto ou decidido)
  oute-emit swarm <rodada> <linha>  emite uma linha do log da rodada
  oute-emit task <opened|reopened|removed> <quem chamou> chave=valor…
                                    (o oute-task usa) emite o evento da sessão, sem corpo
  oute-emit backfill                uma vez por host: manda o histórico anterior ao corte
                                    (~/.oute/emit/since) com a hora original; resumo no stderr;
                                    rodar de novo não emite nada (retoma se falhou no meio)
  oute-emit flush                   reenvia o spool (~/.oute/emit/spool/: o que falhou com o
                                    coletor fora; toda chamada e a subida já reenviam sozinhas)
  oute-emit reconcile               decided de todo ~/inbox/*.out ainda não enviado (ex.: aprovado
                                    com o container fora); a subida já chama; registro em
                                    ~/.oute/emit/decided/; o anterior ao corte é do backfill
  OUTE_EMIT_DEBUG=1 oute-emit …     mostra o erro de envio (normalmente silencioso)

## Memória (ai-memory)
  Única memória dos agentes (auto memory do Claude desligada). Projeto = repo principal
  (worktrees e subpastas caem no mesmo). Handoff automático por diretório (cada worktree
  tem o seu, consumido uma vez). Órfãos: peça ao agente memory_handoff_list / _cancel.

## herdr (básico)
  prefix+c nova aba · prefix+v split direita · prefix+- split abaixo · prefix+q detach
  herdr agent list                  estado dos agentes (idle/working/blocked/done)
