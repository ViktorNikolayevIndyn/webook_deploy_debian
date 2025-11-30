#!/bin/bash
set -e

WORKDIR="$(cd "$(dirname "$0")" && pwd)"
cd "$WORKDIR"

PORT="${1:-3000}"  # Порт из аргумента или 3000 по умолчанию
PID_FILE="$WORKDIR/.server.pid"

# Read restart setting from environment (set by webhook.js) or default to false for static sites
RESTART_ON_DEPLOY="${RESTART_ON_DEPLOY:-false}"

echo "[deploy-static] Working directory: $WORKDIR"
echo "[deploy-static] Port: $PORT"
echo "[deploy-static] Restart on deploy: $RESTART_ON_DEPLOY"

# 1. Check if server is already running
SERVER_RUNNING=0
if [ -f "$PID_FILE" ]; then
  OLD_PID=$(cat "$PID_FILE")
  if kill -0 "$OLD_PID" 2>/dev/null; then
    SERVER_RUNNING=1
  fi
fi

# 2. Smart git pull with change detection
HAS_CHANGES=0
if [ -d ".git" ]; then
  echo "[deploy-static] Checking for changes..."
  
  BEFORE_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "")
  git fetch --all
  REMOTE_COMMIT=$(git rev-parse @{u} 2>/dev/null || echo "")
  
  if [ -n "$BEFORE_COMMIT" ] && [ "$BEFORE_COMMIT" = "$REMOTE_COMMIT" ]; then
    echo "[deploy-static] No changes detected"
    
    # If server is already running and no changes, just exit
    if [ "$SERVER_RUNNING" -eq 1 ]; then
      echo "[deploy-static] Server already running (PID: $OLD_PID) - nothing to do"
      exit 0
    else
      echo "[deploy-static] Server not running - will start it"
    fi
  else
    HAS_CHANGES=1
    
    # Reset any local changes (safe for static sites)
    echo "[deploy-static] Resetting local changes..."
    git reset --hard HEAD
    # Clean untracked files but preserve deploy.sh, .server.pid, server.log
    git clean -fd -e deploy.sh -e .server.pid -e server.log -e '*.log'
    
    git pull --ff-only || {
      echo "[deploy-static] ERROR: git pull failed"
      exit 1
    }
    
    AFTER_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "")
    echo "[deploy-static] Updated from $BEFORE_COMMIT to $AFTER_COMMIT"
  fi
else
  echo "[deploy-static] No .git directory - skipping git pull"
fi

# 2.5. Check if restart is needed for static content
SHOULD_RESTART=0

if [ "$SERVER_RUNNING" -eq 0 ]; then
  # Server not running - need to start
  SHOULD_RESTART=1
elif [ "$HAS_CHANGES" -eq 1 ]; then
  # Changes detected and server running - check config
  if [[ "$RESTART_ON_DEPLOY" =~ ^(true|True|yes|y|Y)$ ]]; then
    # Explicitly enabled restart
    SHOULD_RESTART=1
  elif [ -t 0 ]; then
    # Interactive mode - ask user
    read -r -p "[deploy-static] Server already running. Restart? [y/N]: " RESTART_SERVER
    RESTART_SERVER=${RESTART_SERVER:-N}
    if [[ "$RESTART_SERVER" =~ ^[Yy]$ ]]; then
      SHOULD_RESTART=1
    fi
  else
    # Non-interactive + restartOnDeploy not true = don't restart
    echo "[deploy-static] ✓ Static content updated (restartOnDeploy not enabled)"
    echo "[deploy-static] ✓ Server still running (PID: $OLD_PID)"
    echo "[deploy-static] ✓ Changes are live at http://localhost:$PORT"
    exit 0
  fi
fi

# 3. Stop old server (only if we decided to restart)
if [ "$SHOULD_RESTART" -eq 1 ]; then
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
  
  # Remove old log file to avoid permission issues
  rm -f "$WORKDIR/server.log"

  # 4. Start new server
  echo "[deploy-static] Starting Python HTTP server on port $PORT..."

  # Check if python3 is available
  if ! command -v python3 >/dev/null 2>&1; then
    echo "[deploy-static] ✗ ERROR: python3 not found in PATH"
    exit 1
  fi

  # Check if port is already in use and kill process
  if ss -tln 2>/dev/null | grep -q ":$PORT "; then
    echo "[deploy-static] WARNING: Port $PORT already in use, killing process..."
    
    # Find PID using the port
    PORT_PID=$(ss -tlnp 2>/dev/null | grep ":$PORT " | grep -oP 'pid=\K[0-9]+' | head -1)
    
    if [ -n "$PORT_PID" ]; then
      echo "[deploy-static] Found process PID: $PORT_PID"
      # Try graceful kill first
      kill "$PORT_PID" 2>/dev/null || true
      sleep 1
      
      # If still running, force kill
      if kill -0 "$PORT_PID" 2>/dev/null; then
        echo "[deploy-static] Process still running, force killing..."
        kill -9 "$PORT_PID" 2>/dev/null || true
        sleep 2
      fi
    else
      echo "[deploy-static] Cannot find PID, trying pkill..."
      pkill -9 -f "python3 -m http.server $PORT" 2>/dev/null || true
      sleep 2
    fi
    
    # Final check
    if ss -tln 2>/dev/null | grep -q ":$PORT "; then
      echo "[deploy-static] ✗ ERROR: Cannot free port $PORT"
      echo "[deploy-static] Processes using port $PORT:"
      ss -tlnp 2>/dev/null | grep ":$PORT " || true
      exit 1
    fi
    
    echo "[deploy-static] Port $PORT freed successfully"
  fi
  
  nohup python3 -m http.server "$PORT" > "$WORKDIR/server.log" 2>&1 &
  SERVER_PID=$!
  echo "$SERVER_PID" > "$PID_FILE"

  sleep 2

  # Verify server is running
  if kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "[deploy-static] ✓ Server running (PID: $SERVER_PID)"
    echo "[deploy-static] ✓ Serving: $WORKDIR"
    echo "[deploy-static] ✓ URL: http://localhost:$PORT"
    echo "[deploy-static] ✓ Logs: $WORKDIR/server.log"
  else
    echo "[deploy-static] ✗ ERROR: Failed to start server"
    echo "[deploy-static] Last 10 lines from server.log:"
    tail -n 10 "$WORKDIR/server.log" 2>/dev/null || echo "(no log file)"
    exit 1
  fi
fi

echo "[deploy-static] Deployment completed successfully"
