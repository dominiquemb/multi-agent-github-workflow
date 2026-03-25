# Development container for sub-agent tasks
FROM node:20-bookworm

# Install system dependencies
RUN apt-get update && apt-get install -y \
    git \
    curl \
    wget \
    vim \
    htop \
    python3 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Install Playwright for E2E testing
RUN npm install -g playwright
RUN npx playwright install-deps chromium
RUN npx playwright install chromium

# Set working directory
WORKDIR /workspace

# Default command
CMD ["bash"]
