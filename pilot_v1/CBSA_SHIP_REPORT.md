# CBSA Ship Report

Date: 2026-04-23
Decision: SHIP (CBSA visualization package)

## Scope Verified
- Program scope: CBSA only.
- Router: BNKMENU.
- Route drilldowns covered: ODCS, ODAC, OCCS, OCAC, OUAC, OCRA, OTFN, OCCA.

## Verification Results
- Parse/error check: PASS on all CBSA specs, all CBSA visualization pages, and release artifacts.
- Drilldown wiring: PASS (8 of 8 BNKMENU targets linked and documented in details map).
- House-style consistency: PASS (3-pane layout, tokenized dark style, top-aligned scalable SVG).

## Release Artifacts
- Package manifest: MIDE/pilot_v1/CBSA_PACKAGE_MANIFEST.json
- Release checklist: MIDE/pilot_v1/CBSA_RELEASE_CHECKLIST.md
- Entry point: MIDE/pilot_v1/gui/cbsa_bnkmenu_visualization.html

## Residual Risks
- Source-program wording inconsistency exists in BNK1TFN COBOL error strings (mentions OCCS in return-failure text). Visualization models preserve operational flow and route identity (OTFN) but should not be treated as textual source correction.
- Optional: add screenshot baseline testing for visual regression control across future style updates.

## Packaging Recommendation
- Package now as product release for the CBSA MOSS visualization bundle.
