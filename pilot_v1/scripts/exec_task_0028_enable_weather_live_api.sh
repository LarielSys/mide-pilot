#!/usr/bin/env bash
set -euo pipefail

WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
SITE_SERVER="${HOME}/Documents/itheia-llm/site_kb_server.py"
PORT="8091"

if [[ ! -f "${SITE_SERVER}" ]]; then
  echo "error=site_server_not_found"
  echo "expected=${SITE_SERVER}"
  exit 1
fi

echo "task=MTASK-0028"
echo "worker_name=${WORKER_NAME}"
echo "worker_id=${WORKER_ID}"
echo "site_server=${SITE_SERVER}"

python3 - "${SITE_SERVER}" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="replace")

if '"/api/weather/compare"' in text and '"/api/weather/health"' in text:
    print("weather_routes_patch=already_present")
    sys.exit(0)

snippet = '''

# MTASK-0028: live weather compare endpoints for IDE GUI -> Worker1
def _weather_fetch_open_meteo(lat, lon):
    import json
    import urllib.parse
    import urllib.request

    params = urllib.parse.urlencode({
        "latitude": lat,
        "longitude": lon,
        "current": "temperature_2m,relative_humidity_2m,wind_speed_10m,weather_code",
        "timezone": "UTC"
    })
    url = f"https://api.open-meteo.com/v1/forecast?{params}"
    with urllib.request.urlopen(url, timeout=15) as resp:
        data = json.loads(resp.read().decode("utf-8"))

    cur = data.get("current", {})
    return {
        "temp_c": cur.get("temperature_2m"),
        "humidity_pct": cur.get("relative_humidity_2m"),
        "wind_kph": cur.get("wind_speed_10m"),
        "condition_code": cur.get("weather_code")
    }


def _weather_city_coords(name):
    key = (name or "").strip().lower()
    if key in ("san diego", "san diego, ca", "san diego ca"):
        return (32.7157, -117.1611, "San Diego")
    if key in ("new york city", "nyc", "new york"):
        return (40.7128, -74.0060, "New York City")
    raise ValueError(f"Unsupported city: {name}")


@app.route("/api/weather/health", methods=["GET"])
def api_weather_health():
    from datetime import datetime, timezone
    return jsonify({
        "status": "ok",
        "worker_id": "ubuntu-worker-01",
        "timestamp_utc": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    })


@app.route("/api/weather/compare", methods=["POST"])
def api_weather_compare():
    from datetime import datetime, timezone
    import uuid

    payload = request.get_json(silent=True) or {}
    city_a_in = payload.get("city_a", "San Diego")
    city_b_in = payload.get("city_b", "New York City")

    try:
        lat_a, lon_a, city_a = _weather_city_coords(city_a_in)
        lat_b, lon_b, city_b = _weather_city_coords(city_b_in)
    except ValueError as exc:
        return jsonify({"error": str(exc)}), 400

    data_a = _weather_fetch_open_meteo(lat_a, lon_a)
    data_b = _weather_fetch_open_meteo(lat_b, lon_b)

    temp_a = data_a.get("temp_c")
    temp_b = data_b.get("temp_c")
    hum_a = data_a.get("humidity_pct")
    hum_b = data_b.get("humidity_pct")
    wind_a = data_a.get("wind_kph")
    wind_b = data_b.get("wind_kph")

    resp = {
        "request_id": str(uuid.uuid4()),
        "timestamp_utc": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "city_a": {
            "name": city_a,
            "temp_c": temp_a,
            "humidity_pct": hum_a,
            "wind_kph": wind_a,
            "condition": str(data_a.get("condition_code"))
        },
        "city_b": {
            "name": city_b,
            "temp_c": temp_b,
            "humidity_pct": hum_b,
            "wind_kph": wind_b,
            "condition": str(data_b.get("condition_code"))
        },
        "comparison": {
            "temp_delta_c": (temp_a - temp_b) if isinstance(temp_a, (int, float)) and isinstance(temp_b, (int, float)) else None,
            "humidity_delta_pct": (hum_a - hum_b) if isinstance(hum_a, (int, float)) and isinstance(hum_b, (int, float)) else None,
            "wind_delta_kph": (wind_a - wind_b) if isinstance(wind_a, (int, float)) and isinstance(wind_b, (int, float)) else None,
            "condition_match": str(data_a.get("condition_code")) == str(data_b.get("condition_code")),
            "summary": f"{city_a} vs {city_b} live weather comparison"
        },
        "source": "open-meteo"
    }
    return jsonify(resp)
'''

marker = 'if __name__ == "__main__":'
if marker in text:
    text = text.replace(marker, snippet + "\n\n" + marker, 1)
else:
    text = text + snippet

path.write_text(text, encoding="utf-8")
print("weather_routes_patch=applied")
PY

restart_ok="false"
if systemctl --user list-unit-files 2>/dev/null | grep -q "site-kb-server.service"; then
  systemctl --user restart site-kb-server.service
  restart_ok="true"
  echo "restart_mode=systemd-user-site-kb-server"
else
  if pgrep -f "site_kb_server.py" >/dev/null 2>&1; then
    pkill -f "site_kb_server.py" || true
    sleep 2
  fi
  nohup python3 "${SITE_SERVER}" >/tmp/site_kb_server.log 2>&1 &
  restart_ok="true"
  echo "restart_mode=nohup"
fi

if [[ "${restart_ok}" != "true" ]]; then
  echo "error=restart_failed"
  exit 1
fi

sleep 3
health_json="$(curl -sS "http://127.0.0.1:${PORT}/api/weather/health" || true)"
compare_json="$(curl -sS -H "Content-Type: application/json" -d '{"city_a":"San Diego","city_b":"New York City","units":"metric"}' "http://127.0.0.1:${PORT}/api/weather/compare" || true)"

if [[ -z "${health_json}" || -z "${compare_json}" ]]; then
  echo "error=local_endpoint_check_failed"
  exit 1
fi

echo "local_health=${health_json}"
echo "local_compare_excerpt=$(echo "${compare_json}" | head -c 220)"

public_url="$(curl -sS http://127.0.0.1:4040/api/tunnels | python3 -c 'import json,sys; d=json.load(sys.stdin); t=d.get("tunnels",[]); print(t[0].get("public_url","") if t else "")' || true)"
if [[ -n "${public_url}" ]]; then
  echo "public_base=${public_url}"
  pub_health="$(curl -sS "${public_url}/api/weather/health" || true)"
  echo "public_health=${pub_health}"
fi

echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
