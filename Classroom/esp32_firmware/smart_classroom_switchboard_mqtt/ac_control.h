/*
  =============================================================================
  ClassPulse IoT - Optical IR Air Conditioner Control Module (ac_control.h)
  =============================================================================
  Dedicated ESP32 IR AC Control Logic for Gree Air Conditioners (GPIO 4).
  • Operates the classroom AC via Optical Infrared (IRremoteESP8266 / IRGreeAC).
  • Completely bypasses the 4 mechanical relays so relays never chatter or wear.
  • Supports JSON and plain-text MQTT payloads:
      - Power state ("ON", "OFF", "TOGGLE")
      - Temperature (16°C – 30°C)
      - Mode ("COOL", "AUTO", "DRY", "FAN", "HEAT")
      - Fan Speed (0 = Auto, 1 = Low, 2 = Med, 3 = High)
      - Vertical Louver Swing (true = Auto Swing, false = Fixed Upward)
      - Turbo & Sleep modes
  =============================================================================
*/

#pragma once

#include <Arduino.h>
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

// Default GPIO 4 for Optical IR Transmitter LED
#ifndef IR_LED_PIN
  #define IR_LED_PIN 4
#endif

struct AcState {
  bool   isOn;
  int    temperature; // 16 - 30 °C
  String mode;        // "COOL", "AUTO", "DRY", "FAN", "HEAT"
  int    fanSpeed;    // 0 = Auto, 1 = Low, 2 = Med, 3 = High
  bool   swing;       // true = Auto Vertical Swing, false = Fixed Upward
  bool   turbo;       // true = Turbo fast cooling
};

class ClassroomAcController {
public:
  IRGreeAC irAc;
  AcState state;

  ClassroomAcController(uint16_t irPin = IR_LED_PIN)
    : irAc(irPin),
      state{false, 24, "COOL", 0, false, false},
      _irPin(irPin) {}

  void begin() {
    irAc.begin();
    irAc.setMode(kGreeCool);
    irAc.setTemp(state.temperature);
    irAc.setFan(state.fanSpeed);
    irAc.setSwingVertical(false, kGreeSwingUp);
    irAc.setTurbo(false);
    irAc.setSleep(false);
    irAc.setLight(true);
    Serial.printf("❄️ [IR AC] Gree AC Optical Controller initialized on GPIO %d (Relays Bypassed)\n", _irPin);
  }

  void publishStatus(PubSubClient& mqtt, const char* classroomId, int zoneId, int boardId) {
    if (!mqtt.connected()) return;

    JSON_DOC(doc, 256);
    doc["room"]     = classroomId;
    doc["zone"]     = zoneId;
    doc["board"]    = boardId;
    doc["type"]     = "ac";
    doc["state"]    = state.isOn ? "ON" : "OFF";
    doc["temp"]     = state.temperature;
    doc["mode"]     = state.mode;
    doc["fan"]      = state.fanSpeed;
    doc["swing"]    = state.swing;
    doc["turbo"]    = state.turbo;
    doc["gpio"]     = _irPin;
    doc["protocol"] = "GREE";

    char buffer[256];
    serializeJson(doc, buffer, sizeof(buffer));

    String baseTopic = "ruet/classroom/" + String(classroomId);
    String zoneTopic = baseTopic + "/zone/" + String(zoneId);

    // 1. Zone AC Status: ruet/classroom/<CLASSROOM_ID>/zone/<ZONE_ID>/ac/status
    mqtt.publish((zoneTopic + "/ac/status").c_str(), buffer, false);
    // 2. Global AC Status: ruet/classroom/<CLASSROOM_ID>/status/ac
    mqtt.publish((baseTopic + "/status/ac").c_str(), buffer, false);
    // 3. Board AC Status: ruet/classroom/<CLASSROOM_ID>/status/board/<ZONE_ID>/ac
    mqtt.publish((baseTopic + "/status/board/" + String(zoneId) + "/ac").c_str(), buffer, false);

    Serial.printf("📡 [MQTT] AC Status -> %s (%d°C, %s, Fan %d, Swing %s)\n",
                  state.isOn ? "ON" : "OFF", state.temperature, state.mode.c_str(),
                  state.fanSpeed, state.swing ? "ON" : "OFF");
  }

  void executeControl(
    bool turnOn,
    int temp,
    String mode,
    int fan,
    bool swing,
    PubSubClient* mqtt = nullptr,
    const char* classroomId = "",
    int zoneId = 1,
    int boardId = 1,
    bool publishFeedback = true
  ) {
    state.isOn = turnOn;
    state.temperature = constrain(temp, 16, 30);
    mode.toUpperCase();
    state.mode = mode;
    state.fanSpeed = constrain(fan, 0, 3);
    state.swing = swing;

    if (turnOn) {
      irAc.on();
      irAc.setTemp(state.temperature);
      if (mode == "COOL") irAc.setMode(kGreeCool);
      else if (mode == "DRY") irAc.setMode(kGreeDry);
      else if (mode == "FAN") irAc.setMode(kGreeFan);
      else if (mode == "HEAT") irAc.setMode(kGreeHeat);
      else irAc.setMode(kGreeAuto);

      irAc.setFan(state.fanSpeed);
      if (state.swing) {
        irAc.setSwingVertical(true, kGreeSwingAuto);
      } else {
        irAc.setSwingVertical(false, kGreeSwingUp);
      }
      irAc.setTurbo(state.turbo);
      irAc.setLight(true);
      irAc.send();
      Serial.printf("❄️ [IR AC] Sent IR Command: ON, %d°C, %s, Fan %d, Swing %s via GPIO %d (RELAYS BYPASSED)\n",
                    state.temperature, state.mode.c_str(), state.fanSpeed,
                    state.swing ? "AUTO" : "FIXED", _irPin);
    } else {
      irAc.off();
      irAc.send();
      Serial.printf("❄️ [IR AC] Sent IR Command: OFF via GPIO %d (RELAYS BYPASSED)\n", _irPin);
    }

    if (publishFeedback && mqtt != nullptr && mqtt->connected()) {
      publishStatus(*mqtt, classroomId, zoneId, boardId);
    }
  }

  void handleCommand(
    String msg,
    PubSubClient* mqtt = nullptr,
    const char* classroomId = "",
    int zoneId = 1,
    int boardId = 1
  ) {
    bool turnOn = state.isOn;
    int targetTemp = state.temperature;
    String targetMode = state.mode;
    int targetFan = state.fanSpeed;
    bool targetSwing = state.swing;

    if (msg.startsWith("{")) {
      JSON_DOC(doc, 384);
      DeserializationError err = deserializeJson(doc, msg);
      if (!err) {
        JsonVariant src = doc["ac"].is<JsonObject>() ? doc["ac"] : doc.as<JsonVariant>();
        if (!src["state"].isNull()) {
          String st = src["state"].as<String>();
          st.toUpperCase();
          turnOn = (st == "ON" || st == "1" || st == "TRUE");
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
          state.turbo = src["turbo"].as<bool>();
        }
      }
    } else {
      if (msg.equalsIgnoreCase("ON") || msg == "1" || msg.equalsIgnoreCase("TRUE")) {
        turnOn = true;
      } else if (msg.equalsIgnoreCase("OFF") || msg == "0" || msg.equalsIgnoreCase("FALSE")) {
        turnOn = false;
      } else if (msg.equalsIgnoreCase("TOGGLE")) {
        turnOn = !state.isOn;
      }
    }

    executeControl(turnOn, targetTemp, targetMode, targetFan, targetSwing, mqtt, classroomId, zoneId, boardId, true);
  }

private:
  uint16_t _irPin;
};
