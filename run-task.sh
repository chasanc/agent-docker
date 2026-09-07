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

CREDS_FILE="$HOME/.claude/.credentials.json"
if [[ ! -f "$CREDS_FILE" ]]; then
    echo "Missing $CREDS_FILE — run 'claude login' on the host first." >&2
    exit 1
fi

IMAGE_TAG="agent-docker:latest"
DOCKER_CONTEXT="${AGENT_DOCKER_CONTEXT:-default}"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
CLAUDE_ARGS="${AGENT_CLAUDE_ARGS:-}"
AGENT_MODEL="${AGENT_MODEL:-$(grep -E '^AGENT_MODEL=' .env | tail -n1 | cut -d= -f2- || true)}"

AWS_DIR="${AGENT_AWS_DIR:-$HOME/.aws}"
AWS_MOUNT=()
if [[ "${AGENT_MOUNT_AWS:-1}" != "0" && -d "$AWS_DIR" ]]; then
    AWS_MOUNT=(-v "$AWS_DIR:/home/agent/.aws:ro")
fi

DETACH="${AGENT_DETACH:-0}"
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --detach | -d) DETACH=1 ;;
        *) ARGS+=("$arg") ;;
    esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}

PLAN="${1:-}"
if [[ -z "$PLAN" && -z "${AGENT_TASK_PROMPT:-}" ]]; then
    echo "Usage: $0 [--detach|-d] <plan.md>   (or set AGENT_TASK_PROMPT for an inline prompt)" >&2
    exit 1
fi

if [[ -n "$PLAN" ]]; then
    if [[ ! -f "$PLAN" ]]; then
        echo "Plan file not found: $PLAN" >&2
        exit 1
    fi
    ENVFILE="${PLAN%.md}.env"
    if [[ -f "$ENVFILE" ]]; then
        # shellcheck disable=SC1090
        source "$ENVFILE"
        if [[ "${AGENT_DETACH:-0}" != "0" ]]; then
            DETACH=1
        fi
    fi
    PROMPT="$(<"$PLAN")"
    LABEL="$(basename "${PLAN%.md}" | tr -cs '[:alnum:]' '-' | head -c 40)"
    SLUG="manual-$LABEL"
else
    PROMPT="$AGENT_TASK_PROMPT"
    LABEL="prompt"
    SLUG="manual-prompt-$$"
fi

WORKSPACE_DIR="$(workspace_resolve "$SLUG")"
ALLOWED="${AGENT_ALLOWED_TOOLS:-Bash,Read,Glob,Grep,Edit,Write,WebFetch,mcp__jira,mcp__linear}"
NAME="agent-docker-manual-$LABEL-$$"
LOGFILE="$LOG_DIR/$(date +%Y%m%d-%H%M%S)-manual-$LABEL-$$.log"
echo "Logging to $LOGFILE"
echo "Workspace: $WORKSPACE_DIR"

docker --context "$DOCKER_CONTEXT" build -t "$IMAGE_TAG" .

workspace_prune
workspace_reset "$DOCKER_CONTEXT" "$IMAGE_TAG" "$WORKSPACE_DIR"

RUN_ARGS=(
    --name "$NAME"
    --env-file .env
    -v "$CREDS_FILE:/home/agent/.claude/.credentials.json:ro"
    -v "$WORKSPACE_DIR:/workspace"
    "${AWS_MOUNT[@]}"
    "$IMAGE_TAG"
    --mcp-config /home/agent/mcp.json
    --allowedTools "$ALLOWED"
    --model "${AGENT_MODEL:-sonnet}"
)

if [[ "$DETACH" != "0" ]]; then
    # shellcheck disable=SC2086
    CID="$(docker --context "$DOCKER_CONTEXT" run -d \
        "${RUN_ARGS[@]}" \
        $CLAUDE_ARGS \
        -p "$PROMPT")"

    setsid nohup bash -c '
        ctx=$1; name=$2; log=$3
        docker --context "$ctx" logs -f "$name" >>"$log" 2>&1 || true
        code="$(docker --context "$ctx" inspect -f "{{.State.ExitCode}}" "$name" 2>/dev/null || echo "?")"
        printf "\n[run-task] container %s exited with code %s\n" "$name" "$code" >>"$log"
        docker --context "$ctx" rm "$name" >/dev/null 2>&1 || true
    ' _ "$DOCKER_CONTEXT" "$NAME" "$LOGFILE" >/dev/null 2>&1 &
    disown $! 2>/dev/null || true

    echo "Detached: ${CID:0:12} ($NAME)"
    echo "  follow: tail -f $LOGFILE"
    echo "  status: docker --context $DOCKER_CONTEXT ps --filter name=$NAME"
    echo "  stop:   docker --context $DOCKER_CONTEXT stop $NAME"
else
    # shellcheck disable=SC2086
    docker --context "$DOCKER_CONTEXT" run --rm \
        "${RUN_ARGS[@]}" \
        $CLAUDE_ARGS \
        -p "$PROMPT" 2>&1 | tee "$LOGFILE"
fi
