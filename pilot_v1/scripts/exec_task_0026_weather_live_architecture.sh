#!/usr/bin/env bash
set -euo pipefail

WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
SPEC_ROOT="${HOME}/mide-pilot/pilot_v1/specs/weather_live_compare"
MOSS_FILE="${SPEC_ROOT}/weather_live_architecture.moss"
API_FILE="${SPEC_ROOT}/weather_compare_api_contract.json"
NOTES_FILE="${SPEC_ROOT}/integration_notes.txt"

mkdir -p "${SPEC_ROOT}"

echo "task=MTASK-0026"
echo "worker_name=${WORKER_NAME}"
echo "worker_id=${WORKER_ID}"
echo "spec_root=${SPEC_ROOT}"

cat >"${MOSS_FILE}" <<'EOF'
@MOSS:Weather_Live_Compare_Architecture
@R:~/mide-pilot/pilot_v1/specs/weather_live_compare/

systems:

  IDE_GUI_Windows:
    role: user-facing live interface in IDE
    runtime: windows-main
    depends_on: Worker1_Weather_API, Result_Contract
    inputs: city_a, city_b
    outputs: comparison_view, status_badge

  Worker1_Weather_API:
    role: authoritative weather comparison service
    runtime: ubuntu-worker-01
    transport: HTTP_JSON
    endpoint: /api/weather/compare
    depends_on: Weather_Provider_Adapter, Comparison_Engine, Result_Contract
    outputs: normalized_comparison_payload

  Weather_Provider_Adapter:
    role: fetch and normalize external weather provider data
    runtime: ubuntu-worker-01
    depends_on: External_Weather_Source
    outputs: weather_city_a, weather_city_b

  Comparison_Engine:
    role: compute differences and verdict
    runtime: ubuntu-worker-01
    depends_on: weather_city_a, weather_city_b
    outputs: temperature_delta_c, condition_delta, humidity_delta, wind_delta, summary

  Result_Contract:
    role: shared schema between GUI and worker API
    format: JSON
    request_fields: city_a, city_b, units
    response_fields: request_id, timestamp_utc, city_a, city_b, metrics, summary, source

  Observability_Channel:
    role: visibility for live requests and execution status
    runtime: shared
    depends_on: IDE_GUI_Windows, Worker1_Weather_API
    outputs: request_log, response_log, health_state

dependencies:
  - IDE_GUI_Windows -> Worker1_Weather_API
  - Worker1_Weather_API -> Weather_Provider_Adapter
  - Worker1_Weather_API -> Comparison_Engine
  - Worker1_Weather_API -> Result_Contract
  - IDE_GUI_Windows -> Result_Contract
  - Observability_Channel -> IDE_GUI_Windows
  - Observability_Channel -> Worker1_Weather_API

runtime_constraints:
  - live_communication_required: true
  - transport_mode: synchronous_http
  - gui_must_not_use_git_task_loop: true
EOF

cat >"${API_FILE}" <<'EOF'
{
  "service": "worker1-weather-compare",
  "transport": "http-json",
  "base_path": "/api/weather",
  "endpoints": [
    {
      "name": "health",
      "method": "GET",
      "path": "/health",
      "response": {
        "status": "ok",
        "worker_id": "ubuntu-worker-01",
        "timestamp_utc": "ISO8601"
      }
    },
    {
      "name": "compare",
      "method": "POST",
      "path": "/compare",
      "request": {
        "city_a": "San Diego",
        "city_b": "New York City",
        "units": "metric"
      },
      "response": {
        "request_id": "string",
        "timestamp_utc": "ISO8601",
        "city_a": {
          "name": "string",
          "temp_c": 0,
          "humidity_pct": 0,
          "wind_kph": 0,
          "condition": "string"
        },
        "city_b": {
          "name": "string",
          "temp_c": 0,
          "humidity_pct": 0,
          "wind_kph": 0,
          "condition": "string"
        },
        "comparison": {
          "temp_delta_c": 0,
          "humidity_delta_pct": 0,
          "wind_delta_kph": 0,
          "condition_match": false,
          "summary": "string"
        },
        "source": "provider-name"
      }
    }
  ]
}
EOF

cat >"${NOTES_FILE}" <<'EOF'
Weather Live Compare Integration Notes

1) GUI in IDE (Windows) calls Worker1 live compare endpoint over HTTP.
2) Worker1 owns provider calls and comparison logic.
3) Shared JSON contract decouples frontend from provider shape.
4) MOSS schematic is dependency-first, not UI-first.
5) Orchestrator mtasks are for build/deploy/change control, not live request transport.
EOF

echo "generated_moss=${MOSS_FILE}"
echo "generated_api_contract=${API_FILE}"
echo "generated_notes=${NOTES_FILE}"
echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
