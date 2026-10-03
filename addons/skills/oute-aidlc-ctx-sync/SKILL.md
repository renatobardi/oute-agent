---
name: oute-aidlc-ctx-sync
description: Use quando um ADR de `docs/adr/` for criado ou alterado, ou quando pedirem para conferir a coerência do contexto (`CONTEXT.md`, `AGENTS.md`, notas globais) com os ADRs.
---

# oute-aidlc-ctx-sync

Fase: `ctx` (AI-DLC, ADR-07) · Outcome: tabela de divergências entre os ADRs e os resumos, ou a lista do que foi conferido sem divergência · Gate: Bardi aprova cada ajuste, item a item.

O ADR é o canônico; `CONTEXT.md`, `AGENTS.md` e `docker/agent-notes.md` (as notas globais) são resumos e ficam para trás quando um ADR muda. A comparação é de **sentido**, não de texto: leia e julgue, sem script.

## Regras

- **Nunca proponha mudar um ADR.** Só os resumos mudam para acompanhar o ADR.
- **Conflito entre dois ADRs** não se resolve aqui: vira pergunta ao Bardi, com os dois trechos citados.
- **Arquivo ausente** (`CONTEXT.md`, `AGENTS.md`, `docker/agent-notes.md` ou `docs/adr/`): avise e siga com os que existem.

## Passos

1. **Escolher os ADRs.** Por padrão, os de `docs/adr/` alterados depois do último commit de `CONTEXT.md` e do último de `AGENTS.md`:
   - `git log -1 --format=%H -- CONTEXT.md` e o mesmo para `AGENTS.md` (use o mais antigo dos dois como corte);
   - `git log --name-only --format= <corte>..HEAD -- docs/adr/` lista os ADRs alterados. Inclua os não commitados (`git status --short docs/adr/`).
   - Se o usuário pediu "todos", use todos os ADRs. Fim do passo: lista dos ADRs a conferir, dita ao usuário.
2. **Conferir cada ADR.** Leia o ADR inteiro, adendos incluídos, e compare **status**, **decisões** e **adendos** com:
   - `CONTEXT.md`: seções "Decisões" e "Glossário";
   - `AGENTS.md`: regras, mapa do repo e tabela do fluxo AI-DLC;
   - `docker/agent-notes.md`.

   Procure: decisão que o resumo contradiz ou não menciona, ADR substituído ou revogado ainda citado como vigente, termo do glossário com sentido diferente, regra que o adendo mudou. Fim do passo: cada ADR da lista foi lido e comparado com os três arquivos (ou com os que existem).
3. **Devolver o resultado.**
   - Com divergência, uma tabela:

     | ADR e trecho | Resumo (`arquivo:linha`) | Texto proposto |
     |---|---|---|

   - Sem divergência, diga isso e liste o que conferiu: os ADRs e os arquivos.
4. **Aplicar só com o ok.** Pergunte ao Bardi e aplique **item a item**, só os que ele aprovar, na worktree da sessão (nunca no checkout principal). Entrega por PR; mudança visível entra no changelog por fragmento (`changelog.d/`).
