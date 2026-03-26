# Task Runner - AI Agent Instructions

## ⚡ Quick Start (For AI Agents)

**DO NOT EXPORE. DO NOT INVESTIGATE. Just run this command:**

```bash
~/task-run.sh --project healthtrac --task <task-name> --desc "<description>" --script ~/tasks/scripts/<script-name>.sh
```

**That's it. The task runs in a Docker container and creates a PR automatically.**

---

## What The Task Runner Does

1. Starts a Docker container
2. Clones all project repositories (web, api, mobile)
3. Runs your task script
4. Creates a PR if there are changes
5. Cleans up the container

**You don't need to check containers, logs, or PRs. Just wait for completion.**

---

## Creating Task Scripts

**Task scripts should contain CODE, not instructions.**

### ❌ WRONG (Don't do this)
```bash
#!/bin/bash
# TODO: Implement draggable columns
# Steps:
# 1. Install @dnd-kit
# 2. Update the table component
# 3. Test it
```

### ✅ CORRECT (Do this)
```bash
#!/bin/bash
set -e
cd $PRIMARY_REPO

# Install dependencies
npm install @dnd-kit/core @dnd-kit/sortable

# Make code changes
cat > src/components/DraggableTable.tsx << 'EOF'
// Actual implementation code here
import { DndContext } from '@dnd-kit/core';
export function DraggableTable() { return <div>...</div>; }
EOF

# That's it - the runner handles the rest
```

---

## Common Issues & Solutions

### Container Stops Immediately

**Cause:** SSH key or Docker issue

**Fix:**
```bash
# Check if Docker is running
ssh ubuntu@40.160.8.176 "docker ps"

# Check SSH key
ssh ubuntu@40.160.8.176 "ls -la ~/.ssh/github_key"

# Rebuild base image if needed
ssh ubuntu@40.160.8.176 "cd ~/task-runner-base && docker build -t task-runner-base:latest ."
```

### "Unknown Project" Error

**Cause:** Project not configured

**Fix:** Check `~/.task-project-config.sh` exists with:
```bash
healthtrac_repos="healthtrac360-web healthtrac360-api healthtrac360-mobile"
healthtrac_primary="healthtrac360-web"
```

### No PR Created

**Possible causes:**
1. Task script made no changes (check with `git status`)
2. Script failed before making changes (check logs)
3. Git push failed (SSH key issue)

**Debug:**
```bash
# Check task logs
ssh ubuntu@40.160.8.176 "cat ~/tasks/logs/<task-name>.log"

# Check if branch exists
ssh ubuntu@40.160.8.176 "gh pr list --state all | grep <task-name>"
```

---

## For AI Agents: Decision Making

**When the task needs a decision (library choice, implementation approach):**

### Option A: Include decision in task description
```bash
~/task-run.sh --project healthtrac \
  --task add-columns \
  --desc "Add draggable columns USING @dnd-kit library" \
  --script ~/tasks/scripts/add-columns.sh
```

### Option B: Use AI decider (automated)
```bash
# In your task script
LIBRARY=$(~/ai-decider.sh \
  "Which drag-and-drop library for React columns?" \
  "Project uses React 18, Material-UI, needs TypeScript support")

npm install $LIBRARY
```

### Option C: Make the decision yourself
Don't ask the user. Just pick a reasonable default and proceed.

---

## Example: Complete Workflow

```bash
# 1. Create task script
cat > ~/tasks/scripts/draggable-columns.sh << 'EOF'
#!/bin/bash
set -e
cd $PRIMARY_REPO

# Install library (AI agent makes the choice)
npm install @dnd-kit/core @dnd-kit/sortable

# Add implementation
echo "import { DndContext } from '@dnd-kit/core';" >> src/components/Table.tsx

# Script done - runner handles the rest
EOF
chmod +x ~/tasks/scripts/draggable-columns.sh

# 2. Run task
~/task-run.sh --project healthtrac \
  --task draggable-columns \
  --desc "Implement draggable column reordering" \
  --script ~/tasks/scripts/draggable-columns.sh

# 3. Wait for completion (check GitHub for PR)
# DO NOT: Check containers, logs, or status files
# The task either succeeds (PR created) or fails (check logs)
```

---

## Key Points For AI Agents

1. **Don't over-explore** - Just run the command
2. **Scripts contain code** - Not instructions or TODOs
3. **Don't ask the user** - Make reasonable decisions or use `~/ai-decider.sh`
4. **Don't check status** - Wait for completion, then check GitHub for PR
5. **Containers are ephemeral** - They start, run, and clean up automatically
6. **If it fails** - Check `~/tasks/logs/<task-name>.log` and fix the script

---

## Troubleshooting Checklist

- [ ] Task script is executable: `chmod +x script.sh`
- [ ] Script uses `$PRIMARY_REPO` variable (not hardcoded paths)
- [ ] Script has actual code, not just comments
- [ ] SSH key exists: `~/.ssh/github_key`
- [ ] GitHub token exists: `~/.gh_token`
- [ ] Docker is running: `docker ps`
- [ ] Base image exists: `docker images | grep task-runner-base`

---

**Remember: The task runner is simple. Don't overcomplicate it.**
