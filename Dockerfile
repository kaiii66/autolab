FROM node:22-slim

# System deps for SkyPilot + kubectl
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash curl git openssh-client socat netcat-openbsd rsync python3 python3-venv ca-certificates \
    && curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
    && install kubectl /usr/local/bin/kubectl && rm kubectl \
    && rm -rf /var/lib/apt/lists/*

# Add github.com to known_hosts (for Weave plugin marketplace clone)
RUN mkdir -p /etc/ssh && ssh-keyscan -t ed25519,rsa github.com >> /etc/ssh/ssh_known_hosts

# Global npm packages (must be root)
RUN npm install -g @anthropic-ai/claude-code weave-claude-plugin

# Create non-root user (Claude Code refuses to run as root)
RUN useradd -m -s /bin/bash autolab
USER autolab

# Git identity for commits made by the agent
RUN git config --global user.email "autolab@autolab.ai" && \
    git config --global user.name "Autolab Agent"
WORKDIR /home/autolab

# uv (Python package manager)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/home/autolab/.local/bin:$PATH"

# SkyPilot with Kubernetes support
RUN uv tool install 'skypilot[kubernetes]'

# Claude Code settings — full permissions, no prompts
RUN mkdir -p /home/autolab/.claude && cat > /home/autolab/.claude/settings.json <<'EOF'
{
  "permissions": {
    "allow": [],
    "deny": [],
    "defaultMode": "acceptEdits"
  },
  "enabledPlugins": {
    "weave@weave-claude-plugin": true
  }
}
EOF

WORKDIR /home/autolab/app
COPY --chown=autolab:autolab . /home/autolab/app

COPY --chown=autolab:autolab entrypoint.sh /home/autolab/entrypoint.sh
RUN chmod +x /home/autolab/entrypoint.sh

ENTRYPOINT ["/home/autolab/entrypoint.sh"]
