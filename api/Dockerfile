FROM python:3.11-slim
WORKDIR /app
# было: RUN pip install --no-cache-dir fastapi uvicorn[standard] influxdb-client
RUN pip install --no-cache-dir fastapi uvicorn[standard] influxdb-client paho-mqtt
COPY main.py /app/main.py
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
