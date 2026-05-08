# MTASK-2016 Website Chat Fix (Private)

## Objective
Connect the website chat page to Ubuntu Ollama through the local bridge for local testing modes.

## File Patched
- larielsystems/chat.html

## Changes
- Treat file:// as local mode.
- Route local mode to http://127.0.0.1:8082/api/cockpit/act.
- Use ngrok header only for remote proxy requests.

## Verification
- file:///C:/AI Assistant/larielsystems/chat.html
  - prompt: reply with one word: online
  - response: online
- http://localhost:8080/larielsystems/chat.html
  - prompt: reply with one word: online
  - response: Online.

## Notes
- Continuous git scan remains active per operator instruction.
- Keep listening until operator confirms complete.
