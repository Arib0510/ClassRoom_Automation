/*
  =============================================================================
  ClassPulse IoT - Standalone Dual-Gree AC Optical IR Module (ac_control.h)
  =============================================================================
  Dedicated ESP32 Standalone AC Controller Logic ("zone_ac", "ac_unit"):
  • Runs on an independent ESP32 board with TWO IR Transmitter/Receiver circuits
    controlling the TWO Gree Air Conditioners in the classroom:
      - Gree AC #1 (Front / Unit 1): IR Transmitter on GPIO 33
      - Gree AC #2 (Back  / Unit 2): IR Transmitter on GPIO 12
  • Completely isolated from the 8-switch zone switchboards (Zones 1, 2, 3).
  • Publishes MQTT Discovery payload to `home/discovery`:
      {"zone_id": "zone_ac", "device_type": "ac_unit", "ip": "192.168.X.X",
       "ac_count": 2, "ac1_gpio": 33, "ac2_gpio": 12, "protocol": "GREE"}
  =============================================================================
*/

#pragma once

#include <Arduino.h>
#include <WiFi.h>
#include <PubSubClient.h>
#include <ArduinoJson.h>
#include <IRremoteESP8266.h>
#include <IRsend.h>
#include <ir_Gree.h>

#if ARDUINOJSON_VERSION_MAJOR >= 7
  #ifndef JSON_DOC
    #define JSON_DOC(name, size) JsonDocument name
  #endif
#else
  #ifndef JSON_DOC
    #define JSON_DOC(name, size) StaticJsonDocument<size> name
  #endif
#endif

// Dual IR Transmitter GPIOs for the Two Classroom Gree ACs
#ifndef AC1_IR_PIN
  #define AC1_IR_PIN 33   // GPIO 33: IR Transmitter Circuit #1 -> Gree AC #1
#endif

#ifndef AC2_IR_PIN
  #define AC2_IR_PIN 12   // GPIO 12: IR Transmitter Circuit #2 -> Gree AC #2
#endif

#define AC_ZONE_ID_STR     "zone_ac"
#define AC_DEVICE_TYPE     "ac_unit"
#define AC_DISCOVERY_TOPIC "home/discovery"

struct AcUnitState {
  int      unitId;      // 1 or 2
  uint16_t irPin;       // GPIO 33 (AC 1) or GPIO 12 (AC 2)
  bool     isOn;
  int      temperature; // 16 - 30 °C
  String   mode;        // "COOL", "AUTO", "DRY", "FAN", "HEAT"
  int      fanSpeed;    // 0 = Auto, 1 = Low, 2 = Med, 3 = High
  bool     swing;       // true = Auto Vertical Swing, false = Fixed Upward
  bool     turbo;
};

class StandaloneDualAcController {
public:
  IRGreeAC irAc1;
  IRGreeAC irAc2;
  AcUnitState units[2];
  bool emergencyLocked;

  StandaloneDualAcController(
    uint16_t ac1Pin = AC1_IR_PIN,
    uint16_t ac2Pin = AC2_IR_PIN
  )
    : irAc1(ac1Pin),
      irAc2(ac2Pin),
      units{
        {1, ac1Pin, false, 24, "COOL", 0, false, false},
        {2, ac2Pin, false, 24, "COOL", 0, false, false}
      },
      emergencyLocked(false) {}

  void begin() {
    irAc1.begin();
    irAc2.begin();
    for (int i = 0; i < 2; i++) {
      IRGreeAC& ir = (i == 0) ? irAc1 : irAc2;
      ir.setMode(kGreeCool);
      ir.setTemp(units[i].temperature);
      ir.setFan(units[i].fanSpeed);
      ir.setSwingVertical(false, kGreeSwingUp);
      ir.setTurbo(false);
      ir.setSleep(false);
      ir.setLight(true);
    }
    Serial.printf("❄️ [STANDALONE DUAL-AC] Initialized 2 Gree IR Circuits: AC #1 on GPIO %d | AC #2 on GPIO %d\n",
                  units[0].irPin, units[1].irPin);
  }

  void publishDiscovery(PubSubClient& mqtt, const char* classroomId = "reb_room_301", int boardId = 4) {
    if (!mqtt.connected()) return;

    JSON_DOC(doc, 512);
    doc["zone_id"]     = AC_ZONE_ID_STR;   // "zone_ac"
    doc["device_type"] = AC_DEVICE_TYPE;   // "ac_unit"
    doc["ip"]          = WiFi.localIP().toString();
    doc["room"]        = classroomId;
    doc["zone"]        = boardId;
    doc["board"]       = boardId;
    doc["mac"]         = WiFi.macAddress();
    doc["rssi"]        = WiFi.RSSI();
    doc["protocol"]    = "GREE";
    doc["ac_count"]    = 2;
    doc["ac1_gpio"]    = units[0].irPin;   // GPIO 33
    doc["ac2_gpio"]    = units[1].irPin;   // GPIO 12
    doc["ac1_state"]   = units[0].isOn ? "ON" : "OFF";
    doc["ac2_state"]   = units[1].isOn ? "ON" : "OFF";
    doc["status"]      = "ONLINE";

    char buffer[512];
    serializeJson(doc, buffer, sizeof(buffer));

    String baseTopic = "ruet/classroom/" + String(classroomId);
    mqtt.publish(AC_DISCOVERY_TOPIC, buffer, false);
    mqtt.publish((baseTopic + "/discovery").c_str(), buffer, false);
    mqtt.publish((baseTopic + "/status/board/" + String(boardId)).c_str(), buffer, false);

    Serial.printf("🔍 [AC DISCOVERY] Published to %s => %s\n", AC_DISCOVERY_TOPIC, buffer);
  }

  void publishUnitStatus(int unitNum, PubSubClient& mqtt, const char* classroomId = "reb_room_301") {
    if (!mqtt.connected() || unitNum < 1 || unitNum > 2) return;
    const AcUnitState& u = units[unitNum - 1];

    JSON_DOC(doc, 384);
    doc["room"]        = classroomId;
    doc["zone_id"]     = AC_ZONE_ID_STR;
    doc["device_type"] = AC_DEVICE_TYPE;
    doc["ac_unit"]     = u.unitId;
    doc["zone"]        = u.unitId;
    doc["board"]       = u.unitId;
    doc["type"]        = "ac";
    doc["state"]       = u.isOn ? "ON" : "OFF";
    doc["temp"]        = u.temperature;
    doc["mode"]        = u.mode;
    doc["fan"]         = u.fanSpeed;
    doc["swing"]       = u.swing;
    doc["turbo"]       = u.turbo;
    doc["gpio"]        = u.irPin;
    doc["protocol"]    = "GREE";

    char buffer[384];
    serializeJson(doc, buffer, sizeof(buffer));

    String baseTopic = "ruet/classroom/" + String(classroomId);
    // 1. Unit-specific status: ruet/classroom/<room>/zone/<1|2>/ac/status
    mqtt.publish((baseTopic + "/zone/" + String(u.unitId) + "/ac/status").c_str(), buffer, false);
    mqtt.publish((baseTopic + "/status/board/" + String(u.unitId) + "/ac").c_str(), buffer, false);
    // 2. Global AC status & home/zone_ac/status
    mqtt.publish((baseTopic + "/status/ac").c_str(), buffer, false);
    mqtt.publish("home/zone_ac/status", buffer, false);

    Serial.printf("📡 [MQTT AC #%d SYNC] Gree IR on GPIO %d -> %s (%d°C, %s, Fan %d, Swing %s)\n",
                  u.unitId, u.irPin, u.isOn ? "ON" : "OFF",
                  u.temperature, u.mode.c_str(), u.fanSpeed, u.swing ? "ON" : "OFF");
  }

  void publishAllStatus(PubSubClient& mqtt, const char* classroomId = "reb_room_301") {
    publishUnitStatus(1, mqtt, classroomId);
    publishUnitStatus(2, mqtt, classroomId);
  }

  void executeUnitControl(
    int unitNum,
    bool turnOn,
    int temp,
    String mode,
    int fan,
    bool swing,
    PubSubClient* mqtt = nullptr,
    const char* classroomId = "reb_room_301",
    bool publishFeedback = true
  ) {
    if (unitNum < 1 || unitNum > 2) return;
    if (emergencyLocked) turnOn = false;

    AcUnitState& u = units[unitNum - 1];
    IRGreeAC& ir = (unitNum == 1) ? irAc1 : irAc2;

    u.isOn = turnOn;
    u.temperature = constrain(temp, 16, 30);
    mode.toUpperCase();
    u.mode = mode;
    u.fanSpeed = constrain(fan, 0, 3);
    u.swing = swing;

    if (turnOn) {
      ir.on();
      ir.setTemp(u.temperature);
      if (mode == "COOL") ir.setMode(kGreeCool);
      else if (mode == "DRY") ir.setMode(kGreeDry);
      else if (mode == "FAN") ir.setMode(kGreeFan);
      else if (mode == "HEAT") ir.setMode(kGreeHeat);
      else ir.setMode(kGreeAuto);

      ir.setFan(u.fanSpeed);
      if (u.swing) {
        ir.setSwingVertical(true, kGreeSwingAuto);
      } else {
        ir.setSwingVertical(false, kGreeSwingUp);
      }
      ir.setTurbo(u.turbo);
      ir.setLight(true);
      ir.send();
      Serial.printf("❄️ [GREE IR #%d] Sent IR ON (%d°C, %s, Fan %d, Swing %s) via GPIO %d\n",
                    u.unitId, u.temperature, u.mode.c_str(), u.fanSpeed,
                    u.swing ? "AUTO" : "FIXED", u.irPin);
    } else {
      ir.off();
      ir.send();
      Serial.printf("❄️ [GREE IR #%d] Sent IR OFF via GPIO %d\n", u.unitId, u.irPin);
    }

    if (publishFeedback && mqtt != nullptr && mqtt->connected()) {
      publishUnitStatus(unitNum, *mqtt, classroomId);
    }
  }

  // Handles MQTT AC command for Unit 1 (GPIO 33), Unit 2 (GPIO 12), or Both (targetUnit = 0)
  void handleCommand(
    String msg,
    PubSubClient* mqtt = nullptr,
    const char* classroomId = "reb_room_301",
    int defaultUnit = 0 // 0 = infer from payload (or apply to both if unspecified), 1 = AC #1 (GPIO 33), 2 = AC #2 (GPIO 12)
  ) {
    int targetUnit = defaultUnit;

    if (msg.startsWith("{")) {
      JSON_DOC(doc, 512);
      DeserializationError err = deserializeJson(doc, msg);
      if (!err) {
        JsonVariant src = doc["ac"].is<JsonObject>() ? doc["ac"] : doc.as<JsonVariant>();

        // Determine whether this command targets AC #1 (GPIO 33) or AC #2 (GPIO 12)
        int gpio = src["gpio"] | (doc["gpio"] | 0);
        int acUnit = src["ac_unit"] | (doc["ac_unit"] | 0);
        int zone = src["zone"] | (doc["zone"] | 0);
        int relay = src["relay"] | (doc["relay"] | 0);
        String idStr = doc["id"] | (doc["appliance_id"] | "");

        if (gpio == AC2_IR_PIN || acUnit == 2 || zone == 2 || relay == 2 ||
            idStr.indexOf("ac_2") != -1 || idStr.indexOf("ac2") != -1 || idStr.endsWith("-2")) {
          targetUnit = 2;
        } else if (gpio == AC1_IR_PIN || acUnit == 1 || zone == 1 || relay == 1 ||
                   idStr.indexOf("ac_1") != -1 || idStr.indexOf("ac1") != -1 || idStr.endsWith("-1")) {
          targetUnit = 1;
        }

        int startUnit = (targetUnit == 2) ? 2 : 1;
        int endUnit   = (targetUnit == 1) ? 1 : 2;

        for (int uIdx = startUnit; uIdx <= endUnit; uIdx++) {
          AcUnitState& cur = units[uIdx - 1];
          bool turnOn = cur.isOn;
          int targetTemp = cur.temperature;
          String targetMode = cur.mode;
          int targetFan = cur.fanSpeed;
          bool targetSwing = cur.swing;

          if (!src["state"].isNull()) {
            String st = src["state"].as<String>();
            st.toUpperCase();
            if (st == "TOGGLE") turnOn = !cur.isOn;
            else turnOn = (st == "ON" || st == "1" || st == "TRUE");
          } else if (!doc["desired_state"].isNull()) {
            String st = doc["desired_state"].as<String>();
            st.toUpperCase();
            turnOn = (st == "ON" || st == "1" || st == "TRUE");
          }
          if (!src["temp"].isNull()) {
            targetTemp = constrain(src["temp"].as<int>(), 16, 30);
          }
          if (!src["mode"].isNull()) {
            targetMode = src["mode"].as<String>();
          }
          if (!src["fan"].isNull()) {
            targetFan = constrain(src["fan"].as<int>(), 0, 3);
          }
          if (!src["speed"].isNull() && src["fan"].isNull()) {
            int spd = src["speed"].as<int>();
            targetFan = (spd == 0) ? 0 : constrain(spd - 1, 1, 3);
          }
          if (!src["swing"].isNull()) {
            targetSwing = src["swing"].as<bool>();
          }
          if (!src["turbo"].isNull()) {
            cur.turbo = src["turbo"].as<bool>();
          }

          executeUnitControl(uIdx, turnOn, targetTemp, targetMode, targetFan, targetSwing, mqtt, classroomId, true);
        }
        return;
      }
    }

    // Plain-text command ("ON", "OFF", "TOGGLE")
    int startUnit = (targetUnit == 2) ? 2 : 1;
    int endUnit   = (targetUnit == 1) ? 1 : 2;
    for (int uIdx = startUnit; uIdx <= endUnit; uIdx++) {
      AcUnitState& cur = units[uIdx - 1];
      bool turnOn = cur.isOn;
      if (msg.equalsIgnoreCase("ON") || msg == "1" || msg.equalsIgnoreCase("TRUE") || msg.equalsIgnoreCase("ALL_ON")) {
        turnOn = true;
      } else if (msg.equalsIgnoreCase("OFF") || msg == "0" || msg.equalsIgnoreCase("FALSE") || msg.equalsIgnoreCase("ALL_OFF")) {
        turnOn = false;
      } else if (msg.equalsIgnoreCase("TOGGLE")) {
        turnOn = !cur.isOn;
      }
      executeUnitControl(uIdx, turnOn, cur.temperature, cur.mode, cur.fanSpeed, cur.swing, mqtt, classroomId, true);
    }
  }
};
