#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/task-run.sh"

PROJECT=""
BATCH_FILE=""
LABEL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project|-p) PROJECT="$2"; shift 2 ;;
        --batch|-b) BATCH_FILE="$2"; shift 2 ;;
        --label|-l) LABEL="$2"; shift 2 ;;
        *) echo "Usage: $0 --project <project> --batch <batch-file> [--label <label>]"; exit 1 ;;
    esac
done

[ -z "$PROJECT" ] && { echo "Missing --project"; exit 1; }
[ -z "$BATCH_FILE" ] && { echo "Missing --batch"; exit 1; }
[ ! -f "$BATCH_FILE" ] && { echo "Batch file not found: $BATCH_FILE"; exit 1; }

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LABEL="${LABEL:-$(basename "$BATCH_FILE" | sed 's/\.[^.]*$//')}"
BATCH_DIR="$HOME/tasks/batches/${LABEL}-${TIMESTAMP}"
mkdir -p "$BATCH_DIR"

MANIFEST_FILE="$BATCH_DIR/manifest.tsv"
PIDS_FILE="$BATCH_DIR/pids.tsv"
SUMMARY_FILE="$BATCH_DIR/summary.txt"

echo "Batch label: $LABEL" | tee "$SUMMARY_FILE"
echo "Project: $PROJECT" | tee -a "$SUMMARY_FILE"
echo "Batch file: $BATCH_FILE" | tee -a "$SUMMARY_FILE"
echo "Batch dir: $BATCH_DIR" | tee -a "$SUMMARY_FILE"
echo -e "task\ttype\tdescription\tscript\tpid\tlauncher_log" > "$MANIFEST_FILE"

while IFS='|' read -r TASK_NAME TASK_TYPE DESCRIPTION SCRIPT_PATH; do
    [[ -z "${TASK_NAME// }" ]] && continue
    [[ "$TASK_NAME" =~ ^# ]] && continue
    TASK_TYPE="${TASK_TYPE:-general}"

    if [ ! -f "$SCRIPT_PATH" ]; then
        echo "Skipping $TASK_NAME: script not found at $SCRIPT_PATH" | tee -a "$SUMMARY_FILE"
        continue
    fi

    LAUNCHER_LOG="$HOME/tasks/logs/${TASK_NAME}.launcher.log"
    CMD=(
        env
        TASK_BATCH_ID="${LABEL}-${TIMESTAMP}"
        TASK_BATCH_DIR="$BATCH_DIR"
        "$RUNNER"
        --project "$PROJECT"
        --task "$TASK_NAME"
        --type "$TASK_TYPE"
        --desc "$DESCRIPTION"
        --script "$SCRIPT_PATH"
    )

    CMD_STRING="$(printf '%q ' "${CMD[@]}")"
    setsid bash -lc "exec ${CMD_STRING}" >"$LAUNCHER_LOG" 2>&1 </dev/null &
    PID=$!

    echo -e "${TASK_NAME}\t${TASK_TYPE}\t${DESCRIPTION}\t${SCRIPT_PATH}\t${PID}\t${LAUNCHER_LOG}" >> "$MANIFEST_FILE"
    echo -e "${PID}\t${TASK_NAME}" >> "$PIDS_FILE"
    echo "Started $TASK_NAME (pid $PID)" | tee -a "$SUMMARY_FILE"
done < "$BATCH_FILE"

echo "Manifest: $MANIFEST_FILE" | tee -a "$SUMMARY_FILE"
echo "PIDs: $PIDS_FILE" | tee -a "$SUMMARY_FILE"
echo "Status dir: $HOME/tasks/status" | tee -a "$SUMMARY_FILE"
