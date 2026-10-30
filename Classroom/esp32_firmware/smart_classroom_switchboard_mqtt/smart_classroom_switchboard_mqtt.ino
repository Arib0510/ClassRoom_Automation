/*
  =============================================================================
  RUET Smart Classroom IoT - 4-Channel Switchboard Controller (MQTT Edition)
  =============================================================================
  Project: ClassPulse IoT (Smart Classroom Management System)
  Target: ESP32 Dev Module / ESP32-WROOM-32 / ESP32-WROVER

  System Architecture & Hierarchy:
    Room (e.g. "room_304")
      └── Zone (Zone 1, Zone 2, Zone 3)  <-- Physical Switchboard (ESP32)
            └── Relay (Relays 1, 2, 3, 4)  <-- 4-Channel Relay Module

  Hardware Setup:
    • Exactly 3 Zones per Classroom (Zone 1, Zone 2, Zone 3)
    • Each Zone represents 1 physical Switchboard driven by its own ESP32
    • Each ESP32 drives a 4-channel relay module (4 devices per board)
    • Total per room: 3 ESP32s and 12 controllable devices

  Cross-Talk & Room Isolation:
    • Zone Isolation: Board 1 subscribes ONLY to .../zone/1/# and .../board/1/#.
      Toggling switches in Zone 1 will NEVER affect Zone 2 or Zone 3.
    • Room Isolation: Subscribes strictly to assigned CLASSROOM_ID.
      No '+' wildcards. Room 101 will NEVER trigger Room 304.

  Required Arduino IDE Libraries:
    1. PubSubClient by Nick O'Leary (Install via Arduino Library Manager)
    2. ArduinoJson by Benoit Blanchon (v6 or v7)
    3. IRremoteESP8266 by David Conran et al. (Install via Arduino Library Manager)
    4. WiFi (ESP32 built-in)
  =============================================================================
*/

#include <WiFi.h>
#include <PubSubClient.h>
#include <ArduinoJson.h>
#include <IRremoteESP8266.h>
#include <IRsend.h>
#include <ir_Gree.h>

// Version-adaptive ArduinoJson macro
#if ARDUINOJSON_VERSION_MAJOR >= 7
  #define JSON_DOC(name, size) JsonDocument name
#else
  #define JSON_DOC(name, size) StaticJsonDocument<size> name
#endif

// =============================================================================
// IR TRANSMITTER (GREE AIR CONDITIONER DIRECT OPTICAL CONTROL)
// =============================================================================
// Optical IR control directly operates the Gree AC and COMPLETELY BYPASSES mechanical relays.
// Relays are never triggered or degraded by AC commands.
const uint16_t IR_LED_PIN = 4; // GPIO 4 (IR Transmitter LED signal pin)
IRGreeAC ac(IR_LED_PIN);

// AC Live State tracking
struct AcState {
  bool   isOn;
  int    temperature; // 16 - 30 °C
  String mode;        // "COOL", "AUTO", "DRY", "FAN", "HEAT"
  int    fanSpeed;    // 0 = Auto, 1 = Low, 2 = Med, 3 = High
  bool   swing;       // true = Auto Vertical Swing, false = Fixed Upward
};

AcState acState = {
  false,   // isOn
  24,      // temperature (24°C default)
  "COOL",  // mode
  0,       // fanSpeed (0 = Auto)
  false    // swing (false = Fixed Upward)
};

// =============================================================================
// 1. HARDWARE IDENTIFICATION & ROOM CONFIGURATION
// =============================================================================
// Change ZONE_ID for each physical switchboard (Each switchboard powers 4 devices):
//   1 = Switchboard #1 (Zone 1 in App)
//   2 = Switchboard #2 (Zone 2 in App)
//   3 = Switchboard #3 (Zone 3 in App)
//   4 = Switchboard #4 (Zone 4 in App)
//   5 = Switchboard #5 (Zone 5 in App)
#define ZONE_ID           1
#define BOARD_ID          ZONE_ID

// Physical Classroom ID where this switchboard is installed.
// Must match the classroom in ClassPulse app.
// To guarantee zero cross-talk between buildings (e.g. ETE Room 304 vs EEE Room 304):
//   • For ETE Room 304: use "ete_room_304" (or "room_304" if single building)
//   • For EEE Room 304: use "eee_room_304"
//   • For CSE Room 304: use "cse_room_304"
#define CLASSROOM_ID      "rcb_room_304"

// =============================================================================
// 2. WI-FI NETWORK CONFIGURATION (2.4 GHz)
// =============================================================================
#define WIFI_SSID         "SWAPAN_CID"     // Set your Wi-Fi SSID
#define WIFI_PASSWORD     "ekthekeaat1"  // <-- REPLACE WITH YOUR WI-FI PASSWORD

// =============================================================================
// 3. MQTT BROKER CONFIGURATION
// =============================================================================
const char* MQTT_BROKER   = "broker.emqx.io";
const int   MQTT_PORT     = 1883;
const char* MQTT_USER     = "";            // Leave empty if no authentication
const char* MQTT_PASSWORD = "";            // Leave empty if no authentication

// =============================================================================
// 4. CONFIGURABLE 4-CHANNEL UNIVERSAL RELAYS (ANY CHANNEL: FAN, LIGHT, OR AC)
// =============================================================================
#define NUM_RELAYS 4

// Structure defining each relay channel on this board
struct RelayConfig {
  int pin;              // ESP32 GPIO pin number
  const char* name;     // Channel label
  bool defaultOn;       // Initial state at boot
};

// Universal GPIO assignment: Any channel (1-4) can be connected to ANY appliance!
// (Ceiling Fan, Light, AC, or any electrical load)
RelayConfig relayConfigs[NUM_RELAYS] = {
  {18, "Channel 1", false}, // Relay 1 -> GPIO 18 (Fan, Light, or AC)
  {19, "Channel 2", false}, // Relay 2 -> GPIO 19 (Fan, Light, or AC)
  {21, "Channel 3", false}, // Relay 3 -> GPIO 21 (Fan, Light, or AC)
  {22, "Channel 4", false}  // Relay 4 -> GPIO 22 (Fan, Light, or AC)
};

// Relay states and speed/brightness telemetry
bool relayStates[NUM_RELAYS] = {false, false, false, false};
int  fanSpeeds[NUM_RELAYS]   = {3, 3, 3, 3};         // For fan devices (1-5)
int  brightness[NUM_RELAYS]  = {100, 100, 100, 100}; // For light devices (0-100)

// Relay Trigger Logic: Most 4-channel relay modules are Active LOW (LOW = Relay ON)
const bool RELAY_ACTIVE_LOW = true;
bool emergencyLocked = false;

// =============================================================================
// 5. GLOBAL OBJECTS & TELEMETRY TIMERS
// =============================================================================
WiFiClient espClient;
PubSubClient mqtt(espClient);

unsigned long lastHeartbeat = 0;
const unsigned long HEARTBEAT_INTERVAL = 10000; // Heartbeat telemetry every 10 seconds

// Base topic: ruet/classroom/<CLASSROOM_ID>
inline String getBaseTopic() {
  return "ruet/classroom/" + String(CLASSROOM_ID);
}

// Zone topic: ruet/classroom/<CLASSROOM_ID>/zone/<ZONE_ID>
inline String getZoneTopic() {
  return getBaseTopic() + "/zone/" + String(ZONE_ID);
}

// Board topic alias: ruet/classroom/<CLASSROOM_ID>/board/<ZONE_ID>
inline String getBoardTopic() {
  return getBaseTopic() + "/board/" + String(ZONE_ID);
}

// Relay logic converter with safety emergency cutoff
inline int relayLevel(bool on) {
  if (emergencyLocked) on = false;
  return RELAY_ACTIVE_LOW ? (on ? LOW : HIGH) : (on ? HIGH : LOW);
}

// =============================================================================
// 6. HARDWARE INITIALIZATION (ZERO-GLITCH BOOT)
// =============================================================================
void configureRelayPins() {
  for (int i = 0; i < NUM_RELAYS; i++) {
    relayStates[i] = relayConfigs[i].defaultOn;
    // Drive safe level before pinMode output transition to prevent boot relay chatter
    digitalWrite(relayConfigs[i].pin, relayLevel(relayStates[i]));
    pinMode(relayConfigs[i].pin, OUTPUT);
  }
}

void setRelay(int index, bool turnOn, bool publishFeedback = true);

// =============================================================================
// 7. MQTT STATUS & FEEDBACK PUBLISHING
// =============================================================================
void publishRelayStatus(int index) {
  if (index < 0 || index >= NUM_RELAYS) return;
  int relayNum = index + 1;

  JSON_DOC(doc, 256);
  doc["room"]       = CLASSROOM_ID;
  doc["zone"]       = ZONE_ID;
  doc["board"]      = BOARD_ID;
  doc["relay"]      = relayNum;
  doc["state"]      = relayStates[index] ? "ON" : "OFF";
  doc["gpio"]       = relayConfigs[index].pin;
  doc["name"]       = relayConfigs[index].name;
  doc["speed"]      = relayStates[index] ? fanSpeeds[index] : 0;
  doc["brightness"] = relayStates[index] ? brightness[index] : 0;

  char buffer[256];
  serializeJson(doc, buffer, sizeof(buffer));

  // 1. Hierarchical Topic: ruet/classroom/<CLASSROOM_ID>/zone/<ZONE_ID>/relay/<N>/status
  String topicZoneRelay = getZoneTopic() + "/relay/" + String(relayNum) + "/status";
  mqtt.publish(topicZoneRelay.c_str(), buffer, false);

  // 2. Board Status Alias: ruet/classroom/<CLASSROOM_ID>/status/board/<ZONE_ID>/relay/<N>
  String topicBoardRelay = getBaseTopic() + "/status/board/" + String(ZONE_ID) + "/relay/" + String(relayNum);
  mqtt.publish(topicBoardRelay.c_str(), buffer, false);

  Serial.printf("📡 [MQTT] Zone %d Relay %d (%s) -> %s (GPIO %d)\n",
                ZONE_ID, relayNum, relayConfigs[index].name,
                relayStates[index] ? "ON" : "OFF", relayConfigs[index].pin);
}

void publishAllRelayStatus() {
  for (int i = 0; i < NUM_RELAYS; i++) {
    publishRelayStatus(i);
  }
  publishAcStatus();
}

void publishAcStatus() {
  JSON_DOC(doc, 256);
  doc["room"]     = CLASSROOM_ID;
  doc["zone"]     = ZONE_ID;
  doc["board"]    = BOARD_ID;
  doc["type"]     = "ac";
  doc["state"]    = acState.isOn ? "ON" : "OFF";
  doc["temp"]     = acState.temperature;
  doc["mode"]     = acState.mode;
  doc["fan"]      = acState.fanSpeed;
  doc["swing"]    = acState.swing;
  doc["gpio"]     = IR_LED_PIN;
  doc["protocol"] = "GREE";

  char buffer[256];
  serializeJson(doc, buffer, sizeof(buffer));

  // 1. Zone AC Status: ruet/classroom/<CLASSROOM_ID>/zone/<ZONE_ID>/ac/status
  String topicZoneAc = getZoneTopic() + "/ac/status";
  mqtt.publish(topicZoneAc.c_str(), buffer, false);

  // 2. Global AC Status: ruet/classroom/<CLASSROOM_ID>/status/ac
  String topicRoomAc = getBaseTopic() + "/status/ac";
  mqtt.publish(topicRoomAc.c_str(), buffer, false);

  // 3. Board AC Status: ruet/classroom/<CLASSROOM_ID>/status/board/<ZONE_ID>/ac
  String topicBoardAc = getBaseTopic() + "/status/board/" + String(ZONE_ID) + "/ac";
  mqtt.publish(topicBoardAc.c_str(), buffer, false);

  Serial.printf("📡 [MQTT] AC Status -> %s (%d°C, %s, Fan %d, Swing %s)\n",
                acState.isOn ? "ON" : "OFF", acState.temperature, acState.mode.c_str(),
                acState.fanSpeed, acState.swing ? "ON" : "OFF");
}

void executeAcControl(bool turnOn, int temp, String mode, int fan, bool swing, bool publishStatus = true) {
  acState.isOn = turnOn;
  acState.temperature = constrain(temp, 16, 30);
  acState.mode = mode;
  acState.fanSpeed = constrain(fan, 0, 3);
  acState.swing = swing;

  if (turnOn) {
    ac.on();
    ac.setTemp(acState.temperature);
    if (mode.equalsIgnoreCase("COOL")) ac.setMode(kGreeCool);
    else if (mode.equalsIgnoreCase("DRY")) ac.setMode(kGreeDry);
    else if (mode.equalsIgnoreCase("FAN")) ac.setMode(kGreeFan);
    else if (mode.equalsIgnoreCase("HEAT")) ac.setMode(kGreeHeat);
    else ac.setMode(kGreeAuto);

    ac.setFan(acState.fanSpeed); // 0 = Auto, 1 = Low, 2 = Med, 3 = High
    if (acState.swing) {
      ac.setSwingVertical(true, kGreeSwingAuto);
    } else {
      ac.setSwingVertical(false, kGreeSwingUp);
    }
    ac.setLight(true);
    ac.send();
    Serial.printf("❄️ [IR AC] Sent IR Command: ON, %d°C, %s, Fan %d, Swing %s via GPIO %d (RELAYS BYPASSED)\n",
                  acState.temperature, acState.mode.c_str(), acState.fanSpeed,
                  acState.swing ? "AUTO" : "FIXED", IR_LED_PIN);
  } else {
    ac.off();
    ac.send();
    Serial.printf("❄️ [IR AC] Sent IR Command: OFF via GPIO %d (RELAYS BYPASSED)\n", IR_LED_PIN);
  }

  if (publishStatus && mqtt.connected()) {
    publishAcStatus();
  }
}

void handleAcCommand(String msg) {
  bool turnOn = acState.isOn;
  int targetTemp = acState.temperature;
  String targetMode = acState.mode;
  int targetFan = acState.fanSpeed;
  bool targetSwing = acState.swing;

  if (msg.startsWith("{")) {
    JSON_DOC(doc, 256);
    DeserializationError err = deserializeJson(doc, msg);
    if (!err) {
      if (!doc["state"].isNull()) {
        String st = doc["state"].as<String>();
        st.toUpperCase();
        turnOn = (st == "ON" || st == "1" || st == "TRUE");
      }
      if (!doc["temp"].isNull()) {
        targetTemp = constrain(doc["temp"].as<int>(), 16, 30);
      }
      if (!doc["mode"].isNull()) {
        targetMode = doc["mode"].as<String>();
      }
      if (!doc["fan"].isNull()) {
        targetFan = constrain(doc["fan"].as<int>(), 0, 3);
      }
      if (!doc["speed"].isNull() && doc["fan"].isNull()) {
        int spd = doc["speed"].as<int>();
        targetFan = (spd == 0) ? 0 : constrain(spd - 1, 1, 3);
      }
      if (!doc["swing"].isNull()) {
        targetSwing = doc["swing"].as<bool>();
      }
    }
  } else {
    if (msg.equalsIgnoreCase("ON") || msg == "1" || msg.equalsIgnoreCase("TRUE")) {
      turnOn = true;
    } else if (msg.equalsIgnoreCase("OFF") || msg == "0" || msg.equalsIgnoreCase("FALSE")) {
      turnOn = false;
    } else if (msg.equalsIgnoreCase("TOGGLE")) {
      turnOn = !acState.isOn;
    }
  }

  executeAcControl(turnOn, targetTemp, targetMode, targetFan, targetSwing);
}

void publishHeartbeat() {
  JSON_DOC(doc, 384);
  doc["status"]    = "ONLINE";
  doc["room"]      = CLASSROOM_ID;
  doc["zone"]      = ZONE_ID;
  doc["board"]     = BOARD_ID;
  doc["ip"]        = WiFi.localIP().toString();
  doc["mac"]       = WiFi.macAddress();
  doc["rssi"]      = WiFi.RSSI();
  doc["uptimeSec"] = millis() / 1000;
  doc["freeHeap"]  = ESP.getFreeHeap();
  doc["emergency"] = emergencyLocked;
  doc["acState"]   = acState.isOn ? "ON" : "OFF";
  doc["acTemp"]    = acState.temperature;
  doc["acMode"]    = acState.mode;

  JsonArray rArr = doc.createNestedArray("relays");
  for (int i = 0; i < NUM_RELAYS; i++) {
    rArr.add(relayStates[i] ? 1 : 0);
  }

  char buffer[384];
  serializeJson(doc, buffer, sizeof(buffer));

  // Publish to both board and zone status topics
  String topicBoardStatus = getBaseTopic() + "/status/board/" + String(ZONE_ID);
  String topicZoneStatus  = getZoneTopic() + "/status";
  mqtt.publish(topicBoardStatus.c_str(), buffer, false);
  mqtt.publish(topicZoneStatus.c_str(), buffer, false);

  Serial.printf("💓 [HEARTBEAT] Zone %d in %s ONLINE (IP: %s, RSSI: %d dBm) | AC: %s %d°C\n",
                ZONE_ID, CLASSROOM_ID, WiFi.localIP().toString().c_str(), WiFi.RSSI(),
                acState.isOn ? "ON" : "OFF", acState.temperature);
}

void setRelay(int index, bool turnOn, bool publishFeedback) {
  if (index < 0 || index >= NUM_RELAYS) return;
  bool stateChanged = (relayStates[index] != turnOn);
  relayStates[index] = turnOn;
  digitalWrite(relayConfigs[index].pin, relayLevel(relayStates[index]));
  
  if (stateChanged) {
    Serial.printf("⚡ [RELAY] Output %d (%s) changed -> %s\n",
                  index + 1, relayConfigs[index].name,
                  turnOn ? "ENERGIZED (ON)" : "DE-ENERGIZED (OFF)");
  }

  // Only broadcast status when state actually changes to eliminate infinite echo loops
  if (stateChanged && publishFeedback && mqtt.connected()) {
    publishRelayStatus(index);
  }
}

// =============================================================================
// 8. MQTT INCOMING COMMAND HANDLER (STRICT HIERARCHICAL ISOLATION)
// =============================================================================
void onMqttMessage(char* topic, byte* payload, unsigned int length) {
  String strTopic = String(topic);
  String msg = "";
  for (unsigned int i = 0; i < length; i++) {
    msg += (char)payload[i];
  }
  msg.trim();

  // ---------------------------------------------------------------------------
  // CRITICAL SAFEGUARD: Drop all outbound status & feedback echoes immediately!
  // Prevents infinite broker feedback loops that cause relays to toggle autonomously!
  // ---------------------------------------------------------------------------
  if (strTopic.endsWith("/status") || strTopic.indexOf("/status") != -1) {
    return;
  }

  Serial.printf("\n📩 [MQTT RX] %s => %s\n", topic, msg.c_str());

  // ---------------------------------------------------------------------------
  // Check 0: Dedicated Optical IR AC Control (NO RELAYS TOUCHED!)
  // Topics:
  //   ruet/classroom/<CLASSROOM_ID>/zone/<ZONE_ID>/ac/command
  //   ruet/classroom/<CLASSROOM_ID>/zone/<ZONE_ID>/ac/set
  //   ruet/classroom/<CLASSROOM_ID>/board/<ZONE_ID>/ac/command
  //   ruet/classroom/<CLASSROOM_ID>/ac/command
  // ---------------------------------------------------------------------------
  if (strTopic == getZoneTopic() + "/ac/command" ||
      strTopic == getZoneTopic() + "/ac/set" ||
      strTopic == getBoardTopic() + "/ac/command" ||
      strTopic == getBaseTopic() + "/ac/command" ||
      strTopic.endsWith("/ac/command") ||
      strTopic.endsWith("/ac")) {
    Serial.printf("❄️ [AC DISPATCH] Optical IR AC Command received on %s! Relays BYPASSED.\n", topic);
    handleAcCommand(msg);
    return;
  }

  // ---------------------------------------------------------------------------
  // Check 1: Zone Master Command (Targets ONLY this specific Switchboard/Zone!)
  // Topics:
  //   ruet/classroom/<CLASSROOM_ID>/zone/<ZONE_ID>/command/all
  //   ruet/classroom/<CLASSROOM_ID>/board/<ZONE_ID>/command/all
  // ---------------------------------------------------------------------------
  if (strTopic == getZoneTopic() + "/command/all" || strTopic == getBoardTopic() + "/command/all") {
    bool turnOn = (msg.equalsIgnoreCase("ALL_ON") || msg.equalsIgnoreCase("ON") || msg == "1");
    Serial.printf("⚡ [ZONE MASTER] Zone %d Switchboard: %s\n", ZONE_ID, turnOn ? "ALL ON" : "ALL OFF");
    for (int i = 0; i < NUM_RELAYS; i++) {
      setRelay(i, turnOn, true);
    }
    // Also power down AC if Zone Master OFF
    if (!turnOn) {
      executeAcControl(false, acState.temperature, acState.mode, acState.fanSpeed, acState.swing, true);
    }
    publishHeartbeat();
    return;
  }

  // ---------------------------------------------------------------------------
  // Check 2: Relay-Specific Command for THIS Switchboard/Zone
  // Topics:
  //   ruet/classroom/<CLASSROOM_ID>/zone/<ZONE_ID>/relay/<1-4>
  //   ruet/classroom/<CLASSROOM_ID>/zone/<ZONE_ID>/relay/<1-4>/set
  //   ruet/classroom/<CLASSROOM_ID>/board/<ZONE_ID>/relay/<1-4>
  // ---------------------------------------------------------------------------
  int targetRelay = -1;
  String zoneRelayPrefix  = getZoneTopic() + "/relay/";
  String boardRelayPrefix = getBoardTopic() + "/relay/";

  if (strTopic.startsWith(zoneRelayPrefix)) {
    String sub = strTopic.substring(zoneRelayPrefix.length());
    if (sub.endsWith("/status") || sub.indexOf("/status") != -1) return;
    int slash = sub.indexOf('/');
    targetRelay = (slash != -1 ? sub.substring(0, slash) : sub).toInt();
  } else if (strTopic.startsWith(boardRelayPrefix)) {
    String sub = strTopic.substring(boardRelayPrefix.length());
    if (sub.endsWith("/status") || sub.indexOf("/status") != -1) return;
    int slash = sub.indexOf('/');
    targetRelay = (slash != -1 ? sub.substring(0, slash) : sub).toInt();
  }

  if (targetRelay >= 1 && targetRelay <= NUM_RELAYS) {
    int idx = targetRelay - 1;
    bool newState = relayStates[idx];

    if (msg.startsWith("{")) {
      JSON_DOC(doc, 256);
      DeserializationError err = deserializeJson(doc, msg);
      if (!err) {
        // SAFEGUARD: If this channel is designated as AC, DISPATCH TO IR AND NEVER TOGGLE MECHANICAL RELAYS!
        if ((!doc["type"].isNull() && doc["type"].as<String>().equalsIgnoreCase("ac")) ||
            (!doc["protocol"].isNull() && doc["protocol"].as<String>().equalsIgnoreCase("gree")) ||
            (!doc["id"].isNull() && doc["id"].as<String>().indexOf("ac") != -1)) {
          Serial.printf("❄️ [AC DISPATCH] Relay %d payload identified as AC! Bypassing relay output, firing IR transmitter on GPIO %d...\n",
                        targetRelay, IR_LED_PIN);
          handleAcCommand(msg);
          return;
        }

        if (!doc["state"].isNull()) {
          String st = doc["state"].as<String>();
          st.toUpperCase();
          newState = (st == "ON" || st == "1" || st == "TRUE");
        }
        if (!doc["speed"].isNull()) {
          int spd = doc["speed"].as<int>();
          fanSpeeds[idx] = constrain(spd, 0, 5);
          if (spd > 0) newState = true;
          else if (spd == 0 && doc["state"].isNull()) newState = false;
        }
        if (!doc["brightness"].isNull()) {
          int bri = doc["brightness"].as<int>();
          brightness[idx] = constrain(bri, 0, 100);
          if (bri > 0) newState = true;
          else if (bri == 0 && doc["state"].isNull()) newState = false;
        }
      }
    } else {
      if (msg.equalsIgnoreCase("ON") || msg == "1" || msg.equalsIgnoreCase("TRUE")) {
        newState = true;
      } else if (msg.equalsIgnoreCase("OFF") || msg == "0" || msg.equalsIgnoreCase("FALSE")) {
        newState = false;
      } else if (msg.equalsIgnoreCase("TOGGLE")) {
        newState = !relayStates[idx];
      }
    }

    setRelay(idx, newState, true);
    return;
  }

  // ---------------------------------------------------------------------------
  // Check 3: Classroom Master Power (All Switchboards in THIS Classroom)
  // Topic: ruet/classroom/<CLASSROOM_ID>/command/all
  // ---------------------------------------------------------------------------
  if (strTopic == getBaseTopic() + "/command/all") {
    bool turnOn = (msg.equalsIgnoreCase("ALL_ON") || msg.equalsIgnoreCase("ON") || msg == "1");
    Serial.printf("🌐 [ROOM MASTER] %s Power: %s\n", CLASSROOM_ID, turnOn ? "ALL ON" : "ALL OFF");
    for (int i = 0; i < NUM_RELAYS; i++) {
      setRelay(i, turnOn, true);
    }
    // Also power down AC via optical IR if room is powered down
    if (!turnOn) {
      executeAcControl(false, acState.temperature, acState.mode, acState.fanSpeed, acState.swing, true);
    }
    publishHeartbeat();
    return;
  }

  // ---------------------------------------------------------------------------
  // Check 4: Query / Hardware Scan Telemetry Request (Telemetry only! Never toggle relays!)
  // Topics:
  //   ruet/classroom/<CLASSROOM_ID>/command/query
  //   ruet/classroom/all/command/query
  // ---------------------------------------------------------------------------
  if (strTopic == getBaseTopic() + "/command/query" || 
      strTopic == "ruet/classroom/all/command/query" ||
      strTopic.endsWith("/query")) {
    Serial.printf("🔍 [QUERY] Scan ping received for %s! Broadcasting heartbeat, relay states, and AC status...\n", CLASSROOM_ID);
    publishHeartbeat();
    publishAllRelayStatus();
    return;
  }

  // ---------------------------------------------------------------------------
  // Check 5: Classroom Emergency Cutoff
  // Topic: ruet/classroom/<CLASSROOM_ID>/command/emergency
  // ---------------------------------------------------------------------------
  if (strTopic == getBaseTopic() + "/command/emergency") {
    if (msg.equalsIgnoreCase("CUTOFF") || msg.equalsIgnoreCase("LOCK") || msg == "1") {
      emergencyLocked = true;
      // Shut down AC via IR immediately on emergency
      executeAcControl(false, acState.temperature, acState.mode, acState.fanSpeed, acState.swing, false);
      Serial.println("🚨 [EMERGENCY] Master safety cutoff tripped! Opening all 4 relays and turning OFF AC via IR.");
    } else {
      emergencyLocked = false;
      Serial.println("✅ [EMERGENCY] Master cutoff cleared. Normal operation restored.");
    }
    configureRelayPins();
    publishAllRelayStatus();
    publishHeartbeat();
    return;
  }
}

// =============================================================================
// 9. RECONNECT LOGIC (WI-FI & MQTT)
// =============================================================================
void connectWifi() {
  if (WiFi.status() == WL_CONNECTED) return;
  Serial.printf("\n📶 [WiFi] Connecting to SSID '%s' ", WIFI_SSID);
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  int retry = 0;
  while (WiFi.status() != WL_CONNECTED && retry < 25) {
    delay(500);
    Serial.print(".");
    retry++;
  }
  if (WiFi.status() == WL_CONNECTED) {
    Serial.printf("\n✅ [WiFi] Connected! IP: %s | RSSI: %d dBm\n",
                  WiFi.localIP().toString().c_str(), WiFi.RSSI());
  } else {
    Serial.println("\n⚠️ [WiFi] Connection pending. Retrying in loop...");
  }
}

void connectMqtt() {
  if (mqtt.connected()) return;
  if (WiFi.status() != WL_CONNECTED) return;

  Serial.printf("🔄 [MQTT] Connecting to %s:%d ... ", MQTT_BROKER, MQTT_PORT);
  String clientId = "ESP32_Zone_" + String(ZONE_ID) + "_" + String((uint32_t)ESP.getEfuseMac(), HEX);
  String lwtTopic = getBaseTopic() + "/status/board/" + String(ZONE_ID);
  String lwtMsg   = "{\"status\":\"OFFLINE\",\"zone\":" + String(ZONE_ID) + ",\"board\":" + String(BOARD_ID) + "}";

  // Connect with Last Will & Testament (LWT)
  bool success = false;
  if (strlen(MQTT_USER) > 0) {
    success = mqtt.connect(clientId.c_str(), MQTT_USER, MQTT_PASSWORD, lwtTopic.c_str(), 1, true, lwtMsg.c_str());
  } else {
    success = mqtt.connect(clientId.c_str(), lwtTopic.c_str(), 1, true, lwtMsg.c_str());
  }

  if (success) {
    Serial.println("CONNECTED! 🎉");

    // 1. Strict Zone Topic (Zone Isolation): ONLY receives commands for THIS switchboard!
    String zoneSub  = getZoneTopic() + "/#";
    String boardSub = getBoardTopic() + "/#";
    mqtt.subscribe(zoneSub.c_str(), 1);
    mqtt.subscribe(boardSub.c_str(), 1);

    // 2. Strict Classroom Topic (Room Isolation): Room Master, Emergency, Query for THIS room only!
    String roomSub = getBaseTopic() + "/command/#";
    mqtt.subscribe(roomSub.c_str(), 1);

    // 3. Dedicated AC Command Topics (Optical IR Control)
    String zoneAcSub  = getZoneTopic() + "/ac/#";
    String boardAcSub = getBoardTopic() + "/ac/#";
    String roomAcSub  = getBaseTopic() + "/ac/#";
    mqtt.subscribe(zoneAcSub.c_str(), 1);
    mqtt.subscribe(boardAcSub.c_str(), 1);
    mqtt.subscribe(roomAcSub.c_str(), 1);

    // 4. Global Scan Query (For App's Hardware Discovery Ping)
    mqtt.subscribe("ruet/classroom/all/command/query", 1);

    Serial.println("📥 [MQTT Subscriptions Active]:");
    Serial.printf("  • %s (Zone-Isolated Channel)\n", zoneSub.c_str());
    Serial.printf("  • %s (Board-Isolated Alias)\n", boardSub.c_str());
    Serial.printf("  • %s (Classroom Master Channel)\n", roomSub.c_str());
    Serial.printf("  • %s (Zone AC Optical Channel)\n", zoneAcSub.c_str());
    Serial.printf("  • %s (Room AC Optical Channel)\n", roomAcSub.c_str());
    Serial.printf("  • ruet/classroom/all/command/query (Discovery Ping)\n");

    // Broadcast online telemetry and relay feedback immediately
    publishHeartbeat();
    publishAllRelayStatus();
    publishAcStatus();
  } else {
    Serial.printf("FAILED (rc=%d). Will retry in loop.\n", mqtt.state());
  }
}

// =============================================================================
// 10. SETUP & MAIN LOOP
// =============================================================================
void setup() {
  Serial.begin(115200);
  delay(1000);

  Serial.println("\n\n==========================================================");
  Serial.printf("  RUET Smart Classroom - Switchboard #%d (Zone %d)\n", ZONE_ID, ZONE_ID);
  Serial.printf("  Assigned Classroom: %s\n", CLASSROOM_ID);
  Serial.println("  4-Channel Relays + Optical IR AC (Zero Relay Chatter)");
  Serial.println("==========================================================");

  // Initialize 4 relay outputs (Zero-glitch, all safe at boot)
  configureRelayPins();

  // Initialize IR Optical Transmitter for Gree AC (GPIO 4)
  ac.begin();
  ac.setMode(kGreeCool);
  ac.setTemp(acState.temperature);
  ac.setFan(acState.fanSpeed);
  ac.setSwingVertical(false, kGreeSwingUp);
  ac.setTurbo(false);
  ac.setSleep(false);
  ac.setLight(true);
  Serial.printf("❄️ [IR AC] Gree AC Optical Controller initialized on GPIO %d (Relays Bypassed)\n", IR_LED_PIN);

  // Network & MQTT initialization
  connectWifi();
  mqtt.setServer(MQTT_BROKER, MQTT_PORT);
  mqtt.setCallback(onMqttMessage);
  mqtt.setBufferSize(512); // Support JSON payloads up to 512 bytes
  mqtt.setKeepAlive(30);
  mqtt.setSocketTimeout(5);
}

unsigned long lastMqttRetry = 0;

void loop() {
  // 1. Maintain Wi-Fi link
  if (WiFi.status() != WL_CONNECTED) {
    connectWifi();
  }

  // 2. Maintain MQTT session with 3-second backoff (prevents rapid broker reconnect rate-limiting)
  if (WiFi.status() == WL_CONNECTED && !mqtt.connected()) {
    unsigned long now = millis();
    if (now - lastMqttRetry >= 3000) {
      lastMqttRetry = now;
      connectMqtt();
    }
  }

  // 3. Process MQTT incoming packet queues
  mqtt.loop();

  // 4. Periodic heartbeat transmission
  unsigned long now = millis();
  if (now - lastHeartbeat >= HEARTBEAT_INTERVAL) {
    lastHeartbeat = now;
    if (mqtt.connected()) {
      publishHeartbeat();
    }
  }
}
