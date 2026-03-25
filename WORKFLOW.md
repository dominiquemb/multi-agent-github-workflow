# Sub-Agent Workflow

## Process for Tasks with UI Changes

1. **Sub-agent** works on the task (background process on remote server)
2. **Sub-agent** runs Playwright E2E tests → screenshots saved to `e2e/screenshots/`
3. **Sub-agent** creates a GitHub PR when complete → **You get notified**
4. **Assistant** reviews the code using `/review`
5. **User** reviews screenshots in `e2e/screenshots/` and the PR

## Remote Server Setup (40.160.8.176)

### Repositories (`~/repos/`)

**HealthTrac360:**
- `healthtrac360-web`
- `healthtrac360-api`
- `healthtrac360-mobile`

**Neptune:**
- `neptune` (frontend)
- `neptune-api`
- `neptune-mobile`

**Pythia:**
- `pythia-frontend`
- `pythia-api`

### Background Task System

Tasks run in parallel on the remote server. When complete, a PR is created and you get a GitHub notification.

**Scripts:**
- `~/task-run.sh` - Start a background task
- `~/task-status.sh` - Check task status
- `~/task-clean.sh` - Clean up completed tasks
- `~/tasks/scripts/` - Task implementation scripts

### Starting a Task

```bash
ssh ubuntu@40.160.8.176 "./task-run.sh <task-name> '<description>' <task-script>"
```

Example:
```bash
ssh ubuntu@40.160.8.176 "./task-run.sh draggable-columns 'Implement draggable column reordering' ~/tasks/scripts/draggable-columns.sh"
```

### Checking Status

```bash
# All tasks
ssh ubuntu@40.160.8.176 "./task-status.sh"

# Specific task
ssh ubuntu@40.160.8.176 "./task-status.sh draggable-columns"

# Watch logs live
ssh ubuntu@40.160.8.176 "tail -f ~/tasks/logs/draggable-columns.log"
```

### Running Multiple Tasks in Parallel

```bash
# Start multiple tasks simultaneously
ssh ubuntu@40.160.8.176 "./task-run.sh task-1 'Description 1' ~/tasks/scripts/task1.sh" &
ssh ubuntu@40.160.8.176 "./task-run.sh task-2 'Description 2' ~/tasks/scripts/task2.sh" &
ssh ubuntu@40.160.8.176 "./task-run.sh task-3 'Description 3' ~/tasks/scripts/task3.sh" &
```

Each task:
- Runs independently in the background
- Creates its own git branch
- Creates a separate PR when complete
- Triggers a GitHub notification

### Docker Dev Containers (Optional)

For tasks requiring isolated environments:

```bash
cd ~/docker-dev-container

# Set unique values for each container
export CONTAINER_NAME=agent-task-1
export HOST_PORT=3001

# Build and start
docker-compose up -d --build
```

## Screenshot Location

Screenshots are saved in: `e2e/screenshots/` (inside the repo)

## Review Process

1. Task runs in background on remote server
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
ssh ubuntu@40.160.8.176 "./task-run.sh my-feature 'Add new feature' ~/tasks/scripts/my-feature.sh"

# Check status later
ssh ubuntu@40.160.8.176 "./task-status.sh"

# After PR notification, review code
/review <pr-number>

# Check screenshots
ls -la healthtrac360-web/e2e/screenshots/
```
