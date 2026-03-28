#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUEUE_DIR="$HOME/tasks/queue"
RUN_DIR="$HOME/tasks/queue-running"
DONE_DIR="$HOME/tasks/queue-done"
FAILED_DIR="$HOME/tasks/queue-failed"
DISPATCHER_LOG="$HOME/tasks/logs/batch-dispatcher.log"
RUNNER="$SCRIPT_DIR/run-task-batch.sh"
PID_FILE="$HOME/tasks/batch-dispatcher.pid"
LOCK_DIR="$HOME/tasks/.batch-dispatcher.lock"

mkdir -p "$QUEUE_DIR" "$RUN_DIR" "$DONE_DIR" "$FAILED_DIR" "$(dirname "$DISPATCHER_LOG")"

log() {
    echo "[$(date -Is)] $*" | tee -a "$DISPATCHER_LOG"
}

cleanup() {
    rm -f "$PID_FILE"
    rmdir "$LOCK_DIR" 2>/dev/null || true
}

trap cleanup EXIT

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "Dispatcher already running"
    exit 1
fi

echo "$$" > "$PID_FILE"

process_one() {
    local request_file
    request_file="$(find "$QUEUE_DIR" -maxdepth 1 -type f -name '*.request' | sort | head -n 1)"
    [ -z "$request_file" ] && return 1

    local base request_running request_done request_failed
    base="$(basename "$request_file")"
    request_running="$RUN_DIR/$base"
    request_done="$DONE_DIR/$base"
    request_failed="$FAILED_DIR/$base"
    mv "$request_file" "$request_running"

    local project batch_file label
    # shellcheck disable=SC1090
    source "$request_running"

    log "Dispatching batch: label=$label project=$project batch_file=$batch_file"
    if "$RUNNER" --project "$project" --batch "$batch_file" --label "$label" >> "$DISPATCHER_LOG" 2>&1; then
        mv "$request_running" "$request_done"
        log "Batch dispatched successfully: $label"
    else
        mv "$request_running" "$request_failed"
        log "Batch dispatch failed: $label"
    fi

    return 0
}

MODE="${1:---daemon}"

case "$MODE" in
    --once)
        process_one || true
        ;;
    --daemon)
        log "Dispatcher started"
        while true; do
            process_one || sleep 5
        done
        ;;
    *)
        echo "Usage: $0 [--once|--daemon]"
        exit 1
        ;;
esac
