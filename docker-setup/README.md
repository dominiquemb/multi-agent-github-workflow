# Docker Task Runner Setup

Replicate the background task system with screen recording on any server with Docker.

## Prerequisites

- Ubuntu 22.04+ or Debian 12+
- Docker and Docker Compose installed
- Git configured
- GitHub CLI (`gh`) authenticated

## Quick Setup

```bash
# 1. Clone this repository
git clone https://github.com/dominiquemb/dev-workflow.git
cd dev-workflow/docker-setup

# 2. Copy scripts to home directory
cp *.sh ~/
chmod +x ~/task-*.sh

# 3. Create Docker setup directory
mkdir -p ~/docker-dev-container
cp Dockerfile docker-compose.yml screen-capture.sh ~/docker-dev-container/
cd ~/docker-dev-container

# 4. Build Docker image
docker-compose build

# 5. Configure Git
git config --global user.email "your-email@users.noreply.github.com"
git config --global user.name "your-name"

# 6. Set up GitHub authentication
# Option A: SSH Key (recommended)
ssh-keygen -t ed25519 -C "your-email@users.noreply.github.com" -f ~/.ssh/github_key -N ''
# Add ~/.ssh/github_key.pub to GitHub: https://github.com/settings/keys
# Then create ~/.ssh/config:
echo -e "\nHost github.com\n  HostName github.com\n  User git\n  IdentityFile ~/.ssh/github_key\n  IdentitiesOnly yes" >> ~/.ssh/config
chmod 600 ~/.ssh/config

# Option B: GitHub Token for PR creation
gh auth login
gh auth token > .gh_token
chmod 600 .gh_token

# 7. Create tasks directory
mkdir -p ~/tasks/scripts
```

## Usage

### Start a Task

```bash
# Default repository (healthtrac360-web)
./task-run.sh my-task 'Task description' ~/tasks/scripts/my-task.sh

# Specific repository
./task-run.sh my-task 'Task description' ~/tasks/scripts/my-task.sh repo-name
```

### Check Status

```bash
# All tasks
./task-status.sh

# Specific task
./task-status.sh my-task

# Watch logs
tail -f ~/tasks/logs/my-task.log
```

### Clean Up

```bash
# Clean completed tasks
./task-clean.sh

# Clean specific task
./task-clean.sh my-task
```

## Repository Structure

Tasks work with repositories in `~/repos/`. Clone your repos:

```bash
mkdir -p ~/repos
cd ~/repos
git clone git@github.com:your-org/repo-name.git
```

## Task Script Template

Create task scripts in `~/tasks/scripts/`:

```bash
#!/bin/bash
# Task script template
set -e

echo "=== Task: $(basename $0) ==="
echo "Started at: $(date)"

cd ~/repos/your-repo

# Make your changes here
echo "Making changes..."

# Run tests
npm test || true

# Run E2E tests with screenshots
npm run test:e2e || true

echo "=== Task Complete ==="
```

## What Gets Captured

Each task running in Docker automatically captures:

1. **Screen Recording** - MP4 video of entire execution
2. **Screenshots** - PNG images at key steps
3. **Terminal Log** - All command output
4. **Summary Report** - Markdown with all assets

Output location: `repo/e2e/screenshots/task-<name>/`

## Docker Image

The Docker image includes:
- Node.js 20 (bookworm)
- Playwright + Chromium
- Xvfb (virtual display)
- Fluxbox (window manager)
- FFmpeg (screen recording)
- scrot/ImageMagick (screenshots)
- Git, Python, development tools

Image size: ~2.6GB

## Troubleshooting

### Docker build fails
```bash
cd ~/docker-dev-container
docker-compose build --no-cache
```

### Permission denied on scripts
```bash
chmod +x ~/task-*.sh ~/tasks/scripts/*.sh
```

### GitHub authentication fails
```bash
# Test SSH
ssh -T git@github.com

# Test gh CLI
gh auth status
```

### Container won't start
```bash
cd ~/docker-dev-container
docker-compose up -d
docker-compose logs
```

## Cleanup

Remove all task artifacts:
```bash
./task-clean.sh  # Clean completed tasks

# Remove all Docker containers
docker rm -f $(docker ps -aq)

# Remove Docker volumes
docker volume prune -f

# Remove Docker images
docker rmi docker-dev-container_dev-container
```

## Example

Full example with draggable columns task:

```bash
# 1. Create task script
cat > ~/tasks/scripts/draggable-columns.sh << 'EOF'
#!/bin/bash
set -e
cd ~/repos/healthtrac360-web

# Install DnD library
npm install @dnd-kit/core @dnd-kit/sortable

# Make code changes
echo "Implementing draggable columns..."
# ... your implementation ...

# Run tests
npm run test:e2e
EOF
chmod +x ~/tasks/scripts/draggable-columns.sh

# 2. Run task
./task-run.sh draggable-columns 'Implement draggable column reordering' ~/tasks/scripts/draggable-columns.sh

# 3. Check status
./task-status.sh draggable-columns

# 4. Watch for PR notification on GitHub
# 5. Review PR with embedded screenshots
```
