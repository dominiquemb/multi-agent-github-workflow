# Dev Workflow

This repository contains the current Docker-based autonomous development workflow.

## Primary Paths

- [orchestrator/README.md](/home/ubuntu/dev-workflow/orchestrator/README.md)
  Main setup and usage guide for the task runner.
- [orchestrator/task-run.sh](/home/ubuntu/dev-workflow/orchestrator/task-run.sh)
  Host entrypoint that starts a task container, clones repos, runs the task, and opens PRs.
- [orchestrator/docker-dev-container/spawn-subagent.sh](/home/ubuntu/dev-workflow/orchestrator/docker-dev-container/spawn-subagent.sh)
  In-container sub-agent launcher.
- [orchestrator/Dockerfile.base](/home/ubuntu/dev-workflow/orchestrator/Dockerfile.base)
  Base image used by task containers.

## What It Does

- starts an isolated Docker container per task
- clones all repos for a configured project family
- runs a Codex-backed sub-agent inside the container
- opens PRs automatically when the task succeeds
- enforces screenshots or video for UI-affecting changes
- preserves task logs and artifacts on the host
- instructs the agent to restore DB dumps and run migrations when the repo requires local database state

## Start Here

Follow the full setup guide in [orchestrator/README.md](/home/ubuntu/dev-workflow/orchestrator/README.md).

That document covers:

- building `task-runner-base:latest`
- required host credentials such as `~/.ssh/github_key`, `~/.gh_token`, and `~/.codex/`
- `~/.task-project-config.sh`
- `~/.task-model-config.sh`
- running `orchestrator/task-run.sh`
- UI artifact handling and private-repo blob links
- database dump and migration expectations
