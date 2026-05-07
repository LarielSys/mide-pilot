FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends git && rm -rf /var/lib/apt/lists/*

RUN git config --global --add safe.directory /pilot_v1/customide

# Mirror host path so relative resolution in services.py works correctly:
# Path(__file__).parents[3] → /pilot_v1/customide → ../config = /pilot_v1/config
WORKDIR /pilot_v1/customide/backend

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ app/

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "5555"]
