# Development container for sub-agent tasks with screen recording
# Uses Node.js 22 for OpenClaw compatibility
FROM node:22-bookworm

# Install system dependencies
RUN apt-get update && apt-get install -y \
    git \
    curl \
    wget \
    vim \
    htop \
    python3 \
    python3-pip \
    # Screen recording dependencies
    ffmpeg \
    xvfb \
    x11vnc \
    fluxbox \
    # Screenshot tools
    scrot \
    imagemagick \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install --break-system-packages --no-cache-dir modal

# Install GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update \
    && apt-get install gh -y \
    && rm -rf /var/lib/apt/lists/*

# Install OpenClaw for autonomous sub-agent spawning
RUN npm install -g openclaw@latest \
    && openclaw plugins install @openclaw/acpx \
    && rm -rf /root/.npm

# Install Playwright for E2E testing
RUN npm install -g playwright || true
RUN npx playwright install-deps chromium
RUN npx playwright install chromium

# Set up display for screen recording
ENV DISPLAY=:99

# Create startup script for X server and window manager
RUN echo '#!/bin/bash\n\
Xvfb :99 -screen 0 1920x1080x24 &\n\
export DISPLAY=:99\n\
fluxbox &\n\
sleep 2\n\
exec "$@"' > /usr/local/bin/docker-entrypoint.sh && \
    chmod +x /usr/local/bin/docker-entrypoint.sh

# Set working directory
WORKDIR /workspace

# Create screenshots directory
RUN mkdir -p /workspace/e2e/screenshots

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["bash"]
