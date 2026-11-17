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
  bool manualOverrideOff;

  // Runtime MQTT confirmation state (Pending until ESP32 reports applied state)
  bool isPendingConfirmation;
  bool? pendingTargetOn;

  // Hardware & ESP32 Relay / Switch mapping
  String relayChannel; // e.g. "RELAY 1 [In4 R] (D15) ↔ S1 (D13)" or "GREE AC #1 IR (GPIO 33)"
  String hardwareModel;
  String ipAddress;
  int pingMs;
  String zigbeeOrBleNode;
  String firmwareVersion;

  // HVAC / Standalone Dual-Gree AC specific (GPIO 33 -> AC #1, GPIO 12 -> AC #2)
  int temperature;
  String hvacMode; // AUTO, QUIET, BOOST, COOL, DRY, FAN, HEAT
  bool acSwing;

  // Fan specific
  int fanSpeed; // 0, 1, 2, 3, 4, 5
  bool fanReverse;
  int fanTimerMinutes;

  // Light specific
  double brightness; // 0..100
  int lumens;

  // Projector specific
  String projectorSource;
  bool screenDeployed;
  String screenPosition;
  String pictureProfile;

  // Telemetry specific
  int co2Ppm;
  int humidityRh;
  double ambientTemp;

  // Power strip specific
  int wattage;
  double amperage;
  int activeSockets;
  int totalSockets;

  // Zone mapping ("Zone 1", "Zone 2", "Zone 3", or "Standalone AC")
  String zone;

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
    this.manualOverrideOff = false,
    this.isPendingConfirmation = false,
    this.pendingTargetOn,
    this.zone = 'Zone 1',
    this.temperature = 24,
    this.hvacMode = 'COOL',
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
    this.firmwareVersion = 'v3.2.0-8pair-sync',
    List<DeviceEvent>? eventLog,
  })  : relayChannel = relayChannel ?? _defaultRelayChannel(type, zone: zone),
        hardwareModel = hardwareModel ?? _defaultHardwareModel(type),
        eventLog = eventLog ?? _defaultEventLog(type);

  // ===========================================================================
  // EXACT HARDWARE GPIO MAPPING (ZONE 1 [6], ZONE 2 [8], ZONE 3 [5])
  // ===========================================================================
  static List<Map<String, dynamic>> switchRelayPairsForZone(int boardId) {
    if (boardId == 1) {
      // Zone 1 (ESP32 30-Pin - "1st Board"): Left starts In1 (1-4), Right starts In5 (5-6)
      return const [
        {'relay': 1, 'relayLabel': 'In1 [L]', 'gpio': 16, 'switchName': 'S1', 'switchGpio': 14},
        {'relay': 2, 'relayLabel': 'In2 [L]', 'gpio': 4,  'switchName': 'S2', 'switchGpio': 27},
        {'relay': 3, 'relayLabel': 'In3 [L]', 'gpio': 2,  'switchName': 'S3', 'switchGpio': 26},
        {'relay': 4, 'relayLabel': 'In4 [L]', 'gpio': 15, 'switchName': 'S4', 'switchGpio': 25},
        {'relay': 5, 'relayLabel': 'In5 [R]', 'gpio': 21, 'switchName': 'S5', 'switchGpio': 33},
        {'relay': 6, 'relayLabel': 'In6 [R]', 'gpio': 19, 'switchName': 'S6', 'switchGpio': 34},
      ];
    } else if (boardId == 2) {
      // Zone 2 (Unlabeled Board): 8 pairs
      return const [
        {'relay': 1, 'relayLabel': 'In4 [R]', 'gpio': 15, 'switchName': 'SW1', 'switchGpio': 13},
        {'relay': 2, 'relayLabel': 'In3 [R]', 'gpio': 2,  'switchName': 'SW2', 'switchGpio': 12},
        {'relay': 3, 'relayLabel': 'In2 [R]', 'gpio': 4,  'switchName': 'SW3', 'switchGpio': 14},
        {'relay': 4, 'relayLabel': 'In1 [R]', 'gpio': 16, 'switchName': 'SW4', 'switchGpio': 27},
        {'relay': 5, 'relayLabel': 'In4 [L]', 'gpio': 5,  'switchName': 'SW5', 'switchGpio': 26},
        {'relay': 6, 'relayLabel': 'In3 [L]', 'gpio': 18, 'switchName': 'SW6', 'switchGpio': 25},
        {'relay': 7, 'relayLabel': 'In2 [L]', 'gpio': 19, 'switchName': 'SW7', 'switchGpio': 33},
        {'relay': 8, 'relayLabel': 'In1 [L]', 'gpio': 21, 'switchName': 'SW8', 'switchGpio': 32},
      ];
    } else {
      // Zone 3 ("3rd One"): 5 pairs
      return const [
        {'relay': 1, 'relayLabel': 'In1', 'gpio': 5,  'switchName': 'SW1', 'switchGpio': 32},
        {'relay': 2, 'relayLabel': 'In2', 'gpio': 4,  'switchName': 'SW2', 'switchGpio': 33},
        {'relay': 3, 'relayLabel': 'In3', 'gpio': 2,  'switchName': 'SW3', 'switchGpio': 25},
        {'relay': 4, 'relayLabel': 'In4', 'gpio': 15, 'switchName': 'SW4', 'switchGpio': 26},
        {'relay': 5, 'relayLabel': 'In5', 'gpio': 18, 'switchName': 'SW5', 'switchGpio': 27},
      ];
    }
  }

  static Map<String, dynamic> pairInfoForRelay(int relayNum, {int boardId = 1}) {
    final pairs = switchRelayPairsForZone(boardId);
    final count = pairs.length;
    final idx = ((relayNum - 1) % count).clamp(0, count - 1);
    return pairs[idx];
  }

  static int defaultGpioForRelay(int relayNum, {int boardId = 1}) {
    final info = pairInfoForRelay(relayNum, boardId: boardId);
    return info['gpio'] as int;
  }

  static int defaultSwitchGpioForRelay(int relayNum, {int boardId = 1}) {
    final info = pairInfoForRelay(relayNum, boardId: boardId);
    return info['switchGpio'] as int;
  }

  static String defaultRelayChannelForRelay(int relayNum, {int boardId = 1}) {
    final count = switchRelayPairsForZone(boardId).length;
    final validRelay = ((relayNum - 1) % count) + 1;
    final info = pairInfoForRelay(validRelay, boardId: boardId);
    final rLabel = info['relayLabel'];
    final gpio = info['gpio'];
    final swName = info['switchName'];
    final swGpio = info['switchGpio'];
    return 'RELAY $validRelay [$rLabel] (GPIO $gpio) ↔ $swName (D$swGpio)';
  }

  static int defaultGpioForAcUnit(int acUnitNum) {
    return acUnitNum == 2 ? 12 : 33;
  }

  static String defaultAcChannelForUnit(int acUnitNum) {
    final validUnit = acUnitNum == 2 ? 2 : 1;
    final gpio = defaultGpioForAcUnit(validUnit);
    return 'GREE AC #$validUnit IR (GPIO $gpio)';
  }

  static int _boardIdFromZone(String zoneStr) {
    final lower = zoneStr.toLowerCase();
    if (lower.contains('ac') || lower.contains('standalone')) return 4;
    final m = RegExp(r'(\d+)').firstMatch(zoneStr);
    if (m != null) {
      return int.tryParse(m.group(1) ?? '') ?? 1;
    }
    return 1;
  }

  static String _defaultRelayChannel(DeviceType type, {String zone = 'Zone 1'}) {
    final bId = _boardIdFromZone(zone);
    switch (type) {
      case DeviceType.hvac:
        return defaultAcChannelForUnit(1); // Gree AC #1 on GPIO 33 (AC #2 uses GPIO 12)
      case DeviceType.lighting:
        return defaultRelayChannelForRelay(1, boardId: bId);
      case DeviceType.fan:
        return defaultRelayChannelForRelay(5, boardId: bId);
      case DeviceType.projector:
        return defaultRelayChannelForRelay(7, boardId: bId);
      case DeviceType.telemetry:
        return 'I2C BUS (GPIO 21/22)';
      case DeviceType.powerStrip:
        return defaultRelayChannelForRelay(8, boardId: bId);
    }
  }

  static String _defaultHardwareModel(DeviceType type) {
    switch (type) {
      case DeviceType.hvac:
        return 'Standalone Dual-Gree AC IR Controller (GPIO 33 / GPIO 12)';
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
        title: 'Synced with physical manual switch via MQTT',
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
    if (type == DeviceType.hvac) {
      if (relayChannel.contains('12') ||
          id.toLowerCase().endsWith('ac-2') ||
          id.toLowerCase().endsWith('ac2') ||
          name.contains('2')) {
        return 12; // Gree AC #2 IR Transmitter/Receiver on GPIO 12
      }
      return 33; // Gree AC #1 IR Transmitter/Receiver on GPIO 33
    }
    final match = RegExp(r'(?:GPIO|D)\s*(\d+)', caseSensitive: false).firstMatch(relayChannel);
    if (match != null) {
      final p = int.tryParse(match.group(1) ?? '');
      if (p != null && p >= 0 && p <= 39) {
        return p;
      }
    }
    return defaultGpioForRelay(relayNumber, boardId: boardId);
  }

  int get switchGpioPinNumber {
    if (type == DeviceType.hvac) return gpioPinNumber;
    return defaultSwitchGpioForRelay(relayNumber, boardId: boardId);
  }

  int get relayNumber {
    if (type == DeviceType.hvac) {
      return gpioPinNumber == 12 ? 2 : 1;
    }
    final match = RegExp(r'(?:RELAY|PAIR)\s*(\d+)', caseSensitive: false).firstMatch(relayChannel);
    if (match != null) {
      final parsed = int.tryParse(match.group(1) ?? '');
      if (parsed != null && parsed >= 1 && parsed <= 8) {
        return parsed;
      }
    }
    final idMatch = RegExp(r'[-_](?:r|relay|l|f|p)?([1-8])(?:\b|_|$)', caseSensitive: false).firstMatch(id);
    if (idMatch != null) {
      final parsedId = int.tryParse(idMatch.group(1) ?? '');
      if (parsedId != null && parsedId >= 1 && parsedId <= 8) {
        return parsedId;
      }
    }
    return ((deviceIndex - 1) % 8) + 1;
  }

  int get boardId {
    if (type == DeviceType.hvac ||
        zone.toLowerCase().contains('ac') ||
        zone.toLowerCase().contains('standalone') ||
        zigbeeOrBleNode.toLowerCase().contains('ac')) {
      return 4;
    }
    final zoneMatch = RegExp(r'Zone\s*(\d+)', caseSensitive: false).firstMatch(zone);
    if (zoneMatch != null) {
      return int.tryParse(zoneMatch.group(1) ?? '') ?? 1;
    }
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

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'type': type.name,
      'statusDescription': statusDescription,
      'isOn': isOn,
      'manualOverrideOff': manualOverrideOff,
      'zone': zone,
      'relayNumber': relayNumber,
      'relayChannel': relayChannel,
      'hardwareModel': hardwareModel,
      'ipAddress': ipAddress,
      'macAddress': macAddress,
      'protocol': protocol,
      'zigbeeOrBleNode': zigbeeOrBleNode,
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

  Map<String, dynamic> toFirestoreMap() {
    return {
      'id': id,
      'name': name,
      'type': type.name,
      'zone': zone,
      'relayNumber': relayNumber,
      'relayChannel': relayChannel,
    };
  }

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
      'zigbeeOrBleNode': zigbeeOrBleNode,
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

    final String zoneStr = map['zone']?.toString() ?? (type == DeviceType.hvac ? 'Standalone AC' : 'Zone 1');
    final int bId = _boardIdFromZone(zoneStr);

    int? parsedRelayNum = (map['relayNumber'] as num?)?.toInt();
    String? rawRelayChannel = map['relayChannel']?.toString();

    if (rawRelayChannel != null) {
      final m = RegExp(r'(?:RELAY|PAIR)\s*(\d+)', caseSensitive: false).firstMatch(rawRelayChannel);
      if (m != null) {
        final r = int.tryParse(m.group(1) ?? '');
        if (r != null && r >= 1 && r <= 8) {
          parsedRelayNum ??= r;
        }
      }
    }

    if (parsedRelayNum == null) {
      final idStr = (map['id'] ?? '').toString();
      final idMatch = RegExp(r'[-_](?:r|relay|l|f|p)?([1-8])(?:\b|_|$)', caseSensitive: false).firstMatch(idStr);
      if (idMatch != null) {
        parsedRelayNum = int.tryParse(idMatch.group(1) ?? '');
      }
    }

    final int rNum = (parsedRelayNum != null && parsedRelayNum >= 1 && parsedRelayNum <= 8)
        ? parsedRelayNum
        : 1;

    final bool isAcUnit2 = type == DeviceType.hvac &&
        ((rawRelayChannel != null && rawRelayChannel.contains('12')) ||
            rNum == 2 ||
            (map['name']?.toString().contains('2') == true));

    final bool isAutoMappedSwitch = rawRelayChannel != null &&
        rawRelayChannel.contains('↔') &&
        type != DeviceType.telemetry &&
        (bId >= 1 && bId <= 3);

    final String finalRelayChannel = (type == DeviceType.hvac)
        ? defaultAcChannelForUnit(isAcUnit2 ? 2 : 1)
        : ((!isAutoMappedSwitch &&
                rawRelayChannel != null &&
                rawRelayChannel.contains('GPIO'))
            ? rawRelayChannel
            : defaultRelayChannelForRelay(rNum, boardId: bId));

    return ClassroomDevice(
      id: map['id'] ?? 'dev-${DateTime.now().millisecondsSinceEpoch}',
      name: map['name'] ?? (type == DeviceType.hvac ? 'Standalone AC' : 'Device'),
      type: type,
      statusDescription: map['statusDescription'] ?? (map['isOn'] == true ? 'Active' : 'Standby'),
      isOn: map['isOn'] ?? false,
      manualOverrideOff: map['manualOverrideOff'] == true,
      zone: zoneStr,
      relayChannel: finalRelayChannel,
      hardwareModel: map['hardwareModel'] ?? _defaultHardwareModel(type),
      ipAddress: map['ipAddress'] ?? '192.168.0.100',
      macAddress: map['macAddress'] ?? 'AA:BB:CC:DD:EE:FF',
      protocol: map['protocol'] ?? 'MQTT',
      zigbeeOrBleNode: map['zigbeeOrBleNode'] ?? (type == DeviceType.hvac ? 'Standalone AC' : 'Switchboard #$bId'),
      temperature: (map['temperature'] as num?)?.toInt() ?? 24,
      hvacMode: map['hvacMode'] ?? 'COOL',
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
    bool? manualOverrideOff,
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
      manualOverrideOff: manualOverrideOff ?? this.manualOverrideOff,
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
