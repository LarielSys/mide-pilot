#!/usr/bin/env bash
set -euo pipefail

VERSION="1.0.0"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PKG_ROOT="${ROOT_DIR}/package/linux"
BUILD_DIR="${PKG_ROOT}/build"
STAGE_DIR="${BUILD_DIR}/cbsa-viz-linux-${VERSION}"
PAYLOAD_DIR="${STAGE_DIR}/payload"
ARCHIVE_PATH="${BUILD_DIR}/cbsa-viz-linux-${VERSION}.tar.gz"

rm -rf "$STAGE_DIR"
mkdir -p "$PAYLOAD_DIR/gui" "$PAYLOAD_DIR/specs" "$PAYLOAD_DIR/docs"

copy_gui() {
  cp "${ROOT_DIR}/gui/$1" "${PAYLOAD_DIR}/gui/$1"
}

copy_gui "cbsa_bnkmenu_visualization.html"
copy_gui "cbsa_odcs_execution_visualization.html"
copy_gui "cbsa_odac_execution_visualization.html"
copy_gui "cbsa_occs_execution_visualization.html"
copy_gui "cbsa_ocac_execution_visualization.html"
copy_gui "cbsa_ouac_execution_visualization.html"
copy_gui "cbsa_ocra_execution_visualization.html"
copy_gui "cbsa_otfn_execution_visualization.html"
copy_gui "cbsa_occa_execution_visualization.html"
cp "${ROOT_DIR}/product_architecture_visuals.html" "${PAYLOAD_DIR}/product_architecture_visuals.html"

cp -r "${ROOT_DIR}/specs/cbsa_bnkmenu" "${PAYLOAD_DIR}/specs/"
cp -r "${ROOT_DIR}/specs/cbsa_odcs_execution" "${PAYLOAD_DIR}/specs/"
cp -r "${ROOT_DIR}/specs/cbsa_odac_execution" "${PAYLOAD_DIR}/specs/"
cp -r "${ROOT_DIR}/specs/cbsa_occs_execution" "${PAYLOAD_DIR}/specs/"
cp -r "${ROOT_DIR}/specs/cbsa_ocac_execution" "${PAYLOAD_DIR}/specs/"
cp -r "${ROOT_DIR}/specs/cbsa_ouac_execution" "${PAYLOAD_DIR}/specs/"
cp -r "${ROOT_DIR}/specs/cbsa_ocra_execution" "${PAYLOAD_DIR}/specs/"
cp -r "${ROOT_DIR}/specs/cbsa_otfn_execution" "${PAYLOAD_DIR}/specs/"
cp -r "${ROOT_DIR}/specs/cbsa_occa_execution" "${PAYLOAD_DIR}/specs/"

cp "${ROOT_DIR}/CBSA_PACKAGE_MANIFEST.json" "${PAYLOAD_DIR}/docs/"
cp "${ROOT_DIR}/CBSA_RELEASE_CHECKLIST.md" "${PAYLOAD_DIR}/docs/"
cp "${ROOT_DIR}/CBSA_SHIP_REPORT.md" "${PAYLOAD_DIR}/docs/"
cp "${ROOT_DIR}/CBSA_USER_GUIDE.md" "${PAYLOAD_DIR}/docs/"

cp "${PKG_ROOT}/scripts/install.sh" "${STAGE_DIR}/install.sh"
cp "${PKG_ROOT}/scripts/uninstall.sh" "${STAGE_DIR}/uninstall.sh"
chmod +x "${STAGE_DIR}/install.sh" "${STAGE_DIR}/uninstall.sh"

cat > "${STAGE_DIR}/README.md" <<EOF
# CBSA Visualization Linux Package

Version: ${VERSION}

## Install
\`\`\`bash
chmod +x install.sh
sudo ./install.sh --systemd
\`\`\`

## Run Without systemd
\`\`\`bash
sudo ./install.sh
/opt/cbsa-viz/run.sh
\`\`\`

## Open in Browser
- http://localhost:8765/gui/cbsa_bnkmenu_visualization.html
- http://localhost:8765/product_architecture_visuals.html

## Uninstall
\`\`\`bash
chmod +x uninstall.sh
sudo ./uninstall.sh
\`\`\`
EOF

mkdir -p "$BUILD_DIR"
rm -f "$ARCHIVE_PATH"
tar -czf "$ARCHIVE_PATH" -C "$BUILD_DIR" "cbsa-viz-linux-${VERSION}"

if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$ARCHIVE_PATH" > "${ARCHIVE_PATH}.sha256"
fi

echo "Package created: $ARCHIVE_PATH"
if [[ -f "${ARCHIVE_PATH}.sha256" ]]; then
  echo "Checksum created: ${ARCHIVE_PATH}.sha256"
fi
