# Task Runner Setup Guide

This guide explains how to set up the current Docker-based task runner that:

- clones all repos for a project family into an isolated container
- runs a Codex-backed sub-agent inside that container
- opens PRs automatically when work succeeds
- requires screenshots or video for UI-affecting changes
- can restore a DB dump and run migrations when the repo needs local database state

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                   Task Runner System                        │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Base Image (task-runner-base)                              │
│  - Node.js 20                                               │
│  - Git, GitHub CLI                                          │
│  - Screen recording (FFmpeg, Xvfb)                         │
│  - Playwright for E2E tests                                 │
│                                                             │
│  Project Images (task-healthtrac, task-neptune, etc.)      │
│  - Inherit from base image                                  │
│  - Add project-specific tools                               │
│                                                             │
│  Task Containers (isolated, per-task)                       │
│  - Clone ALL related repos                                  │
│  - Run repo-specific setup                                  │
│  - Execute task script                                      │
│  - Create PR with screenshots                               │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## Project Families

Each project family groups related repositories that should be cloned together. The runner reads these from `~/.task-project-config.sh`.

| Family | Repositories | Primary Repo |
|---|---|---|
| `healthtrac` | `HT360_Web arsmetr_backend arsmetr_mobile` | `HT360_Web` |

## Setup

### 1. Build The Base Image

From this repo:

```bash
cd /home/ubuntu/multi-agent-github-workflow/orchestrator
docker build -f Dockerfile.base -t task-runner-base:latest .
```

The base image currently includes:

- Node.js 20
- Git and GitHub CLI
- Playwright + Chromium
- FFmpeg, Xvfb, Fluxbox, screenshot tools
- `@openai/codex`
- `@qwen-code/qwen-code`

### 2. Prepare Host Credentials

The runner expects these host-side files and directories:

- `~/.ssh/github_key`
  Used inside the container for cloning and pushing.
- `~/.gh_token`
  Used by `gh pr create` inside the container.
- `~/.codex/`
  Mounted into the container so `codex exec` is already authenticated.

Optional:

- `~/.modal.toml`
- `MODAL_TOKEN_ID`
- `MODAL_TOKEN_SECRET`
- `MODAL_PROFILE`

Those are only needed if you still use a Modal-backed model path for non-Codex flows.

### 3. Configure Project Families

Create `~/.task-project-config.sh`:

```bash
healthtrac_repos="HT360_Web arsmetr_backend arsmetr_mobile"
healthtrac_primary="HT360_Web"

HT360_Web_url="git@github.com:sorogersep/HT360-Web.git"
arsmetr_backend_url="git@github.com:healthtrac/arsmetr-backend.git"
arsmetr_mobile_url="git@github.com:healthtrac/arsmetr-mobile.git"
```

The runner uses this file to decide:

- which repos to clone into the container
- which repo is the primary working directory
- which git remotes to use

### 4. Configure Model Selection

Create `~/.task-model-config.sh`:

```bash
export SUBAGENT_MODEL="codex"

# Optional fallbacks for non-Codex flows
# export SUBAGENT_FALLBACK_MODELS="codex/gpt-5.4-mini,qwen"

# Optional OpenClaw vLLM provider settings
# export OPENCLAW_VLLM_BASE_URL="https://example.com/v1"
# export OPENCLAW_VLLM_MODEL_ID="qwen"
# export OPENCLAW_VLLM_API_KEY="..."
```

### 5. Run A Task

The current runner entrypoint is:

```bash
/home/ubuntu/multi-agent-github-workflow/orchestrator/task-run.sh \
  --project healthtrac \
  --task stop-time-purple-indicator \
  --desc "Implement purple border fix" \
  --script /home/ubuntu/tasks/scripts/stop-time-purple-indicator.sh
```

The task script is copied into the container as `/workspace/task.sh`.

Minimal template:

```bash
set -e

SUBAGENT_FOREGROUND=1 /workspace/spawn-subagent.sh \
  'Inspect the stop-time indicator styling and remove the purple border without regressing the rest of the UI state handling.' \
  stop-time-purple-indicator \
  20 \
  codex
```

## Runtime Behavior

For each task, the runner:

1. starts a fresh Docker container from `task-runner-base:latest`
2. mounts host SSH, GitHub token, and Codex auth
3. clones every repo in the project family
4. switches into the primary repo
5. runs `npm install` when `package.json` exists
6. runs the task script
7. if changes are meaningful, creates a branch, pushes it, and opens a PR

If the sub-agent exits successfully but only changes metadata or makes no meaningful app changes, the run fails.

## UI Artifact Rules

UI-affecting tasks are now enforced to leave visual evidence.

Each task automatically captures:

- screenshots or videos produced by Playwright, Cypress, or explicit screenshot steps
- a host-side artifact mirror under `~/tasks/logs/<task>.artifacts`
- PR comments that link to the committed artifact files

If a task changes UI-related files but produces no screenshots or video, the run fails.

Committed repo location:

- `e2e/screenshots/task-<task>/`

Host mirror location:

- `~/tasks/logs/<task>.artifacts/`

Important note for private repos:

- raw GitHub image URLs may 404
- use clickable GitHub blob links in PR comments instead of assuming public raw embeds

## Database Dumps And Migrations

The sub-agent mission brief now explicitly requires this behavior:

- if the repo contains a DB dump, seed file, or snapshot needed for local behavior,
- install or start the required database service,
- restore the dump,
- run the relevant migrations,
- then verify the change

This is instruction-level enforcement for the agent. The runner itself does not yet auto-detect and restore dumps on its own.

## Monitoring

```bash
tail -f ~/tasks/logs/<task>.log

ls ~/tasks/logs/<task>.artifacts
```

Failed tasks preserve the container for inspection instead of deleting it immediately.

## Cleanup

```bash
docker container prune -f
docker image prune -f
```

## Notes

- The current implementation is optimized for `codex`.
- `rg` is not installed in the container today, so agents may fall back to `grep`/`find`.
- The wrapper prefers `docker`, but falls back to `sudo docker` if the current user cannot access the Docker socket.
