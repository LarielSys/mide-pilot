# CardDemo MOSS Rebuild v1

## Overview
Conversion of MOSS v2.0 architecture specification compiler into a direct COBOL source code extraction system for AWS CardDemo banking demo programs.

**Goal**: Transform raw COBOL source → semantic extraction signals (entry/process/output/dependencies/guards) without intermediate `.moss` file layer.

## Directory Structure

```
carddemo_rebuild_v1/
├── README.md                        # This file - overview
├── MOSS_FORMAT_BRIDGE.md           # How MOSS v2.0 → COBOL extraction works
│
├── moss_v2_reference/              # Copy of original C:\Users\marco\OneDrive\Desktop\MOSS
│   ├── moss.py                     # MOSSCompiler v2.0 source code
│   ├── MOSS_FORMAT_SPECIFICATION_v2.md
│   ├── MOSS_INTEGRATION_GUIDE.md
│   ├── schematic_refs.moss         # Example .moss file
│   ├── REFERENCE.md                # How to use this reference
│   └── [tests, examples, ...]
│
├── specs/                           # Generated MOSS-compatible specs from COBOL extraction
│   └── [generated .moss files]
│
├── gui/                             # Visualizations and interactive mappings
│   └── [generated .html files]
│
├── extraction_logs/                 # Detailed logs from each program analysis
│   └── [program extraction traces]
│
├── COTRN00C/                        # First analyzed program
│   ├── analysis.json               # Extraction signals + issues
│   └── [artifacts from backend]
│
└── [program_folders]                # Individual program analysis (COSGN00C/, COCRDLIC/, etc.)
```

## Architecture Bridge: MOSS v2.0 → COBOL Direct Reader

### MOSS v2.0 Original Flow
```
.moss spec file (semantic language)
        ↓
    MOSSCompiler.load(filepath)
        ↓
    _parse_lines() → _auto_enrich_semantics()
        ↓
    Python dict output with:
    - systems (named components)
    - interfaces (protocol contracts)
    - actions (side effects)
    - runtime_constraints (ordered behaviors)
    - dependencies (cross-module references)
    - _moss_manual (metadata)
```

### New COBOL Direct Reader Flow
```
COBOL source code (.cbl file)
        ↓
    analyze_cobol(code, lines)
        ↓
    Extract via regex patterns:
    - Paragraphs (entry points / procedures)
    - PERFORM calls (control flow)
    - Files / DATASETS (I/O references)
    - CICS EXEC statements (cross-module calls)
    - Guard patterns (EVALUATE, IF, flags)
        ↓
    Heuristic selection:
    - Entry: MAIN-PARA (always)
    - Process: PROCESS-* > PAGE-* > KEY handlers
    - Output: SEND-* > RECEIVE-* > MAP operations
        ↓
    Output dict with:
    - entry (paragraph name)
    - process (business logic routine)
    - output (result/screen handler)
    - routines (list of all procedures)
    - dependencies (XCTL program targets)
    - guards (branch conditions)
    - signals (metadata: lines, has_loops, has_branches, etc.)
```

## CardDemo Program Characteristics

### Naming Conventions
- **Entry**: Always `MAIN-PARA`
- **Process**: `PROCESS-*`, `PAGE-FORWARD`, `PAGE-BACKWARD`, `*-ENTER-KEY`
- **Output**: `SEND-*`, `RECEIVE-*`, `POPULATE-*`
- **Routing**: `RETURN-*`, `RETURN-TO-PREV-SCREEN`, `TO-PROGRAM`
- **Utilities**: `INITIALIZE-*`, `POPULATE-HEADER-*`, `START*-FILE`, `READ*-FILE`, `END*-FILE`

### CICS Patterns
- **Screen I/O**: `EXEC CICS SEND MAP / RECEIVE MAP`
- **Data Files**: `EXEC CICS STARTBR / READNEXT / READPREV / ENDBR`
- **Program Transfer**: `EXEC CICS XCTL PROGRAM(name)`

### Key Signals to Capture
1. **Lines of Code**: Determine complexity tier
2. **Routine Count**: Complexity indicator
3. **Loop Presence**: PERFORM UNTIL / VARYING
4. **Branch Presence**: EVALUATE / IF statements
5. **CICS Calls**: Transaction server integration depth
6. **Cross-Module**: XCTL program references

## COTRN00C Analysis (Baseline Reference)

**File**: aws-mainframe-modernization-carddemo/app/cbl/COTRN00C.cbl  
**Lines**: 699  
**Type**: CICS Transaction List Handler

### Extracted Signals
```json
{
  "entry": "MAIN-PARA",
  "process": "RETURN-TO-PREV-SCREEN",  // ⚠️ Should be PROCESS-PAGE-FORWARD
  "output": "RETURN-TO-PREV-SCREEN",   // ⚠️ Should be SEND-TRNLST-SCREEN
  "routines": [
    "MAIN-PARA",
    "PROCESS-ENTER-KEY",
    "PROCESS-PAGE-FORWARD",
    "PROCESS-PAGE-BACKWARD",
    "POPULATE-TRAN-DATA",
    "INITIALIZE-TRAN-DATA",
    "RETURN-TO-PREV-SCREEN",
    "SEND-TRNLST-SCREEN",
    "RECEIVE-TRNLST-SCREEN",
    "POPULATE-HEADER-INFO",
    "STARTBR-TRANSACT-FILE",
    "READNEXT-TRANSACT-FILE",
    "READPREV-TRANSACT-FILE",
    "ENDBR-TRANSACT-FILE"
  ],
  "dependencies": [],  // ⚠️ Missing XCTL targets: COSGN00C, COTRN01C, COMEN01C
  "guards": ["TRANSACT-EOF"],
  "signals": {
    "language": "COBOL",
    "lines": 699,
    "routine_count": 14,
    "has_loops": true,
    "has_branches": true,
    "has_cross_module": true,
    "has_cics": true
  }
}
```

## Heuristic Refinements Needed

### 1. Process Routine Selection
**Current**: Picks first non-utility routine  
**Should**: Prioritize by pattern
```
PROCESS-* (if exists)  [Weight: 100]
PAGE-* (pagination)    [Weight: 80]
ENTER-KEY              [Weight: 70]
MAIN (non-entry)       [Weight: 50]
```

### 2. Output Routine Selection
**Current**: Same as process  
**Should**: Prioritize by I/O pattern
```
SEND-* (screen output)    [Weight: 100]
RECEIVE-* (input)         [Weight: 90]
POPULATE-HEADER (UI prep) [Weight: 80]
RETURN-TO-* (routing)     [Weight: -50, exclude]
```

### 3. Dependency Extraction
**Current**: Missing entirely  
**Should**: Extract from:
```regex
EXEC CICS XCTL PROGRAM\(['"]?([A-Z0-9-]+)['"]?\)
MOVE .* TO CDEMO-TO-PROGRAM  (if assigned XCTL target)
```

## Generated Outputs

### Per-Program Structure
Each analyzed program creates:
```
COTRN00C/
├── analysis.json       # Full extraction signals
├── cotrn00c.moss       # MOSS-compatible spec file (for validation)
├── extraction.log      # Detailed trace of regex matches
└── [GENERATED BY BACKEND]
    ├── index.html      # Interactive visualization
    ├── diagram.svg     # Entry → Process → Output flow
    ├── flow.txt        # Narrative description
    ├── dependency-map.txt
    ├── guards.txt
    └── developer-report.txt
```

### Reference Output URL
http://localhost:8083/generated/moss/20260424-231728-e50b3ea4/index.html

## Backend Integration

**File**: larielsystems/backend/main.py  
**Key Functions**:
- `analyze_cobol(code, lines)` - Extract COBOL structure
- `build_core_payload(analysis)` - Generate flow/dependency/guard text
- `build_tier_diagram(analysis, tier)` - SVG rendering
- Endpoint: POST `/api/moss/analyze` - Analysis only
- Endpoint: POST `/api/moss/compile` - Analysis + artifacts

## Session Progress

### Completed
- ✅ COTRN00C.cbl analyzed (699 lines)
- ✅ Entry point extraction working
- ✅ CICS call detection working
- ✅ Generated map rendering on localhost:8083
- ✅ Routing fix (mounted /generated before /)

### In Progress
- 🔄 Process routine heuristic refinement
- 🔄 Output routine selection accuracy
- 🔄 XCTL program dependency extraction

### Next Steps
1. Map 2-3 more programs (COSGN00C, COCRDLIC, COACTVWC) to validate patterns
2. Refine heuristics based on results
3. Generate MOSS-compatible spec files for each program
4. Build interactive three-pane visualizations (reference: CBSA ODCS)

## References

### Original MOSS
- **File**: C:\Users\marco\OneDrive\Desktop\MOSS\moss.py (v2.0)
- **Format**: `.moss` semantic specification language
- **API**: `MOSSCompiler.load(filepath, expected_manual)`

### MIDE Baseline
- **Specs**: c:\AI Assistant\MIDE\pilot_v1\specs\ (30 existing `.moss` files)
- **Visualization**: c:\AI Assistant\MIDE\pilot_v1\gui\cbsa_odcs_execution_visualization.html
- **Reference Program**: CBSA_ODCS_BNK1DCS (known working extraction)

### CardDemo Repository
- **Source**: c:\AI Assistant\aws-mainframe-modernization-carddemo\app\cbl\
- **Programs**: 44 COBOL files
- **Pattern**: All transaction/utility programs for banking demo

## Contact & Notes
Built incrementally with user validation.  
Focus on correctness over features.  
Step-by-step refinement of heuristics.
