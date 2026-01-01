#!/usr/bin/env bash
# run-all.sh
# Starts/stops/status for the workspace services with a fixed sequence:
# 1) Run: KONG_DATABASE=postgres docker-compose --profile database up (in ./docker-kong/compose)
# 2) Start 2 instances of catalog service (npm run dev)
# 3) Start 2 instances of auth-service (npm run dev)
# 4) Start 1 instance of admin-dashboard (npm run dev)
# 5) Start 1 instance of client-app (npm run dev)
#
# Usage:
#   ./run-all.sh start
#   ./run-all.sh stop
#   ./run-all.sh status
#
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"

# Map of short name -> relative path (relative to SCRIPT_DIR)
declare -A SERVICES
SERVICES[catalog]="catalog service"
SERVICES[auth]="auth-service"
SERVICES[admin]="admin-dashboard"
SERVICES[client]="client-app"

# Instances count per service
declare -A INSTANCES
INSTANCES[catalog]=2
INSTANCES[auth]=2
INSTANCES[admin]=1
INSTANCES[client]=1

# choose which npm script to run: prefer "dev" then "start"
choose_cmd() {
  local dir="$1"
  local pkg="$dir/package.json"
  if [[ ! -f "$pkg" ]]; then
    return 1
  fi
  if grep -q '"dev"' "$pkg"; then
    echo "npm --prefix \"$dir\" run dev"
    return 0
  fi
  if grep -q '"start"' "$pkg"; then
    echo "npm --prefix \"$dir\" start"
    return 0
  fi
  return 2
}

start_all() {
  echo "Starting docker-kong (if present) and services (logs -> $LOG_DIR)"

  # 1) Start docker-kong compose if directory exists
  docker_kong_dir="$SCRIPT_DIR/docker-kong/compose"
  if [[ -d "$docker_kong_dir" ]]; then
    dk_log="$LOG_DIR/docker-kong.log"
    dk_pidfile="$LOG_DIR/docker-kong.pid"
    if [[ -f "$dk_pidfile" ]] && kill -0 "$(cat $dk_pidfile)" 2>/dev/null; then
      echo "[docker-kong] already running (pid $(cat $dk_pidfile))"
    else
      echo "[docker-kong] starting in background -> $dk_log"
      nohup bash -lc "cd \"$docker_kong_dir\"; KONG_DATABASE=postgres docker-compose --profile database up" > "$dk_log" 2>&1 &
      echo $! > "$dk_pidfile"
      echo "  pid: $(cat $dk_pidfile)"
    fi
  else
    echo "[docker-kong] directory not found: $docker_kong_dir (skipping)"
  fi

  # 2) Start app services using instance counts
  for name in "${!SERVICES[@]}"; do
    relpath="${SERVICES[$name]}"
    dir="$SCRIPT_DIR/$relpath"
    instances=${INSTANCES[$name]:-1}

    if [[ ! -d "$dir" ]]; then
      echo "[skip] $name: directory not found: $dir"
      continue
    fi

    for ((i=1;i<=instances;i++)); do
      suffix=""
      if [[ $instances -gt 1 ]]; then
        suffix="-$i"
      fi
      pidfile="$LOG_DIR/$name${suffix}.pid"
      logfile="$LOG_DIR/$name${suffix}.log"

      if [[ -f "$pidfile" ]]; then
        pid=$(cat "$pidfile" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
          echo "[running] $name${suffix} (pid $pid) - skipping"
          continue
        else
          echo "[stale pid] removing $pidfile"
          rm -f "$pidfile"
        fi
      fi

      cmdline="$(choose_cmd "$dir" || true)"
      if [[ -z "$cmdline" ]]; then
        echo "[skip] $name${suffix}: no 'dev' or 'start' script found in $dir/package.json"
        continue
      fi

      echo "[start] $name${suffix} -> $cmdline"
      nohup bash -lc "cd \"$dir\"; $cmdline" > "$logfile" 2>&1 &
      echo $! > "$pidfile"
      echo "  pid: $(cat $pidfile)  log: $logfile"
    done
  done
}

stop_all() {
  echo "Stopping services"
  # Stop docker-kong first if started
  dk_pidfile="$LOG_DIR/docker-kong.pid"
  if [[ -f "$dk_pidfile" ]]; then
    dkpid=$(cat "$dk_pidfile" 2>/dev/null || true)
    if [[ -n "$dkpid" ]] && kill -0 "$dkpid" 2>/dev/null; then
      echo "Stopping docker-kong (pid $dkpid)"
      kill "$dkpid" || true
      sleep 1
      if kill -0 "$dkpid" 2>/dev/null; then
        kill -9 "$dkpid" || true
      fi
    fi
    rm -f "$dk_pidfile"
  fi

  for name in "${!SERVICES[@]}"; do
    instances=${INSTANCES[$name]:-1}
    for ((i=1;i<=instances;i++)); do
      suffix=""
      if [[ $instances -gt 1 ]]; then
        suffix="-$i"
      fi
      pidfile="$LOG_DIR/$name${suffix}.pid"
      if [[ -f "$pidfile" ]]; then
        pid=$(cat "$pidfile" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
          echo "Killing $name${suffix} (pid $pid)"
          kill "$pid" || true
          sleep 1
          if kill -0 "$pid" 2>/dev/null; then
            echo "Force killing $name${suffix} (pid $pid)"
            kill -9 "$pid" || true
          fi
        else
          echo "No running process for $name${suffix} (removing stale pid file)"
        fi
        rm -f "$pidfile"
      else
        echo "No pidfile for $name${suffix}"
      fi
    done
  done
}

status_all() {
  dk_pidfile="$LOG_DIR/docker-kong.pid"
  if [[ -f "$dk_pidfile" ]]; then
    dkpid=$(cat "$dk_pidfile" 2>/dev/null || true)
    if [[ -n "$dkpid" ]] && kill -0 "$dkpid" 2>/dev/null; then
      echo "[running] docker-kong (pid $dkpid)"
    else
      echo "[stale] docker-kong (pidfile present, not running)"
    fi
  else
    echo "[stopped] docker-kong"
  fi

  for name in "${!SERVICES[@]}"; do
    instances=${INSTANCES[$name]:-1}
    for ((i=1;i<=instances;i++)); do
      suffix=""
      if [[ $instances -gt 1 ]]; then
        suffix="-$i"
      fi
      pidfile="$LOG_DIR/$name${suffix}.pid"
      if [[ -f "$pidfile" ]]; then
        pid=$(cat "$pidfile" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
          echo "[running] $name${suffix} (pid $pid)"
        else
          echo "[stale]   $name${suffix} (pidfile present, process not running)"
        fi
      else
        echo "[stopped] $name${suffix}"
      fi
    done
  done
}

case ${1-} in
  start)
    start_all
    ;;
  stop)
    stop_all
    ;;
  status)
    status_all
    ;;
  help|--help|-h|"")
    cat <<'USAGE'
Usage: run-all.sh <command>
Commands:
  start   Start all services in background (logs in ./logs)
  stop    Stop all started services
  status  Show status for each service
  help    Show this help

Notes:
- The script looks for 'dev' then 'start' script in each service's package.json.
- Logs and pid files are created in the 'logs' directory next to this script.
- Paths with spaces (e.g. "catalog service") are supported.
USAGE
    ;;
  *)
    echo "Unknown command: ${1-}"
    exit 2
    ;;
esac
