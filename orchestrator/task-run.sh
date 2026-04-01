#!/bin/bash

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_ASSETS_DIR="$SCRIPT_DIR/docker-dev-container"
TASK_MEMORY_CLI="$SCRIPT_DIR/task-memory.py"
TASK_MEMORY_DB="${TASK_MEMORY_DB:-$HOME/tasks/memory.db}"

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
SECRET_FILES_VAR="${PROJECT}_secret_files"
REPOS=$(eval echo "\$""$REPOS_VAR")
PRIMARY_REPO=$(eval echo "\$""$PRIMARY_VAR")
PROJECT_SECRET_FILES=$(eval echo "\$""$SECRET_FILES_VAR")
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

REQUIRED_REPOS="$(printf '%s' "$REQUIRED_REPOS" | tr ',' ' ' | xargs)"
REQUIRED_REPOS_ENV="${REQUIRED_REPOS// /,}"

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

REPOS="$(printf '%s' "$REPOS" | xargs)"
REPOS_ENV="${REPOS// /,}"
GIT_REMOTES_ENV="$(printf '%s' "$GIT_REMOTES" | xargs | sed 's/ /;/g')"

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

record_task_memory() {
    local state="$1"
    local detail="${2:-}"
    local changed_repos_file="$ARTIFACTS_DIR/multi-repo-prs.txt"
    local backend_evidence_file="$ARTIFACTS_DIR/backend-evidence/summary.md"
    local sufficiency_review_file="$ARTIFACTS_DIR/sufficiency/summary.md"
    local qa_review_file="$ARTIFACTS_DIR/qa/summary.md"
    local related_prs_file="$ARTIFACTS_DIR/multi-repo-prs.txt"
    local changed_repos=""

    if [ -f "$related_prs_file" ]; then
        changed_repos="$(cut -f1 "$related_prs_file" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    fi

    if [ ! -f "$TASK_MEMORY_CLI" ]; then
        return 0
    fi

    python3 "$TASK_MEMORY_CLI" --db "$TASK_MEMORY_DB" record \
        --task-name "$TASK_NAME" \
        --project "$PROJECT" \
        --task-type "$TASK_TYPE" \
        --description "$DESCRIPTION" \
        --required-repos "$REQUIRED_REPOS" \
        --branch-name "$BRANCH_NAME" \
        --state "$state" \
        --detail "$detail" \
        --artifacts-dir "$ARTIFACTS_DIR" \
        --log-file "$LOG_FILE" \
        --changed-repos "$changed_repos" \
        --backend-evidence-file "$backend_evidence_file" \
        --sufficiency-review-file "$sufficiency_review_file" \
        --qa-review-file "$qa_review_file" \
        --related-prs-file "$related_prs_file" \
        >/dev/null 2>&1 || true
}

echo "=== Task Runner ===" | tee -a "$LOG_FILE"
log "Project: $PROJECT | Task: $TASK_NAME | Type: $TASK_TYPE | Repos: $REPOS"
log "Required repos: ${REQUIRED_REPOS:-none specified}"
log "Git remotes: $GIT_REMOTES"
log "Log file: $LOG_FILE"
log "Artifacts dir: $ARTIFACTS_DIR"

mkdir -p "$ARTIFACTS_DIR"
python3 "$TASK_MEMORY_CLI" --db "$TASK_MEMORY_DB" init >/dev/null 2>&1 || true
set_task_status "starting" "runner initialized"

GH_TOKEN=$(cat $HOME_DIR/.gh_token 2>/dev/null || echo '')
DOCKER_RUN_ARGS=(-d --name "$CONTAINER_NAME" -v "$HOME_DIR/.ssh:/root/.ssh")
SECRET_FILE_MAPPINGS_ENV=""
SECRET_INDEX=0

if [ -n "$PROJECT_SECRET_FILES" ]; then
    OLD_IFS="$IFS"
    IFS=';'
    for secret_entry in $PROJECT_SECRET_FILES; do
        [ -n "$secret_entry" ] || continue
        IFS='|' read -r SECRET_REPO SECRET_DEST SECRET_HOST <<< "$secret_entry"
        IFS=';'
        if [ -z "$SECRET_REPO" ] || [ -z "$SECRET_DEST" ] || [ -z "$SECRET_HOST" ]; then
            log "WARNING: skipping malformed secret mapping: $secret_entry"
            continue
        fi
        if [ ! -e "$SECRET_HOST" ]; then
            log "WARNING: secret source not found, skipping: $SECRET_HOST"
            continue
        fi
        SECRET_MOUNT_PATH="/run/task-secrets/secret${SECRET_INDEX}"
        DOCKER_RUN_ARGS+=(-v "$SECRET_HOST:$SECRET_MOUNT_PATH:ro")
        SECRET_FILE_MAPPINGS_ENV="${SECRET_FILE_MAPPINGS_ENV}${SECRET_REPO}|${SECRET_DEST}|${SECRET_MOUNT_PATH};"
        SECRET_INDEX=$((SECRET_INDEX + 1))
    done
    IFS="$OLD_IFS"
fi

if [ -f "$HOME_DIR/.modal.toml" ]; then
    DOCKER_RUN_ARGS+=(-v "$HOME_DIR/.modal.toml:/root/.modal.toml:ro")
fi

if [ -d "$HOME_DIR/.codex" ]; then
    DOCKER_RUN_ARGS+=(-v "$HOME_DIR/.codex:/root/.codex")
fi

if [ -n "${MODAL_TOKEN_ID:-}" ]; then
    DOCKER_RUN_ARGS+=(-e "MODAL_TOKEN_ID=$MODAL_TOKEN_ID")
fi

if [ -n "${MODAL_TOKEN_SECRET:-}" ]; then
    DOCKER_RUN_ARGS+=(-e "MODAL_TOKEN_SECRET=$MODAL_TOKEN_SECRET")
fi

if [ -n "${MODAL_PROFILE:-}" ]; then
    DOCKER_RUN_ARGS+=(-e "MODAL_PROFILE=$MODAL_PROFILE")
fi

if [ -n "${OPENCLAW_VLLM_BASE_URL:-}" ]; then
    DOCKER_RUN_ARGS+=(-e "OPENCLAW_VLLM_BASE_URL=$OPENCLAW_VLLM_BASE_URL")
fi

if [ -n "${OPENCLAW_VLLM_MODEL_ID:-}" ]; then
    DOCKER_RUN_ARGS+=(-e "OPENCLAW_VLLM_MODEL_ID=$OPENCLAW_VLLM_MODEL_ID")
fi

if [ -n "${OPENCLAW_VLLM_API_KEY:-}" ]; then
    DOCKER_RUN_ARGS+=(-e "OPENCLAW_VLLM_API_KEY=$OPENCLAW_VLLM_API_KEY")
fi

if [ -n "${RTK_ENABLED:-}" ]; then
    DOCKER_RUN_ARGS+=(-e "RTK_ENABLED=$RTK_ENABLED")
fi

if [ -n "$SECRET_FILE_MAPPINGS_ENV" ]; then
    DOCKER_RUN_ARGS+=(-e "SECRET_FILE_MAPPINGS=$SECRET_FILE_MAPPINGS_ENV")
fi

if [ -n "${REQUIRED_REPOS_ENV:-}" ]; then
    DOCKER_RUN_ARGS+=(-e "REQUIRED_REPOS=$REQUIRED_REPOS_ENV")
fi

if [ -n "${SUBAGENT_MODEL:-}" ]; then
    DOCKER_RUN_ARGS+=(-e "SUBAGENT_MODEL=$SUBAGENT_MODEL")
fi

if [ -n "${SUBAGENT_FALLBACK_MODELS:-}" ]; then
    DOCKER_RUN_ARGS+=(-e "SUBAGENT_FALLBACK_MODELS=$SUBAGENT_FALLBACK_MODELS")
fi

DOCKER_RUN_ARGS+=(
    -e "GIT_REMOTES=$GIT_REMOTES_ENV"
    -e "REPOS=$REPOS_ENV"
    -e "PRIMARY_REPO=$PRIMARY_REPO"
    -e "BRANCH_NAME=$BRANCH_NAME"
    -e "TASK_NAME=$TASK_NAME"
    -e "TASK_TYPE=$TASK_TYPE"
    -e "NOTIFY_USER=$NOTIFY_USER"
    -e "DESCRIPTION=$DESCRIPTION"
    -e "GH_TOKEN=$GH_TOKEN"
    -e "GIT_AUTHOR_EMAIL=dominiquemb@users.noreply.github.com"
    task-runner-base:latest
    bash
    -c
    "Xvfb :99 -screen 0 1920x1080x24 & fluxbox & sleep 2; tail -f /dev/null"
)

# Start container
log "Starting container: $CONTAINER_NAME"
set_task_status "starting_container" "$CONTAINER_NAME"
if [ "$RUNNING_AS_ROOT" = "true" ]; then
    capture_logged "docker run $CONTAINER_NAME" CONTAINER_ID \
      sudo docker run "${DOCKER_RUN_ARGS[@]}"
else
    capture_logged "docker run $CONTAINER_NAME" CONTAINER_ID \
      docker_cmd run "${DOCKER_RUN_ARGS[@]}"
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

# Copy database detection helper
log "Copying detect-db-engine.sh to container"
set_task_status "copying_db_helper" "/workspace/detect-db-engine.sh"
if [ "$RUNNING_AS_ROOT" = "true" ]; then
    run_logged "docker cp detect-db-engine.sh" sudo docker cp "$CONTAINER_ASSETS_DIR/detect-db-engine.sh" "$CONTAINER_NAME:/workspace/detect-db-engine.sh"
    run_logged "docker exec chmod detect-db-engine.sh" sudo docker exec "$CONTAINER_NAME" chmod +x /workspace/detect-db-engine.sh
else
    run_logged "docker cp detect-db-engine.sh" docker_cmd cp "$CONTAINER_ASSETS_DIR/detect-db-engine.sh" "$CONTAINER_NAME:/workspace/detect-db-engine.sh"
    run_logged "docker exec chmod detect-db-engine.sh" docker_cmd exec "$CONTAINER_NAME" chmod +x /workspace/detect-db-engine.sh
fi

# Copy canonical container-side task runner
log "Copying container-task-run.sh to container"
set_task_status "copying_container_runner" "/workspace/container-task-run.sh"
if [ "$RUNNING_AS_ROOT" = "true" ]; then
    run_logged "docker cp container-task-run.sh" sudo docker cp "$CONTAINER_ASSETS_DIR/container-task-run.sh" "$CONTAINER_NAME:/workspace/container-task-run.sh"
    run_logged "docker exec chmod container-task-run.sh" sudo docker exec "$CONTAINER_NAME" chmod +x /workspace/container-task-run.sh
else
    run_logged "docker cp container-task-run.sh" docker_cmd cp "$CONTAINER_ASSETS_DIR/container-task-run.sh" "$CONTAINER_NAME:/workspace/container-task-run.sh"
    run_logged "docker exec chmod container-task-run.sh" docker_cmd exec "$CONTAINER_NAME" chmod +x /workspace/container-task-run.sh
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
    sudo docker exec "$CONTAINER_NAME" bash /workspace/container-task-run.sh 2>&1 | tee -a "$LOG_FILE"
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
        record_task_memory "failed_task" "task execution exit $TASK_EXIT_CODE"
        log "ERROR: task execution failed with exit $TASK_EXIT_CODE"
        log "Task failed; preserving container for inspection: $CONTAINER_NAME"
        exit "$TASK_EXIT_CODE"
    fi
else
    set +e
    docker_cmd exec "$CONTAINER_NAME" bash /workspace/container-task-run.sh 2>&1 | tee -a "$LOG_FILE"
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
        record_task_memory "failed_task" "task execution exit $TASK_EXIT_CODE"
        log "ERROR: task execution failed with exit $TASK_EXIT_CODE"
        log "Task failed; preserving container for inspection: $CONTAINER_NAME"
        exit "$TASK_EXIT_CODE"
    fi
fi

set_task_status "completed" "success"
record_task_memory "completed" "success"
log "Task completed"
log "Log file: $LOG_FILE"
