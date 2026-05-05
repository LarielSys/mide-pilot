# CBSA MOSS Release Checklist

Release scope: CBSA BNKMENU and 8 action-route drilldowns only.

## 1. Artifact Completeness
- [x] BNKMENU architecture spec present.
- [x] BNKMENU visualization present.
- [x] ODCS spec + visualization.
- [x] ODAC spec + visualization.
- [x] OCCS spec + visualization.
- [x] OCAC spec + visualization.
- [x] OUAC spec + visualization.
- [x] OCRA spec + visualization.
- [x] OTFN spec + visualization.
- [x] OCCA spec + visualization.

## 2. Functional Wiring
- [x] BNKMENU drilldown links exist for all routes (ODCS, ODAC, OCCS, OCAC, OUAC, OCRA, OTFN, OCCA).
- [x] Details panel has drilldown entries for all linked routes.
- [x] Drilldown targets are relative links from BNKMENU visualization.

## 3. Quality Gates
- [x] No parse/errors reported on all CBSA specs and CBSA visualization files.
- [x] Visual layout remains house-style consistent (3-pane, dark tokenized style, top-aligned SVG).
- [x] Guard paths are represented on every drilldown page.

## 4. Scope and Governance
- [x] No cross-program semantic mixing outside explicit CBSA link targets.
- [x] Package manifest created: MIDE/pilot_v1/CBSA_PACKAGE_MANIFEST.json.
- [x] Entry point defined: MIDE/pilot_v1/gui/cbsa_bnkmenu_visualization.html.

## 5. Packaging Recommendation
- [x] Product package readiness: PASS for CBSA visualization package.
- [ ] Optional enhancement: add screenshot-based regression baseline for UI drift detection.
