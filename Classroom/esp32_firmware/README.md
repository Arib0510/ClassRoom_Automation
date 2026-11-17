# ClassPulse IoT — Multi-Zone 8-Switch & Standalone AC ESP32 Guide

Complete hardware, firmware, and MQTT configuration guide for the 3 multi-switch zone boards (`zone_1`, `zone_2`, `zone_3`) and the independent Standalone AC controller (`zone_ac`).

Before compiling, copy each sketch's `secrets.example.h` to `secrets.h` and enter
the private Wi-Fi and role-specific broker credentials. See the [laptop broker
migration guide](../docs/mqtt_laptop_broker_migration.md). `secrets.h` is ignored
by Git.

---

## 1. Hardware & GPIO Mapping

### Zone 1 (`ZONE_ID = 1`, `zone_1` — ESP32 30-Pin "1st Board")
6 active Relays (`OUTPUT`) and 6 Manual Switches linked in pairs (Left starts `In1`, Right starts `In5`):

| Pair | Relay Label | Relay GPIO | Switch Label | Switch GPIO |
| :---: | :---: | :---: | :---: | :---: |
| **Pair 1** | `In1 [L]` | **D16** (`GPIO 16`) | `S1` | **D14** (`GPIO 14`) |
| **Pair 2** | `In2 [L]` | **D4** (`GPIO 4`) | `S2` | **D27** (`GPIO 27`) |
| **Pair 3** | `In3 [L]` | **D2** (`GPIO 2`) | `S3` | **D26** (`GPIO 26`) |
| **Pair 4** | `In4 [L]` | **D15** (`GPIO 15`) | `S4` | **D25** (`GPIO 25`) |
| **Pair 5** | `In5 [R]` | **D21** (`GPIO 21`) | `S5` | **D33** (`GPIO 33`) |
| **Pair 6** | `In6 [R]` | **D19** (`GPIO 19`) | `S6` | **D34** (`GPIO 34`, `INPUT` only) |

### Zone 2 (`ZONE_ID = 2`, `zone_2` — Unlabeled Board)
6 active Relays (`OUTPUT`, App/MQTT only — no physical switches wired; `In5` uses `GPIO 17` instead of `GPIO 11` flash pin):

| Pair | Relay Label | Relay GPIO | Switch Label | Switch GPIO |
| :---: | :---: | :---: | :---: | :---: |
| **Pair 1** | `In1` | **G4** (`GPIO 4`) | `NONE` | App/MQTT only |
| **Pair 2** | `In2` | **G0** (`GPIO 0`) | `NONE` | App/MQTT only |
| **Pair 3** | `In3` | **G2** (`GPIO 2`) | `NONE` | App/MQTT only |
| **Pair 4** | `In4` | **G15** (`GPIO 15`) | `NONE` | App/MQTT only |
| **Pair 5** | `In5` | **G17** (`GPIO 17`) | `NONE` | App/MQTT only |
| **Pair 6** | `In6` | **G5** (`GPIO 5`) | `NONE` | App/MQTT only |

### Zone 3 (`ZONE_ID = 3`, `zone_3` — "3rd One")
5 active Relays (`OUTPUT`) and 5 Manual Switches (`INPUT_PULLUP`):

| Pair | Relay Label | Relay GPIO | Switch Label | Switch GPIO |
| :---: | :---: | :---: | :---: | :---: |
| **Pair 1** | `In1` | **D5** (`GPIO 5`) | `SW1` | **D32** (`GPIO 32`) |
| **Pair 2** | `In2` | **D4** (`GPIO 4`) | `SW2` | **D33** (`GPIO 33`) |
| **Pair 3** | `In3` | **D2** (`GPIO 2`) | `SW3` | **D25** (`GPIO 25`) |
| **Pair 4** | `In4` | **D15** (`GPIO 15`) | `SW4` | **D26** (`GPIO 26`) |
| **Pair 5** | `In5` | **D18** (`GPIO 18`) | `SW5` | **D27** (`GPIO 27`) |

### Standalone Dual-AC IR Controller (`zone_ac` — Separate ESP32 Board)
Runs on a dedicated ESP32 board isolated from the 8-switch zone boards, driving **two IR transmitter/receiver circuits** for the **two Gree Air Conditioners** in the classroom:
- **Gree AC #1 (Front / Unit 1)**: IR Circuit on **GPIO 33**
- **Gree AC #2 (Back / Unit 2)**: IR Circuit on **GPIO 12**

---

## 2. Firmware Files & MQTT Discovery

1. **8-Switchboard Firmware**: `smart_classroom_switchboard_mqtt/smart_classroom_switchboard_mqtt.ino`
   - Set `#define ZONE_ID 1` (or `2`, or `3`) before flashing.
   - Publishes discovery to `home/discovery`:
     ```json
     {"zone_id": "zone_1", "device_type": "switchboard", "ip": "192.168.X.X"}
     ```
2. **Standalone Dual-AC IR Controller Firmware**: `esp32_ac_ir_controller/esp32_ac_ir_controller.ino`
   - Maps **GPIO 33** (Gree AC #1 IR circuit) and **GPIO 12** (Gree AC #2 IR circuit).
   - Publishes discovery to `home/discovery`:
     ```json
     {"zone_id": "zone_ac", "device_type": "ac_unit", "ip": "192.168.X.X", "ac_count": 2, "ac1_gpio": 33, "ac2_gpio": 12, "protocol": "GREE"}
     ```
