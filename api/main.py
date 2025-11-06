from typing import List, Optional, Dict
import os
import datetime as dt

from fastapi import FastAPI, Query, HTTPException, Depends, Security, status, Cookie, Request
from fastapi.security import APIKeyHeader, APIKeyQuery, HTTPBearer, HTTPAuthorizationCredentials
from influxdb_client import InfluxDBClient
from pydantic import BaseModel
import paho.mqtt.client as mqtt

# =========================
# Конфигурация из окружения
# =========================

INFLUXURL = os.getenv("INFLUXURL", "http://localhost:8086")
INFLUXTOKEN = os.getenv("INFLUXTOKEN")
INFLUXORG = os.getenv("INFLUXORG")
INFLUXBUCKET = os.getenv("INFLUXBUCKET", "iotsensors")

# MQTT (необязательно)
MQTTHOST = os.getenv("MQTTHOST", "mosquitto")
MQTTPORT = int(os.getenv("MQTTPORT", "1883"))
MQTTUSER = os.getenv("MQTTUSER")
MQTTPASS = os.getenv("MQTTPASS")

# Простой токен доступа
API_TOKEN = os.getenv("API_TOKEN")

# =========================
# Безопасность (простой токен)
# =========================

# Источники токена
api_key_query = APIKeyQuery(name="token", auto_error=False)
api_key_header = APIKeyHeader(name="X-API-Token", auto_error=False)
http_bearer = HTTPBearer(auto_error=False)

def verify_token(
    token_q: Optional[str] = Security(api_key_query),
    token_h: Optional[str] = Security(api_key_header),
    bearer: Optional[HTTPAuthorizationCredentials] = Security(http_bearer),
    token_cookie: Optional[str] = Cookie(default=None, alias="api_token"),
) -> bool:
    """
    Проверяет токен из query (?token=...), заголовка X-API-Token,
    Authorization: Bearer ... или cookie api_token.
    """
    provided = token_q or token_h or (bearer.credentials if bearer else None) or token_cookie
    if not API_TOKEN or provided != API_TOKEN:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Missing or invalid API token",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return True

# =========================
# Приложение FastAPI (глобальная зависимость)
# =========================

app = FastAPI(
    title="IoT API",
    version="1.0.0",
    docs_url="/docs",
    openapi_url="/openapi.json",
    dependencies=[Depends(verify_token)],  # защищаем всё, включая /docs и /openapi.json
)

# Middleware: если в запросе есть ?token=..., кладём его в cookie,
# чтобы Swagger мог подтянуть openapi.json без ручного добавления токена.
@app.middleware("http")
async def persist_token_cookie(request: Request, call_next):
    token = request.query_params.get("token")
    response = await call_next(request)
    if token:
        # Для продакшна выставьте secure=True при HTTPS
        response.set_cookie("api_token", token, httponly=True, samesite="lax", secure=False)
    return response

# =========================
# InfluxDB клиент
# =========================

client = InfluxDBClient(url=INFLUXURL, token=INFLUXTOKEN, org=INFLUXORG)
q = client.query_api()

# Московская временная зона (UTC+3)
MOSCOW_TZ = dt.timezone(dt.timedelta(hours=3))


def iso_seconds_moscow(ts: Optional[dt.datetime]) -> Optional[str]:
    """
    Преобразует datetime к московскому времени с точностью до секунд
    и убирает суффикс часового пояса из строки.
    """
    if ts is None:
        return None
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=dt.timezone.utc)
    moscow_time = ts.astimezone(MOSCOW_TZ)
    moscow_naive = moscow_time.replace(microsecond=0).replace(tzinfo=None)
    return moscow_naive.isoformat(timespec="seconds")


def parse_moscow_time_to_utc(time_str: str) -> str:
    """
    Преобразует московское время в строке в UTC для InfluxDB запросов.
    """
    try:
        moscow_dt = dt.datetime.fromisoformat(time_str)
        moscow_dt = moscow_dt.replace(tzinfo=MOSCOW_TZ)
        utc_dt = moscow_dt.astimezone(dt.timezone.utc)
        return utc_dt.isoformat()
    except ValueError:
        # Если уже есть часовой пояс, используем как есть
        return time_str


@app.get("/api/devices", response_model=List[str])
def list_devices() -> List[str]:
    """
    Показываем только устройства, у которых есть реальные точки за 7 дней в sensors|bme280.
    """
    flux = f"""
a = from(bucket: "{INFLUXBUCKET}")
  |> range(start: -7d)
  |> filter(fn: (r) => r._measurement == "sensors")
  |> keep(columns: ["deviceid"])
  |> distinct(column: "deviceid")
b = from(bucket: "{INFLUXBUCKET}")
  |> range(start: -7d)
  |> filter(fn: (r) => r._measurement == "bme280")
  |> keep(columns: ["deviceid"])
  |> distinct(column: "deviceid")
union(tables: [a, b])
  |> keep(columns: ["deviceid"])
  |> unique(column: "deviceid")
  |> sort(columns: ["deviceid"], desc: false)
"""
    tables = q.query(org=INFLUXORG, query=flux)
    ids = [rec.values.get("deviceid") for t in tables for rec in t.records if rec.values.get("deviceid")]
    return ids


@app.get("/api/devices/online", response_model=List[str])
def list_online() -> List[str]:
    """
    Последний статус на устройство из devices|status; фильтруем только online и убираем дубли.
    """
    flux = f"""
from(bucket: "{INFLUXBUCKET}")
  |> range(start: -7d)
  |> filter(fn: (r) => (r._measurement == "devices" or r._measurement == "status") and r._field == "value")
  |> group(columns: ["deviceid"])
  |> last()
  |> filter(fn: (r) => r._value == "online")
  |> keep(columns: ["deviceid"])
  |> unique(column: "deviceid")
"""
    tables = q.query(org=INFLUXORG, query=flux)
    ids = [rec.values.get("deviceid") for t in tables for rec in t.records if rec.values.get("deviceid")]
    return sorted(ids)


@app.get("/api/devices/{deviceid}/status")
def device_status(deviceid: str):
    """
    Возвращает статус и время последней телеметрии (в московской зоне).
    """
    # Последний статус устройства из devices|status
    flux_status = f"""
from(bucket: "{INFLUXBUCKET}")
  |> range(start: -7d)
  |> filter(fn: (r) => (r._measurement == "devices" or r._measurement == "status") and r.deviceid == "{deviceid}" and r._field == "value")
  |> group(columns: ["deviceid"])
  |> last()
"""
    status_tables = q.query(org=INFLUXORG, query=flux_status)
    status_val: Optional[str] = None
    status_ts: Optional[dt.datetime] = None
    for t in status_tables:
        for r in t.records:
            status_val = r.get_value()
            status_ts = r.get_time()

    # Последнее время телеметрии устройства из sensors|bme280
    flux_last_data = f"""
a = from(bucket: "{INFLUXBUCKET}")
  |> range(start: -7d)
  |> filter(fn: (r) => r.deviceid == "{deviceid}" and r._measurement == "sensors")
b = from(bucket: "{INFLUXBUCKET}")
  |> range(start: -7d)
  |> filter(fn: (r) => r.deviceid == "{deviceid}" and r._measurement == "bme280")
union(tables: [a, b])
  |> group(columns: ["deviceid"])
  |> last()
  |> keep(columns: ["_time"])
"""
    data_tables = q.query(org=INFLUXORG, query=flux_last_data)
    last_data_ts: Optional[dt.datetime] = None
    for t in data_tables:
        for r in t.records:
            last_data_ts = r.get_time()

    return {
        "deviceid": deviceid,
        "online": True if status_val == "online" else False,
        "statustime": iso_seconds_moscow(status_ts),
        "lastdatatime": iso_seconds_moscow(last_data_ts),
    }


@app.get("/api/devices/{deviceid}/data")
def device_data(
    deviceid: str,
    start: str = Query(..., description="Время начала в московском времени (YYYY-MM-DDTHH:MM:SS)"),
    stop: Optional[str] = Query(None, description="Время окончания в московском времени (необязательно)"),
):
    """
    Получает данные с устройства за указанный период (времена в ответе — Москва без суффикса).
    """
    try:
        # Конвертируем московское время в UTC для InfluxDB
        start_utc = parse_moscow_time_to_utc(start)
        if stop:
            stop_utc = parse_moscow_time_to_utc(stop)
        else:
            # По умолчанию stop = сейчас (UTC)
            now_utc = dt.datetime.now(dt.timezone.utc)
            stop_utc = now_utc.isoformat()

        flux = f"""
a = from(bucket: "{INFLUXBUCKET}")
  |> range(start: {start_utc}, stop: {stop_utc})
  |> filter(fn: (r) => r._measurement == "sensors" and r.deviceid == "{deviceid}")
b = from(bucket: "{INFLUXBUCKET}")
  |> range(start: {start_utc}, stop: {stop_utc})
  |> filter(fn: (r) => r._measurement == "bme280" and r.deviceid == "{deviceid}")
union(tables: [a, b])
  |> pivot(rowKey: ["_time"], columnKey: ["_field"], valueColumn: "_value")
  |> keep(columns: ["_time","temperature","humidity","pressure","deviceid"])
"""
        tables = q.query(org=INFLUXORG, query=flux)

        points = []
        for t in tables:
            for r in t.records:
                moscow_time_str = iso_seconds_moscow(r.get_time())
                points.append(
                    {
                        "time": moscow_time_str,
                        "temperature": r.values.get("temperature"),
                        "humidity": r.values.get("humidity"),
                        "pressure": r.values.get("pressure"),
                    }
                )

        return {
            "deviceid": deviceid,
            "start": start,
            "stop": stop if stop else iso_seconds_moscow(dt.datetime.now(dt.timezone.utc)),
            "points": points,
        }
    except Exception as e:
        return {
            "error": str(e),
            "deviceid": deviceid,
            "start": start,
            "stop": stop,
            "points": [],
        }


class DeleteResult(BaseModel):
    device_id: str
    influx_deleted: Dict[str, bool]
    mqtt_cleared: bool


@app.delete("/api/devices/{device_id}", response_model=DeleteResult)
def delete_device(device_id: str):
    """
    Удаляет все данные устройства из InfluxDB и очищает retained-статус в MQTT.
    """
    bucket = INFLUXBUCKET
    org = INFLUXORG
    delete_api = client.delete_api()

    # Максимальный диапазон на будущее
    start = "1970-01-01T00:00:00Z"
    stop = "2100-01-01T00:00:00Z"

    # Покрываем текущую схему (bme280/status) и альтернативные названия (sensors/devices)
    predicates = [
        f'_measurement="bme280" AND deviceid="{device_id}"',
        f'_measurement="status" AND deviceid="{device_id}"',
        f'_measurement="sensors" AND deviceid="{device_id}"',
        f'_measurement="devices" AND deviceid="{device_id}"',
    ]

    deleted: Dict[str, bool] = {}
    for pred in predicates:
        try:
            delete_api.delete(start, stop, pred, bucket=bucket, org=org)
            deleted[pred] = True
        except Exception:
            deleted[pred] = False

    # Очистка retained-статуса в MQTT: publish retained с пустым payload
    mqtt_cleared = False
    try:
        topic_status = f"devices/{device_id}/status"
        mqc = mqtt.Client(protocol=mqtt.MQTTv311)
        if MQTTUSER and MQTTPASS:
            mqc.username_pw_set(MQTTUSER, MQTTPASS)
        mqc.connect(MQTTHOST, MQTTPORT, keepalive=10)
        # Публикация пустого retained-пакета стирает retained-сообщение в топике
        mqc.publish(topic_status, payload=b"", qos=1, retain=True)
        mqc.loop(timeout=1.0)
        mqc.disconnect()
        mqtt_cleared = True
    except Exception:
        mqtt_cleared = False

    return DeleteResult(
        device_id=device_id,
        influx_deleted=deleted,
        mqtt_cleared=mqtt_cleared,
    )


# Для локального запуска:
# if __name__ == "__main__":
#     import uvicorn
#     uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
