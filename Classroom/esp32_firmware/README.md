# ClassPulse IoT — ESP32 Quick Start Guide

Simple step-by-step instructions to flash the ESP32, add devices in the ClassPulse app, and control your hardware.

---

## 🚀 Quick Start in 3 Easy Steps

### Step 1: Flash the ESP32
1. Open **Arduino IDE**.
2. Open either:
   - Full 6-Relay Controller: `esp32_firmware/smart_classroom_switchboard_mqtt/smart_classroom_switchboard_mqtt.ino`
   - Single Relay Test: `test_setup/esp32_single_relay_test/esp32_single_relay_test.ino`
3. Edit your Wi-Fi password (around line 44):
   ```cpp
   #define WIFI_SSID       "SWAPAN_CID"
   #define WIFI_PASSWORD   "YOUR_WIFI_PASSWORD"
   ```
4. Connect ESP32 via USB.
5. In Arduino IDE:
   - Select Board: **Tools → Board → esp32 → ESP32 Dev Module**
   - Select Port: **Tools → Port → COM...**
6. Click **Upload (➡️)**.
7. Open **Tools → Serial Monitor** (`115200 baud`) to verify:
   ```text
   [WiFi] Connected! IP: 192.168.x.x
   [MQTT] Connecting to broker.emqx.io ... CONNECTED!
   ```

---

### Step 2: Add Device in the App
1. Open the **ClassPulse IoT** app on your phone.
2. Select your Classroom (or tap **+ Add Classroom** if you don't have one yet).
3. Tap the **"+ Add Device"** button.
4. Fill in the fields:

| Field | Example: Fan 1 | Example: Light 1 |
| :--- | :--- | :--- |
| **Category** | Select **Ceiling Fan** | Select **Light** |
| **Device Name** | `Ceiling Fan 1` | `Classroom Light 1` |
| **GPIO Pin** | `GPIO 18` | `GPIO 21` |
| **Zone** | Zone 1 | Zone 1 |
| **Protocol** | MQTT | MQTT |

5. Tap **Save Device**.

---

### Step 3: Run & Test the Device!
1. **Tap the switch card**: 
   - The relay clicks physically (<10ms).
   - ESP32 onboard blue LED (GPIO 2) illuminates.
   - App card glows cyan showing **"MQTT Synced"**.
2. **Fan Speed / Dimmer**: Drag the speed or brightness slider to adjust levels live.
3. **Master Control**: Tap **"Turn Off All"** at the top of the room to power off all relays at once.

---

## 🔌 Hardware Pin Mapping Reference

### Full Switchboard Controller (Board 1):
| Appliance | App Name | ESP32 GPIO Pin | Relay Channel |
| :--- | :--- | :---: | :---: |
| **Fan 1** | `Ceiling Fan 1` | `GPIO 18` | Relay 1 |
| **Fan 2** | `Ceiling Fan 2` | `GPIO 19` | Relay 2 |
| **Light 1** | `Classroom Light 1` | `GPIO 21` | Relay 3 |
| **Light 2** | `Classroom Light 2` | `GPIO 22` | Relay 4 |
| **Light 3** | `Classroom Light 3` | `GPIO 23` | Relay 5 |
| **Light 4** | `Classroom Light 4` | `GPIO 25` | Relay 6 |

### Single Relay Test:
- **Relay Pin**: `GPIO 18` (Works as either `Ceiling Fan 1` or `Light 1`)
- **Status LED**: `GPIO 2` (Onboard Blue LED)

---

## 📡 MQTT Topic Specification

- **Commands (App ➡️ ESP32)**:
  - Fan: `ruet/classroom/{roomId}/command/fan/{number}`
  - Light: `ruet/classroom/{roomId}/command/light/{number}`
  - Master All: `ruet/classroom/{roomId}/command/all`
  - Emergency Cutoff: `ruet/classroom/{roomId}/command/emergency`
- **Feedback (ESP32 ➡️ App)**:
  - Fan: `ruet/classroom/{roomId}/status/fan/{number}`
  - Light: `ruet/classroom/{roomId}/status/light/{number}`
  - Board Telemetry: `ruet/classroom/{roomId}/status/board/{boardId}`

---

## 📦 Required Arduino Libraries
Available in Arduino Library Manager (**Tools ➡️ Manage Libraries...**):
1. **PubSubClient** by Nick O'Leary *(Pre-installed)*
2. **ArduinoJson** by Benoit Blanchon *(v6 or v7 supported)*
