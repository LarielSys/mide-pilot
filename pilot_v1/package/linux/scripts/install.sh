#!/usr/bin/env bash
set -euo pipefail

VERSION="1.0.0"
PREFIX="/opt/cbsa-viz"
PORT="8765"
ENABLE_SYSTEMD="false"

usage() {
  cat <<EOF
CBSA Visualization Package Installer v${VERSION}

Usage:
  ./install.sh [--prefix PATH] [--port PORT] [--systemd]

Options:
  --prefix PATH   Install location (default: /opt/cbsa-viz)
  --port PORT     Local HTTP port (default: 8765)
  --systemd       Create and enable systemd service (requires root/systemd)
  -h, --help      Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      PREFIX="$2"
      shift 2
      ;;
    --port)
      PORT="$2"
      shift 2
      ;;
    --systemd)
      ENABLE_SYSTEMD="true"
      shift
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

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required but was not found."
  exit 1
fi

if [[ ! "$PORT" =~ ^[0-9]+$ ]] || [[ "$PORT" -lt 1 ]] || [[ "$PORT" -gt 65535 ]]; then
  echo "Invalid port: $PORT"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_DIR="${SCRIPT_DIR}/payload"

if [[ ! -d "$PAYLOAD_DIR" ]]; then
  echo "Payload directory not found: $PAYLOAD_DIR"
  exit 1
fi

if [[ "$PREFIX" == /opt/* ]] && [[ "${EUID}" -ne 0 ]]; then
  echo "Installing to $PREFIX requires root. Re-run with sudo or use --prefix under your home directory."
  exit 1
fi

mkdir -p "$PREFIX"
rm -rf "$PREFIX/app"
mkdir -p "$PREFIX/app"
cp -a "$PAYLOAD_DIR"/. "$PREFIX/app"/

cat > "$PREFIX/run.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
python3 -m http.server ${PORT} --directory "${PREFIX}/app"
EOF
chmod +x "$PREFIX/run.sh"

echo "PORT=${PORT}" > "$PREFIX/.env"

if [[ -w /usr/local/bin ]]; then
  cat > /usr/local/bin/cbsa-viz <<EOF
#!/usr/bin/env bash
exec "${PREFIX}/run.sh"
EOF
  chmod +x /usr/local/bin/cbsa-viz
fi

if [[ "$ENABLE_SYSTEMD" == "true" ]]; then
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "systemctl not found; skipping service setup."
  else
    cat > /etc/systemd/system/cbsa-viz.service <<EOF
[Unit]
Description=CBSA Visualization Local Web Server
After=network.target

[Service]
Type=simple
WorkingDirectory=${PREFIX}
ExecStart=/usr/bin/python3 -m http.server ${PORT} --directory ${PREFIX}/app
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now cbsa-viz.service
    echo "Systemd service enabled: cbsa-viz"
  fi
fi

echo ""
echo "Install complete."
echo "Open these URLs in a browser:"
echo "  http://localhost:${PORT}/gui/cbsa_bnkmenu_visualization.html"
echo "  http://localhost:${PORT}/product_architecture_visuals.html"
if [[ "$ENABLE_SYSTEMD" != "true" ]]; then
  echo ""
  echo "To run manually:"
  echo "  ${PREFIX}/run.sh"
fi
