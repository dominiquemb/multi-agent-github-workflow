#!/bin/bash
# Sub-agent Spawner - Spawns OpenClaw autonomous coding agents
# Usage: ~/spawn-subagent.sh "Task description"
# Non-blocking: runs in background, returns immediately

set -e

TASK_DESCRIPTION="$1"
AGENT_ID="${2:-default}"
MAX_TURNS="${3:-25}"

if [ -z "$TASK_DESCRIPTION" ]; then
    echo "Usage: $0 'Task description' [agent-id] [max-turns]"
    exit 1
fi

cd "$PRIMARY_REPO"

echo "========================================"
echo "  SPAWNING SUB-AGENT"
echo "========================================"
echo "Task: $TASK_DESCRIPTION"
echo "Agent ID: $AGENT_ID"
echo "Max Turns: $MAX_TURNS"
echo "Working directory: $(pwd)"
echo "Time: $(date)"
echo "========================================"
echo ""

# Copy identity files to working directory
cp ~/docker-dev-container/SOUL.md ./SOUL.md 2>/dev/null || true
cp ~/docker-dev-container/AGENTS.md ./AGENTS.md 2>/dev/null || true
cp ~/docker-dev-container/USER.md ./USER.md 2>/dev/null || true

# Create mission brief for the sub-agent
MISSION_BRIEF="You are an autonomous coding agent. Your task:

$TASK_DESCRIPTION

Rules:
1. Explore the codebase to understand the structure
2. Identify which files need to be changed
3. Make the necessary changes
4. Do NOT ask questions - make decisions autonomously
5. Do NOT run destructive commands (rm -rf, git push --force, etc.)
6. When complete, exit with code 0

Work in the directory: $(pwd)"

echo "Spawning OpenClaw sub-agent..."

# Non-blocking spawn using background process
# Using --dangerously-skip-permissions for autonomous operation
# Using --max-turns to limit execution time
openclaw --agent "$AGENT_ID" \
    --message "$MISSION_BRIEF" \
    --max-turns "$MAX_TURNS" \
    --dangerously-skip-permissions \
    --output-format json \
    </dev/null &

SPAWN_PID=$!

echo ""
echo "✓ Sub-agent spawned (PID: $SPAWN_PID)"
echo "✓ The sub-agent is running autonomously in the background."
echo "✓ It will explore, implement, and exit when complete."
echo ""
echo "To monitor progress:"
echo "  docker logs -f \$CONTAINER_NAME"
echo ""

# Return immediately (non-blocking)
exit 0
