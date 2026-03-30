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

PROJECT="" TASK_NAME="" DESCRIPTION="" SCRIPT_PATH="" TASK_TYPE="general" REQUIRED_REPOS="" NOTIFY_USER="dominiquemb"
while [[ $# -gt 0 ]]; do
    case $1 in
        --project|-p) PROJECT="$2"; shift 2 ;;
        --task|-t) TASK_NAME="$2"; shift 2 ;;
        --desc|-d) DESCRIPTION="$2"; shift 2 ;;
        --script|-s) SCRIPT_PATH="$2"; shift 2 ;;
        --type) TASK_TYPE="$2"; shift 2 ;;
        --required-repos) REQUIRED_REPOS="$2"; shift 2 ;;
        --user|-u) NOTIFY_USER="$2"; shift 2 ;;
        *) exit 1 ;;
    esac
done

[ -z "$PROJECT" ] || [ -z "$TASK_NAME" ] || [ -z "$SCRIPT_PATH" ] && { echo "Usage: --project --task --desc --script [--type general|ui|api|full-stack] [--required-repos \"repo1 repo2\"]"; exit 1; }

# Get project config
REPOS_VAR="${PROJECT}_repos"
PRIMARY_VAR="${PROJECT}_primary"
REPOS=$(eval echo "\$""$REPOS_VAR")
PRIMARY_REPO=$(eval echo "\$""$PRIMARY_VAR")
[ -z "$REPOS" ] && { echo "Unknown project: $PROJECT"; exit 1; }

if [ -z "$REQUIRED_REPOS" ]; then
    case "$(printf '%s' "$DESCRIPTION" | tr '[:upper:]' '[:lower:]')" in
        *"not loading"*|*"dropdown"*|*"template"*|*"validation"*|*"customer id"*|*"order id"*|*"super admin"*|*"blank"*|*"settings"*|*"results"*|*"api"*|*"backend"*|*"migration"*)
            if [ "$TASK_TYPE" = "general" ]; then
                TASK_TYPE="full-stack"
            fi
            REQUIRED_REPOS="$REPOS"
            ;;
    esac
fi

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
        echo "required_repos=$REQUIRED_REPOS"
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
log "Required repos: ${REQUIRED_REPOS:-none specified}"
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

if [ -n "${HEADROOM_ENABLED:-}" ]; then
    MODEL_ENV_ARGS="$MODEL_ENV_ARGS -e HEADROOM_ENABLED=$HEADROOM_ENABLED"
fi

if [ -n "${HEADROOM_PORT:-}" ]; then
    MODEL_ENV_ARGS="$MODEL_ENV_ARGS -e HEADROOM_PORT=$HEADROOM_PORT"
fi

if [ -n "${HEADROOM_HOST:-}" ]; then
    MODEL_ENV_ARGS="$MODEL_ENV_ARGS -e HEADROOM_HOST=$HEADROOM_HOST"
fi

if [ -n "${HEADROOM_STARTUP_DELAY:-}" ]; then
    MODEL_ENV_ARGS="$MODEL_ENV_ARGS -e HEADROOM_STARTUP_DELAY=$HEADROOM_STARTUP_DELAY"
fi

if [ -n "${RTK_ENABLED:-}" ]; then
    MODEL_ENV_ARGS="$MODEL_ENV_ARGS -e RTK_ENABLED=$RTK_ENABLED"
fi

if [ -n "${REQUIRED_REPOS:-}" ]; then
    MODEL_ENV_ARGS="$MODEL_ENV_ARGS -e REQUIRED_REPOS=$REQUIRED_REPOS"
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
      -e GIT_REMOTES="$GIT_REMOTES" -e REPOS="$REPOS" -e PRIMARY_REPO="$PRIMARY_REPO" -e REQUIRED_REPOS="$REQUIRED_REPOS" \
      -e BRANCH_NAME="$BRANCH_NAME" -e TASK_NAME="$TASK_NAME" -e TASK_TYPE="$TASK_TYPE" -e NOTIFY_USER="$NOTIFY_USER" \
      -e DESCRIPTION="$DESCRIPTION" -e GH_TOKEN="$GH_TOKEN" \
      -e GIT_AUTHOR_EMAIL='dominiquemb@users.noreply.github.com' \
      task-runner-base:latest bash -c "Xvfb :99 -screen 0 1920x1080x24 & fluxbox & sleep 2; tail -f /dev/null"
else
    capture_logged "docker run $CONTAINER_NAME" CONTAINER_ID \
      docker_cmd run -d --name "$CONTAINER_NAME" -v "$HOME_DIR/.ssh:/root/.ssh" \
      $MODAL_MOUNT_ARGS $CODEX_MOUNT_ARGS $MODAL_ENV_ARGS $MODEL_ENV_ARGS \
      -e GIT_REMOTES="$GIT_REMOTES" -e REPOS="$REPOS" -e PRIMARY_REPO="$PRIMARY_REPO" -e REQUIRED_REPOS="$REQUIRED_REPOS" \
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

# Copy canonical container-side run-codex.sh
log "Copying canonical run-codex.sh to container"
set_task_status "copying_codex_wrapper" "/workspace/run-codex.sh"
if [ "$RUNNING_AS_ROOT" = "true" ]; then
    run_logged "docker cp run-codex.sh" sudo docker cp "$CONTAINER_ASSETS_DIR/run-codex.sh" "$CONTAINER_NAME:/workspace/run-codex.sh"
    run_logged "docker exec chmod run-codex.sh" sudo docker exec "$CONTAINER_NAME" chmod +x /workspace/run-codex.sh
else
    run_logged "docker cp run-codex.sh" docker_cmd cp "$CONTAINER_ASSETS_DIR/run-codex.sh" "$CONTAINER_NAME:/workspace/run-codex.sh"
    run_logged "docker exec chmod run-codex.sh" docker_cmd exec "$CONTAINER_NAME" chmod +x /workspace/run-codex.sh
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
  backend_evidence_dir="/workspace/_task_artifacts/backend-evidence"
  backend_evidence_file="$backend_evidence_dir/summary.md"
  mkdir -p "$backend_evidence_dir"
  all_repo_changed_files=""
  backend_changed_files=""
  migration_changed_files=""
  changed_repos=""
  for repo in $REPOS; do
    repo_dir="/workspace/$repo"
    [ -d "$repo_dir/.git" ] || continue
    repo_status="$(cd "$repo_dir" && git status --porcelain)"
    repo_changed="$(printf "%s\n" "$repo_status" | awk '{print $2}')"
    if [ -n "$repo_changed" ]; then
      changed_repos="${changed_repos}${repo}\n"
      all_repo_changed_files="${all_repo_changed_files}${repo}:\n$(printf "%s\n" "$repo_changed")\n"
      repo_backend_changed="$(printf "%s\n" "$repo_changed" | grep -E \"(^src/|^app/|^api/|^server/|^routes/|^controllers/|^services/|^models/|^db/|^database/|^internal/|^cmd/|migration|migrations|schema|prisma|seed|sql/|\\.sql$)\" || true)"
      repo_migration_changed="$(printf "%s\n" "$repo_changed" | grep -E \"(migration|migrations|schema|prisma|seed|sql/|\\.sql$)\" || true)"
      [ -n "$repo_backend_changed" ] && backend_changed_files="${backend_changed_files}${repo}:\n${repo_backend_changed}\n"
      [ -n "$repo_migration_changed" ] && migration_changed_files="${migration_changed_files}${repo}:\n${repo_migration_changed}\n"
    fi
  done
  {
    echo "# Backend Evidence"
    echo
    echo "Task type: $TASK_TYPE"
    echo "Required repos: ${REQUIRED_REPOS:-none specified}"
    echo "Required repo status matrix:"
    for repo in ${REQUIRED_REPOS:-}; do
      repo_status_label="unchanged"
      if printf "%b" "$changed_repos" | grep -Fxq "$repo"; then
        repo_status_label="changed"
      fi
      echo "- $repo: $repo_status_label"
    done
    echo
    echo "Repos with changes:"
    if [ -n "$changed_repos" ]; then
      printf "%b" "$changed_repos" | sed "s/^/- /"
    else
      echo "- none"
    fi
    echo
    echo "All changed files by repo:"
    if [ -n "$all_repo_changed_files" ]; then
      printf "%b" "$all_repo_changed_files"
    else
      echo "none"
    fi
    echo
    echo "Backend-pattern changed files:"
    if [ -n "$backend_changed_files" ]; then
      printf "%b" "$backend_changed_files"
    else
      echo "none"
    fi
    echo
    echo "Migration-pattern changed files:"
    if [ -n "$migration_changed_files" ]; then
      printf "%b" "$migration_changed_files"
    else
      echo "none"
    fi
    if [ -f "$backend_evidence_dir/agent-notes.txt" ]; then
      echo
      echo "Agent notes:"
      cat "$backend_evidence_dir/agent-notes.txt"
    fi
  } > "$backend_evidence_file"
  if [ -s /workspace/_task_artifacts/visual-artifacts-note.txt ] && { [ "$TASK_TYPE" = "ui" ] || [ "$TASK_TYPE" = "full-stack" ]; }; then
    qa_dir="/workspace/_task_artifacts/qa"
    qa_output_file="$qa_dir/review.txt"
    qa_summary_file="$qa_dir/summary.md"
    qa_followup_note=""
    mkdir -p "$qa_dir"
    run_screenshot_qa() {
      local prompt_file="$1"
      shift
      local images=("$@")
      local qa_cmd=(
        /workspace/run-codex.sh
        --cd "$(pwd)"
        --skip-git-repo-check
        --dangerously-bypass-approvals-and-sandbox
        --output-last-message "$qa_output_file"
      )
      for qa_img in "${images[@]}"; do
        qa_cmd+=(--image "$qa_img")
      done
      set +e
      "${qa_cmd[@]}" "$(cat "$prompt_file")" >/tmp/task-qa-codex.log 2>&1
      local qa_exit=$?
      set -e
      cp /tmp/task-qa-codex.log "$qa_dir/codex.log" 2>/dev/null || true
      return "$qa_exit"
    }

    build_qa_summary() {
      local images=("$@")
      {
        echo "# Screenshot QA Review"
        echo
        cat "$qa_output_file" 2>/dev/null || true
        if [ -n "$qa_followup_note" ]; then
          echo
          echo "Follow-up:"
          echo "$qa_followup_note"
        fi
        echo
        echo "Screenshots reviewed:"
        for qa_img in "${images[@]}"; do
          echo "- ${qa_img#/workspace/}"
        done
      } > "$qa_summary_file"
    }

    mapfile -t qa_images < <(find /workspace -path "*/e2e/screenshots/task-${TASK_NAME}/*" \
      \( -name "*.png" -o -name "*.jpg" -o -name "*.jpeg" \) -type f | sort)
    if [ "${#qa_images[@]}" -gt 0 ]; then
      qa_prompt_file="/tmp/task-qa-prompt.txt"
      {
        echo "You are reviewing screenshot evidence for a completed coding task."
        echo
        echo "Task type: $TASK_TYPE"
        echo "Task name: $TASK_NAME"
        echo "Short description: $DESCRIPTION"
        echo
        echo "Original task launcher script:"
        cat /workspace/task.sh
        echo
        echo "Review instructions:"
        echo "1. Compare the attached screenshots against the task intent."
        echo "2. Focus on whether the requested visible UI outcome appears to be present."
        echo "3. Reply using exactly this format:"
        echo "RESULT: PASS or RESULT: FAIL"
        echo "REASON: one concise sentence"
        echo "DETAILS: one short paragraph"
        echo "4. Return FAIL if the screenshots do not provide convincing evidence that the requested UI outcome was achieved."
      } > "$qa_prompt_file"

      if ! run_screenshot_qa "$qa_prompt_file" "${qa_images[@]}"; then
        qa_followup_note="The screenshot QA reviewer could not complete successfully."
      elif ! grep -Eq '^RESULT:[[:space:]]*PASS' "$qa_output_file"; then
        remediation_prompt_file="/tmp/task-qa-remediation-prompt.txt"
        {
          echo "A screenshot QA review found that the task may not fully satisfy the requested UI outcome."
          echo
          echo "Task type: $TASK_TYPE"
          echo "Task name: $TASK_NAME"
          echo "Short description: $DESCRIPTION"
          echo
          echo "Original task launcher script:"
          cat /workspace/task.sh
          echo
          echo "QA review findings:"
          cat "$qa_output_file"
          echo
          echo "Instructions:"
          echo "1. Make the smallest relevant code and test changes needed to improve alignment with the task."
          echo "2. Regenerate screenshots if appropriate."
          echo "3. Do not discard valid prior work."
          echo "4. Exit 0 even if you conclude no further code changes are appropriate."
        } > "$remediation_prompt_file"

        remediation_cmd=(
          /workspace/run-codex.sh
          --cd "$(pwd)"
          --skip-git-repo-check
          --dangerously-bypass-approvals-and-sandbox
        )
        for qa_img in "${qa_images[@]}"; do
          remediation_cmd+=(--image "$qa_img")
        done

        set +e
        "${remediation_cmd[@]}" "$(cat "$remediation_prompt_file")" >/tmp/task-qa-remediation-codex.log 2>&1
        remediation_exit=$?
        set -e
        cp /tmp/task-qa-remediation-codex.log "$qa_dir/remediation.log" 2>/dev/null || true

        if [ "$remediation_exit" -eq 0 ]; then
          mapfile -t qa_images < <(find /workspace -path "*/e2e/screenshots/task-${TASK_NAME}/*" \
            \( -name "*.png" -o -name "*.jpg" -o -name "*.jpeg" \) -type f | sort)
          if run_screenshot_qa "$qa_prompt_file" "${qa_images[@]}"; then
            qa_followup_note="A follow-up remediation pass was attempted after the initial QA review."
          else
            qa_followup_note="A follow-up remediation pass was attempted, but the second QA review could not complete."
          fi
        else
          qa_followup_note="A follow-up remediation pass was attempted, but Codex exited non-zero."
        fi
      fi

      build_qa_summary "${qa_images[@]}"
    fi
  fi
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
  sufficiency_dir="/workspace/_task_artifacts/sufficiency"
  sufficiency_output_file="$sufficiency_dir/review.txt"
  sufficiency_summary_file="$sufficiency_dir/summary.md"
  sufficiency_followup_note=""
  mkdir -p "$sufficiency_dir"
  build_sufficiency_prompt() {
    local prompt_file="$1"
    {
      echo "You are reviewing whether a coding task appears sufficiently implemented before PR creation."
      echo
      echo "Task type: $TASK_TYPE"
      echo "Task name: $TASK_NAME"
      echo "Short description: $DESCRIPTION"
      echo "Required repos: ${REQUIRED_REPOS:-none specified}"
      echo
      echo "Original task launcher script:"
      cat /workspace/task.sh
      echo
      echo "Backend evidence summary:"
      cat /workspace/_task_artifacts/backend-evidence/summary.md 2>/dev/null || true
      echo
      echo "Changed files:"
      printf "%s\n" "$changed_files"
      echo
      echo "Review instructions:"
      echo "1. Determine whether the current changes appear sufficient for the requested task."
      echo "2. Explicitly consider whether backend, API, validation, persistence, or migration changes seem necessary."
      echo "3. For each required repo, classify it as one of: CHANGED, OK-UNCHANGED, or MISSING-WORK."
      echo "4. Reply using exactly this format:"
      echo "RESULT: PASS or RESULT: FAIL"
      echo "REASON: one concise sentence"
      echo "DETAILS: one short paragraph"
      echo "REPO-ASSESSMENT:"
      echo "- <repo>: CHANGED | OK-UNCHANGED | MISSING-WORK - <short reason>"
      echo "5. Return FAIL if the task appears incomplete, if likely backend/API changes are missing, or if likely migrations are missing."
    } > "$prompt_file"
  }

  run_sufficiency_review() {
    local prompt_file="$1"
    set +e
    /workspace/run-codex.sh \
      --cd "$(pwd)" \
      --skip-git-repo-check \
      --dangerously-bypass-approvals-and-sandbox \
      --output-last-message "$sufficiency_output_file" \
      "$(cat "$prompt_file")" >/tmp/task-sufficiency-codex.log 2>&1
    local review_exit=$?
    set -e
    cp /tmp/task-sufficiency-codex.log "$sufficiency_dir/codex.log" 2>/dev/null || true
    return "$review_exit"
  }

  build_sufficiency_summary() {
    {
      echo "# Sufficiency Review"
      echo
      cat "$sufficiency_output_file" 2>/dev/null || true
      if [ -n "$sufficiency_followup_note" ]; then
        echo
        echo "Follow-up:"
        echo "$sufficiency_followup_note"
      fi
      echo
      echo "Changed files reviewed:"
      printf "%s\n" "$changed_files"
    } > "$sufficiency_summary_file"
  }

  sufficiency_prompt_file="/tmp/task-sufficiency-prompt.txt"
  build_sufficiency_prompt "$sufficiency_prompt_file"
  if ! run_sufficiency_review "$sufficiency_prompt_file"; then
    sufficiency_followup_note="The sufficiency reviewer could not complete successfully."
  elif ! grep -Eq '^RESULT:[[:space:]]*PASS' "$sufficiency_output_file"; then
    remediation_prompt_file="/tmp/task-sufficiency-remediation-prompt.txt"
    {
      echo "A sufficiency review found that the current task may still be incomplete."
      echo
      echo "Task type: $TASK_TYPE"
      echo "Task name: $TASK_NAME"
      echo "Short description: $DESCRIPTION"
      echo "Required repos: ${REQUIRED_REPOS:-none specified}"
      echo
      echo "Original task launcher script:"
      cat /workspace/task.sh
      echo
      echo "Backend evidence summary:"
      cat /workspace/_task_artifacts/backend-evidence/summary.md 2>/dev/null || true
      echo
      echo "Changed files:"
      printf "%s\n" "$changed_files"
      echo
      echo "Review findings:"
      cat "$sufficiency_output_file"
      echo
      echo "Instructions:"
      echo "1. Make the smallest relevant code and test changes needed to address the likely omissions."
      echo "2. Explicitly consider backend, API, validation, persistence, and migrations."
      echo "3. Pay special attention to any required repo that the review classified as MISSING-WORK."
      echo "4. Do not discard valid prior work."
      echo "5. Exit 0 even if you conclude no further changes are appropriate."
    } > "$remediation_prompt_file"

    set +e
    /workspace/run-codex.sh \
      --cd "$(pwd)" \
      --skip-git-repo-check \
      --dangerously-bypass-approvals-and-sandbox \
      "$(cat "$remediation_prompt_file")" >/tmp/task-sufficiency-remediation-codex.log 2>&1
    remediation_exit=$?
    set -e
    cp /tmp/task-sufficiency-remediation-codex.log "$sufficiency_dir/remediation.log" 2>/dev/null || true

    changed_files="$(git status --porcelain | awk '{print $2}')"
    meaningful_changes="$(printf "%s\n" "$changed_files" | grep -E "^(src/|app/|components/|pages/|public/|styles/|assets/|lib/|utils/|hooks/|store/|theme/|package\.json$|package-lock\.json$|yarn\.lock$|pnpm-lock\.yaml$|vite\.config|tailwind\.config|tsconfig|playwright\.config|scripts/|tests?/|__tests__/|cypress/|index\.)" || true)"
    ui_changes="$(printf "%s\n" "$changed_files" | grep -E "^(src/components/|components/|pages/|app/|styles/|public/|assets/|theme/|src/.*\.(css|scss|sass|less|jsx|tsx|vue)$|e2e/|cypress/)" || true)"
    build_sufficiency_prompt "$sufficiency_prompt_file"
    if [ "$remediation_exit" -eq 0 ] && run_sufficiency_review "$sufficiency_prompt_file"; then
      sufficiency_followup_note="A follow-up remediation pass was attempted after the initial sufficiency review."
    elif [ "$remediation_exit" -eq 0 ]; then
      sufficiency_followup_note="A follow-up remediation pass was attempted, but the second sufficiency review could not complete."
    else
      sufficiency_followup_note="A follow-up remediation pass was attempted, but Codex exited non-zero."
    fi
  fi
  build_sufficiency_summary
  [ -n "$(git status --porcelain)" ] && {
    git config --global user.email "dominiquemb@users.noreply.github.com"
    git config --global user.name "dominiquemb"
    multi_repo_prs_file="/workspace/_task_artifacts/multi-repo-prs.txt"
    : > "$multi_repo_prs_file"
    changed_repo_list=""
    for repo in $REPOS; do
      repo_dir="/workspace/$repo"
      [ -d "$repo_dir/.git" ] || continue
      repo_status="$(cd "$repo_dir" && git status --porcelain)"
      [ -n "$repo_status" ] || continue
      changed_repo_list="${changed_repo_list}${repo}\n"
    done
    [ -n "$changed_repo_list" ] || exit 2
    while IFS= read -r repo; do
      [ -n "$repo" ] || continue
      repo_dir="/workspace/$repo"
      cd "$repo_dir"
      git checkout -b "$BRANCH_NAME"
      git add -A
      git commit -m "feat: $DESCRIPTION"
      git push -u origin "$BRANCH_NAME" 2>&1
      pr_body="Task: $TASK_NAME

Repository: $repo"
      if [ -s /workspace/_task_artifacts/visual-artifacts-note.txt ] && [ "$repo" = "$PRIMARY_REPO" ]; then
        pr_body="$pr_body

$(cat /workspace/_task_artifacts/visual-artifacts-note.txt)"
      fi
      if [ -s /workspace/_task_artifacts/backend-evidence/summary.md ]; then
        pr_body="$pr_body

Backend evidence summary attached in follow-up PR comment."
      fi
      PR=$(gh pr create --title "feat: $DESCRIPTION" --body "$pr_body" --base main --head "$BRANCH_NAME" --assignee "$NOTIFY_USER" 2>&1)
      printf "%s\t%s\n" "$repo" "$PR" >> "$multi_repo_prs_file"
      echo "PR created for $repo: $PR"
    done < <(printf "%b" "$changed_repo_list")

    while IFS="$(printf '\t')" read -r repo pr_ref; do
      [ -n "$repo" ] || continue
      repo_dir="/workspace/$repo"
      cd "$repo_dir"
      repo_slug="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
      commit_sha="$(git rev-parse HEAD 2>/dev/null || true)"
      gallery_comment_file="/tmp/pr-comment-${repo}.md"
      {
        echo "@$NOTIFY_USER Ready for review!"
        echo
        echo "## Related PRs"
        while IFS="$(printf '\t')" read -r linked_repo linked_pr; do
          [ -n "$linked_repo" ] || continue
          echo "- $linked_repo: $linked_pr"
        done < "$multi_repo_prs_file"
        if [ -s /workspace/_task_artifacts/sufficiency/summary.md ]; then
          echo
          echo "## Sufficiency Review"
          sed '1d' /workspace/_task_artifacts/sufficiency/summary.md
        fi
        if [ -s /workspace/_task_artifacts/backend-evidence/summary.md ]; then
          echo
          echo "## Backend Evidence"
          sed '1d' /workspace/_task_artifacts/backend-evidence/summary.md
        fi
        if [ -s /workspace/_task_artifacts/qa/summary.md ] && [ "$repo" = "$PRIMARY_REPO" ]; then
          echo
          echo "## Screenshot QA"
          sed '1d' /workspace/_task_artifacts/qa/summary.md
        fi
        if [ -n "$repo_slug" ] && [ -n "$commit_sha" ] && [ "$repo" = "$PRIMARY_REPO" ] && [ -d "e2e/screenshots/task-${TASK_NAME}" ]; then
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
      gh pr comment "$pr_ref" --body-file "$gallery_comment_file" 2>/dev/null || gh pr comment "$pr_ref" --body "@$NOTIFY_USER Ready for review!" 2>/dev/null || true
    done < "$multi_repo_prs_file"
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
  backend_evidence_dir="/workspace/_task_artifacts/backend-evidence"
  backend_evidence_file="$backend_evidence_dir/summary.md"
  mkdir -p "$backend_evidence_dir"
  all_repo_changed_files=""
  backend_changed_files=""
  migration_changed_files=""
  changed_repos=""
  for repo in $REPOS; do
    repo_dir="/workspace/$repo"
    [ -d "$repo_dir/.git" ] || continue
    repo_status="$(cd "$repo_dir" && git status --porcelain)"
    repo_changed="$(printf "%s\n" "$repo_status" | awk '{print $2}')"
    if [ -n "$repo_changed" ]; then
      changed_repos="${changed_repos}${repo}\n"
      all_repo_changed_files="${all_repo_changed_files}${repo}:\n$(printf "%s\n" "$repo_changed")\n"
      repo_backend_changed="$(printf "%s\n" "$repo_changed" | grep -E \"(^src/|^app/|^api/|^server/|^routes/|^controllers/|^services/|^models/|^db/|^database/|^internal/|^cmd/|migration|migrations|schema|prisma|seed|sql/|\\.sql$)\" || true)"
      repo_migration_changed="$(printf "%s\n" "$repo_changed" | grep -E \"(migration|migrations|schema|prisma|seed|sql/|\\.sql$)\" || true)"
      [ -n "$repo_backend_changed" ] && backend_changed_files="${backend_changed_files}${repo}:\n${repo_backend_changed}\n"
      [ -n "$repo_migration_changed" ] && migration_changed_files="${migration_changed_files}${repo}:\n${repo_migration_changed}\n"
    fi
  done
  {
    echo "# Backend Evidence"
    echo
    echo "Task type: $TASK_TYPE"
    echo "Required repos: ${REQUIRED_REPOS:-none specified}"
    echo "Required repo status matrix:"
    for repo in ${REQUIRED_REPOS:-}; do
      repo_status_label="unchanged"
      if printf "%b" "$changed_repos" | grep -Fxq "$repo"; then
        repo_status_label="changed"
      fi
      echo "- $repo: $repo_status_label"
    done
    echo
    echo "Repos with changes:"
    if [ -n "$changed_repos" ]; then
      printf "%b" "$changed_repos" | sed "s/^/- /"
    else
      echo "- none"
    fi
    echo
    echo "All changed files by repo:"
    if [ -n "$all_repo_changed_files" ]; then
      printf "%b" "$all_repo_changed_files"
    else
      echo "none"
    fi
    echo
    echo "Backend-pattern changed files:"
    if [ -n "$backend_changed_files" ]; then
      printf "%b" "$backend_changed_files"
    else
      echo "none"
    fi
    echo
    echo "Migration-pattern changed files:"
    if [ -n "$migration_changed_files" ]; then
      printf "%b" "$migration_changed_files"
    else
      echo "none"
    fi
    if [ -f "$backend_evidence_dir/agent-notes.txt" ]; then
      echo
      echo "Agent notes:"
      cat "$backend_evidence_dir/agent-notes.txt"
    fi
  } > "$backend_evidence_file"
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
    git config --global user.email "dominiquemb@users.noreply.github.com"
    git config --global user.name "dominiquemb"
    multi_repo_prs_file="/workspace/_task_artifacts/multi-repo-prs.txt"
    : > "$multi_repo_prs_file"
    changed_repo_list=""
    for repo in $REPOS; do
      repo_dir="/workspace/$repo"
      [ -d "$repo_dir/.git" ] || continue
      repo_status="$(cd "$repo_dir" && git status --porcelain)"
      [ -n "$repo_status" ] || continue
      changed_repo_list="${changed_repo_list}${repo}\n"
    done
    [ -n "$changed_repo_list" ] || exit 2
    while IFS= read -r repo; do
      [ -n "$repo" ] || continue
      repo_dir="/workspace/$repo"
      cd "$repo_dir"
      git checkout -b "$BRANCH_NAME"
      git add -A
      git commit -m "feat: $DESCRIPTION"
      git push -u origin "$BRANCH_NAME" 2>&1
      pr_body="Task: $TASK_NAME

Repository: $repo"
      if [ -s /workspace/_task_artifacts/visual-artifacts-note.txt ] && [ "$repo" = "$PRIMARY_REPO" ]; then
        pr_body="$pr_body

$(cat /workspace/_task_artifacts/visual-artifacts-note.txt)"
      fi
      if [ -s /workspace/_task_artifacts/backend-evidence/summary.md ]; then
        pr_body="$pr_body

Backend evidence summary attached in follow-up PR comment."
      fi
      PR=$(gh pr create --title "feat: $DESCRIPTION" --body "$pr_body" --base main --head "$BRANCH_NAME" --assignee "$NOTIFY_USER" 2>&1)
      printf "%s\t%s\n" "$repo" "$PR" >> "$multi_repo_prs_file"
      echo "PR created for $repo: $PR"
    done < <(printf "%b" "$changed_repo_list")

    while IFS="$(printf '\t')" read -r repo pr_ref; do
      [ -n "$repo" ] || continue
      repo_dir="/workspace/$repo"
      cd "$repo_dir"
      repo_slug="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
      commit_sha="$(git rev-parse HEAD 2>/dev/null || true)"
      gallery_comment_file="/tmp/pr-comment-${repo}.md"
      {
        echo "@$NOTIFY_USER Ready for review!"
        echo
        echo "## Related PRs"
        while IFS="$(printf '\t')" read -r linked_repo linked_pr; do
          [ -n "$linked_repo" ] || continue
          echo "- $linked_repo: $linked_pr"
        done < "$multi_repo_prs_file"
        if [ -s /workspace/_task_artifacts/backend-evidence/summary.md ]; then
          echo
          echo "## Backend Evidence"
          sed '1d' /workspace/_task_artifacts/backend-evidence/summary.md
        fi
        if [ -n "$repo_slug" ] && [ -n "$commit_sha" ] && [ "$repo" = "$PRIMARY_REPO" ] && [ -d "e2e/screenshots/task-${TASK_NAME}" ]; then
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
      gh pr comment "$pr_ref" --body-file "$gallery_comment_file" 2>/dev/null || gh pr comment "$pr_ref" --body "@$NOTIFY_USER Ready for review!" 2>/dev/null || true
    done < "$multi_repo_prs_file"
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
