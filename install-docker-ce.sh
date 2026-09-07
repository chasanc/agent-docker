#!/usr/bin/env bash
set -euo pipefail

WITH_TIMER=0
case "${1:-}" in
    --with-timer) WITH_TIMER=1 ;;
    "") ;;
    *) echo "Usage: sudo $0 [--with-timer]" >&2; exit 1 ;;
esac

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo $0 ${1:-}" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"
KEYRING_DIR="${KEYRING_DIR:-/etc/apt/keyrings}"
APT_SOURCES_DIR="${APT_SOURCES_DIR:-/etc/apt/sources.list.d}"

TARGET_USER="${AGENT_USER:-${SUDO_USER:-}}"
if [[ -z "$TARGET_USER" ]]; then
    echo "Cannot tell which user to add to the docker group — set AGENT_USER." >&2
    exit 1
fi
if ! id -u "$TARGET_USER" >/dev/null 2>&1; then
    echo "User '$TARGET_USER' does not exist." >&2
    exit 1
fi

# shellcheck disable=SC1091
[[ -r /etc/os-release ]] && . /etc/os-release
DISTRO="${DOCKER_APT_DISTRO:-}"
if [[ -z "$DISTRO" ]]; then
    case " ${ID:-} ${ID_LIKE:-} " in
        *" ubuntu "*) DISTRO=ubuntu ;;
        *" debian "*) DISTRO=debian ;;
        *) echo "Unsupported distro (ID=${ID:-?}, ID_LIKE=${ID_LIKE:-?}) — set DOCKER_APT_DISTRO=ubuntu|debian." >&2
           exit 1 ;;
    esac
fi
CANDIDATES=()
add_candidate() {
    local c="$1"
    [[ -n "$c" ]] || return 0
    local seen
    for seen in ${CANDIDATES[@]+"${CANDIDATES[@]}"}; do
        [[ "$seen" == "$c" ]] && return 0
    done
    CANDIDATES+=("$c")
}

[[ "$DISTRO" == ubuntu ]] && add_candidate "${UBUNTU_CODENAME:-}"
add_candidate "${VERSION_CODENAME:-}"
if [[ "$DISTRO" == debian && -r /etc/debian_version ]]; then
    DEBIAN_VERSION="$(tr -d '[:space:]' < /etc/debian_version)"
    case "$DEBIAN_VERSION" in
        10*|*buster*)   add_candidate buster ;;
        11*|*bullseye*) add_candidate bullseye ;;
        12*|*bookworm*) add_candidate bookworm ;;
        13*|*trixie*)   add_candidate trixie ;;
        14*|*forky*)    add_candidate forky ;;
    esac
fi

published() {
    curl -fsI --max-time 15 "https://download.docker.com/linux/$DISTRO/dists/$1/Release" >/dev/null 2>&1
}

if [[ -n "${DOCKER_APT_CODENAME:-}" ]]; then
    CODENAME="$DOCKER_APT_CODENAME"
elif [[ ${#CANDIDATES[@]} -eq 0 ]]; then
    echo "Cannot determine the release codename — set DOCKER_APT_CODENAME." >&2
    exit 1
elif ! curl -fsI --max-time 15 "https://download.docker.com/linux/$DISTRO/dists/" >/dev/null 2>&1; then
    CODENAME="${CANDIDATES[0]}"
    echo "Warning: cannot reach download.docker.com to verify the codename;" >&2
    echo "assuming '$CODENAME'. Override with DOCKER_APT_CODENAME if apt fails." >&2
else
    CODENAME=""
    for candidate in "${CANDIDATES[@]}"; do
        if published "$candidate"; then
            CODENAME="$candidate"
            break
        fi
        echo "Docker publishes no '$DISTRO/$candidate' repo — trying the next candidate."
    done
    if [[ -z "$CODENAME" ]]; then
        echo "None of these has a Docker $DISTRO repo: ${CANDIDATES[*]}." >&2
        echo "Pick the upstream release yours is based on and re-run with" >&2
        echo "DOCKER_APT_CODENAME=<codename> (see download.docker.com/linux/$DISTRO/dists/)." >&2
        exit 1
    fi
fi
echo "Using Docker's $DISTRO apt repo for '$CODENAME'."

install -m 0755 -d "$KEYRING_DIR"
curl -fsSL "https://download.docker.com/linux/$DISTRO/gpg" -o "$KEYRING_DIR/docker.asc"
chmod a+r "$KEYRING_DIR/docker.asc"
echo "deb [arch=$(dpkg --print-architecture) signed-by=$KEYRING_DIR/docker.asc] https://download.docker.com/linux/$DISTRO $CODENAME stable" \
    > "$APT_SOURCES_DIR/docker.list"

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable --now docker

usermod -aG docker "$TARGET_USER"

docker --context default run --rm hello-world

render_unit() {
    sed -e "s|REPLACE_WITH_YOUR_USER|$TARGET_USER|" \
        -e "s|/absolute/path/to/agent-docker|$SCRIPT_DIR|" \
        "$SCRIPT_DIR/systemd/agent-docker.service"
}

echo
if [[ $WITH_TIMER -eq 1 ]]; then
    render_unit > "$UNIT_DIR/agent-docker.service"
    install -m 0644 "$SCRIPT_DIR/systemd/agent-docker.timer" "$UNIT_DIR/agent-docker.timer"
    systemctl daemon-reload
    systemctl enable --now agent-docker.timer
    echo "docker-ce and the nightly timer are installed."
    echo "  Unit:  $UNIT_DIR/agent-docker.service (User=$TARGET_USER, WorkingDirectory=$SCRIPT_DIR)"
    systemctl list-timers agent-docker.timer --no-pager || true
    echo
    echo "Remaining step: re-login (or: newgrp docker) so your shell can use"
    echo "docker without sudo."
else
    echo "docker-ce is installed and running. Next steps:"
    echo "  1. Re-login (or: newgrp docker) so your shell can use it without sudo."
    echo "  2. Install the nightly timer — either re-run this script with"
    echo "     --with-timer, or do it by hand (paths already filled in):"
    echo "       sudo sed -e 's|REPLACE_WITH_YOUR_USER|$TARGET_USER|' \\"
    echo "                -e 's|/absolute/path/to/agent-docker|$SCRIPT_DIR|' \\"
    echo "                $SCRIPT_DIR/systemd/agent-docker.service \\"
    echo "                > $UNIT_DIR/agent-docker.service"
    echo "       sudo cp $SCRIPT_DIR/systemd/agent-docker.timer $UNIT_DIR/"
    echo "       sudo systemctl daemon-reload"
    echo "       sudo systemctl enable --now agent-docker.timer"
    echo "  3. Verify: systemctl list-timers agent-docker.timer"
fi
