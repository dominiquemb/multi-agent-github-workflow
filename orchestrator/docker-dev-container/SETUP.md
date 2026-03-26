# Configurable Background Task Runner

Run tasks in isolated Docker containers with configurable notifications.

## Quick Setup

```bash
# 1. Create configuration
cp .task-config.example ~/.task-config.sh

# 2. Edit configuration
nano ~/.task-config.sh

# 3. Copy scripts to home directory
cp *.sh ~/
chmod +x ~/task-*.sh

# 4. Set up Docker
mkdir -p ~/docker-dev-container
cp Dockerfile docker-compose.yml screen-capture.sh ~/docker-dev-container/
cd ~/docker-dev-container
docker-compose build
```

## Configuration Options

Edit `~/.task-config.sh`:

```bash
# GitHub username to notify (required)
NOTIFY_USER="your-username"

# Email for notifications (optional, for future email support)
NOTIFY_EMAIL="your-email@example.com"

# Default repository for tasks
DEFAULT_REPO="healthtrac360-web"

# Task branch prefix
TASK_BRANCH_PREFIX="task/"

# Directory paths
DOCKER_DIR="$HOME/docker-dev-container"
REPOS_DIR="$HOME/repos"
```

## GitHub Actions Setup

For automatic PR notifications via GitHub Actions:

1. Go to your repository Settings → Variables → Actions
2. Add repository variables:
   - `NOTIFY_USER`: Your GitHub username
   - `TASK_BRANCH_PREFIX`: `task/`

3. Copy the workflow file:
```bash
cp pr-notification-workflow.yml /path/to/your/repo/.github/workflows/pr-notification.yml
git add .github/workflows/pr-notification.yml
git commit -m "Add PR notification workflow"
git push
```

## Usage

```bash
# Run a task
./task-run.sh <task-name> '<description>' <task-script> [repo-name]

# Examples:
./task-run.sh my-feature 'Add new feature' ~/tasks/scripts/my-feature.sh
./task-run.sh bugfix 'Fix login bug' ~/tasks/scripts/fix-login.sh neptune-frontend
```

## What Gets Created

1. **Docker container** with unique name
2. **Git branch** with timestamp
3. **Pull request** with:
   - Assignee: configured user
   - Comment mentioning configured user
   - Screenshots and screen recording
   - Execution summary

## Notifications

The configured user receives notifications via:
- GitHub notification (bell icon)
- Email (if enabled in GitHub settings)
- PR comment mention
