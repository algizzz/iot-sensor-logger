#include <ESP8266WiFi.h>
#include <ESP8266WebServer.h>
#include <ESP8266mDNS.h>
#include <ESP8266HTTPUpdateServer.h>
#include <WiFiManager.h>
#include <PubSubClient.h>
#include <Wire.h>
#include <Adafruit_Sensor.h>
#include <Adafruit_BME280.h>
#include <ArduinoJson.h>
#include <EEPROM.h>

// ==================== ПИНЫ ====================
#define SDA_PIN D2
#define SCL_PIN D1
#define RESET_BUTTON_PIN D6

// ==================== КОНСТАНТЫ ====================
const uint8_t BME_ADDR_PRIMARY = 0x76;
const uint8_t BME_ADDR_ALTERNATE = 0x77;
#define EEPROM_SALT 12348
#define UPDATE_MODE_TIMEOUT 300000  // 5 минут в режиме обновления

typedef struct {
  int salt = EEPROM_SALT;
  char device_id[33] = "";
  char mqtt_server[41] = "193.107.237.215";
  uint16_t mqtt_port = 1883;
  char mqtt_user[21] = "sensor";
  char mqtt_pass[65] = "sensorpass";
} DeviceConfig;

DeviceConfig config;

// ============ ОБЪЕКТЫ ============
WiFiClient wifiClient;
PubSubClient mqtt(wifiClient);
Adafruit_BME280 bme;
ESP8266WebServer httpServer(80);
ESP8266HTTPUpdateServer httpUpdater;

String deviceId, topicData, topicStatus;
const char* STATUS_ONLINE = "{\"status\":\"online\"}";
const char* STATUS_OFFLINE = "{\"status\":\"offline\"}";
bool shouldSaveConfig = false;
bool updateMode = false;  // Флаг режима обновления

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
    Serial.print("  Device ID: ");
    Serial.println(strlen(config.device_id) > 0 ? config.device_id : "(auto)");
    Serial.print("  MQTT Server: ");
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

// =========== Кнопка сброса и режима обновления ============
void checkResetButton() {
  pinMode(RESET_BUTTON_PIN, INPUT_PULLUP);
  
  if (digitalRead(RESET_BUTTON_PIN) == LOW) {
    Serial.println("Button pressed during boot");
    delay(100);
    
    if (digitalRead(RESET_BUTTON_PIN) == LOW) {
      // Ждем 3 секунды для определения режима
      unsigned long pressStart = millis();
      while (digitalRead(RESET_BUTTON_PIN) == LOW && millis() - pressStart < 3000) {
        delay(10);
      }
      
      unsigned long pressDuration = millis() - pressStart;
      
      if (pressDuration >= 3000) {
        // Долгое нажатие (3+ секунды) = режим обновления
        Serial.println("=== ENTERING UPDATE MODE ===");
        updateMode = true;
      } else {
        // Короткое нажатие = сброс настроек
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
}

// =========== Главная страница HTTP сервера ============
void handleRoot() {
  String html = R"(
<!DOCTYPE html>
<html>
<head>
  <meta charset='UTF-8'>
  <meta name='viewport' content='width=device-width, initial-scale=1'>
  <title>ESP8266 Sensor</title>
  <style>
    body { font-family: Arial; margin: 20px; background: #f0f0f0; }
    .container { max-width: 600px; margin: auto; background: white; padding: 20px; border-radius: 10px; }
    h1 { color: #333; }
    .info { background: #e3f2fd; padding: 15px; margin: 10px 0; border-radius: 5px; }
    .button { 
      display: inline-block; 
      padding: 10px 20px; 
      margin: 10px 5px; 
      background: #2196F3; 
      color: white; 
      text-decoration: none; 
      border-radius: 5px; 
    }
    .button:hover { background: #1976D2; }
  </style>
</head>
<body>
  <div class='container'>
    <h1>🌡️ ESP8266 BME280 Sensor</h1>
    <div class='info'>
      <p><strong>Device ID:</strong> )";
  html += deviceId;
  html += R"(</p>
      <p><strong>IP Address:</strong> )";
  html += WiFi.localIP().toString();
  html += R"(</p>
      <p><strong>MQTT Server:</strong> )";
  html += String(config.mqtt_server) + ":" + String(config.mqtt_port);
  html += R"(</p>
      <p><strong>Mode:</strong> Update Mode (No Sleep)</p>
    </div>
    <a href='/update' class='button'>📦 Update Firmware</a>
    <a href='/restart' class='button'>🔄 Restart</a>
  </div>
</body>
</html>
  )";
  httpServer.send(200, "text/html", html);
}

// =========== Обработчик перезагрузки ============
void handleRestart() {
  String html = R"(
<!DOCTYPE html>
<html>
<head>
  <meta charset='UTF-8'>
  <meta http-equiv='refresh' content='10;url=/'>
  <title>Restarting...</title>
</head>
<body style='font-family:Arial;text-align:center;padding:50px;'>
  <h1>Restarting ESP8266...</h1>
  <p>Device will restart and return to normal mode.</p>
  <p>You will be redirected automatically.</p>
</body>
</html>
  )";
  httpServer.send(200, "text/html", html);
  delay(1000);
  ESP.restart();
}

// =========== SETUP ============
void setup() {
  Serial.begin(115200);
  delay(100);
  Serial.println("\n\n=== ESP8266 BME280 with OTA Update Support ===");
  
  // Проверка кнопки для режима обновления или сброса
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
  
  char port_str[6]; 
  sprintf(port_str, "%d", config.mqtt_port);
  
  WiFiManagerParameter p1("device_id", "Device ID (пустое=авто)", config.device_id, 32);
  WiFiManagerParameter p2("mqtt_server", "MQTT Server", config.mqtt_server, 40);
  WiFiManagerParameter p3("mqtt_port", "MQTT Port", port_str, 5);
  WiFiManagerParameter p4("mqtt_user", "MQTT User", config.mqtt_user, 20);
  WiFiManagerParameter p5("mqtt_pass", "MQTT Pass", config.mqtt_pass, 64);
  
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
  
  Serial.print("WiFi Connected! IP: "); 
  Serial.println(WiFi.localIP());
  
  if (shouldSaveConfig) {
    Serial.println("Saving custom parameters...");
    strncpy(config.device_id, p1.getValue(), 32); 
    config.device_id[32] = '\0';
    strncpy(config.mqtt_server, p2.getValue(), 40); 
    config.mqtt_server[40] = '\0';
    config.mqtt_port = atoi(p3.getValue());
    strncpy(config.mqtt_user, p4.getValue(), 20); 
    config.mqtt_user[20] = '\0';
    
    String tempPass = String(p5.getValue());
    tempPass.trim();
    strncpy(config.mqtt_pass, tempPass.c_str(), 64);
    config.mqtt_pass[64] = '\0';
    
    Serial.printf("Saved MQTT password: [%s] (len=%d)\n", 
                  config.mqtt_pass, strlen(config.mqtt_pass));
    saveConfig();
    shouldSaveConfig = false;
  }
  
  makeIdsAndTopics();
  mqtt.setServer(config.mqtt_server, config.mqtt_port);
  mqtt.setKeepAlive(60);
  mqtt.setBufferSize(256);
  
  // =========== РЕЖИМ ОБНОВЛЕНИЯ ===========
  if (updateMode) {
    Serial.println("\n*** UPDATE MODE ACTIVE ***");
    Serial.println("HTTP Server running on port 80");
    Serial.println("No deep sleep will occur");
    
    // Настройка mDNS для удобного доступа
    String hostname = "esp-" + chipIdHex6();
    hostname.toLowerCase();
    if (MDNS.begin(hostname.c_str())) {
      Serial.printf("mDNS started: http://%s.local\n", hostname.c_str());
      MDNS.addService("http", "tcp", 80);
    }
    
    // Настройка HTTP сервера с OTA обновлением
    httpServer.on("/", handleRoot);
    httpServer.on("/restart", handleRestart);
    httpUpdater.setup(&httpServer, "/update");
    httpServer.begin();
    
    Serial.println("\n=== HOW TO UPDATE FIRMWARE ===");
    Serial.printf("1. Open browser: http://%s\n", WiFi.localIP().toString().c_str());
    Serial.printf("   or: http://%s.local\n", hostname.c_str());
    Serial.println("2. Click 'Update Firmware' button");
    Serial.println("3. Select .bin file and upload");
    Serial.println("4. Wait for update to complete");
    Serial.println("==============================\n");
    
    return; // Не переходим в deep sleep
  }
  
  // =========== ОБЫЧНЫЙ РЕЖИМ (с deep sleep) ===========
  Serial.println("\n*** NORMAL MODE: Sending data and going to sleep ***");
  
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

// =========== LOOP ============
void loop() {
  if (updateMode) {
    // Режим обновления - обрабатываем HTTP запросы
    httpServer.handleClient();
    MDNS.update();
    
    // Автоматический выход из режима обновления через 5 минут
    static unsigned long updateModeStart = millis();
    if (millis() - updateModeStart > UPDATE_MODE_TIMEOUT) {
      Serial.println("Update mode timeout, restarting to normal mode...");
      delay(1000);
      ESP.restart();
    }
  }
  // В обычном режиме loop() не используется (deep sleep)
}
