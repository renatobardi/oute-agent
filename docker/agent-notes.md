## Host actions (oute-server / Mac): approval channel

Container has **no host privilege**. `ssh oute-server` = `oute-ops`: read-only + sudo allowlist (backup status, `nginx -t`/reload, `certbot certificates`, `nft list ruleset`, `lab-journal`). Never bypass.

To run on the host as its user or **sudo/root**:

1. **Never ask the user to copy commands.** Write a script, propose it:
   ```bash
   OUTE_PROPOSE_AGENT=<claude|codex> oute-propose "título curto e claro" [--root] <<'SH'
   set -euo pipefail
   echo "o que vai fazer..."
   # comandos
   SH
   ```
   Prints request `id`. `--root` = sudo; without it, host user.
2. User reads whole script, approves/rejects on host with `oute approve`.
3. Wait for the result (output + exit code): `oute-inbox --wait <id>`. Exit 3 = pending/expired.

Script: bash, `set -euo pipefail`, idempotent, one goal per request, `echo` before each step, no secrets in text, nothing interactive. Read state first (via `ssh oute-server`); propose only what is needed.
**Summary and warning in the script (#480).** Every script opens with a `# RESUMO` comment block, in this order: what it does, which host, what it changes, what it does **not** touch, whether it restarts anything. Before each step that **removes, recreates, stops or cannot be undone**: a line `# CUIDADO: <o que o passo faz>. <o que se perde>.` (command first, risk after; "não se desfaz" when so). Warning states the real effect: no exaggeration, no reassurance. Write "não toca em X" only if the script guarantees it (e.g. a check before the step). Both blocks are comments: script runs the same without them. Example:
   ```bash
   set -euo pipefail
   # RESUMO
   # Faz: troca o volume `oute-x`. Host: oute-server. Altera: o volume `oute-x`. Não toca: `oute-memory` (o passo 1 para se achar outro dependente). Reinicia: o container `oute-x`.
   echo "1/2: confere os dependentes"
   # comandos de leitura
   # CUIDADO: `docker volume rm oute-x` apaga o volume. Os dados dele se perdem e não se desfaz.
   echo "2/2: remove o volume"
   docker volume rm oute-x
   ```
Request that **removes, recreates or stops** a host resource (volume, container, file, service): first lists in the script what depends on it and **stops without changing anything** if a dependent is unexpected; or is preceded by a rehearsal request (`--dry-run`/read-only).
Pending request **obsolete** (previous failed, plan changed): tell the user to **reject it before** proposing the replacement; replacement's title says it **replaces** the old one (e.g. "substitui <id>: …").
**Release, deploy, deploy verification: read the queue first (#650).** Before proposing one, read the channel queue (`oute-inbox`, lists pending requests) and open rounds (`oute-swarm busy`, lists issues with a session open in another round). If **another session** has a pending release or deploy request, do not propose another: tell the Bardi (which request, which session) and wait. A deploy request states in `# RESUMO` which rounds are open and which sessions go down with `oute down`/`up`.

**Permanent** oute-server config change: `lab` repo flow (issue → inventory → script → PR). The channel is for diagnosis, one-off adjustments, and deploying an already merged PR.

## Memory (ai-memory): explicit scope

ai-memory tools (`memory_query`, `memory_recent`, `memory_write_page`, `memory_status`, handoffs…): **always pass `workspace` and `project`**:
- values from `.ai-memory.toml` at the repo root (also inside a git worktree);
- no file: `workspace = "default"`, `project` = main repo name (`basename` of `git rev-parse --path-format=absolute --git-common-dir` without `/.git`);
- outside a repo: ask the user before writing.
- **First step, before loading (ToolSearch) or calling any memory tool: read `.ai-memory.toml` with the Read tool** and copy `workspace` and `project`. Never call with `default` without reading the file; with the file at the root, `default` and the folder name are wrong.
Why: unscoped, the server uses the shared "active project", maybe another session's repo.
Only with opt-in `OUTE_MEMORY_RUN=1` (off by default): the interactive worktree session runs under `ai-memory run`. Quota exhausted: exit claude, run `ai-memory run codex` in the same worktree; it gets the conversation context. The explicit `workspace`/`project` rule still applies.

## Git: one session = one worktree + one branch

- Each session in its **own worktree** (`/workspace/.worktrees/<space>/<repo>-<slug>`, branch `sessao/<slug>`; `<space>` = herdr space as folder name, `_sem-space` outside one), opened by `oute-task`. The container shell does it when the user types `claude`/`codex` in the main checkout.
- **Before creating, editing or committing any file, run `git rev-parse --git-dir --git-common-dir`.** Both equal = main checkout: do not create, edit or commit, even if the user says "do it now"; only warn and suggest `oute-task <slug>`.
- **Never edit or switch branch in the main checkout** (`/workspace/<repo>`, always the default branch). If you are in it (`git rev-parse --git-dir` = `--git-common-dir`): change nothing, warn the user, suggest `oute-task <slug>`. Only exception: `git pull --ff-only` there, on the default branch, no local change, without asking (`oute-task clean --yes` does it).
- Before the first push: `git branch -m …` to `<tipo>/<issue>-<slug>`; types: `feat`, `fix`, `chore`, `docs`, `refactor`, `test`.
- Small commits, conventional messages. Deliver by PR (`gh pr create`). **Merge only when the user asks.**
- After merge: `oute-task clean` lists what can be removed; `oute-task clean --yes` removes. Both act only on the current herdr space (`--space <nome>`: another; `--all`: all, including old-format worktrees directly under `/workspace/.worktrees`).
- `oute-task clean` also lists one line per open ai-memory handoff of removed worktrees (`handoff id=<id> workspace=<W> project=<P> cwd=<worktree>`), but **never cancels**. After `clean --yes`, cancel each such line with `memory_handoff_cancel` (`id`, with the line's `workspace` and `project`) and say how many you cancelled; without `memory_*` tools, say you did not cancel. A line `aviso: …` = listing failed: cancel nothing by guess. Never use `ai-memory handoffs --expire-all`: it also expires handoffs of live worktrees.

## Same container: process and merge (#538)

One container, all sessions the same user: `ps`/`pgrep` show other sessions' processes, and GitHub records every merge as the same account.

- **Merging a PR of an open round is not yours.** PR of an open swarm round (`~/.oute/swarm/<rodada>/spawned` has its issue's session and no `fechada` file): refuse, even if the Bardi says "pode fazer merge". Tell him: which round, that the merge goes through that round's dispatcher (branch `sessao/<rodada>`), and the last audit state (PR comment with `<!-- oute-aidlc-qa-pr-audit -->`: audited head and action, or "sem auditoria"). `gh pr merge` already refuses it (exit 77). Only the round's dispatcher merges it.
- **Only kill a process you opened**, by the PID or task id you kept. `pkill` and `killall` (and `pkill -f`) are refused in agent sessions: they kill by name and hit other sessions.
- **"What is running":** list first what you opened (your task list), then separately what belongs to another session, with the owner when known. Never call "from this session" what came from `ps` or `pgrep`.
- **Merge comment:** a standalone session that merges (PR outside a round, at the Bardi's request) comments on the PR before or with it: the session (worktree and id), "a pedido do Bardi" or the authorization used, the merged head. The dispatcher uses its own format (`docker/swarm.md`).
- **Limits:** the merge lock and `pkill` block protect against mistakes, not against circumvention (`gh` API, `bash -c`, another binary). They do not apply to a merge the Bardi does on the website. The `pkill` hook also has a false positive: quoted text with `pkill` or `killall` right after `;`, `&&` or `|` (e.g. `git commit -m "a; pkill x"`) is refused though nothing runs; rewrite the text without the word there.

## Issues and repo context

- Backlog = the repo's **own GitHub issues** via `gh` (`gh issue view <n> --json title,body,comments --jq '"# " + .title + "\n\n" + .body + "\n\n## Comentários\n" + (.comments | map("--- " + .author.login + " " + .url + "\n" + .body) | join("\n\n"))'`, `gh issue create`, `gh issue comment`, `gh issue close`). Pending at task end becomes an issue.
- **Before every `gh issue create`, run `gh issue list --state open --search '<arquivo ou termo> in:title,body'`.** Never create without that search. If an open issue exists on the same point, new evidence goes in a comment on it (`gh issue comment <n>`), not a new issue.
- Before starting, read **`AGENTS.md`** and **`CONTEXT.md`** at the repo root, if present. ADRs in `docs/adr/` are canonical; `CONTEXT.md` = summary + glossary. Missing or conflicting: ask, do not assume.
- Work follows **AI-DLC** (oute-agent ADR-07) (phases `strat` → `iter`, each human-gated): flow skills `oute-aidlc-<fase>-<id>`; never close a gated phase without the user's ok.
- Never write secrets to a file, commit, issue, PR or command output. Secrets come through the environment.
- **Do not read a secret's value**: no `Read`, `cat`, or `grep` without `-q` on `.env`, a key or a token (the value enters the conversation). To check a variable is filled, use a test that prints no value, e.g. `if grep -q '^VAR=.' .env; then echo preenchida; else echo vazia; fi`.

## Text for the Bardi

- **Text for the Bardi** (PR, issue comment, report, channel request, `BLOQUEADO`) follows `docs/pt-controlado.md` (#478). **Write it in pt-BR**, even if the prompt, skill or source is in English. Every claim cites a source the Bardi can open (link, `arquivo:linha@sha`, issue or PR), never a scratchpad or temp-file path; no source: write "não verificado". Recommendation only with a source, or labelled "recomendação do autor". Rewriting does not change a fact, condition or value. Write "fazer merge", never "mergear".
- **Haiku session: final wording goes to a Sonnet subagent (#481).** Text with a decision or risk for the Bardi (PR body, report, proposal, channel script, summary with options) is not left to Haiku's wording. Haiku hands the final wording to a Sonnet subagent (`Agent` tool, `model: "sonnet"`), giving it the facts, the sources and the rules of `docs/pt-controlado.md`. Before publishing, check the subagent's text against the facts: every number, condition and source must match what you passed, no new fact. If not, fix it or ask for a new draft. **Own model:** read the model id in the session context ("You are powered by the model named …" and its id). Id with `haiku` = Haiku. No id: treat as Haiku. **No subagent** (no `Agent` tool, or the Sonnet subagent fails): publish your own text and say on its first line that it came from Haiku and was not reviewed by Sonnet. A Sonnet or Opus session writes it itself and skips this rule.
