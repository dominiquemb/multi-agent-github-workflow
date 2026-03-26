#!/bin/bash
# Task Runner Orchestrator
# All configuration passed as parameters - nothing stored in repositories
#
# Usage: ./task-run.sh --project healthtrac --task "my-task" --desc "Description" --script /path/to/script.sh

set -e

# Parse command line arguments
PROJECT=""
TASK_NAME=""
DESCRIPTION=""
SCRIPT_PATH=""
NOTIFY_USER="dominiquemb"
BRANCH_PREFIX="task/"

while [[ $# -gt 0 ]]; do
    case $1 in
        --project|-p)
            PROJECT="$2"
            shift 2
            ;;
        --task|-t)
            TASK_NAME="$2"
            shift 2
            ;;
        --desc|-d)
            DESCRIPTION="$2"
            shift 2
            ;;
        --script|-s)
            SCRIPT_PATH="$2"
            shift 2
            ;;
        --user|-u)
            NOTIFY_USER="$2"
            shift 2
            ;;
        --branch-prefix)
            BRANCH_PREFIX="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 --project <healthtrac|neptune|pythia> --task <name> --desc <description> --script <path> [--user <github-username>]"
            exit 1
            ;;
    esac
done

# Validate required parameters
if [ -z "$PROJECT" ] || [ -z "$TASK_NAME" ] || [ -z "$DESCRIPTION" ] || [ -z "$SCRIPT_PATH" ]; then
    echo "Error: Missing required parameters"
    echo "Usage: $0 --project <healthtrac|neptune|pythia> --task <name> --desc <description> --script <path>"
    exit 1
fi

if [ ! -f "$SCRIPT_PATH" ]; then
    echo "Error: Script not found: $SCRIPT_PATH"
    exit 1
fi

# Define repositories for each project (passed at runtime, not stored)
case $PROJECT in
    healthtrac|healthtrac360)
        REPOS="healthtrac360-web healthtrac360-api healthtrac360-mobile"
        PRIMARY_REPO="healthtrac360-web"
        ;;
    neptune)
        REPOS="neptune neptune-api neptune-mobile"
        PRIMARY_REPO="neptune"
        ;;
    pythia)
        REPOS="pythia-frontend pythia-api"
        PRIMARY_REPO="pythia-frontend"
        ;;
    *)
        echo "Unknown project: $PROJECT"
        echo "Valid options: healthtrac, neptune, pythia"
        exit 1
        ;;
esac

# Generate unique identifiers
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
CONTAINER_NAME="task-${TASK_NAME}-${TIMESTAMP}"
BRANCH_NAME="${BRANCH_PREFIX}${TASK_NAME}-${TIMESTAMP}"

# Get git remote URLs from local clones (these are discovered at runtime)
REPOS_DIR="${REPOS_DIR:-$HOME/repos}"
GIT_REMOTES=""
for repo in $REPOS; do
    if [ -d "$REPOS_DIR/$repo/.git" ]; then
        REMOTE=$(cd "$REPOS_DIR/$repo" && git remote get-url origin 2>/dev/null || echo "")
        if [ -n "$REMOTE" ]; then
            GIT_REMOTES="$GIT_REMOTES$repo=$REMOTE "
        fi
    fi
done

if [ -z "$GIT_REMOTES" ]; then
    echo "Error: No repositories found in $REPOS_DIR"
    echo "Expected repos: $REPOS"
    exit 1
fi

echo "=== Task Runner ==="
echo "Project: $PROJECT"
echo "Task: $TASK_NAME"
echo "Description: $DESCRIPTION"
echo "Repos: $REPOS"
echo "Container: $CONTAINER_NAME"
echo "Branch: $BRANCH_NAME"
echo "Notify: $NOTIFY_USER"
echo ""

# Create temporary runner script
RUNNER_SCRIPT="/tmp/task-runner-${TASK_NAME}-${TIMESTAMP}.sh"

cat > "$RUNNER_SCRIPT" << EOF
#!/bin/bash
set -e

# All values are injected at runtime - nothing hardcoded
export GIT_REMOTES="$GIT_REMOTES"
export REPOS="$REPOS"
export PRIMARY_REPO="$PRIMARY_REPO"
export BRANCH_NAME="$BRANCH_NAME"
export TASK_NAME="$TASK_NAME"
export NOTIFY_USER="$NOTIFY_USER"
export DESCRIPTION="$DESCRIPTION"
export CONTAINER_NAME="$CONTAINER_NAME"
export GH_TOKEN="\$(cat ~/.gh_token 2>/dev/null || echo '')"

echo "Starting container: \$CONTAINER_NAME"

# Start isolated container with SSH key mounted writable
CONTAINER_ID=\$(docker run -d \\
    --name \$CONTAINER_NAME \\
    -v ~/.ssh:/root/.ssh \\
    -e GIT_REMOTES="\$GIT_REMOTES" \\
    -e REPOS="\$REPOS" \\
    -e PRIMARY_REPO="\$PRIMARY_REPO" \\
    -e BRANCH_NAME="\$BRANCH_NAME" \\
    -e TASK_NAME="\$TASK_NAME" \\
    -e NOTIFY_USER="\$NOTIFY_USER" \\
    -e DESCRIPTION="\$DESCRIPTION" \\
    -e GH_TOKEN="\$GH_TOKEN" \\
    -e GIT_AUTHOR_EMAIL='dominiquemb@users.noreply.github.com' \\
    -e GIT_COMMITTER_EMAIL='dominiquemb@users.noreply.github.com' \\
    -e GIT_AUTHOR_NAME='dominiquemb' \\
    -e GIT_COMMITTER_NAME='dominiquemb' \\
    task-runner-base:latest \\
    bash -c "chmod 600 /root/.ssh/* 2>/dev/null || true; Xvfb :99 -screen 0 1920x1080x24 & export DISPLAY=:99; fluxbox & sleep 2; tail -f /dev/null")

sleep 3

# Copy task script into container
docker cp "$SCRIPT_PATH" \$CONTAINER_NAME:/workspace/task.sh

# Execute task inside container
docker exec -w /workspace \$CONTAINER_NAME bash -c '
    set -e
    
    # Copy SSH files to writable location and fix permissions
    mkdir -p /tmp/.ssh
    cp /root/.ssh/github_key /tmp/.ssh/id_rsa 2>/dev/null || cp /root/.ssh/id_rsa /tmp/.ssh/id_rsa 2>/dev/null || true
    cp /root/.ssh/known_hosts /tmp/.ssh/known_hosts 2>/dev/null || true
    chmod 600 /tmp/.ssh/* 2>/dev/null || true
    rm -f /root/.ssh/config 2>/dev/null || true
    export GIT_SSH_COMMAND="ssh -i /tmp/.ssh/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/.ssh/known_hosts"
    
    echo "=== Task: \$TASK_NAME ==="
    echo "Started at: \$(date)"

    # Clone all repositories (fresh, isolated)
    for repo_info in \$GIT_REMOTES; do
        repo=\${repo_info%%=*}
        remote=\${repo_info#*=}
        echo "Cloning \$repo..."
        git clone \$remote \$repo
    done
    
    cd \$PRIMARY_REPO
    
    # Install dependencies
    [ -f package.json ] && npm install 2>/dev/null || true
    
    # Run task script
    bash /workspace/task.sh
    
    # Create PR if there are changes
    if [ -n "\$(git status --porcelain)" ]; then
        git checkout -b \$BRANCH_NAME
        git add -A
        git commit -m "feat: \$DESCRIPTION"
        git push -u origin \$BRANCH_NAME
        
        PR_URL=\$(gh pr create \\
            --title "feat: \$DESCRIPTION" \\
            --body "Task: \$TASK_NAME\\n\\nProject: $PROJECT\\nContainer: \$CONTAINER_NAME" \\
            --base main \\
            --head \$BRANCH_NAME \\
            --assignee \$NOTIFY_USER)
        
        gh pr comment \$PR_URL --body "@\$NOTIFY_USER Ready for review!" 2>/dev/null || true
        echo "PR created: \$PR_URL"
    fi
'

# Cleanup
docker stop \$CONTAINER_NAME
docker rm \$CONTAINER_NAME

echo "Task completed"
EOF

chmod +x "$RUNNER_SCRIPT"

# Execute in background
nohup bash "$RUNNER_SCRIPT" &
PID=$!

echo ""
echo "Task started (PID: $PID)"
echo "Runner script: $RUNNER_SCRIPT"
echo ""
echo "To check status, monitor Docker:"
echo "  docker ps | grep $CONTAINER_NAME"
echo "  docker logs $CONTAINER_NAME"
