#!/bin/bash
# Sub-agent Spawner - Spawns OpenClaw autonomous coding agents
# Usage: ~/spawn-subagent.sh "Task description" [agent-id] [max-turns] [model] [fallback-models]
# Non-blocking: runs in background, returns immediately

set -e

TASK_DESCRIPTION="$1"
AGENT_ID="${2:-task}"
MAX_TURNS="${3:-25}"
MODEL="${4:-${SUBAGENT_MODEL:-}}"
FALLBACK_MODELS="${5:-${SUBAGENT_FALLBACK_MODELS:-}}"
OPENCLAW_VLLM_BASE_URL="${OPENCLAW_VLLM_BASE_URL:-}"
OPENCLAW_VLLM_MODEL_ID="${OPENCLAW_VLLM_MODEL_ID:-qwen32b}"
OPENCLAW_VLLM_API_KEY="${OPENCLAW_VLLM_API_KEY:-${VLLM_API_KEY:-modal-local-test}}"
SUBAGENT_FOREGROUND="${SUBAGENT_FOREGROUND:-0}"
TASK_TYPE="${TASK_TYPE:-general}"

if [ -z "$TASK_DESCRIPTION" ]; then
    echo "Usage: $0 'Task description' [agent-id] [max-turns] [model] [fallback-models]"
    exit 1
fi

if [ -n "${PRIMARY_REPO:-}" ] && [ -d "$PRIMARY_REPO" ]; then
    cd "$PRIMARY_REPO"
fi

echo "========================================"
echo "  SPAWNING SUB-AGENT"
echo "========================================"
echo "Task: $TASK_DESCRIPTION"
echo "Agent ID: $AGENT_ID"
echo "Max Turns: $MAX_TURNS"
echo "Model: ${MODEL:-default}"
echo "Fallback Models: ${FALLBACK_MODELS:-none}"
echo "Task Type: $TASK_TYPE"
echo "Working directory: $(pwd)"
echo "Time: $(date)"
echo "========================================"
echo ""

TASK_TYPE_RULES=""
case "$TASK_TYPE" in
    ui)
        TASK_TYPE_RULES="
Task-type requirements for UI tasks:
- Inspect the primary frontend path first, but still check any API calls or shared data dependencies touched by the change.
- UI-affecting changes must be verified with a screenshot-producing path.
- Prefer Playwright or Cypress coverage when available."
        ;;
    api)
        TASK_TYPE_RULES="
Task-type requirements for API tasks:
- Inspect all repositories in the project family, not just the primary repo, before deciding scope.
- If the symptom appears in the UI, still verify whether the real fix belongs in backend routes, controllers, serializers, validators, services, or queries.
- If backend behavior depends on local data, restore the relevant database dump or seed data and run migrations before verification.
- If you modify backend or API behavior, run backend tests if present and verify the affected path with a concrete request, integration flow, or end-to-end path.
- Do not stop at UI-only changes if the issue implies a broken API contract or backend behavior."
        ;;
    full-stack)
        TASK_TYPE_RULES="
Task-type requirements for full-stack tasks:
- Inspect all repositories in the project family before deciding which layers must change.
- Treat frontend, backend, API, and persistence as potentially in scope.
- If backend or database state is required, restore the relevant dump or seed data and run migrations before verification.
- Verify both sides of the change: application behavior in the UI and the underlying API/backend behavior.
- Do not mark the task complete if only one layer was updated when the bug spans multiple layers."
        ;;
    *)
        TASK_TYPE_RULES="
Task-type requirements for general tasks:
- Check neighboring repos when the issue may cross repo boundaries.
- If the task implies API or database behavior, verify those paths before declaring success."
        ;;
esac

MISSION_BRIEF="You are an autonomous coding agent. Your task:

$TASK_DESCRIPTION

Task type: $TASK_TYPE

$TASK_TYPE_RULES

Rules:
1. Explore the codebase to understand the structure
2. Identify which files need to be changed
3. Make the necessary changes
4. Do NOT ask questions - make decisions autonomously
5. Do NOT run destructive commands (rm -rf, git push --force, etc.)
6. Do NOT create or modify bootstrap, identity, workspace-state, or metadata files unless the task explicitly requires that
7. Only modify application files that are directly relevant to the task
8. If you did not change any relevant app code, treat the task as incomplete and exit non-zero
9. If information is missing or ambiguous, make the most reasonable assumption and continue without requesting user input
10. If multiple plausible implementations exist, choose the least invasive option that satisfies the task
11. If partially blocked, take the best available path and continue rather than stopping for clarification
12. If you make UI-affecting changes, you must run a relevant screenshot-producing verification path before finishing
13. For UI work, prefer Playwright or Cypress end-to-end coverage over only unit tests when that path exists
14. If UI changes were made and no screenshots or videos were generated, treat the task as incomplete and exit non-zero
15. If the repository includes a database dump, seed file, or snapshot needed for local app or API behavior, install or start the required database service, restore the dump, and run the relevant migrations before verification
16. If the task affects API, backend, or persistence behavior, you must verify that path explicitly; if you could not verify it, treat the task as incomplete and exit non-zero
17. When complete, exit with code 0

Work in the directory: $(pwd)"

echo "Spawning OpenClaw sub-agent..."

configure_modal_vllm_provider() {
    if [ -z "$OPENCLAW_VLLM_BASE_URL" ]; then
        return 0
    fi

    export VLLM_API_KEY="$OPENCLAW_VLLM_API_KEY"
    export OPENCLAW_STATE_DIR="/tmp/openclaw-state-${AGENT_ID}"
    export OPENCLAW_CONFIG_PATH="$OPENCLAW_STATE_DIR/openclaw.json"
    mkdir -p "$OPENCLAW_STATE_DIR"

    openclaw setup --non-interactive --workspace "$(pwd)" >/dev/null 2>&1 || true
    openclaw config set models.mode merge >/dev/null

    provider_json=$(printf '{"baseUrl":"%s","api":"openai-completions","apiKey":"VLLM_API_KEY","models":[{"id":"%s","name":"%s","reasoning":false,"input":["text"],"cost":{"input":0,"output":0},"contextWindow":128000,"maxTokens":8192}]}' \
        "$OPENCLAW_VLLM_BASE_URL" \
        "$OPENCLAW_VLLM_MODEL_ID" \
        "$OPENCLAW_VLLM_MODEL_ID")
    openclaw config set models.providers.vllm "$provider_json" --strict-json >/dev/null
    openclaw config set agents.defaults.model.primary "vllm/$OPENCLAW_VLLM_MODEL_ID" >/dev/null
}

ensure_agent_workspace() {
    local selected_model="$1"

    if openclaw agents list 2>/dev/null | grep -Fq -- "- $AGENT_ID"; then
        return 0
    fi

    agent_cmd=(
        openclaw agents add "$AGENT_ID"
        --workspace "$(pwd)"
        --non-interactive
    )

    if [ -n "$selected_model" ]; then
        agent_cmd+=(--model "$selected_model")
    fi

    "${agent_cmd[@]}" >/dev/null
}

run_subagent() {
    local log_file="${1:-/tmp/openclaw-subagent-${AGENT_ID}-$(date +%s).log}"

    set +e

    IFS=',' read -r -a fallback_array <<< "$FALLBACK_MODELS"
    models_to_try=()

    if [ -n "$MODEL" ]; then
        models_to_try+=("$MODEL")
    fi

    for fallback_model in "${fallback_array[@]}"; do
        fallback_model="$(echo "$fallback_model" | xargs)"
        if [ -n "$fallback_model" ]; then
            models_to_try+=("$fallback_model")
        fi
    done

    if [ "${#models_to_try[@]}" -eq 0 ]; then
        models_to_try+=("")
    fi

    for selected_model in "${models_to_try[@]}"; do
        echo "[$(date -Is)] Starting sub-agent with model: ${selected_model:-default}" >> "$log_file"

        if [ "$selected_model" = "codex" ] || [[ "$selected_model" == codex/* ]]; then
            codex_cmd=(
                codex exec
                --cd "$(pwd)"
                --skip-git-repo-check
                --json
                --dangerously-bypass-approvals-and-sandbox
            )

            if [ "$selected_model" != "codex" ]; then
                codex_cmd+=(--model "${selected_model#codex/}")
            fi

            "${codex_cmd[@]}" "$MISSION_BRIEF" >> "$log_file" 2>&1 </dev/null
            exit_code=$?

            if [ "$exit_code" -eq 0 ]; then
                echo "[$(date -Is)] Codex sub-agent completed with model: ${selected_model}" >> "$log_file"
                return 0
            fi

            echo "[$(date -Is)] Codex sub-agent failed with model: ${selected_model}" >> "$log_file"
            return "$exit_code"
        fi

        configure_modal_vllm_provider >> "$log_file" 2>&1 || return $?
        ensure_agent_workspace "$selected_model" >> "$log_file" 2>&1 || return $?

        cmd=(
            openclaw
            agent
            --local
            --agent "$AGENT_ID"
            --message "$MISSION_BRIEF"
            --json
            --timeout 3600
        )

        "${cmd[@]}" >> "$log_file" 2>&1 </dev/null
        exit_code=$?

        if [ "$exit_code" -eq 0 ]; then
            echo "[$(date -Is)] Sub-agent completed with model: ${selected_model:-default}" >> "$log_file"
            return 0
        fi

        if ! rg -qi '402|429|quota|credit|credits|rate limit|usage limit|insufficient|billing|depleted' "$log_file"; then
            echo "[$(date -Is)] Sub-agent failed with non-quota error on model: ${selected_model:-default}" >> "$log_file"
            return "$exit_code"
        fi

        echo "[$(date -Is)] Quota/rate-limit detected for model: ${selected_model:-default}" >> "$log_file"
    done

    echo "[$(date -Is)] Exhausted all configured models" >> "$log_file"
    return 1
}

spawn_runner() {
    local log_file
    log_file="/tmp/openclaw-subagent-${AGENT_ID}-$(date +%s).log"

    if [ "$SUBAGENT_FOREGROUND" = "1" ]; then
        run_subagent "$log_file"
        return $?
    fi

    (
        run_subagent "$log_file"
    ) &

    SPAWN_PID=$!
    SPAWN_LOG="$log_file"
}

if [ "$SUBAGENT_FOREGROUND" = "1" ]; then
    SPAWN_LOG="/tmp/openclaw-subagent-${AGENT_ID}-$(date +%s).log"
    run_subagent "$SPAWN_LOG"
    exit_code=$?
    echo ""
    echo "✓ Sub-agent finished."
    echo "✓ Log file: $SPAWN_LOG"
    echo ""
    exit "$exit_code"
fi

spawn_runner

echo ""
echo "✓ Sub-agent spawned (PID: $SPAWN_PID)"
echo "✓ The sub-agent is running autonomously in the background."
echo "✓ It will explore, implement, and exit when complete."
echo "✓ Log file: $SPAWN_LOG"
echo ""
echo "To monitor progress:"
echo "  docker logs -f \$CONTAINER_NAME"
echo ""

# Return immediately (non-blocking)
exit 0
