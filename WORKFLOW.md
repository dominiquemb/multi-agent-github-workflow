# Sub-Agent Workflow

## Process for Tasks with UI Changes

1. **Sub-agent** works on the task inside an isolated Docker container on the remote server
2. **Sub-agent** runs Playwright E2E tests → screenshots saved to `e2e/screenshots/`
3. **Sub-agent** creates a GitHub PR when complete → **You get notified**
4. **Assistant** reviews the code using `/review`
5. **User** reviews screenshots in `e2e/screenshots/` and the PR

## Remote Server Setup (40.160.8.176)

### Repositories (`~/repos/`)

**HealthTrac360:**
- `healthtrac360-web` (arsmetr-frontend)
- `healthtrac360-api` (arsmetr-backend)
- `healthtrac360-mobile` (arsmetr-mobile)

**Neptune:**
- `neptune` (neptune-frontend)
- `neptune-api`
- `neptune-mobile`

**Pythia:**
- `pythia-frontend`
- `pythia-api`

### Background Task System with Docker

Tasks run in parallel inside isolated Docker containers. When complete, a PR is created and you get a GitHub notification.

**Scripts:**
- `~/task-run.sh` - Start a background task in Docker
- `~/task-status.sh` - Check task status
- `~/task-clean.sh` - Clean up completed tasks
- `~/tasks/scripts/` - Task implementation scripts
- `~/docker-dev-container/` - Docker configuration

### Starting a Task

```bash
ssh ubuntu@40.160.8.176 "./task-run.sh <task-name> '<description>' <task-script> [repo-name]"
```

Examples:
```bash
# HealthTrac360 web (default repo)
ssh ubuntu@40.160.8.176 "./task-run.sh draggable-columns 'Implement draggable column reordering' ~/tasks/scripts/draggable-columns.sh"

# Different repository
ssh ubuntu@40.160.8.176 "./task-run.sh my-feature 'Add new feature' ~/tasks/scripts/my-feature.sh neptune-frontend"
```

### Checking Status

```bash
# All tasks
ssh ubuntu@40.160.8.176 "./task-status.sh"

# Specific task
ssh ubuntu@40.160.8.176 "./task-status.sh draggable-columns"

# Watch logs live
ssh ubuntu@40.160.8.176 "tail -f ~/tasks/logs/draggable-columns.log"

# View container logs
ssh ubuntu@40.160.8.176 "cat ~/tasks/logs/draggable-columns.log.task"
```

### Running Multiple Tasks in Parallel

```bash
# Start multiple tasks simultaneously (each in its own Docker container)
ssh ubuntu@40.160.8.176 "./task-run.sh task-1 'Description 1' ~/tasks/scripts/task1.sh healthtrac360-web" &
ssh ubuntu@40.160.8.176 "./task-run.sh task-2 'Description 2' ~/tasks/scripts/task2.sh neptune-frontend" &
ssh ubuntu@40.160.8.176 "./task-run.sh task-3 'Description 3' ~/tasks/scripts/task3.sh pythia-frontend" &
```

Each task:
- Runs in its own isolated Docker container
- Has its own branch name with timestamp
- Uses a random host port to avoid conflicts
- Creates a separate PR when complete
- Triggers a GitHub notification

### How Docker Isolation Works

1. Task runner creates unique container name: `task-<name>-<timestamp>`
2. Docker container starts with:
   - Repository mounted at `/workspace`
   - Isolated `node_modules` volume
   - GitHub token for PR creation
3. Task executes inside container
4. Container stops and is removed
5. Git changes persist (mounted volume)
6. PR created from host (git config set)

## Screenshot Location

Screenshots are saved in: `e2e/screenshots/` (inside the repo, persists after container stops)

## Review Process

1. Task runs in Docker container on remote server
2. Task creates branch, makes changes, runs tests
3. Task creates PR → **GitHub notifies you**
4. **Assistant** reviews code using `/review <pr-number>`
5. **User** reviews:
   - PR changes on GitHub
   - Screenshots in `e2e/screenshots/`
6. Merge or request changes

## Example Workflow

```bash
# Start a task
ssh ubuntu@40.160.8.176 "./task-run.sh my-feature 'Add new feature' ~/tasks/scripts/my-feature.sh healthtrac360-web"

# Check status later
ssh ubuntu@40.160.8.176 "./task-status.sh"

# After PR notification, review code
/review <pr-number>

# Check screenshots
ls -la ~/repos/healthtrac360-web/e2e/screenshots/
```
