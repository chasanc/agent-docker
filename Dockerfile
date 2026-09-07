FROM node:22-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        ca-certificates \
        curl \
        gnupg \
        ripgrep \
        jq \
        unzip \
        python3 \
        pipx \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code @tacticlaunch/mcp-linear

# AWS CLI v2 (official installer — no apt package exists for v2). The runners
# mount the host's ~/.aws read-only, so no credentials are baked into the image.
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/awscliv2.zip /tmp/aws \
    && aws --version

# Non-root user so files written into the mounted workspace keep your host UID/GID.
ARG UID=1000
ARG GID=1000
# The base image ships a "node" user already at uid/gid 1000; drop it so we
# can create "agent" at the same ids without a collision.
RUN userdel -r node 2>/dev/null; \
    groupdel node 2>/dev/null; \
    groupadd -g "${GID}" agent \
    && useradd -m -u "${UID}" -g "${GID}" -s /bin/bash agent

USER agent
WORKDIR /workspace
RUN mkdir -p /home/agent/.claude

# mcp-atlassian (Jira via API token) — installed for the agent user via pipx.
ENV PATH="/home/agent/.local/bin:${PATH}"
RUN pipx install mcp-atlassian

COPY --chown=agent:agent mcp.json /home/agent/mcp.json
COPY --chown=agent:agent entrypoint.sh /home/agent/entrypoint.sh
RUN chmod +x /home/agent/entrypoint.sh

ENTRYPOINT ["/home/agent/entrypoint.sh"]
