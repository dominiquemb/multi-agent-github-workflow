# Sub-Agent Workflow

## Process for Tasks with UI Changes

1. **Sub-agent** works on the task inside an isolated Docker container
2. **Sub-agent** runs Playwright E2E tests → screenshots saved locally to `e2e/screenshots/`
3. **Assistant** reviews the code for:
   - Correctness
   - Security
   - Code quality
   - Performance
4. **User** reviews the screenshots for visual/UI verification

## Remote Server Setup (40.160.8.176)

### Repositories (`~/repos/`)

**HealthTrac360:**
- `healthtrac360-web`
- `healthtrac360-api`
- `healthtrac360-mobile`

**Neptune:**
- `neptune` (frontend)
- `neptune-api`
- `neptune-mobile`

**Pythia:**
- `pythia-frontend`
- `pythia-api`

### Docker Dev Containers (`~/docker-dev-container/`)

- Isolated containers for each sub-agent
- Node.js v20, Playwright, Chromium installed
- Screenshots map to local `e2e/screenshots/` directory

### Starting a Container

```bash
cd ~/docker-dev-container

# Set unique values for each agent
export CONTAINER_NAME=agent-task-1
export REPO_PATH=../../repos/healthtrac360-web
export HOST_PORT=3001
export CONTAINER_PORT=3000

# Build and start
docker-compose up -d --build

# Enter container
docker exec -it $CONTAINER_NAME bash
```

### Port Mapping for Parallel Agents

- Agent 1: `3001:3000`
- Agent 2: `3002:3000`
- Agent 3: `3003:3000`

### Running E2E Tests with Screenshots

```bash
# Inside the container
cd /workspace
npm install
npm run test:e2e

# Screenshots saved to local e2e/screenshots/
```

### Stopping a Container

```bash
cd ~/docker-dev-container
export CONTAINER_NAME=agent-task-1
docker-compose down
```

## Screenshot Location

Screenshots are saved locally in: `e2e/screenshots/`

## Review Process

1. Sub-agent completes task in Docker container
2. Sub-agent runs E2E tests → screenshots generated
3. **Assistant** reviews code using `/review` command
4. **User** reviews screenshots in `e2e/screenshots/` directory

## Example Usage

```bash
# Sub-agent runs E2E tests with screenshots
cd healthtrac360-web
npm run test:e2e

# Screenshots generated in:
# e2e/screenshots/*.png
```
