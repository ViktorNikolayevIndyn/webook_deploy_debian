#!/bin/bash
set -e

WORKDIR="$(cd "$(dirname "$0")" && pwd)"
cd "$WORKDIR"

PORT="${1:-3000}"  # Порт из аргумента или 3000 по умолчанию
PID_FILE="$WORKDIR/.server.pid"

echo "[deploy-static] Working directory: $WORKDIR"
echo "[deploy-static] Port: $PORT"

# 1. Smart git pull with change detection
if [ -d ".git" ]; then
  echo "[deploy-static] Checking for changes..."
  
  BEFORE_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "")
  git fetch --all
  REMOTE_COMMIT=$(git rev-parse @{u} 2>/dev/null || echo "")
  
  if [ -n "$BEFORE_COMMIT" ] && [ "$BEFORE_COMMIT" = "$REMOTE_COMMIT" ]; then
    echo "[deploy-static] No changes detected - skipping deployment"
    exit 0
  fi
  
  git pull --ff-only || {
    echo "[deploy-static] ERROR: git pull failed"
    exit 1
  }
  
  AFTER_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "")
  echo "[deploy-static] Updated from $BEFORE_COMMIT to $AFTER_COMMIT"
else
  echo "[deploy-static] No .git directory - skipping git pull"
fi

# 2. Stop old server
if [ -f "$PID_FILE" ]; then
  OLD_PID=$(cat "$PID_FILE")
  if kill -0 "$OLD_PID" 2>/dev/null; then
    echo "[deploy-static] Stopping old server (PID: $OLD_PID)..."
    kill "$OLD_PID" || true
    sleep 1
  fi
  rm -f "$PID_FILE"
fi

# Fallback: kill by port
pkill -f "python3 -m http.server $PORT" 2>/dev/null || true
sleep 0.5

# 3. Start new server
echo "[deploy-static] Starting Python HTTP server on port $PORT..."
nohup python3 -m http.server "$PORT" > "$WORKDIR/server.log" 2>&1 &
SERVER_PID=$!
echo "$SERVER_PID" > "$PID_FILE"

sleep 1

# 4. Verify server is running
if kill -0 "$SERVER_PID" 2>/dev/null; then
  echo "[deploy-static] ✓ Server running (PID: $SERVER_PID)"
  echo "[deploy-static] ✓ Serving: $WORKDIR"
  echo "[deploy-static] ✓ URL: http://localhost:$PORT"
  echo "[deploy-static] ✓ Logs: $WORKDIR/server.log"
else
  echo "[deploy-static] ✗ ERROR: Failed to start server"
  exit 1
fi

echo "[deploy-static] Deployment completed successfully"
