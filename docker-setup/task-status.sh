#!/bin/bash
# Check status of all tasks or a specific task

TASKS_DIR=~/tasks
LOGS_DIR=~/tasks/logs

if [ -z "$1" ]; then
    echo "=== All Background Tasks ==="
    echo ""
    for status_file in $TASKS_DIR/*.status; do
        if [ -f "$status_file" ]; then
            task_name=$(basename "$status_file" .status)
            status=$(cat "$status_file" 2>/dev/null || echo "unknown")
            log_file="$LOGS_DIR/${task_name}.log"
            
            # Color code status
            case $status in
                running) color="\033[33m" ;;  # Yellow
                completed) color="\033[32m" ;;  # Green
                failed) color="\033[31m" ;;  # Red
                *) color="\033[0m" ;;  # Default
            esac
            
            echo -e "Task: ${color}${task_name}\033[0m"
            echo "  Status: ${color}${status}\033[0m"
            
            # Extract PR URL if completed
            if [ "$status" = "completed" ]; then
                pr_url=$(grep "🔗 PR:" "$log_file" 2>/dev/null | sed 's/.*🔗 PR: //')
                if [ -n "$pr_url" ]; then
                    echo "  PR: $pr_url"
                fi
            fi
            
            # Last 3 lines of log
            echo "  Last output:"
            tail -3 "$log_file" 2>/dev/null | sed 's/^/    /'
            echo ""
        fi
    done
else
    TASK_NAME=$1
    STATUS_FILE="$TASKS_DIR/${TASK_NAME}.status"
    LOG_FILE="$LOGS_DIR/${TASK_NAME}.log"
    
    if [ ! -f "$STATUS_FILE" ]; then
        echo "Task '$TASK_NAME' not found"
        exit 1
    fi
    
    echo "=== Task: $TASK_NAME ==="
    echo "Status: $(cat $STATUS_FILE 2>/dev/null)"
    echo ""
    echo "=== Full Log ==="
    cat "$LOG_FILE"
fi
