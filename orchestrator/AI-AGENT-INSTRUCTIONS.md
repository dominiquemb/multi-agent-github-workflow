# Task Runner - AI Agent Instructions

## ⚡ Quick Start

**For AI Agents:**

1. **Write a task script** that spawns a sub-agent
2. **Run the task runner** with that script

```bash
~/task-run.sh --project healthtrac --task <task-name> --desc "<description>" --script ~/tasks/scripts/<script-name>.sh
```

---

## ⚠️ CRITICAL: How Sub-Agent Spawning Works

**Your task script should SPAWN a sub-agent that implements the solution autonomously.**

The sub-agent (OpenClaw) will:
1. Explore the codebase
2. Figure out what files to change
3. Make the changes
4. Exit when complete

### ✅ CORRECT - Spawn sub-agent
```bash
#!/bin/bash
# Spawn autonomous sub-agent to implement the task
~/spawn-subagent.sh "Add purple border around manually edited stop times"
```

### ❌ WRONG - Don't implement directly
```bash
#!/bin/bash
cd $PRIMARY_REPO
sed -i 's/old/new/g' src/file.tsx  # Don't do this yourself
```

### ❌ WRONG - Don't use other AI CLIs
```bash
#!/bin/bash
qwen "Add purple border"  # Not the right tool
claude "Add purple border"  # Not the right tool
```

**Use OpenClaw via `~/spawn-subagent.sh`** - it's designed for autonomous task execution.

---

## How It Actually Works

```
┌─────────────────────────────────────────────────────────┐
│  1. You write task script (spawns sub-agent)           │
│  2. task-run.sh starts Docker container                │
│  3. Your script calls ~/spawn-subagent.sh              │
│  4. OpenClaw sub-agent explores & implements           │
│  5. Sub-agent exits when complete                      │
│  6. Runner detects changes, commits, creates PR        │
│  7. Container is cleaned up                            │
└─────────────────────────────────────────────────────────┘

Your job: Tell the sub-agent WHAT to do.
Sub-agent's job: Figure out HOW to do it.
```

---

## Example: Complete Workflow

**User request:** "Add purple border around manually edited stop times"

**AI Agent creates script** (`~/tasks/scripts/purple-border.sh`):
```bash
#!/bin/bash
# Spawn sub-agent to implement the feature
~/spawn-subagent.sh "Add purple border around manually edited stop times. When a stop time is manually edited, show a purple square indicator around it."
```

**AI Agent runs task:**
```bash
~/task-run.sh --project healthtrac \
  --task purple-border \
  --desc "Add purple border for manually edited stop times" \
  --script ~/tasks/scripts/purple-border.sh
```

**Result:** PR created with the implementation

---

## Key Points For AI Agents

1. **You are the orchestrator** - Write scripts that spawn sub-agents
2. **Sub-agents implement** - OpenClaw does the actual coding work
3. **Be specific in task descriptions** - Include context and requirements
4. **Non-blocking** - spawn-subagent.sh returns immediately
5. **Don't ask the user** - Make reasonable decisions or pass to sub-agent

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Sub-agent makes no changes | Task description too vague - be more specific |
| Sub-agent fails | Check Docker logs: `docker logs $CONTAINER_NAME` |
| Wrong files changed | Add file paths or constraints to task description |
| PR not created | Sub-agent didn't commit - check if it completed successfully |

---

**Remember: You orchestrate. Sub-agents implement.**
