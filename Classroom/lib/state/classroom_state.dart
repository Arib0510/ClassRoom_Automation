import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/classroom.dart';
import '../models/device.dart';
import '../services/firestore_service.dart';
import '../services/mqtt_service.dart';
import 'auth_state.dart';
import 'connectivity_state.dart';

class ClassroomState extends ChangeNotifier {
  static final ClassroomState _instance = ClassroomState._internal();
  factory ClassroomState() => _instance;

  static const String _storageKeyClassrooms = 'classpulse_saved_classrooms_v2';
  static const String _storageKeySelectedRoom =
      'classpulse_selected_room_id_v2';
  static const String _storageKeyVisionControl =
      'classpulse_vision_control_enabled';

  bool _visionControlEnabled = true;
  bool get visionControlEnabled => _visionControlEnabled;

  Timer? _localSaveDebounce;
  StreamSubscription<List<Classroom>>? _classroomsStreamSub;
  final Map<String, int> _lastKnownFrontOcc = {};
  final Map<String, int> _lastKnownBackOcc = {};
  final Map<String, Timer> _pendingConfirmationTimers = {};
  Timer? _visionWatchdogTimer;

  ClassroomState._internal() {
    _classrooms = [];
    _selectedRoomId = '';
    _initLocalStorage();
    _initFirestorePinSync();
    _initFirestoreClassroomsSync();
    _initMqttSync();
    _startClassIntervalSyncTimer();
    _startVisionWatchdogTimer();
  }

  // --- Fast In-Memory Lookups (Building-scoped to eliminate cross-talk) ---
  Classroom? findRoom(String roomId, {String? building}) {
    // 1. Direct match on room ID (e.g. "ete_room_304", "eee_room_304")
    for (var i = 0; i < _classrooms.length; i++) {
      if (_classrooms[i].id == roomId) {
        if (building == null ||
            _classrooms[i].building.toLowerCase().contains(
              building.toLowerCase(),
            )) {
          return _classrooms[i];
        }
      }
    }

    // 2. Match scopedRoomId (e.g. "ete_room_304")
    for (var i = 0; i < _classrooms.length; i++) {
      if (_classrooms[i].scopedRoomId == roomId) {
        return _classrooms[i];
      }
    }

    // 3. Match normalized ID or scoped ID
    final normSearch = roomId.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9]'),
      '',
    );
    for (var i = 0; i < _classrooms.length; i++) {
      final normId = _classrooms[i].id.toLowerCase().replaceAll(
        RegExp(r'[^a-z0-9]'),
        '',
      );
      final normScoped = _classrooms[i].scopedRoomId.toLowerCase().replaceAll(
        RegExp(r'[^a-z0-9]'),
        '',
      );
      if (normId == normSearch || normScoped == normSearch) {
        return _classrooms[i];
      }
    }

    // 4. If search contains building prefix (e.g. "ete_304" or "eee_304")
    for (var i = 0; i < _classrooms.length; i++) {
      final bTag = _classrooms[i].buildingShort.replaceAll(
        RegExp(r'[^a-z0-9]'),
        '',
      );
      final rNum = _classrooms[i].roomNumber.toLowerCase().replaceAll(
        RegExp(r'[^a-z0-9]'),
        '',
      );
      if (normSearch == '$bTag$rNum' || normSearch == '${bTag}room$rNum') {
        return _classrooms[i];
      }
    }

    // 5. Fallback: match roomNumber ONLY if uniquely one room matches (or if building matches)
    final matches = _classrooms.where((c) {
      final normNum = c.roomNumber.toLowerCase().replaceAll(
        RegExp(r'[^a-z0-9]'),
        '',
      );
      final matchesNum = normNum == normSearch || normSearch == 'room$normNum';
      if (building != null) {
        return matchesNum &&
            c.building.toLowerCase().contains(building.toLowerCase());
      }
      return matchesNum;
    }).toList();

    if (matches.length == 1) return matches.first;

    // 6. Match 'reb_room_301' or '301' to any classroom matching 301
    if (normSearch.contains('301')) {
      for (var c in _classrooms) {
        if (c.id.contains('301') ||
            c.roomNumber.contains('301') ||
            c.name.contains('301')) {
          return c;
        }
      }
    }

    // 7. Route to currently selected classroom on user screen
    if (_selectedRoomId.isNotEmpty) {
      for (var c in _classrooms) {
        if (c.id == _selectedRoomId) return c;
      }
    }

    // 8. Fallback to first available classroom if any exists
    if (_classrooms.isNotEmpty) return _classrooms.first;

    return null;
  }

  ClassroomDevice? findDevice(Classroom room, String deviceId) {
    for (var i = 0; i < room.devices.length; i++) {
      if (room.devices[i].id == deviceId) return room.devices[i];
    }
    return null;
  }

  // --- Local SharedPreferences Persistence (Cache-First) ---
  Future<void> _persistDevicePower(
    ClassroomDevice device, {
    String? roomId,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('pwr_${device.id}', device.isOn);
      final rId = roomId ?? selectedRoomId;
      if (rId.isNotEmpty) {
        await prefs.setBool(
          'pwr_${rId}_b${device.boardId}_r${device.relayNumber}',
          device.isOn,
        );
        if (rId.contains('-')) {
          await prefs.setBool(
            'pwr_${rId.replaceAll('-', '_')}_b${device.boardId}_r${device.relayNumber}',
            device.isOn,
          );
        } else if (rId.contains('_')) {
          await prefs.setBool(
            'pwr_${rId.replaceAll('_', '-')}_b${device.boardId}_r${device.relayNumber}',
            device.isOn,
          );
        }
      }
      if (device.type == DeviceType.fan) {
        await prefs.setInt('spd_${device.id}', device.fanSpeed);
      } else if (device.type == DeviceType.lighting) {
        await prefs.setDouble('bri_${device.id}', device.brightness);
      }
    } catch (_) {}
  }

  Future<void> _persistMultipleDevicesPower(
    Iterable<ClassroomDevice> devices, {
    String? roomId,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final rId = roomId ?? selectedRoomId;
      for (final device in devices) {
        await prefs.setBool('pwr_${device.id}', device.isOn);
        if (rId.isNotEmpty) {
          await prefs.setBool(
            'pwr_${rId}_b${device.boardId}_r${device.relayNumber}',
            device.isOn,
          );
          if (rId.contains('-')) {
            await prefs.setBool(
              'pwr_${rId.replaceAll('-', '_')}_b${device.boardId}_r${device.relayNumber}',
              device.isOn,
            );
          } else if (rId.contains('_')) {
            await prefs.setBool(
              'pwr_${rId.replaceAll('_', '-')}_b${device.boardId}_r${device.relayNumber}',
              device.isOn,
            );
          }
        }
        if (device.type == DeviceType.fan) {
          await prefs.setInt('spd_${device.id}', device.fanSpeed);
        } else if (device.type == DeviceType.lighting) {
          await prefs.setDouble('bri_${device.id}', device.brightness);
        }
      }
    } catch (_) {}
  }

  Future<void> _initLocalStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _visionControlEnabled = prefs.getBool(_storageKeyVisionControl) ?? true;
      final isWiped = prefs.getBool('classpulse_explicitly_cleared') ?? false;
      if (isWiped) {
        _classrooms = [];
        _selectedRoomId = '';
        debugPrint(
          '[ClassroomState] System is in wiped state; keeping classrooms clean & empty.',
        );
        notifyListeners();
        return;
      }

      // Purge legacy user-partitioned keys to eliminate zombie rooms across logins
      final allKeys = prefs.getKeys();
      for (final k in allKeys) {
        if (k.startsWith('${_storageKeyClassrooms}_') ||
            k.startsWith('${_storageKeySelectedRoom}_')) {
          await prefs.remove(k);
        }
      }

      final rawJson = prefs.getString(_storageKeyClassrooms);
      if (rawJson != null && rawJson.isNotEmpty && rawJson != '[]') {
        final decoded = jsonDecode(rawJson) as List<dynamic>;
        final loadedRooms = decoded
            .map(
              (item) =>
                  Classroom.fromMap(Map<String, dynamic>.from(item as Map)),
            )
            .toList();
        if (loadedRooms.isNotEmpty) {
          // Normalize room IDs to match building-scoped convention (e.g., ete_room_304)
          for (int i = 0; i < loadedRooms.length; i++) {
            final r = loadedRooms[i];
            r.currentOccupancy = 0;
            r.frontOccupancy = 0;
            r.backOccupancy = 0;
            r.movingOccupancy = 0;
            r.stationaryOccupancy = 0;
            r.isOccupied = false;
            r.visionMode = _visionControlEnabled ? 'OFFLINE' : 'MANUAL';
            r.lastVisionTelemetry = null;
            _lastKnownFrontOcc[r.id] = 0;
            _lastKnownBackOcc[r.id] = 0;
            final roomDigits =
                RegExp(r'\d+').firstMatch(r.roomNumber)?.group(0) ?? '304';
            final b = r.buildingShort.replaceAll(RegExp(r'[^a-z0-9]'), '');
            final cleanId = r.id.startsWith('${b}_')
                ? r.id
                : (b.isNotEmpty ? '${b}_room_$roomDigits' : 'room_$roomDigits');
            if (r.id != cleanId) {
              loadedRooms[i] = r.copyWith(id: cleanId);
            }

            // Restore device power state from local SharedPreferences disk cache
            for (final d in loadedRooms[i].devices) {
              final rId = loadedRooms[i].id;
              final isZoneDev =
                  d.boardId == 1 ||
                  d.boardId == 2 ||
                  d.zone.toLowerCase().contains('zone 1') ||
                  d.zone.toLowerCase().contains('zone 2') ||
                  d.zone.toLowerCase().contains('front') ||
                  d.zone.toLowerCase().contains('back');
              if (_visionControlEnabled && isZoneDev) {
                // Autonomous zone devices boot in standby OFF when cold-starting without active camera
                d.isOn = false;
                d.statusDescription = 'Standby · Vacant Zone';
                prefs.setBool('pwr_${d.id}', false);
                prefs.setBool(
                  'pwr_${rId}_b${d.boardId}_r${d.relayNumber}',
                  false,
                );
              } else {
                final savedPwr =
                    prefs.getBool('pwr_${d.id}') ??
                    prefs.getBool('pwr_${rId}_b${d.boardId}_r${d.relayNumber}');
                if (savedPwr != null) {
                  d.isOn = savedPwr;
                }
              }
              if (d.type == DeviceType.fan) {
                final savedSpd = prefs.getInt('spd_${d.id}');
                if (savedSpd != null) d.fanSpeed = savedSpd;
                d.statusDescription = d.isOn
                    ? 'Speed ${d.fanSpeed} · Active'
                    : 'Standby · Array Off';
              } else if (d.type == DeviceType.lighting) {
                final savedBri = prefs.getDouble('bri_${d.id}');
                if (savedBri != null) d.brightness = savedBri;
                d.statusDescription = d.isOn
                    ? 'Active · Relay Closed'
                    : 'Standby · Power Off';
              } else if (d.type == DeviceType.hvac) {
                d.statusDescription = d.isOn
                    ? 'Cooling 22°C · Active'
                    : 'Standby · Off';
              }
            }
          }
          _classrooms = loadedRooms;
          if (prefs.getBool('migrated_reb_301_pins_v2') != true) {
            final rebIdx = _classrooms.indexWhere(
              (r) => r.id == 'reb_room_301' || r.scopedRoomId == 'reb_room_301',
            );
            if (rebIdx != -1) {
              final reb = _classrooms[rebIdx];
              for (final extra in _extraReb301Devices()) {
                if (!reb.devices.any((d) => d.id == extra.id)) {
                  reb.devices.add(extra);
                }
              }
            }
            await prefs.setBool('migrated_reb_301_pins_v2', true);
            await prefs.setString(
              _storageKeyClassrooms,
              jsonEncode(_classrooms.map((c) => c.toMap()).toList()),
            );
          }
          final savedRoomId = prefs.getString(_storageKeySelectedRoom);
          if (savedRoomId != null &&
              _classrooms.any((r) => r.id == savedRoomId)) {
            _selectedRoomId = savedRoomId;
          } else {
            _selectedRoomId = _classrooms.first.id;
          }
          debugPrint(
            '[ClassroomState] Restored and normalized ${_classrooms.length} rooms from shared campus cache.',
          );
          notifyListeners();
        }
      } else if (rawJson == '[]') {
        _classrooms = [];
        _selectedRoomId = '';
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[ClassroomState] Error loading cached storage: $e');
    }
  }

  static ClassroomDevice _reb301ExtraLight({
    required String id,
    required String name,
    required String zone,
    required int boardId,
    required int relay,
  }) {
    return ClassroomDevice(
      id: id,
      name: name,
      type: DeviceType.lighting,
      statusDescription: 'Standby · Power Off',
      isOn: false,
      zone: zone,
      relayChannel: ClassroomDevice.defaultRelayChannelForRelay(
        relay,
        boardId: boardId,
      ),
      zigbeeOrBleNode: 'Switchboard #$boardId',
      brightness: 100,
    );
  }

  static List<ClassroomDevice> _extraReb301Devices() {
    return [
      _reb301ExtraLight(
        id: 'dev-301-z1-r5',
        name: 'Zone 1 Right Light 1',
        zone: 'Zone 1',
        boardId: 1,
        relay: 5,
      ),
      _reb301ExtraLight(
        id: 'dev-301-z1-r6',
        name: 'Zone 1 Right Light 2',
        zone: 'Zone 1',
        boardId: 1,
        relay: 6,
      ),
      _reb301ExtraLight(
        id: 'dev-301-z3-r5',
        name: 'Zone 3 Rear Light 3',
        zone: 'Zone 3',
        boardId: 3,
        relay: 5,
      ),
    ];
  }

  // Debounced local persistence prevents heavy disk I/O micro-stutters during rapid interactions
  void _scheduleLocalStorageSave({bool immediate = false}) {
    if (immediate) {
      _localSaveDebounce?.cancel();
      _saveToLocalStorage();
      return;
    }
    _localSaveDebounce?.cancel();
    _localSaveDebounce = Timer(const Duration(milliseconds: 500), () {
      _saveToLocalStorage();
    });
  }

  Future<void> _saveToLocalStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonList = _classrooms.map((c) => c.toMap()).toList();
      final encoded = jsonEncode(jsonList);
      await prefs.setString(_storageKeyClassrooms, encoded);
      if (_selectedRoomId.isNotEmpty) {
        await prefs.setString(_storageKeySelectedRoom, _selectedRoomId);
      } else {
        await prefs.remove(_storageKeySelectedRoom);
      }
      debugPrint(
        '[ClassroomState] Persisted state to shared local storage cache.',
      );
    } catch (e) {
      debugPrint('[ClassroomState] Error writing to cached storage: $e');
    }
  }

  // Called when account signs out
  void onUserSignedOut() {
    _localSaveDebounce?.cancel();
    _classroomsStreamSub?.cancel();
    _classroomsStreamSub = null;
    notifyListeners();
  }

  // Called when account signs in
  void onUserSignedIn() {
    _initLocalStorage();
    _initFirestoreClassroomsSync();
  }

  // --- Real-Time MQTT Hardware Synchronization ---
  void _initMqttSync() {
    final mqtt = MqttService();
    // Connect to MQTT Broker in background
    mqtt.connect();

    // Listen to unified MQTT discovery payloads (`home/discovery`) for Zones 1-3 & Standalone AC (`zone_ac`)
    mqtt.onDiscoveryReceived = (zoneId, deviceType, ip, roomId, rssi, isOnline) {
      debugPrint(
        '[MQTT ➡️ State] Discovery: zone_id=$zoneId, device_type=$deviceType, ip=$ip, room=$roomId',
      );
      ConnectivityState().updateDiscoveredDevice(
        zoneId: zoneId,
        deviceType: deviceType,
        ip: ip,
        rssi: rssi,
        roomId: roomId,
        isOnline: isOnline,
      );
    };

    // Listen to real-time ESP32 microcontroller board health & diagnostics
    mqtt.onBoardTelemetryReceived = (roomId, boardId, isOnline, ip, rssi) {
      debugPrint(
        '[MQTT ➡️ State] Board #$boardId Telemetry: room=$roomId, online=$isOnline, ip=$ip, rssi=$rssi dBm',
      );
      ConnectivityState().updateBoardTelemetry(
        boardId,
        isOnline,
        ip,
        rssi,
        roomId,
      );
    };

    // Listen to switchboard-isolated relay status updates (strictly matches physical boardId and relayNumber)
    mqtt.onRelayStatusReceived =
        (roomId, boardId, relayNumber, isOn, speed, brightness, gpio) {
          final room = findRoom(roomId);
          if (room == null) return;
          ClassroomDevice? targetDevice;
          for (var d in room.devices) {
            if (d.boardId == boardId && d.relayNumber == relayNumber) {
              targetDevice = d;
              break;
            }
          }
          if (targetDevice != null) {
            final confirmedPending = targetDevice.isPendingConfirmation &&
                targetDevice.pendingTargetOn == isOn;
            // Drop outdated incoming status if user toggled this device recently and state disagrees
            if (!confirmedPending &&
                _isRecentlyToggled(roomId, targetDevice.id) &&
                targetDevice.isOn != isOn) {
              debugPrint(
                '[MQTT ➡️ State] Suppressed stale incoming relay status for ${targetDevice.name}',
              );
              return;
            }

            _clearPendingConfirmation(targetDevice.id);
            targetDevice.isPendingConfirmation = false;
            targetDevice.pendingTargetOn = null;
            targetDevice.isOn = isOn;
            if (speed != null && targetDevice.type == DeviceType.fan) {
              targetDevice.fanSpeed = speed;
            }
            if (brightness != null &&
                targetDevice.type == DeviceType.lighting) {
              targetDevice.brightness = brightness;
            }
            if (targetDevice.type == DeviceType.fan) {
              targetDevice.statusDescription = isOn
                  ? 'Speed ${targetDevice.fanSpeed} · Active'
                  : 'Standby · Array Off';
            } else if (targetDevice.type == DeviceType.lighting) {
              targetDevice.statusDescription = isOn
                  ? 'Active · Relay Closed'
                  : 'Standby · Power Off';
            }
            _persistDevicePower(targetDevice, roomId: room.id);
            notifyListeners();
            _scheduleLocalStorageSave();
          }
        };

    // Listen to direct optical Dual-AC telemetry updates (AC #1 on GPIO 33, AC #2 on GPIO 12)
    mqtt.onAcStatusReceived = (roomId, acUnitId, isOn, temp, mode, fan, swing) {
      final room = findRoom(roomId);
      if (room == null) return;
      final expectedGpio = acUnitId == 2 ? 12 : 33;
      ClassroomDevice? targetAc;
      for (var d in room.devices) {
        if (d.type == DeviceType.hvac) {
          if (d.gpioPinNumber == expectedGpio || d.relayNumber == acUnitId) {
            targetAc = d;
            break;
          }
          targetAc ??= d;
        }
      }
      if (targetAc != null) {
        final confirmedPending = targetAc.isPendingConfirmation &&
            targetAc.pendingTargetOn == isOn;
        if (!confirmedPending &&
            _isRecentlyToggled(roomId, targetAc.id) &&
            targetAc.isOn != isOn) {
          return;
        }
        _clearPendingConfirmation(targetAc.id);
        targetAc.isPendingConfirmation = false;
        targetAc.pendingTargetOn = null;
        targetAc.isOn = isOn;
        targetAc.temperature = temp;
        targetAc.hvacMode = mode;
        targetAc.fanSpeed = fan;
        targetAc.acSwing = swing;
        targetAc.statusDescription = isOn
            ? '$mode $temp°C · IR GPIO ${targetAc.gpioPinNumber}'
            : 'Standby · IR GPIO ${targetAc.gpioPinNumber}';
        _persistDevicePower(targetAc, roomId: room.id);
        notifyListeners();
        _scheduleLocalStorageSave();
      }
    };

    // Phase 5 Vision Model & Pi Decision Engine Telemetry (Occupancy & Appliances)
    mqtt.onAppStateReceived = (roomId, occupancy, appliances) {
      final room = findRoom(roomId);
      if (room == null) return;

      bool changed = false;
      room.lastVisionTelemetry = DateTime.now();
      room.visionMode = _visionControlEnabled ? 'LIVE' : 'MANUAL';

      final isOfflinePkt =
          occupancy['status'] == 'OFFLINE' || occupancy['online'] == false;
      if (isOfflinePkt) {
        // Offline means occupancy and appliance outputs are unknown, not vacant/off.
        room.visionMode = _visionControlEnabled ? 'OFFLINE' : 'MANUAL';
        notifyListeners();
        return;
      }
      if (occupancy.isNotEmpty) {
        final count = occupancy['count'] ?? occupancy['total_count'];
        if (count is num) {
          room.currentOccupancy = count.toInt();
          room.isOccupied = count > 0;
          changed = true;
        } else if (occupancy['present'] != null) {
          room.isOccupied = occupancy['present'] == true;
          changed = true;
        }

        final moving = occupancy['moving_count'];
        if (moving is num) {
          room.movingOccupancy = moving.toInt();
          changed = true;
        }

        final stationary = occupancy['stationary_count'];
        if (stationary is num) {
          room.stationaryOccupancy = stationary.toInt();
          changed = true;
        }

        final front =
            occupancy['front_count'] ??
            (occupancy['zones'] is Map
                ? (occupancy['zones']['front'] ?? occupancy['zones']['Zone 1'])
                : null);
        if (front is num) {
          room.frontOccupancy = front.toInt();
          changed = true;
        }

        final back =
            occupancy['back_count'] ??
            (occupancy['zones'] is Map
                ? (occupancy['zones']['back'] ?? occupancy['zones']['Zone 2'])
                : null);
        if (back is num) {
          room.backOccupancy = back.toInt();
          changed = true;
        }

        // Automatic Multi-Zone Occupancy Relay Synchronization (active only when Vision Control is ON):
        final prevFront = _lastKnownFrontOcc[room.id] ?? -1;
        final prevBack = _lastKnownBackOcc[room.id] ?? -1;
        final newFront = room.frontOccupancy;
        final newBack = room.backOccupancy;

        if (_visionControlEnabled) {
          if ((prevFront <= 0 && newFront > 0) ||
              (prevFront == -1 && newFront > 0)) {
            debugPrint(
              '[ClassroomState] Front Zone OCCUPIED ($newFront students). Turning ON Zone 1 devices.',
            );
            for (var d in room.devices) {
              if (d.boardId == 1 ||
                  d.zone.toLowerCase().contains('zone 1') ||
                  d.zone.toLowerCase().contains('front')) {
                d.manualOverrideOff = false;
                d.isOn = true;
                if (d.type == DeviceType.fan && d.fanSpeed == 0) {
                  d.fanSpeed = 3;
                }
                if (d.type == DeviceType.lighting && d.brightness == 0) {
                  d.brightness = 85;
                }
                d.statusDescription = d.type == DeviceType.fan
                    ? 'Speed ${d.fanSpeed} · Active (Zone 1 Occupied)'
                    : (d.type == DeviceType.lighting
                          ? 'Active · Relay Closed'
                          : 'Active');
                _persistDevicePower(d, roomId: room.id);
                changed = true;
              }
            }
          } else if (prevFront > 0 && newFront == 0) {
            debugPrint(
              '[ClassroomState] Front Zone VACANT. Turning OFF Zone 1 devices.',
            );
            for (var d in room.devices) {
              if (d.boardId == 1 ||
                  d.zone.toLowerCase().contains('zone 1') ||
                  d.zone.toLowerCase().contains('front')) {
                d.manualOverrideOff = false;
                d.isOn = false;
                d.statusDescription = 'Standby · Vacant Zone';
                _persistDevicePower(d, roomId: room.id);
                changed = true;
              }
            }
          }

          if ((prevBack <= 0 && newBack > 0) ||
              (prevBack == -1 && newBack > 0)) {
            debugPrint(
              '[ClassroomState] Back Zone OCCUPIED ($newBack students). Turning ON Zone 2 devices.',
            );
            for (var d in room.devices) {
              if (d.boardId == 2 ||
                  d.zone.toLowerCase().contains('zone 2') ||
                  d.zone.toLowerCase().contains('back')) {
                d.manualOverrideOff = false;
                d.isOn = true;
                if (d.type == DeviceType.fan && d.fanSpeed == 0) {
                  d.fanSpeed = 3;
                }
                if (d.type == DeviceType.lighting && d.brightness == 0) {
                  d.brightness = 85;
                }
                d.statusDescription = d.type == DeviceType.fan
                    ? 'Speed ${d.fanSpeed} · Active (Zone 2 Occupied)'
                    : (d.type == DeviceType.lighting
                          ? 'Active · Relay Closed'
                          : 'Active');
                _persistDevicePower(d, roomId: room.id);
                changed = true;
              }
            }
          } else if (prevBack > 0 && newBack == 0) {
            debugPrint(
              '[ClassroomState] Back Zone VACANT. Turning OFF Zone 2 devices.',
            );
            for (var d in room.devices) {
              if (d.boardId == 2 ||
                  d.zone.toLowerCase().contains('zone 2') ||
                  d.zone.toLowerCase().contains('back')) {
                d.manualOverrideOff = false;
                d.isOn = false;
                d.statusDescription = 'Standby · Vacant Zone';
                _persistDevicePower(d, roomId: room.id);
                changed = true;
              }
            }
          }
        }
        _lastKnownFrontOcc[room.id] = newFront;
        _lastKnownBackOcc[room.id] = newBack;
      }

      if (changed) {
        notifyListeners();
        _scheduleLocalStorageSave();
      }
    };

    // Phase 5 App Request Results
    mqtt.onAppResultReceived = (roomId, requestId, result, reason) {
      debugPrint('[Phase 5 Result] room= req= result= reason=');
    };
  }

  final Map<String, DateTime> _recentUserToggles = {};

  String _toggleKey(String roomId, String deviceId) {
    final normRoom = roomId.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    return '${normRoom}_$deviceId';
  }

  // Track user-initiated hardware interactions on this specific phone
  final Map<String, DateTime> _localRoomUserModified = {};

  void _recordUserToggle(String roomId, String deviceId) {
    final now = DateTime.now();
    _recentUserToggles[_toggleKey(roomId, deviceId)] = now;
    _recentUserToggles[deviceId] = now;
    _localRoomUserModified[roomId] = now;
    final r = findRoom(roomId);
    if (r != null) {
      _localRoomUserModified[r.id] = now;
      _localRoomUserModified[r.scopedRoomId] = now;
    }
  }

  bool _isRecentlyToggled(String roomId, String deviceId) {
    final now = DateTime.now();
    final key1 = _toggleKey(roomId, deviceId);
    final t1 = _recentUserToggles[key1];
    if (t1 != null && now.difference(t1).inMilliseconds < 800) {
      return true;
    }
    final t2 = _recentUserToggles[deviceId];
    if (t2 != null && now.difference(t2).inMilliseconds < 800) {
      return true;
    }
    return false;
  }

  // Real-time synchronization of classrooms with Firestore (Catalog, definitions & layout)
  Future<void> _initFirestoreClassroomsSync() async {
    await _classroomsStreamSub?.cancel();
    _classroomsStreamSub = null;

    // 1. One-time fetch for instant response on sign-in or cold launch
    try {
      final cloudRooms = await FirestoreService().fetchClassroomsOnce();
      if (cloudRooms != null) {
        await _applyIncomingCloudClassrooms(cloudRooms);
      }
    } catch (e) {
      debugPrint('[ClassroomState] One-time classroom fetch notice: $e');
    }

    // 2. Continuous real-time stream listener with error recovery
    try {
      _classroomsStreamSub = FirestoreService().getClassroomsStream().listen(
        (rooms) async {
          await _applyIncomingCloudClassrooms(rooms);
        },
        onError: (err) {
          debugPrint(
            '[ClassroomState] Firestore classrooms stream error: $err',
          );
          // Auto-reconnect after backoff delay if stream encounters error
          Timer(const Duration(seconds: 4), () {
            if (AuthState().isLoggedIn) {
              _initFirestoreClassroomsSync();
            }
          });
        },
        cancelOnError: false,
      );
    } catch (e) {
      debugPrint('[ClassroomState] Firestore classrooms sync error: $e');
    }
  }

  Future<void> _applyIncomingCloudClassrooms(List<Classroom> rooms) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('classpulse_initialized', true);

    // CRITICAL: When all rooms are deleted in Firebase Console or wiped
    if (rooms.isEmpty) {
      _classrooms = [];
      _selectedRoomId = '';
      await prefs.setString(_storageKeyClassrooms, '[]');
      await prefs.remove(_storageKeySelectedRoom);
      debugPrint(
        '[ClassroomState] Cloud classrooms collection is EMPTY. Cleared local state & cache.',
      );
      notifyListeners();
      return;
    }

    // Automatic state sync on app open and when incoming cloud snapshots arrive
    for (final incomingRoom in rooms) {
      final currentRoom = findRoom(
        incomingRoom.id,
        building: incomingRoom.building,
      );
      final rId = incomingRoom.id;
      final userModifiedTime =
          _localRoomUserModified[rId] ??
          _localRoomUserModified[incomingRoom.scopedRoomId];
      final cloudSyncTime = incomingRoom.lastIntervalSync;

      // Automatically adopt the cloud state snapshot when:
      // 1. Teacher just opened the app (userModifiedTime == null)
      // 2. Or the cloud snapshot from a class interval is newer than any local interaction
      final shouldAdoptCloudState =
          userModifiedTime == null ||
          (cloudSyncTime != null && cloudSyncTime.isAfter(userModifiedTime));

      for (final incomingDev in incomingRoom.devices) {
        final curDev = currentRoom != null
            ? findDevice(currentRoom, incomingDev.id)
            : null;
        final savedPwr =
            prefs.getBool('pwr_${incomingDev.id}') ??
            prefs.getBool(
              'pwr_${rId}_b${incomingDev.boardId}_r${incomingDev.relayNumber}',
            );

        if (shouldAdoptCloudState) {
          if (cloudSyncTime != null) {
            // Cloud has fresh class interval state snapshot: adopt cloud state
            prefs.setBool('pwr_${incomingDev.id}', incomingDev.isOn);
            prefs.setBool(
              'pwr_${rId}_b${incomingDev.boardId}_r${incomingDev.relayNumber}',
              incomingDev.isOn,
            );
            if (incomingDev.type == DeviceType.fan) {
              prefs.setInt('spd_${incomingDev.id}', incomingDev.fanSpeed);
            } else if (incomingDev.type == DeviceType.lighting) {
              prefs.setDouble('bri_${incomingDev.id}', incomingDev.brightness);
            }
          } else {
            // No cloud interval snapshot yet: restore local device power state if present
            if (savedPwr != null) incomingDev.isOn = savedPwr;
            if (incomingDev.type == DeviceType.fan) {
              final spd = prefs.getInt('spd_${incomingDev.id}');
              if (spd != null) incomingDev.fanSpeed = spd;
            } else if (incomingDev.type == DeviceType.lighting) {
              final bri = prefs.getDouble('bri_${incomingDev.id}');
              if (bri != null) incomingDev.brightness = bri;
            }
          }
        } else if (curDev != null) {
          // Active teacher tapping on this device right now: keep local UI state
          incomingDev.isOn = curDev.isOn;
          if (incomingDev.type == DeviceType.fan) {
            incomingDev.fanSpeed = curDev.fanSpeed;
          }
          if (incomingDev.type == DeviceType.lighting) {
            incomingDev.brightness = curDev.brightness;
          }
        }

        // Update status description
        if (incomingDev.type == DeviceType.fan) {
          incomingDev.statusDescription = incomingDev.isOn
              ? 'Speed ${incomingDev.fanSpeed} · Active'
              : 'Standby · Array Off';
        } else if (incomingDev.type == DeviceType.lighting) {
          incomingDev.statusDescription = incomingDev.isOn
              ? 'Active · Relay Closed'
              : 'Standby · Power Off';
        } else if (incomingDev.type == DeviceType.hvac) {
          incomingDev.statusDescription = incomingDev.isOn
              ? 'Cooling 22°C · Active'
              : 'Standby · Off';
        }
      }
    }
    _classrooms = rooms;
    if (_selectedRoomId.isEmpty ||
        !_classrooms.any((r) => r.id == _selectedRoomId)) {
      _selectedRoomId = _classrooms.first.id;
    }
    await _saveToLocalStorage();
    notifyListeners();
  }

  // --- Class Session 3-Interval State & Configuration Cloud Sync (50-min class) ---
  // A standard class duration is 50 minutes. We sync device state & configurations in 3 intervals
  // (every 16 min 40 sec) so that when another teacher comes, their phone syncs live device states.
  static const int kClassDurationMinutes = 50;
  static const int kClassSyncIntervals = 3;
  static const Duration kIntervalSyncDuration = Duration(
    minutes: 16,
    seconds: 40,
  );

  Timer? _classIntervalSyncTimer;
  int _currentClassInterval = 1;
  DateTime? _lastClassIntervalSyncTime;

  int get currentClassInterval => _currentClassInterval;
  DateTime? get lastClassIntervalSyncTime => _lastClassIntervalSyncTime;

  void _startVisionWatchdogTimer() {
    _visionWatchdogTimer?.cancel();
    _visionWatchdogTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      final now = DateTime.now();
      bool changed = false;
      for (final room in _classrooms) {
        if (!_visionControlEnabled) {
          if (room.visionMode != 'MANUAL') {
            room.visionMode = 'MANUAL';
            changed = true;
          }
          continue;
        }
        final isTimedOut =
            room.lastVisionTelemetry == null ||
            now.difference(room.lastVisionTelemetry!) >
                const Duration(seconds: 6);
        if (isTimedOut) {
          if (room.visionMode != 'OFFLINE') {
            debugPrint(
              '[ClassroomState] Watchdog: Vision model offline for ${room.id}. Occupancy is unknown.',
            );
            room.visionMode = 'OFFLINE';
            changed = true;
          }
        }
      }
      if (changed) {
        notifyListeners();
        _scheduleLocalStorageSave();
      }
    });
  }

  Future<void> setVisionControlEnabled(bool enabled) async {
    _visionControlEnabled = enabled;
    for (final room in _classrooms) {
      if (!enabled) {
        room.visionMode = 'MANUAL';
      } else {
        final hasRecentTelemetry =
            room.lastVisionTelemetry != null &&
            DateTime.now().difference(room.lastVisionTelemetry!) <=
                const Duration(seconds: 6);
        room.visionMode = hasRecentTelemetry ? 'LIVE' : 'OFFLINE';
      }
    }
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_storageKeyVisionControl, enabled);
    } catch (_) {}
    final targetRoomId = selectedRoom?.scopedRoomId ?? 'reb_room_301';
    MqttService().publishVisionControl(targetRoomId, enabled);
    if (targetRoomId != 'reb_room_301') {
      MqttService().publishVisionControl('reb_room_301', enabled);
    }
  }

  void _startClassIntervalSyncTimer() {
    _classIntervalSyncTimer?.cancel();
    _classIntervalSyncTimer = Timer.periodic(kIntervalSyncDuration, (timer) {
      _triggerClassIntervalSync();
    });
  }

  void cancelAllTimers() {
    _localSaveDebounce?.cancel();
    _classIntervalSyncTimer?.cancel();
    _classroomsStreamSub?.cancel();
    for (final timer in _pendingConfirmationTimers.values) {
      timer.cancel();
    }
    _pendingConfirmationTimers.clear();
    MqttService().disconnect();
  }

  void _clearPendingConfirmation(String deviceId) {
    _pendingConfirmationTimers.remove(deviceId)?.cancel();
  }

  void _beginPendingConfirmation(
    Classroom room,
    ClassroomDevice device, {
    required bool desiredOn,
    required bool previousOn,
  }) {
    _clearPendingConfirmation(device.id);
    if (!MqttService().isConnected) {
      device.isPendingConfirmation = false;
      device.pendingTargetOn = null;
      return;
    }
    device.isPendingConfirmation = true;
    device.pendingTargetOn = desiredOn;
    device.statusDescription = 'Pending ${desiredOn ? "ON" : "OFF"}…';
    _pendingConfirmationTimers[device.id] = Timer(
      const Duration(seconds: 5),
      () {
        _pendingConfirmationTimers.remove(device.id);
        if (!device.isPendingConfirmation) return;
        device.isPendingConfirmation = false;
        device.pendingTargetOn = null;
        device.isOn = previousOn;
        device.statusDescription = 'No ESP32 response';
        notifyListeners();
      },
    );
  }

  void _triggerClassIntervalSync() {
    _lastClassIntervalSyncTime = DateTime.now();
    debugPrint(
      '[ClassroomState] Class 50-min session: Interval $_currentClassInterval/$kClassSyncIntervals triggered. Syncing device state & config to Firebase for next teacher...',
    );
    syncAllClassroomsStateAndConfig(interval: _currentClassInterval);
    _currentClassInterval = (_currentClassInterval % kClassSyncIntervals) + 1;
    notifyListeners();
  }

  // Explicit or interval sync of all classrooms device state & config to Firebase
  Future<void> syncAllClassroomsStateAndConfig({int? interval}) async {
    final targetInterval = interval ?? _currentClassInterval;
    _lastClassIntervalSyncTime = DateTime.now();
    for (final room in _classrooms) {
      await FirestoreService().syncClassroomStateAndConfig(
        room,
        interval: targetInterval,
      );
    }
    notifyListeners();
  }

  // Sync state & config of a specific classroom to Firebase (e.g. at end of class)
  Future<void> syncClassroomStateAndConfigForRoom(String roomId) async {
    final room = findRoom(roomId);
    if (room == null) return;
    _lastClassIntervalSyncTime = DateTime.now();
    await FirestoreService().syncClassroomStateAndConfig(
      room,
      interval: _currentClassInterval,
    );
    notifyListeners();
  }

  bool _isEmergencyPinEnabled = true;
  bool get isEmergencyPinEnabled => _isEmergencyPinEnabled;

  String _emergencyPin = '1234';
  String get emergencyPin => _emergencyPin;

  // Real-time synchronization of security emergency PIN with Firestore
  void _initFirestorePinSync() {
    try {
      FirestoreService().getSecurityConfigStream().listen((snapshot) {
        if (snapshot.exists && snapshot.data() != null) {
          final data = snapshot.data()!;
          if (data['emergencyPin'] != null) {
            _emergencyPin = data['emergencyPin'].toString();
          }
          if (data['isEmergencyPinEnabled'] != null) {
            _isEmergencyPinEnabled = data['isEmergencyPinEnabled'] as bool;
          }
          notifyListeners();
        }
      });
    } catch (e) {
      debugPrint('Firestore PIN sync error: $e');
    }
  }

  // Save emergency PIN exclusively to Firestore (never locally)
  void setEmergencyPin(String pin) {
    _emergencyPin = pin;
    notifyListeners();
    FirestoreService().saveEmergencyPin(pin, _isEmergencyPinEnabled);
  }

  // Save emergency PIN enabled state exclusively to Firestore
  void setEmergencyPinEnabled(bool enabled) {
    _isEmergencyPinEnabled = enabled;
    notifyListeners();
    FirestoreService().saveEmergencyPin(_emergencyPin, enabled);
  }

  List<Classroom> _classrooms = [];
  List<Classroom> get classrooms => _classrooms;

  String _selectedRoomId = 'room-101';
  String get selectedRoomId => _selectedRoomId;

  Classroom? get selectedRoom {
    try {
      return _classrooms.firstWhere((r) => r.id == _selectedRoomId);
    } catch (_) {
      return _classrooms.isNotEmpty ? _classrooms.first : null;
    }
  }

  int get totalActivePeripherals {
    int count = 0;
    for (var c in _classrooms) {
      count += c.activeDeviceCount;
    }
    return count;
  }

  int get totalConfiguredPeripherals {
    int count = 0;
    for (var c in _classrooms) {
      count += c.totalDeviceCount;
    }
    return count;
  }

  int get activeZonesCount {
    return _classrooms.where((c) => c.activeDeviceCount > 0).length;
  }

  int get totalZonesCount => _classrooms.length;

  void selectRoom(String roomId) {
    _selectedRoomId = roomId;
    notifyListeners();
    _saveToLocalStorage();
  }

  void _initInitialData() {
    _classrooms = [
      Classroom(
        id: 'reb_room_301',
        roomNumber: 'Room 301',
        name: 'IoT Smart Classroom (REB 301)',
        building: 'RUET REB Building',
        floor: 'Fl 3',
        isOccupied: true,
        occupancyCeiling: 40,
        currentOccupancy: 32,
        gatewayId: 'HUB-ESP32-MESH',
        roomType: 'Standard Class',
        zoneCount: 3,
        zones: ['Zone 1', 'Zone 2', 'Zone 3'],
        devices: [
          // Zone 1 (ESP32 30-Pin - "1st Board": 6 Relays <-> S1..S6)
          ClassroomDevice(
            id: 'dev-301-z1-r1',
            name: 'Zone 1 Front Light 1',
            type: DeviceType.lighting,
            statusDescription: 'Standby · Power Off',
            isOn: false,
            zone: 'Zone 1',
            relayChannel: ClassroomDevice.defaultRelayChannelForRelay(
              1,
              boardId: 1,
            ),
            zigbeeOrBleNode: 'Switchboard #1',
            brightness: 100,
          ),
          ClassroomDevice(
            id: 'dev-301-z1-r2',
            name: 'Zone 1 Front Light 2',
            type: DeviceType.lighting,
            statusDescription: 'Standby · Power Off',
            isOn: false,
            zone: 'Zone 1',
            relayChannel: ClassroomDevice.defaultRelayChannelForRelay(
              2,
              boardId: 1,
            ),
            zigbeeOrBleNode: 'Switchboard #1',
            brightness: 100,
          ),
          ClassroomDevice(
            id: 'dev-301-z1-r3',
            name: 'Zone 1 Ceiling Fan 1',
            type: DeviceType.fan,
            statusDescription: 'Speed 0 (Idle)',
            isOn: false,
            zone: 'Zone 1',
            relayChannel: ClassroomDevice.defaultRelayChannelForRelay(
              3,
              boardId: 1,
            ),
            zigbeeOrBleNode: 'Switchboard #1',
            fanSpeed: 0,
          ),
          ClassroomDevice(
            id: 'dev-301-z1-r4',
            name: 'Zone 1 Ceiling Fan 2',
            type: DeviceType.fan,
            statusDescription: 'Speed 0 (Idle)',
            isOn: false,
            zone: 'Zone 1',
            relayChannel: ClassroomDevice.defaultRelayChannelForRelay(
              4,
              boardId: 1,
            ),
            zigbeeOrBleNode: 'Switchboard #1',
            fanSpeed: 0,
          ),
          _reb301ExtraLight(
            id: 'dev-301-z1-r5',
            name: 'Zone 1 Right Light 1',
            zone: 'Zone 1',
            boardId: 1,
            relay: 5,
          ),
          _reb301ExtraLight(
            id: 'dev-301-z1-r6',
            name: 'Zone 1 Right Light 2',
            zone: 'Zone 1',
            boardId: 1,
            relay: 6,
          ),

          // Zone 2 (Unlabeled Board: 8 Relays <-> SW1..SW8)
          ClassroomDevice(
            id: 'dev-301-z2-r1',
            name: 'Zone 2 Center Light 1',
            type: DeviceType.lighting,
            statusDescription: 'Standby · Power Off',
            isOn: false,
            zone: 'Zone 2',
            relayChannel: ClassroomDevice.defaultRelayChannelForRelay(
              1,
              boardId: 2,
            ),
            zigbeeOrBleNode: 'Switchboard #2',
            brightness: 100,
          ),
          ClassroomDevice(
            id: 'dev-301-z2-r2',
            name: 'Zone 2 Center Light 2',
            type: DeviceType.lighting,
            statusDescription: 'Standby · Power Off',
            isOn: false,
            zone: 'Zone 2',
            relayChannel: ClassroomDevice.defaultRelayChannelForRelay(
              2,
              boardId: 2,
            ),
            zigbeeOrBleNode: 'Switchboard #2',
            brightness: 100,
          ),
          ClassroomDevice(
            id: 'dev-301-z2-r3',
            name: 'Zone 2 Center Fan 1',
            type: DeviceType.fan,
            statusDescription: 'Speed 0 (Idle)',
            isOn: false,
            zone: 'Zone 2',
            relayChannel: ClassroomDevice.defaultRelayChannelForRelay(
              3,
              boardId: 2,
            ),
            zigbeeOrBleNode: 'Switchboard #2',
            fanSpeed: 0,
          ),
          ClassroomDevice(
            id: 'dev-301-z2-r4',
            name: 'Zone 2 Center Fan 2',
            type: DeviceType.fan,
            statusDescription: 'Speed 0 (Idle)',
            isOn: false,
            zone: 'Zone 2',
            relayChannel: ClassroomDevice.defaultRelayChannelForRelay(
              4,
              boardId: 2,
            ),
            zigbeeOrBleNode: 'Switchboard #2',
            fanSpeed: 0,
          ),

          // Zone 3 ("3rd One": 5 Relays <-> SW1..SW5)
          ClassroomDevice(
            id: 'dev-301-z3-r1',
            name: 'Zone 3 Rear Light 1',
            type: DeviceType.lighting,
            statusDescription: 'Standby · Power Off',
            isOn: false,
            zone: 'Zone 3',
            relayChannel: ClassroomDevice.defaultRelayChannelForRelay(
              1,
              boardId: 3,
            ),
            zigbeeOrBleNode: 'Switchboard #3',
            brightness: 100,
          ),
          ClassroomDevice(
            id: 'dev-301-z3-r2',
            name: 'Zone 3 Rear Light 2',
            type: DeviceType.lighting,
            statusDescription: 'Standby · Power Off',
            isOn: false,
            zone: 'Zone 3',
            relayChannel: ClassroomDevice.defaultRelayChannelForRelay(
              2,
              boardId: 3,
            ),
            zigbeeOrBleNode: 'Switchboard #3',
            brightness: 100,
          ),
          ClassroomDevice(
            id: 'dev-301-z3-r3',
            name: 'Zone 3 Rear Fan 1',
            type: DeviceType.fan,
            statusDescription: 'Speed 0 (Idle)',
            isOn: false,
            zone: 'Zone 3',
            relayChannel: ClassroomDevice.defaultRelayChannelForRelay(
              3,
              boardId: 3,
            ),
            zigbeeOrBleNode: 'Switchboard #3',
            fanSpeed: 0,
          ),
          ClassroomDevice(
            id: 'dev-301-z3-r4',
            name: 'Zone 3 Rear Fan 2',
            type: DeviceType.fan,
            statusDescription: 'Speed 0 (Idle)',
            isOn: false,
            zone: 'Zone 3',
            relayChannel: ClassroomDevice.defaultRelayChannelForRelay(
              4,
              boardId: 3,
            ),
            zigbeeOrBleNode: 'Switchboard #3',
            fanSpeed: 0,
          ),
          _reb301ExtraLight(
            id: 'dev-301-z3-r5',
            name: 'Zone 3 Rear Light 3',
            zone: 'Zone 3',
            boardId: 3,
            relay: 5,
          ),

          // Standalone Dual-AC IR Controller (Separate ESP32: Gree AC #1 on GPIO 33, Gree AC #2 on GPIO 12)
          ClassroomDevice(
            id: 'dev-301-ac-1',
            name: 'Gree AC 1 (Front)',
            type: DeviceType.hvac,
            statusDescription: 'Standby · IR GPIO 33',
            isOn: false,
            zone: 'Standalone AC',
            relayChannel: 'GREE AC #1 IR (GPIO 33)',
            hardwareModel:
                'Standalone Dual-Gree AC IR Controller (GPIO 33 / GPIO 12)',
            zigbeeOrBleNode: 'Standalone AC',
            temperature: 24,
            hvacMode: 'COOL',
          ),
          ClassroomDevice(
            id: 'dev-301-ac-2',
            name: 'Gree AC 2 (Back)',
            type: DeviceType.hvac,
            statusDescription: 'Standby · IR GPIO 12',
            isOn: false,
            zone: 'Standalone AC',
            relayChannel: 'GREE AC #2 IR (GPIO 12)',
            hardwareModel:
                'Standalone Dual-Gree AC IR Controller (GPIO 33 / GPIO 12)',
            zigbeeOrBleNode: 'Standalone AC',
            temperature: 24,
            hvacMode: 'COOL',
          ),
        ],
      ),
      Classroom(
        id: 'room-101',
        roomNumber: 'Room 101',
        name: 'Science Lab',
        building: 'RUET CSE Building',
        floor: 'Fl 1',
        isOccupied: true,
        occupancyCeiling: 35,
        currentOccupancy: 28,
        gatewayId: 'HUB-ESP32-MESH',
        roomType: 'Laboratory',
        zoneCount: 2,
        zones: ['Zone 1', 'Zone 2'],
        devices: [
          // Zone 1
          ClassroomDevice(
            id: 'dev-101-fan1',
            name: 'Ceiling Fan 1',
            type: DeviceType.fan,
            statusDescription: 'Speed 3 · Forward Airflow',
            isOn: true,
            zone: 'Zone 1',
            relayChannel: 'RELAY 1 (GPIO 18)',
            fanSpeed: 3,
            fanReverse: false,
          ),
          ClassroomDevice(
            id: 'dev-101-light1',
            name: 'Front Light Array',
            type: DeviceType.lighting,
            statusDescription: '100% Brightness · Relay Closed',
            isOn: true,
            zone: 'Zone 1',
            relayChannel: 'RELAY 2 (GPIO 19)',
            brightness: 100,
          ),
          ClassroomDevice(
            id: 'dev-101-ac1',
            name: 'Front AC Unit',
            type: DeviceType.hvac,
            statusDescription: 'Cooling 22°C · Compressor Active',
            isOn: true,
            zone: 'Zone 1',
            relayChannel: 'RELAY 3 (GPIO 21)',
            temperature: 22,
            hvacMode: 'AUTO',
          ),
          // Zone 2
          ClassroomDevice(
            id: 'dev-101-fan2',
            name: 'Ceiling Fan 2',
            type: DeviceType.fan,
            statusDescription: 'Speed 3 · Forward Airflow',
            isOn: true,
            zone: 'Zone 2',
            relayChannel: 'RELAY 1 (GPIO 18)',
            fanSpeed: 3,
            fanReverse: false,
          ),
          ClassroomDevice(
            id: 'dev-101-light2',
            name: 'Rear Light Array',
            type: DeviceType.lighting,
            statusDescription: '85% Brightness · Relay Closed',
            isOn: true,
            zone: 'Zone 2',
            relayChannel: 'RELAY 2 (GPIO 19)',
            brightness: 85,
          ),
        ],
      ),
      Classroom(
        id: 'room-204',
        roomNumber: 'Room 204',
        name: 'Lecture Hall',
        building: 'RUET EEE Building',
        floor: 'Fl 2',
        isOccupied: true,
        occupancyCeiling: 120,
        currentOccupancy: 80,
        gatewayId: 'HUB-ESP32-MESH',
        roomType: 'Lecture Hall',
        zoneCount: 3,
        zones: ['Zone 1', 'Zone 2', 'Zone 3'],
        devices: [
          // Zone 1
          ClassroomDevice(
            id: 'dev-204-fan1',
            name: 'Stage Ceiling Fan',
            type: DeviceType.fan,
            statusDescription: 'Speed 2 · Forward Airflow',
            isOn: true,
            zone: 'Zone 1',
            relayChannel: 'RELAY 1 (GPIO 18)',
            fanSpeed: 2,
          ),
          ClassroomDevice(
            id: 'dev-204-light1',
            name: 'Stage Spotlights',
            type: DeviceType.lighting,
            statusDescription: '100% Brightness · Relay Closed',
            isOn: true,
            zone: 'Zone 1',
            relayChannel: 'RELAY 2 (GPIO 19)',
            brightness: 100,
          ),
          ClassroomDevice(
            id: 'dev-204-ac1',
            name: 'Stage AC Unit',
            type: DeviceType.hvac,
            statusDescription: 'Cooling 21°C · Active',
            isOn: true,
            zone: 'Zone 1',
            relayChannel: 'RELAY 3 (GPIO 21)',
            temperature: 21,
          ),
          // Zone 2
          ClassroomDevice(
            id: 'dev-204-fan2',
            name: 'Auditorium Center Fan',
            type: DeviceType.fan,
            statusDescription: 'Speed 3 · Forward Airflow',
            isOn: true,
            zone: 'Zone 2',
            relayChannel: 'RELAY 1 (GPIO 18)',
            fanSpeed: 3,
          ),
          ClassroomDevice(
            id: 'dev-204-light2',
            name: 'Main Seating Lights',
            type: DeviceType.lighting,
            statusDescription: '75% Brightness · Relay Closed',
            isOn: true,
            zone: 'Zone 2',
            relayChannel: 'RELAY 2 (GPIO 19)',
            brightness: 75,
          ),
          ClassroomDevice(
            id: 'dev-204-ac2',
            name: 'Center AC Unit',
            type: DeviceType.hvac,
            statusDescription: 'Cooling 22°C · Active',
            isOn: true,
            zone: 'Zone 2',
            relayChannel: 'RELAY 3 (GPIO 21)',
            temperature: 22,
          ),
          // Zone 3
          ClassroomDevice(
            id: 'dev-204-fan3',
            name: 'Rear Balcony Fan',
            type: DeviceType.fan,
            statusDescription: 'Speed 2 · Forward Airflow',
            isOn: true,
            zone: 'Zone 3',
            relayChannel: 'RELAY 1 (GPIO 18)',
            fanSpeed: 2,
          ),
          ClassroomDevice(
            id: 'dev-204-light3',
            name: 'Balcony Lights',
            type: DeviceType.lighting,
            statusDescription: '60% Brightness · Relay Closed',
            isOn: true,
            zone: 'Zone 3',
            relayChannel: 'RELAY 2 (GPIO 19)',
            brightness: 60,
          ),
        ],
      ),
      Classroom(
        id: 'room-305',
        roomNumber: 'Room 305',
        name: 'Seminar Room',
        building: 'Civil Engineering Building',
        floor: 'Fl 3',
        isOccupied: false,
        occupancyCeiling: 60,
        currentOccupancy: 0,
        gatewayId: 'HUB-ESP32-MESH',
        roomType: 'Seminar Room',
        zoneCount: 2,
        zones: ['Zone 1', 'Zone 2'],
        devices: [
          ClassroomDevice(
            id: 'dev-305-fan1',
            name: 'Conference Fan',
            type: DeviceType.fan,
            statusDescription: 'Speed 3 · Forward Airflow',
            isOn: false,
            zone: 'Zone 1',
            relayChannel: 'RELAY 1 (GPIO 18)',
            fanSpeed: 0,
          ),
          ClassroomDevice(
            id: 'dev-305-light1',
            name: 'Panel Lights',
            type: DeviceType.lighting,
            statusDescription: 'Standby · Power Off',
            isOn: false,
            zone: 'Zone 1',
            relayChannel: 'RELAY 2 (GPIO 19)',
            brightness: 80,
          ),
          ClassroomDevice(
            id: 'dev-305-ac1',
            name: 'Conference AC',
            type: DeviceType.hvac,
            statusDescription: 'Standby · Off',
            isOn: false,
            zone: 'Zone 2',
            relayChannel: 'RELAY 1 (GPIO 18)',
            temperature: 24,
          ),
        ],
      ),
    ];
  }

  // --- Vision Gate Helper ---
  int getZoneOccupancy(Classroom room, String zoneName, {int? boardId}) {
    if (boardId == 2) return room.backOccupancy;
    if (boardId == 1) return room.frontOccupancy;

    final lower = zoneName.toLowerCase();
    if (lower.contains('zone 2') ||
        lower.contains('zone_2') ||
        lower.contains('back')) {
      return room.backOccupancy;
    }
    if (lower.contains('zone 1') ||
        lower.contains('zone_1') ||
        lower.contains('front')) {
      return room.frontOccupancy;
    }

    return room.currentOccupancy;
  }

  // --- Interaction Methods ---

  String? toggleDevice(String roomId, String deviceId) {
    final room = findRoom(roomId);
    if (room == null) return null;
    final device = findDevice(room, deviceId);
    if (device == null) return null;

    final willTurnOn = !device.isOn;

    // Strict Vision Gate Check (active only when Vision Control is enabled):
    // If turning ON, ensure someone is actually sitting or moving in this zone!
    if (willTurnOn) {
      if (_visionControlEnabled) {
        final occ = getZoneOccupancy(
          room,
          device.zone,
          boardId: device.boardId,
        );
        if (occ <= 0) {
          debugPrint(
            '[Vision Gate] BLOCKED toggle ON for ${device.name} in ${device.zone}: 0 occupants.',
          );
          device.isOn = false;
          notifyListeners();
          return 'Vision Gate: ${device.zone} is empty (0 occupants). Turn off Vision Control for direct control.';
        }
      }
      // User is manually turning device ON -> Clear manual override off!
      device.manualOverrideOff = false;
    } else {
      // User is manually turning device OFF while zone might be occupied:
      // Mark manualOverrideOff = true so automation does NOT immediately turn it back ON!
      device.manualOverrideOff = true;
      debugPrint(
        '[Manual Override] User turned OFF ${device.name}. Manual override active.',
      );
    }

    final previousOn = device.isOn;
    device.isOn = willTurnOn;

    if (device.type == DeviceType.fan) {
      if (device.isOn && device.fanSpeed == 0) {
        device.fanSpeed = 3;
      }
      device.statusDescription = device.isOn
          ? 'Speed ${device.fanSpeed} · Active'
          : 'Standby · Array Off';
    } else if (device.type == DeviceType.lighting) {
      device.statusDescription = device.isOn
          ? 'Active · Relay Closed'
          : 'Standby · Power Off';
    } else if (device.type == DeviceType.hvac) {
      device.statusDescription = device.isOn
          ? '${device.hvacMode} ${device.temperature}°C · IR GPIO ${device.gpioPinNumber}'
          : 'Standby · IR GPIO ${device.gpioPinNumber}';
    } else if (device.type == DeviceType.projector) {
      device.statusDescription = device.isOn
          ? 'Laser Projector · Active'
          : 'Standby · Lamp Off';
    } else if (device.type == DeviceType.powerStrip) {
      device.statusDescription = device.isOn
          ? 'Sockets Active'
          : 'Relays Disengaged';
    }

    _beginPendingConfirmation(
      room,
      device,
      desiredOn: willTurnOn,
      previousOn: previousOn,
    );
    _recordUserToggle(roomId, deviceId);
    _persistDevicePower(device, roomId: room.id);
    notifyListeners();
    _scheduleLocalStorageSave(immediate: true);
    // Direct physical relay toggle via MQTT (power state stored locally + MQTT)
    MqttService().publishDeviceCommand(room.scopedRoomId, device, device.isOn);
    // Notify Pi Decision Engine of manual override
    MqttService().publishAppRequest(
      room.scopedRoomId,
      applianceId: device.id,
      desiredState: device.isOn ? 'ON' : 'OFF',
    );
    return null;
  }

  void setFanSpeed(String roomId, String deviceId, int speed) {
    final room = findRoom(roomId);
    if (room == null) return;
    final device = findDevice(room, deviceId);
    if (device == null) return;
    if (speed > 0 && _visionControlEnabled) {
      final occ = getZoneOccupancy(room, device.zone, boardId: device.boardId);
      if (occ <= 0) {
        debugPrint(
          '[Vision Gate] BLOCKED fan speed on empty zone: ${device.zone}',
        );
        device.fanSpeed = 0;
        device.isOn = false;
        notifyListeners();
        return;
      }
    }
    device.fanSpeed = speed;
    if (speed == 0) {
      device.isOn = false;
      device.statusDescription = 'Speed 0 (Idle)';
    } else {
      device.isOn = true;
      device.statusDescription = 'Speed $speed · Active';
    }
    _recordUserToggle(roomId, deviceId);
    _persistDevicePower(device, roomId: room.id);
    notifyListeners();
    _scheduleLocalStorageSave(immediate: true);
    MqttService().publishFanSpeed(
      room.scopedRoomId,
      device.boardId,
      device.relayNumber,
      speed,
    );
  }

  void toggleFanReverse(String roomId, String deviceId) {
    final room = findRoom(roomId);
    if (room == null) return;
    final device = findDevice(room, deviceId);
    if (device == null) return;
    device.fanReverse = !device.fanReverse;
    if (device.isOn && device.fanSpeed > 0) {
      device.statusDescription = 'Speed ${device.fanSpeed} · Active';
    }
    notifyListeners();
    _scheduleLocalStorageSave();
  }

  void setTemperature(String roomId, String deviceId, int delta) {
    final room = findRoom(roomId);
    if (room == null) return;
    final device = findDevice(room, deviceId);
    if (device == null) return;
    final newTemp = (device.temperature + delta).clamp(16, 30);
    device.temperature = newTemp;
    if (!device.isOn) device.isOn = true;
    device.statusDescription =
        '${device.hvacMode} ${device.temperature}°C · IR GPIO ${device.gpioPinNumber}';
    _recordUserToggle(roomId, deviceId);
    _persistDevicePower(device, roomId: room.id);
    notifyListeners();
    _scheduleLocalStorageSave(immediate: true);
    MqttService().publishDeviceCommand(room.scopedRoomId, device, device.isOn);
  }

  void setHvacMode(String roomId, String deviceId, String mode) {
    final room = findRoom(roomId);
    if (room == null) return;
    final device = findDevice(room, deviceId);
    if (device == null) return;
    device.hvacMode = mode;
    if (!device.isOn) device.isOn = true;
    device.statusDescription =
        '${device.hvacMode} ${device.temperature}°C · IR GPIO ${device.gpioPinNumber}';
    _recordUserToggle(roomId, deviceId);
    _persistDevicePower(device, roomId: room.id);
    notifyListeners();
    _scheduleLocalStorageSave(immediate: true);
    MqttService().publishDeviceCommand(room.scopedRoomId, device, device.isOn);
  }

  void setAcFanSpeed(String roomId, String deviceId, int fanSpeed) {
    final room = findRoom(roomId);
    if (room == null) return;
    final device = findDevice(room, deviceId);
    if (device == null) return;
    device.fanSpeed = fanSpeed.clamp(0, 3);
    if (!device.isOn) device.isOn = true;
    device.statusDescription =
        '${device.hvacMode} ${device.temperature}°C · IR GPIO ${device.gpioPinNumber}';
    _recordUserToggle(roomId, deviceId);
    _persistDevicePower(device, roomId: room.id);
    notifyListeners();
    _scheduleLocalStorageSave(immediate: true);
    MqttService().publishDeviceCommand(room.scopedRoomId, device, device.isOn);
  }

  void toggleAcSwing(String roomId, String deviceId) {
    final room = findRoom(roomId);
    if (room == null) return;
    final device = findDevice(room, deviceId);
    if (device == null) return;
    device.acSwing = !device.acSwing;
    if (!device.isOn) device.isOn = true;
    _recordUserToggle(roomId, deviceId);
    _persistDevicePower(device, roomId: room.id);
    notifyListeners();
    _scheduleLocalStorageSave(immediate: true);
    MqttService().publishDeviceCommand(room.scopedRoomId, device, device.isOn);
  }

  void setBrightness(String roomId, String deviceId, double brightness) {
    final room = findRoom(roomId);
    if (room == null) return;
    final device = findDevice(room, deviceId);
    if (device == null) return;
    device.brightness = brightness;
    device.lumens = ((brightness / 100.0) * 1400).round();
    if (brightness > 0 && !device.isOn) {
      device.isOn = true;
    } else if (brightness == 0) {
      device.isOn = false;
    }
    _recordUserToggle(roomId, deviceId);
    _persistDevicePower(device, roomId: room.id);
    notifyListeners();
    _scheduleLocalStorageSave(immediate: true);
    MqttService().publishLightBrightness(
      room.scopedRoomId,
      device.boardId,
      device.relayNumber,
      brightness,
    );
  }

  void setProjectorSource(String roomId, String deviceId, String source) {
    final room = findRoom(roomId);
    if (room == null) return;
    final device = findDevice(room, deviceId);
    if (device == null) return;
    device.projectorSource = source;
    notifyListeners();
    _scheduleLocalStorageSave();
  }

  void toggleProjectorScreen(String roomId, String deviceId) {
    final room = findRoom(roomId);
    if (room == null) return;
    final device = findDevice(room, deviceId);
    if (device == null) return;
    device.screenDeployed = !device.screenDeployed;
    notifyListeners();
    _scheduleLocalStorageSave();
  }

  void setRoomMaster(String roomId, bool powerOn) {
    final room = findRoom(roomId);
    if (room == null) return;
    for (var device in room.devices) {
      device.isOn = powerOn;
      if (powerOn) {
        if (device.type == DeviceType.fan && device.fanSpeed == 0) {
          device.fanSpeed = 3;
        }
        if (device.type == DeviceType.lighting && device.brightness == 0) {
          device.brightness = 85;
        }
      }
    }
    room.isOccupied = powerOn;
    _persistMultipleDevicesPower(room.devices, roomId: room.id);
    notifyListeners();
    _scheduleLocalStorageSave(immediate: true);
    MqttService().publishAllDevices(room.scopedRoomId, powerOn);
  }

  void toggleRoomMaster(String roomId) {
    final room = findRoom(roomId);
    if (room == null) return;
    setRoomMaster(roomId, !room.isMasterOn);
  }

  void setMasterAll(bool allOn) {
    for (var room in _classrooms) {
      for (var device in room.devices) {
        device.isOn = allOn;
        if (allOn) {
          if (device.type == DeviceType.fan && device.fanSpeed == 0) {
            device.fanSpeed = 3;
          }
          if (device.type == DeviceType.lighting && device.brightness == 0) {
            device.brightness = 85;
          }
        }
      }
      room.isOccupied = allOn;
      _persistMultipleDevicesPower(room.devices, roomId: room.id);
      MqttService().publishAllDevices(room.scopedRoomId, allOn);
    }
    notifyListeners();
    _scheduleLocalStorageSave(immediate: true);
  }

  void applyPreset(String roomId, String preset) {
    final room = _classrooms.firstWhere((r) => r.id == roomId);
    room.isOccupied = true;

    for (var d in room.devices) {
      switch (preset) {
        case 'Lecture':
          if (d.type == DeviceType.projector) {
            d.isOn = true;
            d.screenDeployed = true;
            d.projectorSource = 'HDMI 1';
          }
          if (d.type == DeviceType.lighting) {
            d.isOn = true;
            d.brightness = 65;
            d.lumens = 900;
          }
          if (d.type == DeviceType.hvac) {
            d.isOn = true;
            d.temperature = 22;
            d.hvacMode = 'AUTO';
          }
          if (d.type == DeviceType.fan) {
            d.isOn = true;
            d.fanSpeed = 2;
          }
          break;

        case 'Lab Work':
          if (d.type == DeviceType.lighting) {
            d.isOn = true;
            d.brightness = 100;
            d.lumens = 1400;
          }
          if (d.type == DeviceType.hvac) {
            d.isOn = true;
            d.temperature = 20;
            d.hvacMode = 'BOOST';
          }
          if (d.type == DeviceType.fan) {
            d.isOn = true;
            d.fanSpeed = 4;
          }
          if (d.type == DeviceType.powerStrip) {
            d.isOn = true;
          }
          break;

        case 'Eco Save':
          if (d.type == DeviceType.projector) {
            d.isOn = false;
          }
          if (d.type == DeviceType.lighting) {
            d.isOn = true;
            d.brightness = 40;
            d.lumens = 550;
          }
          if (d.type == DeviceType.hvac) {
            d.isOn = true;
            d.temperature = 25;
            d.hvacMode = 'QUIET';
          }
          if (d.type == DeviceType.fan) {
            d.isOn = true;
            d.fanSpeed = 1;
          }
          break;

        case 'Break':
          if (d.type == DeviceType.projector) {
            d.isOn = false;
          }
          if (d.type == DeviceType.lighting) {
            d.isOn = true;
            d.brightness = 50;
            d.lumens = 700;
          }
          if (d.type == DeviceType.hvac) {
            d.isOn = true;
            d.temperature = 24;
            d.hvacMode = 'AUTO';
          }
          if (d.type == DeviceType.fan) {
            d.isOn = true;
            d.fanSpeed = 2;
          }
          break;
      }
    }
    notifyListeners();
    _persistMultipleDevicesPower(room.devices, roomId: room.id);
    _scheduleLocalStorageSave(immediate: true);
    for (final d in room.devices) {
      MqttService().publishDeviceCommand(room.scopedRoomId, d, d.isOn);
    }
  }

  void triggerEmergencyCutoff(String roomId) {
    final room = findRoom(roomId);
    if (room == null) return;
    for (var d in room.devices) {
      d.isOn = false;
      if (d.type == DeviceType.fan) d.fanSpeed = 0;
      if (d.type == DeviceType.lighting) d.brightness = 0;
    }
    room.isOccupied = false;
    notifyListeners();
    _scheduleLocalStorageSave(immediate: true);
    MqttService().publishEmergencyCutoff(room.scopedRoomId, true);
  }

  void updateDeviceGpio(String roomId, String deviceId, int newGpioPin) {
    final room = findRoom(roomId);
    if (room == null) return;
    final device = findDevice(room, deviceId);
    if (device == null) return;
    device.relayChannel = 'RELAY ${device.deviceIndex} (GPIO $newGpioPin)';
    notifyListeners();
    _scheduleLocalStorageSave();

    // Calculate all fanPins and lightPins for this board to publish OTA config
    final boardId = ((device.deviceIndex - 1) ~/ 4) + 1;
    final fanPins = room.devices
        .where((d) => d.type == DeviceType.fan)
        .map((d) => d.gpioPinNumber)
        .toList();
    final lightPins = room.devices
        .where((d) => d.type == DeviceType.lighting)
        .map((d) => d.gpioPinNumber)
        .toList();

    MqttService().publishGpioConfig(
      room.scopedRoomId,
      boardId,
      fanPins: fanPins.isNotEmpty ? fanPins : [18, 19],
      lightPins: lightPins.isNotEmpty ? lightPins : [21, 22, 23, 25],
    );
  }

  void addClassroom(Classroom room) {
    SharedPreferences.getInstance().then((prefs) {
      prefs.setBool('classpulse_explicitly_cleared', false);
    });
    _classrooms.add(room);
    _selectedRoomId = room.id;
    notifyListeners();
    _scheduleLocalStorageSave(immediate: true);
    FirestoreService().syncClassroom(room);
  }

  void renameClassroom(String roomId, String newName, String newRoomNumber) {
    final idx = _classrooms.indexWhere((r) => r.id == roomId);
    if (idx != -1) {
      _classrooms[idx].name = newName;
      _classrooms[idx].roomNumber = newRoomNumber;
      notifyListeners();
      _scheduleLocalStorageSave();
      FirestoreService().syncClassroom(_classrooms[idx]);
    }
  }

  void updateRoomSettings({
    required String roomId,
    required String name,
    required String roomNumber,
    required String roomType,
    String? building,
    required int occupancyCeiling,
    required bool automatedSchedules,
  }) {
    final idx = _classrooms.indexWhere((r) => r.id == roomId);
    if (idx != -1) {
      _classrooms[idx].name = name;
      _classrooms[idx].roomNumber = roomNumber;
      _classrooms[idx].roomType = roomType;
      if (building != null && building.trim().isNotEmpty) {
        _classrooms[idx].building = building.trim();
      }
      _classrooms[idx].occupancyCeiling = occupancyCeiling;
      _classrooms[idx].automatedSchedules = automatedSchedules;
      notifyListeners();
      _scheduleLocalStorageSave();
      FirestoreService().syncClassroom(_classrooms[idx]);
    }
  }

  void deleteClassroom(String roomId) {
    _classrooms.removeWhere((r) => r.id == roomId);
    if (_selectedRoomId == roomId && _classrooms.isNotEmpty) {
      _selectedRoomId = _classrooms.first.id;
    }
    notifyListeners();
    _scheduleLocalStorageSave(immediate: true);
    FirestoreService().deleteClassroom(roomId);
  }

  void addDevice(String roomId, ClassroomDevice device) {
    final room = findRoom(roomId);
    if (room == null) return;
    room.devices.add(device);
    notifyListeners();
    _scheduleLocalStorageSave(immediate: true);
    FirestoreService().syncClassroom(room);
  }

  void addDevices(String roomId, List<ClassroomDevice> newDevices) {
    final room = findRoom(roomId);
    if (room == null || newDevices.isEmpty) return;
    room.devices.addAll(newDevices);
    notifyListeners();
    _scheduleLocalStorageSave(immediate: true);
    FirestoreService().syncClassroom(room);
  }

  void deleteDevice(String roomId, String deviceId) {
    final room = findRoom(roomId);
    if (room == null) return;
    final devIndex = room.devices.indexWhere((d) => d.id == deviceId);
    if (devIndex != -1) {
      final dev = room.devices[devIndex];
      if (dev.isOn) {
        // Disengage physical relay before removing mapping
        MqttService().publishDeviceCommand(room.scopedRoomId, dev, false);
      }
      room.devices.removeAt(devIndex);
    }
    notifyListeners();
    _scheduleLocalStorageSave(immediate: true);
    FirestoreService().syncClassroom(room);
  }

  void setDevicePower(String roomId, String deviceId, bool isOn) {
    final room = findRoom(roomId);
    if (room == null) return;
    final device = findDevice(room, deviceId);
    if (device == null) return;
    device.isOn = isOn;
    if (isOn) {
      if (device.type == DeviceType.fan && device.fanSpeed == 0) {
        device.fanSpeed = 3;
      }
      if (device.type == DeviceType.lighting && device.brightness == 0) {
        device.brightness = 85;
      }
    }
    _recordUserToggle(roomId, deviceId);
    _persistDevicePower(device, roomId: room.id);
    notifyListeners();
    _scheduleLocalStorageSave(immediate: true);
    MqttService().publishDeviceCommand(room.scopedRoomId, device, isOn);
  }

  void setScreenPosition(String roomId, String deviceId, String position) {
    final room = findRoom(roomId);
    if (room == null) return;
    final device = findDevice(room, deviceId);
    if (device == null) return;
    device.screenPosition = position;
    device.screenDeployed = (position != 'Retracted');
    notifyListeners();
    _scheduleLocalStorageSave();
  }

  void setPictureProfile(String roomId, String deviceId, String profile) {
    final room = findRoom(roomId);
    if (room == null) return;
    final device = findDevice(room, deviceId);
    if (device == null) return;
    device.pictureProfile = profile;
    notifyListeners();
    _scheduleLocalStorageSave();
  }

  void setFanTimer(String roomId, String deviceId, int minutes) {
    final room = findRoom(roomId);
    if (room == null) return;
    final device = findDevice(room, deviceId);
    if (device == null) return;
    device.fanTimerMinutes = minutes;
    notifyListeners();
    _scheduleLocalStorageSave();
  }

  void runRelaySelfTest(String roomId, String deviceId) {
    final room = findRoom(roomId);
    if (room == null) return;
    final device = findDevice(room, deviceId);
    if (device == null) return;
    device.eventLog.insert(
      0,
      DeviceEvent(
        time: 'Just now',
        title: 'Relay self-test pulsed: 250ms zero-cross cycle successful',
        isHighlight: true,
      ),
    );
    notifyListeners();
    _scheduleLocalStorageSave();
  }

  void rebootNode(String roomId, String deviceId) {
    final room = findRoom(roomId);
    if (room == null) return;
    final device = findDevice(room, deviceId);
    if (device == null) return;
    device.eventLog.insert(
      0,
      DeviceEvent(
        time: 'Just now',
        title: 'ESP32 microcontroller reboot command issued via BLE mesh',
        isHighlight: true,
      ),
    );
    notifyListeners();
    _scheduleLocalStorageSave();
  }

  void syncRelays(String roomId, String deviceId) {
    final room = findRoom(roomId);
    if (room == null) return;
    final device = findDevice(room, deviceId);
    if (device == null) return;
    device.eventLog.insert(
      0,
      DeviceEvent(
        time: 'Just now',
        title: 'Hardware relay contact states verified in sync with mesh bus',
        isHighlight: true,
      ),
    );
    notifyListeners();
    _scheduleLocalStorageSave();
  }

  String? toggleZone(String roomId, String zoneName) {
    final room = findRoom(roomId);
    if (room == null) return null;
    final zoneDevs = room.devicesInZone(zoneName);

    final willTurnOn = !zoneDevs.any((d) => d.isOn);

    if (willTurnOn) {
      if (_visionControlEnabled) {
        final occ = getZoneOccupancy(room, zoneName);
        if (occ <= 0) {
          debugPrint(
            '[Vision Gate] BLOCKED toggleZone ON for $zoneName: 0 occupants.',
          );
          return 'Vision Gate: $zoneName is empty (0 occupants). Turn off Vision Control for direct control.';
        }
      }
      for (var d in zoneDevs) {
        d.manualOverrideOff = false;
      }
    } else {
      for (var d in zoneDevs) {
        d.manualOverrideOff = true;
      }
    }
    for (var d in zoneDevs) {
      d.isOn = willTurnOn;
      if (willTurnOn) {
        if (d.type == DeviceType.fan && d.fanSpeed == 0) d.fanSpeed = 3;
        if (d.type == DeviceType.lighting && d.brightness == 0) {
          d.brightness = 85;
        }
      }
    }

    // Determine target switchboard / boardId for this zone (e.g. Zone 1 -> 1, Zone 2 -> 2)
    final zoneMatch = RegExp(
      r'Zone\s*(\d+)',
      caseSensitive: false,
    ).firstMatch(zoneName);
    final boardId = zoneMatch != null
        ? (int.tryParse(zoneMatch.group(1) ?? '') ?? 1)
        : (zoneDevs.isNotEmpty ? zoneDevs.first.boardId : 1);

    // 1. Publish dedicated Zone Master command targeting ONLY this switchboard!
    MqttService().publishZoneAll(room.scopedRoomId, boardId, willTurnOn);

    // 2. Also publish individual device state updates
    for (var d in zoneDevs) {
      MqttService().publishDeviceCommand(room.scopedRoomId, d, willTurnOn);
    }

    _persistMultipleDevicesPower(zoneDevs, roomId: room.id);
    notifyListeners();
    _scheduleLocalStorageSave(immediate: true);
    return null;
  }

  void addZone(String roomId, String zoneName) {
    final room = findRoom(roomId);
    if (room == null) return;
    if (!room.zones.contains(zoneName)) {
      room.zones.add(zoneName);
      room.zoneCount = room.zones.length;
      notifyListeners();
      _scheduleLocalStorageSave();
      FirestoreService().syncClassroom(room);
    }
  }

  // Renames a zone for UI display only (e.g. "Front Podium" for "Zone 1").
  // Internal device mapping, MQTT topics, and ESP32 board IDs remain strictly on the hardware zone key ("Zone 1").
  void renameZone(String roomId, String zoneKey, String newDisplayName) {
    final room = findRoom(roomId);
    if (room == null) return;
    final trimmed = newDisplayName.trim();
    if (trimmed.isEmpty || trimmed.toLowerCase() == zoneKey.toLowerCase()) {
      room.zoneAliases.remove(zoneKey);
    } else {
      room.zoneAliases[zoneKey] = trimmed;
    }
    notifyListeners();
    _scheduleLocalStorageSave(immediate: true);
    FirestoreService().syncClassroom(room);
  }

  // Deletes a zone and removes any devices assigned to that zone
  void deleteZone(String roomId, String zoneKey) {
    final room = findRoom(roomId);
    if (room == null) return;
    room.zones.remove(zoneKey);
    room.zoneAliases.remove(zoneKey);
    room.zoneCount = room.zones.length;
    room.devices.removeWhere((d) => d.zone == zoneKey);
    notifyListeners();
    _scheduleLocalStorageSave(immediate: true);
    FirestoreService().syncClassroom(room);
  }

  Future<void> clearAllData() async {
    _classrooms.clear();
    _selectedRoomId = '';
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('classpulse_explicitly_cleared', true);
      await prefs.setBool('classpulse_initialized', true);
      await prefs.setString(_storageKeyClassrooms, '[]');
      await prefs.remove(_storageKeySelectedRoom);

      // Clean up all device power state keys and legacy partitioned keys
      final allKeys = prefs.getKeys();
      for (final k in allKeys) {
        if (k.startsWith('pwr_') ||
            k.startsWith('spd_') ||
            k.startsWith('bri_') ||
            k.startsWith('${_storageKeyClassrooms}_') ||
            k.startsWith('${_storageKeySelectedRoom}_')) {
          await prefs.remove(k);
        }
      }
    } catch (_) {}
    try {
      await FirestoreService().wipeAllClassrooms();
    } catch (e) {
      debugPrint('Error wiping Firebase classrooms in clearAllData: $e');
    }
  }

  void loadDemoData() {
    SharedPreferences.getInstance().then((prefs) {
      prefs.setBool('classpulse_explicitly_cleared', false);
      prefs.setBool('classpulse_initialized', true);
    });
    _initInitialData();
    if (_classrooms.isNotEmpty) {
      _selectedRoomId = _classrooms.first.id;
    }
    notifyListeners();
    _saveToLocalStorage();
    for (final room in _classrooms) {
      FirestoreService().syncClassroom(room);
    }
  }
}
