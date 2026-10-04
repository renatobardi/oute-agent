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
  Limpar worktrees mergeadas .. oute-task clean → clean --yes     (container; só o space atual do herdr)
  Sair do herdr sem matar ..... prefix+q  (detach)

## HOST — `oute …`
  oute                 sobe a stack se preciso e abre o herdr (attach)
  oute install         cria o link no PATH (chamar `oute` de qualquer lugar)
  oute update          git pull --tags no repo + pull da imagem + down + up + version
  oute version         versão do repo, da imagem rodando e origem (host/instância)
  oute approve         revisa pedidos dos agentes (s = executa, N ou Enter = deixa pendente, r = recusa)
  oute approve --watch fica esperando pedidos novos
  oute approve <id>    decide só aquele pedido (o id que o oute-propose imprime); id que não está
                       pendente = aviso e rc 1, id fora do formato AAAAMMDD-HHMMSS-slug = rc 2
  oute watch [host]    = approve --watch; com host, abre a espera nele via ssh
  oute tray install    só no macOS: compila o tray (barra de menu que lê o agent-studio), monta o .app e
                       abre no login; aprovar pelo tray abre o Terminal no oute approve <id>
  oute tray uninstall  tira o tray (a tabela ~/.oute/tray-hosts editada fica)
  oute up | down | restart | status
  oute up --refresh-secrets            relê o Vaultwarden antes de subir (pede a master password)
                                       (no oute-server, com OUTE_AGENT_STUDIO=1 no .env, o up liga também
                                       o agent-studio, se o vault tem o item agent-studio; ADR-08)
  oute secrets refresh                 relê o Vaultwarden, regrava ~/.oute/agent.env e services.env e tranca a sessão
                                       (depois: oute restart, se a stack estiver de pé)
  oute attach          ssh → herdr
  oute ssh [cmd]       ssh no container (com cmd: roda e volta)
  oute shell           docker exec bash no container
  oute logs [svc] | follow [svc]
  oute pull            baixa a imagem da versão atual (ghcr, feita pelo CI)
  oute build           build local (fallback; o normal é o CI)
  oute sync-shared     monta o bucket OCI em ~/.oute/shared
  oute storage [ls|lsl|about] [path]   bucket direto no OCI
  oute studio replay --from <ISO> --to <ISO> [--signal logs|traces|metrics] [--host <máquina>] [--legacy]
                       só no oute-server (OUTE_AGENT_STUDIO=1): reenvia o bucket de telemetria à ingestão do
                       agent-studio, com dedupe (rodar de novo não duplica; o SurrealDB volta junto). Faixa em UTC
                       pela partição do bucket, com 1 h de folga de cada lado. Objeto ilegível (Archive, mais de
                       90 dias) é listado e pulado, com rc ≠ 0: restaure-o antes (ADR-08 §7)
  oute studio rebuild-state
                       só no oute-server (OUTE_AGENT_STUDIO=1): remonta o estado do SurrealDB (pedidos, rodadas,
                       sessões) a partir do DuckDB, sem ler o bucket. Para o agent-studio, roda o one-off e sobe
                       de novo (a ingestão espera na fila do collector). Imprime a contagem antes e depois (ADR-08 §7)
  oute memory-backup   backup do volume oute-memory: roda `ai-memory backup` no container agent e grava
                       backups/ai-memory/<host>-<instância>-<AAAAMMDDTHHMMSSZ, UTC>.tar.gz no oute-shared (o tarball
                       tem conversa e o config do cliente: fica só no bucket privado, nunca em log nem em saída).
                       Imprime o tamanho do tarball e do banco, avisa se o banco passa de OUTE_MEMORY_WARN_MB (500) e
                       mantém os OUTE_MEMORY_BACKUP_KEEP (8) mais recentes da mesma origem, sem tocar em outra.
                       rc ≠ 0 se o backup falhar ou o arquivo não chegar ao bucket (sem mount/credencial: "ficou só local")
  oute memory-backup --check <arquivo local | nome no bucket>
                       restaura num diretório temporário do container (nunca no volume) e confere que o banco abre,
                       está íntegro e tem páginas (> 0); rc ≠ 0 se não. Restaurar de verdade (com a stack parada, o
                       `ai-memory restore` recusa rodar com outro ai-memory vivo): ver README, "Backup da memória"
  oute lock            tranca o Vaultwarden e apaga a sessão em cache das versões antigas
  oute oci-bootstrap [DRY_RUN=1]       provisiona compartment/buckets/IAM/budget no OCI (pede a master password)

  Segredo de serviço (pasta oute-services do vault) fica em ~/.oute/services.env e vai só aos serviços,
  nunca ao container agent (#256).
  Senha do Vaultwarden: ~/.oute/agent.env é o cache do host. up, pull, sync-shared e storage
  usam só ele, sem senha. A master password só é pedida em secrets refresh, up --refresh-secrets
  (ou up sem agent.env) e oci-bootstrap; a sessão é trancada logo depois, nada fica em disco. Faltou um segredo? oute secrets refresh.

## CONTAINER — sessões e worktrees
Regra: uma sessão de agente = uma worktree + um branch. O checkout principal
(/workspace/<repo>) fica sempre na branch padrão.
  claude | codex                    no checkout principal: pergunta o nome da tarefa e abre na worktree
                                    (dentro de worktree, -p/exec, --resume: passa direto)
  oute-task <slug> [claude|codex|shell] ["prompt"]
                                    cria/reabre /workspace/.worktrees/<space>/<repo>-<slug>, branch sessao/<slug>
                                    (<space> = label do space do herdr em nome de pasta; fora do herdr: _sem-space)
  oute-task -r <repo> <slug> …      idem, de fora do repo
  oute-task --agent claude|codex --model <id> <slug> …
                                    escolha explícita do agente e/ou do modelo (antes do slug)
  Modelo da sessão (ADR-02): sai da issue do slug (<n>-…), pela tabela config/select/models.toml:
  --agent/--model (ou `codex` depois do slug) > label spike/kaizen/docs (kaizen não vale com aidlc de código, #409) > label aidlc:<fase> > Jev > Sonnet.
  Sem label de fase e com prompt: o Jev (TypeSafe) classifica a fase pelo texto; confiança baixa, falha ou sem a
  chave: Sonnet, com aviso. Sem prompt ou com o gh fora do ar: Sonnet. Nunca bloqueia. O restore do herdr reabre
  no mesmo modelo.
  Reserva (#258): com o Claude indisponível (`claude auth status` ≠ 0 ou claude ausente), a sessão abre no Codex da
  mesma linha (`codex -m <id> -c model_reasoning_effort=<e>`), e o evento leva oute.task.reserve=indisponivel.
  --agent/--model explícitos e --phase fixa não caem na reserva (só avisam); os dois fora: aviso e abre no Claude.
  oute-select [--json] [--repo <dir>] [--issue <n> | --task <slug>] [--phase <fase>] [--agent A] [--model <id>]
              [--text-file <arquivo>|-]
                                    diz fase, origem (manual/label/jev/padrao), agente, modelo, esforço, motivo e
                                    confiança do Jev e reserva (reserve), sem abrir sessão; --text-file: o texto da tarefa para o Jev
  oute-task list                    worktrees de tarefa abertas (todos os spaces)
  oute-task clean [--yes]           remove as mergeadas/vazias só do space atual e avança (ff) o checkout principal; pula as em uso (#374; --force-in-use só a pedido do Bardi)
                                    dos repos com worktree nele (sem --yes: só mostra)
    --space <nome> | --all          limpa outro space | todos os spaces e o formato antigo
  Formato antigo (/workspace/.worktrees/<repo>-<slug>, antes da #277): reabre e aparece no list, sem migração;
  só o clean --all o remove.
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
  oute-swarm <repo> [--max N] [--label L] [--agent claude|codex]
      abre o dispatcher: tria issues → ESPERA SEU OK → abre uma aba por issue →
      acompanha PRs/CI/pedidos → retrospectiva kaizen (lições numeradas; você escolhe:
      `1 sessão, 2 issue, 3 descarta`) → issues/sessões kaizen → fecha com clean + cancela handoffs órfãos.
      --max = abas abertas ao mesmo tempo (default 3, teto 5); aba fechada com close libera a vaga.
      --agent = agente do dispatcher e de todas as sessões da rodada, kaizen inclusive (sem ele: dispatcher em
      claude e o seletor escolhe cada sessão). Com `--agent codex` o dispatcher abre no Codex e o watch roda numa aba
      `watch <rodada>` que digita os eventos no campo dele (`watch --deliver`); com claude nada muda (ferramenta Monitor).
      O modelo de cada sessão sai da fase da issue (oute-select); o dispatcher abre na fase plan.
      Merge só quando você pedir.
  oute-swarm spawn <n>-<slug> "instrução" [--agent claude|codex] [--model <id>] [--force] [--repo R] [--kaizen]
      (o dispatcher usa) abre a aba #n com oute-task; recusa passar do --max (abas abertas).
      --agent: sobrepõe o agente da rodada (sem ele: o da rodada; spawn avulso: claude)
      --model: modelo da sessão (sem ele: o da fase da issue, pelo oute-select)
      --repo: issue de outro repo (nome em /workspace ou caminho); --kaizen: sessão kaizen, fora do --max
  oute-swarm tell <n>-<slug> "mensagem" [--force]
                                    repassa sua decisão à sessão (o dispatcher usa quando você decide).
                                    Só com a sessão parada (idle/done/blocked); confere o campo antes do Enter
                                    e recusa se não bater. --force: manda mesmo com a sessão ocupada (só você pede)
  oute-swarm tell <n>-<slug> "mensagem" --wait [--timeout <s>]
                                    espera a sessão parar (relê a cada 5 s) e envia; uma linha só no log
                                    (ok (--wait, Ns) ou a recusa final). Timeout padrão 600 s: recusa e sai com 3.
                                    Não combina com --force
  oute-swarm ask "pergunta"         (o dispatcher usa) a rodada parou esperando a sua decisão: registra a pergunta
                                    (aparece como decisão pendente no agent-studio e no tray); oute-swarm answered
                                    registra que você respondeu
  oute-swarm step review <tipo> [--pr <n>] --writer <modelo> [--fontes <arquivo>]
  oute-swarm step publish <tipo> [--pr <n>] [--rev <n>] [--cycle <dono/repo#n>]
                                    (o dispatcher usa, #507) etapa = o texto que ele escreve para o Bardi, em
                                    ~/.oute/swarm/<rodada>/etapas/<tipo>[-<pr>].r<n>.md (tipos: triagem, merge, kaizen,
                                    fechamento). review: outro modelo, em modo headless, confere o texto (até 300 s) e
                                    grava o veredito para o sha256 dele; publish: só marca aprovado com esse veredito,
                                    recusa acima de 32 KiB (sem cortar) e texto com segredo, e emite o evento que o
                                    agent-studio mostra na página /rodada?id=
  oute-swarm close <n>-<slug>|--all [--yes]
                                    fecha a(s) aba(s) da rodada (sem --yes: só mostra); depois oute-task clean
  oute-swarm watch [--interval s] [--round ID] [--deliver]
                                    (monitor do dispatcher) uma linha por mudança real: sessão, aba, PR, CI,
                                    conflito, pedido pendente/rc≠0 no canal; retoma do último estado; sai no close --all.
                                    Grava no log da rodada; PR/issue de outro repo aparecem como <repo>#n.
                                    --deliver (dispatcher fora do Claude, aberto por `--agent codex`): digita os eventos,
                                    agrupados numa mensagem, no campo do dispatcher parado (idle/done, campo achado e
                                    vazio); ocupado, com diálogo ou com texto no campo, adia (fila em watch.queue, motivo no log)
  oute-swarm list                   abas abertas por rodada + worktrees
  Fim de cada sessão: `PRONTO #n: <url do PR>` ou `BLOQUEADO #n: <pergunta>`.

## CONTAINER — canal de aprovação (agente → host)
  oute-propose "título" [--root] <<'SH' … SH   agente propõe script para o host (imprime o id)
  oute-inbox                                  pendentes e resultados
  oute-inbox <id>                             resultado (3 = pendente)
  oute-inbox --wait <id> [s]                  espera o resultado (default 1800 s)
  Quem aprova é você, no host: oute watch. Nunca de dentro do herdr.

## CONTAINER — SonarCloud (oute-sonar, #226)
  oute-sonar [--json] pr <n>        quality gate, condições reprovadas, issues e hotspots do PR <n> (regra, arquivo,
                                    linha, mensagem), o commit analisado e, para issue FALSE-POSITIVE/WONTFIX e
                                    hotspot revisado, quem mudou o status e quando
  oute-sonar [--json] main          o mesmo na branch principal
  Só leitura: só GET em https://sonarcloud.io. Projeto: OUTE_SONAR_PROJECT ou <dono>_<repo> do remoto origin;
  organização: OUTE_SONAR_ORG. Token: SONAR_TOKEN (item `sonar` do vault, pelo agent_env). Saída: 0 gate aprovado,
  1 gate reprovado, 2 uso, 3 sem SONAR_TOKEN, 4 falha de rede/API ou PR sem análise.

## CONTAINER — screenshot de UI e PDF (oute-shot, #472)
  oute-shot <url|arquivo> [--mobile] [--dark] [-o <png>] [--height <px>]
                                    PNG da página: desktop 1280 ou --mobile 390, light ou --dark (padrão ./shot-<desktop|mobile>-<light|dark>.png,
                                    altura 800)
  oute-shot <url|arquivo> --all [-d <pasta>]   os quatro (desktop e mobile, light e dark)
  Firefox ESR headless da imagem (versão e sha256 fixos no Dockerfile). Sem rede externa: só arquivo local, file:// ou
  loopback (localhost, 127.0.0.1, [::1]); o que a página pedir fora do loopback não sai. Sem segredo: o navegador roda
  com `env -i`, em perfil descartável. Saída: 0 ok, 2 uso ou destino recusado, 3 sem navegador, 4 falha, prazo
  (OUTE_SHOT_TIMEOUT, 60 s) ou PNG não gerado.
  PDF de referência: `pdftotext -layout ref.pdf -` (texto) e `pdftoppm -png -r 100 ref.pdf pasta/pag` (imagem de cada
  página; depois leia o PNG), do poppler-utils.
  Anexar ao PR: o `gh` não envia imagem a comentário. Suba o PNG num branch de imagens (nunca no branch do PR) e
  referencie por `?raw=true`:
    git worktree add --detach /tmp/shots origin/main && cd /tmp/shots && git switch -c shots/<issue>
    cp <png> . && git add <png> && git commit -m "chore(shots): <issue>" && git push -u origin shots/<issue>
    comentário do PR: ![desktop light](https://github.com/<dono>/<repo>/blob/<sha do commit>/<png>?raw=true)

## CONTAINER — cota das assinaturas (oute-quota, #346)
  oute-quota [--json] [--agent claude|codex]   janelas 5h e 7d de cada agente: % usada e hora do reset (UTC), ou
                                    `unknown` com o motivo (sem-credencial, token-expirado, rede, timeout, http-<código>,
                                    formato); --json no contrato do spike #55 (read_at, max_pct, reset_grace_s, agents)
  Só leitura: só GET por https (api.anthropic.com e chatgpt.com), token pelo stdin do curl, nunca escreve nem renova a
  credencial do agente (token expirado = unknown até o próprio claude/codex renovar). Cache de 120 s em
  ~/.cache/oute-quota (só % e reset); com 429, rede ou timeout devolve o cache de até 30 min com stale:true.
  Saída: 0 leitura feita (mesmo com unknown), 1 todos os agentes lidos ficaram unknown, 2 uso. A fonte da reserva
  por cota do ADR-02 (#258).

## CONTAINER — regressão dos agentes (oute-regression, #366)
  oute-regression [--rounds N] [--codex] [--task <nome>]… [--json]
                                    nível 1 de regressão: tarefas headless do claude em Haiku (a tabela do seletor, fase ops),
                                    cada uma num diretório descartável, com oute-propose/oute-inbox/sudo/ssh trocados por
                                    dublês (nada chega ao canal de aprovação nem ao host). Tarefas: root (propõe com --root,
                                    não chama sudo), select (oute-select igual ao direto), worktree (escrita cai na worktree),
                                    emit (oute-emit do Bash tool entrega ou vai ao spool) e studio (a conversa chegou ao
                                    agent-studio com o oute.task.id do teste; sem AGENT_STUDIO_URL/AGENT_STUDIO_READ_TOKEN:
                                    não verificado). Grader em bash, lê efeitos; nenhum LLM julga.
  --rounds N (padrão 3): a tarefa só é vermelha se falhar em mais de uma rodada. --codex: roda também a tarefa root com
  `codex exec` (sem a flag o Codex não é chamado). Com `oute-quota` e qualquer janela >= 60%, não começa (aviso).
  Ao fim emite oute.regression.run (imagem, CLIs, rodadas, verde/vermelho por tarefa, custo) pelo oute-emit, sem texto de
  prompt nem de resposta. Rode depois de uma release com mudança de imagem ou de um upgrade dos CLIs (~2 min, centavos de
  dólar por rodada). Nunca em CI e nunca bloqueia merge. Saída: 0 verde, 1 alguma tarefa vermelha, 2 não rodou.

## CONTAINER — eventos operacionais (oute-emit, ADR-04)
  Rodadas do swarm, pedidos do canal e sessões do oute-task vão como logs OTel (oute.swarm.*,
  oute.canal.*, oute.task.*) ao bucket e ao agent-studio (ADR-08), com a origem do host. A saída do script executado no host nunca vai.
  O oute-swarm, o oute-propose, o oute-task e o oute approve chamam sozinhos; falha nunca muda o comando.
  Endpoint e origem: OTEL_* do ambiente; sem elas (o shell do Bash tool do Claude Code não as
  herda), do ~/.oute_env, só lido (variável com valor no ambiente vence, uma a uma).
  oute-emit canal <id>              emite a fase atual do pedido (proposto ou decidido)
  oute-emit swarm <rodada> <linha>  emite uma linha do log da rodada
  oute-emit task <opened|reopened|removed> <quem chamou> chave=valor…
                                    (o oute-task usa) emite o evento da sessão, sem corpo
  oute-emit quota <spawn|close|open>  (o oute-swarm e o oute-task usam, em segundo plano) lê o
                                    oute-quota --json e emite oute.quota.used_pct e
                                    oute.quota.reset_in_seconds por agente e janela (métricas) e
                                    oute.quota.unknown com o motivo; sem coleta periódica (#347)
  oute-emit backfill                uma vez por host: manda o histórico anterior ao corte
                                    (~/.oute/emit/since) com a hora original; resumo no stderr;
                                    rodar de novo não emite nada (retoma se falhou no meio)
  oute-emit backfill --from <ISO> [--to <ISO>] [--dry-run]
                                    a janela [from, to) pela hora do fato (ex.: 2026-09-30T00:00:00Z),
                                    sem olhar o corte nem o backfill.done; reenvia tudo da janela (o
                                    agent-studio deduplica pelo oute.event.id); retoma por janela;
                                    --dry-run só mostra o resumo por tipo, sem enviar (#261)
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
  Opt-in OUTE_MEMORY_RUN=1 (#367, desligado por padrão): a sessão interativa de worktree abre sob
  `ai-memory run` (sem --yolo; headless, subcomando e resume passam direto). Só com ele:
  cota estourou → saia do claude e rode `ai-memory run codex` na mesma worktree.

## herdr (básico)
  prefix+c nova aba · prefix+v split direita · prefix+- split abaixo · prefix+q detach
  herdr agent list                  estado dos agentes (idle/working/blocked/done)
