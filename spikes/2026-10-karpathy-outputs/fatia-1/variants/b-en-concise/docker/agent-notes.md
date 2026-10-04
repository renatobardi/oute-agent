## Host actions (oute-server / Mac) — approval channel

You run in a container **with no host privilege**. `ssh oute-server` logs in as `oute-ops`: read-only plus a sudo allowlist (backup status, `nginx -t`/reload, `certbot certificates`, `nft list ruleset`, `lab-journal`). Do not try to bypass this.

When something must run on the host as its user or with **sudo/root**:

1. **Do not ask the user to copy commands.** Write a script and propose it:
   ```bash
   OUTE_PROPOSE_AGENT=<claude|codex> oute-propose "título curto e claro" [--root] <<'SH'
   set -euo pipefail
   echo "o que vai fazer..."
   # comandos
   SH
   ```
   Prints the request `id`. `--root` = runs with sudo; without it, runs as the host user.
2. The user reads the whole script and approves (or rejects) it on the host with `oute approve`.
3. Wait and read the result (output + exit code): `oute-inbox --wait <id>`. Exit 3 = still pending/expired.

Script rules: bash, `set -euo pipefail`, idempotent, one goal per request, `echo` before each step, no secrets in the text, nothing interactive. Read the state first (via `ssh oute-server`) and propose only what is needed.
A request that **removes, recreates or stops** a host resource (volume, container, file, service) first lists, in the script itself, what depends on it and **stops without changing anything** if it finds an unexpected dependent; or is preceded by a rehearsal request (`--dry-run`/read-only).
A pending request that became **obsolete** (the previous one failed, the plan changed): tell the user to **reject it before** you propose the replacement, and the replacement's title says it **replaces** the previous one (e.g.: "substitui <id>: …").

A **permanent** change to the oute-server configuration follows the `lab` repository flow (issue → inventory → script → PR). The approval channel is for diagnosis, one-off adjustments and running the deploy of an already merged PR.

## Memory (ai-memory) — always with explicit scope

In the ai-memory memory tools (`memory_query`, `memory_recent`, `memory_write_page`, `memory_status`, handoffs…), **always pass `workspace` and `project`**:
- values from `.ai-memory.toml` at the root of the repository you are working in (also holds inside a git worktree);
- without that file: `workspace = "default"` and `project` = main repository name (`basename` of `git rev-parse --path-format=absolute --git-common-dir` without the `/.git`);
- outside a repository, ask the user before writing.
Reason: without scope, the server uses the shared "active project", which may be another session's in another repo.
With the opt-in `OUTE_MEMORY_RUN=1` (off by default; applies only with it), the worktree's interactive session runs under `ai-memory run`. Quota exhausted: exit claude and run `ai-memory run codex` in the same worktree; it receives the conversation context. The explicit `workspace`/`project` rule still applies.


## Git: one session = one worktree + one branch

- Every session runs in **its own worktree** (`/workspace/.worktrees/<space>/<repo>-<slug>`, branch `sessao/<slug>`; `<space>` = herdr space as a folder name, `_sem-space` outside it), opened by `oute-task`. The container shell already does this when the user types `claude`/`codex` in the main checkout.
- **Never edit or switch branches in the main checkout** (`/workspace/<repo>`), which always stays on the default branch. If you are in it (`git rev-parse --git-dir` equal to `--git-common-dir`), change nothing: tell the user and suggest `oute-task <slug>`. Only exception: `git pull --ff-only` in it, on the default branch and with no local change, may be done without asking (`oute-task clean --yes` already does it).
- Before the first push, rename the branch to `<tipo>/<issue>-<slug>` (`git branch -m …`); types: `feat`, `fix`, `chore`, `docs`, `refactor`, `test`.
- Small commits, conventional-commit messages. Deliver by PR (`gh pr create`). **Merge only when the user asks.**
- After the merge, `oute-task clean` lists what can be removed; `oute-task clean --yes` removes it. Both act only on the current herdr space (`--space <nome>`: another one; `--all`: all, including worktrees in the old format, directly under `/workspace/.worktrees`).

## Issues and repository context

- Backlog = **GitHub issues of the repo itself**, via `gh` (`gh issue view <n> --comments`, `gh issue create`, `gh issue comment`, `gh issue close`). Whatever is left pending at the end of the task becomes an issue. Before `gh issue create`, search for an **open** issue on the same point: `gh issue list --state open --search '<arquivo ou termo> in:title,body'`. If one exists, the new evidence goes in a comment on it (`gh issue comment <n>`), not in a new issue.
- Before starting, read **`AGENTS.md`** and **`CONTEXT.md`** at the repo root, if they exist. The ADRs in the repo's `docs/adr/` are canonical; `CONTEXT.md` is the summary with a glossary. If something is missing or conflicts, ask instead of assuming.
- Work follows the **AI-DLC** (ADR-07 of oute-agent) (phases `strat` → `iter`, each with a human gate): flow skills `oute-aidlc-<fase>-<id>`; do not close a gated phase without the user's ok.
- Never write secrets to a file, commit, issue, PR or command output. Secrets arrive through the environment.
