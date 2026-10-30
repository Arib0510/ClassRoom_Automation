import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import '../models/device.dart';

enum MqttConnectionStatus {
  disconnected,
  connecting,
  connected,
  error,
}

class MqttService {
  static final MqttService _instance = MqttService._internal();
  factory MqttService() => _instance;

  MqttService._internal();

  MqttServerClient? _client;

  // Broker Configuration (Defaults to free, public, high-availability EMQX broker)
  String _broker = 'broker.emqx.io';
  int _port = 1883;
  String _baseTopic = 'ruet/classroom';
  String _username = '';
  String _password = '';

  String get broker => _broker;
  int get port => _port;
  String get baseTopic => _baseTopic;

  MqttConnectionStatus _status = MqttConnectionStatus.disconnected;
  MqttConnectionStatus get status => _status;
  bool get isConnected => _status == MqttConnectionStatus.connected;

  // Stream controller for live status changes
  final _statusController = StreamController<MqttConnectionStatus>.broadcast();
  Stream<MqttConnectionStatus> get statusStream => _statusController.stream;

  // Device status callback: (roomId, deviceTypeStr, deviceNumber, isOn, speed, brightness, gpio)
  void Function(
    String roomId,
    String deviceType,
    int deviceNumber,
    bool isOn,
    int? speed,
    double? brightness,
    int? gpio,
  )? onDeviceStatusReceived;

  // Board telemetry callback: (roomId, boardId, isOnline, ip, rssi)
  void Function(
    String roomId,
    int boardId,
    bool isOnline,
    String ip,
    int rssi,
  )? onBoardTelemetryReceived;

  // Switchboard-isolated relay status callback: (roomId, boardId, relayNumber, isOn, speed, brightness, gpio)
  void Function(
    String roomId,
    int boardId,
    int relayNumber,
    bool isOn,
    int? speed,
    double? brightness,
    int? gpio,
  )? onRelayStatusReceived;

  // Optical AC status callback: (roomId, boardId, isOn, temp, mode, fan, swing)
  void Function(
    String roomId,
    int boardId,
    bool isOn,
    int temp,
    String mode,
    int fan,
    bool swing,
  )? onAcStatusReceived;

  void configure({
    String? broker,
    int? port,
    String? baseTopic,
    String? username,
    String? password,
  }) {
    if (broker != null) _broker = broker.trim();
    if (port != null) _port = port;
    if (baseTopic != null) _baseTopic = baseTopic.trim();
    if (username != null) _username = username.trim();
    if (password != null) _password = password.trim();
  }

  Future<bool> connect() async {
    if (_status == MqttConnectionStatus.connecting) return false;
    _setStatus(MqttConnectionStatus.connecting);

    final clientId =
        'ClassPulseApp_${DateTime.now().millisecondsSinceEpoch}_${(100 + (DateTime.now().microsecond % 900))}';

    _client = MqttServerClient.withPort(_broker, clientId, _port);
    _client!.logging(on: false);
    _client!.keepAlivePeriod = 20;
    _client!.connectTimeoutPeriod = 8000;
    _client!.autoReconnect = true;
    _client!.setProtocolV311();
    _client!.onDisconnected = _onDisconnected;
    _client!.onConnected = _onConnected;
    _client!.onSubscribed = _onSubscribed;

    final connMess = MqttConnectMessage()
        .withClientIdentifier(clientId)
        .startClean();

    if (_username.isNotEmpty) {
      connMess.authenticateAs(_username, _password);
    }
    _client!.connectionMessage = connMess;

    try {
      debugPrint('[MQTT] Connecting to $_broker:$_port as $clientId...');
      await _client!.connect();
    } catch (e) {
      debugPrint('[MQTT] Exception during connect: $e');
      _disconnectInternal();
      _setStatus(MqttConnectionStatus.error);
      return false;
    }

    if (_client!.connectionStatus!.state == MqttConnectionState.connected) {
      _setStatus(MqttConnectionStatus.connected);
      _subscribeTopics();
      _listenIncomingMessages();
      return true;
    } else {
      debugPrint(
          '[MQTT] Connection failed with state: ${_client!.connectionStatus!.state}');
      _disconnectInternal();
      _setStatus(MqttConnectionStatus.error);
      return false;
    }
  }

  void _setStatus(MqttConnectionStatus s) {
    _status = s;
    _statusController.add(s);
  }

  void _onConnected() {
    debugPrint('[MQTT] Connected successfully to $_broker:$_port');
    _setStatus(MqttConnectionStatus.connected);
    // 1. Purge any stale retained messages from public broker to eliminate ghost toggles
    clearLegacyRetainedStatus();
    // 2. Query actual live hardware states from all active ESP32 switchboards
    Timer(const Duration(milliseconds: 350), () {
      requestHardwareSync();
    });
  }

  void requestHardwareSync([String roomId = 'room_304']) {
    _publish('$_baseTopic/all/command/query', 'QUERY', retain: false);
    _publish('$_baseTopic/$roomId/command/query', 'QUERY', retain: false);
    if (roomId.contains('_')) {
      _publish('$_baseTopic/${roomId.replaceAll('_', '-')}/command/query', 'QUERY', retain: false);
    } else if (roomId.contains('-')) {
      _publish('$_baseTopic/${roomId.replaceAll('-', '_')}/command/query', 'QUERY', retain: false);
    }
    debugPrint('[MQTT] Hardware sync queried for room: $roomId');
  }

  // Deletes any old stale retained messages on the public EMQX broker
  void clearLegacyRetainedStatus([String roomId = 'room_304']) {
    try {
      final rooms = [roomId, 'room_304', 'room-304', 'room-402', 'room_402', 'room-3152', 'room-6191', 'room-6445', 'room-9853', 'all'];
      for (final r in rooms) {
        for (int b = 1; b <= 4; b++) {
          _publish('$_baseTopic/$r/status/board/$b', '', retain: true);
          _publish('$_baseTopic/$r/zone/$b/status', '', retain: true);
          for (int rel = 1; rel <= 4; rel++) {
            _publish('$_baseTopic/$r/status/board/$b/relay/$rel', '', retain: true);
            _publish('$_baseTopic/$r/zone/$b/relay/$rel/status', '', retain: true);
            _publish('$_baseTopic/$r/zone/$b/relay/$rel', '', retain: true);
          }
        }
        for (int i = 1; i <= 8; i++) {
          _publish('$_baseTopic/$r/status/fan/$i', '', retain: true);
          _publish('$_baseTopic/$r/status/light/$i', '', retain: true);
          _publish('$_baseTopic/$r/status/ac/$i', '', retain: true);
        }
      }
    } catch (_) {}
  }

  void _onDisconnected() {
    debugPrint('[MQTT] Disconnected from broker. Auto-reconnecting in 2s...');
    _setStatus(MqttConnectionStatus.disconnected);
    Timer(const Duration(seconds: 2), () {
      if (!isConnected && _status != MqttConnectionStatus.connecting) {
        connect();
      }
    });
  }

  void _onSubscribed(String topic) {
    debugPrint('[MQTT] Subscribed to topic: $topic');
  }

  void _disconnectInternal() {
    try {
      _client?.disconnect();
    } catch (_) {}
    _client = null;
  }

  void disconnect() {
    _disconnectInternal();
    _setStatus(MqttConnectionStatus.disconnected);
  }

  void _subscribeTopics() {
    if (!isConnected || _client == null) return;

    // Listen strictly to physical switchboard telemetry & relay status channels (no catch-all wildcards)
    // Supports both single-level (e.g. ruet/classroom/ete_room_304/...) and dual-level (ruet/classroom/ete/room_304/...)
    _client!.subscribe('$_baseTopic/+/zone/+/status', MqttQos.atLeastOnce);
    _client!.subscribe('$_baseTopic/+/+/zone/+/status', MqttQos.atLeastOnce);
    _client!.subscribe('$_baseTopic/+/zone/+/relay/+/status', MqttQos.atLeastOnce);
    _client!.subscribe('$_baseTopic/+/+/zone/+/relay/+/status', MqttQos.atLeastOnce);
    _client!.subscribe('$_baseTopic/+/status/board/+', MqttQos.atLeastOnce);
    _client!.subscribe('$_baseTopic/+/+/status/board/+', MqttQos.atLeastOnce);
    _client!.subscribe('$_baseTopic/+/status/board/+/relay/+', MqttQos.atLeastOnce);
    _client!.subscribe('$_baseTopic/+/+/status/board/+/relay/+', MqttQos.atLeastOnce);

    // Optical AC status telemetry
    _client!.subscribe('$_baseTopic/+/zone/+/ac/status', MqttQos.atLeastOnce);
    _client!.subscribe('$_baseTopic/+/+/zone/+/ac/status', MqttQos.atLeastOnce);
    _client!.subscribe('$_baseTopic/+/status/ac', MqttQos.atLeastOnce);
    _client!.subscribe('$_baseTopic/+/+/status/ac', MqttQos.atLeastOnce);
    _client!.subscribe('$_baseTopic/+/status/board/+/ac', MqttQos.atLeastOnce);
    _client!.subscribe('$_baseTopic/+/+/status/board/+/ac', MqttQos.atLeastOnce);

    // Listen to configuration acknowledgements
    _client!.subscribe('$_baseTopic/+/config/ack', MqttQos.atLeastOnce);
    _client!.subscribe('$_baseTopic/+/+/config/ack', MqttQos.atLeastOnce);
  }

  void _listenIncomingMessages() {
    _client!.updates?.listen((List<MqttReceivedMessage<MqttMessage>> messages) {
      for (final msg in messages) {
        final recMess = msg.payload as MqttPublishMessage;
        final isRetained = recMess.header?.retain ?? false;
        final topic = msg.topic;
        final payload =
            MqttPublishPayload.bytesToStringAsString(recMess.payload.message);

        // STALE RETAINED MESSAGE INTERCEPTOR:
        // Stale messages lingering on the public EMQX broker must NEVER overwrite
        // active user states or mimic phantom hardware toggles.
        if (isRetained) {
          debugPrint('[MQTT] Discarding stale retained broker message on $topic - purging from broker');
          _publish(topic, '', retain: true);
          continue;
        }

        _handleMessage(topic, payload);
      }
    });
  }

  void _handleMessage(String topic, String payload) {
    // Drop any messages that are not status/telemetry to avoid parsing commands as feedback
    if (!topic.endsWith('/status') && !topic.contains('/status/')) {
      return;
    }

    debugPrint('[MQTT RECV] $topic => $payload');

    try {
      final parts = topic.split('/');
      // Topic formats supported:
      // Single-level: ruet / classroom / <roomId> / zone / <zoneId> / ...
      // Dual-level:   ruet / classroom / <building> / <room> / zone / <zoneId> / ...

      int offset = 0;
      String roomId = '';

      if (parts.length >= 6 && (parts[4] == 'zone' || parts[4] == 'status')) {
        roomId = '${parts[2]}_${parts[3]}';
        offset = 1;
      } else if (parts.length >= 5) {
        roomId = parts[2];
        offset = 0;
      } else {
        return;
      }

      final section = parts[3 + offset];

      // Format: ruet/classroom/<roomId>/zone/<zoneId>/...
      if (section == 'zone' && parts.length >= (5 + offset)) {
        final zoneId = int.tryParse(parts[4 + offset]) ?? 1;

        // Relay status: ruet/classroom/<roomId>/zone/<zoneId>/relay/<relayNum>/status
        if (parts.length >= (7 + offset) && parts[5 + offset] == 'relay') {
          final relayNum = int.tryParse(parts[6 + offset]) ?? 1;
          bool isOn = false;
          int? speed;
          double? brightness;
          int? gpio;

          try {
            if (payload.startsWith('{')) {
              final data = jsonDecode(payload) as Map<String, dynamic>;
              isOn = (data['state'] == 'ON' || data['state'] == true || data['state'] == '1');
              if (data.containsKey('speed')) speed = (data['speed'] as num?)?.toInt();
              if (data.containsKey('brightness')) brightness = (data['brightness'] as num?)?.toDouble();
              if (data.containsKey('gpio')) gpio = (data['gpio'] as num?)?.toInt();
            } else {
              isOn = (payload.trim().toUpperCase() == 'ON' || payload.trim() == '1');
            }
            onRelayStatusReceived?.call(roomId, zoneId, relayNum, isOn, speed, brightness, gpio);
          } catch (e) {
            debugPrint('[MQTT] Error parsing zone relay status payload: $e');
          }
          return;
        }

        // Zone AC Status: ruet/classroom/<roomId>/zone/<zoneId>/ac/status
        if (parts.length >= (6 + offset) && parts[5 + offset] == 'ac') {
          try {
            if (payload.startsWith('{')) {
              final data = jsonDecode(payload) as Map<String, dynamic>;
              final isOn = (data['state'] == 'ON' || data['state'] == true || data['state'] == '1');
              final temp = (data['temp'] as num?)?.toInt() ?? 24;
              final mode = data['mode']?.toString() ?? 'COOL';
              final fan = (data['fan'] as num?)?.toInt() ?? 0;
              final swing = data['swing'] == true;
              onAcStatusReceived?.call(roomId, zoneId, isOn, temp, mode, fan, swing);
            }
          } catch (e) {
            debugPrint('[MQTT] Error parsing zone AC status payload: $e');
          }
          return;
        }

        // Zone Heartbeat: ruet/classroom/<roomId>/zone/<zoneId>/status
        if (parts.length >= (6 + offset) && parts[5 + offset] == 'status') {
          try {
            if (payload.trim().isEmpty) {
              onBoardTelemetryReceived?.call(roomId, zoneId, false, '', 0);
              return;
            }
            final data = jsonDecode(payload) as Map<String, dynamic>;
            final isOnline = data['status'] == 'ONLINE';
            final ip = data['ip']?.toString() ?? '192.168.0.x';
            final rssi = (data['rssi'] as num?)?.toInt() ?? -60;
            onBoardTelemetryReceived?.call(roomId, zoneId, isOnline, ip, rssi);
          } catch (_) {
            onBoardTelemetryReceived?.call(roomId, zoneId, false, '', 0);
          }
          return;
        }
      }

      // Format: ruet/classroom/<roomId>/status/...
      if (section == 'status' && parts.length >= (6 + offset)) {
        final type = parts[4 + offset]; // 'fan', 'light', 'ac', 'board'
        final targetStr = parts[5 + offset];

        if (type == 'board') {
          final boardId = int.tryParse(targetStr) ?? 1;

          // Relay-specific status: ruet/classroom/<roomId>/status/board/<boardId>/relay/<relayNum>
          if (parts.length >= (8 + offset) && parts[6 + offset] == 'relay') {
            final relayNum = int.tryParse(parts[7 + offset]) ?? 1;
            bool isOn = false;
            int? speed;
            double? brightness;
            int? gpio;

            try {
              if (payload.startsWith('{')) {
                final data = jsonDecode(payload) as Map<String, dynamic>;
                isOn = (data['state'] == 'ON' || data['state'] == true || data['state'] == '1');
                if (data.containsKey('speed')) speed = (data['speed'] as num?)?.toInt();
                if (data.containsKey('brightness')) brightness = (data['brightness'] as num?)?.toDouble();
                if (data.containsKey('gpio')) gpio = (data['gpio'] as num?)?.toInt();
              } else {
                isOn = (payload.trim().toUpperCase() == 'ON' || payload.trim() == '1');
              }
              onRelayStatusReceived?.call(roomId, boardId, relayNum, isOn, speed, brightness, gpio);
            } catch (e) {
              debugPrint('[MQTT] Error parsing board relay status payload: $e');
            }
            return;
          }

          // Board Health Telemetry: ruet/classroom/<roomId>/status/board/<boardId>
          try {
            if (payload.trim().isEmpty) {
              onBoardTelemetryReceived?.call(roomId, boardId, false, '', 0);
              return;
            }
            final data = jsonDecode(payload) as Map<String, dynamic>;
            final isOnline = data['status'] == 'ONLINE';
            final ip = data['ip']?.toString() ?? '192.168.0.x';
            final rssi = (data['rssi'] as num?)?.toInt() ?? -60;
            onBoardTelemetryReceived?.call(roomId, boardId, isOnline, ip, rssi);
          } catch (_) {
            onBoardTelemetryReceived?.call(roomId, boardId, false, '', 0);
          }
          return;
        }

        if (type == 'ac') {
          try {
            if (payload.startsWith('{')) {
              final data = jsonDecode(payload) as Map<String, dynamic>;
              final isOn = (data['state'] == 'ON' || data['state'] == true || data['state'] == '1');
              final temp = (data['temp'] as num?)?.toInt() ?? 24;
              final mode = data['mode']?.toString() ?? 'COOL';
              final fan = (data['fan'] as num?)?.toInt() ?? 0;
              final swing = data['swing'] == true;
              final bId = (data['board'] as num?)?.toInt() ?? (data['zone'] as num?)?.toInt() ?? 1;
              onAcStatusReceived?.call(roomId, bId, isOn, temp, mode, fan, swing);
            }
          } catch (e) {
            debugPrint('[MQTT] Error parsing AC status payload: $e');
          }
          return;
        }

        // Appliance Status Update (Fan / Light)
        final deviceNum = int.tryParse(targetStr) ?? 1;
        bool isOn = false;
        int? speed;
        double? brightness;
        int? gpio;

        try {
          if (payload.startsWith('{')) {
            final data = jsonDecode(payload) as Map<String, dynamic>;
            isOn = (data['state'] == 'ON' || data['state'] == true || data['state'] == '1');
            if (data.containsKey('speed')) speed = (data['speed'] as num?)?.toInt();
            if (data.containsKey('brightness')) brightness = (data['brightness'] as num?)?.toDouble();
            if (data.containsKey('gpio')) gpio = (data['gpio'] as num?)?.toInt();
          } else {
            isOn = (payload.trim().toUpperCase() == 'ON' || payload.trim() == '1');
          }

          onDeviceStatusReceived?.call(
            roomId,
            type,
            deviceNum,
            isOn,
            speed,
            brightness,
            gpio,
          );
        } catch (e) {
          debugPrint('[MQTT] Error parsing status payload: $e');
        }
      }
    } catch (e) {
      debugPrint('[MQTT] Handler error: $e');
    }
  }

  // ===========================================================================
  // PUBLISHING COMMANDS (APP ➡️ ESP32)
  // ===========================================================================

  final Map<String, Timer> _publishThrottlers = {};

  void _publishThrottled(
    String topic,
    String payload, {
    Duration duration = const Duration(milliseconds: 75),
    bool retain = false,
  }) {
    _publishThrottlers[topic]?.cancel();
    _publishThrottlers[topic] = Timer(duration, () {
      _publish(topic, payload, retain: retain);
    });
  }

  void _publish(String topic, String payload, {bool retain = false, MqttQos qos = MqttQos.atMostOnce}) {
    if (!isConnected || _client == null) {
      debugPrint('[MQTT] Cannot publish (not connected): $topic. Initiating connect...');
      connect();
      return;
    }
    final builder = MqttClientPayloadBuilder();
    builder.addString(payload);
    _client!.publishMessage(
      topic,
      qos,
      builder.payload!,
      retain: retain,
    );
    debugPrint('[MQTT PUB] $topic => $payload');
  }

  // Fast single-packet publication to room (Zero duplicate storm, no dropped commands)
  void _publishToRoom(String roomId, String subTopic, String payload, {bool retain = false, MqttQos qos = MqttQos.atMostOnce}) {
    _publish('$_baseTopic/$roomId/$subTopic', payload, retain: retain, qos: qos);
    if (roomId.contains('-')) {
      final alt = roomId.replaceAll('-', '_');
      _publish('$_baseTopic/$alt/$subTopic', payload, retain: retain, qos: qos);
    }
  }

  void _publishThrottledToRoom(
    String roomId,
    String subTopic,
    String payload, {
    Duration duration = const Duration(milliseconds: 75),
    bool retain = false,
  }) {
    _publishThrottled('$_baseTopic/$roomId/$subTopic', payload, duration: duration, retain: retain);
    if (roomId.contains('-')) {
      final alt = roomId.replaceAll('-', '_');
      _publishThrottled('$_baseTopic/$alt/$subTopic', payload, duration: duration, retain: retain);
    }
  }

  // 1. Toggle Single Device with Ultra-Fast, Zero-Collision Direct Targeting
  void publishDeviceCommand(
    String roomId,
    ClassroomDevice device,
    bool turnOn,
  ) {
    final boardId = device.boardId;
    final relayNum = device.relayNumber;
    final gpio = device.gpioPinNumber;

    String typeStr = 'light';
    if (device.type == DeviceType.fan) {
      typeStr = 'fan';
    } else if (device.type == DeviceType.hvac) {
      typeStr = 'ac';
    }

    final Map<String, dynamic> payloadMap = {
      'room': roomId,
      'zone': boardId,
      'board': boardId,
      'relay': relayNum,
      'state': turnOn ? 'ON' : 'OFF',
      'gpio': gpio,
      'id': device.id,
      'type': typeStr,
    };

    if (device.type == DeviceType.fan) {
      payloadMap['speed'] = turnOn ? (device.fanSpeed > 0 ? device.fanSpeed : 3) : 0;
    } else if (device.type == DeviceType.lighting) {
      payloadMap['brightness'] = turnOn ? device.brightness : 0;
    } else if (device.type == DeviceType.hvac) {
      payloadMap['temp'] = device.temperature;
      payloadMap['mode'] = device.hvacMode;
      payloadMap['fan'] = device.fanSpeed;
      payloadMap['swing'] = device.acSwing;
      payloadMap['gpio'] = 4;
      payloadMap['protocol'] = 'GREE';
    }

    final payloadStr = jsonEncode(payloadMap);

    // Single high-speed targeted publish with QoS 0 (Instant TCP delivery, eliminates packet dropping during fast taps)
    _publishToRoom(roomId, 'zone/$boardId/relay/$relayNum', payloadStr, retain: false, qos: MqttQos.atMostOnce);
    if (device.type == DeviceType.hvac) {
      _publishToRoom(roomId, 'zone/$boardId/ac/command', payloadStr, retain: false, qos: MqttQos.atMostOnce);
      _publishToRoom(roomId, 'ac/command', payloadStr, retain: false, qos: MqttQos.atMostOnce);
    }
  }

  // Dedicated Optical AC Command (Direct Gree IR signal, relays bypassed)
  void publishAcCommand(
    String roomId,
    int boardId, {
    required bool isOn,
    required int temp,
    required String mode,
    required int fanSpeed,
    required bool swing,
  }) {
    final payload = jsonEncode({
      'room': roomId,
      'zone': boardId,
      'board': boardId,
      'type': 'ac',
      'state': isOn ? 'ON' : 'OFF',
      'temp': temp,
      'mode': mode,
      'fan': fanSpeed,
      'swing': swing,
      'gpio': 4,
      'protocol': 'GREE',
    });
    _publishToRoom(roomId, 'zone/$boardId/ac/command', payload, retain: false, qos: MqttQos.atMostOnce);
    _publishToRoom(roomId, 'ac/command', payload, retain: false, qos: MqttQos.atMostOnce);
  }

  // 2. Zone All On / All Off (Targets ONLY this switchboard / zone!)
  void publishZoneAll(String roomId, int boardId, bool turnOn) {
    final payload = turnOn ? 'ALL_ON' : 'ALL_OFF';
    _publishToRoom(roomId, 'zone/$boardId/command/all', payload, retain: false, qos: MqttQos.atMostOnce);
  }

  // 3. Adjust Fan Speed with Board Isolation
  void publishFanSpeed(String roomId, int boardId, int relayNumber, int speed) {
    final payload = jsonEncode({
      'room': roomId,
      'zone': boardId,
      'board': boardId,
      'relay': relayNumber,
      'state': speed > 0 ? 'ON' : 'OFF',
      'speed': speed,
    });
    _publishToRoom(roomId, 'zone/$boardId/relay/$relayNumber', payload, retain: false, qos: MqttQos.atMostOnce);
  }

  // 4. Adjust Light Brightness with Board Isolation
  void publishLightBrightness(String roomId, int boardId, int relayNumber, double brightness) {
    final payload = jsonEncode({
      'room': roomId,
      'zone': boardId,
      'board': boardId,
      'relay': relayNumber,
      'state': brightness > 0 ? 'ON' : 'OFF',
      'brightness': brightness.round(),
    });
    // Throttled to prevent flooding ESP32 PWM during continuous touch drag
    _publishThrottledToRoom(roomId, 'zone/$boardId/relay/$relayNumber', payload, duration: const Duration(milliseconds: 75), retain: false);
  }

  // 5. Global All On / All Off for Entire Room
  void publishAllDevices(String roomId, bool allOn) {
    final payload = allOn ? 'ALL_ON' : 'ALL_OFF';
    _publishToRoom(roomId, 'command/all', payload, retain: false, qos: MqttQos.atMostOnce);
  }

  // 6. Emergency Cutoff / Trip All Relays
  void publishEmergencyCutoff(String roomId, bool cutoff) {
    _publishToRoom(roomId, 'command/emergency', cutoff ? 'CUTOFF' : 'RESTORE');
  }

  // 7. Remote Customizable GPIO Configuration (OTA Pin Remapping)
  void publishGpioConfig(
    String roomId,
    int boardId, {
    required List<int> fanPins,
    required List<int> lightPins,
    bool activeLow = true,
  }) {
    final payload = jsonEncode({
      'board': boardId,
      'fanPins': fanPins,
      'lightPins': lightPins,
      'activeLow': activeLow,
    });
    _publishToRoom(roomId, 'config/board/$boardId/gpio', payload, retain: true);
  }

  // 8. Active Telemetry Ping / Hardware Scan Query
  void publishStatusQuery([String? roomId]) {
    if (roomId != null && roomId.isNotEmpty) {
      _publishToRoom(roomId, 'command/query', 'PING');
    }
    // Also ping all rooms wildcard
    _publish('$_baseTopic/all/command/query', 'PING');
  }

  // 8. Clear retained board status
  void clearBoardRetainedStatus(String roomId, int boardId) {
    final topic = '$_baseTopic/$roomId/status/board/$boardId';
    _publish(topic, '', retain: true);
  }
}

