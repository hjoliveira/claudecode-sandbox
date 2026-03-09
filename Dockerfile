# Claude Code Sandbox — Docker-based isolation
#
# Provides filesystem and network isolation for Claude Code CLI
# without requiring root on the host machine.

FROM node:22.14.0-slim

# Install networking tools for domain-based egress filtering, plus Python
RUN apt-get update && apt-get install -y --no-install-recommends \
        iptables \
        dnsutils \
        iproute2 \
        ca-certificates \
        git \
        curl \
        gosu \
        python3 \
        python3-pip \
        python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Install Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code

# Create a non-root user for running Claude Code.
# The entrypoint will handle iptables (which needs NET_ADMIN) before
# dropping to this user.
RUN useradd -m -s /bin/bash sandbox

# Project directory — the host project will be bind-mounted here
RUN mkdir -p /home/sandbox/project && chown sandbox:sandbox /home/sandbox/project

# Claude config directory — only credentials file is bind-mounted from host
RUN mkdir -p /home/sandbox/.claude && chown sandbox:sandbox /home/sandbox/.claude
WORKDIR /home/sandbox/project

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
