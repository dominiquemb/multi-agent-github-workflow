# Sub-Agent Workflow

## Process for Tasks with UI Changes

1. **Sub-agent** works on the task inside an isolated Docker container on the remote server
2. **Docker container records** the screen + takes screenshots during execution
3. **Sub-agent** runs Playwright E2E tests → screenshots saved to `e2e/screenshots/`
4. **Sub-agent** creates a GitHub PR with screenshots/videos embedded → **You get notified**
5. **Assistant** reviews the code using `/review`
6. **User** reviews screenshots/videos in PR and `e2e/screenshots/`

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

Tasks run in parallel inside isolated Docker containers with screen recording. When complete, a PR is created with embedded screenshots and you get a GitHub notification.

**Scripts:**
- `~/task-run.sh` - Start a background task in Docker
- `~/task-status.sh` - Check task status
- `~/task-clean.sh` - Clean up completed tasks
- `~/tasks/scripts/` - Task implementation scripts
- `~/docker-dev-container/` - Docker configuration with screen recording

### Docker Container Features

Each container includes:
- **Xvfb** - Virtual display for headless screen recording
- **Fluxbox** - Lightweight window manager
- **FFmpeg** - Screen recording (MP4)
- **scrot/ImageMagick** - Screenshots (PNG)
- **Playwright** - E2E testing with Chromium
- **Node.js 20** - JavaScript/TypeScript runtime

### What Gets Captured

1. **Screen Recording** - Full MP4 video of task execution
2. **Screenshots** - PNG images at key steps:
   - After dependency installation
   - After task completion
   - During E2E tests
3. **Terminal Log** - All command output
4. **Summary Report** - Markdown file with all assets linked

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
- Records screen and takes screenshots
- Creates a separate PR with embedded media when complete
- Triggers a GitHub notification

### How Docker Isolation Works

1. Task runner creates unique container name: `task-<name>-<timestamp>`
2. Docker container starts with:
   - Repository mounted at `/workspace`
   - Isolated `node_modules` volume
   - GitHub token for PR creation
   - Virtual display (Xvfb) for screen recording
3. Task executes inside container:
   - Screen recording starts automatically
   - Screenshots taken at key steps
   - Terminal output captured
4. Container stops and is removed
5. Git changes persist (mounted volume)
6. Screenshots copied to repo: `e2e/screenshots/task-<name>/`
7. PR created with embedded screenshots and recordings

## Screenshot Location

Screenshots and recordings are saved in: `e2e/screenshots/task-<task-name>/`

Structure:
```
e2e/screenshots/
└── task-draggable-columns/
    ├── draggable-columns-after-install.png
    ├── draggable-columns-after-task.png
    ├── draggable-columns-execution.mp4    # Screen recording
    ├── draggable-columns-summary.md       # Auto-generated report
    └── draggable-columns-terminal.log     # Full terminal output
```

## PR Body Format

PRs automatically include:

```markdown
## Task: draggable-columns

**Description:** Implement draggable column reordering

**Completed:** 2026-03-25T20:45:00Z

**Container:** task-draggable-columns-20260325-204500

## Screenshots & Recordings

![after-install](e2e/screenshots/task-draggable-columns/after-install.png)
![after-task](e2e/screenshots/task-draggable-columns/after-task.png)

**Recording:** [execution.mp4](e2e/screenshots/task-draggable-columns/execution.mp4)

## Execution Summary
See [summary.md](e2e/screenshots/task-draggable-columns/summary.md) for full details.

---

**Screenshots:** Check `e2e/screenshots/task-draggable-columns/` for visual changes and recordings.
```

## Review Process

1. Task runs in Docker container on remote server
2. Screen recording + screenshots captured automatically
3. Task creates branch, makes changes, runs tests
4. Task creates PR with embedded media → **GitHub notifies you**
5. **Assistant** reviews code using `/review <pr-number>`
6. **User** reviews:
   - PR changes on GitHub
   - Embedded screenshots in PR body
   - Screen recording (MP4)
   - Summary report
7. Merge or request changes

## Example Workflow

```bash
# Start a task
ssh ubuntu@40.160.8.176 "./task-run.sh my-feature 'Add new feature' ~/tasks/scripts/my-feature.sh healthtrac360-web"

# Check status later
ssh ubuntu@40.160.8.176 "./task-status.sh"

# After PR notification:
# 1. Review code
/review <pr-number>

# 2. View screenshots in PR body (embedded)

# 3. Check full resolution screenshots
ls -la ~/repos/healthtrac360-web/e2e/screenshots/task-my-feature/

# 4. Watch screen recording
# Download the MP4 from the repo or view via GitHub
```
