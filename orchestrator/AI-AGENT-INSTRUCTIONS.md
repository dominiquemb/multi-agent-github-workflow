# Task Runner - AI Agent Instructions

## ⚡ CRITICAL: READ THIS FIRST

**You are an AI agent. You CANNOT spawn sub-agents directly.**

**The `spawn-subagent.sh` script invokes OpenClaw CLI, which IS the sub-agent.**

**Your job:** Write task scripts that call `~/spawn-subagent.sh` with a clear task description.

**The sub-agent's job:** Explore, implement, and complete the task.

---

## ✅ CORRECT: Spawn Sub-Agent

```bash
#!/bin/bash
# This script spawns a sub-agent that does the actual work
~/spawn-subagent.sh "Add purple border around manually edited stop times. When a user manually edits a stop time, show a purple square indicator around it."
```

**That's it.** The sub-agent will:
1. Explore the codebase
2. Find the relevant files
3. Implement the solution
4. Exit when complete

---

## ❌ WRONG: Don't Implement Yourself

```bash
#!/bin/bash
# DON'T do this - you're not the implementer
cd $PRIMARY_REPO
sed -i 's/old/new/g' src/file.tsx
```

---

## ❌ WRONG: Don't Explore Yourself

```bash
#!/bin/bash
# DON'T do this - the sub-agent explores
find src -name "*StopTime*"
grep -r "stop.time" src/
```

---

## ❌ WRONG: Don't Write TODOs

```bash
#!/bin/bash
# DON'T do this - no TODOs
# TODO: Find the stop time component
# TODO: Add purple border
echo "Need to implement this"
```

---

## How It Works

```
┌─────────────────────────────────────────────────────────┐
│  YOU (AI Agent)                                        │
│  Write a script that calls spawn-subagent.sh           │
└─────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────┐
│  spawn-subagent.sh                                      │
│  Launches OpenClaw CLI (the sub-agent)                 │
└─────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────┐
│  SUB-AGENT (OpenClaw)                                  │
│  1. Explores codebase                                  │
│  2. Finds relevant files                               │
│  3. Implements solution                                │
│  4. Exits when complete                                │
└─────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────┐
│  task-run.sh                                            │
│  Detects changes, commits, creates PR                  │
└─────────────────────────────────────────────────────────┘
```

---

## Example: Complete Workflow

**Task:** "Add purple border around manually edited stop times"

**Your script** (`~/tasks/scripts/purple-border.sh`):
```bash
#!/bin/bash
~/spawn-subagent.sh "Add purple border around manually edited stop times. When a user manually edits a stop time, show a purple square indicator around it."
```

**Run the task:**
```bash
~/task-run.sh --project healthtrac \
  --task purple-border \
  --desc "Add purple border for manually edited stop times" \
  --script ~/tasks/scripts/purple-border.sh
```

**Result:** Sub-agent implements everything, PR is created automatically.

---

## Key Rules

1. **You write scripts that spawn sub-agents** - You don't implement
2. **Sub-agents explore and implement** - They do the actual work
3. **Be specific in task descriptions** - Include requirements and context
4. **One task per script** - Keep it focused
5. **Don't explore yourself** - The sub-agent explores
6. **Don't implement yourself** - The sub-agent implements

---

## Monitoring Task Progress

**Logs are stored in:** `~/tasks/logs/<task-name>.log`

**To check progress:**
```bash
# View full log
cat ~/tasks/logs/<task-name>.log

# Follow log in real-time
tail -f ~/tasks/logs/<task-name>.log

# Check last 50 lines
tail -50 ~/tasks/logs/<task-name>.log
```

**Example:**
```bash
# After running a task, check logs
cat ~/tasks/logs/stop-time-purple-indicator.log
```

**Log file contains:**
- Task runner startup info
- Container start/stop events
- Git clone progress
- npm install output
- Sub-agent execution logs
- PR creation confirmation

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| "I don't know which files to change" | That's the sub-agent's job - just describe the task |
| "Should I explore first?" | No - the sub-agent explores |
| "Should I write the code?" | No - the sub-agent writes the code |
| "What do I put in the script?" | Just call `~/spawn-subagent.sh "task description"` |

---

**Remember: You orchestrate. Sub-agents implement.**
