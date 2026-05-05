#!/usr/bin/env bash
set -euo pipefail

PREFIX="/opt/cbsa-viz"

usage() {
  cat <<EOF
CBSA Visualization Uninstaller

Usage:
  ./uninstall.sh [--prefix PATH]

Options:
  --prefix PATH   Install location to remove (default: /opt/cbsa-viz)
  -h, --help      Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      PREFIX="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ "$PREFIX" == /opt/* ]] && [[ "${EUID}" -ne 0 ]]; then
  echo "Removing $PREFIX requires root. Re-run with sudo or use --prefix under your home directory."
  exit 1
fi

if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q '^cbsa-viz.service'; then
  systemctl disable --now cbsa-viz.service || true
  rm -f /etc/systemd/system/cbsa-viz.service
  systemctl daemon-reload
fi

rm -rf "$PREFIX"
rm -f /usr/local/bin/cbsa-viz || true

echo "Uninstall complete for prefix: $PREFIX"
