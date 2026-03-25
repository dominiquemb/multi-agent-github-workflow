#!/bin/bash
# Clean up task files (not the git branches/PRs)
# Usage: ./task-clean.sh [task-name]

TASKS_DIR=~/tasks
LOGS_DIR=~/tasks/logs

if [ -z "$1" ]; then
    # Clean all completed tasks
    echo "Cleaning up completed task files..."
    for status_file in $TASKS_DIR/*.status; do
        if [ -f "$status_file" ]; then
            task_name=$(basename "$status_file" .status)
            status=$(cat "$status_file" 2>/dev/null || echo "")
            if [ "$status" = "completed" ] || [ "$status" = "failed" ]; then
                rm -f "$status_file" "$TASKS_DIR/${task_name}.sh" "$LOGS_DIR/${task_name}.log"
                echo "  ✓ Cleaned: $task_name"
            fi
        fi
    done
    echo "Done. Git branches and PRs are not affected."
else
    # Clean specific task
    TASK_NAME=$1
    rm -f "$TASKS_DIR/${TASK_NAME}.status" "$TASKS_DIR/${TASK_NAME}.sh" "$LOGS_DIR/${TASK_NAME}.log"
    echo "Cleaned task: $TASK_NAME"
fi
