#!/bin/bash

set -euo pipefail

LABEL="${1:-}"
shopt -s nullglob

if [ -z "$LABEL" ]; then
    echo "Usage: $0 <label-fragment>"
    exit 1
fi

found=0
for pids_file in "$HOME"/tasks/batches/*"$LABEL"*"/pids.tsv"; do
    found=1
    while IFS=$'\t' read -r pid task_name; do
        [ -z "${pid:-}" ] && continue
        kill "$pid" 2>/dev/null || true
        if command -v sudo >/dev/null 2>&1; then
            sudo docker ps --format '{{.Names}}' | grep -F "task-${task_name}-" | while read -r container_name; do
                [ -n "$container_name" ] && sudo docker stop "$container_name" >/dev/null 2>&1 || true
            done
        fi
    done < "$pids_file"
    echo "Stopped batch entries from $pids_file"
done

if [ "$found" -eq 0 ]; then
    echo "No batch found matching: $LABEL"
    exit 1
fi
