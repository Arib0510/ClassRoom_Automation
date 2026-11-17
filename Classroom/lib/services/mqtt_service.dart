import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/device.dart';

enum MqttConnectionStatus { disconnected, connecting, connected, error }

class MqttService {
  static final MqttService _instance = MqttService._internal();
  factory MqttService() => _instance;

  MqttService._internal();

  @visibleForTesting
  static bool isFreshVisionState(
    Map<String, dynamic> data, {
    required int nowMs,
  }) {
    final occupancy = data['occupancy'];
    if (data['status'] == 'OFFLINE' ||
        data['online'] == false ||
        occupancy is Map &&
            (occupancy['status'] == 'OFFLINE' ||
                occupancy['online'] == false)) {
      return true;
    }
    final sentAt = data['sent_at_unix_ms'];
    if (sentAt is! num || sentAt > nowMs + 3000) return false;
    final expiresAt = data['expires_at_unix_ms'];
    final freshness = data['freshness_seconds'];
    if (expiresAt is num) {
      return nowMs <= expiresAt &&
          (freshness is! num || nowMs - sentAt <= freshness * 1000);
    }
    return freshness is num &&
        freshness > 0 &&
        nowMs - sentAt <= freshness * 1000;
  }

  MqttServerClient? _client;

  static const String _kBrokerKey = 'classpulse_mqtt_broker_v1';
  static const String _kPortKey = 'classpulse_mqtt_port_v1';
  static const String _kTopicKey = 'classpulse_mqtt_topic_v1';
  static const String _kUserKey = 'classpulse_mqtt_user_v1';
  static const String _kPassKey = 'classpulse_mqtt_pass_v1';

  // Deployment-specific host & optional credentials are supplied at build time or persisted locally.
  String _broker = const String.fromEnvironment(
    'MQTT_BROKER_HOST',
    defaultValue: '10.247.68.155',
  );
  int _port = int.tryParse(
        const String.fromEnvironment('MQTT_PORT', defaultValue: '1883'),
      ) ??
      1883;
  String _baseTopic = 'ruet/classroom';
  String _username = const String.fromEnvironment(
    'MQTT_USERNAME',
    defaultValue: 'flutter-app',
  );
  String _password = const String.fromEnvironment(
    'MQTT_PASSWORD',
    defaultValue: '',
  );
  bool _configLoaded = false;

  String get broker => _broker;
  int get port => _port;
  String get baseTopic => _baseTopic;
  String get username => _username;
  String get password => _password;
  bool get hasCredentials => _username.isNotEmpty && _password.isNotEmpty;

  MqttConnectionStatus _status = MqttConnectionStatus.disconnected;
  MqttConnectionStatus get status => _status;
  bool get isConnected =>
      _status == MqttConnectionStatus.connected &&
      _client?.connectionStatus?.state == MqttConnectionState.connected;
  bool _explicitDisconnect = false;
  Timer? _reconnectTimer;
  Completer<bool>? _connectCompleter;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _updatesSub;
  String? _pendingDiscoveryRoomId;

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
  )?
  onDeviceStatusReceived;

  // Board telemetry callback: (roomId, boardId, isOnline, ip, rssi)
  void Function(String roomId, int boardId, bool isOnline, String ip, int rssi)?
  onBoardTelemetryReceived;

  // Unified MQTT Discovery callback (`home/discovery`): (zoneId, deviceType, ip, roomId, rssi, isOnline)
  void Function(
    String zoneId,
    String deviceType,
    String ip,
    String roomId,
    int rssi,
    bool isOnline,
  )?
  onDiscoveryReceived;

  // Switchboard-isolated relay status callback: (roomId, boardId, relayNumber, isOn, speed, brightness, gpio)
  void Function(
    String roomId,
    int boardId,
    int relayNumber,
    bool isOn,
    int? speed,
    double? brightness,
    int? gpio,
  )?
  onRelayStatusReceived;

  // Optical AC status callback: (roomId, boardId, isOn, temp, mode, fan, swing)
  void Function(
    String roomId,
    int boardId,
    bool isOn,
    int temp,
    String mode,
    int fan,
    bool swing,
  )?
  onAcStatusReceived;

  // Phase 5 AppBridge Callbacks:
  // App result callback: (roomId, requestId, result, reason)
  void Function(String roomId, String requestId, String result, String reason)?
  onAppResultReceived;

  // Unified App State snapshot callback: (roomId, occupancyMap, appliancesMap)
  void Function(
    String roomId,
    Map<String, dynamic> occupancy,
    Map<String, dynamic> appliances,
  )?
  onAppStateReceived;

  Future<void> loadSavedConfig() async {
    if (_configLoaded) return;
    _configLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedBroker = prefs.getString(_kBrokerKey);
      final savedPort = prefs.getInt(_kPortKey);
      final savedTopic = prefs.getString(_kTopicKey);
      final savedUser = prefs.getString(_kUserKey);
      final savedPass = prefs.getString(_kPassKey);
      if (savedBroker != null && savedBroker.trim().isNotEmpty) {
        _broker = savedBroker.trim();
      }
      if (savedPort != null && savedPort > 0) {
        _port = savedPort;
      }
      if (savedTopic != null && savedTopic.trim().isNotEmpty) {
        _baseTopic = savedTopic.trim();
      }
      if (savedUser != null && savedUser.trim().isNotEmpty) {
        _username = savedUser.trim();
      }
      if (savedPass != null && savedPass.isNotEmpty) {
        _password = savedPass;
      }
    } catch (_) {}
  }

  Future<void> _saveConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kBrokerKey, _broker);
      await prefs.setInt(_kPortKey, _port);
      await prefs.setString(_kTopicKey, _baseTopic);
      await prefs.setString(_kUserKey, _username);
      await prefs.setString(_kPassKey, _password);
    } catch (_) {}
  }

  void configure({
    String? broker,
    int? port,
    String? baseTopic,
    String? username,
    String? password,
    bool persist = true,
  }) {
    _configLoaded = true;
    if (broker != null && broker.trim().isNotEmpty) _broker = broker.trim();
    if (port != null && port > 0) _port = port;
    if (baseTopic != null && baseTopic.trim().isNotEmpty) {
      _baseTopic = baseTopic.trim();
    }
    if (username != null) _username = username.trim();
    if (password != null) _password = password.trim();
    if (persist) {
      _saveConfig();
    }
  }

  Future<bool> connect() async {
    _explicitDisconnect = false;
    if (isConnected) return true;
    if (_connectCompleter != null && !_connectCompleter!.isCompleted) {
      return _connectCompleter!.future;
    }

    final completer = Completer<bool>();
    _connectCompleter = completer;
    _reconnectTimer?.cancel();
    _disconnectInternal();
    _setStatus(MqttConnectionStatus.connecting);
    await loadSavedConfig();

    final clientId =
        'ClassPulseApp_${DateTime.now().millisecondsSinceEpoch}_${(100 + (DateTime.now().microsecond % 900))}';

    final client = MqttServerClient.withPort(_broker, clientId, _port);
    client.logging(on: false);
    client.keepAlivePeriod = 20;
    client.connectTimeoutPeriod = 6000;
    // Manage reconnects deterministically so every reconnect re-subscribes & attaches updates cleanly.
    client.autoReconnect = false;
    client.setProtocolV311();
    client.onDisconnected = _onDisconnected;
    client.onConnected = _onConnected;
    client.onSubscribed = _onSubscribed;
    _client = client;

    final connMess = MqttConnectMessage()
        .withClientIdentifier(clientId)
        .startClean();

    if (_username.isEmpty || _password.isEmpty) {
      _setStatus(MqttConnectionStatus.error);
      if (!completer.isCompleted) completer.complete(false);
      return false;
    }
    connMess.authenticateAs(_username, _password);
    client.connectionMessage = connMess;

    try {
      debugPrint('[MQTT] Connecting to $_broker:$_port as $clientId...');
      await client.connect();
    } catch (e) {
      debugPrint('[MQTT] Exception during connect: $e');
      _disconnectInternal();
      _setStatus(MqttConnectionStatus.error);
      _scheduleReconnect();
      if (!completer.isCompleted) completer.complete(false);
      return false;
    }

    if (client.connectionStatus?.state == MqttConnectionState.connected) {
      _setStatus(MqttConnectionStatus.connected);
      _subscribeTopics();
      _listenIncomingMessages();
      _flushPendingDiscovery();
      if (!completer.isCompleted) completer.complete(true);
      return true;
    } else {
      debugPrint(
        '[MQTT] Connection failed with state: ${client.connectionStatus?.state}',
      );
      _disconnectInternal();
      _setStatus(MqttConnectionStatus.error);
      _scheduleReconnect();
      if (!completer.isCompleted) completer.complete(false);
      return false;
    }
  }

  Future<void> ensureConnectedAndSync([String roomId = 'reb_room_301']) async {
    _pendingDiscoveryRoomId = roomId;
    if (isConnected) {
      publishStatusQuery(roomId);
      return;
    }
    final ok = await connect();
    if (ok) {
      publishStatusQuery(roomId);
    }
  }

  void _flushPendingDiscovery() {
    final pendingRoom = _pendingDiscoveryRoomId;
    if (pendingRoom != null && pendingRoom.isNotEmpty) {
      _pendingDiscoveryRoomId = null;
      Timer(const Duration(milliseconds: 200), () {
        if (isConnected) {
          publishStatusQuery(pendingRoom);
        }
      });
    }
  }

  void _scheduleReconnect() {
    if (_explicitDisconnect) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 2), () {
      if (!isConnected && _status != MqttConnectionStatus.connecting) {
        connect();
      }
    });
  }

  void _setStatus(MqttConnectionStatus s) {
    _status = s;
    _statusController.add(s);
  }

  void _onConnected() {
    debugPrint('[MQTT] Connected successfully to $_broker:$_port as $_username');
    _setStatus(MqttConnectionStatus.connected);
    // Query actual live hardware states from all active ESP32 switchboards
    Timer(const Duration(milliseconds: 350), () {
      requestHardwareSync();
    });
  }

  void requestHardwareSync([String roomId = 'reb_room_301']) {
    if (!isConnected) {
      _pendingDiscoveryRoomId = roomId;
      connect();
      return;
    }
    _publish('home/discovery/query', 'QUERY', retain: false);
    _publish('$_baseTopic/$roomId/command/query', 'QUERY', retain: false);
    debugPrint('[MQTT] Hardware sync & discovery queried for room: $roomId');
  }

  // Deletes old retained status records in the migrated room only.
  void clearLegacyRetainedStatus([String roomId = 'reb_room_301']) {
    try {
      final rooms = [roomId];
      for (final r in rooms) {
        for (int b = 1; b <= 4; b++) {
          _publish('$_baseTopic/$r/status/board/$b', '', retain: true);
          _publish('$_baseTopic/$r/zone/$b/status', '', retain: true);
          for (int rel = 1; rel <= 4; rel++) {
            _publish(
              '$_baseTopic/$r/status/board/$b/relay/$rel',
              '',
              retain: true,
            );
            _publish(
              '$_baseTopic/$r/zone/$b/relay/$rel/status',
              '',
              retain: true,
            );
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
    _updatesSub?.cancel();
    _updatesSub = null;
    _setStatus(MqttConnectionStatus.disconnected);
    _scheduleReconnect();
  }

  void _onSubscribed(String topic) {
    debugPrint('[MQTT] Subscribed to topic: $topic');
  }

  void _disconnectInternal() {
    _updatesSub?.cancel();
    _updatesSub = null;
    try {
      _client?.disconnect();
    } catch (_) {}
    _client = null;
  }

  void disconnect() {
    _explicitDisconnect = true;
    _reconnectTimer?.cancel();
    _disconnectInternal();
    _setStatus(MqttConnectionStatus.disconnected);
  }

  void _subscribeTopics() {
    if (!isConnected || _client == null) return;

    // 1. Unified MQTT Discovery Topic (`home/discovery`) for Zones 1-3 and Standalone AC (`zone_ac`)
    _client!.subscribe('home/discovery', MqttQos.atLeastOnce);
    _client!.subscribe('$_baseTopic/+/discovery', MqttQos.atLeastOnce);
    _client!.subscribe('$_baseTopic/+/+/discovery', MqttQos.atLeastOnce);
    _client!.subscribe('home/+/relay/+/status', MqttQos.atLeastOnce);
    _client!.subscribe('home/zone_ac/status', MqttQos.atLeastOnce);
    _client!.subscribe('$_baseTopic/+/vision/control', MqttQos.atLeastOnce);
    _client!.subscribe('classpulse/+/vision/control', MqttQos.atLeastOnce);

    // 2. Listen strictly to physical switchboard telemetry & relay status channels (Relays 1-8)
    _client!.subscribe('$_baseTopic/+/zone/+/status', MqttQos.atLeastOnce);
    _client!.subscribe('$_baseTopic/+/+/zone/+/status', MqttQos.atLeastOnce);
    _client!.subscribe(
      '$_baseTopic/+/zone/+/relay/+/status',
      MqttQos.atLeastOnce,
    );
    _client!.subscribe(
      '$_baseTopic/+/+/zone/+/relay/+/status',
      MqttQos.atLeastOnce,
    );
    _client!.subscribe('$_baseTopic/+/status/board/+', MqttQos.atLeastOnce);
    _client!.subscribe('$_baseTopic/+/+/status/board/+', MqttQos.atLeastOnce);
    _client!.subscribe(
      '$_baseTopic/+/status/board/+/relay/+',
      MqttQos.atLeastOnce,
    );
    _client!.subscribe(
      '$_baseTopic/+/+/status/board/+/relay/+',
      MqttQos.atLeastOnce,
    );

    // 3. Standalone AC status telemetry
    _client!.subscribe('$_baseTopic/+/zone/+/ac/status', MqttQos.atLeastOnce);
    _client!.subscribe('$_baseTopic/+/+/zone/+/ac/status', MqttQos.atLeastOnce);
    _client!.subscribe('$_baseTopic/+/status/ac', MqttQos.atLeastOnce);
    _client!.subscribe('$_baseTopic/+/+/status/ac', MqttQos.atLeastOnce);
    _client!.subscribe('$_baseTopic/+/status/board/+/ac', MqttQos.atLeastOnce);
    _client!.subscribe(
      '$_baseTopic/+/+/status/board/+/ac',
      MqttQos.atLeastOnce,
    );

    // 4. Listen to configuration acknowledgements
    _client!.subscribe('$_baseTopic/+/config/ack', MqttQos.atLeastOnce);
    _client!.subscribe('$_baseTopic/+/+/config/ack', MqttQos.atLeastOnce);

    // 5. Phase 5 AppBridge (Decision Maker Telemetry & Results)
    _client!.subscribe('$_baseTopic/+/app/results', MqttQos.atLeastOnce);
    _client!.subscribe('$_baseTopic/+/+/app/results', MqttQos.atLeastOnce);
    _client!.subscribe('$_baseTopic/+/app/state', MqttQos.atLeastOnce);
    _client!.subscribe('$_baseTopic/+/+/app/state', MqttQos.atLeastOnce);
    _client!.subscribe('classpulse/+/app/results', MqttQos.atLeastOnce);
    _client!.subscribe('classpulse/+/app/state', MqttQos.atLeastOnce);
  }

  void _listenIncomingMessages() {
    _updatesSub?.cancel();
    _updatesSub = _client?.updates?.listen((List<MqttReceivedMessage<MqttMessage>> messages) {
      for (final msg in messages) {
        final recMess = msg.payload as MqttPublishMessage;
        final isRetained = recMess.header?.retain ?? false;
        final topic = msg.topic;
        final payload = MqttPublishPayload.bytesToStringAsString(
          recMess.payload.message,
        );

        // STALE RETAINED MESSAGE INTERCEPTOR:
        // Retained messages must NEVER overwrite
        // active user states or mimic phantom hardware toggles.
        if (isRetained) {
          if (payload.isEmpty) continue;
          if (topic.endsWith('/app/state')) {
            if (_isOfflineState(payload)) {
              _handleMessage(topic, payload);
            } else {
              _handleMessage(topic, payload);
            }
            continue;
          }
          // Process retained board availability / LWT and reported hardware status.
          if (topic.endsWith('/status') || topic.contains('/status/')) {
            _handleMessage(topic, payload);
            continue;
          }
          // Never execute or keep stale retained control commands.
          debugPrint(
            '[MQTT] Discarding stale retained command on $topic - purging from broker',
          );
          _publish(topic, '', retain: true);
          continue;
        }

        _handleMessage(topic, payload);
      }
    });
  }

  bool _isOfflineState(String payload) {
    try {
      final data = jsonDecode(payload) as Map<String, dynamic>;
      final occupancy = data['occupancy'];
      return data['status'] == 'OFFLINE' ||
          data['online'] == false ||
          occupancy is Map &&
              (occupancy['status'] == 'OFFLINE' ||
                  occupancy['online'] == false);
    } catch (_) {
      return false;
    }
  }

  void _handleMessage(String topic, String payload) {
    // Phase 5 AppBridge Ingress Handling:
    if (topic.endsWith('/app/results')) {
      try {
        final data = jsonDecode(payload) as Map<String, dynamic>;
        final reqId = data['request_id']?.toString() ?? '';
        final res = data['result']?.toString() ?? '';
        final reason = data['reason']?.toString() ?? '';
        final parts = topic.split('/');
        final rId = parts.length >= 3 ? parts[parts.length - 3] : 'room';
        debugPrint('[MQTT APP RESULT] $rId -> $reqId: $res ($reason)');
        onAppResultReceived?.call(rId, reqId, res, reason);
      } catch (e) {
        debugPrint('[MQTT] Error parsing app result: $e');
      }
      return;
    }

    if (topic.endsWith('/app/state')) {
      try {
        final data = jsonDecode(payload) as Map<String, dynamic>;
        final occ = (data['occupancy'] as Map<String, dynamic>?) ?? {};
        final apps = (data['appliances'] as Map<String, dynamic>?) ?? {};
        if (!isFreshVisionState(
          data,
          nowMs: DateTime.now().millisecondsSinceEpoch,
        )) {
          debugPrint(
            '[MQTT] Ignoring stale or un-timestamped vision state on $topic',
          );
          return;
        }
        final parts = topic.split('/');
        final rId = parts.length >= 3 ? parts[parts.length - 3] : 'room';
        debugPrint(
          '[MQTT APP STATE] $rId state snapshot received with ${occ.length} zones, ${apps.length} appliances',
        );
        onAppStateReceived?.call(rId, occ, apps);
      } catch (e) {
        debugPrint('[MQTT] Error parsing app state: $e');
      }
      return;
    }

    // Unified Discovery Handling (`home/discovery` & `/discovery`):
    if (topic == 'home/discovery' || topic.endsWith('/discovery')) {
      try {
        if (payload.trim().startsWith('{')) {
          final data = jsonDecode(payload) as Map<String, dynamic>;
          final zoneId =
              data['zone_id']?.toString() ??
              (data['zone'] != null ? 'zone_${data['zone']}' : 'zone_1');
          final deviceType =
              data['device_type']?.toString() ??
              (zoneId == 'zone_ac' ? 'ac_unit' : 'switchboard');
          final ip = data['ip']?.toString() ?? '192.168.1.x';
          final roomId = data['room']?.toString() ?? 'reb_room_301';
          final rssi = (data['rssi'] as num?)?.toInt() ?? -55;
          final isOnline =
              (data['status']?.toString() ?? 'ONLINE').toUpperCase() !=
              'OFFLINE';

          debugPrint(
            '[MQTT DISCOVERY] zone_id=$zoneId, device_type=$deviceType, ip=$ip, room=$roomId',
          );
          onDiscoveryReceived?.call(
            zoneId,
            deviceType,
            ip,
            roomId,
            rssi,
            isOnline,
          );

          if (deviceType == 'ac_unit' || zoneId == 'zone_ac') {
            if (data.containsKey('state')) {
              final isOn =
                  data['state'] == 'ON' ||
                  data['state'] == true ||
                  data['state'] == '1';
              final temp = (data['temp'] as num?)?.toInt() ?? 24;
              final mode = data['mode']?.toString() ?? 'COOL';
              onAcStatusReceived?.call(roomId, 4, isOn, temp, mode, 0, false);
            }
          }
        }
      } catch (e) {
        debugPrint('[MQTT] Error parsing discovery payload: $e');
      }
      return;
    }

    // Home Standalone Dual-AC Status (`home/zone_ac/status`)
    if (topic == 'home/zone_ac/status') {
      try {
        if (payload.trim().startsWith('{')) {
          final data = jsonDecode(payload) as Map<String, dynamic>;
          final roomId = data['room']?.toString() ?? 'reb_room_301';
          final isOn =
              data['state'] == 'ON' ||
              data['state'] == true ||
              data['state'] == '1';
          final temp = (data['temp'] as num?)?.toInt() ?? 24;
          final mode = data['mode']?.toString() ?? 'COOL';
          final fan = (data['fan'] as num?)?.toInt() ?? 0;
          final swing = data['swing'] == true;
          final gpio = (data['gpio'] as num?)?.toInt();
          final acUnit =
              (data['ac_unit'] as num?)?.toInt() ??
              (gpio == 12 ? 2 : ((data['zone'] as num?)?.toInt() ?? 1));
          onAcStatusReceived?.call(
            roomId,
            acUnit,
            isOn,
            temp,
            mode,
            fan,
            swing,
          );
        }
      } catch (e) {
        debugPrint('[MQTT] Error parsing home/zone_ac/status: $e');
      }
      return;
    }

    // Home Switchboard Relay Status (`home/zone_<id>/relay/<num>/status`)
    if (topic.startsWith('home/zone_') &&
        topic.endsWith('/status') &&
        topic.contains('/relay/')) {
      try {
        final parts = topic.split('/');
        // home / zone_1 / relay / 1 / status
        if (parts.length >= 5) {
          final zoneStr = parts[1];
          final bId =
              int.tryParse(zoneStr.replaceAll(RegExp(r'[^0-9]'), '')) ?? 1;
          final relayNum = int.tryParse(parts[3]) ?? 1;
          if (payload.trim().startsWith('{')) {
            final data = jsonDecode(payload) as Map<String, dynamic>;
            final roomId = data['room']?.toString() ?? 'reb_room_301';
            final isOn =
                data['state'] == 'ON' ||
                data['state'] == true ||
                data['state'] == '1';
            final speed = (data['speed'] as num?)?.toInt();
            final brightness = (data['brightness'] as num?)?.toDouble();
            final gpio = (data['gpio'] as num?)?.toInt();
            onRelayStatusReceived?.call(
              roomId,
              bId,
              relayNum,
              isOn,
              speed,
              brightness,
              gpio,
            );
          }
        }
      } catch (e) {
        debugPrint('[MQTT] Error parsing home relay status: $e');
      }
      return;
    }

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
        final rawZonePart = parts[4 + offset];
        final isAcZone =
            rawZonePart.toLowerCase() == 'ac' || rawZonePart == '4';
        final zoneId = isAcZone ? 4 : (int.tryParse(rawZonePart) ?? 1);

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
              isOn =
                  (data['state'] == 'ON' ||
                  data['state'] == true ||
                  data['state'] == '1');
              if (data.containsKey('speed')) {
                speed = (data['speed'] as num?)?.toInt();
              }
              if (data.containsKey('brightness')) {
                brightness = (data['brightness'] as num?)?.toDouble();
              }
              if (data.containsKey('gpio')) {
                gpio = (data['gpio'] as num?)?.toInt();
              }
            } else {
              isOn =
                  (payload.trim().toUpperCase() == 'ON' ||
                  payload.trim() == '1');
            }
            onRelayStatusReceived?.call(
              roomId,
              zoneId,
              relayNum,
              isOn,
              speed,
              brightness,
              gpio,
            );
          } catch (e) {
            debugPrint('[MQTT] Error parsing zone relay status payload: $e');
          }
          return;
        }

        // Zone AC Status: ruet/classroom/<roomId>/zone/<zoneId>/ac/status or .../zone/ac/status
        if ((parts.length >= (6 + offset) && parts[5 + offset] == 'ac') ||
            (isAcZone &&
                parts.length >= (6 + offset) &&
                parts[5 + offset] == 'status')) {
          try {
            if (payload.startsWith('{')) {
              final data = jsonDecode(payload) as Map<String, dynamic>;
              final isOn =
                  (data['state'] == 'ON' ||
                  data['state'] == true ||
                  data['state'] == '1');
              final temp = (data['temp'] as num?)?.toInt() ?? 24;
              final mode = data['mode']?.toString() ?? 'COOL';
              final fan = (data['fan'] as num?)?.toInt() ?? 0;
              final swing = data['swing'] == true;
              onAcStatusReceived?.call(
                roomId,
                zoneId,
                isOn,
                temp,
                mode,
                fan,
                swing,
              );
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
            final isOnline = data['online'] == true ||
                data['status']?.toString().toUpperCase() == 'ONLINE';
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
                isOn =
                    (data['state'] == 'ON' ||
                    data['state'] == true ||
                    data['state'] == '1');
                if (data.containsKey('speed')) {
                  speed = (data['speed'] as num?)?.toInt();
                }
                if (data.containsKey('brightness')) {
                  brightness = (data['brightness'] as num?)?.toDouble();
                }
                if (data.containsKey('gpio')) {
                  gpio = (data['gpio'] as num?)?.toInt();
                }
              } else {
                isOn =
                    (payload.trim().toUpperCase() == 'ON' ||
                    payload.trim() == '1');
              }
              onRelayStatusReceived?.call(
                roomId,
                boardId,
                relayNum,
                isOn,
                speed,
                brightness,
                gpio,
              );
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
            final isOnline = data['online'] == true ||
                data['status']?.toString().toUpperCase() == 'ONLINE';
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
              final isOn =
                  (data['state'] == 'ON' ||
                  data['state'] == true ||
                  data['state'] == '1');
              final temp = (data['temp'] as num?)?.toInt() ?? 24;
              final mode = data['mode']?.toString() ?? 'COOL';
              final fan = (data['fan'] as num?)?.toInt() ?? 0;
              final swing = data['swing'] == true;
              final bId =
                  (data['board'] as num?)?.toInt() ??
                  (data['zone'] as num?)?.toInt() ??
                  1;
              onAcStatusReceived?.call(
                roomId,
                bId,
                isOn,
                temp,
                mode,
                fan,
                swing,
              );
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
            isOn =
                (data['state'] == 'ON' ||
                data['state'] == true ||
                data['state'] == '1');
            if (data.containsKey('speed')) {
              speed = (data['speed'] as num?)?.toInt();
            }
            if (data.containsKey('brightness')) {
              brightness = (data['brightness'] as num?)?.toDouble();
            }
            if (data.containsKey('gpio')) {
              gpio = (data['gpio'] as num?)?.toInt();
            }
          } else {
            isOn =
                (payload.trim().toUpperCase() == 'ON' || payload.trim() == '1');
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

  void _publish(
    String topic,
    String payload, {
    bool retain = false,
    MqttQos qos = MqttQos.atMostOnce,
  }) {
    if (!isConnected || _client == null) {
      debugPrint(
        '[MQTT] Cannot publish (not connected): $topic. Initiating connect...',
      );
      connect();
      return;
    }
    try {
      final builder = MqttClientPayloadBuilder();
      builder.addString(payload);
      _client!.publishMessage(topic, qos, builder.payload!, retain: retain);
      debugPrint('[MQTT PUB] $topic => $payload');
    } catch (e) {
      debugPrint('[MQTT] Publish failed ($topic): $e. Reconnecting...');
      _disconnectInternal();
      _setStatus(MqttConnectionStatus.disconnected);
      connect();
    }
  }

  // Fast single-packet publication to room (Zero duplicate storm, no dropped commands)
  void _publishToRoom(
    String roomId,
    String subTopic,
    String payload, {
    bool retain = false,
    MqttQos qos = MqttQos.atMostOnce,
  }) {
    _publish(
      '$_baseTopic/$roomId/$subTopic',
      payload,
      retain: retain,
      qos: qos,
    );
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
    _publishThrottled(
      '$_baseTopic/$roomId/$subTopic',
      payload,
      duration: duration,
      retain: retain,
    );
    if (roomId.contains('-')) {
      final alt = roomId.replaceAll('-', '_');
      _publishThrottled(
        '$_baseTopic/$alt/$subTopic',
        payload,
        duration: duration,
        retain: retain,
      );
    }
  }

  // ===========================================================================
  // PHASE 5 APP INGRESS REQUEST (FLUTTER ➡️ PI DECISION ENGINE)
  // ===========================================================================
  void publishAppRequest(
    String roomId, {
    required String applianceId,
    required String desiredState, // 'ON', 'OFF', 'AUTO'
    double durationSeconds = 300.0,
    String? requestId,
  }) {
    final reqId = requestId ?? 'req-${DateTime.now().millisecondsSinceEpoch}';
    final payload = jsonEncode({
      'request_id': reqId,
      'appliance_id': applianceId,
      'desired_state': desiredState.toUpperCase(),
      'duration_seconds': durationSeconds,
      'operator': 'classpulse_flutter_user',
      'sent_at_unix_ms': DateTime.now().millisecondsSinceEpoch,
    });

    _publishToRoom(
      roomId,
      'app/requests',
      payload,
      retain: false,
      qos: MqttQos.atLeastOnce,
    );
    _publish(
      'classpulse/$roomId/app/requests',
      payload,
      retain: false,
      qos: MqttQos.atLeastOnce,
    );
    debugPrint(
      '[MQTT APP REQ] $roomId -> $applianceId desired: $desiredState (reqId: $reqId)',
    );
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
      'zone_id': device.type == DeviceType.hvac ? 'zone_ac' : 'zone_$boardId',
      'device_type': device.type == DeviceType.hvac ? 'ac_unit' : 'switchboard',
      'zone': boardId,
      'board': boardId,
      'relay': relayNum,
      'state': turnOn ? 'ON' : 'OFF',
      'gpio': gpio,
      'id': device.id,
      'type': typeStr,
      'cmd_id': 'cmd-${DateTime.now().millisecondsSinceEpoch}',
      'sent_at_unix_ms': DateTime.now().millisecondsSinceEpoch,
    };

    if (device.type == DeviceType.fan) {
      payloadMap['speed'] = turnOn
          ? (device.fanSpeed > 0 ? device.fanSpeed : 3)
          : 0;
    } else if (device.type == DeviceType.lighting) {
      payloadMap['brightness'] = turnOn ? device.brightness : 0;
    } else if (device.type == DeviceType.hvac) {
      final acGpio =
          device.gpioPinNumber; // GPIO 33 (Gree AC #1) or GPIO 12 (Gree AC #2)
      final acUnit = acGpio == 12 ? 2 : 1;
      payloadMap['ac_unit'] = acUnit;
      payloadMap['zone'] = acUnit;
      payloadMap['board'] = acUnit;
      payloadMap['temp'] = device.temperature;
      payloadMap['mode'] = device.hvacMode;
      payloadMap['fan'] = device.fanSpeed;
      payloadMap['swing'] = device.acSwing;
      payloadMap['gpio'] = acGpio;
      payloadMap['protocol'] = 'GREE';
    }

    final payloadStr = jsonEncode(payloadMap);

    if (device.type == DeviceType.hvac) {
      final acUnit = device.gpioPinNumber == 12 ? 2 : 1;
      // Standalone Dual-AC IR Controller (`zone_ac`: AC #1 on GPIO 33, AC #2 on GPIO 12)
      _publishToRoom(
        roomId,
        'ac/$acUnit/command',
        payloadStr,
        retain: false,
        qos: MqttQos.atLeastOnce,
      );
      _publishToRoom(
        roomId,
        'zone/$acUnit/ac/command',
        payloadStr,
        retain: false,
        qos: MqttQos.atLeastOnce,
      );
      _publishToRoom(
        roomId,
        'ac/command',
        payloadStr,
        retain: false,
        qos: MqttQos.atLeastOnce,
      );
      _publish(
        'home/zone_ac/command',
        payloadStr,
        retain: false,
        qos: MqttQos.atLeastOnce,
      );
    } else {
      // 8-Switch Zone Switchboard (Zones 1, 2, 3, Relays 1..8)
      _publishToRoom(
        roomId,
        'zone/$boardId/relay/$relayNum',
        payloadStr,
        retain: false,
        qos: MqttQos.atLeastOnce,
      );
      _publish(
        'home/zone_$boardId/relay/$relayNum',
        payloadStr,
        retain: false,
        qos: MqttQos.atLeastOnce,
      );
    }
  }

  // Dedicated Standalone Dual-AC IR Command (Gree AC #1 on GPIO 33, Gree AC #2 on GPIO 12)
  void publishAcCommand(
    String roomId,
    int acUnitOrBoardId, {
    required bool isOn,
    required int temp,
    required String mode,
    required int fanSpeed,
    required bool swing,
    int? irGpio,
  }) {
    final int unitNum = (irGpio == 12 || acUnitOrBoardId == 2) ? 2 : 1;
    final int resolvedGpio = irGpio ?? (unitNum == 2 ? 12 : 33);
    final payload = jsonEncode({
      'room': roomId,
      'zone_id': 'zone_ac',
      'device_type': 'ac_unit',
      'ac_unit': unitNum,
      'zone': unitNum,
      'board': unitNum,
      'type': 'ac',
      'state': isOn ? 'ON' : 'OFF',
      'temp': temp,
      'mode': mode,
      'fan': fanSpeed,
      'swing': swing,
      'gpio': resolvedGpio,
      'protocol': 'GREE',
      'cmd_id': 'cmd-${DateTime.now().millisecondsSinceEpoch}',
      'sent_at_unix_ms': DateTime.now().millisecondsSinceEpoch,
    });
    _publishToRoom(
      roomId,
      'ac/$unitNum/command',
      payload,
      retain: false,
      qos: MqttQos.atLeastOnce,
    );
    _publishToRoom(
      roomId,
      'zone/$unitNum/ac/command',
      payload,
      retain: false,
      qos: MqttQos.atLeastOnce,
    );
    _publishToRoom(
      roomId,
      'ac/command',
      payload,
      retain: false,
      qos: MqttQos.atLeastOnce,
    );
    _publish(
      'home/zone_ac/command',
      payload,
      retain: false,
      qos: MqttQos.atLeastOnce,
    );
  }

  // 2. Zone All On / All Off (Targets ONLY this switchboard / zone!)
  void publishZoneAll(String roomId, int boardId, bool turnOn) {
    final payload = turnOn ? 'ALL_ON' : 'ALL_OFF';
    _publishToRoom(
      roomId,
      'zone/$boardId/command/all',
      payload,
      retain: false,
      qos: MqttQos.atLeastOnce,
    );
    _publish(
      'home/zone_$boardId/command/all',
      payload,
      retain: false,
      qos: MqttQos.atLeastOnce,
    );
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
      'sent_at_unix_ms': DateTime.now().millisecondsSinceEpoch,
    });
    _publishToRoom(
      roomId,
      'zone/$boardId/relay/$relayNumber',
      payload,
      retain: false,
      qos: MqttQos.atLeastOnce,
    );
    _publish(
      'home/zone_$boardId/relay/$relayNumber',
      payload,
      retain: false,
      qos: MqttQos.atLeastOnce,
    );
  }

  // 4. Adjust Light Brightness with Board Isolation
  void publishLightBrightness(
    String roomId,
    int boardId,
    int relayNumber,
    double brightness,
  ) {
    final payload = jsonEncode({
      'room': roomId,
      'zone': boardId,
      'board': boardId,
      'relay': relayNumber,
      'state': brightness > 0 ? 'ON' : 'OFF',
      'brightness': brightness.round(),
      'sent_at_unix_ms': DateTime.now().millisecondsSinceEpoch,
    });
    // Throttled to prevent flooding ESP32 PWM during continuous touch drag
    _publishThrottledToRoom(
      roomId,
      'zone/$boardId/relay/$relayNumber',
      payload,
      duration: const Duration(milliseconds: 75),
      retain: false,
    );
    _publishThrottled(
      'home/zone_$boardId/relay/$relayNumber',
      payload,
      duration: const Duration(milliseconds: 75),
      retain: false,
    );
  }

  // 5. Global All On / All Off for Entire Room
  void publishAllDevices(String roomId, bool allOn) {
    final payload = allOn ? 'ALL_ON' : 'ALL_OFF';
    _publishToRoom(
      roomId,
      'command/all',
      payload,
      retain: false,
      qos: MqttQos.atLeastOnce,
    );
  }

  // 6. Emergency Cutoff / Trip All Relays
  void publishEmergencyCutoff(String roomId, bool cutoff) {
    final payload = cutoff ? 'CUTOFF' : 'RESTORE';
    _publishToRoom(
      roomId,
      'command/emergency',
      payload,
      qos: MqttQos.atLeastOnce,
    );
  }

  // 6b. Toggle Vision Control vs Direct App Control on Pi Vision Model
  void publishVisionControl(String roomId, bool enabled) {
    final payload = jsonEncode({
      'room': roomId,
      'vision_control': enabled,
      'mode': enabled ? 'VISION' : 'MANUAL',
      'sent_at_unix_ms': DateTime.now().millisecondsSinceEpoch,
    });
    _publishToRoom(
      roomId,
      'vision/control',
      payload,
      retain: false,
      qos: MqttQos.atLeastOnce,
    );
    _publish(
      'classpulse/$roomId/vision/control',
      payload,
      retain: false,
      qos: MqttQos.atLeastOnce,
    );
    _publish(
      'home/vision/control',
      payload,
      retain: false,
      qos: MqttQos.atLeastOnce,
    );
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

  // 8. Active Telemetry Ping / Unified Hardware Discovery Scan Query
  void publishStatusQuery([String? roomId]) {
    final targetRoom = (roomId != null && roomId.isNotEmpty)
        ? roomId
        : 'reb_room_301';
    if (!isConnected) {
      _pendingDiscoveryRoomId = targetRoom;
      connect();
      return;
    }
    _publish('home/discovery/query', 'PING');
    if (roomId != null && roomId.isNotEmpty) {
      _publishToRoom(roomId, 'command/query', 'PING');
    }
  }

  // 8. Clear retained board status
  void clearBoardRetainedStatus(String roomId, int boardId) {
    final topic = '$_baseTopic/$roomId/status/board/$boardId';
    _publish(topic, '', retain: true);
  }
}
