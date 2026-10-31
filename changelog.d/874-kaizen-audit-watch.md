### Changed
- **PR audit dispatches the workflow a criterion names** (#874, lesson 1). `oute-aidlc-qa-pr-audit` runs `gh workflow run --ref <branch>` before recommending `merge como está` when a criterion is "a workflow does X", and asks the Bardi first if the dispatch has an external effect. **Needs a release** (the skill is copied into the image).

### Fixed
- **`oute-swarm watch` no longer reports `sem PR` for a session whose branch has an open PR** (#874, lesson 3). The PR is looked up on the branch of the session worktree, so a session with a sub-item id (`1b-…`) or a renamed branch is matched too; the event reads `(PR #n open)` and the `done sem PR` pending line is not repeated. **Needs a release** (`docker/oute-swarm` is copied into the image).
