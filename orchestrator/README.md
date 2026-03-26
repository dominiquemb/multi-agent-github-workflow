# Task Runner Setup Guide

This guide explains how to set up the background task runner system for your repositories.

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

Each project family groups related repositories that should be cloned together:

| Family    | Repositories                              | Primary Repo        |
|-----------|-------------------------------------------|---------------------|
| healthtrac| healthtrac360-web, healthtrac360-api, healthtrac360-mobile | healthtrac360-web |
| neptune   | neptune, neptune-api, neptune-mobile      | neptune             |
| pythia    | pythia-frontend, pythia-api               | pythia-frontend     |

## Setup Instructions

### 1. Build Base Image (One-Time Setup)

On the remote server:

```bash
cd ~/task-runner-base
docker build -t task-runner-base:latest .
```

### 2. Add Task Runner to Each Repository

For each repository, create the following structure:

```
your-repo/
├── .github/
│   └── task-runner/
│       ├── Dockerfile      # Project-specific Dockerfile
│       └── setup.sh        # Repo-specific setup script
```

#### Example: HealthTrac360 Web

`.github/task-runner/Dockerfile`:
```dockerfile
FROM task-runner-base:latest

# Install web-specific dependencies
RUN apt-get update && apt-get install -y \
    nginx \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
```

`.github/task-runner/setup.sh`:
```bash
#!/bin/bash
set -e

# Install npm dependencies
npm install

# Copy environment template
if [ ! -f .env ] && [ -f .env.example ]; then
    cp .env.example .env
fi

# Run migrations if needed
npm run db:migrate 2>/dev/null || true
```

### 3. Configure Task Runner

On the remote server, create `~/.task-config.sh`:

```bash
# GitHub username to notify
NOTIFY_USER="your-username"

# Default project family
DEFAULT_PROJECT="healthtrac"

# Task branch prefix
TASK_BRANCH_PREFIX="task/"

# Directory paths
DOCKER_DIR="$HOME/docker-dev-container"
BASE_IMAGE_DIR="$HOME/task-runner-base"
REPOS_DIR="$HOME/repos"
```

### 4. Run Tasks

```bash
# Basic usage
./task-run.sh <task-name> '<description>' <task-script> [project-family]

# Examples
./task-run.sh draggable-columns 'Implement draggable columns' ~/tasks/scripts/draggable-columns.sh healthtrac
./task-run.sh fix-login 'Fix login bug' ~/tasks/scripts/fix-login.sh neptune
./task-run.sh add-feature 'Add new feature' ~/tasks/scripts/add-feature.sh pythia
```

## Task Script Template

```bash
#!/bin/bash
# Task script template
set -e

echo "=== Task: $(basename $0) ==="
echo "Started at: $(date)"

# Navigate to primary repo (already cloned in /workspace)
cd $PRIMARY_REPO

# Make your changes here
echo "Making changes..."

# Run tests
npm test || true

# Run E2E tests with screenshots
npm run test:e2e || true

echo "=== Task Complete ==="
```

## What Gets Captured

Each task automatically captures:

1. **Screen Recording** - Full MP4 video of task execution
2. **Screenshots** - PNG images at key steps
3. **Terminal Log** - All command output
4. **Summary Report** - Markdown file with all assets linked

Output location: `repo/e2e/screenshots/task-<name>/`

## Parallel Execution

Multiple tasks can run simultaneously - each gets its own isolated Docker container:

```bash
# Run multiple tasks in parallel
./task-run.sh task-1 'Description 1' ~/tasks/scripts/task1.sh healthtrac &
./task-run.sh task-2 'Description 2' ~/tasks/scripts/task2.sh neptune &
./task-run.sh task-3 'Description 3' ~/tasks/scripts/task3.sh pythia &
```

## Monitoring

```bash
# Check all tasks
./task-status.sh

# Check specific task
./task-status.sh task-name

# Watch logs live
tail -f ~/tasks/logs/task-name.log
```

## Cleanup

```bash
# Clean completed task files
./task-clean.sh

# Remove old Docker containers
docker container prune -f

# Remove old images
docker image prune -f
```
