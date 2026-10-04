## Host actions (oute-server / Mac) — approval channel

You run in a container **without privilege on the host**. `ssh oute-server` logs in as `oute-ops`. This user has read access and a sudo allowlist only (backup status, `nginx -t`/reload, `certbot certificates`, `nft list ruleset`, `lab-journal`). Do not try to bypass this limit.

When something must run on the host as the host user or with **sudo/root**:

1. **Do not ask the user to copy commands.** Write a script and propose it:
   ```bash
   OUTE_PROPOSE_AGENT=<claude|codex> oute-propose "título curto e claro" [--root] <<'SH'
   set -euo pipefail
   echo "o que vai fazer..."
   # comandos
   SH
   ```
   The command prints the `id` of the request. `--root` = the script runs with sudo. Without `--root`, the script runs as the host user.
2. The user reads the full script and approves (or rejects) it on the host with `oute approve`.
3. Wait and read the result (output + exit code): `oute-inbox --wait <id>`. Exit code 3 = the request is still pending or it expired.

Rules for the script:
- bash;
- `set -euo pipefail`;
- idempotent;
- one goal for each request;
- `echo` before each step;
- no secrets in the text;
- nothing interactive.

Read the state first (through `ssh oute-server`). Propose only what is necessary.
A request that **removes, recreates or stops** a host resource (volume, container, file, service) must obey one of these two rules. The script first lists what depends on the resource, and **stops without a change** if it finds a dependent that is not expected. Or a rehearsal request (`--dry-run`/read only) comes before the request.
A pending request can become **obsolete** (the previous request failed, the plan changed). Tell the user to **reject it before** you propose the replacement request. The title of the replacement request says that it **replaces** the previous request (example: "substitui <id>: …").

A **permanent** change to the configuration of the oute-server follows the flow of the `lab` repository (issue → inventory → script → PR). Use the approval channel for diagnosis, for one-time adjustments and to run the deploy of a merged PR.

## Memory (ai-memory) — always with explicit scope

In the memory tools of ai-memory (`memory_query`, `memory_recent`, `memory_write_page`, `memory_status`, handoffs…), **always pass `workspace` and `project`**:
- Use the values from `.ai-memory.toml` at the root of the repository where you work (this also applies in a git worktree).
- Without this file, use `workspace = "default"` and `project` = the name of the main repository (`basename` of `git rev-parse --path-format=absolute --git-common-dir` without the `/.git`).
- Out of a repository, ask the user before you write.

Reason: without a scope, the server uses the shared "active project". That project can be the project of a different session in a different repo.
The opt-in `OUTE_MEMORY_RUN=1` is off by default, and the next rule applies only with it. With the opt-in, the interactive session of the worktree runs under `ai-memory run`. If the quota is exhausted, exit claude and run `ai-memory run codex` in the same worktree. Codex receives the context of the conversation. The rule of explicit `workspace`/`project` continues to apply.


## Git: one session = one worktree + one branch

- Each session runs in **its own worktree** (`/workspace/.worktrees/<space>/<repo>-<slug>`, branch `sessao/<slug>`). `<space>` = the herdr space as a folder name, or `_sem-space` out of herdr. `oute-task` opens the worktree. The container shell already does this when the user types `claude`/`codex` in the main checkout.
- **Do not edit and do not change branch in the main checkout** (`/workspace/<repo>`). The main checkout always stays on the default branch. If you are in the main checkout (`git rev-parse --git-dir` equal to `--git-common-dir`), do not change anything. Tell the user and suggest `oute-task <slug>`. There is one exception. You can run `git pull --ff-only` in the main checkout without a question, on the default branch and with no local change (`oute-task clean --yes` already does this).
- Before the first push, rename the branch to `<tipo>/<issue>-<slug>` (`git branch -m …`). The types are: `feat`, `fix`, `chore`, `docs`, `refactor`, `test`.
- Make small commits, with the message in the conventional standard. Deliver through a PR (`gh pr create`). **Merge only when the user asks.**
- After the merge, `oute-task clean` lists what can be removed, and `oute-task clean --yes` removes it. The two commands act only on the current herdr space. `--space <nome>` selects a different space. `--all` selects all spaces, and includes the worktrees in the old format, directly in `/workspace/.worktrees`.

## Issues and repository context

- Backlog = **GitHub issues of the same repo**, through `gh` (`gh issue view <n> --comments`, `gh issue create`, `gh issue comment`, `gh issue close`). What stays pending at the end of the task becomes an issue. Before `gh issue create`, look for an **open** issue about the same point: `gh issue list --state open --search '<arquivo ou termo> in:title,body'`. If one exists, write the new evidence in a comment on that issue (`gh issue comment <n>`), not in a new issue.
- Before you start, read **`AGENTS.md`** and **`CONTEXT.md`** at the root of the repo, if they exist. The ADRs in `docs/adr/` of the repo are the canonical source. `CONTEXT.md` is the summary with a glossary. If something is absent or conflicts, ask the user. Do not assume.
- The work follows the **AI-DLC** (ADR-07 of oute-agent) (phases `strat` → `iter`, each phase with a human gate). The flow skills are `oute-aidlc-<fase>-<id>`. Do not close a phase that has a gate without the ok of the user.
- Do not write secrets in a file, commit, issue, PR or command output. The secrets arrive through the environment.
