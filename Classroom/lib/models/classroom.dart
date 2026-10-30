import 'package:cloud_firestore/cloud_firestore.dart';
import 'device.dart';
import 'user_role.dart';

class Classroom {
  final String id;
  String roomNumber;
  String name;
  String building;
  String floor;
  bool isOccupied;
  int occupancyCeiling;
  int currentOccupancy;
  String gatewayId;
  String roomType; // Laboratory, Lecture Hall, Seminar Room, Standard Class
  bool automatedSchedules;
  int zoneCount;
  List<String> zones;
  Map<String, String> zoneAliases; // Custom display name aliases for UI only (e.g. {'Zone 1': 'Front Podium'})
  List<ClassroomDevice> devices;
  DateTime? lastIntervalSync;
  int? classSyncInterval;

  Classroom({
    required this.id,
    required this.roomNumber,
    required this.name,
    required this.building,
    required this.floor,
    this.isOccupied = false,
    this.occupancyCeiling = 35,
    this.currentOccupancy = 0,
    this.gatewayId = 'HUB-ESP32-MESH',
    this.roomType = 'Laboratory',
    this.automatedSchedules = true,
    int? zoneCount,
    List<String>? zones,
    Map<String, String>? zoneAliases,
    required this.devices,
    this.lastIntervalSync,
    this.classSyncInterval,
  })  : zoneCount = zoneCount ?? (zones != null && zones.isNotEmpty ? zones.length : 2),
        zones = zones ?? (zoneCount != null && zoneCount > 0
            ? List.generate(zoneCount, (i) => 'Zone ${i + 1}')
            : ['Zone 1', 'Zone 2']),
        zoneAliases = zoneAliases ?? {};

  String getZoneDisplayName(String zone) {
    final alias = zoneAliases[zone];
    if (alias != null && alias.trim().isNotEmpty) {
      return alias.trim();
    }
    return zone;
  }

  int get activeDeviceCount => devices.where((d) => d.isOn).length;
  int get totalDeviceCount => devices.length;
  bool get isMasterOn => activeDeviceCount > 0;

  String get buildingShort => getDepartmentShortName(building).toLowerCase();

  // Scoped unique identifier for MQTT topics & isolation (e.g. "ete_room_304", "eee_room_304")
  // Guarantees zero cross-talk between identical room numbers in different campus buildings.
  String get scopedRoomId {
    final b = buildingShort.replaceAll(RegExp(r'[^a-z0-9]'), '');
    final r = roomNumber.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '_').replaceAll(RegExp(r'_+'), '_');
    final cleanRoom = r.startsWith('room') ? r : 'room_$r';
    if (id.startsWith('${b}_')) return id;
    return '${b}_$cleanRoom';
  }

  List<ClassroomDevice> devicesInZone(String zoneName) {
    return devices.where((d) => d.zone == zoneName).toList();
  }

  int activeDevicesInZone(String zoneName) {
    return devices.where((d) => d.zone == zoneName && d.isOn).length;
  }

  bool isZoneActive(String zoneName) {
    final zoneDevs = devicesInZone(zoneName);
    return zoneDevs.isNotEmpty && zoneDevs.any((d) => d.isOn);
  }

  String get deploymentBadge {
    if (activeDeviceCount > 0) {
      return '$activeDeviceCount Active ($zoneCount Zones)';
    }
    return 'Standby ($zoneCount Zones)';
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'roomNumber': roomNumber,
      'name': name,
      'building': building,
      'floor': floor,
      'isOccupied': isOccupied,
      'occupancyCeiling': occupancyCeiling,
      'currentOccupancy': currentOccupancy,
      'gatewayId': gatewayId,
      'roomType': roomType,
      'automatedSchedules': automatedSchedules,
      'zoneCount': zoneCount,
      'zones': zones,
      'zoneAliases': zoneAliases,
      'devices': devices.map((d) => d.toMap()).toList(),
      'lastIntervalSync': lastIntervalSync?.toIso8601String(),
      'classSyncInterval': classSyncInterval,
    };
  }

  // Cloud Firestore serialization (EXCLUDES live power ON/OFF state)
  Map<String, dynamic> toFirestoreMap() {
    return {
      'id': id,
      'roomNumber': roomNumber,
      'name': name,
      'building': building,
      'floor': floor,
      'isOccupied': isOccupied,
      'occupancyCeiling': occupancyCeiling,
      'currentOccupancy': currentOccupancy,
      'gatewayId': gatewayId,
      'roomType': roomType,
      'automatedSchedules': automatedSchedules,
      'zoneCount': zoneCount,
      'zones': zones,
      'zoneAliases': zoneAliases,
      'devices': devices.map((d) => d.toFirestoreMap()).toList(),
    };
  }

  factory Classroom.fromMap(Map<String, dynamic> map) {
    final rawDevices = map['devices'] as List<dynamic>? ?? [];

    // Check if devicesState snapshot exists in the document (from 3-interval class sync)
    final rawStateList = map['devicesState'] as List<dynamic>? ?? [];
    final Map<String, Map<String, dynamic>> stateMap = {};
    for (final s in rawStateList) {
      if (s is Map) {
        final m = Map<String, dynamic>.from(s);
        final devId = m['id']?.toString();
        if (devId != null) {
          stateMap[devId] = m;
        }
      }
    }

    final Map<String, int> zoneDeviceCounter = {};
    final devList = rawDevices.map((d) {
      final baseMap = Map<String, dynamic>.from(d as Map);
      final devId = baseMap['id']?.toString();
      if (devId != null && stateMap.containsKey(devId)) {
        baseMap.addAll(stateMap[devId]!);
      }

      final zoneName = baseMap['zone']?.toString() ?? 'Zone 1';
      final count = (zoneDeviceCounter[zoneName] ?? 0) + 1;
      zoneDeviceCounter[zoneName] = count;
      final autoRelay = ((count - 1) % 4) + 1;

      final existingRelay = (baseMap['relayNumber'] as num?)?.toInt();
      final existingChannel = baseMap['relayChannel']?.toString() ?? '';

      if (existingRelay == null || existingRelay < 1 || existingRelay > 4 || existingChannel.contains('GPIO 16') || existingChannel.contains('GPIO 17')) {
        final idStr = baseMap['id']?.toString() ?? '';
        final idMatch = RegExp(r'[-_](?:r|relay|l|f)?([1-4])(?:\b|_|$)', caseSensitive: false).firstMatch(idStr);
        final rNum = idMatch != null ? (int.tryParse(idMatch.group(1) ?? '') ?? autoRelay) : autoRelay;
        baseMap['relayNumber'] = rNum;
        baseMap['relayChannel'] = ClassroomDevice.defaultRelayChannelForRelay(rNum);
      }

      return ClassroomDevice.fromMap(baseMap);
    }).toList();

    final rawZones = map['zones'] as List<dynamic>?;
    final zoneList = rawZones?.map((z) => z.toString()).toList() ?? ['Zone 1', 'Zone 2'];
    final int zCount = (map['zoneCount'] as num?)?.toInt() ?? zoneList.length;
    final cleanZoneList = (zoneList.length > zCount && zCount > 0)
        ? zoneList.take(zCount).toList()
        : zoneList;

    final rawAliases = map['zoneAliases'] as Map<dynamic, dynamic>?;
    final Map<String, String> parsedAliases = {};
    if (rawAliases != null) {
      rawAliases.forEach((k, v) {
        if (v != null && v.toString().trim().isNotEmpty) {
          parsedAliases[k.toString()] = v.toString().trim();
        }
      });
    }

    DateTime? lastIntervalSync;
    if (map['lastIntervalSync'] != null) {
      if (map['lastIntervalSync'] is Timestamp) {
        lastIntervalSync = (map['lastIntervalSync'] as Timestamp).toDate();
      } else if (map['lastIntervalSync'] is String) {
        lastIntervalSync = DateTime.tryParse(map['lastIntervalSync']);
      }
    }
    final classSyncInterval = (map['classSyncInterval'] as num?)?.toInt();

    return Classroom(
      id: map['id'] ?? 'room-${DateTime.now().millisecondsSinceEpoch}',
      roomNumber: map['roomNumber'] ?? 'Room 101',
      name: map['name'] ?? 'Classroom',
      building: map['building'] ?? 'Academic Building',
      floor: map['floor'] ?? '1st Floor',
      isOccupied: map['isOccupied'] ?? false,
      occupancyCeiling: (map['occupancyCeiling'] as num?)?.toInt() ?? 35,
      currentOccupancy: (map['currentOccupancy'] as num?)?.toInt() ?? 0,
      gatewayId: map['gatewayId'] ?? 'HUB-ESP32-MESH',
      roomType: map['roomType'] ?? 'Standard Class',
      automatedSchedules: map['automatedSchedules'] ?? true,
      zoneCount: zCount,
      zones: cleanZoneList,
      zoneAliases: parsedAliases,
      devices: devList,
      lastIntervalSync: lastIntervalSync,
      classSyncInterval: classSyncInterval,
    );
  }

  Classroom copyWith({
    String? id,
    String? roomNumber,
    String? name,
    String? building,
    String? floor,
    bool? isOccupied,
    int? occupancyCeiling,
    int? currentOccupancy,
    String? gatewayId,
    String? roomType,
    bool? automatedSchedules,
    int? zoneCount,
    List<String>? zones,
    Map<String, String>? zoneAliases,
    List<ClassroomDevice>? devices,
  }) {
    return Classroom(
      id: id ?? this.id,
      roomNumber: roomNumber ?? this.roomNumber,
      name: name ?? this.name,
      building: building ?? this.building,
      floor: floor ?? this.floor,
      isOccupied: isOccupied ?? this.isOccupied,
      occupancyCeiling: occupancyCeiling ?? this.occupancyCeiling,
      currentOccupancy: currentOccupancy ?? this.currentOccupancy,
      gatewayId: gatewayId ?? this.gatewayId,
      roomType: roomType ?? this.roomType,
      automatedSchedules: automatedSchedules ?? this.automatedSchedules,
      zoneCount: zoneCount ?? this.zoneCount,
      zones: zones ?? this.zones,
      zoneAliases: zoneAliases ?? Map<String, String>.from(this.zoneAliases),
      devices: devices ?? this.devices,
    );
  }
}
