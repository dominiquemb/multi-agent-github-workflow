#!/bin/bash
# Compatibility wrapper for the canonical container-side sub-agent launcher.

set -e

CANONICAL_SCRIPT="$HOME/docker-dev-container/spawn-subagent.sh"

if [ ! -f "$CANONICAL_SCRIPT" ]; then
    echo "ERROR: Canonical launcher not found at $CANONICAL_SCRIPT"
    exit 1
fi

if command -v openclaw >/dev/null 2>&1; then
    exec "$CANONICAL_SCRIPT" "$@"
fi

echo "This launcher is intended to run inside the task container."
echo "Use ~/task-run.sh to start a containerized task, or copy:"
echo "  $CANONICAL_SCRIPT"
echo "into the container as /workspace/spawn-subagent.sh."
exit 1
