### Changed
- **Worker confirms declared GitHub settings** (kaizen swarm-1025-1957). Before opening the PR, the worker confirms with a read-only `gh api` call every GitHub setting the PR body declares as applied, and writes "not verified" otherwise. **Needs release** (`docker/swarm-worker.md` goes into the image).
