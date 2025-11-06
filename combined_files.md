## Файл: .env

- Размер: 746 байт; Изменён: 2025-09-04 15:04:41; Кодировка: utf-8
```plaintext
PUBLIC_IP=83.219.97.252

# InfluxDB 2 bootstrap (первый старт контейнера)
DOCKER_INFLUXDB_INIT_MODE=setup
DOCKER_INFLUXDB_INIT_USERNAME=admin
DOCKER_INFLUXDB_INIT_PASSWORD=i5AMPArwXkejDeQFl0XR
DOCKER_INFLUXDB_INIT_ORG=iot
DOCKER_INFLUXDB_INIT_BUCKET=iotsensors
DOCKER_INFLUXDB_INIT_RETENTION=168h
DOCKER_INFLUXDB_INIT_ADMIN_TOKEN=FLIueXZaUqgEcaVvM7aIsGPYyeBrHosPaadolO1xxxuUQtSrRv3hJd960Z6SQLav

# Клиентские настройки для Telegraf и API
INFLUXURL=http://influxdb:8086
INFLUXORG=${DOCKER_INFLUXDB_INIT_ORG}
INFLUXBUCKET=${DOCKER_INFLUXDB_INIT_BUCKET}

# Порт HTTP API
APIPORT=8000
MQTTUSER=telegraf
MQTTPASS=telegrafpass
INFLUXTOKEN=FLIueXZaUqgEcaVvM7aIsGPYyeBrHosPaadolO1xxxuUQtSrRv3hJd960Z6SQLav

```

## Файл: .influxdb-config/influx-configs

- Размер: 472 байт; Изменён: 2025-09-04 12:35:56; Кодировка: utf-8
```plaintext
[default]
  url = "http://localhost:8086"
  token = "FLIueXZaUqgEcaVvM7aIsGPYyeBrHosPaadolO1xxxuUQtSrRv3hJd960Z6SQLav"
  org = "iot"
  active = true
# 
# [eu-central]
#   url = "https://eu-central-1-1.aws.cloud2.influxdata.com"
#   token = "XXX"
#   org = ""
# 
# [us-central]
#   url = "https://us-central1-1.gcp.cloud2.influxdata.com"
#   token = "XXX"
#   org = ""
# 
# [us-west]
#   url = "https://us-west-2-1.aws.cloud2.influxdata.com"
#   token = "XXX"
#   org = ""

```

## Файл: .mosquitto/config/mosquitto.conf

- Размер: 360 байт; Изменён: 2025-09-04 12:26:53; Кодировка: utf-8
```ini
listener 1883 0.0.0.0
allow_anonymous false
password_file /mosquitto/config/passwd

persistence true
persistence_location /mosquitto/data

# TLS можно добавить позже на 8883:
# listener 8883 0.0.0.0
# cafile /mosquitto/config/ca.crt
# certfile /mosquitto/config/server.crt
# keyfile /mosquitto/config/server.key
# require_certificate false

```

## Файл: .mosquitto/config/passwd

- Размер: 363 байт; Изменён: 2025-09-05 08:36:41; Кодировка: utf-8
```plaintext
sensor:$7$101$Z5DEa1am2g18gIJZ$0Tp6jtydCr3OjRgJPqBEp10jF/HkrwB1N/ZXLcjJ7aOicSPeyp0+oiA14BnqizSs0G6d+eMmPzyjdM00NXMTmw==
telegraf:$7$101$/YYX7FGvkgt6zx7E$FLYjno3yio24G9sUlaTZbhnP3KNWGEpFpeg73IHUN/n1yVSeAMDgQKsWEiEy+QMuT2cYgr9JtHPdO2nP/rTcjA==
sensors:$7$101$WP3tMNCz4ye4QqNT$1QW/Hb1Vu7rXkOKOY5P9vNYQPeYBSzLYef7Shq+BE6oDNeNcepKGT7tFpHXJdGGAQgagtxqIBtda9J2fZXcaWQ==

```

## Файл: api/Dockerfile

- Размер: 201 байт; Изменён: 2025-09-04 12:29:31; Кодировка: utf-8
```dockerfile
FROM python:3.11-slim
WORKDIR /app
RUN pip install --no-cache-dir fastapi uvicorn[standard] influxdb-client
COPY main.py /app/main.py
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]

```

## Файл: api/main.py

- Размер: 3446 байт; Изменён: 2025-09-04 13:34:39; Кодировка: utf-8
```python
from fastapi import FastAPI, Query
from typing import List, Optional
import os, datetime as dt
from influxdb_client import InfluxDBClient

INFLUXURL = os.getenv("INFLUXURL", "http://localhost:8086")
INFLUXTOKEN = os.getenv("INFLUXTOKEN")
INFLUXORG = os.getenv("INFLUXORG")
INFLUXBUCKET = os.getenv("INFLUXBUCKET", "iotsensors")

app = FastAPI(title="IoT API", version="1.0.0", docs_url="/docs", openapi_url="/openapi.json")
client = InfluxDBClient(url=INFLUXURL, token=INFLUXTOKEN, org=INFLUXORG)
q = client.query_api()

@app.get("/api/devices", response_model=List[str])
def list_devices():
    flux = f'''
      import "influxdata/influxdb/schema"
      schema.tagValues(bucket: "{INFLUXBUCKET}", tag: "deviceid",
        predicate: (r) => r._measurement == "sensors", start: -7d)
    '''
    tables = q.query(org=INFLUXORG, query=flux)
    return sorted({rec.get_value() for t in tables for rec in t.records if rec.get_value()})

@app.get("/api/devices/online", response_model=List[str])
def list_online():
    flux = f'''
      from(bucket: "{INFLUXBUCKET}")
        |> range(start: -7d)
        |> filter(fn: (r) => r._measurement == "devices" and r._field == "value")
        |> last()
        |> filter(fn: (r) => r._value == "online")
        |> keep(columns: ["deviceid"])
    '''
    tables = q.query(org=INFLUXORG, query=flux)
    return sorted({rec.values.get("deviceid") for t in tables for rec in t.records})

@app.get("/api/devices/{deviceid}/status")
def device_status(deviceid: str):
    flux = f'''
      lastStatus = from(bucket: "{INFLUXBUCKET}")
        |> range(start: -7d)
        |> filter(fn: (r) => r._measurement == "devices" and r.deviceid == "{deviceid}" and r._field == "value")
        |> last()
      lastData = from(bucket: "{INFLUXBUCKET}")
        |> range(start: -7d)
        |> filter(fn: (r) => r._measurement == "sensors" and r.deviceid == "{deviceid}")
        |> last()
      union(tables: [lastStatus, lastData])
    '''
    tables = q.query(org=INFLUXORG, query=flux)
    statusval, statusts, lastts = None, None, None
    for t in tables:
        for r in t.records:
            if r.get_measurement() == "devices":
                statusval, statusts = r.get_value(), r.get_time()
            else:
                lastts = r.get_time()
    return {"deviceid": deviceid, "online": statusval=="online", "status": statusval, "statustime": statusts, "lastdatatime": lastts}

@app.get("/api/devices/{deviceid}/data")
def device_data(deviceid: str, start: str = Query(...), stop: Optional[str] = Query(None)):
    stop_iso = stop or dt.datetime.utcnow().isoformat() + "Z"
    flux = f'''
      from(bucket: "{INFLUXBUCKET}")
        |> range(start: time(v: "{start}"), stop: time(v: "{stop_iso}"))
        |> filter(fn: (r) => r._measurement == "sensors" and r.deviceid == "{deviceid}")
        |> pivot(rowKey: ["_time"], columnKey: ["_field"], valueColumn: "_value")
        |> keep(columns: ["_time","temperature","humidity","pressure","deviceid"])
    '''
    tables = q.query(org=INFLUXORG, query=flux)
    rows = []
    for t in tables:
        for r in t.records:
            rows.append({
              "time": r.get_time().isoformat(),
              "temperature": r.values.get("temperature"),
              "humidity": r.values.get("humidity"),
              "pressure": r.values.get("pressure"),
            })
    return {"deviceid": deviceid, "start": start, "stop": stop_iso, "points": rows}

```

## Файл: docker-compose.yml

- Размер: 1526 байт; Изменён: 2025-09-04 12:30:36; Кодировка: utf-8
```yaml
services:
  mosquitto:
    image: eclipse-mosquitto:2
    container_name: mosquitto
    ports: ["1883:1883"]
    volumes:
      - ./.mosquitto/config:/mosquitto/config
      - ./.mosquitto/data:/mosquitto/data
      - ./.mosquitto/log:/mosquitto/log
    restart: unless-stopped

  influxdb:
    image: influxdb:2
    container_name: influxdb
    ports: ["8086:8086"]
    environment:
      - DOCKER_INFLUXDB_INIT_MODE=${DOCKER_INFLUXDB_INIT_MODE}
      - DOCKER_INFLUXDB_INIT_USERNAME=${DOCKER_INFLUXDB_INIT_USERNAME}
      - DOCKER_INFLUXDB_INIT_PASSWORD=${DOCKER_INFLUXDB_INIT_PASSWORD}
      - DOCKER_INFLUXDB_INIT_ORG=${DOCKER_INFLUXDB_INIT_ORG}
      - DOCKER_INFLUXDB_INIT_BUCKET=${DOCKER_INFLUXDB_INIT_BUCKET}
      - DOCKER_INFLUXDB_INIT_RETENTION=${DOCKER_INFLUXDB_INIT_RETENTION}
      - DOCKER_INFLUXDB_INIT_ADMIN_TOKEN=${DOCKER_INFLUXDB_INIT_ADMIN_TOKEN}
    volumes:
      - ./.influxdb-data:/var/lib/influxdb2
      - ./.influxdb-config:/etc/influxdb2
    restart: unless-stopped

  telegraf:
    image: telegraf:1.30
    container_name: telegraf
    depends_on: [mosquitto, influxdb]
    env_file: .env
    volumes:
      - ./telegraf/telegraf.conf:/etc/telegraf/telegraf.conf:ro
    restart: unless-stopped

  api:
    build: ./api
    container_name: iot-api
    env_file: .env
    environment:
      - INFLUXURL=${INFLUXURL}
      - INFLUXTOKEN=${INFLUXTOKEN}
      - INFLUXORG=${INFLUXORG}
      - INFLUXBUCKET=${INFLUXBUCKET}
    ports: ["8000:8000"]
    depends_on: [influxdb]
    restart: unless-stopped

```

## Файл: telegraf/telegraf.conf

- Размер: 1492 байт; Изменён: 2025-09-04 15:22:52; Кодировка: utf-8
```ini
[agent]
  interval = "10s"
  round_interval = true
  debug = true

# 1) Измерения BME280
[[inputs.mqtt_consumer]]
  servers   = ["tcp://mosquitto:1883"]
  topics    = ["sensors/+/bme280"]
  qos       = 0
  client_id = "telegraf-iot-bme280"
  username  = "${MQTTUSER}"
  password  = "${MQTTPASS}"
  data_format = "json_v2"

  [[inputs.mqtt_consumer.topic_parsing]]
    topic = "sensors/+/bme280"
    measurement = "bme280"
    tags = "_/deviceid/_"

  [[inputs.mqtt_consumer.json_v2]]
    [[inputs.mqtt_consumer.json_v2.field]]
      path = "temperature"
      type = "float"
    [[inputs.mqtt_consumer.json_v2.field]]
      path = "humidity"
      type = "float"
    [[inputs.mqtt_consumer.json_v2.field]]
      path = "pressure"
      type = "float"

# 2) Статусы устройств (retained LWT online/offline)
[[inputs.mqtt_consumer]]
  servers   = ["tcp://mosquitto:1883"]
  topics    = ["devices/+/status"]
  qos       = 0
  client_id = "telegraf-iot"
  username  = "${MQTTUSER}"
  password  = "${MQTTPASS}"
  data_format = "json_v2"

  [[inputs.mqtt_consumer.topic_parsing]]
    topic = "devices/+/status"
    measurement = "status"
    tags = "_/deviceid/_"

  [[inputs.mqtt_consumer.json_v2]]
    [[inputs.mqtt_consumer.json_v2.field]]
      path = "status"
      rename = "value"
      type = "string"

[[outputs.influxdb_v2]]
  urls          = ["${INFLUXURL}"]
  token         = "${INFLUXTOKEN}"
  organization  = "${INFLUXORG}"
  bucket        = "${INFLUXBUCKET}"

```

