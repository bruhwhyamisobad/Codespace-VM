#!/usr/bin/env bash
set -euo pipefail

# === Config ===
IMAGE="ghcr.io/linuxserver/webtop:ubuntu-kde"
CONTAINER_NAME="webtop"
PORT_HTTP=3000
PORT_HTTPS=3001
CONFIG_DIR="${PWD}/webtop-config"
PUID=1000
PGID=1000
TZ="America/Los_Angeles"

# === Credentials from Codespaces secrets ===
if [ -z "${WEBTOP_USER:-}" ] || [ -z "${WEBTOP_PASSWORD:-}" ]; then
    echo "❌ ERROR: WEBTOP_USER and WEBTOP_PASSWORD must be set as Codespaces secrets!"
    exit 1
fi
CUSTOM_USER="$WEBTOP_USER"
PASSWORD="$WEBTOP_PASSWORD"

# Optional GPU support
GPU_FLAG=""
if [ -d "/dev/dri" ]; then
    GPU_FLAG="--device /dev/dri:/dev/dri"
fi

# Ensure persistent config exists
mkdir -p "$CONFIG_DIR"

# Stop & remove existing container
EXISTING_CONTAINER=$(docker ps -a -q -f name="^/${CONTAINER_NAME}$" || true)
if [ -n "$EXISTING_CONTAINER" ]; then
    echo "Stopping and removing existing Webtop container..."
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

# Generate self-signed HTTPS certificate if missing
SSL_CERT_DIR="$CONFIG_DIR/ssl"
mkdir -p "$SSL_CERT_DIR"
CERT_FILE="$SSL_CERT_DIR/webtop.crt"
KEY_FILE="$SSL_CERT_DIR/webtop.key"
if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
    echo "Generating self-signed HTTPS certificate..."
    openssl req -x509 -nodes -days 365 \
        -subj "/CN=localhost" \
        -newkey rsa:2048 \
        -keyout "$KEY_FILE" \
        -out "$CERT_FILE"
fi

# Run Webtop container
echo "Starting Webtop container..."
docker run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  -p "${PORT_HTTP}:3000" \
  -p "${PORT_HTTPS}:3001" \
  -v "${CONFIG_DIR}:/config" \
  -e PUID="$PUID" \
  -e PGID="$PGID" \
  -e TZ="$TZ" \
  -e CUSTOM_HTTPS_PORT="$PORT_HTTPS" \
  -e SSL_CERT_FILE="/config/ssl/webtop.crt" \
  -e SSL_KEY_FILE="/config/ssl/webtop.key" \
  -e CUSTOM_USER="$CUSTOM_USER" \
  -e PASSWORD="$PASSWORD" \
  --shm-size="1gb" \
  --security-opt no-new-privileges:true \
  --read-only \
  --tmpfs /tmp:rw,size=256m \
  $GPU_FLAG \
  "$IMAGE"

# Wait for container initialization
sleep 5

# === Install PRoot apps (persistent) ===
APPS=("filezilla" "vscode" "firefox")
echo "Installing PRoot apps: ${APPS[*]}"
for APP in "${APPS[@]}"; do
    if ! docker exec -it "$CONTAINER_NAME" bash -c "proot-apps list | grep -q '^$APP$'" >/dev/null 2>&1; then
        echo "Installing $APP..."
        docker exec -it "$CONTAINER_NAME" proot-apps install "$APP" || echo "⚠️ Failed to install $APP"
    else
        echo "$APP already installed, skipping."
    fi
done

# Display access info
echo "✅ Webtop is running!"
echo "HTTP:  http://localhost:${PORT_HTTP}"
echo "HTTPS: https://localhost:${PORT_HTTPS}"
echo "Username: $CUSTOM_USER"
echo "Password: $PASSWORD"
echo "Persistent files & PRoot apps: $CONFIG_DIR"

# Open browser automatically if possible
if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "https://localhost:${PORT_HTTPS}" || true
fi
