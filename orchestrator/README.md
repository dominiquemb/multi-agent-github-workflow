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
- `rtk`

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

Optional for RTK:

- `RTK_ENABLED=1`
  Enables RTK's Codex integration inside each task container using an isolated in-container Codex home.

Optional for repo-local key and env files:

- declare per-project secret file mappings in `~/.task-project-config.sh`
- format: `repo|path/inside/repo|/absolute/host/path`
- separate multiple mappings with `;`

Example:

```bash
healthtrac_secret_files="\
arsmetr_backend|keys/supabase-anon-key.json|/home/ubuntu/task-secrets/healthtrac/arsmetr_backend/keys/supabase-anon-key.json;\
arsmetr_backend|keys/stripe-secret-key.json|/home/ubuntu/task-secrets/healthtrac/arsmetr_backend/keys/stripe-secret-key.json;\
arsmetr_backend|.env|/home/ubuntu/task-secrets/healthtrac/arsmetr_backend/.env"
```

At task startup, the runner mounts those host files read-only into the container and copies them into the declared repo-relative paths after cloning. This is intended for local-only files that are required for tests or server startup but should not live in git.

### 3. Configure Project Families

Create `~/.task-project-config.sh`:

```bash
healthtrac_repos="HT360_Web arsmetr_backend arsmetr_mobile"
healthtrac_primary="HT360_Web"

HT360_Web_url="git@github.com:sorogersep/HT360-Web.git"
arsmetr_backend_url="git@github.com:healthtrac/arsmetr-backend.git"
arsmetr_mobile_url="git@github.com:healthtrac/arsmetr-mobile.git"

healthtrac_secret_files="\
arsmetr_backend|keys/supabase-anon-key.json|/home/ubuntu/task-secrets/healthtrac/arsmetr_backend/keys/supabase-anon-key.json;\
arsmetr_backend|keys/stripe-secret-key.json|/home/ubuntu/task-secrets/healthtrac/arsmetr_backend/keys/stripe-secret-key.json"
```

The runner uses this file to decide:

- which repos to clone into the container
- which repo is the primary working directory
- which git remotes to use

### 4. Configure Model Selection

Create `~/.task-model-config.sh`:

```bash
export SUBAGENT_MODEL="codex"

# Optional RTK integration for Codex command rewriting
# export RTK_ENABLED=1

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
6. optionally prepares an isolated RTK-enabled Codex home in-container when `RTK_ENABLED=1`
7. runs the task script
8. if changes are meaningful, creates a branch, pushes it, and opens a PR

## RTK Integration

The orchestrator now also includes an optional RTK integration for Codex-backed runs.

When `RTK_ENABLED=1` is present in the host environment or `~/.task-model-config.sh`:

- `task-run.sh` forwards `RTK_ENABLED` into each task container
- [run-codex.sh](/home/ubuntu/dev-workflow/orchestrator/docker-dev-container/run-codex.sh) creates an isolated temporary Codex home
- it copies the mounted `/root/.codex` config into that temporary home
- it runs `rtk init -g --codex` there before launching Codex
- Codex then runs with RTK-managed command rewriting without mutating the host-mounted `~/.codex`

This currently covers the container-side Codex invocation points that matter:

- the main sub-agent execution path
- screenshot QA review passes
- sufficiency review passes


If the sub-agent exits successfully but only changes metadata or makes no meaningful app changes, the run fails.

## UI Artifact Rules

UI-affecting tasks are now enforced to leave visual evidence.

Each task automatically captures:

- screenshots or videos produced by Playwright, Cypress, or explicit screenshot steps
- a host-side artifact mirror under `~/tasks/logs/<task>.artifacts`
- PR comments that link to the committed artifact files
- a general sufficiency review for every task
- a screenshot QA review for `ui` and `full-stack` tasks when image artifacts exist

If a task changes UI-related files but produces no screenshots or video, the run fails.
The sufficiency review does not block PR creation; it records concerns, can trigger one follow-up remediation pass, and is posted to the PR comment.
If the screenshot QA stage finds issues, it now records them in the artifacts and PR comment and can trigger one follow-up remediation pass before the PR is created.

Committed repo location:

- `e2e/screenshots/task-<task>/`

Host mirror location:

- `~/tasks/logs/<task>.artifacts/`

Screenshot QA review files:

- `~/tasks/logs/<task>.artifacts/qa/review.txt`
- `~/tasks/logs/<task>.artifacts/qa/summary.md`

Sufficiency review files:

- `~/tasks/logs/<task>.artifacts/sufficiency/review.txt`
- `~/tasks/logs/<task>.artifacts/sufficiency/summary.md`

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

Each task log now records host-side step boundaries such as:

- `STEP: docker run ...`
- `STEP: docker cp ...`
- `STEP: docker exec ...`
- explicit `ERROR: step failed: ... (exit N)` lines

That makes it possible to distinguish:

- launcher failure before the container starts
- container setup failure
- in-container task failure
- artifact copy failure

## Batch Launching

Use the host-side batch launcher when you want to start multiple tasks at once and leave them running:

```bash
/home/ubuntu/multi-agent-github-workflow/orchestrator/run-task-batch.sh \
  --project healthtrac \
  --batch /home/ubuntu/multi-agent-github-workflow/orchestrator/batches/healthtrac-current-tasks.txt \
  --label healthtrac-current
```

Batch file format:

```text
task-name|task-type|required repo list|Plain English description|/absolute/path/to/task-script.sh
```

Example:

```text
track-order-results-not-loading|full-stack|HT360_Web arsmetr_backend|Fix Track an Order page so results load correctly|/home/ubuntu/tasks/scripts/track-order-results-not-loading.sh
```

Supported task types:

- `ui`
- `api`
- `full-stack`
- `general`

The launcher writes batch metadata under:

- `~/tasks/batches/<label>-<timestamp>/summary.txt`
- `~/tasks/batches/<label>-<timestamp>/manifest.tsv`
- `~/tasks/batches/<label>-<timestamp>/pids.tsv`

Each task still writes its own:

- `~/tasks/logs/<task>.launcher.log`
- `~/tasks/logs/<task>.log`
- `~/tasks/logs/<task>.artifacts/`
- `~/tasks/status/<task>.status`
- `~/tasks/status/<task>.failure_reason`

For backend/API visibility, tasks also emit:

- `~/tasks/logs/<task>.artifacts/backend-evidence/summary.md`
- optional agent-written notes at `~/tasks/logs/<task>.artifacts/backend-evidence/agent-notes.txt`

The sufficiency review now distinguishes required repos as:

- `CHANGED`
- `OK-UNCHANGED`
- `MISSING-WORK`

For repos touched by the runner:

- if a repo already has an automated PR notification workflow, the runner leaves it alone
- otherwise it adds a managed `.github/workflows/task-runner-pr-notification.yml`
- that workflow comments on newly opened `task/*` pull requests and mentions the configured notify user so future automated PRs generate a repo-local notification signal

## Task Memory

The orchestrator now includes a small Codex-native task memory layer in:

- [task-memory.py](/home/ubuntu/dev-workflow/orchestrator/task-memory.py)

It stores task runs in:

- `~/tasks/memory.db`

Each completed or failed run records:

- task metadata
- required repos
- changed repos inferred from related PRs
- backend evidence summary
- sufficiency review summary
- screenshot QA summary
- related PR references

Useful commands:

```bash
python3 /home/ubuntu/multi-agent-github-workflow/orchestrator/task-memory.py init
python3 /home/ubuntu/multi-agent-github-workflow/orchestrator/task-memory.py search "template dropdown"
python3 /home/ubuntu/multi-agent-github-workflow/orchestrator/task-memory.py history healthtrac
```

## AI-Triggered Queueing

If you want the AI to trigger a batch without depending on the current interactive session staying alive, use the queue + dispatcher flow.

Start the dispatcher once on the host:

```bash
/home/ubuntu/multi-agent-github-workflow/orchestrator/start-batch-dispatcher.sh
```

Enqueue a batch request:

```bash
/home/ubuntu/multi-agent-github-workflow/orchestrator/enqueue-task-batch.sh \
  --project healthtrac \
  --batch /home/ubuntu/multi-agent-github-workflow/orchestrator/batches/healthtrac-current-tasks.txt \
  --label healthtrac-current
```

The dispatcher watches:

- `~/tasks/queue/`
- `~/tasks/queue-running/`
- `~/tasks/queue-done/`
- `~/tasks/queue-failed/`

## Status And Debugging

Check dispatcher and queue state:

```bash
/home/ubuntu/multi-agent-github-workflow/orchestrator/batch-status.sh
```

Stop a batch by label fragment:

```bash
/home/ubuntu/multi-agent-github-workflow/orchestrator/batch-stop.sh healthtrac-current
```

Each task now writes explicit states such as:

- `starting`
- `starting_container`
- `container_started`
- `copying_task_script`
- `copying_launcher`
- `copying_identity`
- `executing`
- `cleanup`
- `completed`
- `failed_host_step`
- `failed_task`

The failure reason file captures the most recent host-side or task-side reason when available.

## Task Types

The runner can now pass a task type through to the sub-agent:

```bash
/home/ubuntu/multi-agent-github-workflow/orchestrator/task-run.sh \
  --project healthtrac \
  --task track-order-results-not-loading \
  --type full-stack \
  --required-repos "HT360_Web arsmetr_backend" \
  --desc "Fix Track an Order page so results load correctly" \
  --script /home/ubuntu/tasks/scripts/track-order-results-not-loading.sh
```

Type behavior:

- `ui`
  - emphasizes screenshot-producing verification
- `api`
  - requires backend/API inspection, DB setup when needed, and explicit API verification
- `full-stack`
  - requires cross-repo inspection and verification across UI + backend layers
- `general`
  - default if no type is specified

If `--required-repos` is omitted, the runner now auto-escalates some backend-suspect descriptions to `full-stack` and defaults the required repo set to the full project family.

## Cleanup

```bash
docker container prune -f
docker image prune -f
```

## Notes

- The current implementation is optimized for `codex`.
- `rg` is not installed in the container today, so agents may fall back to `grep`/`find`.
- The wrapper prefers `docker`, but falls back to `sudo docker` if the current user cannot access the Docker socket.
