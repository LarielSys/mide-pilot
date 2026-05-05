# MOSS Format Bridge: v2.0 Architecture → COBOL Direct Extraction

## Conceptual Bridge

MOSS v2.0 was designed to capture **semantic architecture specifications** for abstract systems. Our task is to extract **equivalent semantic signals** directly from COBOL source code, bypassing the need for intermediate `.moss` spec files.

### MOSS v2.0 Input Example (.moss file)
```
@MOSS: CBSA_ODCS_BNK1DCS_Execution_v1
@R: system_architecture

// Semantic systems (named components)
systems:
  MainTransaction:
    role: "transaction entry point"
    type: "CICS transaction"
    entry: "A010"
  
  ProcessCustomer:
    role: "main business logic"
    type: "data retrieval and validation"
    entry: "PROCESS-MAP"
  
  OutputScreen:
    role: "customer data display"
    type: "screen output handler"
    entry: "UNPROT-CUST-DATA"

// Interfaces (protocol contracts)
interfaces:
  TransactionProtocol:
    semantics: ["EIBAID routing", "MAP send/receive"]
  
  FileIOSemantics:
    semantics: ["READ with AT END flag", "WRITE with line count"]

// Dependencies (cross-module references)
dependencies:
  - calls: [COSGN00C, COTRN01C, COMEN01C]
    type: "XCTL program transfer"
```

### COBOL Source Equivalent
```cobol
       IDENTIFICATION DIVISION.
       PROGRAM-ID. COTRN00C.
       
       PROCEDURE DIVISION.
       MAIN-PARA.                        *> Entry point (A010 analog)
           IF EIBCALEN = 0
               PERFORM RETURN-TO-PREV-SCREEN
           ELSE
               PERFORM RECEIVE-TRNLST-SCREEN
               EVALUATE EIBAID
                   WHEN DFHENTER
                       PERFORM PROCESS-ENTER-KEY
                   WHEN DFHPF3
                       MOVE 'COMEN01C' TO CDEMO-TO-PROGRAM
                       EXEC CICS XCTL PROGRAM(CDEMO-TO-PROGRAM) END-EXEC
               END-EVALUATE
           END-IF.
       
       PROCESS-ENTER-KEY.               *> Process logic (PROCESS-MAP analog)
           PERFORM PROCESS-PAGE-FORWARD.
       
       PROCESS-PAGE-FORWARD.            *> Main business logic
           PERFORM STARTBR-TRANSACT-FILE.
           PERFORM READNEXT-TRANSACT-FILE.
       
       SEND-TRNLST-SCREEN.              *> Output handler (UNPROT-CUST-DATA analog)
           EXEC CICS SEND MAP('COTRN0A') ERASE CURSOR END-EXEC.
       
       RECEIVE-TRNLST-SCREEN.
           EXEC CICS RECEIVE MAP('COTRN0A') INTO(COTRN0AI) END-EXEC.
       
       STARTBR-TRANSACT-FILE.           *> File I/O (READ with cursor)
           EXEC CICS STARTBR DATASET('TRANSACT') RIDFLD(TRAN-ID) END-EXEC.
```

## Mapping Matrix: MOSS Concepts → COBOL Extraction

| MOSS Concept | MOSS v2.0 Element | COBOL Extraction Point | Signal Extracted |
|---|---|---|---|
| **Entry System** | `systems[MainTransaction].entry` | Paragraph `MAIN-PARA` | `entry: "MAIN-PARA"` |
| **Process System** | `systems[ProcessCustomer].entry` | `PROCESS-*` paragraphs | `process: "PROCESS-PAGE-FORWARD"` |
| **Output System** | `systems[OutputScreen].entry` | `SEND-*` / `RECEIVE-*` paragraphs | `output: "SEND-TRNLST-SCREEN"` |
| **Cross-Module Deps** | `dependencies[].calls[]` | `EXEC CICS XCTL PROGRAM(...)` | `dependencies: ["COSGN00C", "COTRN01C", "COMEN01C"]` |
| **File I/O Semantics** | `interfaces[FileIOSemantics].semantics` | `EXEC CICS STARTBR/READ*/ENDBR` | `guards: ["TRANSACT-EOF"]` |
| **Transaction Protocol** | `interfaces[TransactionProtocol].semantics` | `EVALUATE EIBAID WHEN ...` | `signals.has_branches: true` |
| **Routine Semantics** | `systems[*].role` | Procedure paragraph name prefix | Inferred from naming convention |
| **Constraints** | `runtime_constraints[]` | Flag-driven guards (88-level) | `guards: ["TRANSACT-EOF", ...]` |

## Extraction Algorithm

### Phase 1: Paragraph Identification
```python
# Input: COBOL source lines
# Output: {name: str, line_range: (int, int), type: str}

for line in cobol_source:
    if matches(r'^       ([A-Z][A-Z0-9-]{1,32})\.'):
        # Entry point paragraphs (SECTION level)
        if name in ['MAIN-PARA', 'IDENTIFICATION DIVISION']:
            paragraph_type = 'ENTRY'
        # Process paragraphs
        elif name.startswith(('PROCESS-', 'PAGE-')):
            paragraph_type = 'PROCESS'
        # Output paragraphs
        elif name.startswith(('SEND-', 'RECEIVE-', 'POPULATE-')):
            paragraph_type = 'OUTPUT'
        # File I/O paragraphs
        elif name.startswith(('START', 'READ', 'END', 'WRITE')):
            paragraph_type = 'IO'
        # Default
        else:
            paragraph_type = 'UTILITY'
```

### Phase 2: Dependency Extraction
```python
# Input: Paragraph content (lines between . delimiters)
# Output: {type: str, targets: list[str]}

for paragraph in paragraphs:
    # CICS XCTL programs
    xctl_matches = findall(r'EXEC CICS XCTL PROGRAM\([\'"]?([A-Z0-9-]+)[\'"]?\)', paragraph)
    if xctl_matches:
        dependencies['programs'].extend(xctl_matches)
    
    # File/Dataset references
    file_matches = findall(r'DATASET\s*\(\s*[\'"]?(\w+)[\'"]?\)', paragraph)
    if file_matches:
        dependencies['files'].extend(file_matches)
    
    # CICS operations
    cics_ops = findall(r'EXEC CICS (\w+)', paragraph)
    if cics_ops:
        dependencies['cics'].extend(cics_ops)
```

### Phase 3: Guard Extraction
```python
# Input: Full COBOL source
# Output: {flag_name: str, type: str, values: list[str]}

for line in cobol_source:
    # 88-level condition names
    if matches(r'^\s+88\s+([A-Z0-9-]+)\s+VALUE'):
        guard_name = captured_group(1)
        guards.append(guard_name)
    
    # EVALUATE conditions
    if matches(r'EVALUATE\s+(\w+)'):
        guarded_var = captured_group(1)
        guards.add_context(guarded_var, 'branch')
    
    # IF conditions
    if matches(r'IF\s+(.+?)(?:THEN|$)'):
        condition = captured_group(1)
        guards.add_context(condition, 'conditional')
```

### Phase 4: Heuristic Selection
```python
def select_process_routine(paragraphs):
    """Prioritize PROCESS-* > PAGE-* > *-KEY > Generic"""
    scores = {}
    for para in paragraphs:
        if para.name.startswith('PROCESS-'):
            scores[para] = 100
        elif para.name.startswith('PAGE-'):
            scores[para] = 80
        elif para.name.endswith('-KEY'):
            scores[para] = 70
        elif para.type == 'UTILITY':
            scores[para] = 0
        else:
            scores[para] = 50
    return max(scores, key=scores.get)

def select_output_routine(paragraphs):
    """Prioritize SEND-* > RECEIVE-* > POPULATE-HEADER > Generic"""
    scores = {}
    for para in paragraphs:
        if para.name.startswith('SEND-'):
            scores[para] = 100
        elif para.name.startswith('RECEIVE-'):
            scores[para] = 90
        elif para.name == 'POPULATE-HEADER-INFO':
            scores[para] = 80
        elif para.name.startswith(('RETURN-', 'TO-')):
            scores[para] = -50  # Exclude routing
        else:
            scores[para] = 50
    return max(scores, key=scores.get)
```

## MOSS-Compatible Output Format

After extraction, generate a MOSS-compatible spec file for each program:

```moss
@MOSS: COTRN00C_Extracted_v1
@R: cobol_program_architecture

// Extracted from: aws-mainframe-modernization-carddemo/app/cbl/COTRN00C.cbl
// Lines: 699
// Extracted: 2026-04-24T23:17:28Z

systems:
  TransactionEntry:
    role: "CICS transaction entry point for transaction listing"
    entry: "MAIN-PARA"
    type: "control_flow"
  
  TransactionListing:
    role: "paginated transaction data retrieval and population"
    entry: "PROCESS-PAGE-FORWARD"
    type: "business_logic"
  
  ScreenDisplay:
    role: "transaction list screen output handler"
    entry: "SEND-TRNLST-SCREEN"
    type: "io_handler"
  
  FileAccess:
    role: "sequential transaction file navigation"
    entry: "STARTBR-TRANSACT-FILE"
    type: "file_io"

interfaces:
  CICSTransactionProtocol:
    protocol: "DFHAID key routing with EIBAID evaluation"
    semantics: ["ENTER routes to PROCESS-ENTER-KEY", "PF3 routes to COMEN01C", "PF7/PF8 for pagination"]
  
  SequentialFileIO:
    protocol: "keyed browse with STARTBR/READNEXT/READPREV/ENDBR"
    semantics: ["TRANSACT-EOF flag controls loop termination", "RIDFLD used for key-based positioning", "READNEXT advances cursor"]

dependencies:
  - xctl_programs: [COSGN00C, COTRN01C, COMEN01C]
    via: "CDEMO-TO-PROGRAM variable in PROCESS-ENTER-KEY and RETURN-TO-PREV-SCREEN"
  - file_datasets: [TRANSACT]
    via: "EXEC CICS STARTBR/READNEXT/READPREV on WS-TRANSACT-FILE"
  - cics_operations: [SEND, RECEIVE, STARTBR, READNEXT, READPREV, ENDBR, XCTL, RETURN]

guards:
  TRANSACT-EOF:
    type: "file_end_condition"
    values: ["Y (EOF reached)", "N (more records)"]
    triggers: ["READNEXT END-OF-FILE", "Page limit reached"]
  
  ERR-FLG:
    type: "error_flag"
    values: ["Y (error occurred)", "N (normal flow)"]
    triggers: ["CICS exception response", "Invalid input"]

signals:
  lines: 699
  routines: 16
  has_loops: true
  has_branches: true
  has_cics: true
  has_cross_module: true
  complexity_score: 18
```

## Validation Approach

For each extracted program:

1. **Compare Entry** with manual review: Always MAIN-PARA ✓
2. **Validate Process** against code flow: Should match business logic path
3. **Confirm Output** against SEND/RECEIVE paragraphs: Should match screen handler
4. **Verify Dependencies** against XCTL calls: Must extract all cross-module targets
5. **Check Guards** against all conditions: Must identify all 88-level flags

## Next: Batch Processing

Once heuristics are validated on 3-5 programs, generate `.moss` specs for all 44 CardDemo programs:

```python
for cbl_file in carddemo_cbl_files:
    extraction = analyze_cobol(cbl_file)
    moss_spec = generate_moss_spec(extraction)
    save_to(f'specs/{program_id}.moss', moss_spec)
    generate_visualization(extraction, f'gui/{program_id}.html')
```

Result: Complete semantic architecture map of CardDemo ecosystem.
