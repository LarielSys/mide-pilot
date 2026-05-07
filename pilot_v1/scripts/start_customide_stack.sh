#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="/home/larieladmin/mide-pilot/pilot_v1/customide"
BACKEND_DIR="$BASE_DIR/backend"
FRONTEND_DIR="$BASE_DIR/frontend"
RELAY_DIR="/home/larieladmin/Documents/itheia-llm"
RELAY_VENV="$RELAY_DIR/.venv/bin/python"
BACKEND_PORT=5555
FRONTEND_PORT=5570
RELAY_PORT=8787

BACKEND_LOG="$BACKEND_DIR/backend.log"
FRONTEND_LOG="$FRONTEND_DIR/frontend.log"
RELAY_LOG="$RELAY_DIR/relay_server.log"

port_is_listening() {
  local port="$1"
  ss -ltn "sport = :${port}" | grep -q LISTEN
}

start_backend() {
  if port_is_listening "$BACKEND_PORT"; then
    echo "Backend already running on :$BACKEND_PORT"
    return
  fi

  echo "Starting backend on :$BACKEND_PORT"
  cd "$BACKEND_DIR"

  if [[ -x "$BACKEND_DIR/.venv/bin/uvicorn" ]]; then
    nohup "$BACKEND_DIR/.venv/bin/uvicorn" app.main:app --host 0.0.0.0 --port "$BACKEND_PORT" >> "$BACKEND_LOG" 2>&1 &
  else
    nohup python3 -m uvicorn app.main:app --host 0.0.0.0 --port "$BACKEND_PORT" >> "$BACKEND_LOG" 2>&1 &
  fi
}

start_frontend() {
  if port_is_listening "$FRONTEND_PORT"; then
    echo "Frontend already running on :$FRONTEND_PORT"
    return
  fi

  echo "Starting frontend on :$FRONTEND_PORT"
  cd "$FRONTEND_DIR"
  nohup python3 -m http.server "$FRONTEND_PORT" --bind 0.0.0.0 >> "$FRONTEND_LOG" 2>&1 &
}

start_relay() {
  if port_is_listening "$RELAY_PORT"; then
    echo "Ole Green relay already running on :$RELAY_PORT"
    return
  fi

  echo "Starting Ole Green relay on :$RELAY_PORT"
  cd "$RELAY_DIR"
  nohup "$RELAY_VENV" relay_server.py >> "$RELAY_LOG" 2>&1 &
}

start_backend
start_frontend
start_relay

echo ""
echo "CustomIDE Cockpit services are up:"
echo "- Backend:  http://127.0.0.1:$BACKEND_PORT"
echo "- Frontend: http://127.0.0.1:$FRONTEND_PORT"
echo "- Relay:    http://127.0.0.1:$RELAY_PORT"
