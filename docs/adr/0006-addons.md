# ADR-06 — Addons: pasta do monorepo montada read-only (issue #53)

Status: **aceito** (2026-09-26). Saído do grilling da #53. Adendo 2026-09-27: nome de skill de fluxo e skills importadas do Matt Pocock (ADR-07).

## Contexto
- O ADR-01 deixava em aberto um repo separado `oute-agent-plugins` para as skills. Esse repo nunca foi criado.
- "Plugin" já tem dois donos nativos: o plugin do Claude Code e o plugin herdr (ADR-05). O guarda-chuva passa a se chamar **addon** (skill, persona, script, plugin herdr). Vocabulário no `CONTEXT.md`.
- Claude, Codex e Pi leem o mesmo formato de skill (`SKILL.md`, agentskills.io). Claude procura em `~/.claude/skills`; Codex e Pi, em `~/.agents/skills`.

## Decisão
Os addons ficam em `addons/<tipo>/` **neste repo**. O compose monta a pasta **read-only** a partir do checkout do host, e o entrypoint cria um link por addon nas pastas de cada harness. Addon novo ou alterado entra com `git pull` + `oute down/up`, sem release, como `config/`.

Regras:
- Todo addon leva o prefixo `oute-`, inclusive plugin herdr.
- O entrypoint não sobrescreve um nome que já existe (por exemplo, skills `synced` do claude.ai ou `.system` do Codex). Nesse caso, loga um aviso e segue. Links quebrados que apontam para o mount são removidos.
- Sem o mount, o container sobe normalmente e só loga um aviso.
- **Primitivo** (canal de aprovação, `oute-task`, `oute-swarm` e seus prompts) continua na imagem. Um primitivo pode citar um addon, mas sempre com plano B inline: nunca depende dele.
- Skill importada é fork sem volta, com procedência registrada. Sem licença que permita, o original é só referência e o texto é todo nosso.

## Opções consideradas
- **Repo separado `oute-agent-addons`, clonado no container:** exige repo novo e deixa o clone gravável pelo agente. Só compensaria se os addons fossem usados fora do container, e hoje não são.
- **Copiar para a imagem**, como `agent-notes.md`: cada skill exigiria release.
- **Mount read-only (escolhida):** sem release e sem repo novo. Um agente em yolo não consegue reescrever as próprias skills de forma persistente, o que é coerente com o ADR-01 (container = fronteira).

## Consequências
- Os addons são versionados junto com o oute-agent. Se um dia forem usados fora do container, esta decisão volta para a mesa.
- Mac e oute-server precisam de um checkout atualizado para ver addon novo.
- Persona não é única entre harnesses (o Pi não tem subagente nativo). A conversão por harness fica para issue própria.

## Adendo 2026-09-27 — AI-DLC (ADR-07)
- **Skill de fluxo** (serve a uma fase do AI-DLC) leva `oute-aidlc-<fase>-<id>`. Skill utilitária segue `oute-<id>`. O linker não muda: as duas passam no filtro `oute-*`.
- **Skills de engenharia do Matt Pocock** entram como fork em `addons/skills/oute-aidlc-*`, adaptadas pelo Bardi ao longo do tempo, **sem registro de procedência** (decisão do Bardi): exceção à regra de procedência acima, só para esse conjunto.
- Valem **só no container** do oute-agent (mount de addons). As cópias do Mac (`~/.agents/skills`) ficam como estão, fora deste repo.
