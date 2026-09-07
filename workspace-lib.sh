#!/usr/bin/env bash

WORKSPACE_MARKER=".agent-workspace"

workspace_root() {
    printf '%s\n' "${AGENT_WORKSPACE_ROOT:-$HOME/agent-docker-workspace}"
}

workspace_resolve() {
    local slug="$1" dir root

    if [[ -n "${AGENT_WORKSPACE:-}" ]]; then
        dir="$AGENT_WORKSPACE"
        mkdir -p "$dir"
        printf '%s\n' "$dir"
        return 0
    fi

    slug="$(printf '%s' "$slug" | tr -cs '[:alnum:]._-' '-' | head -c 40)"
    slug="${slug#"${slug%%[!.]*}"}"
    slug="${slug%"${slug##*[![:punct:]]}"}"
    [[ -n "$slug" ]] || slug="task"
    root="$(workspace_root)"
    dir="$root/$slug"
    mkdir -p "$dir"
    workspace_mark "$dir"
    printf '%s\n' "$dir"
}

workspace_mark() {
    printf '%s\n' \
        "Created by agent-docker. Directories carrying this marker are pruned" \
        "after AGENT_WORKSPACE_RETENTION_DAYS days; delete it to keep this one." \
        >"$1/$WORKSPACE_MARKER"
}

workspace_prune() {
    local days="${AGENT_WORKSPACE_RETENTION_DAYS:-7}"
    local root marker dir

    [[ "$days" =~ ^[0-9]+$ ]] || return 0
    ((days > 0)) || return 0

    root="$(workspace_root)"
    [[ -d "$root" ]] || return 0

    while IFS= read -r marker; do
        dir="$(dirname "$marker")"
        echo "[workspace] pruning $dir (unused for more than ${days}d)"
        rm -rf -- "$dir"
    done < <(find "$root" -mindepth 2 -maxdepth 2 -name "$WORKSPACE_MARKER" \
        -type f -mtime "+$days")
}

workspace_reset() {
    local ctx="$1" image="$2" dir="$3"

    [[ "${AGENT_WORKSPACE_RESET:-0}" != "0" ]] || return 0

    echo "[workspace] AGENT_WORKSPACE_RESET=1 — emptying $dir"
    docker --context "$ctx" run --rm \
        --entrypoint /bin/bash \
        -v "$dir:/workspace" \
        "$image" \
        -c 'shopt -s dotglob nullglob; rm -rf -- /workspace/*'
    [[ -n "${AGENT_WORKSPACE:-}" ]] || workspace_mark "$dir"
}
