/*
  =============================================================================
  RUET Smart Classroom / Smart Home IoT - Standalone Dual-AC IR Controller
  =============================================================================
  Standalone ESP32 firmware for the classroom Dual-Gree Air Conditioner module:
  • Unique Identifier:
      - zone_id:     "zone_ac"
      - device_type: "ac_unit"
  • Hardware GPIO Mapping (2 IR Transmitter/Receiver Circuits for 2 Gree ACs):
      - Gree AC #1 (Front / Unit 1): IR Transmitter on GPIO 33
      - Gree AC #2 (Back  / Unit 2): IR Transmitter on GPIO 12
  • Strictly isolated from the 8-switch zone boards (Zones 1, 2, and 3).
  • Publishes MQTT Discovery Payload to `home/discovery` on boot & scan:
      {"zone_id": "zone_ac", "device_type": "ac_unit", "ip": "192.168.X.X",
       "ac_count": 2, "ac1_gpio": 33, "ac2_gpio": 12, "protocol": "GREE"}
  =============================================================================
*/

#include <WiFi.h>
#include <PubSubClient.h>
#include <ArduinoJson.h>
#include "../smart_classroom_switchboard_mqtt/ac_control.h"

#define CLASSROOM_ID      "reb_room_301"
#define AC_BOARD_ID       4                // Board 4 = Standalone Dual-AC Controller (zone_ac)

#define WIFI_SSID         "S 23"
#define WIFI_PASSWORD     "asdf1234"

const char* MQTT_BROKER   = "broker.emqx.io";
const int   MQTT_PORT     = 1883;

WiFiClient espClient;
PubSubClient mqtt(espClient);
StandaloneDualAcController acController(AC1_IR_PIN, AC2_IR_PIN);

unsigned long lastHeartbeat = 0;
unsigned long lastMqttRetry = 0;

inline String getBaseTopic() {
  return "ruet/classroom/" + String(CLASSROOM_ID);
}

void onMqttMessage(char* topic, byte* payload, unsigned int length) {
  String strTopic = String(topic);
  if (strTopic.endsWith("/status") || strTopic.indexOf("/status") != -1 || strTopic == AC_DISCOVERY_TOPIC) {
    return;
  }

  String msg = "";
  for (unsigned int i = 0; i < length; i++) {
    msg += (char)payload[i];
  }
  msg.trim();

  Serial.printf("\n📩 [DUAL-AC MQTT RX] %s => %s\n", topic, msg.c_str());

  // 1. Unified Discovery & Status Scan Query
  if (strTopic == "home/discovery/query" ||
      strTopic.endsWith("/command/query") ||
      strTopic.endsWith("/query")) {
    acController.publishDiscovery(mqtt, CLASSROOM_ID, AC_BOARD_ID);
    acController.publishAllStatus(mqtt, CLASSROOM_ID);
    return;
  }

  // 2. Emergency Cutoff (Turns OFF both Gree ACs via IR on GPIO 33 & GPIO 13)
  if (strTopic.endsWith("/command/emergency")) {
    acController.emergencyLocked = (msg.equalsIgnoreCase("CUTOFF") || msg.equalsIgnoreCase("LOCK") || msg == "1");
    acController.executeUnitControl(1, false, acController.units[0].temperature, acController.units[0].mode, acController.units[0].fanSpeed, acController.units[0].swing, &mqtt, CLASSROOM_ID, true);
    acController.executeUnitControl(2, false, acController.units[1].temperature, acController.units[1].mode, acController.units[1].fanSpeed, acController.units[1].swing, &mqtt, CLASSROOM_ID, true);
    return;
  }

  // 3. Room / Zone Master Power
  if (strTopic.endsWith("/command/all")) {
    bool turnOn = (msg.equalsIgnoreCase("ALL_ON") || msg.equalsIgnoreCase("ON") || msg == "1");
    if (strTopic.indexOf("/zone/1/") != -1 || strTopic.indexOf("/board/1/") != -1) {
      acController.executeUnitControl(1, turnOn, acController.units[0].temperature, acController.units[0].mode, acController.units[0].fanSpeed, acController.units[0].swing, &mqtt, CLASSROOM_ID, true);
    } else if (strTopic.indexOf("/zone/2/") != -1 || strTopic.indexOf("/board/2/") != -1) {
      acController.executeUnitControl(2, turnOn, acController.units[1].temperature, acController.units[1].mode, acController.units[1].fanSpeed, acController.units[1].swing, &mqtt, CLASSROOM_ID, true);
    } else {
      acController.executeUnitControl(1, turnOn, acController.units[0].temperature, acController.units[0].mode, acController.units[0].fanSpeed, acController.units[0].swing, &mqtt, CLASSROOM_ID, true);
      acController.executeUnitControl(2, turnOn, acController.units[1].temperature, acController.units[1].mode, acController.units[1].fanSpeed, acController.units[1].swing, &mqtt, CLASSROOM_ID, true);
    }
    return;
  }

  // 4. Dedicated AC Control Commands (AC #1 on GPIO 33, AC #2 on GPIO 13, or Both)
  int topicUnit = 0;
  if (strTopic.indexOf("/ac/1") != -1 || strTopic.indexOf("/zone/1/ac") != -1 || strTopic.indexOf("/board/1/ac") != -1) {
    topicUnit = 1;
  } else if (strTopic.indexOf("/ac/2") != -1 || strTopic.indexOf("/zone/2/ac") != -1 || strTopic.indexOf("/board/2/ac") != -1) {
    topicUnit = 2;
  }

  if (strTopic.indexOf("/ac") != -1 ||
      strTopic.indexOf("zone_ac") != -1 ||
      strTopic.indexOf("/zone/4") != -1 ||
      strTopic.indexOf("/board/4") != -1) {
    acController.handleCommand(msg, &mqtt, CLASSROOM_ID, topicUnit);
    return;
  }
}

void connectWifi() {
  if (WiFi.status() == WL_CONNECTED) return;
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  int retry = 0;
  while (WiFi.status() != WL_CONNECTED && retry < 20) {
    delay(250);
    retry++;
  }
}

void connectMqtt() {
  if (mqtt.connected() || WiFi.status() != WL_CONNECTED) return;

  String clientId = "ESP32_Standalone_DualAC_" + String((uint32_t)ESP.getEfuseMac(), HEX);
  String lwtTopic = getBaseTopic() + "/status/board/" + String(AC_BOARD_ID);
  String lwtMsg   = "{\"status\":\"OFFLINE\",\"zone_id\":\"zone_ac\",\"device_type\":\"ac_unit\",\"board\":4}";

  if (mqtt.connect(clientId.c_str(), lwtTopic.c_str(), 1, true, lwtMsg.c_str())) {
    mqtt.subscribe("home/discovery/query", 1);
    mqtt.subscribe("home/zone_ac/#", 1);
    mqtt.subscribe((getBaseTopic() + "/ac/#").c_str(), 1);
    mqtt.subscribe((getBaseTopic() + "/zone/ac/#").c_str(), 1);
    mqtt.subscribe((getBaseTopic() + "/zone/1/ac/#").c_str(), 1);
    mqtt.subscribe((getBaseTopic() + "/zone/2/ac/#").c_str(), 1);
    mqtt.subscribe((getBaseTopic() + "/board/1/ac/#").c_str(), 1);
    mqtt.subscribe((getBaseTopic() + "/board/2/ac/#").c_str(), 1);
    mqtt.subscribe((getBaseTopic() + "/zone/4/#").c_str(), 1);
    mqtt.subscribe((getBaseTopic() + "/board/4/#").c_str(), 1);
    mqtt.subscribe((getBaseTopic() + "/command/#").c_str(), 1);
    mqtt.subscribe("ruet/classroom/all/command/query", 1);

    // Publish MQTT Discovery (`home/discovery`) and live AC Status for both Gree ACs on connect
    acController.publishDiscovery(mqtt, CLASSROOM_ID, AC_BOARD_ID);
    acController.publishAllStatus(mqtt, CLASSROOM_ID);
  }
}

void setup() {
  Serial.begin(115200);
  delay(500);
  Serial.println("\n==============================================================");
  Serial.println("  Smart Classroom Standalone Dual-Gree AC Controller (zone_ac)");
  Serial.println("  Gree AC #1 IR: GPIO 33 | Gree AC #2 IR: GPIO 12");
  Serial.println("==============================================================");

  acController.begin();
  connectWifi();
  mqtt.setServer(MQTT_BROKER, MQTT_PORT);
  mqtt.setCallback(onMqttMessage);
  mqtt.setBufferSize(512);
}

void loop() {
  if (WiFi.status() != WL_CONNECTED) {
    connectWifi();
  }
  if (WiFi.status() == WL_CONNECTED && !mqtt.connected()) {
    unsigned long now = millis();
    if (now - lastMqttRetry >= 3000) {
      lastMqttRetry = now;
      connectMqtt();
    }
  }

  mqtt.loop();

  if (millis() - lastHeartbeat >= 12000) {
    lastHeartbeat = millis();
    if (mqtt.connected()) {
      acController.publishDiscovery(mqtt, CLASSROOM_ID, AC_BOARD_ID);
      acController.publishAllStatus(mqtt, CLASSROOM_ID);
    }
  }
}
