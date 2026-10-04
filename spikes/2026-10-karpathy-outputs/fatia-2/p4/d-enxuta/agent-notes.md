## Host actions (oute-server / Mac): approval channel

Container has **no host privilege**. `ssh oute-server` = `oute-ops`: read-only + sudo allowlist (backup status, `nginx -t`/reload, `certbot certificates`, `nft list ruleset`, `lab-journal`). Never bypass.

To run on host as its user or **sudo/root**:

1. **Never ask user to copy commands.** Write script, propose:
   ```bash
   OUTE_PROPOSE_AGENT=<claude|codex> oute-propose "título curto e claro" [--root] <<'SH'
   set -euo pipefail
   echo "o que vai fazer..."
   # comandos
   SH
   ```
   Prints request `id`. `--root` = sudo; else host user.
2. User reads whole script, approves/rejects on host with `oute approve`.
3. Read result (output + exit code): `oute-inbox --wait <id>`. Exit 3 = pending/expired.

Script: bash, `set -euo pipefail`, idempotent, one goal per request, `echo` before each step, no secrets in text, nothing interactive. Read state first (via `ssh oute-server`); propose only what is needed.
Request that **removes, recreates or stops** a host resource (volume, container, file, service): script first lists its dependents and **stops without changing anything** on unexpected dependent; or a rehearsal request (`--dry-run`/read-only) precedes it.
Pending request **obsolete** (previous failed, plan changed): tell user to **reject it before** proposing the replacement; replacement title says it **replaces** the old (e.g.: "substitui <id>: …").

**Permanent** oute-server config change: `lab` repo flow (issue → inventory → script → PR). Approval channel = diagnosis, one-off adjustments, deploy of an already merged PR.

## Memory (ai-memory): explicit scope

ai-memory tools (`memory_query`, `memory_recent`, `memory_write_page`, `memory_status`, handoffs…): **always pass `workspace` and `project`**:
- values from `.ai-memory.toml` at repo root (also inside a git worktree);
- no file: `workspace = "default"`, `project` = main repo name (`basename` of `git rev-parse --path-format=absolute --git-common-dir` minus `/.git`);
- outside a repo: ask user before writing.
Why: unscoped, server uses shared "active project", maybe another session's repo.
Only with opt-in `OUTE_MEMORY_RUN=1` (default off): interactive worktree session runs under `ai-memory run`. Quota exhausted: exit claude, run `ai-memory run codex` in same worktree; it gets conversation context. `workspace`/`project` rule still applies.

## Git: one session = one worktree + one branch

- Each session in **own worktree** (`/workspace/.worktrees/<space>/<repo>-<slug>`, branch `sessao/<slug>`; `<space>` = herdr space as folder name, `_sem-space` outside one), opened by `oute-task`. Container shell does it when user types `claude`/`codex` in main checkout.
- **Never edit or switch branch in main checkout** (`/workspace/<repo>`; always default branch). If in it (`git rev-parse --git-dir` = `--git-common-dir`): change nothing, tell user, suggest `oute-task <slug>`. Only exception: `git pull --ff-only` there, on default branch, no local change, no asking (`oute-task clean --yes` does it).
- Before first push: `git branch -m …` to `<tipo>/<issue>-<slug>`; types: `feat`, `fix`, `chore`, `docs`, `refactor`, `test`.
- Small commits, conventional messages. Deliver by PR (`gh pr create`). **Merge only when user asks.**
- After merge: `oute-task clean` lists removable; `oute-task clean --yes` removes. Both act on current herdr space only (`--space <nome>`: another; `--all`: all, incl. old-format worktrees directly under `/workspace/.worktrees`).

## Issues and repo context

- Backlog = **repo's own GitHub issues** via `gh` (`gh issue view <n> --comments`, `gh issue create`, `gh issue comment`, `gh issue close`). Pending at task end becomes an issue. Before `gh issue create`, search **open** issue on same point: `gh issue list --state open --search '<arquivo ou termo> in:title,body'`. If exists: new evidence goes in comment (`gh issue comment <n>`), not new issue.
- Before starting read **`AGENTS.md`** and **`CONTEXT.md`** at repo root, if present. ADRs in `docs/adr/` canonical; `CONTEXT.md` = summary + glossary. Missing/conflicting: ask, don't assume.
- Work follows **AI-DLC** (ADR-07 of oute-agent) (phases `strat` → `iter`, each human-gated): flow skills `oute-aidlc-<fase>-<id>`; never close a gated phase without user's ok.
- Never write secrets to file, commit, issue, PR or command output. Secrets come via environment.
