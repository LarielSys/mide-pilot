# CBSA Visualization Package User Guide

## 1. Purpose
This guide explains how to use the CBSA MOSS visualization package, review the architecture drilldowns, and run the release-readiness workflow.

Package scope:
- Program: CBSA
- Router: BNKMENU
- Route drilldowns: ODCS, ODAC, OCCS, OCAC, OUAC, OCRA, OTFN, OCCA

## 2. What Is Included
Core entrypoint:
- MIDE/pilot_v1/gui/cbsa_bnkmenu_visualization.html

Execution drilldowns:
- MIDE/pilot_v1/gui/cbsa_odcs_execution_visualization.html
- MIDE/pilot_v1/gui/cbsa_odac_execution_visualization.html
- MIDE/pilot_v1/gui/cbsa_occs_execution_visualization.html
- MIDE/pilot_v1/gui/cbsa_ocac_execution_visualization.html
- MIDE/pilot_v1/gui/cbsa_ouac_execution_visualization.html
- MIDE/pilot_v1/gui/cbsa_ocra_execution_visualization.html
- MIDE/pilot_v1/gui/cbsa_otfn_execution_visualization.html
- MIDE/pilot_v1/gui/cbsa_occa_execution_visualization.html

Contracts/specs:
- MIDE/pilot_v1/specs/cbsa_bnkmenu/architecture.moss
- MIDE/pilot_v1/specs/cbsa_odcs_execution/architecture.moss
- MIDE/pilot_v1/specs/cbsa_odac_execution/architecture.moss
- MIDE/pilot_v1/specs/cbsa_occs_execution/architecture.moss
- MIDE/pilot_v1/specs/cbsa_ocac_execution/architecture.moss
- MIDE/pilot_v1/specs/cbsa_ouac_execution/architecture.moss
- MIDE/pilot_v1/specs/cbsa_ocra_execution/architecture.moss
- MIDE/pilot_v1/specs/cbsa_otfn_execution/architecture.moss
- MIDE/pilot_v1/specs/cbsa_occa_execution/architecture.moss

Release artifacts:
- MIDE/pilot_v1/CBSA_PACKAGE_MANIFEST.json
- MIDE/pilot_v1/CBSA_RELEASE_CHECKLIST.md
- MIDE/pilot_v1/CBSA_SHIP_REPORT.md

Optional product architecture visuals page:
- MIDE/pilot_v1/product_architecture_visuals.html

## 3. Quick Start (Localhost)
### Option A: Open files directly
You can open the HTML files directly from your file explorer or editor.

### Option B: Run a local server (recommended)
From workspace root:
1. Run: python -m http.server 8765
2. Open: http://localhost:8765/MIDE/pilot_v1/gui/cbsa_bnkmenu_visualization.html
3. For product architecture diagrams, open: http://localhost:8765/MIDE/pilot_v1/product_architecture_visuals.html

## 4. How To Navigate the Visualizations
Each page has 3 panes:
1. Left pane: source-flow summary by step/guard.
2. Center pane: interactive SVG execution diagram.
3. Right pane: contextual details panel.

Interactions:
1. Hover on a node to highlight corresponding source-flow lines.
2. Read node semantics in the details pane.
3. Click drilldown nodes in BNKMENU to open route-specific pages.

## 5. Recommended Review Flow
1. Start at BNKMENU overview to confirm route map.
2. Open one route at a time and verify:
- entry and AID routing
- validation gate(s)
- subprogram links
- guard/failure paths
- return semantics
3. Repeat for all 8 routes.

## 6. Packaging Workflow
Use this sequence for a release cycle:
1. Scope lock:
- Confirm CBSA-only scope and active target set.
2. Completeness check:
- Verify all 8 route specs and pages exist.
3. Wiring check:
- Verify BNKMENU drilldowns for all routes.
4. Quality gate:
- Ensure no parse or validation errors in package files.
5. Artifact check:
- Verify manifest, checklist, and ship report are present.
6. Release decision:
- Ship only when checklist and ship report indicate PASS.

## 7. Security and Safety Model (Operational)
If running this as a product pipeline:
1. Execute analysis/compilation in isolated worker environments.
2. Use pinned toolchain/compiler images for repeatability.
3. Enforce command allowlists and policy gates.
4. Keep source mounts read-only when possible.
5. Restrict network egress by default.
6. Store keys/secrets in a vault and keep signed audit trails.

## 8. Troubleshooting
### Page does not render
1. Confirm localhost server is running.
2. Confirm URL path starts with /MIDE/pilot_v1/.
3. Hard-refresh browser tab.

### Mermaid diagram page does not load
1. Ensure internet access for CDN-based Mermaid module.
2. If blocked by policy, host Mermaid locally and update import path.

### Drilldown clicks do nothing
1. Verify file path names did not change.
2. Open browser developer tools and check for missing-file errors.

### Visual layout appears clipped
1. Increase browser zoom out level.
2. Use full-width window.
3. Confirm latest page version is loaded (hard refresh).

## 9. Roles and Usage
- Architects: use BNKMENU + route pages for end-to-end architecture validation.
- Engineers: use route pages for flow-level operational understanding.
- Release owners: use manifest/checklist/ship report for package sign-off.

## 10. Versioning Notes
Current package release:
- Version: 1.0.0
- Date: 2026-04-23
- Scope: CBSA BNKMENU + 8 drilldowns
