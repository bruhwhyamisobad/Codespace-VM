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

# Always use vscode-style uid/gid (1000), even if script runs as root
if [ "$(id -u)" -eq 0 ]; then
  HOST_UID="${WEBTOP_HOST_UID:-1000}"
  HOST_GID="${WEBTOP_HOST_GID:-1000}"
else
  HOST_UID="$(id -u)"
  HOST_GID="$(id -g)"
fi

# Defaults tuned for a 2-core / 8 GB Codespace
SHM_SIZE="${WEBTOP_SHM_SIZE:-1gb}"
MEM_LIMIT="${WEBTOP_MEM_LIMIT:-6g}"
CPU_LIMIT="${WEBTOP_CPU_LIMIT:-1.8}"
HEALTH_TIMEOUT="${WEBTOP_HEALTH_TIMEOUT:-60}"

mkdir -p "$PERSISTENT_HOME"
if [ -z "$(ls -A "$PERSISTENT_HOME")" ]; then
  touch "$PERSISTENT_HOME/.gitkeep"
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker CLI not found. Ensure docker-in-docker feature is enabled in the devcontainer."
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "ERROR: Docker daemon not responding. Restart the Codespace or the docker-in-docker feature."
  exit 1
fi

chown -R "${HOST_UID}:${HOST_GID}" "$PERSISTENT_HOME" || true

# Remove any existing container
EXISTING="$(docker ps -a -q -f name="^/${CONTAINER_NAME}$" || true)"
if [ -n "$EXISTING" ]; then
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

docker pull "$IMAGE" || true

RUN_ARGS=(
  -d
  --name "$CONTAINER_NAME"
  -p 3000:3000
  -p 3001:3001
  -e "PUID=${HOST_UID:-1000}"
  -e "PGID=${HOST_GID:-1000}"
  -e "TZ=America/Los_Angeles"
  -v "$PERSISTENT_HOME":/config
  --shm-size="$SHM_SIZE"
  --restart unless-stopped
  --log-opt max-size=10m
  --log-opt max-file=3
  --label "devcontainer.webtop=true"
)

# Apply limits
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

docker run "${RUN_ARGS[@]}" "$IMAGE"

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