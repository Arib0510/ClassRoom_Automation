enum DeviceType {
  hvac,
  fan,
  lighting,
  projector,
  telemetry,
  powerStrip,
}

class DeviceEvent {
  final String time;
  final String title;
  final bool isHighlight;

  const DeviceEvent({
    required this.time,
    required this.title,
    this.isHighlight = false,
  });
}

class ClassroomDevice {
  final String id;
  String name;
  final DeviceType type;
  String statusDescription;
  bool isOn;

  // Hardware & ESP32 Relay mapping
  String relayChannel; // e.g. "RELAY 1 (GPIO 16)"
  String hardwareModel; // e.g. "Ceiling Fan Controller"
  String ipAddress;
  int pingMs;
  String zigbeeOrBleNode;
  String firmwareVersion;

  // HVAC specific
  int temperature;
  String hvacMode; // AUTO, QUIET, BOOST, COOL, DRY
  bool acSwing; // Auto vertical louver oscillation

  // Fan specific
  int fanSpeed; // 0, 1, 2, 3, 4
  bool fanReverse; // false: forward downward, true: reverse upward
  int fanTimerMinutes; // 0, 15, 30, 60, 120

  // Light specific
  double brightness; // 0..100
  int lumens;

  // Projector specific
  String projectorSource; // HDMI 1, HDMI 2, AIRPLAY, USB-C
  bool screenDeployed;
  String screenPosition; // 'Retracted', 'Halfway', 'Deployed'
  String pictureProfile; // 'Presentation', 'Cinema Eco', 'Blackboard'

  // Telemetry specific
  int co2Ppm;
  int humidityRh;
  double ambientTemp;

  // Power strip specific
  int wattage;
  double amperage;
  int activeSockets;
  int totalSockets;

  // Zone mapping
  String zone; // e.g. "Zone 1", "Zone 2"

  // Metadata
  String macAddress;
  String protocol;
  List<DeviceEvent> eventLog;

  ClassroomDevice({
    required this.id,
    required this.name,
    required this.type,
    required this.statusDescription,
    this.isOn = true,
    this.zone = 'Zone 1',
    this.temperature = 22,
    this.hvacMode = 'AUTO',
    this.acSwing = false,
    this.fanSpeed = 3,
    this.fanReverse = false,
    this.fanTimerMinutes = 0,
    this.brightness = 85.0,
    this.lumens = 1200,
    this.projectorSource = 'HDMI 1',
    this.screenDeployed = true,
    this.screenPosition = 'Deployed',
    this.pictureProfile = 'Presentation',
    this.co2Ppm = 650,
    this.humidityRh = 48,
    this.ambientTemp = 22.4,
    this.wattage = 142,
    this.amperage = 1.2,
    this.activeSockets = 6,
    this.totalSockets = 6,
    this.macAddress = 'AA:BB:CC:11:22:33',
    this.protocol = 'MQTT',
    String? relayChannel,
    String? hardwareModel,
    this.ipAddress = '192.168.1.142',
    this.pingMs = 12,
    this.zigbeeOrBleNode = 'ESP32-BOARD-01',
    this.firmwareVersion = 'v3.1.2-esp32-relays',
    List<DeviceEvent>? eventLog,
  })  : relayChannel = relayChannel ?? _defaultRelayChannel(type),
        hardwareModel = hardwareModel ?? _defaultHardwareModel(type),
        eventLog = eventLog ?? _defaultEventLog(type);

  // Exact 4-channel GPIO pin mappings on physical ESP32 switchboards
  static int defaultGpioForRelay(int relayNum) {
    switch (relayNum) {
      case 1:
        return 18;
      case 2:
        return 19;
      case 3:
        return 21;
      case 4:
        return 22;
      default:
        return 18;
    }
  }

  static String defaultRelayChannelForRelay(int relayNum) {
    final validRelay = ((relayNum - 1) % 4) + 1;
    final gpio = defaultGpioForRelay(validRelay);
    return 'RELAY $validRelay (GPIO $gpio)';
  }

  static String _defaultRelayChannel(DeviceType type) {
    switch (type) {
      case DeviceType.hvac:
        return 'IR TRANSMITTER (GPIO 4)'; // Optical Gree IR on GPIO 4 (Relays bypassed)
      case DeviceType.lighting:
        return defaultRelayChannelForRelay(2); // Relay 2 -> GPIO 19
      case DeviceType.fan:
        return defaultRelayChannelForRelay(3); // Relay 3 -> GPIO 21
      case DeviceType.projector:
        return defaultRelayChannelForRelay(4); // Relay 4 -> GPIO 22
      case DeviceType.telemetry:
        return 'I2C BUS (GPIO 21/22)';
      case DeviceType.powerStrip:
        return defaultRelayChannelForRelay(1);
    }
  }

  static String _defaultHardwareModel(DeviceType type) {
    switch (type) {
      case DeviceType.hvac:
        return 'Gree AC Optical Controller (IR)';
      case DeviceType.fan:
        return 'Ceiling Fan Controller';
      case DeviceType.lighting:
        return 'Lighting Controller';
      case DeviceType.projector:
        return 'Projector Controller';
      case DeviceType.telemetry:
        return 'Environmental Sensor';
      case DeviceType.powerStrip:
        return 'Relay Breakout Board';
    }
  }

  static List<DeviceEvent> _defaultEventLog(DeviceType type) {
    return [
      const DeviceEvent(
        time: '09:02 AM',
        title: 'Relay contact closed: Hardware circuit energized',
        isHighlight: true,
      ),
      const DeviceEvent(
        time: '08:58 AM',
        title: 'Auto-powered ON via Timetable Schedule (Mesh synced)',
        isHighlight: false,
      ),
      const DeviceEvent(
        time: 'Yesterday 22:15',
        title: 'Hardware relay diagnostic self-check passed',
        isHighlight: false,
      ),
    ];
  }

  int get gpioPinNumber {
    final match = RegExp(r'GPIO\s*(\d+)', caseSensitive: false).firstMatch(relayChannel);
    if (match != null) {
      final p = int.tryParse(match.group(1) ?? '');
      if (p != null && (p == 18 || p == 19 || p == 21 || p == 22)) {
        return p;
      }
    }
    return defaultGpioForRelay(relayNumber);
  }

  int get relayNumber {
    final match = RegExp(r'RELAY\s*(\d+)', caseSensitive: false).firstMatch(relayChannel);
    if (match != null) {
      final parsed = int.tryParse(match.group(1) ?? '');
      if (parsed != null && parsed >= 1 && parsed <= 4) {
        return parsed;
      }
    }
    final idMatch = RegExp(r'[-_](?:r|relay|l|f)?([1-4])(?:\b|_|$)', caseSensitive: false).firstMatch(id);
    if (idMatch != null) {
      final parsedId = int.tryParse(idMatch.group(1) ?? '');
      if (parsedId != null && parsedId >= 1 && parsedId <= 4) {
        return parsedId;
      }
    }
    return ((deviceIndex - 1) % 4) + 1;
  }

  int get boardId {
    // 1. Direct from Zone: "Zone 1" -> 1, "Zone 2" -> 2, etc.
    final zoneMatch = RegExp(r'Zone\s*(\d+)', caseSensitive: false).firstMatch(zone);
    if (zoneMatch != null) {
      return int.tryParse(zoneMatch.group(1) ?? '') ?? 1;
    }
    // 2. Direct from zigbeeOrBleNode: "Switchboard #1" -> 1
    final nodeMatch = RegExp(r'(\d+)').firstMatch(zigbeeOrBleNode);
    if (nodeMatch != null) {
      return int.tryParse(nodeMatch.group(1) ?? '') ?? 1;
    }
    return 1;
  }

  int get deviceIndex {
    final match = RegExp(r'(\d+)').firstMatch(name);
    if (match != null) {
      return int.tryParse(match.group(1) ?? '') ?? 1;
    }
    return 1;
  }

  // Full local serialization (preserves runtime ON/OFF state in SharedPreferences)
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'type': type.name,
      'statusDescription': statusDescription,
      'isOn': isOn,
      'zone': zone,
      'relayNumber': relayNumber,
      'relayChannel': relayChannel,
      'hardwareModel': hardwareModel,
      'ipAddress': ipAddress,
      'macAddress': macAddress,
      'protocol': protocol,
      'temperature': temperature,
      'hvacMode': hvacMode,
      'acSwing': acSwing,
      'fanSpeed': fanSpeed,
      'fanReverse': fanReverse,
      'fanTimerMinutes': fanTimerMinutes,
      'brightness': brightness,
      'lumens': lumens,
      'projectorSource': projectorSource,
      'screenDeployed': screenDeployed,
      'screenPosition': screenPosition,
      'pictureProfile': pictureProfile,
      'co2Ppm': co2Ppm,
      'humidityRh': humidityRh,
      'ambientTemp': ambientTemp,
      'wattage': wattage,
      'amperage': amperage,
      'activeSockets': activeSockets,
      'totalSockets': totalSockets,
    };
  }

  // Cloud catalog serialization: ONLY stores device id, name, type, zone, and relayNumber (what device is added where).
  // Live power states and volatile hardware properties remain strictly on phone storage.
  Map<String, dynamic> toFirestoreMap() {
    return {
      'id': id,
      'name': name,
      'type': type.name,
      'zone': zone,
      'relayNumber': relayNumber,
    };
  }

  // Full device state & configuration snapshot (synced to Firebase in 3 intervals per 50-minute class session)
  Map<String, dynamic> toStateAndConfigMap() {
    return {
      'id': id,
      'name': name,
      'type': type.name,
      'zone': zone,
      'relayNumber': relayNumber,
      'isOn': isOn,
      'statusDescription': statusDescription,
      'relayChannel': relayChannel,
      'hardwareModel': hardwareModel,
      'ipAddress': ipAddress,
      'macAddress': macAddress,
      'protocol': protocol,
      'temperature': temperature,
      'hvacMode': hvacMode,
      'acSwing': acSwing,
      'fanSpeed': fanSpeed,
      'fanReverse': fanReverse,
      'fanTimerMinutes': fanTimerMinutes,
      'brightness': brightness,
      'lumens': lumens,
      'projectorSource': projectorSource,
      'screenDeployed': screenDeployed,
      'screenPosition': screenPosition,
      'pictureProfile': pictureProfile,
      'co2Ppm': co2Ppm,
      'humidityRh': humidityRh,
      'ambientTemp': ambientTemp,
      'wattage': wattage,
      'amperage': amperage,
      'activeSockets': activeSockets,
      'totalSockets': totalSockets,
    };
  }

  factory ClassroomDevice.fromMap(Map<String, dynamic> map) {
    DeviceType type = DeviceType.lighting;
    final typeStr = (map['type'] ?? '').toString().toLowerCase();
    if (typeStr.contains('fan')) {
      type = DeviceType.fan;
    } else if (typeStr.contains('hvac') || typeStr.contains('ac')) {
      type = DeviceType.hvac;
    } else if (typeStr.contains('projector')) {
      type = DeviceType.projector;
    } else if (typeStr.contains('telemetry')) {
      type = DeviceType.telemetry;
    } else if (typeStr.contains('powerstrip')) {
      type = DeviceType.powerStrip;
    } else {
      type = DeviceType.lighting;
    }

    int? parsedRelayNum = (map['relayNumber'] as num?)?.toInt();
    String? rawRelayChannel = map['relayChannel']?.toString();

    // If relayChannel exists and does not contain legacy GPIO 16/17 bugs, extract relay number from it
    if (rawRelayChannel != null && !rawRelayChannel.contains('GPIO 16') && !rawRelayChannel.contains('GPIO 17')) {
      final m = RegExp(r'RELAY\s*(\d+)', caseSensitive: false).firstMatch(rawRelayChannel);
      if (m != null) {
        final r = int.tryParse(m.group(1) ?? '');
        if (r != null && r >= 1 && r <= 4) {
          parsedRelayNum ??= r;
        }
      }
    }

    // Check device id (e.g. dev-...-1, dev-...-2, dev-304-z1-l1, dev-304-z1-f2)
    if (parsedRelayNum == null) {
      final idStr = (map['id'] ?? '').toString();
      final idMatch = RegExp(r'[-_](?:r|relay|l|f)?([1-4])(?:\b|_|$)', caseSensitive: false).firstMatch(idStr);
      if (idMatch != null) {
        parsedRelayNum = int.tryParse(idMatch.group(1) ?? '');
      }
    }

    final int rNum = (parsedRelayNum != null && parsedRelayNum >= 1 && parsedRelayNum <= 4)
        ? parsedRelayNum
        : 1;

    final String finalRelayChannel = (type == DeviceType.hvac)
        ? 'IR TRANSMITTER (GPIO 4)'
        : ((rawRelayChannel != null &&
                !rawRelayChannel.contains('GPIO 16') &&
                !rawRelayChannel.contains('GPIO 17') &&
                rawRelayChannel.contains('GPIO'))
            ? rawRelayChannel
            : defaultRelayChannelForRelay(rNum));

    return ClassroomDevice(
      id: map['id'] ?? 'dev-${DateTime.now().millisecondsSinceEpoch}',
      name: map['name'] ?? 'Device',
      type: type,
      statusDescription: map['statusDescription'] ?? (map['isOn'] == true ? 'Active' : 'Standby'),
      isOn: map['isOn'] ?? false,
      zone: map['zone'] ?? 'Zone 1',
      relayChannel: finalRelayChannel,
      hardwareModel: map['hardwareModel'] ?? _defaultHardwareModel(type),
      ipAddress: map['ipAddress'] ?? '192.168.0.100',
      macAddress: map['macAddress'] ?? 'AA:BB:CC:DD:EE:FF',
      protocol: map['protocol'] ?? 'BLE / Wi-Fi',
      temperature: (map['temperature'] as num?)?.toInt() ?? 22,
      hvacMode: map['hvacMode'] ?? 'AUTO',
      acSwing: map['acSwing'] ?? false,
      fanSpeed: (map['fanSpeed'] as num?)?.toInt() ?? 3,
      fanReverse: map['fanReverse'] ?? false,
      fanTimerMinutes: (map['fanTimerMinutes'] as num?)?.toInt() ?? 0,
      brightness: (map['brightness'] as num?)?.toDouble() ?? 85.0,
      lumens: (map['lumens'] as num?)?.toInt() ?? 1200,
      projectorSource: map['projectorSource'] ?? 'HDMI 1',
      screenDeployed: map['screenDeployed'] ?? true,
      screenPosition: map['screenPosition'] ?? 'Deployed',
      pictureProfile: map['pictureProfile'] ?? 'Presentation',
      co2Ppm: (map['co2Ppm'] as num?)?.toInt() ?? 650,
      humidityRh: (map['humidityRh'] as num?)?.toInt() ?? 48,
      ambientTemp: (map['ambientTemp'] as num?)?.toDouble() ?? 22.4,
      wattage: (map['wattage'] as num?)?.toInt() ?? 142,
      amperage: (map['amperage'] as num?)?.toDouble() ?? 1.2,
      activeSockets: (map['activeSockets'] as num?)?.toInt() ?? 6,
      totalSockets: (map['totalSockets'] as num?)?.toInt() ?? 6,
    );
  }

  ClassroomDevice copyWith({
    String? id,
    String? name,
    DeviceType? type,
    String? statusDescription,
    bool? isOn,
    int? temperature,
    String? hvacMode,
    bool? acSwing,
    int? fanSpeed,
    bool? fanReverse,
    int? fanTimerMinutes,
    double? brightness,
    int? lumens,
    String? projectorSource,
    bool? screenDeployed,
    String? screenPosition,
    String? pictureProfile,
    int? co2Ppm,
    int? humidityRh,
    double? ambientTemp,
    int? wattage,
    double? amperage,
    int? activeSockets,
    int? totalSockets,
    String? macAddress,
    String? protocol,
    String? relayChannel,
    String? hardwareModel,
    String? ipAddress,
    int? pingMs,
    String? zigbeeOrBleNode,
    String? firmwareVersion,
    String? zone,
    List<DeviceEvent>? eventLog,
  }) {
    return ClassroomDevice(
      id: id ?? this.id,
      name: name ?? this.name,
      type: type ?? this.type,
      statusDescription: statusDescription ?? this.statusDescription,
      isOn: isOn ?? this.isOn,
      zone: zone ?? this.zone,
      temperature: temperature ?? this.temperature,
      hvacMode: hvacMode ?? this.hvacMode,
      acSwing: acSwing ?? this.acSwing,
      fanSpeed: fanSpeed ?? this.fanSpeed,
      fanReverse: fanReverse ?? this.fanReverse,
      fanTimerMinutes: fanTimerMinutes ?? this.fanTimerMinutes,
      brightness: brightness ?? this.brightness,
      lumens: lumens ?? this.lumens,
      projectorSource: projectorSource ?? this.projectorSource,
      screenDeployed: screenDeployed ?? this.screenDeployed,
      screenPosition: screenPosition ?? this.screenPosition,
      pictureProfile: pictureProfile ?? this.pictureProfile,
      co2Ppm: co2Ppm ?? this.co2Ppm,
      humidityRh: humidityRh ?? this.humidityRh,
      ambientTemp: ambientTemp ?? this.ambientTemp,
      wattage: wattage ?? this.wattage,
      amperage: amperage ?? this.amperage,
      activeSockets: activeSockets ?? this.activeSockets,
      totalSockets: totalSockets ?? this.totalSockets,
      macAddress: macAddress ?? this.macAddress,
      protocol: protocol ?? this.protocol,
      relayChannel: relayChannel ?? this.relayChannel,
      hardwareModel: hardwareModel ?? this.hardwareModel,
      ipAddress: ipAddress ?? this.ipAddress,
      pingMs: pingMs ?? this.pingMs,
      zigbeeOrBleNode: zigbeeOrBleNode ?? this.zigbeeOrBleNode,
      firmwareVersion: firmwareVersion ?? this.firmwareVersion,
      eventLog: eventLog ?? this.eventLog,
    );
  }
}
