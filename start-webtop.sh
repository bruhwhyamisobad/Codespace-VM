#!/usr/bin/env bash
set -euo pipefail

# -------------------------------
# Fully persistent Webtop start (all files)
# -------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"

IMAGE="ghcr.io/linuxserver/webtop:ubuntu-kde"
CONTAINER_NAME="webtop"
PORT=3000
HEALTH_TIMEOUT=30

# Single persistent folder for everything in /home/user
PERSISTENT_HOME="$REPO_ROOT/webtop-home"
mkdir -p "$PERSISTENT_HOME"

# Create .gitkeep if folder is empty (for Git tracking)
if [ -z "$(ls -A "$PERSISTENT_HOME")" ]; then
  touch "$PERSISTENT_HOME/.gitkeep"
fi

# Docker CLI/daemon check
if ! command -v docker >/dev/null 2>&1; then
  echo "docker CLI not found. Install Docker first."
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Docker daemon not responding. Try 'sudo dockerd &' or restart the container."
  exit 1
fi

# Stop & remove existing container
EXISTING="$(docker ps -a -q -f name="^/${CONTAINER_NAME}$" || true)"
if [ -n "$EXISTING" ]; then
  echo "Stopping and removing existing container..."
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

# Pull latest image
docker pull "$IMAGE" || true

# Host UID/GID for proper file ownership
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

# Run container with full home persistence
echo "Starting Webtop with full /home/user persistence..."
docker run -d \
  --name "$CONTAINER_NAME" \
  -p "${PORT}:3000" \
  -e PUID="$HOST_UID" \
  -e PGID="$HOST_GID" \
  -v "$PERSISTENT_HOME:/home/user" \
  --restart unless-stopped \
  "$IMAGE"

# Fix ownership
chown -R "$HOST_UID:$HOST_GID" "$PERSISTENT_HOME" || true

# Health check
echo "Waiting for Webtop to become reachable..."
for i in $(seq 1 $HEALTH_TIMEOUT); do
  if curl -sSf --connect-timeout 1 "http://localhost:${PORT}" >/dev/null 2>&1; then
    echo "Webtop ready at http://localhost:${PORT}"
    break
  fi
  sleep 1
done

echo "All /home/user files are now fully persistent in $PERSISTENT_HOME."
