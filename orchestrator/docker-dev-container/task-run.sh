#!/bin/bash
# Background Task Runner with Docker isolation and GitHub PR notification
# Usage: ./task-run.sh <task-name> <description> <task-script> [repo-name]

set -e

# Load configuration (create .task-config.sh from .task-config.example)
if [ -f ~/.task-config.sh ]; then
    source ~/.task-config.sh
fi

# Configuration with defaults
NOTIFY_USER="${NOTIFY_USER:-dominiquemb}"
TASK_BRANCH_PREFIX="${TASK_BRANCH_PREFIX:-task/}"
DEFAULT_REPO="${DEFAULT_REPO:-healthtrac360-web}"
DOCKER_DIR="${DOCKER_DIR:-~/docker-dev-container}"
REPOS_DIR="${REPOS_DIR:-~/repos}"

TASK_NAME=$1
DESCRIPTION=$2
TASK_SCRIPT=$3
REPO_NAME=${4:-$DEFAULT_REPO}

TASKS_DIR=~/tasks
LOGS_DIR=~/tasks/logs
REPO_DIR=$REPOS_DIR/$REPO_NAME

# Create directories
mkdir -p $TASKS_DIR $LOGS_DIR

if [ -z "$TASK_NAME" ] || [ -z "$DESCRIPTION" ] || [ -z "$TASK_SCRIPT" ]; then
    echo "Usage: $0 <task-name> <description> <task-script> [repo-name]"
    echo ""
    echo "Examples:"
    echo "  # HealthTrac360 web (default)"
    echo "  $0 draggable-columns 'Implement draggable column reordering' ~/tasks/scripts/draggable-columns.sh"
    echo ""
    echo "  # Different repository"
    echo "  $0 my-feature 'Add new feature' ~/tasks/scripts/my-feature.sh neptune-frontend"
    exit 1
fi

if [ ! -f "$TASK_SCRIPT" ]; then
    echo "Error: Task script not found: $TASK_SCRIPT"
    exit 1
fi

# Generate unique container and branch names
CONTAINER_NAME="task-${TASK_NAME}-$(date +%Y%m%d-%H%M%S)"
BRANCH_NAME="task/${TASK_NAME}-$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$LOGS_DIR/${TASK_NAME}.log"
STATUS_FILE="$TASKS_DIR/${TASK_NAME}.status"

echo "=== Docker Background Task Runner ==="
echo "Task: $TASK_NAME"
echo "Description: $DESCRIPTION"
echo "Script: $TASK_SCRIPT"
echo "Repo: $REPO_NAME"
echo "Container: $CONTAINER_NAME"
echo "Branch: $BRANCH_NAME"
echo "Log: $LOG_FILE"
echo ""

# Create runner script that executes inside Docker
RUNNER_SCRIPT="$TASKS_DIR/${TASK_NAME}.runner.sh"

cat > "$RUNNER_SCRIPT" << RUNNER_EOF
#!/bin/bash
set -e

echo "Starting task at \$(date)" > $LOG_FILE
echo "running" > $STATUS_FILE

# ============================================
# Run task inside Docker container
# ============================================
cd $DOCKER_DIR

# Set environment variables for docker-compose
export CONTAINER_NAME=$CONTAINER_NAME
export REPO_PATH=../repos/$REPO_NAME
export HOST_PORT=$(shuf -i 3000-3999 -n 1)  # Random port to avoid conflicts
export CONTAINER_PORT=5173

echo "Starting Docker container: $CONTAINER_NAME" >> $LOG_FILE
echo "Repo path: \$REPO_PATH" >> $LOG_FILE
echo "Host port: \$HOST_PORT" >> $LOG_FILE

# Build and start container
docker-compose up -d --build >> $LOG_FILE 2>&1

# Copy task script into container
docker cp $TASK_SCRIPT ${CONTAINER_NAME}:/workspace/task.sh >> $LOG_FILE 2>&1

# Copy screen capture script into container
docker cp $DOCKER_DIR/screen-capture.sh ${CONTAINER_NAME}:/workspace/screen-capture.sh >> $LOG_FILE 2>&1

# Execute task inside container
echo "Executing task script inside container..." >> $LOG_FILE
echo "Starting screen capture..." >> $LOG_FILE

# Get GitHub token for PR creation
GH_TOKEN=\$(cat .gh_token 2>/dev/null || echo '')

docker exec -w /workspace ${CONTAINER_NAME} bash -c "
    set -e
    export GH_TOKEN=\$GH_TOKEN
    export GIT_AUTHOR_EMAIL='dominiquemb@users.noreply.github.com'
    export GIT_COMMITTER_EMAIL='dominiquemb@users.noreply.github.com'
    export GIT_AUTHOR_NAME='dominiquemb'
    export GIT_COMMITTER_NAME='dominiquemb'
    export TASK_NAME='$TASK_NAME'
    export SCREENCAST_DIR='/workspace/e2e/screenshots'
    
    # Source screen capture functions
    source /workspace/screen-capture.sh
    
    echo '=== Task Execution ===' >> /workspace/task.log
    echo 'Started at: \$(date)' >> /workspace/task.log
    echo '' >> /workspace/task.log
    
    # Start terminal capture
    capture_terminal
    
    # Start screen recording
    start_recording 'execution'
    
    # Install dependencies
    if [ -f package.json ]; then
        echo 'Installing dependencies...' >> /workspace/task.log
        npm install >> /workspace/task.log 2>&1 || true
    fi
    
    # Take screenshot after install
    take_screenshot 'after-install'
    
    # Run the task script
    echo 'Running task script...' >> /workspace/task.log
    bash /workspace/task.sh >> /workspace/task.log 2>&1
    
    # Take screenshot after task
    take_screenshot 'after-task'
    
    # Stop recording
    stop_recording
    
    # Generate summary report
    generate_report
    
    echo '' >> /workspace/task.log
    echo 'Task completed at: \$(date)' >> /workspace/task.log
" >> $LOG_FILE 2>&1

# Copy logs and screenshots back from container
docker cp ${CONTAINER_NAME}:/workspace/task.log $LOG_FILE.task 2>/dev/null || true
docker cp ${CONTAINER_NAME}:/workspace/e2e/screenshots $LOG_FILE.screenshots 2>/dev/null || true

# Stop and remove container
echo "Stopping container..." >> $LOG_FILE
docker-compose down >> $LOG_FILE 2>&1

echo "completed" > $STATUS_FILE

# ============================================
# Create PR if there are changes
# ============================================
cd $REPO_DIR

# Copy screenshots from task execution
SCREENSHOT_SRC="$LOG_FILE.screenshots/screenshots"
SCREENSHOT_DEST="./e2e/screenshots/task-${TASK_NAME}"
if [ -d "$SCREENSHOT_SRC" ]; then
    mkdir -p "$SCREENSHOT_DEST"
    cp -r "$SCREENSHOT_SRC"/* "$SCREENSHOT_DEST/" 2>/dev/null || true
    echo "Screenshots copied to: $SCREENSHOT_DEST" >> $LOG_FILE
fi

if [ -n "\$(git status --porcelain)" ]; then
    echo "Changes detected, creating PR..." >> $LOG_FILE

    git config user.email "dominiquemb@users.noreply.github.com"
    git config user.name "dominiquemb"

    git checkout -b $BRANCH_NAME >> $LOG_FILE 2>&1
    git add -A
    git commit -m "feat: $DESCRIPTION

Task: $TASK_NAME
Container: $CONTAINER_NAME
Completed at: \$(date)

Includes screenshots and screen recordings in e2e/screenshots/task-${TASK_NAME}/"

    git push -u origin $BRANCH_NAME >> $LOG_FILE 2>&1

    # Build screenshot gallery for PR body
    SCREENSHOT_GALLERY=""
    if [ -d "$SCREENSHOT_DEST" ]; then
        SCREENSHOT_GALLERY="## Screenshots & Recordings

"
        # Add PNG images
        for img in "$SCREENSHOT_DEST"/*.png; do
            if [ -f "$img" ]; then
                img_name=\$(basename "$img")
                SCREENSHOT_GALLERY+="![$img_name](e2e/screenshots/task-${TASK_NAME}/$img_name)
"
            fi
        done

        # Add screen recordings
        for vid in "$SCREENSHOT_DEST"/*.mp4; do
            if [ -f "$vid" ]; then
                vid_name=\$(basename "$vid")
                SCREENSHOT_GALLERY+="
**Recording:** [$vid_name](e2e/screenshots/task-${TASK_NAME}/$vid_name)"
            fi
        done

        # Add summary report
        if [ -f "$SCREENSHOT_DEST/summary.md" ]; then
            SCREENSHOT_GALLERY+="

## Execution Summary
See [summary.md](e2e/screenshots/task-${TASK_NAME}/summary.md) for full details.
"
        fi
        SCREENSHOT_GALLERY+="
---
"
    fi

    PR_URL=\$(gh pr create \\
        --title "feat: $DESCRIPTION" \\
        --body "## Task: $TASK_NAME

**Description:** $DESCRIPTION

**Completed:** \$(date)

**Container:** $CONTAINER_NAME

**Changes:**
- Auto-generated by background task runner
- Executed in isolated Docker container with screen recording

$SCREENSHOT_GALLERY
**Screenshots:** Check \`e2e/screenshots/task-${TASK_NAME}/\` for visual changes and recordings.

---
*This PR was automatically created when the background task completed.*" \\
        --base main \\
        --head $BRANCH_NAME \\
        --assignee $NOTIFY_USER)

    # Add comment mentioning user to trigger notification
    gh pr comment \$PR_URL --body "@$NOTIFY_USER This PR is ready for your review!" 2>/dev/null || true

    echo "" >> $LOG_FILE
    echo "=========================================" >> $LOG_FILE
    echo "✅ TASK COMPLETED" >> $LOG_FILE
    echo "🔗 PR: $PR_URL" >> $LOG_FILE
    echo "📸 Screenshots: $SCREENSHOT_DEST" >> $LOG_FILE
    echo "=========================================" >> $LOG_FILE
    echo "Pull Request created: $PR_URL"
else
    echo "No changes to commit" >> $LOG_FILE
fi
RUNNER_EOF

chmod +x "$RUNNER_SCRIPT"

# Run in background
nohup bash "$RUNNER_SCRIPT" > "$LOG_FILE" 2>&1 &
PID=$!

echo "✅ Task started with PID $PID"
echo "Container: $CONTAINER_NAME"
echo ""
echo "Monitor progress:"
echo "  ./task-status.sh $TASK_NAME    # Check status"
echo "  tail -f $LOG_FILE              # Watch logs live"
echo ""
echo "When complete, a PR will be created and you'll get a GitHub notification."
