window.CUSTOMIDE_CONFIG = {
  backendBaseUrl: "http://127.0.0.1:5555",
  backendCandidates: [
    "http://127.0.0.1:5555",
    "http://localhost:5555"
  ],
  refreshIntervalMs: 2500,
  localStatePaths: {
    status: "../../state/worker_autopilot_status.json",
    events: "../../state/worker_autopilot_events.log",
    tokens: "../TOKEN_COUNTER_TASKS.txt",
    hardReset: "../../state/cockpit_hard_reset_request.json"
  },
  workerServicesPath: "../../config/worker1_services.json"
};
