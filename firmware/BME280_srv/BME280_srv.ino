// ESP8266 + BME280 + WiFiManager с кастомными параметрами
// Все настройки (WiFi + Device ID + MQTT) в одном портале конфигурации

#include <Wire.h>
#include <ESP8266WiFi.h>
#include <PubSubClient.h>
#include <Adafruit_Sensor.h>
#include <Adafruit_BME280.h>
#include <ArduinoJson.h>
#include <WiFiManager.h>
#include <EEPROM.h>

// ==================== ПИНЫ ====================
#define SDA_PIN D2
#define SCL_PIN D1
#define RESET_BUTTON_PIN D5      // Кнопка сброса WiFi (удержать при загрузке)

// ==================== КОНСТАНТЫ ====================
const uint8_t BME_ADDR_PRIMARY   = 0x76;
const uint8_t BME_ADDR_ALTERNATE = 0x77;
const uint32_t PUBLISH_INTERVAL_MS = 10000;
#define EEPROM_SALT 12348  // Версия конфигурации

// ==================== СТРУКТУРА КОНФИГУРАЦИИ ====================
typedef struct {
  int salt = EEPROM_SALT;
  char device_id[33] = "";
  char mqtt_server[41] = "83.219.97.252";
  uint16_t mqtt_port = 1883;
  char mqtt_user[21] = "sensor";
  char mqtt_pass[21] = "sensorpass";
} DeviceConfig;

DeviceConfig config;

// ==================== ГЛОБАЛЬНЫЕ ОБЪЕКТЫ ====================
WiFiClient wifiClient;
PubSubClient mqtt(wifiClient);
Adafruit_BME280 bme;

// ==================== ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ ====================
String deviceId;
String topicData;
String topicStatus;
const char* STATUS_ONLINE  = "{\"status\":\"online\"}";
const char* STATUS_OFFLINE = "{\"status\":\"offline\"}";
uint32_t lastPublishMs = 0;
bool shouldSaveConfig = false;

// ==================== ФУНКЦИИ РАБОТЫ С EEPROM ====================
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

// Callback вызывается когда нужно сохранить конфигурацию
void saveConfigCallback() {
  Serial.println("Should save config flag set");
  shouldSaveConfig = true;
}

// ==================== ФУНКЦИИ DEVICE ID ====================
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
  
  Serial.print("Using Device ID: ");
  Serial.println(deviceId);
  Serial.print("Data Topic: ");
  Serial.println(topicData);
  Serial.print("Status Topic: ");
  Serial.println(topicStatus);
}

// ==================== ФУНКЦИИ BME280 ====================
bool initBME() {
  Wire.begin(SDA_PIN, SCL_PIN);
  if (bme.begin(BME_ADDR_PRIMARY))   return true;
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

// ==================== ФУНКЦИИ MQTT ====================
bool connectMQTT() {
  if (mqtt.connected()) return true;
  
  String cid = "sensor-" + deviceId;
  Serial.print("Connecting MQTT as ");
  Serial.println(cid);
  
  bool ok = mqtt.connect(cid.c_str(),
                         config.mqtt_user, 
                         config.mqtt_pass,
                         topicStatus.c_str(), 
                         0, 
                         true, 
                         STATUS_OFFLINE,
                         true);
  if (ok) {
    mqtt.publish(topicStatus.c_str(), STATUS_ONLINE, true);
    Serial.println("MQTT connected");
  } else {
    Serial.print("MQTT failed, rc=");
    Serial.println(mqtt.state());
  }
  return ok;
}

void ensureConnected() {
  if (WiFi.status() != WL_CONNECTED) return;
  
  if (!mqtt.connected()) {
    mqtt.setServer(config.mqtt_server, config.mqtt_port);
    mqtt.setKeepAlive(30);
    mqtt.setBufferSize(256);
    connectMQTT();
  }
}

void publishTelemetry() {
  float t, h, p;
  if (!readBME(t, h, p)) {
    Serial.println("Failed to read BME280");
    return;
  }

  StaticJsonDocument<128> doc;
  doc["temperature"] = t;
  doc["humidity"]    = h;
  doc["pressure"]    = p;

  String payload;
  payload.reserve(96);
  serializeJson(doc, payload);
  
  if (mqtt.publish(topicData.c_str(), payload.c_str(), false)) {
    Serial.print("Published: ");
    Serial.println(payload);
  }
}

// ==================== КНОПКА СБРОСА ====================
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

// ==================== SETUP ====================
void setup() {
  Serial.begin(115200);
  delay(100);
  Serial.println("\n\n=== ESP8266 BME280 with WiFiManager ===");
  
  pinMode(RESET_BUTTON_PIN, INPUT_PULLUP);
  
  checkResetButton();
  
  // Загрузка конфигурации из EEPROM
  loadConfig();
  
  // Инициализация BME280
  if (!initBME()) {
    Serial.println("BME280 not found");
  } else {
    Serial.println("BME280 initialized");
  }
  
  // ==================== НАСТРОЙКА WIFIMANAGER ====================
  WiFiManager wifiManager;
  
  // Установить callback для сохранения конфигурации
  wifiManager.setSaveConfigCallback(saveConfigCallback);
  
  // Создать кастомные параметры с текущими значениями из EEPROM
  char port_str[6];
  sprintf(port_str, "%d", config.mqtt_port);
  
  WiFiManagerParameter custom_device_id(
    "device_id", 
    "Device ID (пустое = авто)", 
    config.device_id, 
    32
  );
  
  WiFiManagerParameter custom_mqtt_server(
    "mqtt_server", 
    "MQTT Server IP", 
    config.mqtt_server, 
    40
  );
  
  WiFiManagerParameter custom_mqtt_port(
    "mqtt_port", 
    "MQTT Port", 
    port_str, 
    5
  );
  
  WiFiManagerParameter custom_mqtt_user(
    "mqtt_user", 
    "MQTT Username", 
    config.mqtt_user, 
    20
  );
  
  WiFiManagerParameter custom_mqtt_pass(
    "mqtt_pass", 
    "MQTT Password", 
    config.mqtt_pass, 
    20
  );
  
  // Добавить все параметры в портал WiFiManager
  wifiManager.addParameter(&custom_device_id);
  wifiManager.addParameter(&custom_mqtt_server);
  wifiManager.addParameter(&custom_mqtt_port);
  wifiManager.addParameter(&custom_mqtt_user);
  wifiManager.addParameter(&custom_mqtt_pass);
  
  // Настроить таймауты
  wifiManager.setConfigPortalTimeout(180);  // 3 минуты
  
  // Создать уникальное имя точки доступа
  String apName = "ESP-Config-" + chipIdHex6();
  Serial.print("Starting WiFiManager with AP: ");
  Serial.println(apName);
  
  // Попытка автоподключения или запуск портала конфигурации
  if (!wifiManager.autoConnect(apName.c_str())) {
    Serial.println("Failed to connect, restarting...");
    delay(3000);
    ESP.restart();
  }
  
  Serial.println("WiFi connected!");
  Serial.print("IP: ");
  Serial.println(WiFi.localIP());
  
  // ==================== СОХРАНЕНИЕ ПАРАМЕТРОВ ====================
  if (shouldSaveConfig) {
    Serial.println("Saving custom parameters...");
    
    // Получить значения из WiFiManager
    strncpy(config.device_id, custom_device_id.getValue(), 32);
    config.device_id[32] = '\0';
    
    strncpy(config.mqtt_server, custom_mqtt_server.getValue(), 40);
    config.mqtt_server[40] = '\0';
    
    config.mqtt_port = atoi(custom_mqtt_port.getValue());
    
    strncpy(config.mqtt_user, custom_mqtt_user.getValue(), 20);
    config.mqtt_user[20] = '\0';
    
    strncpy(config.mqtt_pass, custom_mqtt_pass.getValue(), 20);
    config.mqtt_pass[20] = '\0';
    
    // Сохранить в EEPROM
    saveConfig();
    
    shouldSaveConfig = false;
  }
  
  // Создание Device ID и топиков на основе конфигурации
  makeIdsAndTopics();
  
  // Настройка MQTT
  mqtt.setServer(config.mqtt_server, config.mqtt_port);
  mqtt.setKeepAlive(30);
  mqtt.setBufferSize(256);
  
  // Первое подключение к MQTT
  if (WiFi.status() == WL_CONNECTED) {
    connectMQTT();
  }
  
  Serial.println("Setup complete!");
}

// ==================== LOOP ====================
void loop() {
  // Поддержание соединений
  ensureConnected();
  mqtt.loop();
  
  // Публикация телеметрии
  uint32_t now = millis();
  if (now - lastPublishMs >= PUBLISH_INTERVAL_MS) {
    lastPublishMs = now;
    if (mqtt.connected()) {
      publishTelemetry();
    }
  }
}
