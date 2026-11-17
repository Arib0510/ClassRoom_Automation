# Laptop MQTT broker migration

## Broker setup already applied

The Windows Mosquitto service uses MQTT 3.1.1 on `10.247.68.155:1883`. It binds
only to the trusted hotspot Wi-Fi address. Windows Firewall allows inbound TCP
1883 only on the Private Wi-Fi interface from `10.247.68.0/24`. Anonymous access
is disabled. The service ACL protects the broker files, and credentials are
stored outside the repository under `C:\ProgramData\ClassroomMQTT`.

Run the provisioning script from elevated PowerShell if the hotspot address or
subnet changes:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Classroom\scripts\configure_windows_mosquitto.ps1 `
  -BrokerAddress 10.247.68.155 `
  -Subnet 10.247.68.0/24 `
  -InterfaceAlias 'Wi-Fi'
```

It reuses the protected generated credentials across reruns. `client-credentials.txt`
is readable only by SYSTEM and local Administrators. Copy each role's credentials
directly into its device configuration; do not paste them into chat, logs, Git,
or shell history.

On the laptop, an administrator can open the protected credential file locally:

```powershell
notepad C:\ProgramData\ClassroomMQTT\client-credentials.txt
```

## Raspberry Pi 5 vision process

Copy `Vision_Model/config/mqtt.env.example` to `Vision_Model/config/mqtt.env` on
the Pi. Fill in the `pi-vision` password from the protected Windows file and set
the laptop hotspot address. Then run:

```bash
cd ~/Classroom_Automation/Vision_Model
chmod 600 config/mqtt.env
set -a
. config/mqtt.env
set +a
.venv/bin/python scripts/run_classroom_vision.py \
  --broker "$CLASSROOM_MQTT_HOST" --port 1883 --mode DRY_RUN --no-gui
```

For systemd, configure `EnvironmentFile` to that private env file. The existing
six-zone geometry, detector thresholds, tracking, freshness policy, and manual
override handling remain in the vision and controller code.

## ESP32 and app setup

For each firmware folder, copy `secrets.example.h` to `secrets.h`, enter the
trusted Wi-Fi credentials, laptop host, and that board's broker username/password.
For switchboards, set the username to `esp32-board01`, `esp32-board02`, or
`esp32-board03` to match `ZONE_ID`; put only that board's password in its local
header. Compile and flash only during an approved hardware deployment; flashing
is not part of broker verification.

Example compile and upload commands (replace `COMx` with the board's serial
port; these commands are deployment steps and have not been run here):

```powershell
Copy-Item .\Classroom\esp32_firmware\smart_classroom_switchboard_mqtt\secrets.example.h `
  .\Classroom\esp32_firmware\smart_classroom_switchboard_mqtt\secrets.h
notepad .\Classroom\esp32_firmware\smart_classroom_switchboard_mqtt\secrets.h
arduino-cli compile --fqbn esp32:esp32:esp32 .\Classroom\esp32_firmware\smart_classroom_switchboard_mqtt
arduino-cli upload -p COMx --fqbn esp32:esp32:esp32 .\Classroom\esp32_firmware\smart_classroom_switchboard_mqtt

Copy-Item .\Classroom\esp32_firmware\esp32_ac_ir_controller\secrets.example.h `
  .\Classroom\esp32_firmware\esp32_ac_ir_controller\secrets.h
notepad .\Classroom\esp32_firmware\esp32_ac_ir_controller\secrets.h
arduino-cli compile --fqbn esp32:esp32:esp32 .\Classroom\esp32_firmware\esp32_ac_ir_controller
arduino-cli upload -p COMx --fqbn esp32:esp32:esp32 .\Classroom\esp32_firmware\esp32_ac_ir_controller
```

Run the Flutter app with the broker host set at build time if it differs from the
current default:

```powershell
cd Classroom
flutter run --dart-define=MQTT_BROKER_HOST=10.247.68.155
```

In Settings or the Connectivity panel, enter the `flutter-app` username and
password. The app keeps credentials in memory only; enter them again after an
app restart. Its command and status topics are unchanged.

## Safe checks and deployment boundaries

The local broker check reads the protected credential file and only uses
non-actuating topics:

```powershell
Vision_Model\.venv-diagnostics\Scripts\python.exe Vision_Model\scripts\verify_windows_broker.py
```

It checks anonymous rejection, authenticated publish/subscribe, app-to-controller
query delivery with the Pi disconnected, retained Last Will delivery, and a
cross-board ACL denial. It does not connect to cameras, ESP32 hardware, or
appliances. Pi and firmware software checks do not establish radio range, model
accuracy, calibration quality, physical relay state, or appliance safety.

The old Pi broker remains available for rollback. No firmware was flashed, no
camera was opened, and no appliance command was sent during this migration.
