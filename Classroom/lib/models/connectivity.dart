import 'package:flutter_blue_plus/flutter_blue_plus.dart';

class WifiNetwork {
  final String ssid;
  final String bssid;
  int signalDbm;
  final bool isSecured;
  final String securityType;
  final String frequency;
  bool isConnected;

  WifiNetwork({
    required this.ssid,
    required this.bssid,
    required this.signalDbm,
    this.isSecured = true,
    this.securityType = 'WPA2/WPA3',
    this.frequency = 'Wi-Fi',
    this.isConnected = false,
  });
}

class BleDeviceNode {
  final String id;
  final String name;
  final String macAddress;
  final String category;
  int rssiDbm;
  bool isPaired;
  bool isConnecting;
  final BluetoothDevice? rawDevice;

  BleDeviceNode({
    required this.id,
    required this.name,
    required this.macAddress,
    required this.category,
    required this.rssiDbm,
    this.isPaired = false,
    this.isConnecting = false,
    this.rawDevice,
  });
}

class IpDeviceNode {
  final int boardId;
  final String zoneId;     // e.g. 'zone_1', 'zone_2', 'zone_3', 'zone_ac'
  final String deviceType; // e.g. 'switchboard', 'ac_unit'
  final String ip;
  final String name;
  final int port;
  final String status;
  final int responseTimeMs;
  final DateTime lastSeen;
  final String roomId;

  IpDeviceNode({
    this.boardId = 1,
    String? zoneId,
    this.deviceType = 'switchboard',
    required this.ip,
    required this.name,
    this.port = 1883,
    this.status = 'ONLINE',
    this.responseTimeMs = -55,
    DateTime? lastSeen,
    this.roomId = '',
  })  : zoneId = zoneId ?? (deviceType == 'ac_unit' ? 'zone_ac' : 'zone_$boardId'),
        lastSeen = lastSeen ?? DateTime.now();

  bool get isAcUnit =>
      deviceType.toLowerCase() == 'ac_unit' ||
      zoneId.toLowerCase() == 'zone_ac' ||
      boardId == 4;

  bool get isOnline =>
      status == 'ONLINE' && DateTime.now().difference(lastSeen).inSeconds <= 30;
}
