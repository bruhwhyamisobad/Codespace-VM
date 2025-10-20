#!/usr/bin/env bash
set -euo pipefail

# Fully optimized Webtop launcher for GitHub Codespaces.
# - Persists all user data to <workspace>/webtop-config
# - Uses Docker-in-Docker
# - Passwordless (no WEBTOP_PASSWORD)
# - Optimized for 2-core / 8 GB / 32 GB Codespace
# - Includes log rotation to prevent disk exhaustion

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE="${WEBTOP_IMAGE:-lscr.io/linuxserver/webtop:ubuntu-kde}"
CONTAINER_NAME="webtop"
PERSISTENT_HOME="$REPO_ROOT/webtop-config"

# Always use vscode uid/gid 1000 to avoid permission mismatches on workspace mounts
HOST_UID=1000
HOST_GID=1000

# Defaults tuned for a 2-core / 8 GB Codespace
SHM_SIZE="${WEBTOP_SHM_SIZE:-1gb}"
MEM_LIMIT="${WEBTOP_MEM_LIMIT:-6g}"
CPU_LIMIT="${WEBTOP_CPU_LIMIT:-1.8}"
HEALTH_TIMEOUT="${WEBTOP_HEALTH_TIMEOUT:-60}"

# Ensure persistent folder exists on the host workspace
mkdir -p "$PERSISTENT_HOME"
if [ -z "$(ls -A "$PERSISTENT_HOME")" ]; then
  touch "$PERSISTENT_HOME/.gitkeep"
fi

# Wait up to 60 seconds for Docker CLI and daemon to be ready (d-in-d can be slow)
MAX_WAIT=60
WAITED=0

while ! command -v docker >/dev/null 2>&1; do
  if [ "$WAITED" -ge "$MAX_WAIT" ]; then
    echo "ERROR: Docker CLI not available after ${MAX_WAIT}s. Ensure docker-in-docker feature is active."
    exit 1
  fi
  sleep 1
  WAITED=$((WAITED+1))
done

WAITED=0
while ! docker info >/dev/null 2>&1; do
  if [ "$WAITED" -ge "$MAX_WAIT" ]; then
    echo "ERROR: Docker daemon not responding after ${MAX_WAIT}s. Restart Codespace or docker-in-docker."
    exit 1
  fi
  sleep 1
  WAITED=$((WAITED+1))
done

# Ensure persistent folder ownership
chown -R "${HOST_UID}:${HOST_GID}" "$PERSISTENT_HOME" || true

# Remove any existing container
EXISTING="$(docker ps -a -q -f name="^/${CONTAINER_NAME}$" || true)"
if [ -n "$EXISTING" ]; then
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

# Pull the latest Webtop image
docker pull "$IMAGE" || true

# Build Docker run arguments
RUN_ARGS=(
  -d
  --name "$CONTAINER_NAME"
  -p 3000:3000
  -p 3001:3001
  -e "PUID=${HOST_UID}"
  -e "PGID=${HOST_GID}"
  -e "TZ=America/Los_Angeles"
  -v "$PERSISTENT_HOME":/config
  --shm-size="$SHM_SIZE"
  --restart unless-stopped
  --log-opt max-size=10m
  --log-opt max-file=3
  --label "devcontainer.webtop=true"
)

# Apply resource limits
if [ -n "$MEM_LIMIT" ]; then
  RUN_ARGS+=(--memory="$MEM_LIMIT")
fi
if [ -n "$CPU_LIMIT" ]; then
  RUN_ARGS+=(--cpus="$CPU_LIMIT")
fi

# Health check
RUN_ARGS+=(
  --health-cmd='curl -fsS http://localhost:3000 || exit 1'
  --health-interval=10s
  --health-retries=6
  --health-timeout=2s
)

# Start Webtop container
docker run "${RUN_ARGS[@]}" "$IMAGE"

# Wait until Webtop responds or dump logs
for i in $(seq 1 "$HEALTH_TIMEOUT"); do
  if curl -sSf --connect-timeout 1 "http://localhost:3000" >/dev/null 2>&1; then
    echo "Webtop available at http://localhost:3000"
    echo "Persistent config stored at: $PERSISTENT_HOME"
    exit 0
  fi
  sleep 1
done

echo "Webtop did not become healthy in ${HEALTH_TIMEOUT}s. Last 200 log lines:"
docker logs --tail 200 "$CONTAINER_NAME" || true
exit 1