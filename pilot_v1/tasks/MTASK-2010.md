# MTASK-2010 Local Protocol Index (Private)

## Purpose
This local-private MTASK makes the autonomous workflow protocol directly accessible through MTASK reads.

## Protocol File
- pilot_v1/OLLAMA_AUTONOMOUS_MTASK_PROTOCOL.md

## What This Covers
- How Windows cockpit plans and reads MTASKs.
- How Ubuntu worker selects dispatchable MTASKs.
- Full autonomous execution loop with evidence requirements.
- Privacy and dispatch boundaries for local-only context tasks.
- Tunnel policy and required Ubuntu Ollama models.

## Retrieval
Use cockpit prompts such as:
- read mtask 2010 with md
- read mtask 2010 and 2009 with md
- read it

## Privacy Rules
- Do not dispatch to ubuntu-worker-01.
- Do not push this task to remote git unless explicitly approved.
- Do not mirror this context to room chat.
