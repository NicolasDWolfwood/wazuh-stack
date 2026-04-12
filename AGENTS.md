# Agent Instructions

This repository is a Docker Compose deployment for Wazuh plus `syslog-ng`, intended for an Unraid-style environment.

## Working Style

- Use the repository root as the working directory.
- Prefer fast local inspection tools such as `rg`, `sed`, and `git diff`.
- Treat `.env` as deployment-specific state. Do not rewrite it unless the user explicitly asks.
- Keep `.env.example` as a template with guidance, not as a populated live config.

## Git

Agents are allowed to use `git` for normal repository work, including:

- `git status`
- `git diff`
- `git add`
- `git commit`
- `git log --oneline`

Do not use destructive commands such as `git reset --hard`, `git checkout --`, or history rewrites unless the user explicitly requests them.

## Docker

Agents are allowed to use Docker and Docker Compose commands for validation and stack operations.

Preferred commands:

- `docker compose config`
- `./scripts/docker-compose-host.sh config`
- `./scripts/docker-compose-host.sh up -d`
- `./scripts/docker-compose-host.sh down`
- `./scripts/docker-compose-host.sh logs --tail=200 <service>`
- `./scripts/docker-compose-host.sh ps`

Notes:

- Prefer `./scripts/docker-compose-host.sh` for Compose operations in this repo. It handles native Docker and the WSL-to-Docker-Desktop fallback.
- Use `docker compose config` or the wrapper script's `config` command to validate Compose changes after editing `docker-compose.yml` or `.env.example`.
- Avoid tearing down or restarting the live stack unless the user asked for it.

## Project Workflow

Typical safe workflow:

1. Inspect current files and `git diff`.
2. Make the requested change.
3. Validate with `docker compose config` when Compose or env templates changed.
4. Summarize the result clearly, including any commands that could not be run.

## Repo-Specific Files

- `docker-compose.yml`: main stack definition
- `.env.example`: template for user-supplied environment values
- `.env`: live local environment values
- `scripts/bootstrap-appdata.sh`: builds appdata layout and renders config from `.env`
- `scripts/docker-compose-host.sh`: preferred wrapper for Compose commands
- `generate-indexer-certs.yml`: one-off Compose file for certificate generation

## Environment Assumptions

- External Docker networks referenced by `.env` must already exist.
- Static container IPs are intentional in this stack.
- Public TLS is expected to be handled upstream, for example by Nginx Proxy Manager.
