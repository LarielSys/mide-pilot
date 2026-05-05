# Linux Package Builder

This folder builds a portable Linux install package for the CBSA visualization product.

## Build
Run from this folder:

```bash
chmod +x build_linux_package.sh
./build_linux_package.sh
```

Output:
- build/cbsa-viz-linux-1.0.0.tar.gz
- build/cbsa-viz-linux-1.0.0.tar.gz.sha256 (if sha256sum available)

## Install on Target Linux Machine
1. Copy the tarball to the target machine.
2. Extract it.
3. Run install script.

```bash
tar -xzf cbsa-viz-linux-1.0.0.tar.gz
cd cbsa-viz-linux-1.0.0
chmod +x install.sh
sudo ./install.sh --systemd
```

Then open:
- http://localhost:8765/gui/cbsa_bnkmenu_visualization.html
- http://localhost:8765/product_architecture_visuals.html
