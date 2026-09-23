# Changelog

Formato: [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/). Versionamento: [SemVer](https://semver.org/lang/pt-BR/).

## [Unreleased]

### Added
- Runtime container (Ubuntu 24.04 arm64): herdr, Pi, Claude Code, Codex, Goose, ai-memory, gh, oci, gcloud, aws, firebase-tools, rclone, bw, sshd.
- Compose com 3 serviços: `agent`, `jev-router` (LiteLLM + hook Jev via OpenRouter), `ai-memory`.
- Segredos exclusivamente via Vaultwarden (`oute-secrets`).
- CLI de host `scripts/oute` (build/up/attach/ssh/shell/logs/status/sync-shared/version).
- Versionamento: `VERSION`, `CHANGELOG.md`, `scripts/release`, label OCI na imagem.
