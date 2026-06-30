#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/ragflow-backend.log"
PID_FILE="$LOG_DIR/ragflow-backend.pid"

usage() {
  echo "Usage: $0 {start|stop|restart}"
}

read_pid() {
  if [[ -f "$PID_FILE" ]]; then
    tr -d '[:space:]' < "$PID_FILE"
  fi
}

process_exists() {
  local pid="${1:-}"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

is_backend_process() {
  local pid="${1:-}"
  local command

  process_exists "$pid" || return 1
  command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ "$command" == *"docker/launch_backend_service.sh"* ]]
}

start_backend() {
  local pid

  mkdir -p "$LOG_DIR"
  pid="$(read_pid || true)"

  if is_backend_process "$pid"; then
    echo "RAGFlow backend is already running. pid=$pid"
    echo "Log: $LOG_FILE"
    return 0
  fi

  if [[ -n "$pid" ]]; then
    echo "Removing stale pid file: $PID_FILE"
    rm -f "$PID_FILE"
  fi

  if [[ ! -f "$SCRIPT_DIR/.venv/bin/activate" ]]; then
    echo "Missing .venv. Run uv sync first." >&2
    exit 1
  fi

  nohup bash -lc 'source .venv/bin/activate && export PYTHONPATH="$PWD" && exec bash docker/launch_backend_service.sh' \
    > "$LOG_FILE" 2>&1 &
  pid=$!
  echo "$pid" > "$PID_FILE"

  echo "Started RAGFlow backend. pid=$pid"
  echo "Log: $LOG_FILE"
  echo "Watch logs: ./ragflow-backend-logs.sh"
}

stop_backend() {
  local pid
  local i

  pid="$(read_pid || true)"
  if [[ -z "$pid" ]]; then
    echo "RAGFlow backend is not running: no pid file."
    return 0
  fi

  if ! process_exists "$pid"; then
    echo "RAGFlow backend is not running. Removing stale pid file."
    rm -f "$PID_FILE"
    return 0
  fi

  if ! is_backend_process "$pid"; then
    echo "PID file points to another process; not stopping it. pid=$pid" >&2
    echo "Removing stale pid file: $PID_FILE" >&2
    rm -f "$PID_FILE"
    return 1
  fi

  echo "Stopping RAGFlow backend. pid=$pid"
  kill "$pid" 2>/dev/null || true

  for i in {1..30}; do
    if ! process_exists "$pid"; then
      rm -f "$PID_FILE"
      echo "Stopped RAGFlow backend."
      return 0
    fi
    sleep 1
  done

  echo "Backend did not stop within 30s; sending SIGKILL to launcher pid=$pid" >&2
  kill -9 "$pid" 2>/dev/null || true
  rm -f "$PID_FILE"
  echo "Stopped launcher. If child processes remain, run:"
  echo '  pkill -f "api/ragflow_server.py|rag/svr/task_executor.py"'
}

case "${1:-}" in
  start)
    start_backend
    ;;
  stop)
    stop_backend
    ;;
  restart)
    stop_backend
    start_backend
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
