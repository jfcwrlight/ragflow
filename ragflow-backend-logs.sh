#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/logs/ragflow-backend.log"
LINES="${1:-200}"

if [[ ! "$LINES" =~ ^[0-9]+$ ]]; then
  echo "Usage: $0 [lines]" >&2
  exit 2
fi

if [[ ! -f "$LOG_FILE" ]]; then
  echo "Log file does not exist yet: $LOG_FILE" >&2
  echo "Start backend first: ./ragflow-backend.sh start" >&2
  exit 1
fi

tail -n "$LINES" -f "$LOG_FILE"
