#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SCRIPT_DIR/batch-dispatcher.sh"
LOG_FILE="$HOME/tasks/logs/batch-dispatcher.launcher.log"
PID_FILE="$HOME/tasks/batch-dispatcher.pid"

if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "Dispatcher already running with PID $(cat "$PID_FILE")"
    exit 0
fi

mkdir -p "$HOME/tasks/logs"
setsid bash -lc "exec '$DISPATCHER' --daemon" >> "$LOG_FILE" 2>&1 </dev/null &
sleep 1

if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "Dispatcher started with PID $(cat "$PID_FILE")"
else
    echo "Dispatcher failed to start"
    exit 1
fi
