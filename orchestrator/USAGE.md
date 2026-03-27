# Task Runner Orchestrator - Usage Guide

## Overview

The task runner allows you to execute tasks in isolated Docker containers with automatic PR creation and GitHub notifications.

## Quick Start

```bash
# Basic usage
~/task-run.sh --project <project-name> --task <task-name> --desc "Description" --script <script-path> --user <github-username>
```

## Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| --project | Yes | Project family (healthtrac, neptune, pythia) |
| --task | Yes | Unique task name |
| --desc | Yes | Task description |
| --script | Yes | Path to task script |
| --user | No | GitHub username to notify (default: dominiquemb) |

## Available Projects

### healthtrac
- Repos: healthtrac360-web, healthtrac360-api, healthtrac360-mobile
- Primary: healthtrac360-web

### neptune  
- Repos: neptune, neptune-api, neptune-mobile
- Primary: neptune

### pythia
- Repos: pythia-frontend, pythia-api
- Primary: pythia-frontend

## Examples

```bash
# Run a task on healthtrac project
~/task-run.sh --project healthtrac --task add-feature --desc "Add new feature" --script ~/tasks/scripts/feature.sh

# Run with custom notify user
~/task-run.sh --project neptune --task fix-bug --desc "Fix login bug" --script ~/tasks/scripts/fix.sh --user john-doe

# Run parallel tasks (each in isolated container)
~/task-run.sh --project healthtrac --task task-1 --desc "Task 1" --script ~/tasks/scripts/task1.sh &
~/task-run.sh --project healthtrac --task task-2 --desc "Task 2" --script ~/tasks/scripts/task2.sh &
~/task-run.sh --project healthtrac --task task-3 --desc "Task 3" --script ~/tasks/scripts/task3.sh &
```

## What Happens

1. **Docker container starts** - Isolated environment with all tools
2. **All related repos cloned** - Fresh clone of entire project family
3. **npm install** - Dependencies installed in primary repo
4. **Task script executes** - Your custom script runs
5. **PR created** (if changes detected) - Branch pushed, PR opened
6. **Notification sent** - GitHub @mention triggers notification

## Monitoring

```bash
# Check running containers
docker ps | grep task-

# View container logs
docker logs <container-name>

# Check task status
cat ~/tasks/logs/<task-name>.log
```

## Task Script Template

```bash
#!/bin/bash
set -e

echo "=== Task: My Task ==="
echo "Started at: $(date)"

# You are in the primary repo directory
# Already in correct directory

# Make your changes
echo "Making changes..."

# Install dependencies if needed
[ -f package.json ] && npm install

# Run tests
npm test || true

# Run E2E tests with screenshots
npm run test:e2e || true

echo "=== Task Complete ==="
```

## Configuration

Project families are configured in `~/.task-project-config.sh`

To add a new project family, edit this file:

```bash
# Project: myproject
myproject_repos="my-web my-api my-mobile"
myproject_primary="my-web"
```

## Troubleshooting

### Unknown project error
Make sure the project is defined in `~/.task-project-config.sh`

### No repositories found
Ensure repos are cloned in `~/repos/` directory

### SSH key issues
Verify `~/.ssh/github_key` exists and has correct permissions

### GitHub CLI not authenticated
Run `gh auth login` or ensure `~/.gh_token` exists

## Additional Resources

- Main orchestrator docs: https://github.com/dominiquemb/multi-agent-github-workflow
- Project configs: https://github.com/dominiquemb/task-runner-config
