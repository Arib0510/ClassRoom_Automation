import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/connectivity.dart';

class ConnectivityState extends ChangeNotifier {
  static final ConnectivityState _instance = ConnectivityState._internal();
  factory ConnectivityState() => _instance;

  static const MethodChannel _systemChannel =
      MethodChannel('com.smartcampus.iot/system');

  ConnectivityState._internal() {
    _initRealConnectivity();
  }

  // --- Real Wi-Fi State ---
  bool _isWifiEnabled = true;
  bool get isWifiEnabled => _isWifiEnabled;

  String _connectedSsid = 'Checking Wi-Fi...';
  String get connectedSsid => _connectedSsid;

  String _ipAddress = '--';
  String get ipAddress => _ipAddress;

  String _gatewayAddress = '--';
  String get gatewayAddress => _gatewayAddress;

  String? _wifiBssid;
  String? get wifiBssid => _wifiBssid;

  bool _isLocationPermissionGranted = false;
  bool get isLocationPermissionGranted => _isLocationPermissionGranted;

  bool _isLocationServiceEnabled = false;
  bool get isLocationServiceEnabled => _isLocationServiceEnabled;

  bool _isScanningWifi = false;
  bool get isScanningWifi => _isScanningWifi;

  List<WifiNetwork> _wifiNetworks = [];
  List<WifiNetwork> get wifiNetworks => _wifiNetworks;

  final List<IpDeviceNode> _discoveredIpNodes = [];
  List<IpDeviceNode> get discoveredIpNodes {
    final now = DateTime.now();
    // 30-second grace window: stable against network jitter while cleanly pruning offline boards
    _discoveredIpNodes.removeWhere((n) => now.difference(n.lastSeen).inSeconds > 30 || n.status != 'ONLINE');
    _discoveredIpNodes.sort((a, b) => a.boardId.compareTo(b.boardId));
    return List.unmodifiable(_discoveredIpNodes);
  }

  void purgeAllDiscoveredNodes({bool force = false}) {
    if (force) {
      _discoveredIpNodes.clear();
      notifyListeners();
    } else {
      final now = DateTime.now();
      _discoveredIpNodes.removeWhere((n) => now.difference(n.lastSeen).inSeconds > 30);
      notifyListeners();
    }
  }

  // --- Real Bluetooth State ---
  bool _isBleEnabled = false;
  bool get isBleEnabled => _isBleEnabled;

  bool _isScanningBle = false;
  bool get isScanningBle => _isScanningBle;

  final List<BleDeviceNode> _pairedBleNodes = [];
  List<BleDeviceNode> get pairedBleNodes => _pairedBleNodes;

  final List<BleDeviceNode> _discoveredBleNodes = [];
  List<BleDeviceNode> get discoveredBleNodes => _discoveredBleNodes;

  StreamSubscription? _bleScanSub;
  StreamSubscription? _bleAdapterSub;
  StreamSubscription? _networkSub;

  int? _wifiSignalDbm;
  int? get wifiSignalDbm => _wifiSignalDbm;

  void pairBleNode(BleDeviceNode node) => pairNode(node);
  void unpairBleNode(String id) => unpairNode(id);
  Future<void> refreshNetworkInfo() => _checkRealWifi();

  void _initRealConnectivity() {
    // 1. Listen to real Bluetooth adapter state
    try {
      _bleAdapterSub = FlutterBluePlus.adapterState.listen((state) {
        _isBleEnabled = (state == BluetoothAdapterState.on);
        notifyListeners();
      });
    } catch (_) {}

    // 2. Listen to real network changes
    try {
      _networkSub = Connectivity().onConnectivityChanged.listen((results) {
        _checkRealWifi();
      });
      _checkRealWifi();
    } catch (_) {}
  }

  // --- Permissions Management ---

  Future<void> checkPermissions() async {
    if (Platform.isAndroid) {
      try {
        final loc = await Permission.location.isGranted ||
            await Permission.locationWhenInUse.isGranted;
        _isLocationPermissionGranted = loc;

        // Check if GPS / Location service is turned on in Android settings
        try {
          final isLocOn = await _systemChannel.invokeMethod<bool>('isLocationEnabled');
          _isLocationServiceEnabled = isLocOn ?? false;
        } catch (_) {
          _isLocationServiceEnabled = await Permission.location.serviceStatus.isEnabled;
        }
      } catch (_) {}
    } else {
      _isLocationPermissionGranted = true;
      _isLocationServiceEnabled = true;
    }
    notifyListeners();
  }

  Future<bool> requestLocationPermission() async {
    if (Platform.isAndroid) {
      try {
        final statuses = await [
          Permission.location,
          Permission.locationWhenInUse,
          Permission.bluetoothScan,
          Permission.bluetoothConnect,
        ].request();

        final locStatus = statuses[Permission.location] ??
            statuses[Permission.locationWhenInUse];
        _isLocationPermissionGranted =
            locStatus?.isGranted == true || locStatus?.isLimited == true;

        try {
          final isLocOn = await _systemChannel.invokeMethod<bool>('isLocationEnabled');
          _isLocationServiceEnabled = isLocOn ?? false;
        } catch (_) {}

        notifyListeners();

        // If granted, immediately refresh Wi-Fi and Bluetooth info
        if (_isLocationPermissionGranted) {
          await _checkRealWifi();
          scanWifi();
          scanBle();
        }
        return _isLocationPermissionGranted;
      } catch (e) {
        debugPrint('Location permission request error: $e');
      }
    }
    return true;
  }

  Future<void> openLocationSettings() async {
    try {
      await _systemChannel.invokeMethod('openLocationSettings');
    } catch (_) {
      await openAppSettings();
    }
  }

  Future<void> openAppSettingsPage() async {
    await openAppSettings();
  }

  // --- Real Wi-Fi Operations ---

  Future<void> _checkRealWifi() async {
    await checkPermissions();

    // Query hardware Wi-Fi enabled status from native WifiManager
    if (Platform.isAndroid) {
      try {
        final hwWifi = await _systemChannel.invokeMethod<bool>('isWifiEnabled');
        if (hwWifi != null) {
          _isWifiEnabled = hwWifi;
        }
      } catch (_) {}
    }

    try {
      final connectivityResults = await Connectivity().checkConnectivity();
      final hasWifi = connectivityResults.contains(ConnectivityResult.wifi);

      if (hasWifi) {
        _isWifiEnabled = true;
        final info = NetworkInfo();
        String? wifiName;
        String? wifiIp;
        String? wifiBssid;
        String? wifiGateway;

        try {
          wifiName = await info.getWifiName();
          wifiIp = await info.getWifiIP();
          wifiBssid = await info.getWifiBSSID();
          wifiGateway = await info.getWifiGatewayIP();
        } catch (_) {}

        // If wifiIp is not reported by NetworkInfo, resolve from network interfaces
        if (wifiIp == null || wifiIp.isEmpty || wifiIp == '127.0.0.1') {
          try {
            final interfaces =
                await NetworkInterface.list(type: InternetAddressType.IPv4);
            for (var iface in interfaces) {
              final lower = iface.name.toLowerCase();
              if (lower.contains('wlan') ||
                  lower.contains('wifi') ||
                  lower.contains('eth')) {
                if (iface.addresses.isNotEmpty) {
                  wifiIp = iface.addresses.first.address;
                  break;
                }
              }
            }
          } catch (_) {}
        }

        // Clean up quotes from SSID (Android wraps SSID in quotes)
        String cleanSsid = wifiName?.replaceAll('"', '').trim() ?? '';
        if (cleanSsid.isEmpty || cleanSsid == '<unknown ssid>') {
          if (!_isLocationPermissionGranted) {
            cleanSsid = 'Wi-Fi Active (Grant Location to View SSID)';
          } else if (!_isLocationServiceEnabled) {
            cleanSsid = 'Wi-Fi Active (Turn ON GPS to View SSID)';
          } else {
            cleanSsid = 'Connected Wi-Fi Access Point';
          }
        }

        _connectedSsid = cleanSsid;
        _ipAddress = wifiIp ?? 'DHCP Assigned';
        _gatewayAddress = wifiGateway ?? '192.168.1.1';
        _wifiBssid = wifiBssid;

        // Ensure connected network is in the list
        final existingIdx = _wifiNetworks.indexWhere((n) => n.ssid == cleanSsid);
        if (existingIdx >= 0) {
          _wifiNetworks[existingIdx].isConnected = true;
        } else {
          _wifiNetworks.insert(
            0,
            WifiNetwork(
              ssid: cleanSsid,
              bssid: wifiBssid ?? 'Connected AP',
              signalDbm: -45,
              securityType: 'WPA2/WPA3 Protected',
              frequency: 'Active Hardware Link',
              isConnected: true,
            ),
          );
        }
      } else if (connectivityResults.contains(ConnectivityResult.mobile)) {
        _connectedSsid = 'Cellular Data Active (Wi-Fi Inactive)';
        _ipAddress = '--';
        _gatewayAddress = '--';
        _wifiBssid = null;
      } else {
        _connectedSsid = 'No Network Connection';
        _ipAddress = '--';
        _gatewayAddress = '--';
        _wifiBssid = null;
      }
    } catch (_) {
      _connectedSsid = 'Standby';
    }
    notifyListeners();
  }

  Future<void> toggleWifi([bool? targetState]) async {
    final target = targetState ?? !_isWifiEnabled;
    try {
      if (Platform.isAndroid) {
        await _systemChannel.invokeMethod('toggleWifi', {'enabled': target});
      }
    } catch (e) {
      debugPrint('Error toggling Wi-Fi: $e');
    }
    // Give OS time to update panel / radio
    await Future.delayed(const Duration(milliseconds: 500));
    await _checkRealWifi();
  }

  Future<void> openWifiSettings() async {
    try {
      await _systemChannel.invokeMethod('openWifiSettings');
    } catch (_) {}
  }

  Future<void> scanWifi() async {
    if (_isScanningWifi) return;
    _isScanningWifi = true;
    notifyListeners();

    try {
      // 1. Ensure location permission is requested (required by Android for Wi-Fi scanning)
      if (!_isLocationPermissionGranted) {
        await requestLocationPermission();
      }

      await _checkRealWifi();

      // 2. Query real hardware Wi-Fi scan results from Android WifiManager
      if (Platform.isAndroid) {
        try {
          final rawResults = await _systemChannel
              .invokeMethod<List<dynamic>>('getWifiScanResults');
          if (rawResults != null && rawResults.isNotEmpty) {
            final List<WifiNetwork> scannedList = [];
            for (var item in rawResults) {
              final map = Map<String, dynamic>.from(item as Map);
              final ssid = map['ssid']?.toString() ?? '';
              if (ssid.isEmpty) continue;

              final isConn = (ssid == _connectedSsid);
              scannedList.add(
                WifiNetwork(
                  ssid: ssid,
                  bssid: map['bssid']?.toString() ?? '',
                  signalDbm: (map['level'] as num?)?.toInt() ?? -60,
                  securityType: map['capabilities']?.toString() ?? 'WPA2 Secure',
                  frequency: map['frequency']?.toString() ?? '2.4 GHz',
                  isConnected: isConn,
                ),
              );
            }

            if (scannedList.isNotEmpty) {
              // Sort connected first, then by signal strength (descending)
              scannedList.sort((a, b) {
                if (a.isConnected && !b.isConnected) return -1;
                if (!a.isConnected && b.isConnected) return 1;
                return b.signalDbm.compareTo(a.signalDbm);
              });
              _wifiNetworks = scannedList;
            }
          }
        } catch (e) {
          debugPrint('Native Wi-Fi scan error: $e');
        }
      }

      // 3. Scan local subnet for active IP IoT Nodes (e.g. ESP32 web servers)
      await _scanSubnetForIotDevices();
    } catch (e) {
      debugPrint('Wi-Fi scan failed: $e');
    } finally {
      _isScanningWifi = false;
      notifyListeners();
    }
  }

  Future<void> _scanSubnetForIotDevices() async {
    // Only real hardware microcontrollers that broadcast live telemetry via MQTT or genuine handshakes are recorded.
    // Fake/blind port-80 probing is disabled to prevent phantom mock hardware nodes from showing.
  }

  void updateBoardTelemetry(int boardId, bool isOnline, String ip, int rssi, [String roomId = '']) {
    final nodeName = 'Switchboard #$boardId';
    if (!isOnline) {
      _discoveredIpNodes.removeWhere((n) => n.boardId == boardId || n.name == nodeName || n.ip == ip);
      notifyListeners();
      return;
    }
    final existingIdx = _discoveredIpNodes.indexWhere((n) => n.boardId == boardId || n.name == nodeName || n.ip == ip);
    final newNode = IpDeviceNode(
      boardId: boardId,
      ip: ip,
      name: nodeName,
      port: 1883,
      status: 'ONLINE',
      responseTimeMs: rssi,
      lastSeen: DateTime.now(),
      roomId: roomId,
    );
    if (existingIdx != -1) {
      _discoveredIpNodes[existingIdx] = newNode;
    } else {
      _discoveredIpNodes.add(newNode);
    }
    notifyListeners();
  }

  void connectToWifi(String ssid) {
    _connectedSsid = ssid;
    for (var w in _wifiNetworks) {
      w.isConnected = (w.ssid == ssid);
    }
    notifyListeners();
  }

  // --- Real Bluetooth Operations ---

  Future<void> toggleBle(bool enabled) async {
    if (enabled) {
      try {
        if (Platform.isAndroid) {
          await FlutterBluePlus.turnOn();
        }
      } catch (_) {}
      _isBleEnabled = true;
    } else {
      _isBleEnabled = false;
      try {
        await FlutterBluePlus.stopScan();
        if (Platform.isAndroid) {
          await _systemChannel.invokeMethod('openBluetoothSettings');
        }
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> scanBle() async {
    if (_isScanningBle) return;

    _isScanningBle = true;
    _discoveredBleNodes.clear();
    notifyListeners();

    try {
      // 1. Ensure runtime location and BLE permissions are granted
      if (!_isLocationPermissionGranted) {
        await requestLocationPermission();
      }

      // 2. Ensure Bluetooth adapter is powered on
      if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
        try {
          await FlutterBluePlus.turnOn();
          await Future.delayed(const Duration(milliseconds: 600));
        } catch (_) {}
      }

      // 3. Retrieve system bonded / paired devices immediately
      try {
        final bonded = await FlutterBluePlus.bondedDevices;
        for (var d in bonded) {
          final id = d.remoteId.str;
          String name = d.platformName.isNotEmpty ? d.platformName : 'Bonded Peripheral';
          _addOrUpdateBleNode(id, name, -50, d);
        }
      } catch (_) {}

      // 4. Cancel any previous scan subscription
      await _bleScanSub?.cancel();

      // 5. Listen for real Bluetooth broadcast advertisements
      _bleScanSub = FlutterBluePlus.onScanResults.listen((results) {
        for (ScanResult r in results) {
          final id = r.device.remoteId.str;
          if (_pairedBleNodes.any((p) => p.id == id)) continue;

          String rawName = r.device.platformName.isNotEmpty
              ? r.device.platformName
              : r.advertisementData.advName;

          if (rawName.isEmpty) {
            rawName = 'ESP32-BLE [${id.length > 5 ? id.substring(id.length - 5) : id}]';
          }

          _addOrUpdateBleNode(id, rawName, r.rssi, r.device);
        }
      });

      // 6. Start real BLE scanning with fine location enabled
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 12),
        androidUsesFineLocation: true,
        continuousUpdates: true,
      );
    } catch (e) {
      debugPrint('Real BLE scan error: $e');
    }

    // Wait until scanning stops
    await FlutterBluePlus.isScanning
        .where((s) => !s)
        .first
        .catchError((_) => false);

    _isScanningBle = false;
    notifyListeners();
  }

  void _addOrUpdateBleNode(
      String id, String rawName, int rssi, BluetoothDevice device) {
    String category = 'ESP32 Device';
    final lower = rawName.toLowerCase();
    if (lower.contains('fan')) {
      category = 'Ceiling Fan Controller';
    } else if (lower.contains('light') || lower.contains('led')) {
      category = 'Lighting Relay';
    } else if (lower.contains('ac') ||
        lower.contains('cool') ||
        lower.contains('temp')) {
      category = 'AC Climate Relay';
    } else if (lower.contains('relay') || lower.contains('esp')) {
      category = 'ESP32 Relay Node';
    }

    final existingIdx = _discoveredBleNodes.indexWhere((n) => n.id == id);
    final newNode = BleDeviceNode(
      id: id,
      name: rawName,
      macAddress: id,
      rssiDbm: rssi,
      category: category,
      rawDevice: device,
    );

    if (existingIdx >= 0) {
      _discoveredBleNodes[existingIdx] = newNode;
    } else {
      _discoveredBleNodes.add(newNode);
    }
    notifyListeners();
  }

  void pairNode(BleDeviceNode node) {
    if (!_pairedBleNodes.any((n) => n.id == node.id)) {
      _pairedBleNodes.add(node);
      _discoveredBleNodes.removeWhere((n) => n.id == node.id);
      notifyListeners();
    }
  }

  void unpairNode(String id) {
    _pairedBleNodes.removeWhere((n) => n.id == id);
    notifyListeners();
  }

  @override
  void dispose() {
    _bleScanSub?.cancel();
    _bleAdapterSub?.cancel();
    _networkSub?.cancel();
    super.dispose();
  }
}
