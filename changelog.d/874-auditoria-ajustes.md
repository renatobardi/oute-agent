### Changed
- **Audit dispatch rule tightened** (#874). `oute-aidlc-qa-pr-audit` dispatches a workflow only when the workflow file and every script/action it runs are byte-equal to the base, asks the Bardi first when the run uses secrets or write permissions, and lists `gh workflow run` and `gh run view` in its command allowlist (auditor only). **Needs a release** (the skill is copied into the image).

### Fixed
- **`oute-swarm watch` keeps the earlier session state when the branch PR lookup fails** (#874). The `sem PR` event no longer goes out falsely when `gh` does not answer; it is read again on the next pass. Cross-repository PRs are ignored. **Needs a release** (`docker/oute-swarm` is copied into the image).
