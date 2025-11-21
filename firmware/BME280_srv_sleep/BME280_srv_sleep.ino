#include <ESP8266WiFi.h>
#include <ESP8266WebServer.h>
#include <WiFiManager.h>
#include <Wire.h>
#include <EEPROM.h>
#include <Adafruit_Sensor.h>
#include <Adafruit_BME280.h>
#include <PubSubClient.h>
#include <ArduinoJson.h>

// ==================== ПИНЫ ====================
#define SDA_PIN D2
#define SCL_PIN D1
#define RESET_BUTTON_PIN D6

// ==================== КОНСТАНТЫ ====================
const uint8_t BME_ADDR_PRIMARY = 0x76;
const uint8_t BME_ADDR_ALTERNATE = 0x77;
#define EEPROM_SALT 12348

typedef struct {
  int salt = EEPROM_SALT;
  char device_id[33] = "";
  char mqtt_server[41] = "193.107.237.215";
  uint16_t mqtt_port = 1883;
  char mqtt_user[21] = "sensor";
  char mqtt_pass[21] = "sensorpass";
} DeviceConfig;

DeviceConfig config;

// ============ ОБЪЕКТЫ ============
WiFiClient wifiClient;
PubSubClient mqtt(wifiClient);
Adafruit_BME280 bme;

String deviceId, topicData, topicStatus;
const char* STATUS_ONLINE = "{\"status\":\"online\"}";
const char* STATUS_OFFLINE = "{\"status\":\"offline\"}";
bool shouldSaveConfig = false;

// ============ EEPROM ============
void loadConfig() {
  EEPROM.begin(512);
  EEPROM.get(0, config);
  EEPROM.end();
  if (config.salt != EEPROM_SALT) {
    Serial.println("Invalid config, using defaults");
    DeviceConfig defaults;
    config = defaults;
    saveConfig();
  } else {
    Serial.println("Config loaded from EEPROM:");
    Serial.print(" Device ID: ");
    Serial.println(strlen(config.device_id) > 0 ? config.device_id : "(auto)");
    Serial.print(" MQTT Server: ");
    Serial.print(config.mqtt_server);
    Serial.print(":");
    Serial.println(config.mqtt_port);
  }
}

void saveConfig() {
  EEPROM.begin(512);
  EEPROM.put(0, config);
  EEPROM.commit();
  EEPROM.end();
  Serial.println("Config saved to EEPROM");
}

void saveConfigCallback() {
  Serial.println("shouldSaveConfig = true");
  shouldSaveConfig = true;
}

// =========== IDs, топики ============
static String chipIdHex6() {
  String s = String(ESP.getChipId(), HEX);
  s.toUpperCase();
  while (s.length() < 6) s = "0" + s;
  return s;
}

void makeIdsAndTopics() {
  if (strlen(config.device_id) == 0) {
    deviceId = chipIdHex6();
  } else {
    deviceId = String(config.device_id);
  }
  topicData = "sensors/" + deviceId + "/bme280";
  topicStatus = "devices/" + deviceId + "/status";
  Serial.print("Device ID: "); Serial.println(deviceId);
  Serial.print("Data Topic: "); Serial.println(topicData);
  Serial.print("Status Topic: "); Serial.println(topicStatus);
}

// =========== BME280 ============
bool initBME() {
  Wire.begin(SDA_PIN, SCL_PIN);
  if (bme.begin(BME_ADDR_PRIMARY)) return true;
  if (bme.begin(BME_ADDR_ALTERNATE)) return true;
  return false;
}

bool readBME(float& t, float& h, float& p_hPa) {
  t = bme.readTemperature();
  h = bme.readHumidity();
  float p_Pa = bme.readPressure();
  if (isnan(t) || isnan(h) || isnan(p_Pa)) return false;
  p_hPa = p_Pa / 100.0f;
  return true;
}

// =========== MQTT ============
bool connectMQTT() {
  // Диагностика: выводим пароль перед подключением
  Serial.printf("MQTT password: [%s] (len=%d)\n", config.mqtt_pass, strlen(config.mqtt_pass));
  if (mqtt.connected()) return true;
  String cid = "sensor-" + deviceId;
  Serial.print("Connecting MQTT as "); Serial.println(cid);
  bool ok = mqtt.connect(cid.c_str(),
                         config.mqtt_user,
                         config.mqtt_pass,
                         topicStatus.c_str(),
                         0, true, STATUS_OFFLINE, true);
  if (ok) {
    mqtt.publish(topicStatus.c_str(), STATUS_ONLINE, true);
    Serial.println("MQTT connected");
  } else {
    Serial.print("MQTT failed, rc=");
    Serial.println(mqtt.state());
  }
  return ok;
}

void publishTelemetry() {
  float t, h, p;
  if (!readBME(t, h, p)) {
    Serial.println("Failed to read BME280");
    return;
  }
  StaticJsonDocument<128> doc;
  doc["temperature"] = t;
  doc["humidity"] = h;
  doc["pressure"] = p;
  String payload;
  serializeJson(doc, payload);
  if (mqtt.publish(topicData.c_str(), payload.c_str(), false)) {
    Serial.print("Published: "); Serial.println(payload);
  } else {
    Serial.print("Publish failed: "); Serial.println(payload);
  }
}

// =========== Кнопка сброса ============
void checkResetButton() {
  if (digitalRead(RESET_BUTTON_PIN) == LOW) {
    Serial.println("Reset button pressed during boot");
    delay(100);
    if (digitalRead(RESET_BUTTON_PIN) == LOW) {
      Serial.println("Resetting WiFi and config...");
      WiFiManager wifiManager;
      wifiManager.resetSettings();
      DeviceConfig defaults;
      config = defaults;
      saveConfig();
      delay(1000);
      ESP.restart();
    }
  }
}

// =========== SETUP ============
void setup() {
  Serial.begin(115200);
  delay(100);
  Serial.println("\n\n=== ESP8266 BME280 with WiFiManager + DeepSleep ===");

  pinMode(RESET_BUTTON_PIN, INPUT_PULLUP);
  checkResetButton();

  loadConfig();

  if (!initBME()) {
    Serial.println("BME280 not found");
  } else {
    Serial.println("BME280 initialized");
  }

  // ----------- WiFiManager портал -----------
  WiFiManager wifiManager;
  wifiManager.setSaveConfigCallback(saveConfigCallback);

  char port_str[6]; sprintf(port_str, "%d", config.mqtt_port);

  WiFiManagerParameter p1("device_id", "Device ID (пустое=авто)", config.device_id, 32);
  WiFiManagerParameter p2("mqtt_server", "MQTT Server", config.mqtt_server, 40);
  WiFiManagerParameter p3("mqtt_port", "MQTT Port", port_str, 5);
  WiFiManagerParameter p4("mqtt_user", "MQTT User", config.mqtt_user, 20);
  WiFiManagerParameter p5("mqtt_pass", "MQTT Pass", config.mqtt_pass, 20);

  wifiManager.addParameter(&p1);
  wifiManager.addParameter(&p2);
  wifiManager.addParameter(&p3);
  wifiManager.addParameter(&p4);
  wifiManager.addParameter(&p5);

  wifiManager.setConfigPortalTimeout(180);

  String apName = "ESP-Config-" + chipIdHex6();
  Serial.print("WiFiManager AP: "); Serial.println(apName);

  if (!wifiManager.autoConnect(apName.c_str())) {
    Serial.println("Failed to connect, restarting...");
    delay(3000);
    ESP.restart();
  }

  Serial.print("WiFi "); Serial.println(WiFi.localIP());

  if (shouldSaveConfig) {
    Serial.println("Saving custom parameters...");
    strncpy(config.device_id, p1.getValue(), 32); config.device_id[32] = '\0';
    strncpy(config.mqtt_server, p2.getValue(), 40); config.mqtt_server[40] = '\0';
    config.mqtt_port = atoi(p3.getValue());
    strncpy(config.mqtt_user, p4.getValue(), 20); config.mqtt_user[20] = '\0';
    // --- ОБРАБОТКА ПАРОЛЯ ---
    String tempPass = String(p5.getValue());
    tempPass.trim();
    strncpy(config.mqtt_pass, tempPass.c_str(), 20);
    config.mqtt_pass[20] = '\0';
    Serial.printf("Saved MQTT password: [%s] (len=%d)\n", config.mqtt_pass, strlen(config.mqtt_pass));
    saveConfig(); shouldSaveConfig = false;
  }

  makeIdsAndTopics();

  mqtt.setServer(config.mqtt_server, config.mqtt_port);
  mqtt.setKeepAlive(60);
  mqtt.setBufferSize(256);

  // --------- Отправка MQTT с задержкой после публикации ---------
  if (WiFi.status() == WL_CONNECTED) {
    if (connectMQTT()) {
      publishTelemetry();
      for (int i = 0; i < 10; i++) {
        mqtt.loop();
        delay(100);
      }
    }
  }

  Serial.println("Setup complete! DeepSleep 30 sec...");
  ESP.deepSleep(30 * 1e6);
}

void loop() {
  // Всё делается в setup (глубокий сон)
}
