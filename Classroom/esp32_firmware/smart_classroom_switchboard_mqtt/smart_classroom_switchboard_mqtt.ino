/*
  =============================================================================
  RUET Smart Classroom / Smart Home IoT - 8-Channel Switchboard Controller
  =============================================================================
  Project: ClassPulse IoT (Multi-Zone Switchboard & Manual Switch Sync Edition)
  Target:  ESP32 30-Pin Dev Module / ESP32-WROOM-32

  1. Hardware & Exact GPIO Mapping (Relays <-> Manual Switches):
  -----------------------------------------------------------------------------
  • ZONE 1 (ESP32 30-Pin - "1st Board", ZONE_ID = 1, 6 Active Pairs):
      Left starts In1 (Pairs 1-4), Right starts In5 (Pairs 5-6):
      Pair 1: Relay In1 [L] on D16 (GPIO 16) <-> Switch S1 on D14 (GPIO 14)
      Pair 2: Relay In2 [L] on D4  (GPIO 4)  <-> Switch S2 on D27 (GPIO 27)
      Pair 3: Relay In3 [L] on D2  (GPIO 2)  <-> Switch S3 on D26 (GPIO 26)
      Pair 4: Relay In4 [L] on D15 (GPIO 15) <-> Switch S4 on D25 (GPIO 25)
      Pair 5: Relay In5 [R] on D21 (GPIO 21) <-> Switch S5 on D33 (GPIO 33)
      Pair 6: Relay In6 [R] on D19 (GPIO 19) <-> Switch S6 on D34 (GPIO 34, input-only)

  • ZONE 2 (Unlabeled Board, ZONE_ID = 2, 6 Active Relays — App/MQTT only, no switches):
      Pair 1: Relay In1 on G4  (GPIO 4)  (No physical switch)
      Pair 2: Relay In2 on G0  (GPIO 0)  (No physical switch)
      Pair 3: Relay In3 on G2  (GPIO 2)  (No physical switch)
      Pair 4: Relay In4 on G15 (GPIO 15) (No physical switch)
      Pair 5: Relay In5 on G17 (GPIO 17) (No physical switch; swapped from G11 flash pin)
      Pair 6: Relay In6 on G5  (GPIO 5)  (No physical switch)

  • ZONE 3 ("3rd One", ZONE_ID = 3, 5 Active Pairs):
      Pair 1: Relay In1 on D5  (GPIO 5)  <-> Switch SW1 on D32 (GPIO 32)
      Pair 2: Relay In2 on D4  (GPIO 4)  <-> Switch SW2 on D33 (GPIO 33)
      Pair 3: Relay In3 on D2  (GPIO 2)  <-> Switch SW3 on D25 (GPIO 25)
      Pair 4: Relay In4 on D15 (GPIO 15) <-> Switch SW4 on D26 (GPIO 26)
      Pair 5: Relay In5 on D18 (GPIO 18) <-> Switch SW5 on D27 (GPIO 27)

  • Standalone Dual-Gree AC Controller runs on a separate ESP32 board
    (AC #1 IR on GPIO 33, AC #2 IR on GPIO 12) — see esp32_ac_ir_controller.ino.

  2. Firmware Behavior:
  -----------------------------------------------------------------------------
  • Sets all 8 switch pins to INPUT_PULLUP and all 8 relay pins to OUTPUT.
  • Hardware-interrupt / state-change listener on each switch pin: when a
    physical switch toggles (HIGH <-> LOW), immediately inverts its paired
    relay and publishes the updated state to MQTT so the mobile app stays in sync.
  • Publishes MQTT discovery payload to `home/discovery` on boot and scan queries:
    {"zone_id": "zone_1", "device_type": "switchboard", "ip": "192.168.X.X"}
  =============================================================================
*/

#include <WiFi.h>
#include <PubSubClient.h>
#include <ArduinoJson.h>

#if ARDUINOJSON_VERSION_MAJOR >= 7
  #define JSON_DOC(name, size) JsonDocument name
#else
  #define JSON_DOC(name, size) StaticJsonDocument<size> name
#endif

// =============================================================================
// 1. HARDWARE IDENTIFICATION & ZONE SELECTION
// =============================================================================
// Set ZONE_ID before flashing each physical ESP32 switchboard:
//   1 = Zone 1 (ESP32 30-Pin - "1st Board")
//   2 = Zone 2 (Unlabeled Board)
//   3 = Zone 3 ("3rd One")
#ifndef ZONE_ID
#define ZONE_ID           1
#endif
#define BOARD_ID          ZONE_ID
#define CLASSROOM_ID      "reb_room_301"

#include "secrets.h"  // Copy secrets.example.h to secrets.h and fill locally; never commit it.

#if ZONE_ID == 1
  #define ZONE_ID_STR     "zone_1"
  #define CONTROLLER_ID   "board01"
#elif ZONE_ID == 2
  #define ZONE_ID_STR     "zone_2"
  #define CONTROLLER_ID   "board02"
#else
  #define ZONE_ID_STR     "zone_3"
  #define CONTROLLER_ID   "board03"
#endif

#define DEVICE_TYPE_STR   "switchboard"
#define DISCOVERY_TOPIC   "home/discovery"
#define PROTOCOL_NAME     "classroom-control-v1"

char controllerBootId[33] = "";
String activeSessionId   = "";
String activeChallenge   = "";
int64_t lastCmdSequence  = 0;
uint32_t phase5StatusSeq = 1;
uint32_t phase5AckSeq    = 1;

// =============================================================================
// 2. WI-FI & MQTT BROKER CONFIGURATION
// =============================================================================
const char* MQTT_BROKER   = CLASSROOM_MQTT_HOST;
const int   MQTT_PORT     = CLASSROOM_MQTT_PORT;
#define WIFI_SSID         CLASSROOM_WIFI_SSID
#define WIFI_PASSWORD     CLASSROOM_WIFI_PASSWORD
const char* MQTT_USER     = CLASSROOM_MQTT_USERNAME;
const char* MQTT_PASSWORD = CLASSROOM_MQTT_PASSWORD;

// =============================================================================
// 3. RELAY & MANUAL SWITCH GPIO MAPPING
// =============================================================================
struct SwitchRelayPair {
  int relayPin;           // ESP32 GPIO pin for Relay (OUTPUT)
  int switchPin;          // ESP32 GPIO pin for Manual Switch (INPUT_PULLUP / INPUT for >=34)
  const char* relayLabel; // Hardware Relay label (e.g. "In1 [L]")
  const char* switchName; // Hardware Switch label (e.g. "S1" or "SW1")
  bool defaultOn;         // Boot relay state
};

#if ZONE_ID == 1
#define NUM_RELAYS 6
// Zone 1 (ESP32 30-Pin - "1st Board"): Left starts In1 (Pairs 1-4), Right starts In5 (Pairs 5-6)
SwitchRelayPair pairConfigs[NUM_RELAYS] = {
  {16, 14, "In1 [L]", "S1", false}, // Pair 1: Relay In1 [L] (D16) <-> Switch S1 (D14)
  { 4, 27, "In2 [L]", "S2", false}, // Pair 2: Relay In2 [L] (D4)  <-> Switch S2 (D27)
  { 2, 26, "In3 [L]", "S3", false}, // Pair 3: Relay In3 [L] (D2)  <-> Switch S3 (D26)
  {15, 25, "In4 [L]", "S4", false}, // Pair 4: Relay In4 [L] (D15) <-> Switch S4 (D25)
  {21, 33, "In5 [R]", "S5", false}, // Pair 5: Relay In5 [R] (D21) <-> Switch S5 (D33)
  {19, 34, "In6 [R]", "S6", false}  // Pair 6: Relay In6 [R] (D19) <-> Switch S6 (D34, input-only)
};
#elif ZONE_ID == 2
#define NUM_RELAYS 6
// Zone 2 (Unlabeled Board) Exact 6-Relay Pins (App/MQTT only, no physical switches):
SwitchRelayPair pairConfigs[NUM_RELAYS] = {
  { 4, -1, "In1", "NONE", false}, // Pair 1: Relay In1 (G4)  (No physical switch)
  { 0, -1, "In2", "NONE", false}, // Pair 2: Relay In2 (G0)  (No physical switch)
  { 2, -1, "In3", "NONE", false}, // Pair 3: Relay In3 (G2)  (No physical switch)
  {15, -1, "In4", "NONE", false}, // Pair 4: Relay In4 (G15) (No physical switch)
  {17, -1, "In5", "NONE", false}, // Pair 5: Relay In5 (G17) (No physical switch)
  { 5, -1, "In6", "NONE", false}  // Pair 6: Relay In6 (G5)  (No physical switch)
};
#else
#define NUM_RELAYS 5
// Zone 3 ("3rd One") Exact 5-Pair Pins:
SwitchRelayPair pairConfigs[NUM_RELAYS] = {
  { 5, 32, "In1", "SW1", false}, // Pair 1: Relay In1 (D5)  <-> Switch SW1 (D32)
  { 4, 33, "In2", "SW2", false}, // Pair 2: Relay In2 (D4)  <-> Switch SW2 (D33)
  { 2, 25, "In3", "SW3", false}, // Pair 3: Relay In3 (D2)  <-> Switch SW3 (D25)
  {15, 26, "In4", "SW4", false}, // Pair 4: Relay In4 (D15) <-> Switch SW4 (D26)
  {18, 27, "In5", "SW5", false}  // Pair 5: Relay In5 (D18) <-> Switch SW5 (D27)
};
#endif

// Runtime states for all configured pairs
bool relayStates[NUM_RELAYS]        = {};
int  fanSpeeds[NUM_RELAYS];
int  brightness[NUM_RELAYS];

// Switch state-change tracking & hardware interrupt flags
int  lastStableSwitchState[NUM_RELAYS];
int  lastRawSwitchReading[NUM_RELAYS];
unsigned long lastSwitchDebounceMs[NUM_RELAYS];
volatile bool switchIrqTriggered[NUM_RELAYS] = {};
const unsigned long SWITCH_DEBOUNCE_MS = 45;

// Relay Trigger Logic: Active LOW (LOW = Relay ON, HIGH = Relay OFF)
const bool RELAY_ACTIVE_LOW = true;
bool emergencyLocked = false;

// =============================================================================
// 4. GLOBAL OBJECTS & TOPIC HELPERS
// =============================================================================
WiFiClient espClient;
PubSubClient mqtt(espClient);

unsigned long lastHeartbeat = 0;
const unsigned long HEARTBEAT_INTERVAL = 10000;
unsigned long lastMqttRetry = 0;

inline String getBaseTopic() {
  return "ruet/classroom/" + String(CLASSROOM_ID);
}

inline String getZoneTopic() {
  return getBaseTopic() + "/zone/" + String(ZONE_ID);
}

inline String getBoardTopic() {
  return getBaseTopic() + "/board/" + String(ZONE_ID);
}

inline String getControllerPrefix() {
  return "ruet/classroom/" + String(CLASSROOM_ID) + "/controllers/" + String(CONTROLLER_ID);
}

inline String getAltControllerPrefix() {
  return "classpulse/" + String(CLASSROOM_ID) + "/controllers/" + String(CONTROLLER_ID);
}

inline int relayLevel(bool on) {
  if (emergencyLocked) on = false;
  return RELAY_ACTIVE_LOW ? (on ? LOW : HIGH) : (on ? HIGH : LOW);
}

// =============================================================================
// 5. HARDWARE ISR & PIN INITIALIZATION
// =============================================================================
void IRAM_ATTR onSwitch0Change() { switchIrqTriggered[0] = true; }
void IRAM_ATTR onSwitch1Change() { switchIrqTriggered[1] = true; }
void IRAM_ATTR onSwitch2Change() { switchIrqTriggered[2] = true; }
void IRAM_ATTR onSwitch3Change() { switchIrqTriggered[3] = true; }
void IRAM_ATTR onSwitch4Change() { switchIrqTriggered[4] = true; }
void IRAM_ATTR onSwitch5Change() { switchIrqTriggered[5] = true; }
void IRAM_ATTR onSwitch6Change() { switchIrqTriggered[6] = true; }
void IRAM_ATTR onSwitch7Change() { switchIrqTriggered[7] = true; }

void (*switchIsrTable[8])() = {
  onSwitch0Change, onSwitch1Change, onSwitch2Change, onSwitch3Change,
  onSwitch4Change, onSwitch5Change, onSwitch6Change, onSwitch7Change
};

void configureHardwarePins() {
  unsigned long now = millis();
  for (int i = 0; i < NUM_RELAYS; i++) {
    // 1. Configure Relay Pin as OUTPUT (drive safe initial level first to prevent boot chatter)
    relayStates[i] = pairConfigs[i].defaultOn;
    fanSpeeds[i]   = 3;
    brightness[i]  = 100;
    digitalWrite(pairConfigs[i].relayPin, relayLevel(relayStates[i]));
    pinMode(pairConfigs[i].relayPin, OUTPUT);

    // 2. Configure Manual Switch Pin (skip if -1; GPIO 34-39 are input-only without pull-up)
    if (pairConfigs[i].switchPin >= 0) {
      int switchMode = (pairConfigs[i].switchPin >= 34) ? INPUT : INPUT_PULLUP;
      pinMode(pairConfigs[i].switchPin, switchMode);
      int initialReading = digitalRead(pairConfigs[i].switchPin);
      lastStableSwitchState[i] = initialReading;
      lastRawSwitchReading[i]  = initialReading;
      lastSwitchDebounceMs[i]  = now;
      attachInterrupt(digitalPinToInterrupt(pairConfigs[i].switchPin), switchIsrTable[i], CHANGE);
    } else {
      lastStableSwitchState[i] = HIGH;
      lastRawSwitchReading[i]  = HIGH;
      lastSwitchDebounceMs[i]  = now;
    }
  }
}

void setRelay(int index, bool turnOn, bool publishFeedback = true);

// =============================================================================
// 6. MQTT DISCOVERY & TELEMETRY PUBLISHING
// =============================================================================
void publishDiscovery() {
  if (!mqtt.connected()) return;

  JSON_DOC(doc, 384);
  doc["zone_id"]     = ZONE_ID_STR;         // "zone_1", "zone_2", or "zone_3"
  doc["device_type"] = DEVICE_TYPE_STR;     // "switchboard"
  doc["ip"]          = WiFi.localIP().toString();
  doc["room"]        = CLASSROOM_ID;
  doc["zone"]        = ZONE_ID;
  doc["board"]       = BOARD_ID;
  doc["mac"]         = WiFi.macAddress();
  doc["rssi"]        = WiFi.RSSI();
  doc["relays"]      = NUM_RELAYS;
  doc["status"]      = "ONLINE";

  char buffer[384];
  serializeJson(doc, buffer, sizeof(buffer));

  // Publish to unified discovery topic (home/discovery) and room discovery topic
  mqtt.publish(DISCOVERY_TOPIC, buffer, false);
  mqtt.publish((getBaseTopic() + "/discovery").c_str(), buffer, false);

  Serial.printf("🔍 [DISCOVERY] Published to %s => %s\n", DISCOVERY_TOPIC, buffer);
}

void publishRelayStatus(int index) {
  if (index < 0 || index >= NUM_RELAYS || !mqtt.connected()) return;
  int relayNum = index + 1;

  JSON_DOC(doc, 320);
  doc["room"]        = CLASSROOM_ID;
  doc["zone_id"]     = ZONE_ID_STR;
  doc["device_type"] = DEVICE_TYPE_STR;
  doc["zone"]        = ZONE_ID;
  doc["board"]       = BOARD_ID;
  doc["relay"]       = relayNum;
  doc["state"]       = relayStates[index] ? "ON" : "OFF";
  doc["gpio"]        = pairConfigs[index].relayPin;
  doc["switch_gpio"] = pairConfigs[index].switchPin;
  doc["name"]        = pairConfigs[index].relayLabel;
  doc["switch_name"] = pairConfigs[index].switchName;
  doc["speed"]       = relayStates[index] ? fanSpeeds[index] : 0;
  doc["brightness"]  = relayStates[index] ? brightness[index] : 0;
  doc["uptime"]      = millis();

  char buffer[352];
  serializeJson(doc, buffer, sizeof(buffer));

  // 1. Hierarchical Zone Relay Topic (retained reported state): ruet/classroom/<CLASSROOM_ID>/zone/<ZONE_ID>/relay/<1-8>/status
  String topicZoneRelay = getZoneTopic() + "/relay/" + String(relayNum) + "/status";
  mqtt.publish(topicZoneRelay.c_str(), buffer, true);

  // 2. Board Status Alias: ruet/classroom/<CLASSROOM_ID>/status/board/<ZONE_ID>/relay/<1-8>
  String topicBoardRelay = getBaseTopic() + "/status/board/" + String(ZONE_ID) + "/relay/" + String(relayNum);
  mqtt.publish(topicBoardRelay.c_str(), buffer, true);

  // 3. Home Zone Status Alias: home/zone_<ZONE_ID>/relay/<1-8>/status
  String topicHomeRelay = "home/" + String(ZONE_ID_STR) + "/relay/" + String(relayNum) + "/status";
  mqtt.publish(topicHomeRelay.c_str(), buffer, false);

  Serial.printf("📡 [MQTT SYNC] %s Pair %d (%s D%d <-> %s D%d) -> %s\n",
                ZONE_ID_STR, relayNum,
                pairConfigs[index].relayLabel, pairConfigs[index].relayPin,
                pairConfigs[index].switchName, pairConfigs[index].switchPin,
                relayStates[index] ? "ON" : "OFF");
}

void publishAllRelayStatus() {
  for (int i = 0; i < NUM_RELAYS; i++) {
    publishRelayStatus(i);
  }
}

void publishHeartbeat() {
  if (!mqtt.connected()) return;

  JSON_DOC(doc, 512);
  doc["status"]      = "ONLINE";
  doc["online"]      = true;
  doc["zone_id"]     = ZONE_ID_STR;
  doc["device_type"] = DEVICE_TYPE_STR;
  doc["room"]        = CLASSROOM_ID;
  doc["zone"]        = ZONE_ID;
  doc["board"]       = BOARD_ID;
  doc["ip"]          = WiFi.localIP().toString();
  doc["mac"]         = WiFi.macAddress();
  doc["rssi"]        = WiFi.RSSI();
  doc["uptime"]      = millis();
  doc["uptimeSec"]   = millis() / 1000;
  doc["freeHeap"]    = ESP.getFreeHeap();
  doc["emergency"]   = emergencyLocked;

  JsonArray rArr = doc.createNestedArray("relays");
  for (int i = 0; i < NUM_RELAYS; i++) {
    rArr.add(relayStates[i] ? 1 : 0);
  }

  char buffer[512];
  serializeJson(doc, buffer, sizeof(buffer));

  String topicBoardStatus = getBaseTopic() + "/status/board/" + String(ZONE_ID);
  String topicZoneStatus  = getZoneTopic() + "/status";
  mqtt.publish(topicBoardStatus.c_str(), buffer, true);
  mqtt.publish(topicZoneStatus.c_str(), buffer, true);
  mqtt.publish(DISCOVERY_TOPIC, buffer, false);
}

void setRelay(int index, bool turnOn, bool publishFeedback) {
  if (index < 0 || index >= NUM_RELAYS) return;
  bool stateChanged = (relayStates[index] != turnOn);
  relayStates[index] = turnOn;
  digitalWrite(pairConfigs[index].relayPin, relayLevel(relayStates[index]));

  if (stateChanged) {
    Serial.printf("⚡ [PAIR %d] Relay %s (D%d) -> %s\n",
                  index + 1, pairConfigs[index].relayLabel,
                  pairConfigs[index].relayPin,
                  turnOn ? "ON" : "OFF");
  }

  if (stateChanged && publishFeedback && mqtt.connected()) {
    publishRelayStatus(index);
  }
}

// =============================================================================
// 7. PHYSICAL MANUAL SWITCH SCANNER (SERIAL LINKING: SWITCH <-> RELAY)
// =============================================================================
void pollManualSwitches() {
  unsigned long now = millis();
  for (int i = 0; i < NUM_RELAYS; i++) {
    if (pairConfigs[i].switchPin < 0) continue;
    int currentReading = digitalRead(pairConfigs[i].switchPin);

    if (currentReading != lastRawSwitchReading[i] || switchIrqTriggered[i]) {
      switchIrqTriggered[i] = false;
      lastRawSwitchReading[i] = currentReading;
      lastSwitchDebounceMs[i] = now;
    }

    if ((now - lastSwitchDebounceMs[i]) >= SWITCH_DEBOUNCE_MS) {
      if (currentReading != lastStableSwitchState[i]) {
        lastStableSwitchState[i] = currentReading;
        // Physical switch toggled (HIGH <-> LOW): invert paired relay state immediately!
        bool newRelayState = !relayStates[i];
        Serial.printf("🔘 [MANUAL SWITCH] %s (D%d) toggled -> Inverting Pair %d Relay %s (D%d) to %s\n",
                      pairConfigs[i].switchName, pairConfigs[i].switchPin,
                      i + 1, pairConfigs[i].relayLabel, pairConfigs[i].relayPin,
                      newRelayState ? "ON" : "OFF");
        setRelay(i, newRelayState, true);
      }
    }
  }
}

// =============================================================================
// 8. PHASE 5 PROTOCOL IMPLEMENTATION (classroom-control-v1)
// =============================================================================
void publishPhase5Status() {
  if (!mqtt.connected() || activeChallenge.length() == 0) return;
  JSON_DOC(doc, 640);
  doc["protocol"]           = PROTOCOL_NAME;
  doc["kind"]               = "status";
  doc["controller_id"]      = CONTROLLER_ID;
  doc["controller_boot_id"] = controllerBootId;
  doc["session_id"]         = activeSessionId;
  doc["challenge"]          = activeChallenge;
  doc["sequence"]           = phase5StatusSeq++;
  doc["clock_valid"]        = true;

  JsonObject outputs = doc.createNestedObject("outputs");
  for (int i = 0; i < NUM_RELAYS; i++) {
    String chName = "relay_" + String(i + 1);
    outputs[chName] = relayStates[i] ? "ON" : "OFF";
  }

  unsigned long nowMs = millis();
  doc["sent_at_unix_ms"]    = (uint64_t)nowMs;
  doc["expires_at_unix_ms"] = (uint64_t)(nowMs + 4000);

  char buf[640];
  serializeJson(doc, buf, sizeof(buf));
  mqtt.publish((getControllerPrefix() + "/status").c_str(), buf, false);
  mqtt.publish((getAltControllerPrefix() + "/status").c_str(), buf, false);
}

void handlePhase5Hello(String msg) {
  JSON_DOC(doc, 384);
  if (deserializeJson(doc, msg)) return;
  if (!doc["session_id"].isNull()) activeSessionId = doc["session_id"].as<String>();
  if (!doc["challenge"].isNull()) activeChallenge = doc["challenge"].as<String>();
  publishPhase5Status();
}

void handlePhase5Command(String msg, bool isDryRunTopic) {
  JSON_DOC(doc, 512);
  if (deserializeJson(doc, msg)) return;
  if (doc["protocol"].as<String>() != PROTOCOL_NAME) return;
  if (doc["controller_id"].as<String>() != CONTROLLER_ID) return;

  String sess = doc["session_id"].as<String>();
  String chal = doc["challenge"].as<String>();
  if (activeSessionId.length() > 0 && sess != activeSessionId && chal != "authorized") return;

  uint32_t seq = doc["sequence"].as<uint32_t>();
  if (seq <= lastCmdSequence) return;
  lastCmdSequence = seq;

  String channel = doc["channel"].as<String>();
  int relayIndex = -1;
  for (int i = 1; i <= NUM_RELAYS; i++) {
    if (channel.indexOf(String(i)) != -1) {
      relayIndex = i - 1;
      break;
    }
  }

  String desired = doc["desired_state"].as<String>();
  String mode    = doc["mode"].as<String>();
  String cmdId   = doc["command_id"].as<String>();
  String appid   = doc["appliance_id"].as<String>();

  bool isDryRun = isDryRunTopic || mode.equalsIgnoreCase("DRY_RUN");
  String actualState = "UNKNOWN";
  String resultState = "SIMULATED";

  if (relayIndex >= 0 && relayIndex < NUM_RELAYS) {
    if (isDryRun) {
      actualState = relayStates[relayIndex] ? "ON" : "OFF";
      resultState = "SIMULATED";
    } else {
      bool turnOn = desired.equalsIgnoreCase("ON");
      setRelay(relayIndex, turnOn, true);
      actualState = turnOn ? "ON" : "OFF";
      resultState = "APPLIED";
    }
  }

  JSON_DOC(ackDoc, 512);
  ackDoc["protocol"]           = PROTOCOL_NAME;
  ackDoc["kind"]               = "ack";
  ackDoc["controller_id"]      = CONTROLLER_ID;
  ackDoc["controller_boot_id"] = controllerBootId;
  ackDoc["session_id"]         = activeSessionId;
  ackDoc["challenge"]          = activeChallenge;
  ackDoc["sequence"]           = phase5AckSeq++;
  ackDoc["command_id"]         = cmdId;
  ackDoc["command_sequence"]   = seq;
  ackDoc["appliance_id"]       = appid;
  ackDoc["desired_state"]      = desired;
  ackDoc["result"]             = resultState;
  ackDoc["actual_state"]       = actualState;

  unsigned long nowMs = millis();
  ackDoc["sent_at_unix_ms"]    = (uint64_t)nowMs;
  ackDoc["expires_at_unix_ms"] = (uint64_t)(nowMs + 3000);

  char ackBuf[512];
  serializeJson(ackDoc, ackBuf, sizeof(ackBuf));
  mqtt.publish((getControllerPrefix() + "/ack").c_str(), ackBuf, false);
  mqtt.publish((getAltControllerPrefix() + "/ack").c_str(), ackBuf, false);
  publishPhase5Status();
}

// =============================================================================
// 9. MQTT INCOMING COMMAND HANDLER
// =============================================================================
void onMqttMessage(char* topic, byte* payload, unsigned int length) {
  String strTopic = String(topic);
  if (strTopic.endsWith("/status") || strTopic.indexOf("/status") != -1 || strTopic == DISCOVERY_TOPIC) {
    return;
  }

  String msg = "";
  for (unsigned int i = 0; i < length; i++) {
    msg += (char)payload[i];
  }
  msg.trim();

  Serial.printf("\n📩 [MQTT RX] %s => %s\n", topic, msg.c_str());

  // 1. Phase 5 Wire Protocol
  if (strTopic == getControllerPrefix() + "/hello" || strTopic == getAltControllerPrefix() + "/hello") {
    handlePhase5Hello(msg);
    return;
  }
  if (strTopic == getControllerPrefix() + "/command" || strTopic == getAltControllerPrefix() + "/command") {
    handlePhase5Command(msg, false);
    return;
  }
  if (strTopic == getControllerPrefix() + "/dry_run/command" || strTopic == getAltControllerPrefix() + "/dry_run/command") {
    handlePhase5Command(msg, true);
    return;
  }

  // 2. Discovery & Status Scan Query
  if (strTopic == "home/discovery/query" ||
      strTopic == getBaseTopic() + "/command/query" ||
      strTopic == "ruet/classroom/all/command/query" ||
      strTopic.endsWith("/query")) {
    Serial.printf("🔍 [SCAN QUERY] Broadcasting discovery & %d-relay status for %s...\n", NUM_RELAYS, ZONE_ID_STR);
    publishDiscovery();
    publishHeartbeat();
    publishAllRelayStatus();
    return;
  }

  // 3. Zone Master Command (ALL ON / ALL OFF for this 8-relay switchboard)
  if (strTopic == getZoneTopic() + "/command/all" ||
      strTopic == getBoardTopic() + "/command/all" ||
      strTopic == "home/" + String(ZONE_ID_STR) + "/command/all") {
    bool turnOn = (msg.equalsIgnoreCase("ALL_ON") || msg.equalsIgnoreCase("ON") || msg == "1");
    for (int i = 0; i < NUM_RELAYS; i++) {
      setRelay(i, turnOn, true);
    }
    publishHeartbeat();
    return;
  }

  // 4. Individual Relay Command (Relays 1..8)
  int targetRelay = -1;
  String zoneRelayPrefix  = getZoneTopic() + "/relay/";
  String boardRelayPrefix = getBoardTopic() + "/relay/";
  String homeRelayPrefix  = "home/" + String(ZONE_ID_STR) + "/relay/";

  if (strTopic.startsWith(zoneRelayPrefix)) {
    String sub = strTopic.substring(zoneRelayPrefix.length());
    int slash = sub.indexOf('/');
    targetRelay = (slash != -1 ? sub.substring(0, slash) : sub).toInt();
  } else if (strTopic.startsWith(boardRelayPrefix)) {
    String sub = strTopic.substring(boardRelayPrefix.length());
    int slash = sub.indexOf('/');
    targetRelay = (slash != -1 ? sub.substring(0, slash) : sub).toInt();
  } else if (strTopic.startsWith(homeRelayPrefix)) {
    String sub = strTopic.substring(homeRelayPrefix.length());
    int slash = sub.indexOf('/');
    targetRelay = (slash != -1 ? sub.substring(0, slash) : sub).toInt();
  }

  if (targetRelay >= 1 && targetRelay <= NUM_RELAYS) {
    int idx = targetRelay - 1;
    bool newState = relayStates[idx];

    if (msg.startsWith("{")) {
      JSON_DOC(doc, 256);
      if (!deserializeJson(doc, msg)) {
        if (!doc["room"].isNull()) {
          String targetRoom = doc["room"].as<String>();
          if (targetRoom.length() > 0 && targetRoom != String(CLASSROOM_ID)) {
            Serial.printf("⚠️ [VALIDATION] Ignored command addressed to room '%s'\n", targetRoom.c_str());
            return;
          }
        }
        if (!doc["zone"].isNull() && doc["zone"].is<int>()) {
          int targetZone = doc["zone"].as<int>();
          if (targetZone > 0 && targetZone != ZONE_ID) {
            Serial.printf("⚠️ [VALIDATION] Ignored command addressed to zone %d\n", targetZone);
            return;
          }
        }
        if (!doc["state"].isNull()) {
          String st = doc["state"].as<String>();
          st.toUpperCase();
          if (st == "TOGGLE") newState = !relayStates[idx];
          else newState = (st == "ON" || st == "1" || st == "TRUE");
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

  // 5. Classroom Master Power (All Switchboards in Room)
  if (strTopic == getBaseTopic() + "/command/all" || strTopic == "home/command/all") {
    bool turnOn = (msg.equalsIgnoreCase("ALL_ON") || msg.equalsIgnoreCase("ON") || msg == "1");
    for (int i = 0; i < NUM_RELAYS; i++) {
      setRelay(i, turnOn, true);
    }
    publishHeartbeat();
    return;
  }

  // 6. Classroom Emergency Cutoff
  if (strTopic == getBaseTopic() + "/command/emergency" || strTopic == "home/command/emergency") {
    emergencyLocked = (msg.equalsIgnoreCase("CUTOFF") || msg.equalsIgnoreCase("LOCK") || msg == "1");
    for (int i = 0; i < NUM_RELAYS; i++) {
      digitalWrite(pairConfigs[i].relayPin, relayLevel(relayStates[i]));
    }
    publishAllRelayStatus();
    publishHeartbeat();
    return;
  }
}

// =============================================================================
// 10. WI-FI & MQTT CONNECTION MANAGEMENT
// =============================================================================
void connectWifi() {
  if (WiFi.status() == WL_CONNECTED) return;
  Serial.printf("\n📶 [WiFi] Connecting to '%s' ", WIFI_SSID);
  WiFi.mode(WIFI_STA);
  WiFi.begin(CLASSROOM_WIFI_SSID, CLASSROOM_WIFI_PASSWORD);
  int retry = 0;
  while (WiFi.status() != WL_CONNECTED && retry < 20) {
    // Keep polling physical manual switches even while Wi-Fi connects!
    pollManualSwitches();
    delay(250);
    Serial.print(".");
    retry++;
  }
  if (WiFi.status() == WL_CONNECTED) {
    Serial.printf("\n✅ [WiFi] Connected! IP: %s | RSSI: %d dBm\n",
                  WiFi.localIP().toString().c_str(), WiFi.RSSI());
  }
}

void connectMqtt() {
  if (mqtt.connected() || WiFi.status() != WL_CONNECTED) return;

  String clientId = "ESP32_" + String(ZONE_ID_STR) + "_" + String((uint32_t)ESP.getEfuseMac(), HEX);
  String lwtTopic = getBaseTopic() + "/status/board/" + String(ZONE_ID);
  String lwtMsg   = "{\"status\":\"OFFLINE\",\"online\":false,\"zone_id\":\"" + String(ZONE_ID_STR) +
                    "\",\"device_type\":\"switchboard\",\"zone\":" + String(ZONE_ID) +
                    ",\"board\":" + String(BOARD_ID) + "}";

  bool success = false;
  if (strlen(MQTT_USER) > 0) {
    success = mqtt.connect(clientId.c_str(), MQTT_USER, MQTT_PASSWORD, lwtTopic.c_str(), 1, true, lwtMsg.c_str());
  } else {
    success = mqtt.connect(clientId.c_str(), lwtTopic.c_str(), 1, true, lwtMsg.c_str());
  }

  if (success) {
    Serial.printf("🎉 [MQTT] Connected as %s (%s) to %s:%d\n",
                  clientId.c_str(), ZONE_ID_STR, MQTT_BROKER, MQTT_PORT);

    // Subscribe strictly to ACL-authorized topics for this board
    mqtt.subscribe((getZoneTopic() + "/#").c_str(), 1);
    mqtt.subscribe((getBoardTopic() + "/#").c_str(), 1);
    mqtt.subscribe(("home/" + String(ZONE_ID_STR) + "/#").c_str(), 1);
    mqtt.subscribe((getBaseTopic() + "/command/#").c_str(), 1);
    mqtt.subscribe("home/discovery/query", 1);

    // Phase 5 Subscriptions
    mqtt.subscribe((getControllerPrefix() + "/hello").c_str(), 1);
    mqtt.subscribe((getControllerPrefix() + "/command").c_str(), 1);
    mqtt.subscribe((getControllerPrefix() + "/dry_run/command").c_str(), 1);
    mqtt.subscribe((getAltControllerPrefix() + "/hello").c_str(), 1);
    mqtt.subscribe((getAltControllerPrefix() + "/command").c_str(), 1);
    mqtt.subscribe((getAltControllerPrefix() + "/dry_run/command").c_str(), 1);

    // Broadcast Discovery, retained Heartbeat, and retained 8-Relay states immediately upon boot/connect
    publishDiscovery();
    publishHeartbeat();
    publishAllRelayStatus();
  }
}

// =============================================================================
// 11. SETUP & MAIN LOOP
// =============================================================================
void setup() {
  Serial.begin(115200);
  delay(500);
  snprintf(controllerBootId, sizeof(controllerBootId), "boot_%08x%08x",
           (uint32_t)ESP.getEfuseMac(), (uint32_t)esp_random());

  Serial.println("\n==============================================================");
  Serial.printf("  Smart Home / Classroom 8-Switchboard Controller (%s)\n", ZONE_ID_STR);
  Serial.printf("  Classroom: %s | Board #%d | %d Relays <-> %d Manual Switches\n", CLASSROOM_ID, BOARD_ID, NUM_RELAYS, NUM_RELAYS);
  Serial.println("==============================================================");

  configureHardwarePins();
  for (int i = 0; i < NUM_RELAYS; i++) {
    if (pairConfigs[i].switchPin >= 0) {
      Serial.printf("  Pair %d: Relay %-7s (GPIO %2d) <-> Switch %-3s (GPIO %2d)\n",
                    i + 1, pairConfigs[i].relayLabel, pairConfigs[i].relayPin,
                    pairConfigs[i].switchName, pairConfigs[i].switchPin);
    } else {
      Serial.printf("  Pair %d: Relay %-7s (GPIO %2d) <-> No physical switch (App/MQTT only)\n",
                    i + 1, pairConfigs[i].relayLabel, pairConfigs[i].relayPin);
    }
  }

  connectWifi();
  mqtt.setServer(MQTT_BROKER, MQTT_PORT);
  mqtt.setCallback(onMqttMessage);
  mqtt.setBufferSize(768);
  mqtt.setKeepAlive(30);
  mqtt.setSocketTimeout(5);
}

void loop() {
  // 1. Always poll manual physical switches first for instant (<1ms) hardware response
  pollManualSwitches();

  // 2. Maintain Wi-Fi & MQTT connectivity
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

  // 3. Periodic Heartbeat & Discovery keep-alive
  unsigned long now = millis();
  if (now - lastHeartbeat >= HEARTBEAT_INTERVAL) {
    lastHeartbeat = now;
    if (mqtt.connected()) {
      publishHeartbeat();
    }
  }
}
