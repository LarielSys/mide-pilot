# COTRN00C vs SBNPROGRAM2: Heuristic Validation Report

## Executive Summary

Two COBOL programs analyzed to validate extraction heuristics:
- **COTRN00C**: CICS transaction program (CardDemo) - 699 lines
- **SBNPROGRAM2**: Batch report program - 137 lines

**Finding**: Current heuristics designed for CICS naming patterns fail on batch programs. Root cause: Program type variance + keyword capture bug.

## Program Comparison

| Aspect | COTRN00C (CICS) | SBNPROGRAM2 (Batch) |
|--------|------------------|---------------------|
| **Program Type** | Interactive transaction | Sequential batch report |
| **Entry Point** | MAIN-PARA | 10-CONTROL-MODULE |
| **Main Loop** | IF/THEN/ELSE + EVALUATE | PERFORM UNTIL + READ/AT END |
| **I/O Method** | SEND/RECEIVE MAP (CICS) | READ/WRITE file (sequential) |
| **Cross-Module** | XCTL PROGRAM calls | (none) |
| **Processing Order** | Flag-driven branching | Sequential paragraphs |
| **Paragraph Naming** | Functional (PROCESS-*, SEND-*) | Numeric (10-, 20-, 30-...) |
| **Control Logic** | Transaction routing | Warehouse break groups |

## Extraction Results Comparison

### COTRN00C Extraction
```
Extracted:
  Entry:       MAIN-PARA ✓
  Process:     RETURN-TO-PREV-SCREEN ✗ (should be PROCESS-PAGE-FORWARD)
  Output:      RETURN-TO-PREV-SCREEN ✗ (should be SEND-TRNLST-SCREEN)
  Dependencies: [] ✗ (should include COSGN00C, COTRN01C, COMEN01C)
  Files:       TRANSACT ✓
  Guards:      [TRANSACT-EOF, ERR-FLG, ...] ✓
  Routines:    16 ✓
```

**Issue**: Heuristic prioritizes RETURN-* routines (routing) over PROCESS-* (business logic)

### SBNPROGRAM2 Extraction
```
Extracted:
  Entry:       FILE-CONTROL ✗ (should be 10-CONTROL-MODULE)
  Process:     UNTIL ✗ (should be 40-MAIN-ROUTINE)
  Output:      UNTIL ✗ (should be 100-WRITE-LINE)
  Dependencies: [EMPLOYEE-RECORD-FILE, SALARY-REPORT-FILE] ✓
  Files:       ✓
  Guards:      [EOF, warehouse break] ✓
  Routines:    2 ✗ (should be 11)
```

**Issues**: 
1. Keywords captured instead of routine names (UNTIL from PERFORM UNTIL)
2. FILE-CONTROL picked because it's first major section
3. Routine extraction regex not filtering for valid paragraph identifiers

## Root Cause Analysis

### Issue 1: Keyword Capture in Process/Output Selection

**Current Flow**:
```
analyze_cobol(code) 
  → extract_list(code, regex, limit)
    → Finds all matches for paragraph pattern
    → Returns PROCESS-PAGE-FORWARD, PERFORM, UNTIL, IF, etc.
  → Heuristic selects "major" routine
    → UNTIL matches loop keyword, selected as process
```

**Problem**: `extract_list()` returns keywords, not just paragraph names

**Fix**: Validate extracted names are in `@@PROCEDURE DIVISION` context and match paragraph pattern `^       [A-Z][A-Z0-9-]{1,32}\.$`

### Issue 2: Naming Pattern Assumptions

**Current Heuristic**:
```python
if para.name.startswith('PROCESS-'):
    score = 100
elif para.name.startswith('RETURN-'):
    score = 50
```

**Problem**: Assumes PROCESS-* pattern. SBNPROGRAM2 uses 10-, 40-, etc.

**Fix**: Add numeric pattern support:
```python
def is_numeric_paragraph(name):
    return re.match(r'^\d{2,3}-\w+$', name)

# For numeric programs: prioritize by position in code
if is_numeric_paragraph(para.name):
    return numeric_heuristic(paragraphs)
else:
    return functional_heuristic(paragraphs)
```

### Issue 3: Entry Point Detection

**Current**:
```python
entry = "MAIN-PARA"  # Always hardcoded
```

**Problem**: Works for CardDemo, fails for batch programs with numeric labels

**Fix**: Detect entry point from control flow:
```python
# Entry is: first PROCEDURE DIVISION paragraph OR
# paragraph that PERFORMS other main routines (10-*, MAIN-*)
if first_para.name.startswith(('MAIN', '10-', '00-')):
    return first_para.name
```

### Issue 4: Keyword vs Routine Name Confusion

**Current Extraction**:
```
regex matches: ["PERFORM", "UNTIL", "PROCEDURE", "READ", "WRITE", ...]
```

**Problem**: Keywords mixed with routine names

**Fix**: Two-phase extraction:
1. **Phase 1**: Extract all paragraph names from lines ending with `.`
2. **Phase 2**: Match paragraph names against known patterns

## Solution: Multi-Pattern Heuristic

### Pattern A: Functional Naming (COTRN00C style)
```
Entry:    Always MAIN-PARA (special case)
Process:  PROCESS-* > PAGE-* > *-KEY-* > others
Output:   SEND-* > RECEIVE-* > WRITE-* > others
Exclude:  RETURN-*, TO-*, POPULATE-*
```

### Pattern B: Numeric Ordering (SBNPROGRAM2 style)
```
Entry:    First paragraph (10-, MAIN-, or PROCEDURE DIVISION start)
Process:  First major routine (20-, 30-, 40-...) that has PERFORM UNTIL or READ
Output:   Routine containing WRITE (batch) or SEND (CICS)
Logic:    Examine PERFORM targets to infer structure
```

### Pattern C: Semantic Labels (future)
```
Entry:    *-CONTROL-*, MAIN-*, START-*
Process:  *-ROUTINE-*, MAIN-LOGIC-*, *-PROCESS-*
Output:   *-OUTPUT-*, *-WRITE-*, REPORT-*
```

## Implementation Roadmap

### Phase 1: Fix Regex (HIGH PRIORITY)
**Goal**: Eliminate keyword capture in extract_list()  
**Change**: Filter results to valid paragraph identifiers in PROCEDURE DIVISION  
**Impact**: Both COTRN00C and SBNPROGRAM2 improvement expected

### Phase 2: Detect Program Type
**Goal**: Distinguish CICS vs Batch vs Other  
**Detection**:
- CICS: Has EXEC CICS, SEND MAP, RECEIVE MAP, EIBAID, XCTL
- Batch: Has PERFORM UNTIL, READ/AT END, WRITE, control breaks
- Other: (future)
**Impact**: Select appropriate heuristic pattern

### Phase 3: Implement Multi-Pattern Heuristics
**Goal**: Support both functional and numeric naming  
**Approach**:
- Analyze paragraph names in order of appearance
- If all start with digits: apply numeric pattern
- If all have functional prefixes: apply functional pattern
- Fallback: apply generic pattern
**Impact**: Handle variety of COBOL styles

### Phase 4: Validate on 5+ Programs
**Goal**: Ensure heuristics generalize  
**Test Set**: COTRN00C, SBNPROGRAM2, COSGN00C, COCRDLIC, BNK1DCS  
**Success Criteria**: Entry/Process/Output correctly identified on 90%+ of programs

## Testing Strategy

### Unit Tests (Backend)
```python
def test_extract_no_keywords():
    """Ensure extract_list filters out keywords"""
    code = "PERFORM UNTIL EOF ... END-PERFORM."
    result = extract_list(code, regex, limit)
    assert "UNTIL" not in result
    assert "PERFORM" not in result

def test_numeric_paragraph_detection():
    """Detect numeric naming pattern"""
    assert is_numeric_paragraph("10-CONTROL-MODULE")
    assert is_numeric_paragraph("40-MAIN-ROUTINE")
    assert not is_numeric_paragraph("PROCESS-DATA")

def test_program_type_detection():
    """Identify CICS vs Batch"""
    cics_code = "EXEC CICS SEND MAP(...) END-EXEC"
    assert detect_program_type(cics_code) == "CICS"
    
    batch_code = "PERFORM UNTIL EOF READ FILE..."
    assert detect_program_type(batch_code) == "BATCH"

def test_entry_selection():
    """Select correct entry point"""
    assert select_entry(cotrn00c_paragraphs) == "MAIN-PARA"
    assert select_entry(sbnprogram2_paragraphs) == "10-CONTROL-MODULE"
```

### Integration Tests
1. **COTRN00C**: Should extract Entry ✓, Process (improved), Output (improved), Dependencies ✗→✓
2. **SBNPROGRAM2**: Should extract all major components correctly
3. **Regression**: COTRN00C must not regress in existing passing criteria

## Success Metrics

| Metric | Current | Target | COTRN00C | SBNPROGRAM2 |
|--------|---------|--------|----------|-------------|
| Entry Correct | 50% | 100% | ✓ | ✗→✓ |
| Process Correct | 0% | 100% | ✗→✓ | ✗→✓ |
| Output Correct | 0% | 100% | ✗→✓ | ✗→✓ |
| Dependencies Correct | 50% | 100% | ✗→✓ | ✓ |
| No Keyword Artifacts | 0% | 100% | ✗→✓ | ✗→✓ |

## Files Modified

- `larielsystems/backend/main.py` - Fixes to extract_list(), new heuristics
- `MIDE/carddemo_rebuild_v1/COTRN00C/analysis.json` - Baseline
- `MIDE/carddemo_rebuild_v1/SBNPROGRAM2/analysis.json` - Validation test
- `MIDE/carddemo_rebuild_v1/README.md` - Updated with findings

## Timeline

- **Now**: Bug fix for keyword capture
- **Next**: Program type detection
- **Then**: Multi-pattern heuristics
- **Final**: Validation on 5+ programs + batch processing all 44 CardDemo programs

---

**Document Date**: 2026-04-24  
**Programs Analyzed**: 2 (COTRN00C, SBNPROGRAM2)  
**Heuristics Version**: v0.2 (post-validation)  
**Status**: REFINEMENT IN PROGRESS
