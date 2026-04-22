#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  open_worker_target.sh open-url <url> [--wait-http-seconds=<n>]
  open_worker_target.sh open-file <absolute-or-relative-path>
  open_worker_target.sh launch-program <program> [args...]

Examples:
  open_worker_target.sh open-url http://127.0.0.1:8787/ --wait-http-seconds=30
  open_worker_target.sh open-file /home/larieladmin/mide-pilot/clone/larielsystems/larielsystems.com/index.html
  open_worker_target.sh launch-program firefox --new-window http://127.0.0.1:8787/
EOF
}

now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

require_gui_session() {
  if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
    echo "error=no_gui_session_detected"
    echo "hint=Set DISPLAY or WAYLAND_DISPLAY for desktop launch operations."
    return 1
  fi
}

find_opener() {
  if command -v xdg-open >/dev/null 2>&1; then
    echo "xdg-open"
    return 0
  fi

  if command -v gio >/dev/null 2>&1; then
    echo "gio open"
    return 0
  fi

  if [[ -n "${BROWSER:-}" ]]; then
    echo "${BROWSER}"
    return 0
  fi

  return 1
}

wait_for_http() {
  local url="$1"
  local timeout_seconds="$2"
  local deadline=$((SECONDS + timeout_seconds))

  while (( SECONDS < deadline )); do
    if curl -sS -o /dev/null -w "%{http_code}" "${url}" | grep -qE '^(200|301|302|304)$'; then
      echo "http_ready=true"
      return 0
    fi
    sleep 1
  done

  echo "http_ready=false"
  return 1
}

launch_detached() {
  local log_file="$1"
  shift

  nohup "$@" >"${log_file}" 2>&1 &
  local pid=$!
  echo "launch_pid=${pid}"
  echo "launch_log=${log_file}"
}

if [[ $# -lt 2 ]]; then
  usage
  exit 2
fi

mode="$1"
shift

case "${mode}" in
  open-url)
    target_url="$1"
    shift
    wait_seconds="0"

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --wait-http-seconds=*)
          wait_seconds="${1#*=}"
          ;;
        *)
          echo "error=unknown_option"
          echo "option=$1"
          exit 2
          ;;
      esac
      shift
    done

    if [[ "${wait_seconds}" != "0" ]]; then
      wait_for_http "${target_url}" "${wait_seconds}"
    fi

    require_gui_session
    opener="$(find_opener)" || {
      echo "error=no_desktop_opener_found"
      echo "hint=Install xdg-utils or set BROWSER."
      exit 1
    }

    echo "timestamp_utc=$(now_utc)"
    echo "mode=open-url"
    echo "target=${target_url}"
    echo "opener=${opener}"

    # shellcheck disable=SC2086
    launch_detached "/tmp/mide_open_url.log" ${opener} "${target_url}"
    ;;

  open-file)
    target_file="$1"

    require_gui_session
    if [[ ! -e "${target_file}" ]]; then
      echo "error=file_not_found"
      echo "target=${target_file}"
      exit 1
    fi

    opener="$(find_opener)" || {
      echo "error=no_desktop_opener_found"
      echo "hint=Install xdg-utils or set BROWSER."
      exit 1
    }

    echo "timestamp_utc=$(now_utc)"
    echo "mode=open-file"
    echo "target=${target_file}"
    echo "opener=${opener}"

    # shellcheck disable=SC2086
    launch_detached "/tmp/mide_open_file.log" ${opener} "${target_file}"
    ;;

  launch-program)
    if [[ $# -lt 1 ]]; then
      echo "error=missing_program"
      usage
      exit 2
    fi

    echo "timestamp_utc=$(now_utc)"
    echo "mode=launch-program"
    echo "program=$1"

    launch_detached "/tmp/mide_launch_program.log" "$@"
    ;;

  *)
    echo "error=invalid_mode"
    echo "mode=${mode}"
    usage
    exit 2
    ;;
esac
