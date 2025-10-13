#!/usr/bin/env bash
set -euo pipefail

# -------------------------------
# Fully persistent Webtop start (with Node + Playwright + KDE defaults + VS Code terminal)
# Idempotent version
# Optional Node/Playwright reinstall via FORCE_NODE_INSTALL
# -------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"

IMAGE="ghcr.io/linuxserver/webtop:ubuntu-kde"
CONTAINER_NAME="webtop"
PORT=3000
HEALTH_TIMEOUT=30

# Optional: force Node.js + Playwright reinstall (default false)
FORCE_NODE_INSTALL="${FORCE_NODE_INSTALL:-false}"

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
  echo "Docker daemon not responding. Try 'sudo dockerd &' or restart Docker."
  exit 1
fi

# Stop & remove existing container (idempotent)
EXISTING="$(docker ps -a -q -f name="^/${CONTAINER_NAME}$" || true)"
if [ -n "$EXISTING" ]; then
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

# Pull latest image (idempotent)
docker pull "$IMAGE" || true

# Host UID/GID for proper file ownership
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

# Run container with full home persistence (skip if already running)
if ! docker ps -q -f name="^/${CONTAINER_NAME}$" | grep -q .; then
  docker run -d \
    --name "$CONTAINER_NAME" \
    -p "${PORT}:3000" \
    -e PUID="$HOST_UID" \
    -e PGID="$HOST_GID" \
    -v "$PERSISTENT_HOME:/home/user" \
    --shm-size="2gb" \
    --restart unless-stopped \
    "$IMAGE"
fi

# Fix ownership (idempotent)
chown -R "$HOST_UID:$HOST_GID" "$PERSISTENT_HOME" || true

# Health check (idempotent)
for i in $(seq 1 $HEALTH_TIMEOUT); do
  if curl -sSf --connect-timeout 1 "http://localhost:${PORT}" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

# Install Node.js + Playwright (idempotent unless forced)
docker exec -u 0 "$CONTAINER_NAME" bash -lc "
set -e
if [ \"$FORCE_NODE_INSTALL\" = \"true\" ] || ! command -v node >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y curl ca-certificates gnupg
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
  echo \"deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main\" > /etc/apt/sources.list.d/nodesource.list
  apt-get update -y
  apt-get install -y nodejs
  npm install -g npm@latest playwright
  npx playwright install-deps
  npx playwright install --with-deps || true
  apt-get clean
  rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
else
  echo \"Node.js already installed (\$(node -v))\"
fi
"

# KDE/XDG defaults + kconsole + VS Code terminal (idempotent)
docker exec -u 0 "$CONTAINER_NAME" bash -lc '
set -e

# Create standard user folders
for d in Desktop Documents Downloads Music Pictures Public Templates Videos; do
  mkdir -p "/home/user/$d"
done

# Configure XDG user directories
mkdir -p /home/user/.config
cat > /home/user/.config/user-dirs.dirs <<'EOF'
XDG_DESKTOP_DIR="$HOME/Desktop"
XDG_DOWNLOAD_DIR="$HOME/Downloads"
XDG_DOCUMENTS_DIR="$HOME/Documents"
XDG_MUSIC_DIR="$HOME/Music"
XDG_PICTURES_DIR="$HOME/Pictures"
XDG_PUBLICSHARE_DIR="$HOME/Public"
XDG_TEMPLATES_DIR="$HOME/Templates"
XDG_VIDEOS_DIR="$HOME/Videos"
EOF

# Configure kconsole to start in /home/user
mkdir -p /home/user/.config
cat > /home/user/.config/konsolerc <<'EOK'
[Desktop Entry]
Name=Konsole
Exec=konsole --workdir /home/user
EOK

# Configure VS Code integrated terminal to open in /home/user
mkdir -p /home/user/.vscode-server/data/Machine
cat > /home/user/.vscode-server/data/Machine/settings.json <<'JSON'
{
  "terminal.integrated.cwd": "/home/user"
}
JSON

# Ensure system-wide HOME for root and all processes
if ! grep -q "^HOME=/home/user" /etc/environment 2>/dev/null; then
  echo "HOME=/home/user" >> /etc/environment
fi

# Set vscode user home directory (idempotent)
usermod -d /home/user vscode || true

# -------------------------------
# Ensure all interactive shells start in /home/user
# -------------------------------
BASHRC_FILE="/home/user/.bashrc"
if ! grep -q "cd /home/user" "$BASHRC_FILE"; then
  echo "cd /home/user" >> "$BASHRC_FILE"
  echo "export HOME=/home/user" >> "$BASHRC_FILE"
fi
'

echo "All set! Access Webtop at: http://localhost:${PORT}"
echo "All files persist in: $PERSISTENT_HOME"
