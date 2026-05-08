# MTASK-2012 Chat Repair to Ubuntu Ollama (Private)

## Objective
Repair website chat connectivity so OLEGREEN routes to Ubuntu-hosted Ollama.

## Process (Network-First)
1. Confirm Ubuntu endpoint reachability.
2. Confirm required models on Ubuntu endpoint.
3. Apply bridge/startup routing updates.
4. Pause git-backed MTASK dispatch operations in cockpit.
5. Restart bridge and verify /api/connectors reports endpoint and git_paused=true.
6. Validate /api/cockpit/act chat reply path.

## Current State
- Endpoint reachable: http://192.168.1.21:11434
- Missing required models on Ubuntu for policy baseline:
  - qwen2.5-coder:7b
  - qwen2.5vl:7b
- Temporary blocker recorded until models are present.

## Commands to Run After Models Exist
- restart bridge via olegreen/restart_bridge.ps1
- verify connectors and ollama status from cockpit
- run chat smoke test prompt from UI

## Privacy Rules
- Do not dispatch to ubuntu-worker-01 from this MTASK.
- Do not push to remote git unless explicitly approved.
- Do not mirror this context to room chat.
