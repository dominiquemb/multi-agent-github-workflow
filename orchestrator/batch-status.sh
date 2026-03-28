#!/bin/bash

set -euo pipefail

STATUS_DIR="$HOME/tasks/status"
QUEUE_DIR="$HOME/tasks/queue"
RUN_DIR="$HOME/tasks/queue-running"
DONE_DIR="$HOME/tasks/queue-done"
FAILED_DIR="$HOME/tasks/queue-failed"
PID_FILE="$HOME/tasks/batch-dispatcher.pid"

echo "Dispatcher:"
if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "  running (pid $(cat "$PID_FILE"))"
else
    echo "  not running"
fi

echo
echo "Queue:"
echo "  pending: $(find "$QUEUE_DIR" -maxdepth 1 -type f -name '*.request' 2>/dev/null | wc -l)"
echo "  running: $(find "$RUN_DIR" -maxdepth 1 -type f -name '*.request' 2>/dev/null | wc -l)"
echo "  done: $(find "$DONE_DIR" -maxdepth 1 -type f -name '*.request' 2>/dev/null | wc -l)"
echo "  failed: $(find "$FAILED_DIR" -maxdepth 1 -type f -name '*.request' 2>/dev/null | wc -l)"

echo
echo "Task status:"
for status_file in "$STATUS_DIR"/*.status; do
    [ -f "$status_file" ] || continue
    task=""
    state=""
    detail=""
    while IFS='=' read -r key value; do
        case "$key" in
            task) task="$value" ;;
            state) state="$value" ;;
            detail) detail="$value" ;;
        esac
    done < "$status_file"
    printf '  %s\t%s\t%s\n' "$task" "$state" "$detail"
done | sort
