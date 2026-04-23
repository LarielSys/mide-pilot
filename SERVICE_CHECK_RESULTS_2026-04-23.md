# Service Verification Results (2026-04-23)

## Scope
Requested checks were run one-at-a-time for:
- `worker-frontend.service`
- `worker-backend.service`
- ports `5570` and `5555`

## Commands and Outputs

### 1) Check service status
Command:
```bash
systemctl --user status worker-frontend.service worker-backend.service
```
Output:
```text
Unit worker-frontend.service could not be found.
Unit worker-backend.service could not be found.

Command exited with code 4
```

### 2) Tail logs (last 30 lines each)
Command:
```bash
tail -30 ~/.local/share/systemd/user/worker-frontend.log 2>/dev/null || journalctl --user -u worker-frontend.service -n 30 --no-pager
```
Output:
```text
-- No entries --
```

Command:
```bash
tail -30 ~/.local/share/systemd/user/worker-backend.log 2>/dev/null || journalctl --user -u worker-backend.service -n 30 --no-pager
```
Output:
```text
-- No entries --
```

### 3) Verify ports (5570, 5555)
Command:
```bash
ss -tulpn | grep -E "5570|5555" || netstat -tulpn 2>/dev/null | grep -E "5570|5555"
```
Output:
```text
(no listeners found)
Command exited with code 1
```

### 4) Restart both services
Command:
```bash
systemctl --user restart worker-frontend.service worker-backend.service
```
Output:
```text
Failed to restart worker-frontend.service: Unit worker-frontend.service not found.
Failed to restart worker-backend.service: Unit worker-backend.service not found.

Command exited with code 5
```

### 5) Verify they came up
Command:
```bash
systemctl --user status worker-frontend.service worker-backend.service
```
Output:
```text
Unit worker-frontend.service could not be found.
Unit worker-backend.service could not be found.

Command exited with code 4
```

## Additional discovery
Command:
```bash
systemctl --user list-unit-files --type=service | grep -Ei "frontend|backend|worker|customide|site_kb|ngrok|code-server" || true
```
Output:
```text
ngrok-site-kb.service                                 enabled   enabled
worker-mtask-autopilot.service                        enabled   enabled
```

## Conclusion
- `worker-frontend.service` and `worker-backend.service` are not installed as user systemd units on this host.
- No process is listening on ports `5570` or `5555`.
- Existing relevant user services are `worker-mtask-autopilot.service` and `ngrok-site-kb.service`.
