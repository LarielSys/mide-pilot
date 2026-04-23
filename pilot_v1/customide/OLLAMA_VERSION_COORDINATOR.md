# Ollama Version Coordinator

## Goal
Keep Ollama runtime version aligned between Windows and Ubuntu Worker 1 so shared LLM behavior is reproducible.

## Canonical Version File
- Path: `pilot_v1/config/ollama_version.txt`
- This file is the contract value for local parity checks.

## Verification Commands
### Ubuntu Worker 1
```bash
ollama --version
cat ~/mide-pilot/pilot_v1/config/ollama_version.txt
```

### Windows
```powershell
Invoke-RestMethod http://localhost:11434/api/version
Get-Content c:\AI Assistant\MIDE\pilot_v1\config\ollama_version.txt
```

## Contract Rule
- If Ubuntu or Windows runtime version differs from `ollama_version.txt`, treat as mismatch and halt architecture-forward MTASK execution until reconciled.

## Update Procedure
1. Update/confirm Ollama on both systems.
2. Write canonical value to `pilot_v1/config/ollama_version.txt`.
3. Re-run validation commands on both systems.
4. Continue next MTASK only after parity is verified.
