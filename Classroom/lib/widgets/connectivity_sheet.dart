import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/connectivity.dart';
import '../state/connectivity_state.dart';
import '../state/classroom_state.dart';
import '../services/mqtt_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';
import 'cyber_switch.dart';
import 'cyber_toast.dart';
import 'pulsing_beacon.dart';

class ConnectivitySheet extends StatefulWidget {
  final int initialTab; // 0: WiFi, 1: MQTT, 2: ESP-NOW

  const ConnectivitySheet({super.key, this.initialTab = 0});

  static void show(BuildContext context, {int initialTab = 0}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => ConnectivitySheet(initialTab: initialTab),
    );
  }

  @override
  State<ConnectivitySheet> createState() => _ConnectivitySheetState();
}

class _ConnectivitySheetState extends State<ConnectivitySheet>
    with WidgetsBindingObserver {
  final ConnectivityState _connState = ConnectivityState();
  late int _activeTab;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _activeTab = widget.initialTab;
    _connState.addListener(_onStateChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _connState.checkPermissions();
      _connState.refreshNetworkInfo();
      _connState.scanWifi();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _connState.checkPermissions();
      _connState.refreshNetworkInfo();
      _connState.scanWifi();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connState.removeListener(_onStateChanged);
    super.dispose();
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.86,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                color: Colors.white.withValues(alpha: 0.2),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Icon(Icons.hub, size: 20, color: AppColors.primary),
                  const SizedBox(width: 8),
                  Text(
                    'Hardware Connectivity',
                    style: AppTypography.headlineSm(color: AppColors.onSurface),
                  ),
                ],
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 20, color: AppColors.outline),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),

          const SizedBox(height: 10),

          // Location Permission / GPS Notice
          _buildPermissionBanner(),

          // Tab Switcher (Wi-Fi, MQTT, ESP-NOW)
          Container(
            height: 40,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: AppColors.surfaceContainerLowest,
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            padding: const EdgeInsets.all(3),
            child: Row(
              children: [
                // Wi-Fi Tab
                Expanded(
                  child: GestureDetector(
                    onTap: () {
                      HapticFeedback.selectionClick();
                      setState(() => _activeTab = 0);
                      _connState.scanWifi();
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 140),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        color: _activeTab == 0
                            ? AppColors.surfaceContainer
                            : Colors.transparent,
                        border: _activeTab == 0
                            ? Border.all(
                                color: AppColors.primary.withValues(alpha: 0.3))
                            : null,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.wifi,
                            size: 15,
                            color: _activeTab == 0
                                ? AppColors.primary
                                : AppColors.onSurfaceVariant,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            'Wi-Fi',
                            style: AppTypography.labelSm(
                              color: _activeTab == 0
                                  ? AppColors.primary
                                  : AppColors.onSurfaceVariant,
                            ).copyWith(fontWeight: _activeTab == 0 ? FontWeight.bold : FontWeight.normal),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                // MQTT Tab
                Expanded(
                  child: GestureDetector(
                    onTap: () {
                      HapticFeedback.selectionClick();
                      setState(() => _activeTab = 1);
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 140),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        color: _activeTab == 1
                            ? AppColors.surfaceContainer
                            : Colors.transparent,
                        border: _activeTab == 1
                            ? Border.all(
                                color: AppColors.primary.withValues(alpha: 0.3))
                            : null,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.cloud_sync,
                            size: 15,
                            color: _activeTab == 1
                                ? AppColors.primary
                                : AppColors.onSurfaceVariant,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            'MQTT',
                            style: AppTypography.labelSm(
                              color: _activeTab == 1
                                  ? AppColors.primary
                                  : AppColors.onSurfaceVariant,
                            ).copyWith(fontWeight: _activeTab == 1 ? FontWeight.bold : FontWeight.normal),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                // ESP-NOW Tab
                Expanded(
                  child: GestureDetector(
                    onTap: () {
                      HapticFeedback.selectionClick();
                      setState(() => _activeTab = 2);
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 140),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        color: _activeTab == 2
                            ? AppColors.surfaceContainer
                            : Colors.transparent,
                        border: _activeTab == 2
                            ? Border.all(
                                color: AppColors.primary.withValues(alpha: 0.3))
                            : null,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.developer_board,
                            size: 15,
                            color: _activeTab == 2
                                ? AppColors.primary
                                : AppColors.onSurfaceVariant,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            'ESP-NOW',
                            style: AppTypography.labelSm(
                              color: _activeTab == 2
                                  ? AppColors.primary
                                  : AppColors.onSurfaceVariant,
                            ).copyWith(fontWeight: _activeTab == 2 ? FontWeight.bold : FontWeight.normal),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 14),

          // Tab Content
          Expanded(
            child: _activeTab == 0
                ? _buildWifiTab()
                : (_activeTab == 1 ? _buildMqttTab() : _buildEspNowTab()),
          ),
        ],
      ),
    );
  }

  Widget _buildPermissionBanner() {
    if (!_connState.isLocationPermissionGranted) {
      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: AppColors.telemetryAmber.withValues(alpha: 0.12),
          border: Border.all(color: AppColors.telemetryAmber.withValues(alpha: 0.4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.location_on, size: 16, color: AppColors.telemetryAmber),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'LOCATION PERMISSION REQUIRED',
                    style: AppTypography.labelSm(color: AppColors.telemetryAmber)
                        .copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Android requires Location permission to read your connected Wi-Fi network SSID.',
              style: AppTypography.bodySm(color: AppColors.onSurfaceVariant)
                  .copyWith(fontSize: 12),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 36,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.telemetryAmber,
                  foregroundColor: Colors.black,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: () async {
                  HapticFeedback.mediumImpact();
                  final ok = await _connState.requestLocationPermission();
                  if (!ok && mounted) {
                    _connState.openAppSettingsPage();
                  }
                },
                icon: const Icon(Icons.security, size: 16),
                label: const Text(
                  'GRANT LOCATION PERMISSION',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ),
            ),
          ],
        ),
      );
    } else if (!_connState.isLocationServiceEnabled) {
      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: AppColors.primary.withValues(alpha: 0.1),
          border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            const Icon(Icons.gps_fixed, size: 18, color: AppColors.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'DEVICE GPS LOCATION IS OFF',
                    style: AppTypography.labelSm(color: AppColors.primary)
                        .copyWith(fontWeight: FontWeight.bold),
                  ),
                  Text(
                    'Turn on GPS in phone settings to see nearby Wi-Fi SSIDs & BLE beacons.',
                    style: AppTypography.bodySm(color: AppColors.outline)
                        .copyWith(fontSize: 11),
                  ),
                ],
              ),
            ),
            TextButton(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () => _connState.openLocationSettings(),
              child: Text(
                'ENABLE GPS',
                style: AppTypography.labelSm(color: AppColors.primary)
                    .copyWith(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _buildWifiTab() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Wi-Fi Master Toggle Card
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: AppColors.surfaceContainerLowest,
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Icon(
                            Icons.wifi,
                            size: 22,
                            color: _connState.isWifiEnabled
                                ? AppColors.primary
                                : AppColors.outline,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Phone Wi-Fi Radio',
                                  style: AppTypography.headlineSm(fontSize: 14),
                                ),
                                Text(
                                  _connState.isWifiEnabled
                                      ? 'Active · ${_connState.connectedSsid}'
                                      : 'Wi-Fi radio offline / disabled',
                                  style: AppTypography.bodySm(
                                    color: _connState.isWifiEnabled
                                        ? AppColors.primary
                                        : AppColors.outline,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    CyberSwitch(
                      value: _connState.isWifiEnabled,
                      onChanged: (val) {
                        _connState.toggleWifi(val);
                      },
                    ),
                  ],
                ),
                if (!_connState.isWifiEnabled) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 34,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(
                            color: AppColors.primary.withValues(alpha: 0.4)),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: () => _connState.toggleWifi(true),
                      icon: const Icon(Icons.wifi, size: 16, color: AppColors.primary),
                      label: Text(
                        'TURN ON PHONE WI-FI',
                        style: AppTypography.labelSm(color: AppColors.primary),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),

          if (_connState.isWifiEnabled) ...[
            const SizedBox(height: 14),

            // Active Connection Telemetry Readout
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: AppColors.surfaceContainer,
                border:
                    Border.all(color: AppColors.primary.withValues(alpha: 0.2)),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            const PulsingBeacon(
                                size: 6, color: AppColors.onlineMint),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _connState.connectedSsid,
                                style: AppTypography.headlineSm(fontSize: 14),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          color: AppColors.primary.withValues(alpha: 0.15),
                        ),
                        child: Text(
                          _connState.wifiSignalDbm != null
                              ? '${_connState.wifiSignalDbm} dBm'
                              : 'ONLINE',
                          style: AppTypography.labelSm(color: AppColors.primary),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Divider(color: Colors.white.withValues(alpha: 0.06)),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          'IP: ${_connState.ipAddress}',
                          style: AppTypography.labelSm(color: AppColors.outline),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          'GATEWAY: ${_connState.gatewayAddress}',
                          style: AppTypography.labelSm(color: AppColors.outline),
                          textAlign: TextAlign.end,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // Detected Networks Header + Scan Action
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'NEARBY WI-FI NETWORKS (${_connState.wifiNetworks.length})',
                  style: AppTypography.labelSm(color: AppColors.onSurfaceVariant),
                ),
                GestureDetector(
                  onTap: _connState.isScanningWifi
                      ? null
                      : () => _connState.scanWifi(),
                  child: Row(
                    children: [
                      if (_connState.isScanningWifi) ...[
                        const SizedBox(
                          width: 10,
                          height: 10,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: AppColors.primary,
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Text(
                        _connState.isScanningWifi ? 'SCANNING...' : 'REFRESH SCAN',
                        style: AppTypography.labelSm(color: AppColors.primary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // Networks List
            if (_connState.wifiNetworks.isEmpty && !_connState.isScanningWifi)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Center(
                  child: Text(
                    'No Wi-Fi signals found. Tap REFRESH SCAN.',
                    style: AppTypography.bodySm(color: AppColors.outline),
                  ),
                ),
              )
            else
              ..._connState.wifiNetworks.map((net) => _buildWifiTile(net)),

            // Discovered Subnet IoT Nodes (if any)
            if (_connState.discoveredIpNodes.isNotEmpty) ...[
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'LOCAL NETWORK IOT NODES (${_connState.discoveredIpNodes.length})',
                    style:
                        AppTypography.labelSm(color: AppColors.onSurfaceVariant),
                  ),
                  Text(
                    'PORT 80 / ESP32',
                    style: AppTypography.labelSm(color: AppColors.onlineMint),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ..._connState.discoveredIpNodes.map((node) => _buildIpNodeTile(node)),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildWifiTile(WifiNetwork net) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: net.isConnected
            ? AppColors.primary.withValues(alpha: 0.1)
            : AppColors.surfaceContainerLowest,
        border: Border.all(
          color: net.isConnected
              ? AppColors.primary.withValues(alpha: 0.4)
              : Colors.white.withValues(alpha: 0.06),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Row(
              children: [
                Icon(
                  Icons.wifi,
                  size: 16,
                  color: net.isConnected
                      ? AppColors.primary
                      : AppColors.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        net.ssid,
                        style: AppTypography.bodySm(
                          color: net.isConnected
                              ? AppColors.primary
                              : AppColors.onSurface,
                        ).copyWith(fontWeight: FontWeight.w500),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '${net.frequency} · ${net.securityType} · ${net.signalDbm} dBm',
                        style: AppTypography.labelSm(color: AppColors.outline),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (net.isConnected)
            Text(
              'CONNECTED',
              style: AppTypography.labelSm(color: AppColors.primary)
                  .copyWith(fontWeight: FontWeight.bold),
            )
          else
            TextButton(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () {
                HapticFeedback.selectionClick();
                _connState.openWifiSettings();
              },
              child: Text(
                'CONNECT',
                style: AppTypography.labelSm(color: AppColors.primary),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildIpNodeTile(IpDeviceNode node) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: AppColors.surfaceContainerLowest,
        border: Border.all(
          color: AppColors.onlineMint.withValues(alpha: 0.25),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Row(
              children: [
                const Icon(
                  Icons.developer_board,
                  size: 16,
                  color: AppColors.onlineMint,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        node.name,
                        style: AppTypography.bodySm(color: AppColors.onSurface)
                            .copyWith(fontWeight: FontWeight.w500),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        node.responseTimeMs < 0
                            ? 'IP: ${node.ip} · RSSI: ${node.responseTimeMs} dBm'
                            : 'IP: ${node.ip} · Port ${node.port}',
                        style: AppTypography.labelSm(color: AppColors.outline),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              color: AppColors.onlineMint.withValues(alpha: 0.15),
            ),
            child: Text(
              node.status,
              style: AppTypography.labelSm(color: AppColors.onlineMint),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMqttTab() {
    final isConnected = MqttService().isConnected;
    final state = ClassroomState();

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Connection Status Card
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: AppColors.surfaceContainerLowest,
              border: Border.all(
                color: isConnected
                    ? AppColors.onlineMint.withValues(alpha: 0.35)
                    : AppColors.telemetryAmber.withValues(alpha: 0.35),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    PulsingBeacon(
                      size: 8,
                      color: isConnected ? AppColors.onlineMint : AppColors.telemetryAmber,
                      isPulsing: isConnected,
                    ),
                    const SizedBox(width: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'MQTT Broker Status',
                          style: AppTypography.headlineSm(fontSize: 14),
                        ),
                        Text(
                          isConnected ? 'Connected & Synchronized' : 'Connecting / Standby',
                          style: AppTypography.bodySm(
                            color: isConnected ? AppColors.onlineMint : AppColors.telemetryAmber,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.surfaceContainerHigh,
                    foregroundColor: AppColors.primary,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    MqttService().connect();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('MQTT reconnection initiated...'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                  child: Text('RECONNECT', style: AppTypography.labelSm(color: AppColors.primary)),
                ),
              ],
            ),
          ),

          const SizedBox(height: 14),

          // Broker Configuration Details Card
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: AppColors.surfaceContainer,
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.dns, size: 16, color: AppColors.primary),
                        const SizedBox(width: 8),
                        Text('BROKER SERVER PARAMETERS', style: AppTypography.labelSm(color: AppColors.onSurfaceVariant)),
                      ],
                    ),
                    InkWell(
                      onTap: _showConfigureBrokerDialog,
                      borderRadius: BorderRadius.circular(6),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        child: Row(
                          children: [
                            const Icon(Icons.edit, size: 12, color: AppColors.primary),
                            const SizedBox(width: 4),
                            Text('EDIT', style: AppTypography.labelSm(color: AppColors.primary).copyWith(fontSize: 10, fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _buildParamRow('Broker Host', MqttService().broker),
                _buildParamRow('Port', '${MqttService().port} (TCP)'),
                _buildParamRow('Base Topic', MqttService().baseTopic),
                _buildParamRow('Protocol', 'MQTT v3.1.1 Standard'),
                _buildParamRow('Classrooms Linked', '${state.classrooms.length} Active Rooms'),
              ],
            ),
          ),

          const SizedBox(height: 14),

          // Topic Hierarchy Card
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: AppColors.surfaceContainer,
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.alt_route, size: 16, color: AppColors.secondary),
                    const SizedBox(width: 8),
                    Text('MQTT TOPIC PROTOCOL HIERARCHY', style: AppTypography.labelSm(color: AppColors.onSurfaceVariant)),
                  ],
                ),
                const SizedBox(height: 10),
                _buildTopicRow('Device Commands', 'ruet/classroom/<ROOM>/command/<DEVICE>/set'),
                _buildTopicRow('ESP32 Telemetry', 'ruet/classroom/<ROOM>/status/board/<ID>'),
                _buildTopicRow('GPIO Reconfig', 'ruet/classroom/<ROOM>/config/board/<ID>/gpio'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildParamRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: AppTypography.bodySm(color: AppColors.outline)),
          Text(value, style: AppTypography.bodySm(color: AppColors.onSurface).copyWith(fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  Widget _buildTopicRow(String label, String topic) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppTypography.labelSm(color: AppColors.outline).copyWith(fontSize: 10)),
          const SizedBox(height: 2),
          Text(
            topic,
            style: AppTypography.labelSm(color: AppColors.primary).copyWith(fontFamily: 'monospace', fontSize: 11),
          ),
        ],
      ),
    );
  }

  void _showConfigureBrokerDialog() {
    final hostController = TextEditingController(text: MqttService().broker);
    final portController = TextEditingController(text: MqttService().port.toString());
    final topicController = TextEditingController(text: MqttService().baseTopic);

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.surfaceContainerHigh,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: AppColors.primary.withValues(alpha: 0.3)),
          ),
          title: Row(
            children: [
              const Icon(Icons.dns, color: AppColors.primary, size: 20),
              const SizedBox(width: 8),
              Text('Configure MQTT Broker', style: AppTypography.headlineSm(fontSize: 16)),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('BROKER HOST (Domain or Local IP)', style: AppTypography.labelSm(color: AppColors.onSurfaceVariant)),
                const SizedBox(height: 6),
                TextField(
                  controller: hostController,
                  style: AppTypography.bodyMd(color: AppColors.onSurface),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: AppColors.surfaceContainerLowest,
                    hintText: 'e.g. broker.emqx.io or 192.168.1.100',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
                const SizedBox(height: 12),
                Text('PORT', style: AppTypography.labelSm(color: AppColors.onSurfaceVariant)),
                const SizedBox(height: 6),
                TextField(
                  controller: portController,
                  keyboardType: TextInputType.number,
                  style: AppTypography.bodyMd(color: AppColors.onSurface),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: AppColors.surfaceContainerLowest,
                    hintText: '1883',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
                const SizedBox(height: 12),
                Text('BASE TOPIC', style: AppTypography.labelSm(color: AppColors.onSurfaceVariant)),
                const SizedBox(height: 6),
                TextField(
                  controller: topicController,
                  style: AppTypography.bodyMd(color: AppColors.onSurface),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: AppColors.surfaceContainerLowest,
                    hintText: 'ruet/classroom',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('CANCEL', style: AppTypography.labelMd(color: AppColors.outline)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: AppColors.surfaceContainerLowest,
              ),
              onPressed: () {
                final h = hostController.text.trim();
                final p = int.tryParse(portController.text.trim()) ?? 1883;
                final t = topicController.text.trim();
                if (h.isNotEmpty) {
                  MqttService().configure(broker: h, port: p, baseTopic: t.isNotEmpty ? t : null);
                  MqttService().disconnect();
                  MqttService().connect();
                  setState(() {});
                  Navigator.pop(context);
                  CyberToast.show(
                    context,
                    message: 'Broker configured. Connecting to $h:$p...',
                    type: ToastType.info,
                  );
                }
              },
              child: Text('APPLY & CONNECT', style: AppTypography.labelMd().copyWith(fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  Widget _buildEspNowTab() {
    final liveBoards = _connState.discoveredIpNodes;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ESP-NOW Protocol Overview Card
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: AppColors.surfaceContainerLowest,
              border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: AppColors.primary.withValues(alpha: 0.15),
                  ),
                  child: const Icon(Icons.flash_on, color: AppColors.primary, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('ESP-NOW Hardware Bus', style: AppTypography.headlineSm(fontSize: 14)),
                      const SizedBox(height: 2),
                      Text(
                        'Direct peer-to-peer 2.4GHz mesh for zero-latency relay triggers',
                        style: AppTypography.bodySm(color: AppColors.onSurfaceVariant).copyWith(fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 14),

          // Hardware Switchboards Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('ESP32 HARDWARE CONTROLLERS', style: AppTypography.labelSm(color: AppColors.onSurfaceVariant)),
              Text(
                liveBoards.isNotEmpty ? '${liveBoards.length} BOARDS ACTIVE' : '0 BOARDS ACTIVE',
                style: AppTypography.labelSm(
                  color: liveBoards.isNotEmpty ? AppColors.onlineMint : AppColors.outline,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          if (liveBoards.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: AppColors.surfaceContainerLowest,
                border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
              ),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.surfaceContainerHigh,
                    ),
                    child: const Icon(Icons.developer_board_off, size: 28, color: AppColors.outline),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'No Physical ESP32 Switchboards Online',
                    style: AppTypography.headlineSm(color: AppColors.onSurface).copyWith(fontSize: 14),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'No microcontrollers are currently transmitting telemetry on this mesh. When an ESP32 board is powered on with the test firmware, it will appear here automatically.',
                    style: AppTypography.bodySm(color: AppColors.onSurfaceVariant),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            )
          else
            ...liveBoards.map((board) => Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: AppColors.surfaceContainerLowest,
                border: Border.all(color: AppColors.primary.withValues(alpha: 0.2)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.memory, size: 16, color: AppColors.primary),
                          const SizedBox(width: 8),
                          Text(
                            board.name,
                            style: AppTypography.bodyMd().copyWith(fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(4),
                          color: AppColors.onlineMint.withValues(alpha: 0.15),
                        ),
                        child: Text(board.status, style: AppTypography.labelSm(color: AppColors.onlineMint).copyWith(fontSize: 9)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'IP Address: ${board.ip} · Signal: ${board.responseTimeMs} dBm · Port: ${board.port}',
                    style: AppTypography.labelSm(color: AppColors.outline),
                  ),
                ],
              ),
            )),
        ],
      ),
    );
  }
}
