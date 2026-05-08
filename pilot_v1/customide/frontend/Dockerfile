FROM python:3.12-slim

WORKDIR /app

COPY . .

EXPOSE 5570
CMD ["python3", "-m", "http.server", "5570", "--bind", "0.0.0.0"]
