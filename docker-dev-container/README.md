# Docker Dev Container for Sub-Agent Tasks

Each sub-agent should run in an isolated Docker container to prevent overlap issues.

## Usage

### Start a container for a specific task:

```bash
cd docker-dev-container

# Set environment variables for the specific task
export CONTAINER_NAME=agent-task-1
export REPO_PATH=../../repos/healthtrac360-web
export HOST_PORT=3001
export CONTAINER_PORT=3000

# Build and start container
docker-compose up -d --build

# Enter the container
docker exec -it agent-task-1 bash
```

### Run E2E tests with screenshots:

```bash
# Inside the container
cd /workspace
npm install
npm run test:e2e

# Screenshots will be saved to the local e2e/screenshots/ directory
```

### Stop and clean up:

```bash
docker-compose down
```

## Port Mapping

Use different host ports for parallel containers:
- Container 1: `3001:3000`
- Container 2: `3002:3000`
- Container 3: `3003:3000`
- etc.
