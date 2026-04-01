#!/bin/bash

set -euo pipefail

mkdir -p /tmp/.ssh
mkdir -p /workspace/_task_artifacts

REPOS="${REPOS//,/ }"
REQUIRED_REPOS="${REQUIRED_REPOS//,/ }"

cp /root/.ssh/github_key /tmp/.ssh/id_rsa 2>/dev/null || {
  echo "ERROR: SSH key not found"
  exit 1
}
chmod 600 /tmp/.ssh/* 2>/dev/null || true
rm -f /root/.ssh/config 2>/dev/null || true
export GIT_SSH_COMMAND="ssh -i /tmp/.ssh/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

backend_evidence_dir="/workspace/_task_artifacts/backend-evidence"
backend_evidence_file="$backend_evidence_dir/summary.md"
sufficiency_dir="/workspace/_task_artifacts/sufficiency"
sufficiency_output_file="$sufficiency_dir/review.txt"
sufficiency_summary_file="$sufficiency_dir/summary.md"
qa_dir="/workspace/_task_artifacts/qa"
qa_output_file="$qa_dir/review.txt"
qa_summary_file="$qa_dir/summary.md"

changed_files=""
meaningful_changes=""
ui_changes=""
changed_repo_list=""
changed_repos=""
all_repo_changed_files=""
backend_changed_files=""
migration_changed_files=""
sufficiency_followup_note=""
qa_followup_note=""

cleanup_metadata() {
  rm -f SOUL.md USER.md IDENTITY.md TOOLS.md HEARTBEAT.md BOOTSTRAP.md
  rm -f .openclaw/workspace-state.json
  rmdir .openclaw 2>/dev/null || true
}

clone_repos() {
  local old_ifs="$IFS"
  IFS=";"
  for info in $GIT_REMOTES; do
    [ -n "$info" ] || continue
    local repo_name="${info%%=*}"
    local repo_url="${info#*=}"
    git clone "$repo_url" "$repo_name" 2>&1
  done
  IFS="$old_ifs"
}

install_primary_repo() {
  cd "/workspace/$PRIMARY_REPO"
  [ -f package.json ] && npm install 2>/dev/null
}

inject_secret_files() {
  [ -n "${SECRET_FILE_MAPPINGS:-}" ] || return 0

  local old_ifs="$IFS"
  IFS=';'
  for mapping in $SECRET_FILE_MAPPINGS; do
    [ -n "$mapping" ] || continue
    local repo=""
    local dest=""
    local source=""
    IFS='|' read -r repo dest source <<< "$mapping"
    IFS=';'

    [ -n "$repo" ] || continue
    [ -n "$dest" ] || continue
    [ -n "$source" ] || continue

    local repo_dir="/workspace/$repo"
    [ -d "$repo_dir" ] || continue
    [ -e "$source" ] || continue

    local target_path="$repo_dir/$dest"
    if [ -d "$source" ]; then
      mkdir -p "$target_path"
      cp -R "$source"/. "$target_path"/ 2>/dev/null || true
    else
      mkdir -p "$(dirname "$target_path")"
      cp "$source" "$target_path" 2>/dev/null || true
    fi
  done
  IFS="$old_ifs"
}

run_task() {
  artifact_marker="/tmp/task-artifacts-start"
  touch "$artifact_marker"
  set +e
  bash /workspace/task.sh 2>&1
  task_exit=$?
  set -e
  cp /tmp/openclaw-subagent-"${TASK_NAME}"-*.log /workspace/_task_artifacts/ 2>/dev/null || true
  return "$task_exit"
}

collect_visual_artifacts() {
  local visual_artifact_note=""
  for repo in $REPOS; do
    local repo_dir="/workspace/$repo"
    local task_visual_dir="$repo_dir/e2e/screenshots/task-${TASK_NAME}"
    local artifact_mirror_dir="/workspace/_task_artifacts/$repo/task-${TASK_NAME}"
    local artifact_found=0
    [ -d "$repo_dir" ] || continue
    mkdir -p "$task_visual_dir" "$artifact_mirror_dir"
    while IFS= read -r -d '' asset; do
      artifact_found=1
      local base_name
      local prefixed_name
      base_name="$(basename "$asset")"
      prefixed_name="${repo}-${base_name}"
      cp "$asset" "$task_visual_dir/$prefixed_name" 2>/dev/null || true
      cp "$asset" "$artifact_mirror_dir/$prefixed_name" 2>/dev/null || true
    done < <(find "$repo_dir" \
      \( -path "*/node_modules/*" -o -path "*/.git/*" \) -prune -o \
      -newer "$artifact_marker" \
      -type f \( -name "*.png" -o -name "*.jpg" -o -name "*.jpeg" -o -name "*.mp4" -o -name "*.webm" \) \
      \( -path "*/test-results/*" -o -path "*/playwright-report/*" -o -path "*/e2e/screenshots/*" -o -path "*/cypress/screenshots/*" -o -path "*/cypress/videos/*" \) \
      -print0 2>/dev/null)

    if [ "$artifact_found" -eq 1 ]; then
      local summary_file="$task_visual_dir/summary.md"
      {
        echo "# Visual Test Artifacts"
        echo
        echo "Task: $TASK_NAME"
        echo "Repository: $repo"
        echo
        echo "Files:"
        find "$task_visual_dir" -maxdepth 1 -type f ! -name "summary.md" | sed "s|^$task_visual_dir/|- |" | sort
      } > "$summary_file"
      cp "$summary_file" "$artifact_mirror_dir/summary.md" 2>/dev/null || true
      visual_artifact_note="${visual_artifact_note}\n- \`$repo/e2e/screenshots/task-${TASK_NAME}/\`"
    else
      rmdir "$task_visual_dir" 2>/dev/null || true
      rmdir "$artifact_mirror_dir" 2>/dev/null || true
      rmdir "/workspace/_task_artifacts/$repo" 2>/dev/null || true
    fi
  done

  if [ -n "$visual_artifact_note" ]; then
    printf "Visual artifacts committed in:\n%b\n" "$visual_artifact_note" > /workspace/_task_artifacts/visual-artifacts-note.txt
  fi
}

ensure_pr_notification_workflow() {
  local repo_dir="$1"
  local workflow_dir="$repo_dir/.github/workflows"
  local workflow_file="$workflow_dir/task-runner-pr-notification.yml"

  if [ -d "$workflow_dir" ]; then
    if grep -RIlq "This comment was posted automatically to ensure you receive a notification." "$workflow_dir" 2>/dev/null; then
      return 0
    fi
  fi

  mkdir -p "$workflow_dir"
  cat > "$workflow_file" <<EOF
name: PR Notification

on:
  pull_request:
    types: [opened]

jobs:
  notify:
    runs-on: ubuntu-latest
    permissions:
      issues: write
      pull-requests: write

    steps:
      - name: Post notification comment
        uses: actions/github-script@v7
        with:
          github-token: \${{ secrets.GITHUB_TOKEN }}
          script: |
            const notifyUser = '${NOTIFY_USER}';
            const branchName = context.payload.pull_request.head.ref;
            const issue_number = context.issue.number;

            if (!branchName.startsWith('task/')) {
              console.log(\`Skipping PR #\${issue_number} - not a task branch\`);
              return;
            }

            const taskMatch = branchName.match(/task\/(.+?)-\d{8}-\d{6}/);
            const taskName = taskMatch ? taskMatch[1] : 'unknown';

            const body = \`## 🤖 Automated PR Notification

            **Task:** \\\`\${taskName}\\\`

            @\${notifyUser} This PR was automatically created by the background task runner and is ready for your review.

            ---
            *This comment was posted automatically to ensure you receive a notification.*\`;

            await github.rest.issues.createComment({
              owner: context.repo.owner,
              repo: context.repo.repo,
              issue_number: issue_number,
              body: body
            });

            console.log(\`Posted notification comment on PR #\${issue_number}\`);
EOF
}

generate_backend_evidence() {
  mkdir -p "$backend_evidence_dir"
  changed_repos=""
  all_repo_changed_files=""
  backend_changed_files=""
  migration_changed_files=""

  for repo in $REPOS; do
    local repo_dir="/workspace/$repo"
    [ -d "$repo_dir/.git" ] || continue
    local repo_status
    local repo_changed
    local repo_backend_changed
    local repo_migration_changed
    repo_status="$(cd "$repo_dir" && git status --porcelain)"
    repo_changed="$(printf "%s\n" "$repo_status" | awk '{print $2}')"
    if [ -n "$repo_changed" ]; then
      changed_repos="${changed_repos}${repo}\n"
      all_repo_changed_files="${all_repo_changed_files}${repo}:\n$(printf "%s\n" "$repo_changed")\n"
      repo_backend_changed="$(printf "%s\n" "$repo_changed" | grep -E '(^src/|^app/|^api/|^server/|^routes/|^controllers/|^services/|^models/|^db/|^database/|^internal/|^cmd/|migration|migrations|schema|prisma|seed|sql/|\.sql$)' || true)"
      repo_migration_changed="$(printf "%s\n" "$repo_changed" | grep -E '(migration|migrations|schema|prisma|seed|sql/|\.sql$)' || true)"
      [ -n "$repo_backend_changed" ] && backend_changed_files="${backend_changed_files}${repo}:\n${repo_backend_changed}\n"
      [ -n "$repo_migration_changed" ] && migration_changed_files="${migration_changed_files}${repo}:\n${repo_migration_changed}\n"
    fi
  done

  {
    echo "# Backend Evidence"
    echo
    echo "Task type: $TASK_TYPE"
    echo "Required repos: ${REQUIRED_REPOS:-none specified}"
    echo "Required repo status matrix:"
    for repo in ${REQUIRED_REPOS:-}; do
      local repo_status_label="unchanged"
      if printf "%b" "$changed_repos" | grep -Fxq "$repo"; then
        repo_status_label="changed"
      fi
      echo "- $repo: $repo_status_label"
    done
    echo
    echo "Repos with changes:"
    if [ -n "$changed_repos" ]; then
      printf "%b" "$changed_repos" | sed 's/^/- /'
    else
      echo "- none"
    fi
    echo
    echo "All changed files by repo:"
    if [ -n "$all_repo_changed_files" ]; then
      printf "%b" "$all_repo_changed_files"
    else
      echo "none"
    fi
    echo
    echo "Backend-pattern changed files:"
    if [ -n "$backend_changed_files" ]; then
      printf "%b" "$backend_changed_files"
    else
      echo "none"
    fi
    echo
    echo "Migration-pattern changed files:"
    if [ -n "$migration_changed_files" ]; then
      printf "%b" "$migration_changed_files"
    else
      echo "none"
    fi
    if [ -f "$backend_evidence_dir/agent-notes.txt" ]; then
      echo
      echo "Agent notes:"
      cat "$backend_evidence_dir/agent-notes.txt"
    fi
  } > "$backend_evidence_file"
}

compute_change_sets() {
  changed_files=""
  meaningful_changes=""
  ui_changes=""
  changed_repo_list=""

  for repo in $REPOS; do
    local repo_dir="/workspace/$repo"
    [ -d "$repo_dir/.git" ] || continue
    local repo_status
    local repo_changed_files
    local repo_meaningful_changes
    local repo_ui_changes
    repo_status="$(cd "$repo_dir" && git status --porcelain)"
    [ -n "$repo_status" ] || continue
    changed_repo_list="${changed_repo_list}${repo}\n"
    repo_changed_files="$(printf "%s\n" "$repo_status" | awk '{print $2}')"
    changed_files="${changed_files}$(printf "%s\n" "$repo_changed_files" | sed "s|^|${repo}/|")\n"
    repo_meaningful_changes="$(printf "%s\n" "$repo_changed_files" | grep -E '^(src/|app/|components/|pages/|public/|styles/|assets/|lib/|utils/|hooks/|store/|theme/|package\.json$|package-lock\.json$|yarn\.lock$|pnpm-lock\.yaml$|vite\.config|tailwind\.config|tsconfig|playwright\.config|scripts/|tests?/|__tests__/|cypress/|index\.)' || true)"
    repo_ui_changes="$(printf "%s\n" "$repo_changed_files" | grep -E '^(src/components/|components/|pages/|app/|styles/|public/|assets/|theme/|src/.*\.(css|scss|sass|less|jsx|tsx|vue)$|e2e/|cypress/)' || true)"
    [ -n "$repo_meaningful_changes" ] && meaningful_changes="${meaningful_changes}$(printf "%s\n" "$repo_meaningful_changes" | sed "s|^|${repo}/|")\n"
    [ -n "$repo_ui_changes" ] && ui_changes="${ui_changes}$(printf "%b" "$repo_ui_changes" | sed "s|^|${repo}/|")\n"
  done

  changed_files="$(printf "%b" "$changed_files" | sed '/^$/d')"
  meaningful_changes="$(printf "%b" "$meaningful_changes" | sed '/^$/d')"
  ui_changes="$(printf "%b" "$ui_changes" | sed '/^$/d')"
}

run_screenshot_qa() {
  [ "$TASK_TYPE" = "ui" ] || [ "$TASK_TYPE" = "full-stack" ] || return 0
  [ -s /workspace/_task_artifacts/visual-artifacts-note.txt ] || return 0

  mkdir -p "$qa_dir"
  mapfile -t qa_images < <(find /workspace -path "*/e2e/screenshots/task-${TASK_NAME}/*" \
    \( -name "*.png" -o -name "*.jpg" -o -name "*.jpeg" \) -type f | sort)
  [ "${#qa_images[@]}" -gt 0 ] || return 0

  local qa_prompt_file="/tmp/task-qa-prompt.txt"
  {
    echo "You are reviewing screenshot evidence for a completed coding task."
    echo
    echo "Task type: $TASK_TYPE"
    echo "Task name: $TASK_NAME"
    echo "Short description: $DESCRIPTION"
    echo
    echo "Original task launcher script:"
    cat /workspace/task.sh
    echo
    echo "Review instructions:"
    echo "1. Compare the attached screenshots against the task intent."
    echo "2. Focus on whether the requested visible UI outcome appears to be present."
    echo "3. Reply using exactly this format:"
    echo "RESULT: PASS or RESULT: FAIL"
    echo "REASON: one concise sentence"
    echo "DETAILS: one short paragraph"
    echo "4. Return FAIL if the screenshots do not provide convincing evidence that the requested UI outcome was achieved."
  } > "$qa_prompt_file"

  local qa_cmd=(/workspace/run-codex.sh --cd "$(pwd)" --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox --output-last-message "$qa_output_file")
  for qa_img in "${qa_images[@]}"; do
    qa_cmd+=(--image "$qa_img")
  done

  set +e
  "${qa_cmd[@]}" "$(cat "$qa_prompt_file")" >/tmp/task-qa-codex.log 2>&1
  local qa_exit=$?
  set -e
  cp /tmp/task-qa-codex.log "$qa_dir/codex.log" 2>/dev/null || true

  if [ "$qa_exit" -ne 0 ]; then
    qa_followup_note="The screenshot QA reviewer could not complete successfully."
  elif ! grep -Eq '^RESULT:[[:space:]]*PASS' "$qa_output_file"; then
    local remediation_prompt_file="/tmp/task-qa-remediation-prompt.txt"
    {
      echo "A screenshot QA review found that the task may not fully satisfy the requested UI outcome."
      echo
      echo "Task type: $TASK_TYPE"
      echo "Task name: $TASK_NAME"
      echo "Short description: $DESCRIPTION"
      echo
      echo "Original task launcher script:"
      cat /workspace/task.sh
      echo
      echo "QA review findings:"
      cat "$qa_output_file"
      echo
      echo "Instructions:"
      echo "1. Make the smallest relevant code and test changes needed to improve alignment with the task."
      echo "2. Regenerate screenshots if appropriate."
      echo "3. Do not discard valid prior work."
      echo "4. Exit 0 even if you conclude no further code changes are appropriate."
    } > "$remediation_prompt_file"

    local remediation_cmd=(/workspace/run-codex.sh --cd "$(pwd)" --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox)
    for qa_img in "${qa_images[@]}"; do
      remediation_cmd+=(--image "$qa_img")
    done

    set +e
    "${remediation_cmd[@]}" "$(cat "$remediation_prompt_file")" >/tmp/task-qa-remediation-codex.log 2>&1
    local remediation_exit=$?
    set -e
    cp /tmp/task-qa-remediation-codex.log "$qa_dir/remediation.log" 2>/dev/null || true

    if [ "$remediation_exit" -eq 0 ]; then
      mapfile -t qa_images < <(find /workspace -path "*/e2e/screenshots/task-${TASK_NAME}/*" \
        \( -name "*.png" -o -name "*.jpg" -o -name "*.jpeg" \) -type f | sort)
      if [ "${#qa_images[@]}" -gt 0 ]; then
        qa_cmd=(/workspace/run-codex.sh --cd "$(pwd)" --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox --output-last-message "$qa_output_file")
        for qa_img in "${qa_images[@]}"; do
          qa_cmd+=(--image "$qa_img")
        done
        set +e
        "${qa_cmd[@]}" "$(cat "$qa_prompt_file")" >/tmp/task-qa-codex.log 2>&1
        qa_exit=$?
        set -e
        cp /tmp/task-qa-codex.log "$qa_dir/codex.log" 2>/dev/null || true
        if [ "$qa_exit" -eq 0 ]; then
          qa_followup_note="A follow-up remediation pass was attempted after the initial QA review."
        else
          qa_followup_note="A follow-up remediation pass was attempted, but the second QA review could not complete."
        fi
      fi
    else
      qa_followup_note="A follow-up remediation pass was attempted, but Codex exited non-zero."
    fi
  fi

  {
    echo "# Screenshot QA Review"
    echo
    cat "$qa_output_file" 2>/dev/null || true
    if [ -n "$qa_followup_note" ]; then
      echo
      echo "Follow-up:"
      echo "$qa_followup_note"
    fi
    echo
    echo "Screenshots reviewed:"
    for qa_img in "${qa_images[@]}"; do
      echo "- ${qa_img#/workspace/}"
    done
  } > "$qa_summary_file"
}

run_sufficiency_review() {
  mkdir -p "$sufficiency_dir"

  build_sufficiency_prompt() {
    local prompt_file="$1"
    {
      echo "You are reviewing whether a coding task appears sufficiently implemented before PR creation."
      echo
      echo "Task type: $TASK_TYPE"
      echo "Task name: $TASK_NAME"
      echo "Short description: $DESCRIPTION"
      echo "Required repos: ${REQUIRED_REPOS:-none specified}"
      echo
      echo "Original task launcher script:"
      cat /workspace/task.sh
      echo
      echo "Backend evidence summary:"
      cat /workspace/_task_artifacts/backend-evidence/summary.md 2>/dev/null || true
      echo
      echo "Changed files:"
      printf "%s\n" "$changed_files"
      echo
      echo "Review instructions:"
      echo "1. Determine whether the current changes appear sufficient for the requested task."
      echo "2. Explicitly consider whether backend, API, validation, persistence, or migration changes seem necessary."
      echo "3. For each required repo, classify it as one of: CHANGED, OK-UNCHANGED, or MISSING-WORK."
      echo "4. Reply using exactly this format:"
      echo "RESULT: PASS or RESULT: FAIL"
      echo "REASON: one concise sentence"
      echo "DETAILS: one short paragraph"
      echo "REPO-ASSESSMENT:"
      echo "- <repo>: CHANGED | OK-UNCHANGED | MISSING-WORK - <short reason>"
      echo "5. Return FAIL if the task appears incomplete, if likely backend/API changes are missing, or if likely migrations are missing."
    } > "$prompt_file"
  }

  local sufficiency_prompt_file="/tmp/task-sufficiency-prompt.txt"
  build_sufficiency_prompt "$sufficiency_prompt_file"

  set +e
  /workspace/run-codex.sh \
    --cd "$(pwd)" \
    --skip-git-repo-check \
    --dangerously-bypass-approvals-and-sandbox \
    --output-last-message "$sufficiency_output_file" \
    "$(cat "$sufficiency_prompt_file")" >/tmp/task-sufficiency-codex.log 2>&1
  local review_exit=$?
  set -e
  cp /tmp/task-sufficiency-codex.log "$sufficiency_dir/codex.log" 2>/dev/null || true

  if [ "$review_exit" -ne 0 ]; then
    sufficiency_followup_note="The sufficiency reviewer could not complete successfully."
  elif ! grep -Eq '^RESULT:[[:space:]]*PASS' "$sufficiency_output_file"; then
    local remediation_prompt_file="/tmp/task-sufficiency-remediation-prompt.txt"
    {
      echo "A sufficiency review found that the current task may still be incomplete."
      echo
      echo "Task type: $TASK_TYPE"
      echo "Task name: $TASK_NAME"
      echo "Short description: $DESCRIPTION"
      echo "Required repos: ${REQUIRED_REPOS:-none specified}"
      echo
      echo "Original task launcher script:"
      cat /workspace/task.sh
      echo
      echo "Backend evidence summary:"
      cat /workspace/_task_artifacts/backend-evidence/summary.md 2>/dev/null || true
      echo
      echo "Changed files:"
      printf "%s\n" "$changed_files"
      echo
      echo "Review findings:"
      cat "$sufficiency_output_file"
      echo
      echo "Instructions:"
      echo "1. Make the smallest relevant code and test changes needed to address the likely omissions."
      echo "2. Explicitly consider backend, API, validation, persistence, and migrations."
      echo "3. Pay special attention to any required repo that the review classified as MISSING-WORK."
      echo "4. Do not discard valid prior work."
      echo "5. Exit 0 even if you conclude no further changes are appropriate."
    } > "$remediation_prompt_file"

    set +e
    /workspace/run-codex.sh \
      --cd "$(pwd)" \
      --skip-git-repo-check \
      --dangerously-bypass-approvals-and-sandbox \
      "$(cat "$remediation_prompt_file")" >/tmp/task-sufficiency-remediation-codex.log 2>&1
    local remediation_exit=$?
    set -e
    cp /tmp/task-sufficiency-remediation-codex.log "$sufficiency_dir/remediation.log" 2>/dev/null || true

    compute_change_sets
    build_sufficiency_prompt "$sufficiency_prompt_file"

    if [ "$remediation_exit" -eq 0 ]; then
      set +e
      /workspace/run-codex.sh \
        --cd "$(pwd)" \
        --skip-git-repo-check \
        --dangerously-bypass-approvals-and-sandbox \
        --output-last-message "$sufficiency_output_file" \
        "$(cat "$sufficiency_prompt_file")" >/tmp/task-sufficiency-codex.log 2>&1
      review_exit=$?
      set -e
      cp /tmp/task-sufficiency-codex.log "$sufficiency_dir/codex.log" 2>/dev/null || true
      if [ "$review_exit" -eq 0 ]; then
        sufficiency_followup_note="A follow-up remediation pass was attempted after the initial sufficiency review."
      else
        sufficiency_followup_note="A follow-up remediation pass was attempted, but the second sufficiency review could not complete."
      fi
    else
      sufficiency_followup_note="A follow-up remediation pass was attempted, but Codex exited non-zero."
    fi
  fi

  {
    echo "# Sufficiency Review"
    echo
    cat "$sufficiency_output_file" 2>/dev/null || true
    if [ -n "$sufficiency_followup_note" ]; then
      echo
      echo "Follow-up:"
      echo "$sufficiency_followup_note"
    fi
    echo
    echo "Changed files reviewed:"
    printf "%s\n" "$changed_files"
  } > "$sufficiency_summary_file"
}

create_prs_and_comments() {
  git config --global user.email "dominiquemb@users.noreply.github.com"
  git config --global user.name "dominiquemb"

  local multi_repo_prs_file="/workspace/_task_artifacts/multi-repo-prs.txt"
  local push_remediation_max_attempts="${PUSH_REMEDIATION_MAX_ATTEMPTS:-5}"
  : > "$multi_repo_prs_file"
  [ -n "$changed_repo_list" ] || exit 2

  attempt_push_with_remediation() {
    local repo="$1"
    local repo_dir="$2"
    local branch_name="$3"
    local attempt=1
    local remediation_dir="/workspace/_task_artifacts/push-remediation/${repo}"
    mkdir -p "$remediation_dir"

    while [ "$attempt" -le "$push_remediation_max_attempts" ]; do
      local push_output_file="$remediation_dir/push-attempt-${attempt}.log"
      set +e
      git push -u origin "$branch_name" >"$push_output_file" 2>&1
      local push_exit=$?
      set -e

      cat "$push_output_file"

      if [ "$push_exit" -eq 0 ]; then
        return 0
      fi

      if ! grep -qi 'husky - pre-push script failed' "$push_output_file"; then
        return "$push_exit"
      fi

      if [ "$attempt" -ge "$push_remediation_max_attempts" ]; then
        echo "Pre-push hook failed after ${push_remediation_max_attempts} remediation attempts" >&2
        return "$push_exit"
      fi

      local remediation_prompt_file="$remediation_dir/remediation-attempt-${attempt}.txt"
      {
        echo "The implementation is complete, but git push is blocked by the repository pre-push hook."
        echo
        echo "Repository: $repo"
        echo "Task: $TASK_NAME"
        echo "Description: $DESCRIPTION"
        echo "Attempt: $attempt of $push_remediation_max_attempts"
        echo
        echo "Current changed files:"
        git status --short
        echo
        echo "Pre-push output:"
        cat "$push_output_file"
        echo
        echo "Instructions:"
        echo "1. Fix the failing tests or checks reported by the pre-push hook."
        echo "2. Keep changes tightly scoped to the task and the reported failures."
        echo "3. Do not revert valid existing work."
        echo "4. If more than one failing test exists, address all of them before finishing."
        echo "5. Exit 0 when you believe the repo is ready for another push attempt."
      } > "$remediation_prompt_file"

      set +e
      /workspace/run-codex.sh \
        --cd "$repo_dir" \
        --skip-git-repo-check \
        --dangerously-bypass-approvals-and-sandbox \
        "$(cat "$remediation_prompt_file")" >"$remediation_dir/codex-attempt-${attempt}.log" 2>&1
      local remediation_exit=$?
      set -e

      cat "$remediation_dir/codex-attempt-${attempt}.log"

      if [ "$remediation_exit" -ne 0 ]; then
        echo "Codex remediation failed during push remediation attempt $attempt" >&2
        return "$remediation_exit"
      fi

      if [ -z "$(git status --porcelain)" ]; then
        echo "Push remediation attempt $attempt produced no new changes" >&2
        return 1
      fi

      git add -A
      git commit -m "fix: address pre-push failures for $TASK_NAME (attempt $attempt)"
      attempt=$((attempt + 1))
    done

    return 1
  }

  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    local repo_dir="/workspace/$repo"
    cd "$repo_dir"
    ensure_pr_notification_workflow "$repo_dir"
    git checkout -b "$BRANCH_NAME"
    git add -A
    git commit -m "feat: $DESCRIPTION"
    attempt_push_with_remediation "$repo" "$repo_dir" "$BRANCH_NAME"
    local pr_body="Task: $TASK_NAME

Repository: $repo"
    if [ -s /workspace/_task_artifacts/visual-artifacts-note.txt ] && [ "$repo" = "$PRIMARY_REPO" ]; then
      pr_body="$pr_body

$(cat /workspace/_task_artifacts/visual-artifacts-note.txt)"
    fi
    if [ -s /workspace/_task_artifacts/backend-evidence/summary.md ]; then
      pr_body="$pr_body

Backend evidence summary attached in follow-up PR comment."
    fi
    local pr_ref
    pr_ref="$(gh pr create --title "feat: $DESCRIPTION" --body "$pr_body" --base main --head "$BRANCH_NAME" --assignee "$NOTIFY_USER" 2>&1)"
    printf "%s\t%s\n" "$repo" "$pr_ref" >> "$multi_repo_prs_file"
    echo "PR created for $repo: $pr_ref"
  done < <(printf "%b" "$changed_repo_list")

  while IFS=$'\t' read -r repo pr_ref; do
    [ -n "$repo" ] || continue
    local repo_dir="/workspace/$repo"
    cd "$repo_dir"
    local repo_slug
    local commit_sha
    local gallery_comment_file
    repo_slug="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
    commit_sha="$(git rev-parse HEAD 2>/dev/null || true)"
    gallery_comment_file="/tmp/pr-comment-${repo}.md"
    {
      echo "@$NOTIFY_USER Ready for review!"
      echo
      echo "## Related PRs"
      while IFS=$'\t' read -r linked_repo linked_pr; do
        [ -n "$linked_repo" ] || continue
        echo "- $linked_repo: $linked_pr"
      done < "$multi_repo_prs_file"
      if [ -s /workspace/_task_artifacts/sufficiency/summary.md ]; then
        echo
        echo "## Sufficiency Review"
        sed '1d' /workspace/_task_artifacts/sufficiency/summary.md
      fi
      if [ -s /workspace/_task_artifacts/backend-evidence/summary.md ]; then
        echo
        echo "## Backend Evidence"
        sed '1d' /workspace/_task_artifacts/backend-evidence/summary.md
      fi
      if [ -s /workspace/_task_artifacts/qa/summary.md ] && [ "$repo" = "$PRIMARY_REPO" ]; then
        echo
        echo "## Screenshot QA"
        sed '1d' /workspace/_task_artifacts/qa/summary.md
      fi
      if [ -n "$repo_slug" ] && [ -n "$commit_sha" ] && [ "$repo" = "$PRIMARY_REPO" ] && [ -d "e2e/screenshots/task-${TASK_NAME}" ]; then
        echo
        echo "## Visual artifacts"
        for img in e2e/screenshots/task-${TASK_NAME}/*.png e2e/screenshots/task-${TASK_NAME}/*.jpg e2e/screenshots/task-${TASK_NAME}/*.jpeg; do
          [ -f "$img" ] || continue
          local blob_url="https://github.com/$repo_slug/blob/$commit_sha/$img?raw=1"
          echo
          echo "- [${img##*/}]($blob_url)"
        done
        local video_printed=0
        for vid in e2e/screenshots/task-${TASK_NAME}/*.webm e2e/screenshots/task-${TASK_NAME}/*.mp4; do
          [ -f "$vid" ] || continue
          if [ "$video_printed" -eq 0 ]; then
            echo
            echo "## Videos"
            video_printed=1
          fi
          local blob_url="https://github.com/$repo_slug/blob/$commit_sha/$vid?raw=1"
          echo "- [$vid]($blob_url)"
        done
      fi
    } > "$gallery_comment_file"
    gh pr comment "$pr_ref" --body-file "$gallery_comment_file" 2>/dev/null || gh pr comment "$pr_ref" --body "@$NOTIFY_USER Ready for review!" 2>/dev/null || true
  done < "$multi_repo_prs_file"
}

echo "=== Task Execution Started ==="
clone_repos
inject_secret_files
install_primary_repo

if ! run_task; then
  collect_visual_artifacts
  exit $?
fi

collect_visual_artifacts
generate_backend_evidence
run_screenshot_qa
cleanup_metadata
compute_change_sets

if [ -n "$changed_files" ] && [ -z "$meaningful_changes" ]; then
  echo "ERROR: metadata-only or non-application changes detected; refusing to commit"
  printf "%s\n" "$changed_files"
  exit 1
fi

if [ -z "$meaningful_changes" ]; then
  echo "ERROR: sub-agent completed without meaningful application changes"
  exit 2
fi

if [ -n "$ui_changes" ] && [ ! -s /workspace/_task_artifacts/visual-artifacts-note.txt ]; then
  echo "ERROR: UI-affecting changes detected but no screenshots or videos were captured"
  printf "%s\n" "$ui_changes"
  exit 3
fi

run_sufficiency_review
compute_change_sets
create_prs_and_comments
