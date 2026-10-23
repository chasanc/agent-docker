#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# shellcheck source=workspace-lib.sh
source "$SCRIPT_DIR/workspace-lib.sh"

if [[ ! -f .env ]]; then
    echo "Missing .env (copy env.sample to .env and fill in GitHub/Jira/Linear tokens)" >&2
    exit 1
fi

CLAUDE_DIR="${AGENT_CLAUDE_CONFIG_DIR:-$(grep -E '^AGENT_CLAUDE_CONFIG_DIR=' .env | tail -n1 | cut -d= -f2- || true)}"
CREDS_FILE="${CLAUDE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}/.credentials.json"
if [[ ! -f "$CREDS_FILE" ]]; then
    echo "Missing $CREDS_FILE — run 'claude login' on the host first (or set AGENT_CLAUDE_CONFIG_DIR)." >&2
    exit 1
fi

IMAGE_TAG="agent-docker:latest"
DOCKER_CONTEXT="${AGENT_DOCKER_CONTEXT:-default}"

TASK_FILE="$SCRIPT_DIR/next-task.md"
QUEUE_DIR="$SCRIPT_DIR/task-queue"
ARCHIVE_DIR="$SCRIPT_DIR/task-archive"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
CLAUDE_ARGS="${AGENT_CLAUDE_ARGS:-}"
AGENT_MODEL="${AGENT_MODEL:-$(grep -E '^AGENT_MODEL=' .env | tail -n1 | cut -d= -f2- || true)}"

AWS_DIR="${AGENT_AWS_DIR:-$HOME/.aws}"
AWS_MOUNT=()
if [[ "${AGENT_MOUNT_AWS:-1}" != "0" && -d "$AWS_DIR" ]]; then
    AWS_MOUNT=(-v "$AWS_DIR:/home/agent/.aws:ro")
fi

run_task() (
    local plan="$1"
    local envfile="${plan%.md}.env"
    if [[ -f "$envfile" ]]; then
        # shellcheck disable=SC1090
        source "$envfile"
    fi
    local workspace
    workspace="$(workspace_resolve "$(basename "${plan%.md}")")"
    workspace_reset "$DOCKER_CONTEXT" "$IMAGE_TAG" "$workspace"
    local allowed="${AGENT_ALLOWED_TOOLS:-Bash,Read,Glob,Grep,Edit,Write,WebFetch,mcp__jira,mcp__linear}"
    local name
    name="agent-docker-$(basename "${plan%.md}" | tr -cs '[:alnum:]' '-' | head -c 40)$$"
    local logfile
    logfile="$LOG_DIR/$(date +%Y%m%d-%H%M%S)-$(basename "${plan%.md}").log"
    echo "Logging to $logfile"
    echo "Workspace: $workspace"

    # shellcheck disable=SC2086
    docker --context "$DOCKER_CONTEXT" run --rm \
        --name "$name" \
        --env-file .env \
        -v "$CREDS_FILE:/home/agent/.claude/.credentials.json:ro" \
        -v "$workspace:/workspace" \
        "${AWS_MOUNT[@]}" \
        "$IMAGE_TAG" \
        --mcp-config /home/agent/mcp.json \
        --allowedTools "$allowed" \
        --model "${AGENT_MODEL:-sonnet}" \
        $CLAUDE_ARGS \
        -p "$(<"$plan")" 2>&1 | tee "$logfile"
)

archive_task() {
    local plan="$1"
    local envfile="${plan%.md}.env"
    mkdir -p "$ARCHIVE_DIR"
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    mv "$plan" "$ARCHIVE_DIR/$stamp-$(basename "$plan")"
    [[ -f "$envfile" ]] && mv "$envfile" "$ARCHIVE_DIR/$stamp-$(basename "$envfile")"
    echo "Archived: $ARCHIVE_DIR/$stamp-$(basename "$plan")"
}

PLANS=()
if [[ -d "$QUEUE_DIR" ]]; then
    while IFS= read -r f; do PLANS+=("$f"); done \
        < <(find "$QUEUE_DIR" -maxdepth 1 -name '*.md' | sort)
fi
[[ -f "$TASK_FILE" ]] && PLANS+=("$TASK_FILE")

if [[ ${#PLANS[@]} -eq 0 ]]; then
    echo "No task armed (no $TASK_FILE and no $QUEUE_DIR/*.md) — nothing to do."
    exit 0
fi

exec 9>"$SCRIPT_DIR/.run.lock"
if ! flock -n 9; then
    echo "Another run is already executing the armed plans — exiting."
    exit 0
fi

docker --context "$DOCKER_CONTEXT" build -t "$IMAGE_TAG" .

workspace_prune

for plan in "${PLANS[@]}"; do
    echo "=== Running task: $(basename "$plan") ==="
    run_task "$plan"
    archive_task "$plan"
done
echo "All armed tasks completed — timer disarmed until a new plan is created."
