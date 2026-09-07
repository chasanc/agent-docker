#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    git config --global url."https://x-access-token:${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/"
fi

git config --global user.name "${GIT_USER_NAME:-Claude Agent}"
git config --global user.email "${GIT_USER_EMAIL:-claude-agent@example.invalid}"

exec claude "$@"
