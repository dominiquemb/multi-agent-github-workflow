#!/bin/bash

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_ASSETS_DIR="$SCRIPT_DIR/docker-dev-container"

# Create logs directory
mkdir -p ~/tasks/logs

log() {
    local message="$1"
    echo "[$(date -Is)] $message" | tee -a "$LOG_FILE"
}

run_logged() {
    local step="$1"
    shift
    local output=""
    local status=0

    log "STEP: $step"
    set +e
    output=$("$@" 2>&1)
    status=$?
    set -e

    if [ -n "$output" ]; then
        printf '%s\n' "$output" | tee -a "$LOG_FILE"
    fi

    if [ "$status" -ne 0 ]; then
        set_task_status "failed_host_step" "$step (exit $status)"
        log "ERROR: step failed: $step (exit $status)"
        exit "$status"
    fi
}

capture_logged() {
    local step="$1"
    shift
    local __resultvar="$1"
    shift
    local output=""
    local status=0

    log "STEP: $step"
    set +e
    output=$("$@" 2>&1)
    status=$?
    set -e

    if [ -n "$output" ]; then
        printf '%s\n' "$output" | tee -a "$LOG_FILE"
    fi

    if [ "$status" -ne 0 ]; then
        set_task_status "failed_host_step" "$step (exit $status)"
        log "ERROR: step failed: $step (exit $status)"
        exit "$status"
    fi

    printf -v "$__resultvar" '%s' "$output"
}

docker_cmd() {
    if docker info >/dev/null 2>&1; then
        docker "$@"
        return
    fi

    sudo docker "$@"
}

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

PROJECT="" TASK_NAME="" DESCRIPTION="" SCRIPT_PATH="" TASK_TYPE="general" NOTIFY_USER="dominiquemb"
while [[ $# -gt 0 ]]; do
    case $1 in
        --project|-p) PROJECT="$2"; shift 2 ;;
        --task|-t) TASK_NAME="$2"; shift 2 ;;
        --desc|-d) DESCRIPTION="$2"; shift 2 ;;
        --script|-s) SCRIPT_PATH="$2"; shift 2 ;;
        --type) TASK_TYPE="$2"; shift 2 ;;
        --user|-u) NOTIFY_USER="$2"; shift 2 ;;
        *) exit 1 ;;
    esac
done

[ -z "$PROJECT" ] || [ -z "$TASK_NAME" ] || [ -z "$SCRIPT_PATH" ] && { echo "Usage: --project --task --desc --script [--type general|ui|api|full-stack]"; exit 1; }

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
ARTIFACTS_DIR="$HOME_DIR/tasks/logs/${TASK_NAME}.artifacts"
STATUS_DIR="$HOME_DIR/tasks/status"
STATUS_FILE="$STATUS_DIR/${TASK_NAME}.status"
FAILURE_REASON_FILE="$STATUS_DIR/${TASK_NAME}.failure_reason"
BATCH_ID="${TASK_BATCH_ID:-}"
BATCH_DIR="${TASK_BATCH_DIR:-}"

mkdir -p "$STATUS_DIR"

set_task_status() {
    local state="$1"
    local detail="${2:-}"
    {
        echo "task=$TASK_NAME"
        echo "project=$PROJECT"
        echo "state=$state"
        echo "timestamp=$(date -Is)"
        echo "container_name=$CONTAINER_NAME"
        echo "branch_name=$BRANCH_NAME"
        echo "log_file=$LOG_FILE"
        echo "artifacts_dir=$ARTIFACTS_DIR"
        echo "batch_id=$BATCH_ID"
        echo "batch_dir=$BATCH_DIR"
        echo "task_type=$TASK_TYPE"
        echo "detail=$detail"
    } > "$STATUS_FILE"

    if [[ "$state" == failed* ]] && [ -n "$detail" ]; then
        printf '%s\n' "$detail" > "$FAILURE_REASON_FILE"
    elif [[ "$state" != failed* ]]; then
        rm -f "$FAILURE_REASON_FILE"
    fi
}

echo "=== Task Runner ===" | tee -a "$LOG_FILE"
log "Project: $PROJECT | Task: $TASK_NAME | Type: $TASK_TYPE | Repos: $REPOS"
log "Git remotes: $GIT_REMOTES"
log "Log file: $LOG_FILE"
log "Artifacts dir: $ARTIFACTS_DIR"

mkdir -p "$ARTIFACTS_DIR"
set_task_status "starting" "runner initialized"

GH_TOKEN=$(cat $HOME_DIR/.gh_token 2>/dev/null || echo '')
MODAL_MOUNT_ARGS=""
MODAL_ENV_ARGS=""
MODEL_ENV_ARGS=""
CODEX_MOUNT_ARGS=""

if [ -f "$HOME_DIR/.modal.toml" ]; then
    MODAL_MOUNT_ARGS="-v $HOME_DIR/.modal.toml:/root/.modal.toml:ro"
fi

if [ -d "$HOME_DIR/.codex" ]; then
    CODEX_MOUNT_ARGS="-v $HOME_DIR/.codex:/root/.codex"
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
log "Starting container: $CONTAINER_NAME"
set_task_status "starting_container" "$CONTAINER_NAME"
if [ "$RUNNING_AS_ROOT" = "true" ]; then
    capture_logged "docker run $CONTAINER_NAME" CONTAINER_ID \
      sudo docker run -d --name "$CONTAINER_NAME" -v "$HOME_DIR/.ssh:/root/.ssh" \
      $MODAL_MOUNT_ARGS $CODEX_MOUNT_ARGS $MODAL_ENV_ARGS $MODEL_ENV_ARGS \
      -e GIT_REMOTES="$GIT_REMOTES" -e REPOS="$REPOS" -e PRIMARY_REPO="$PRIMARY_REPO" \
      -e BRANCH_NAME="$BRANCH_NAME" -e TASK_NAME="$TASK_NAME" -e TASK_TYPE="$TASK_TYPE" -e NOTIFY_USER="$NOTIFY_USER" \
      -e DESCRIPTION="$DESCRIPTION" -e GH_TOKEN="$GH_TOKEN" \
      -e GIT_AUTHOR_EMAIL='dominiquemb@users.noreply.github.com' \
      task-runner-base:latest bash -c "Xvfb :99 -screen 0 1920x1080x24 & fluxbox & sleep 2; tail -f /dev/null"
else
    capture_logged "docker run $CONTAINER_NAME" CONTAINER_ID \
      docker_cmd run -d --name "$CONTAINER_NAME" -v "$HOME_DIR/.ssh:/root/.ssh" \
      $MODAL_MOUNT_ARGS $CODEX_MOUNT_ARGS $MODAL_ENV_ARGS $MODEL_ENV_ARGS \
      -e GIT_REMOTES="$GIT_REMOTES" -e REPOS="$REPOS" -e PRIMARY_REPO="$PRIMARY_REPO" \
      -e BRANCH_NAME="$BRANCH_NAME" -e TASK_NAME="$TASK_NAME" -e TASK_TYPE="$TASK_TYPE" -e NOTIFY_USER="$NOTIFY_USER" \
      -e DESCRIPTION="$DESCRIPTION" -e GH_TOKEN="$GH_TOKEN" \
      -e GIT_AUTHOR_EMAIL='dominiquemb@users.noreply.github.com' \
      task-runner-base:latest bash -c "Xvfb :99 -screen 0 1920x1080x24 & fluxbox & sleep 2; tail -f /dev/null"
fi

sleep 3

CONTAINER_ID="$(printf '%s\n' "$CONTAINER_ID" | tail -n 1 | tr -d '\r')"
[ -z "$CONTAINER_ID" ] && { set_task_status "failed_host_step" "docker run returned no container id"; log "ERROR: docker run returned no container id"; exit 1; }
set_task_status "container_started" "$CONTAINER_ID"

# Copy task script
log "Copying task script to container"
set_task_status "copying_task_script" "/workspace/task.sh"
if [ "$RUNNING_AS_ROOT" = "true" ]; then
    run_logged "docker cp task script" sudo docker cp "$SCRIPT_PATH" "$CONTAINER_NAME:/workspace/task.sh"
else
    run_logged "docker cp task script" docker_cmd cp "$SCRIPT_PATH" "$CONTAINER_NAME:/workspace/task.sh"
fi

# Copy canonical container-side spawn-subagent.sh
log "Copying canonical spawn-subagent.sh to container"
set_task_status "copying_launcher" "/workspace/spawn-subagent.sh"
if [ "$RUNNING_AS_ROOT" = "true" ]; then
    run_logged "docker cp spawn-subagent.sh" sudo docker cp "$CONTAINER_ASSETS_DIR/spawn-subagent.sh" "$CONTAINER_NAME:/workspace/spawn-subagent.sh"
    run_logged "docker exec chmod spawn-subagent.sh" sudo docker exec "$CONTAINER_NAME" chmod +x /workspace/spawn-subagent.sh
else
    run_logged "docker cp spawn-subagent.sh" docker_cmd cp "$CONTAINER_ASSETS_DIR/spawn-subagent.sh" "$CONTAINER_NAME:/workspace/spawn-subagent.sh"
    run_logged "docker exec chmod spawn-subagent.sh" docker_cmd exec "$CONTAINER_NAME" chmod +x /workspace/spawn-subagent.sh
fi

# Copy identity files
log "Copying identity files to container"
set_task_status "copying_identity" "/workspace/SOUL.md,/workspace/AGENTS.md,/workspace/USER.md"
if [ "$RUNNING_AS_ROOT" = "true" ]; then
    run_logged "docker cp SOUL.md" sudo docker cp "$CONTAINER_ASSETS_DIR/SOUL.md" "$CONTAINER_NAME:/workspace/SOUL.md"
    run_logged "docker cp AGENTS.md" sudo docker cp "$CONTAINER_ASSETS_DIR/AGENTS.md" "$CONTAINER_NAME:/workspace/AGENTS.md"
    run_logged "docker cp USER.md" sudo docker cp "$CONTAINER_ASSETS_DIR/USER.md" "$CONTAINER_NAME:/workspace/USER.md"
else
    run_logged "docker cp SOUL.md" docker_cmd cp "$CONTAINER_ASSETS_DIR/SOUL.md" "$CONTAINER_NAME:/workspace/SOUL.md"
    run_logged "docker cp AGENTS.md" docker_cmd cp "$CONTAINER_ASSETS_DIR/AGENTS.md" "$CONTAINER_NAME:/workspace/AGENTS.md"
    run_logged "docker cp USER.md" docker_cmd cp "$CONTAINER_ASSETS_DIR/USER.md" "$CONTAINER_NAME:/workspace/USER.md"
fi

# Execute in container
log "Executing task in container"
set_task_status "executing" "docker exec"
TASK_EXIT_CODE=0
if [ "$RUNNING_AS_ROOT" = "true" ]; then
    set +e
    sudo docker exec $CONTAINER_NAME bash -c '
  set -e
  mkdir -p /tmp/.ssh
  mkdir -p /workspace/_task_artifacts
  cp /root/.ssh/github_key /tmp/.ssh/id_rsa 2>/dev/null || { echo "ERROR: SSH key not found"; exit 1; }
  chmod 600 /tmp/.ssh/* 2>/dev/null || true
  rm -f /root/.ssh/config 2>/dev/null || true
  export GIT_SSH_COMMAND="ssh -i /tmp/.ssh/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  
  echo "=== Task Execution Started ==="
  for info in $GIT_REMOTES; do r=${info%%=*}; git clone ${info#*=} $r 2>&1; done
  cd $PRIMARY_REPO
  [ -f package.json ] && npm install 2>/dev/null
  artifact_marker="/tmp/task-artifacts-start"
  touch "$artifact_marker"
  set +e
  bash /workspace/task.sh 2>&1
  task_exit=$?
  set -e
  cp /tmp/openclaw-subagent-${TASK_NAME}-*.log /workspace/_task_artifacts/ 2>/dev/null || true
  visual_artifact_note=""
  for repo in $REPOS; do
    repo_dir="/workspace/$repo"
    task_visual_dir="$repo_dir/e2e/screenshots/task-${TASK_NAME}"
    artifact_mirror_dir="/workspace/_task_artifacts/$repo/task-${TASK_NAME}"
    artifact_found=0
    [ -d "$repo_dir" ] || continue
    mkdir -p "$task_visual_dir" "$artifact_mirror_dir"
    while IFS= read -r -d "" asset; do
      artifact_found=1
      base_name="$(basename "$asset")"
      prefixed_name="${repo}-${base_name}"
      cp "$asset" "$task_visual_dir/$prefixed_name" 2>/dev/null || true
      cp "$asset" "$artifact_mirror_dir/$prefixed_name" 2>/dev/null || true
    done < <(find "$repo_dir" \
      \( -path "*/node_modules/*" -o -path "*/.git/*" \) -prune -o \
      -newer "$artifact_marker" \
      -type f \( -name "*.png" -o -name "*.jpg" -o -name "*.jpeg" -o -name "*.mp4" -o -name "*.webm" \) \
      \( -path "*/test-results/*" -o -path "*/playwright-report/*" -o -path "*/e2e/screenshots/*" -o -path "*/cypress/screenshots/*" -o -path "*/cypress/videos/*" \) \
      -print0 2>/dev/null)
    if [ "$artifact_found" -eq 1 ]; then
      summary_file="$task_visual_dir/summary.md"
      mirror_summary_file="$artifact_mirror_dir/summary.md"
      {
        echo "# Visual Test Artifacts"
        echo
        echo "Task: $TASK_NAME"
        echo "Repository: $repo"
        echo
        echo "Files:"
        find "$task_visual_dir" -maxdepth 1 -type f ! -name "summary.md" | sed "s|^$task_visual_dir/|- |" | sort
      } > "$summary_file"
      cp "$summary_file" "$mirror_summary_file" 2>/dev/null || true
      visual_artifact_note="${visual_artifact_note}\n- \`$repo/e2e/screenshots/task-${TASK_NAME}/\`"
    else
      rmdir "$task_visual_dir" 2>/dev/null || true
      rmdir "$artifact_mirror_dir" 2>/dev/null || true
      rmdir "/workspace/_task_artifacts/$repo" 2>/dev/null || true
    fi
  done
  if [ -n "$visual_artifact_note" ]; then
    printf "Visual artifacts committed in:\n%b\n" "$visual_artifact_note" > /workspace/_task_artifacts/visual-artifacts-note.txt
  fi
  [ "$task_exit" -ne 0 ] && exit "$task_exit"
  rm -f SOUL.md USER.md IDENTITY.md TOOLS.md HEARTBEAT.md BOOTSTRAP.md
  rm -f .openclaw/workspace-state.json
  rmdir .openclaw 2>/dev/null || true
  changed_files="$(git status --porcelain | awk '"'"'{print $2}'"'"')"
  meaningful_changes="$(printf "%s\n" "$changed_files" | grep -E '"'"'^(src/|app/|components/|pages/|public/|styles/|assets/|lib/|utils/|hooks/|store/|theme/|package\.json$|package-lock\.json$|yarn\.lock$|pnpm-lock\.yaml$|vite\.config|tailwind\.config|tsconfig|playwright\.config|scripts/|tests?/|__tests__/|cypress/|index\.)'"'"' || true)"
  ui_changes="$(printf "%s\n" "$changed_files" | grep -E '"'"'^(src/components/|components/|pages/|app/|styles/|public/|assets/|theme/|src/.*\.(css|scss|sass|less|jsx|tsx|vue)$|e2e/|cypress/)'"'"' || true)"
  if [ -n "$changed_files" ] && [ -z "$meaningful_changes" ]; then
    echo "ERROR: metadata-only or non-application changes detected; refusing to commit"
    printf "%s\n" "$changed_files"
    exit 1
  fi
  if [ -z "$meaningful_changes" ]; then
    echo "ERROR: sub-agent completed without meaningful application changes"
    exit 2
  fi
  if [ -n "$ui_changes" ] && [ ! -s /workspace/_task_artifacts/visual-artifacts-note.txt ]; then
    echo "ERROR: UI-affecting changes detected but no screenshots or videos were captured"
    printf "%s\n" "$ui_changes"
    exit 3
  fi
  [ -n "$(git status --porcelain)" ] && {
    git config user.email "dominiquemb@users.noreply.github.com" && git config user.name "dominiquemb"
    git checkout -b $BRANCH_NAME && git add -A && git commit -m "feat: $DESCRIPTION" && git push -u origin $BRANCH_NAME 2>&1
    pr_body="Task: $TASK_NAME"
    if [ -s /workspace/_task_artifacts/visual-artifacts-note.txt ]; then
      pr_body="$pr_body

$(cat /workspace/_task_artifacts/visual-artifacts-note.txt)"
    fi
    PR=$(gh pr create --title "feat: $DESCRIPTION" --body "$pr_body" --base main --head $BRANCH_NAME --assignee $NOTIFY_USER 2>&1)
    repo_slug="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
    commit_sha="$(git rev-parse HEAD 2>/dev/null || true)"
    gallery_comment_file="/tmp/pr-visual-comment.md"
    {
      echo "@$NOTIFY_USER Ready for review!"
      if [ -n "$repo_slug" ] && [ -n "$commit_sha" ] && [ -d "e2e/screenshots/task-${TASK_NAME}" ]; then
        echo
        echo "## Visual artifacts"
        for img in e2e/screenshots/task-${TASK_NAME}/*.png e2e/screenshots/task-${TASK_NAME}/*.jpg e2e/screenshots/task-${TASK_NAME}/*.jpeg; do
          [ -f "$img" ] || continue
          blob_url="https://github.com/$repo_slug/blob/$commit_sha/$img"
          echo
          echo "- [${img##*/}]($blob_url)"
        done
        video_printed=0
        for vid in e2e/screenshots/task-${TASK_NAME}/*.webm e2e/screenshots/task-${TASK_NAME}/*.mp4; do
          [ -f "$vid" ] || continue
          if [ "$video_printed" -eq 0 ]; then
            echo
            echo "## Videos"
            video_printed=1
          fi
          blob_url="https://github.com/$repo_slug/blob/$commit_sha/$vid?raw=1"
          echo "- [$vid]($blob_url)"
        done
      fi
    } > "$gallery_comment_file"
    gh pr comment $PR --body-file "$gallery_comment_file" 2>/dev/null || gh pr comment $PR --body "@$NOTIFY_USER Ready for review!" 2>/dev/null || true
    echo "PR created: $PR"
  }
' 2>&1 | tee -a "$LOG_FILE"
    TASK_EXIT_CODE=${PIPESTATUS[0]}
    set +e
    sudo docker cp "$CONTAINER_NAME:/workspace/_task_artifacts/." "$ARTIFACTS_DIR/" 2>&1 | tee -a "$LOG_FILE"
    COPY_ARTIFACTS_EXIT_CODE=${PIPESTATUS[0]}
    set -e
    if [ "$COPY_ARTIFACTS_EXIT_CODE" -ne 0 ]; then
        log "Artifact copy returned exit $COPY_ARTIFACTS_EXIT_CODE"
    fi

    if [ "$TASK_EXIT_CODE" -eq 0 ]; then
        set_task_status "cleanup" "stopping container"
        run_logged "docker stop $CONTAINER_NAME" sudo docker stop "$CONTAINER_NAME"
        run_logged "docker rm $CONTAINER_NAME" sudo docker rm "$CONTAINER_NAME"
    else
        set_task_status "failed_task" "task execution exit $TASK_EXIT_CODE"
        log "ERROR: task execution failed with exit $TASK_EXIT_CODE"
        log "Task failed; preserving container for inspection: $CONTAINER_NAME"
        exit "$TASK_EXIT_CODE"
    fi
else
    set +e
    docker_cmd exec $CONTAINER_NAME bash -c '
  set -e
  mkdir -p /tmp/.ssh
  mkdir -p /workspace/_task_artifacts
  cp /root/.ssh/github_key /tmp/.ssh/id_rsa 2>/dev/null || { echo "ERROR: SSH key not found"; exit 1; }
  chmod 600 /tmp/.ssh/* 2>/dev/null || true
  rm -f /root/.ssh/config 2>/dev/null || true
  export GIT_SSH_COMMAND="ssh -i /tmp/.ssh/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  
  echo "=== Task Execution Started ==="
  for info in $GIT_REMOTES; do r=${info%%=*}; git clone ${info#*=} $r 2>&1; done
  cd $PRIMARY_REPO
  [ -f package.json ] && npm install 2>/dev/null
  artifact_marker="/tmp/task-artifacts-start"
  touch "$artifact_marker"
  set +e
  bash /workspace/task.sh 2>&1
  task_exit=$?
  set -e
  cp /tmp/openclaw-subagent-${TASK_NAME}-*.log /workspace/_task_artifacts/ 2>/dev/null || true
  visual_artifact_note=""
  for repo in $REPOS; do
    repo_dir="/workspace/$repo"
    task_visual_dir="$repo_dir/e2e/screenshots/task-${TASK_NAME}"
    artifact_mirror_dir="/workspace/_task_artifacts/$repo/task-${TASK_NAME}"
    artifact_found=0
    [ -d "$repo_dir" ] || continue
    mkdir -p "$task_visual_dir" "$artifact_mirror_dir"
    while IFS= read -r -d "" asset; do
      artifact_found=1
      base_name="$(basename "$asset")"
      prefixed_name="${repo}-${base_name}"
      cp "$asset" "$task_visual_dir/$prefixed_name" 2>/dev/null || true
      cp "$asset" "$artifact_mirror_dir/$prefixed_name" 2>/dev/null || true
    done < <(find "$repo_dir" \
      \( -path "*/node_modules/*" -o -path "*/.git/*" \) -prune -o \
      -newer "$artifact_marker" \
      -type f \( -name "*.png" -o -name "*.jpg" -o -name "*.jpeg" -o -name "*.mp4" -o -name "*.webm" \) \
      \( -path "*/test-results/*" -o -path "*/playwright-report/*" -o -path "*/e2e/screenshots/*" -o -path "*/cypress/screenshots/*" -o -path "*/cypress/videos/*" \) \
      -print0 2>/dev/null)
    if [ "$artifact_found" -eq 1 ]; then
      summary_file="$task_visual_dir/summary.md"
      mirror_summary_file="$artifact_mirror_dir/summary.md"
      {
        echo "# Visual Test Artifacts"
        echo
        echo "Task: $TASK_NAME"
        echo "Repository: $repo"
        echo
        echo "Files:"
        find "$task_visual_dir" -maxdepth 1 -type f ! -name "summary.md" | sed "s|^$task_visual_dir/|- |" | sort
      } > "$summary_file"
      cp "$summary_file" "$mirror_summary_file" 2>/dev/null || true
      visual_artifact_note="${visual_artifact_note}\n- \`$repo/e2e/screenshots/task-${TASK_NAME}/\`"
    else
      rmdir "$task_visual_dir" 2>/dev/null || true
      rmdir "$artifact_mirror_dir" 2>/dev/null || true
      rmdir "/workspace/_task_artifacts/$repo" 2>/dev/null || true
    fi
  done
  if [ -n "$visual_artifact_note" ]; then
    printf "Visual artifacts committed in:\n%b\n" "$visual_artifact_note" > /workspace/_task_artifacts/visual-artifacts-note.txt
  fi
  [ "$task_exit" -ne 0 ] && exit "$task_exit"
  rm -f SOUL.md USER.md IDENTITY.md TOOLS.md HEARTBEAT.md BOOTSTRAP.md
  rm -f .openclaw/workspace-state.json
  rmdir .openclaw 2>/dev/null || true
  changed_files="$(git status --porcelain | awk '"'"'{print $2}'"'"')"
  meaningful_changes="$(printf "%s\n" "$changed_files" | grep -E '"'"'^(src/|app/|components/|pages/|public/|styles/|assets/|lib/|utils/|hooks/|store/|theme/|package\.json$|package-lock\.json$|yarn\.lock$|pnpm-lock\.yaml$|vite\.config|tailwind\.config|tsconfig|playwright\.config|scripts/|tests?/|__tests__/|cypress/|index\.)'"'"' || true)"
  ui_changes="$(printf "%s\n" "$changed_files" | grep -E '"'"'^(src/components/|components/|pages/|app/|styles/|public/|assets/|theme/|src/.*\.(css|scss|sass|less|jsx|tsx|vue)$|e2e/|cypress/)'"'"' || true)"
  if [ -n "$changed_files" ] && [ -z "$meaningful_changes" ]; then
    echo "ERROR: metadata-only or non-application changes detected; refusing to commit"
    printf "%s\n" "$changed_files"
    exit 1
  fi
  if [ -z "$meaningful_changes" ]; then
    echo "ERROR: sub-agent completed without meaningful application changes"
    exit 2
  fi
  if [ -n "$ui_changes" ] && [ ! -s /workspace/_task_artifacts/visual-artifacts-note.txt ]; then
    echo "ERROR: UI-affecting changes detected but no screenshots or videos were captured"
    printf "%s\n" "$ui_changes"
    exit 3
  fi
  [ -n "$(git status --porcelain)" ] && {
    git config user.email "dominiquemb@users.noreply.github.com" && git config user.name "dominiquemb"
    git checkout -b $BRANCH_NAME && git add -A && git commit -m "feat: $DESCRIPTION" && git push -u origin $BRANCH_NAME 2>&1
    pr_body="Task: $TASK_NAME"
    if [ -s /workspace/_task_artifacts/visual-artifacts-note.txt ]; then
      pr_body="$pr_body

$(cat /workspace/_task_artifacts/visual-artifacts-note.txt)"
    fi
    PR=$(gh pr create --title "feat: $DESCRIPTION" --body "$pr_body" --base main --head $BRANCH_NAME --assignee $NOTIFY_USER 2>&1)
    repo_slug="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
    commit_sha="$(git rev-parse HEAD 2>/dev/null || true)"
    gallery_comment_file="/tmp/pr-visual-comment.md"
    {
      echo "@$NOTIFY_USER Ready for review!"
      if [ -n "$repo_slug" ] && [ -n "$commit_sha" ] && [ -d "e2e/screenshots/task-${TASK_NAME}" ]; then
        echo
        echo "## Visual artifacts"
        for img in e2e/screenshots/task-${TASK_NAME}/*.png e2e/screenshots/task-${TASK_NAME}/*.jpg e2e/screenshots/task-${TASK_NAME}/*.jpeg; do
          [ -f "$img" ] || continue
          raw_url="https://raw.githubusercontent.com/$repo_slug/$commit_sha/$img"
          echo
          echo "![${img##*/}]($raw_url)"
        done
        video_printed=0
        for vid in e2e/screenshots/task-${TASK_NAME}/*.webm e2e/screenshots/task-${TASK_NAME}/*.mp4; do
          [ -f "$vid" ] || continue
          if [ "$video_printed" -eq 0 ]; then
            echo
            echo "## Videos"
            video_printed=1
          fi
          blob_url="https://github.com/$repo_slug/blob/$commit_sha/$vid?raw=1"
          echo "- [$vid]($blob_url)"
        done
      fi
    } > "$gallery_comment_file"
    gh pr comment $PR --body-file "$gallery_comment_file" 2>/dev/null || gh pr comment $PR --body "@$NOTIFY_USER Ready for review!" 2>/dev/null || true
    echo "PR created: $PR"
  }
' 2>&1 | tee -a "$LOG_FILE"
    TASK_EXIT_CODE=${PIPESTATUS[0]}
    set +e
    docker_cmd cp "$CONTAINER_NAME:/workspace/_task_artifacts/." "$ARTIFACTS_DIR/" 2>&1 | tee -a "$LOG_FILE"
    COPY_ARTIFACTS_EXIT_CODE=${PIPESTATUS[0]}
    set -e
    if [ "$COPY_ARTIFACTS_EXIT_CODE" -ne 0 ]; then
        log "Artifact copy returned exit $COPY_ARTIFACTS_EXIT_CODE"
    fi

    if [ "$TASK_EXIT_CODE" -eq 0 ]; then
        set_task_status "cleanup" "stopping container"
        run_logged "docker stop $CONTAINER_NAME" docker_cmd stop "$CONTAINER_NAME"
        run_logged "docker rm $CONTAINER_NAME" docker_cmd rm "$CONTAINER_NAME"
    else
        set_task_status "failed_task" "task execution exit $TASK_EXIT_CODE"
        log "ERROR: task execution failed with exit $TASK_EXIT_CODE"
        log "Task failed; preserving container for inspection: $CONTAINER_NAME"
        exit "$TASK_EXIT_CODE"
    fi
fi

set_task_status "completed" "success"
log "Task completed"
log "Log file: $LOG_FILE"
