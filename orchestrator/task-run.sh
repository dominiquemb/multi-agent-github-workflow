#!/bin/bash

# Create logs directory
mkdir -p ~/tasks/logs

# Detect if running as root
if [ "$(id -u)" = "0" ]; then
    RUNNING_AS_ROOT=true
    HOME_DIR=/home/ubuntu
    export HOME=$HOME_DIR
else
    RUNNING_AS_ROOT=false
    HOME_DIR=$HOME
fi

# Source config
[ -f $HOME_DIR/.task-project-config.sh ] && source $HOME_DIR/.task-project-config.sh
[ -f $HOME_DIR/.task-model-config.sh ] && source $HOME_DIR/.task-model-config.sh

PROJECT="" TASK_NAME="" DESCRIPTION="" SCRIPT_PATH="" NOTIFY_USER="dominiquemb"
while [[ $# -gt 0 ]]; do
    case $1 in
        --project|-p) PROJECT="$2"; shift 2 ;;
        --task|-t) TASK_NAME="$2"; shift 2 ;;
        --desc|-d) DESCRIPTION="$2"; shift 2 ;;
        --script|-s) SCRIPT_PATH="$2"; shift 2 ;;
        --user|-u) NOTIFY_USER="$2"; shift 2 ;;
        *) exit 1 ;;
    esac
done

[ -z "$PROJECT" ] || [ -z "$TASK_NAME" ] || [ -z "$SCRIPT_PATH" ] && { echo "Usage: --project --task --desc --script"; exit 1; }

# Get project config
REPOS_VAR="${PROJECT}_repos"
PRIMARY_VAR="${PROJECT}_primary"
REPOS=$(eval echo "\$""$REPOS_VAR")
PRIMARY_REPO=$(eval echo "\$""$PRIMARY_VAR")
[ -z "$REPOS" ] && { echo "Unknown project: $PROJECT"; exit 1; }

# Build git remotes from config URLs
GIT_REMOTES=""
for repo in $REPOS; do
    URL_VAR="${repo}_url"
    URL=$(eval echo "\$""$URL_VAR")
    if [ -n "$URL" ]; then
        GIT_REMOTES="$GIT_REMOTES$repo=$URL "
    fi
done

[ -z "$GIT_REMOTES" ] && { echo "No git URLs configured for project: $PROJECT"; exit 1; }

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
CONTAINER_NAME="task-${TASK_NAME}-${TIMESTAMP}"
BRANCH_NAME="task/${TASK_NAME}-${TIMESTAMP}"
LOG_FILE="$HOME_DIR/tasks/logs/${TASK_NAME}.log"

echo "=== Task Runner ===" | tee -a "$LOG_FILE"
echo "Project: $PROJECT | Task: $TASK_NAME | Repos: $REPOS" | tee -a "$LOG_FILE"
echo "Git remotes: $GIT_REMOTES" | tee -a "$LOG_FILE"
echo "Log file: $LOG_FILE" | tee -a "$LOG_FILE"

GH_TOKEN=$(cat $HOME_DIR/.gh_token 2>/dev/null || echo '')
MODAL_MOUNT_ARGS=""
MODAL_ENV_ARGS=""
MODEL_ENV_ARGS=""

if [ -f "$HOME_DIR/.modal.toml" ]; then
    MODAL_MOUNT_ARGS="-v $HOME_DIR/.modal.toml:/root/.modal.toml:ro"
fi

if [ -n "${MODAL_TOKEN_ID:-}" ]; then
    MODAL_ENV_ARGS="$MODAL_ENV_ARGS -e MODAL_TOKEN_ID=$MODAL_TOKEN_ID"
fi

if [ -n "${MODAL_TOKEN_SECRET:-}" ]; then
    MODAL_ENV_ARGS="$MODAL_ENV_ARGS -e MODAL_TOKEN_SECRET=$MODAL_TOKEN_SECRET"
fi

if [ -n "${MODAL_PROFILE:-}" ]; then
    MODAL_ENV_ARGS="$MODAL_ENV_ARGS -e MODAL_PROFILE=$MODAL_PROFILE"
fi

if [ -n "${OPENCLAW_VLLM_BASE_URL:-}" ]; then
    MODEL_ENV_ARGS="$MODEL_ENV_ARGS -e OPENCLAW_VLLM_BASE_URL=$OPENCLAW_VLLM_BASE_URL"
fi

if [ -n "${OPENCLAW_VLLM_MODEL_ID:-}" ]; then
    MODEL_ENV_ARGS="$MODEL_ENV_ARGS -e OPENCLAW_VLLM_MODEL_ID=$OPENCLAW_VLLM_MODEL_ID"
fi

if [ -n "${OPENCLAW_VLLM_API_KEY:-}" ]; then
    MODEL_ENV_ARGS="$MODEL_ENV_ARGS -e OPENCLAW_VLLM_API_KEY=$OPENCLAW_VLLM_API_KEY"
fi

if [ -n "${SUBAGENT_MODEL:-}" ]; then
    MODEL_ENV_ARGS="$MODEL_ENV_ARGS -e SUBAGENT_MODEL=$SUBAGENT_MODEL"
fi

if [ -n "${SUBAGENT_FALLBACK_MODELS:-}" ]; then
    MODEL_ENV_ARGS="$MODEL_ENV_ARGS -e SUBAGENT_FALLBACK_MODELS=$SUBAGENT_FALLBACK_MODELS"
fi

# Start container
echo "Starting container: $CONTAINER_NAME" | tee -a "$LOG_FILE"
if [ "$RUNNING_AS_ROOT" = "true" ]; then
    sudo docker run -d --name $CONTAINER_NAME -v $HOME_DIR/.ssh:/root/.ssh \
      $MODAL_MOUNT_ARGS $MODAL_ENV_ARGS $MODEL_ENV_ARGS \
      -e GIT_REMOTES="$GIT_REMOTES" -e REPOS="$REPOS" -e PRIMARY_REPO="$PRIMARY_REPO" \
      -e BRANCH_NAME="$BRANCH_NAME" -e TASK_NAME="$TASK_NAME" -e NOTIFY_USER="$NOTIFY_USER" \
      -e DESCRIPTION="$DESCRIPTION" -e GH_TOKEN="$GH_TOKEN" \
      -e GIT_AUTHOR_EMAIL='dominiquemb@users.noreply.github.com' \
      task-runner-base:latest bash -c "Xvfb :99 -screen 0 1920x1080x24 & fluxbox & sleep 2; tail -f /dev/null" 2>&1 | tee -a "$LOG_FILE"
else
    docker run -d --name $CONTAINER_NAME -v ~/.ssh:/root/.ssh \
      $MODAL_MOUNT_ARGS $MODAL_ENV_ARGS $MODEL_ENV_ARGS \
      -e GIT_REMOTES="$GIT_REMOTES" -e REPOS="$REPOS" -e PRIMARY_REPO="$PRIMARY_REPO" \
      -e BRANCH_NAME="$BRANCH_NAME" -e TASK_NAME="$TASK_NAME" -e NOTIFY_USER="$NOTIFY_USER" \
      -e DESCRIPTION="$DESCRIPTION" -e GH_TOKEN="$GH_TOKEN" \
      -e GIT_AUTHOR_EMAIL='dominiquemb@users.noreply.github.com' \
      task-runner-base:latest bash -c "Xvfb :99 -screen 0 1920x1080x24 & fluxbox & sleep 2; tail -f /dev/null" 2>&1 | tee -a "$LOG_FILE"
fi

sleep 3

# Copy task script
echo "Copying task script to container" | tee -a "$LOG_FILE"
if [ "$RUNNING_AS_ROOT" = "true" ]; then
    sudo docker cp "$SCRIPT_PATH" $CONTAINER_NAME:/workspace/task.sh 2>&1 | tee -a "$LOG_FILE"
else
    docker cp "$SCRIPT_PATH" $CONTAINER_NAME:/workspace/task.sh 2>&1 | tee -a "$LOG_FILE"
fi

# Copy canonical container-side spawn-subagent.sh
echo "Copying canonical spawn-subagent.sh to container" | tee -a "$LOG_FILE"
if [ "$RUNNING_AS_ROOT" = "true" ]; then
    sudo docker cp $HOME_DIR/docker-dev-container/spawn-subagent.sh $CONTAINER_NAME:/workspace/spawn-subagent.sh 2>&1 | tee -a "$LOG_FILE"
    sudo docker exec $CONTAINER_NAME chmod +x /workspace/spawn-subagent.sh 2>&1 | tee -a "$LOG_FILE"
else
    docker cp $HOME_DIR/docker-dev-container/spawn-subagent.sh $CONTAINER_NAME:/workspace/spawn-subagent.sh 2>&1 | tee -a "$LOG_FILE"
    docker exec $CONTAINER_NAME chmod +x /workspace/spawn-subagent.sh 2>&1 | tee -a "$LOG_FILE"
fi

# Copy identity files
echo "Copying identity files to container" | tee -a "$LOG_FILE"
if [ "$RUNNING_AS_ROOT" = "true" ]; then
    sudo docker cp $HOME_DIR/docker-dev-container/SOUL.md $CONTAINER_NAME:/workspace/SOUL.md 2>&1 | tee -a "$LOG_FILE"
    sudo docker cp $HOME_DIR/docker-dev-container/AGENTS.md $CONTAINER_NAME:/workspace/AGENTS.md 2>&1 | tee -a "$LOG_FILE"
    sudo docker cp $HOME_DIR/docker-dev-container/USER.md $CONTAINER_NAME:/workspace/USER.md 2>&1 | tee -a "$LOG_FILE"
else
    docker cp $HOME_DIR/docker-dev-container/SOUL.md $CONTAINER_NAME:/workspace/SOUL.md 2>&1 | tee -a "$LOG_FILE"
    docker cp $HOME_DIR/docker-dev-container/AGENTS.md $CONTAINER_NAME:/workspace/AGENTS.md 2>&1 | tee -a "$LOG_FILE"
    docker cp $HOME_DIR/docker-dev-container/USER.md $CONTAINER_NAME:/workspace/USER.md 2>&1 | tee -a "$LOG_FILE"
fi

# Execute in container
echo "Executing task in container" | tee -a "$LOG_FILE"
if [ "$RUNNING_AS_ROOT" = "true" ]; then
    sudo docker exec $CONTAINER_NAME bash -c '
  set -e
  mkdir -p /tmp/.ssh
  cp /root/.ssh/github_key /tmp/.ssh/id_rsa 2>/dev/null || { echo "ERROR: SSH key not found"; exit 1; }
  chmod 600 /tmp/.ssh/* 2>/dev/null || true
  rm -f /root/.ssh/config 2>/dev/null || true
  export GIT_SSH_COMMAND="ssh -i /tmp/.ssh/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  
  echo "=== Task Execution Started ==="
  for info in $GIT_REMOTES; do r=${info%%=*}; git clone ${info#*=} $r 2>&1; done
  cd $PRIMARY_REPO
  [ -f package.json ] && npm install 2>/dev/null
  bash /workspace/task.sh 2>&1
  rm -f SOUL.md USER.md IDENTITY.md TOOLS.md HEARTBEAT.md BOOTSTRAP.md
  rm -f .openclaw/workspace-state.json
  rmdir .openclaw 2>/dev/null || true
  changed_files="$(git status --porcelain | awk '"'"'{print $2}'"'"')"
  meaningful_changes="$(printf "%s\n" "$changed_files" | grep -E '"'"'^(src/|app/|components/|pages/|public/|styles/|assets/|lib/|utils/|hooks/|store/|theme/|package\.json$|package-lock\.json$|yarn\.lock$|pnpm-lock\.yaml$|vite\.config|tailwind\.config|tsconfig|playwright\.config|scripts/|tests?/|__tests__/|cypress/|index\.)'"'"' || true)"
  if [ -n "$changed_files" ] && [ -z "$meaningful_changes" ]; then
    echo "ERROR: metadata-only or non-application changes detected; refusing to commit"
    printf "%s\n" "$changed_files"
    exit 1
  fi
  [ -n "$(git status --porcelain)" ] && {
    git config user.email "dominiquemb@users.noreply.github.com" && git config user.name "dominiquemb"
    git checkout -b $BRANCH_NAME && git add -A && git commit -m "feat: $DESCRIPTION" && git push -u origin $BRANCH_NAME 2>&1
    PR=$(gh pr create --title "feat: $DESCRIPTION" --body "Task: $TASK_NAME" --base main --head $BRANCH_NAME --assignee $NOTIFY_USER 2>&1)
    gh pr comment $PR --body "@$NOTIFY_USER Ready for review!" 2>/dev/null || true
    echo "PR created: $PR"
  }
' 2>&1 | tee -a "$LOG_FILE"
    
    sudo docker stop $CONTAINER_NAME 2>&1 | tee -a "$LOG_FILE"
    sudo docker rm $CONTAINER_NAME 2>&1 | tee -a "$LOG_FILE"
else
    docker exec $CONTAINER_NAME bash -c '
  set -e
  mkdir -p /tmp/.ssh
  cp /root/.ssh/github_key /tmp/.ssh/id_rsa 2>/dev/null || { echo "ERROR: SSH key not found"; exit 1; }
  chmod 600 /tmp/.ssh/* 2>/dev/null || true
  rm -f /root/.ssh/config 2>/dev/null || true
  export GIT_SSH_COMMAND="ssh -i /tmp/.ssh/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  
  echo "=== Task Execution Started ==="
  for info in $GIT_REMOTES; do r=${info%%=*}; git clone ${info#*=} $r 2>&1; done
  cd $PRIMARY_REPO
  [ -f package.json ] && npm install 2>/dev/null
  bash /workspace/task.sh 2>&1
  rm -f SOUL.md USER.md IDENTITY.md TOOLS.md HEARTBEAT.md BOOTSTRAP.md
  rm -f .openclaw/workspace-state.json
  rmdir .openclaw 2>/dev/null || true
  changed_files="$(git status --porcelain | awk '"'"'{print $2}'"'"')"
  meaningful_changes="$(printf "%s\n" "$changed_files" | grep -E '"'"'^(src/|app/|components/|pages/|public/|styles/|assets/|lib/|utils/|hooks/|store/|theme/|package\.json$|package-lock\.json$|yarn\.lock$|pnpm-lock\.yaml$|vite\.config|tailwind\.config|tsconfig|playwright\.config|scripts/|tests?/|__tests__/|cypress/|index\.)'"'"' || true)"
  if [ -n "$changed_files" ] && [ -z "$meaningful_changes" ]; then
    echo "ERROR: metadata-only or non-application changes detected; refusing to commit"
    printf "%s\n" "$changed_files"
    exit 1
  fi
  [ -n "$(git status --porcelain)" ] && {
    git config user.email "dominiquemb@users.noreply.github.com" && git config user.name "dominiquemb"
    git checkout -b $BRANCH_NAME && git add -A && git commit -m "feat: $DESCRIPTION" && git push -u origin $BRANCH_NAME 2>&1
    PR=$(gh pr create --title "feat: $DESCRIPTION" --body "Task: $TASK_NAME" --base main --head $BRANCH_NAME --assignee $NOTIFY_USER 2>&1)
    gh pr comment $PR --body "@$NOTIFY_USER Ready for review!" 2>/dev/null || true
    echo "PR created: $PR"
  }
' 2>&1 | tee -a "$LOG_FILE"
    
    docker stop $CONTAINER_NAME 2>&1 | tee -a "$LOG_FILE"
    docker rm $CONTAINER_NAME 2>&1 | tee -a "$LOG_FILE"
fi

echo "Task completed" | tee -a "$LOG_FILE"
echo "Log file: $LOG_FILE" | tee -a "$LOG_FILE"
