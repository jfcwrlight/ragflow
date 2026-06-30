#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/ragflow-backend.log"
PID_FILE="$LOG_DIR/ragflow-backend.pid"
API_PID_FILE="$LOG_DIR/ragflow-api.pid"
TASK_EXECUTOR_PID_FILE="$LOG_DIR/ragflow-task-executor.pid"

usage() {
  echo "Usage: $0 {start|stop|restart}"
}

read_pid() {
  local file="${1:-$PID_FILE}"
  if [[ -f "$file" ]]; then
    tr -d '[:space:]' < "$file"
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

command_matches() {
  local pid="${1:-}"
  local pattern="${2:-}"
  local command

  process_exists "$pid" || return 1
  command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ "$command" == *"$pattern"* ]]
}

collect_descendants() {
  local parent="${1:-}"
  local child

  command -v pgrep >/dev/null 2>&1 || return 0
  for child in $(pgrep -P "$parent" 2>/dev/null || true); do
    echo "$child"
    collect_descendants "$child"
  done
}

all_processes_stopped() {
  local pid

  for pid in "$@"; do
    if process_exists "$pid"; then
      return 1
    fi
  done
  return 0
}

pid_cwd_matches_project() {
  local pid="${1:-}"
  local cwd

  if [[ -e "/proc/$pid/cwd" ]]; then
    cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null || true)"
    [[ "$cwd" == "$SCRIPT_DIR" ]]
    return
  fi

  return 1
}

terminate_process_tree() {
  local root_pid="${1:-}"
  local label="${2:-process}"
  local descendant
  local pgid
  local i
  local pids=()

  process_exists "$root_pid" || return 0

  while IFS= read -r descendant; do
    [[ -n "$descendant" ]] && pids+=("$descendant")
  done < <(collect_descendants "$root_pid")
  pids+=("$root_pid")

  pgid="$(ps -o pgid= -p "$root_pid" 2>/dev/null | tr -d '[:space:]' || true)"

  echo "Stopping $label. pid=$root_pid"
  if [[ -n "$pgid" && "$pgid" == "$root_pid" ]]; then
    kill -TERM -- "-$root_pid" 2>/dev/null || true
  else
    kill -TERM "${pids[@]}" 2>/dev/null || true
  fi

  for i in {1..30}; do
    if all_processes_stopped "${pids[@]}"; then
      return 0
    fi
    sleep 1
  done

  echo "$label did not stop within 30s; sending SIGKILL. pid=$root_pid" >&2
  if [[ -n "$pgid" && "$pgid" == "$root_pid" ]]; then
    kill -KILL -- "-$root_pid" 2>/dev/null || true
  else
    kill -KILL "${pids[@]}" 2>/dev/null || true
  fi

  for i in {1..5}; do
    if all_processes_stopped "${pids[@]}"; then
      return 0
    fi
    sleep 1
  done

  echo "Warning: some $label processes are still running." >&2
  return 1
}

stop_pid_file_process() {
  local file="$1"
  local label="$2"
  local pattern="$3"
  local strict="${4:-false}"
  local pid
  local status=0

  pid="$(read_pid "$file" || true)"
  if [[ -z "$pid" ]]; then
    return 0
  fi

  if ! process_exists "$pid"; then
    echo "$label is not running. Removing stale pid file: $file"
    rm -f "$file"
    return 0
  fi

  if ! command_matches "$pid" "$pattern"; then
    echo "PID file points to another process; not stopping it. file=$file pid=$pid" >&2
    echo "Removing stale pid file: $file" >&2
    rm -f "$file"
    if [[ "$strict" == "true" ]]; then
      return 1
    fi
    return 0
  fi

  terminate_process_tree "$pid" "$label" || status=1
  rm -f "$file"
  return "$status"
}

stop_matching_project_processes() {
  local label="$1"
  local pattern="$2"
  local pid
  local status=0

  command -v pgrep >/dev/null 2>&1 || return 0
  for pid in $(pgrep -f "$pattern" 2>/dev/null || true); do
    [[ "$pid" == "$$" ]] && continue
    process_exists "$pid" || continue
    if pid_cwd_matches_project "$pid"; then
      terminate_process_tree "$pid" "$label" || status=1
    fi
  done

  return "$status"
}

start_backend() {
  local pid

  mkdir -p "$LOG_DIR"
  pid="$(read_pid "$PID_FILE" || true)"

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

  if command -v setsid >/dev/null 2>&1; then
    nohup setsid bash -lc 'source .venv/bin/activate && export PYTHONPATH="$PWD" && export NLTK_DATA="$PWD/ragflow_deps/nltk_data:$PWD/nltk_data" && exec bash docker/launch_backend_service.sh' \
      > "$LOG_FILE" 2>&1 &
  else
    nohup bash -lc 'source .venv/bin/activate && export PYTHONPATH="$PWD" && export NLTK_DATA="$PWD/ragflow_deps/nltk_data:$PWD/nltk_data" && exec bash docker/launch_backend_service.sh' \
      > "$LOG_FILE" 2>&1 &
  fi
  pid=$!
  echo "$pid" > "$PID_FILE"

  echo "Started RAGFlow backend. pid=$pid"
  echo "Log: $LOG_FILE"
  echo "Watch logs: ./ragflow-backend-logs.sh"
}

stop_backend() {
  local pid
  local status=0

  pid="$(read_pid "$PID_FILE" || true)"
  if [[ -z "$pid" ]]; then
    echo "RAGFlow backend is not running: no pid file."
  elif ! process_exists "$pid"; then
    echo "RAGFlow backend is not running. Removing stale pid file."
    rm -f "$PID_FILE"
  elif ! is_backend_process "$pid"; then
    echo "PID file points to another process; not stopping it. pid=$pid" >&2
    echo "Removing stale pid file: $PID_FILE" >&2
    rm -f "$PID_FILE"
    status=1
  else
    terminate_process_tree "$pid" "RAGFlow backend" || status=1
    rm -f "$PID_FILE"
    echo "Stopped RAGFlow backend."
  fi

  # Also clean up processes started by the documented split-start workflow.
  stop_pid_file_process "$API_PID_FILE" "manual RAGFlow API" "api/ragflow_server.py" false || status=1
  stop_pid_file_process "$TASK_EXECUTOR_PID_FILE" "manual task executor" "rag/svr/task_executor.py" false || status=1
  stop_matching_project_processes "orphan RAGFlow API" "api/ragflow_server.py" || status=1
  stop_matching_project_processes "orphan Go RAGFlow API" "bin/ragflow_server" || status=1
  stop_matching_project_processes "orphan task executor" "rag/svr/task_executor.py" || status=1
  return "$status"
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
