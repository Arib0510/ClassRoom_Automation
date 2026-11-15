/*
  =============================================================================
  RUET Smart Classroom IoT - Dedicated Optical IR AC Controller (ESP32)
  =============================================================================
  Standalone firmware for controlling a classroom Gree Air Conditioner via an
  IR Transmitter LED on GPIO 4 over MQTT (synced with Raspberry Pi 5 Vision &
  ClassPulse Flutter App).
  =============================================================================
*/

#include <WiFi.h>
#include <PubSubClient.h>
#include <ArduinoJson.h>
#include "../smart_classroom_switchboard_mqtt/ac_control.h"

#define CLASSROOM_ID      "reb_room_301"
#define ZONE_ID           1
#define BOARD_ID          ZONE_ID

#define WIFI_SSID         "S 23"
#define WIFI_PASSWORD     "asdf1234"

const char* MQTT_BROKER   = "broker.emqx.io";
const int   MQTT_PORT     = 1883;

WiFiClient espClient;
PubSubClient mqtt(espClient);
ClassroomAcController acController(IR_LED_PIN);

unsigned long lastHeartbeat = 0;
unsigned long lastMqttRetry = 0;

inline String getBaseTopic() {
  return "ruet/classroom/" + String(CLASSROOM_ID);
}

inline String getZoneTopic() {
  return getBaseTopic() + "/zone/" + String(ZONE_ID);
}

void onMqttMessage(char* topic, byte* payload, unsigned int length) {
  String strTopic = String(topic);
  if (strTopic.endsWith("/status") || strTopic.indexOf("/status") != -1) {
    return;
  }

  String msg = "";
  for (unsigned int i = 0; i < length; i++) {
    msg += (char)payload[i];
  }
  msg.trim();

  if (strTopic.endsWith("/ac/command") ||
      strTopic.endsWith("/ac/set") ||
      strTopic.endsWith("/ac")) {
    acController.handleCommand(msg, &mqtt, CLASSROOM_ID, ZONE_ID, BOARD_ID);
    return;
  }

  if (strTopic.endsWith("/command/all")) {
    bool turnOn = (msg.equalsIgnoreCase("ALL_ON") || msg.equalsIgnoreCase("ON") || msg == "1");
    if (!turnOn) {
      acController.executeControl(
        false,
        acController.state.temperature,
        acController.state.mode,
        acController.state.fanSpeed,
        acController.state.swing,
        &mqtt,
        CLASSROOM_ID,
        ZONE_ID,
        BOARD_ID,
        true
      );
    }
    return;
  }

  if (strTopic.endsWith("/command/query") || strTopic.endsWith("/query")) {
    acController.publishStatus(mqtt, CLASSROOM_ID, ZONE_ID, BOARD_ID);
    return;
  }
}

void connectWifi() {
  if (WiFi.status() == WL_CONNECTED) return;
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  int retry = 0;
  while (WiFi.status() != WL_CONNECTED && retry < 25) {
    delay(500);
    retry++;
  }
}

void connectMqtt() {
  if (mqtt.connected() || WiFi.status() != WL_CONNECTED) return;
  String clientId = "ESP32_AC_Zone_" + String(ZONE_ID) + "_" + String((uint32_t)ESP.getEfuseMac(), HEX);
  if (mqtt.connect(clientId.c_str())) {
    mqtt.subscribe((getZoneTopic() + "/ac/#").c_str(), 1);
    mqtt.subscribe((getBaseTopic() + "/ac/#").c_str(), 1);
    mqtt.subscribe((getBaseTopic() + "/command/#").c_str(), 1);
    mqtt.subscribe("ruet/classroom/all/command/query", 1);
    acController.publishStatus(mqtt, CLASSROOM_ID, ZONE_ID, BOARD_ID);
  }
}

void setup() {
  Serial.begin(115200);
  delay(500);
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
  if (millis() - lastHeartbeat >= 15000) {
    lastHeartbeat = millis();
    acController.publishStatus(mqtt, CLASSROOM_ID, ZONE_ID, BOARD_ID);
  }
}
