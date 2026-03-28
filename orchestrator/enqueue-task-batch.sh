#!/bin/bash

set -euo pipefail

QUEUE_DIR="$HOME/tasks/queue"
mkdir -p "$QUEUE_DIR"

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
REQUEST_FILE="$QUEUE_DIR/${TIMESTAMP}-${LABEL}.request"

{
    echo "project=$PROJECT"
    echo "batch_file=$BATCH_FILE"
    echo "label=$LABEL"
    echo "requested_at=$(date -Is)"
} > "$REQUEST_FILE"

echo "$REQUEST_FILE"
