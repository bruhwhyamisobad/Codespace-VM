#!/usr/bin/env bash
set -euo pipefail

# Idempotent Webtop launcher for Codespaces/devcontainer.
# - Persists all webtop user data to <workspace>/webtop-config
# - Uses Docker-in-Docker feature provided by devcontainer
# - Uses latest image by default via WEBTOP_IMAGE env var (set in devcontainer.json)
# - Does not configure password/auth; run behind a proxy if exposing publicly

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE="${WEBTOP_IMAGE:-lscr.io/linuxserver/webtop:ubuntu-kde}"
CONTAINER_NAME="webtop"
PERSISTENT_HOME="$REPO_ROOT/webtop-config"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
SHM_SIZE="${WEBTOP_SHM_SIZE:-2gb}"
HEALTH_TIMEOUT="${WEBTOP_HEALTH_TIMEOUT:-60}"
MEM_LIMIT="${WEBTOP_MEM_LIMIT:-}"
CPU_LIMIT="${WEBTOP_CPU_LIMIT:-}"

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
  -e "PUID=$HOST_UID"
  -e "PGID=$HOST_GID"
  -e "TZ=America/Los_Angeles"
  -v "$PERSISTENT_HOME":/config
  --shm-size="$SHM_SIZE"
  --security-opt no-new-privileges:true
  --restart unless-stopped
  --label "devcontainer.webtop=true"
)

if [ -n "$MEM_LIMIT" ]; then
  RUN_ARGS+=(--memory="$MEM_LIMIT")
fi
if [ -n "$CPU_LIMIT" ]; then
  RUN_ARGS+=(--cpus="$CPU_LIMIT")
fi

# health command ensures Docker marks the container healthy when the web UI responds
RUN_ARGS+=(--health-cmd='curl -fsS http://localhost:3000 || exit 1' --health-interval=10s --health-retries=6 --health-timeout=2s)

docker run "${RUN_ARGS[@]}" "$IMAGE"

for i in $(seq 1 "$HEALTH_TIMEOUT"); do
  if curl -sSf --connect-timeout 1 "http://localhost:3000" >/dev/null 2>&1; then
    echo "SUCCESS: Webtop available at http://localhost:3000"
    echo "Persistent config at: $PERSISTENT_HOME"
    exit 0
  fi
  sleep 1
done

echo "ERROR: Webtop did not become healthy in ${HEALTH_TIMEOUT}s. Last 200 log lines:"
docker logs --tail 200 "$CONTAINER_NAME" || true
exit 1
