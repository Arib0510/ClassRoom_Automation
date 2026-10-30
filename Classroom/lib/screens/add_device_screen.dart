import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/device.dart';
import '../services/mqtt_service.dart';
import '../state/classroom_state.dart';
import '../state/connectivity_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';
import '../widgets/cyber_switch.dart';
import '../widgets/pulsing_beacon.dart';
import '../widgets/ceiling_fan_icon.dart';
import '../widgets/cyber_dropdown.dart';
import '../widgets/cyber_toast.dart';

enum AddProvisioningMode {
  batchZone,
  singleAppliance,
}

class _BatchChannelConfig {
  final int relayNumber;
  int gpio;
  bool enabled = true;
  String category; // 'Light', 'Ceiling Fan', 'AC'
  DeviceType type;
  TextEditingController nameController;
  bool defaultOn;

  _BatchChannelConfig({
    required this.relayNumber,
    required this.gpio,
    this.category = 'Light',
    this.type = DeviceType.lighting,
    required String initialName,
    this.defaultOn = false,
  }) : nameController = TextEditingController(text: initialName);

  void dispose() {
    nameController.dispose();
  }
}

class AddDeviceScreen extends StatefulWidget {
  final String? preselectedRoomId;

  const AddDeviceScreen({super.key, this.preselectedRoomId});

  @override
  State<AddDeviceScreen> createState() => _AddDeviceScreenState();
}

class _AddDeviceScreenState extends State<AddDeviceScreen> {
  final ClassroomState _state = ClassroomState();

  AddProvisioningMode _mode = AddProvisioningMode.batchZone;
  bool _keepOpenAfterSingleAdd = false;

  late String _selectedRoomId;
  String _selectedZone = 'Zone 1';
  final TextEditingController _deviceNameController = TextEditingController();
  final TextEditingController _macController = TextEditingController();

  // Switchboard selection (Board 1, Board 2, etc.)
  int _selectedBoardId = 1;
  String _selectedBoardName = 'Switchboard #1';
  bool _isScanningMqtt = false;

  // Single Appliance mode fields
  String _selectedCategory = 'Ceiling Fan';
  String _selectedProtocol = 'MQTT';
  bool _defaultOn = true;
  int _selectedGpio = 18;
  int _selectedRelayNumber = 1;

  final List<String> _protocols = ['MQTT', 'Wi-Fi', 'ESP-NOW'];

  final List<Map<String, dynamic>> _deviceCategories = [
    {
      'title': 'Ceiling Fan',
      'icon': Icons.toys,
      'type': DeviceType.fan,
      'defaultName': 'Ceiling Fan',
      'defaultGpio': 18,
    },
    {
      'title': 'Light',
      'icon': Icons.lightbulb_outline,
      'type': DeviceType.lighting,
      'defaultName': 'Classroom Light',
      'defaultGpio': 21,
    },
    {
      'title': 'AC',
      'icon': Icons.ac_unit,
      'type': DeviceType.hvac,
      'defaultName': 'Classroom AC',
      'defaultGpio': 4,
    },
  ];

  final List<Map<String, int>> _switchboardRelays = [
    {'relay': 1, 'gpio': 18},
    {'relay': 2, 'gpio': 19},
    {'relay': 3, 'gpio': 21},
    {'relay': 4, 'gpio': 22},
  ];

  // Batch channels (4 physical relays)
  late final List<_BatchChannelConfig> _batchChannels;

  @override
  void initState() {
    super.initState();
    _selectedRoomId = widget.preselectedRoomId ??
        (_state.classrooms.isNotEmpty ? _state.classrooms.first.id : '');
    _updateDefaultZone();

    _batchChannels = [
      _BatchChannelConfig(
        relayNumber: 1,
        gpio: 18,
        category: 'Light',
        type: DeviceType.lighting,
        initialName: '$_selectedZone Front Light',
        defaultOn: true,
      ),
      _BatchChannelConfig(
        relayNumber: 2,
        gpio: 19,
        category: 'Light',
        type: DeviceType.lighting,
        initialName: '$_selectedZone Board Light',
        defaultOn: true,
      ),
      _BatchChannelConfig(
        relayNumber: 3,
        gpio: 21,
        category: 'Ceiling Fan',
        type: DeviceType.fan,
        initialName: '$_selectedZone Fan 1',
        defaultOn: true,
      ),
      _BatchChannelConfig(
        relayNumber: 4,
        gpio: 22,
        category: 'AC',
        type: DeviceType.hvac,
        initialName: '$_selectedZone AC Unit',
        defaultOn: false,
      ),
    ];

    _updateDefaultDeviceName();
    _updateBatchDefaultNames();
    ConnectivityState().addListener(_onConnectivityChanged);
    _runMqttHardwareScan();
  }

  void _onConnectivityChanged() {
    if (!mounted) return;
    final online = ConnectivityState().discoveredIpNodes;
    if (online.isNotEmpty && (_selectedBoardId == 0 || !_isScanningMqtt)) {
      final currentFound = online.where((n) => n.boardId == _selectedBoardId).firstOrNull ?? online.first;
      if (_macController.text.startsWith('ESP32_') || _macController.text.isEmpty) {
        _macController.text = currentFound.ip;
      }
    }
    setState(() {});
  }

  Future<void> _runMqttHardwareScan() async {
    if (!mounted) return;
    setState(() => _isScanningMqtt = true);
    // Soft prune nodes older than 30s; preserve active boards to eliminate flickering
    ConnectivityState().purgeAllDiscoveredNodes(force: false);

    // Double-ping query for reliable broker packet propagation
    MqttService().publishStatusQuery(_selectedRoomId);
    await Future.delayed(const Duration(milliseconds: 250));
    MqttService().publishStatusQuery(_selectedRoomId);

    await Future.delayed(const Duration(milliseconds: 1500));
    if (!mounted) return;
    setState(() {
      _isScanningMqtt = false;
      final online = ConnectivityState().discoveredIpNodes;
      if (online.isNotEmpty) {
        final currentFound = online.where((n) => n.boardId == _selectedBoardId).firstOrNull ?? online.first;
        _selectedBoardId = currentFound.boardId;
        _selectedBoardName = currentFound.name;
        _macController.text = currentFound.ip;
      } else {
        // If no hardware online, keep zone-bound board index for offline provisioning
        final match = RegExp(r'(\d+)').firstMatch(_selectedZone);
        final bId = match != null ? (int.tryParse(match.group(1) ?? '') ?? 1) : 1;
        _selectedBoardId = bId;
        _selectedBoardName = 'Switchboard #$bId';
        if (_macController.text.trim().isEmpty) {
          _macController.text = 'ESP32_Board_$bId';
        }
      }
      _updateDefaultDeviceName();
    });
  }

  @override
  void dispose() {
    ConnectivityState().removeListener(_onConnectivityChanged);
    _deviceNameController.dispose();
    _macController.dispose();
    for (var ch in _batchChannels) {
      ch.dispose();
    }
    super.dispose();
  }

  void _updateDefaultZone() {
    if (_state.classrooms.isNotEmpty) {
      final curRoom = _state.classrooms.firstWhere(
        (r) => r.id == _selectedRoomId,
        orElse: () => _state.classrooms.first,
      );
      if (curRoom.zones.isNotEmpty) {
        if (!curRoom.zones.contains(_selectedZone)) {
          _selectedZone = curRoom.zones.first;
        }
      } else {
        _selectedZone = 'Zone 1';
      }
      final match = RegExp(r'(\d+)').firstMatch(_selectedZone);
      if (match != null) {
        final bId = int.tryParse(match.group(1) ?? '') ?? 1;
        _selectedBoardId = bId;
        _selectedBoardName = 'Switchboard #$bId';
      }
    }
  }

  void _onZoneSelected(String zone) {
    HapticFeedback.selectionClick();
    setState(() {
      _selectedZone = zone;
      final match = RegExp(r'(\d+)').firstMatch(zone);
      if (match != null) {
        final bId = int.tryParse(match.group(1) ?? '') ?? 1;
        _selectedBoardId = bId;
        _selectedBoardName = 'Switchboard #$bId';
        if (_macController.text.startsWith('ESP32_Board_')) {
          _macController.text = 'ESP32_Board_$bId';
        }
      }
      _updateDefaultDeviceName();
      _updateBatchDefaultNames();
    });
  }

  void _updateDefaultDeviceName() {
    final categoryItem = _deviceCategories.firstWhere(
      (c) => c['title'] == _selectedCategory,
      orElse: () => _deviceCategories.first,
    );
    final prefix = categoryItem['defaultName'] as String;

    final currentRoom = _state.classrooms.isNotEmpty
        ? _state.classrooms.firstWhere(
            (r) => r.id == _selectedRoomId,
            orElse: () => _state.classrooms.first,
          )
        : null;

    final countInZone = currentRoom?.devices
            .where((d) => d.zone == _selectedZone && d.type == categoryItem['type'])
            .length ??
        0;

    _deviceNameController.text = '$prefix ${countInZone + 1}';
  }

  void _updateBatchDefaultNames() {
    for (int i = 0; i < _batchChannels.length; i++) {
      final ch = _batchChannels[i];
      if (ch.category == 'Light') {
        ch.nameController.text = '$_selectedZone Light ${i + 1}';
      } else if (ch.category == 'Ceiling Fan') {
        ch.nameController.text = '$_selectedZone Fan ${i + 1}';
      } else if (ch.category == 'AC') {
        ch.nameController.text = '$_selectedZone AC Unit';
      }
    }
  }

  void _setBatchChannelCategory(int index, String category) {
    HapticFeedback.selectionClick();
    setState(() {
      final ch = _batchChannels[index];
      ch.category = category;
      if (category == 'Ceiling Fan') {
        ch.type = DeviceType.fan;
        ch.nameController.text = '$_selectedZone Fan ${ch.relayNumber}';
      } else if (category == 'Light') {
        ch.type = DeviceType.lighting;
        ch.nameController.text = '$_selectedZone Light ${ch.relayNumber}';
      } else {
        ch.type = DeviceType.hvac;
        ch.nameController.text = '$_selectedZone AC Unit';
      }
    });
  }

  void _showAddZoneDialog() {
    final curRoom = _state.classrooms.firstWhere(
      (r) => r.id == _selectedRoomId,
      orElse: () => _state.classrooms.first,
    );
    final nextZoneNum = curRoom.zones.length + 1;
    final controller = TextEditingController(text: 'Zone $nextZoneNum');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: AppColors.primary.withValues(alpha: 0.3)),
        ),
        title: Row(
          children: [
            const Icon(Icons.add_box, color: AppColors.primary),
            const SizedBox(width: 8),
            Text('Add Control Zone', style: AppTypography.headlineSm(fontSize: 16)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Add a dedicated zone & switchboard to ${curRoom.roomNumber}:',
              style: AppTypography.bodySm(color: AppColors.outline),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              style: AppTypography.bodyMd(),
              decoration: InputDecoration(
                labelText: 'Zone Name (e.g. Zone 4)',
                filled: true,
                fillColor: AppColors.surfaceContainerLowest,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('CANCEL', style: AppTypography.labelMd(color: AppColors.outline)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: AppColors.surfaceContainerLowest,
            ),
            onPressed: () {
              final newName = controller.text.trim();
              if (newName.isNotEmpty) {
                _state.addZone(_selectedRoomId, newName);
                setState(() {
                  _selectedZone = newName;
                  final match = RegExp(r'(\d+)').firstMatch(newName);
                  if (match != null) {
                    final bId = int.tryParse(match.group(1) ?? '') ?? 1;
                    _selectedBoardId = bId;
                    _selectedBoardName = 'Switchboard #$bId';
                  }
                  _updateBatchDefaultNames();
                });
                Navigator.pop(ctx);
                CyberToast.show(
                  context,
                  message: 'Created $newName in ${curRoom.roomNumber}',
                  type: ToastType.success,
                );
              }
            },
            child: Text('ADD ZONE', style: AppTypography.labelMd().copyWith(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showCustomGpioDialog() {
    final controller = TextEditingController(text: _selectedGpio.toString());
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
              const Icon(Icons.settings_input_component, color: AppColors.primary),
              const SizedBox(width: 8),
              Text('Custom GPIO Pin', style: AppTypography.headlineSm(fontSize: 16)),
            ],
          ),
          content: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            autofocus: true,
            style: AppTypography.bodyMd(),
            decoration: InputDecoration(
              labelText: 'ESP32 GPIO Number (0-39)',
              prefixText: 'GPIO ',
              filled: true,
              fillColor: AppColors.surfaceContainerLowest,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
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
                final p = int.tryParse(controller.text);
                if (p != null && p >= 0 && p <= 39) {
                  setState(() => _selectedGpio = p);
                  Navigator.pop(context);
                }
              },
              child: Text('SET PIN', style: AppTypography.labelMd().copyWith(fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  // --- Register Batch Devices (All 4 Relays Under Selected Zone) ---
  void _registerBatchDevices() {
    if (_state.classrooms.isEmpty || _selectedRoomId.isEmpty) {
      CyberToast.show(
        context,
        message: 'Please provision a classroom first before adding devices.',
        type: ToastType.error,
      );
      return;
    }

    final enabledChannels = _batchChannels.where((c) => c.enabled).toList();
    if (enabledChannels.isEmpty) {
      CyberToast.show(
        context,
        message: 'Please enable at least 1 relay channel to add.',
        type: ToastType.error,
      );
      return;
    }

    HapticFeedback.mediumImpact();

    final String hardwareId = _selectedBoardId > 0
        ? (_macController.text.trim().isNotEmpty && _macController.text.trim() != 'Unassigned'
            ? _macController.text.trim()
            : 'ESP32_Board_$_selectedBoardId')
        : 'Virtual / Unassigned';

    final List<ClassroomDevice> newDevices = [];
    final currentRoom = _state.classrooms.firstWhere((r) => r.id == _selectedRoomId);

    for (final ch in enabledChannels) {
      final devName = ch.nameController.text.trim().isNotEmpty
          ? ch.nameController.text.trim()
          : '$_selectedZone ${ch.category} (Ch ${ch.relayNumber})';

      String statusDesc;
      if (ch.type == DeviceType.fan) {
        statusDesc = ch.defaultOn ? 'Speed 3 · Forward Airflow' : 'Standby · Array Off';
      } else if (ch.type == DeviceType.lighting) {
        statusDesc = ch.defaultOn ? '100% Brightness · Relay Closed' : 'Standby · Power Off';
      } else {
        statusDesc = ch.defaultOn ? 'Cooling 22°C · Active' : 'Standby · Idle';
      }

      final device = ClassroomDevice(
        id: 'dev-${DateTime.now().millisecondsSinceEpoch % 100000}-${ch.relayNumber}',
        name: devName,
        type: ch.type,
        statusDescription: statusDesc,
        isOn: ch.defaultOn,
        zone: _selectedZone,
        relayChannel: ch.type == DeviceType.hvac
            ? 'IR TRANSMITTER (GPIO 4)'
            : 'RELAY ${ch.relayNumber} (GPIO ${ch.gpio})',
        hardwareModel: ch.type == DeviceType.hvac
            ? 'Gree AC Optical Controller (IR)'
            : 'Smart Relay Switch',
        zigbeeOrBleNode: _selectedBoardName,
        macAddress: hardwareId,
        protocol: ch.type == DeviceType.hvac ? 'GREE IR' : _selectedProtocol,
        fanSpeed: ch.type == DeviceType.fan ? (ch.defaultOn ? 3 : 0) : 0,
        brightness: ch.type == DeviceType.lighting ? 100.0 : 0.0,
        temperature: ch.type == DeviceType.hvac ? 22 : 24,
        hvacMode: ch.type == DeviceType.hvac ? 'COOL' : 'AUTO',
        acSwing: false,
      );
      newDevices.add(device);
    }

    _state.addDevices(_selectedRoomId, newDevices);

    CyberToast.show(
      context,
      message: 'Added ${newDevices.length} devices to $_selectedZone in ${currentRoom.roomNumber}.',
      type: ToastType.success,
    );

    Navigator.pop(context);
  }

  // --- Register Single Appliance ---
  void _registerSingleDevice() {
    final devName = _deviceNameController.text.trim();
    if (_state.classrooms.isEmpty || _selectedRoomId.isEmpty) {
      CyberToast.show(
        context,
        message: 'Please provision a classroom first before adding devices.',
        type: ToastType.error,
      );
      return;
    }

    if (devName.isEmpty) {
      CyberToast.show(
        context,
        message: 'Please enter a device name.',
        type: ToastType.error,
      );
      return;
    }

    HapticFeedback.mediumImpact();

    DeviceType type;
    String statusDesc;
    final chNum = _selectedRelayNumber;
    final relayChannel = _selectedCategory == 'AC'
        ? 'IR TRANSMITTER (GPIO 4)'
        : 'RELAY $chNum (GPIO $_selectedGpio)';

    if (_selectedCategory == 'Ceiling Fan') {
      type = DeviceType.fan;
      statusDesc = _defaultOn ? 'Speed 3 · Forward Airflow' : 'Standby · Array Off';
    } else if (_selectedCategory == 'Light') {
      type = DeviceType.lighting;
      statusDesc = _defaultOn ? '100% Brightness · Relay Closed' : 'Standby · Power Off';
    } else {
      type = DeviceType.hvac;
      statusDesc = _defaultOn ? 'Cooling 22°C · Active' : 'Standby · Idle';
    }

    final String hardwareId = _selectedBoardId > 0
        ? (_macController.text.trim().isNotEmpty && _macController.text.trim() != 'Unassigned'
            ? _macController.text.trim()
            : 'ESP32_Board_$_selectedBoardId')
        : 'Virtual / Unassigned';

    final newDevice = ClassroomDevice(
      id: 'dev-${DateTime.now().millisecondsSinceEpoch % 10000}',
      name: devName,
      type: type,
      statusDescription: statusDesc,
      isOn: _defaultOn,
      zone: _selectedZone,
      relayChannel: relayChannel,
      hardwareModel: type == DeviceType.hvac
          ? 'Gree AC Optical Controller (IR)'
          : 'Smart Relay Switch',
      zigbeeOrBleNode: _selectedBoardName,
      macAddress: hardwareId,
      protocol: type == DeviceType.hvac ? 'GREE IR' : _selectedProtocol,
      fanSpeed: type == DeviceType.fan ? (_defaultOn ? 3 : 0) : 0,
      brightness: type == DeviceType.lighting ? 100.0 : 0.0,
      temperature: type == DeviceType.hvac ? 22 : 24,
      hvacMode: type == DeviceType.hvac ? 'COOL' : 'AUTO',
      acSwing: false,
    );

    _state.addDevice(_selectedRoomId, newDevice);

    final targetRoom = _state.classrooms.firstWhere((r) => r.id == _selectedRoomId);

    CyberToast.show(
      context,
      message: '$devName assigned to $_selectedZone in ${targetRoom.roomNumber}.',
      type: ToastType.success,
    );

    if (_keepOpenAfterSingleAdd) {
      setState(() {
        _updateDefaultDeviceName();
      });
    } else {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final onlineNodes = ConnectivityState().discoveredIpNodes;
    final currentRoom = _state.classrooms.isNotEmpty
        ? _state.classrooms.firstWhere(
            (r) => r.id == _selectedRoomId,
            orElse: () => _state.classrooms.first,
          )
        : null;
    final availableZones = currentRoom?.zones ?? ['Zone 1', 'Zone 2', 'Zone 3'];

    return Scaffold(
      backgroundColor: AppColors.surfaceContainerLowest,
      appBar: AppBar(
        backgroundColor: AppColors.surface.withValues(alpha: 0.90),
        leading: IconButton(
          icon: Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: AppColors.surfaceContainerHigh,
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: const Icon(Icons.arrow_back, size: 18, color: AppColors.primary),
          ),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Add Device',
          style: AppTypography.headlineSm(color: AppColors.onSurface),
        ),
        actions: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: AppColors.surfaceContainerLow,
              border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const PulsingBeacon(size: 5, color: AppColors.primary),
                const SizedBox(width: 6),
                Text(
                  'UNIVERSAL RELAYS',
                  style: AppTypography.labelSm(color: AppColors.primary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Mode Switcher: Batch (4 Relays) vs Single Device
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: AppColors.surfaceContainerLow,
                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setState(() => _mode = AddProvisioningMode.batchZone);
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 140),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          color: _mode == AddProvisioningMode.batchZone ? AppColors.primary : Colors.transparent,
                          boxShadow: _mode == AddProvisioningMode.batchZone
                              ? [BoxShadow(color: AppColors.primary.withValues(alpha: 0.35), blurRadius: 8)]
                              : null,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.dynamic_feed,
                              size: 15,
                              color: _mode == AddProvisioningMode.batchZone
                                  ? AppColors.surfaceContainerLowest
                                  : AppColors.outline,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Batch (4 Relays)',
                              style: AppTypography.labelSm(
                                color: _mode == AddProvisioningMode.batchZone
                                    ? AppColors.surfaceContainerLowest
                                    : AppColors.onSurfaceVariant,
                              ).copyWith(fontWeight: FontWeight.bold, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setState(() => _mode = AddProvisioningMode.singleAppliance);
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 140),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          color: _mode == AddProvisioningMode.singleAppliance ? AppColors.primary : Colors.transparent,
                          boxShadow: _mode == AddProvisioningMode.singleAppliance
                              ? [BoxShadow(color: AppColors.primary.withValues(alpha: 0.35), blurRadius: 8)]
                              : null,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.electrical_services,
                              size: 15,
                              color: _mode == AddProvisioningMode.singleAppliance
                                  ? AppColors.surfaceContainerLowest
                                  : AppColors.outline,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Single Device',
                              style: AppTypography.labelSm(
                                color: _mode == AddProvisioningMode.singleAppliance
                                    ? AppColors.surfaceContainerLowest
                                    : AppColors.onSurfaceVariant,
                              ).copyWith(fontWeight: FontWeight.bold, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Form Card
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: AppColors.surfaceContainerLow.withValues(alpha: 0.85),
                border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _mode == AddProvisioningMode.batchZone ? Icons.layers : Icons.electrical_services,
                        size: 18,
                        color: AppColors.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _mode == AddProvisioningMode.batchZone
                              ? 'Batch Setup'
                              : 'Single Device',
                          style: AppTypography.headlineSm(color: AppColors.onSurface).copyWith(fontSize: 15),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
                        ),
                        child: Text(
                          _mode == AddProvisioningMode.batchZone ? '4 RELAYS' : 'SINGLE',
                          style: AppTypography.labelSm(color: AppColors.primary)
                              .copyWith(fontWeight: FontWeight.bold, fontSize: 10),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Divider(color: Colors.white.withValues(alpha: 0.08)),
                  const SizedBox(height: 14),

                  // Classroom Assignment Dropdown
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'ASSIGN TO CLASSROOM',
                        style: AppTypography.labelSm(color: AppColors.onSurfaceVariant),
                      ),
                      Text('REQUIRED', style: AppTypography.labelSm(color: AppColors.primary)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  CyberDropdown<String>(
                    value: (_selectedRoomId.isNotEmpty && _state.classrooms.any((r) => r.id == _selectedRoomId))
                        ? _selectedRoomId
                        : (_state.classrooms.isNotEmpty ? _state.classrooms.first.id : null),
                    hint: _state.classrooms.isEmpty ? 'No classrooms configured' : 'Select Classroom',
                    sheetTitle: 'Target Classroom',
                    prefixIcon: Icons.meeting_room,
                    items: _state.classrooms.map((room) {
                      return CyberDropdownItem<String>(
                        value: room.id,
                        label: '${room.roomNumber} - ${room.name}',
                        subtitle: '${room.building} · ${room.zoneCount} Control Zones',
                        icon: Icons.meeting_room,
                      );
                    }).toList(),
                    onChanged: (val) {
                      setState(() {
                        _selectedRoomId = val;
                        _updateDefaultZone();
                        _updateBatchDefaultNames();
                      });
                    },
                  ),

                  if (_selectedRoomId.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceContainerLowest,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.developer_board, size: 14, color: AppColors.primary),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'MQTT ID: "$_selectedRoomId"',
                                style: AppTypography.labelSm(color: AppColors.primary)
                                    .copyWith(fontSize: 11, fontFamily: 'monospace', fontWeight: FontWeight.bold),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            InkWell(
                              borderRadius: BorderRadius.circular(4),
                              onTap: () {
                                Clipboard.setData(ClipboardData(text: _selectedRoomId));
                                CyberToast.show(
                                  context,
                                  message: 'Copied "$_selectedRoomId" to clipboard',
                                  type: ToastType.success,
                                );
                              },
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(4),
                                  color: AppColors.primary.withValues(alpha: 0.12),
                                ),
                                child: const Icon(Icons.copy, size: 12, color: AppColors.primary),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                  const SizedBox(height: 14),

                  // Zone Selection
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.grid_view_rounded, size: 15, color: AppColors.primary),
                          const SizedBox(width: 6),
                          Text(
                            'TARGET CONTROL ZONE',
                            style: AppTypography.labelSm(color: AppColors.onSurfaceVariant)
                                .copyWith(fontWeight: FontWeight.bold, letterSpacing: 0.6),
                          ),
                        ],
                      ),
                      GestureDetector(
                        onTap: _showAddZoneDialog,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(6),
                            color: AppColors.secondary.withValues(alpha: 0.12),
                            border: Border.all(color: AppColors.secondary.withValues(alpha: 0.35)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.add, size: 13, color: AppColors.secondary),
                              const SizedBox(width: 4),
                              Text(
                                'New Zone',
                                style: AppTypography.labelSm(color: AppColors.secondary)
                                    .copyWith(fontSize: 10, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(
                    'Assign to a zone powered by physical Switchboard #$_selectedBoardId',
                    style: AppTypography.bodySm(color: AppColors.outline).copyWith(fontSize: 11),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ...availableZones.map((zone) {
                        final isSelected = _selectedZone == zone;
                        final countInZone = currentRoom?.devicesInZone(zone).length ?? 0;
                        final displayName = currentRoom?.getZoneDisplayName(zone) ?? zone;
                        final hasAlias = displayName.toLowerCase() != zone.toLowerCase();
                        return GestureDetector(
                          onTap: () => _onZoneSelected(zone),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 140),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              color: isSelected ? AppColors.primary : AppColors.surfaceContainer,
                              border: Border.all(
                                color: isSelected ? AppColors.primary : Colors.white.withValues(alpha: 0.1),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.grid_view,
                                  size: 14,
                                  color: isSelected ? AppColors.surfaceContainerLowest : AppColors.primary,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  hasAlias ? '$displayName ($zone)' : zone,
                                  style: AppTypography.labelSm(
                                    color: isSelected ? AppColors.surfaceContainerLowest : AppColors.onSurface,
                                  ).copyWith(fontWeight: FontWeight.w600),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  '($countInZone)',
                                  style: AppTypography.labelSm(
                                    color: isSelected
                                        ? AppColors.surfaceContainerLowest.withValues(alpha: 0.8)
                                        : AppColors.outline,
                                  ).copyWith(fontSize: 10),
                                ),
                              ],
                            ),
                          ),
                        );
                      }),
                      // Inline matching "+ New Zone" button
                      GestureDetector(
                        onTap: _showAddZoneDialog,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 140),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            color: AppColors.surfaceContainer,
                            border: Border.all(
                              color: AppColors.secondary.withValues(alpha: 0.4),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.add, size: 14, color: AppColors.secondary),
                              const SizedBox(width: 6),
                              Text(
                                'New Zone',
                                style: AppTypography.labelSm(color: AppColors.secondary)
                                    .copyWith(fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 16),

                  // Switchboard Controller Selection Section
                  Row(
                    children: [
                      const Icon(Icons.developer_board, size: 16, color: AppColors.primary),
                      const SizedBox(width: 8),
                      Text(
                        'ASSIGN TO SWITCHBOARD (ESP32)',
                        style: AppTypography.labelSm(color: AppColors.onSurfaceVariant),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Matched to Switchboard #$_selectedBoardId (Relays 1-4 on Pins 18, 19, 21, 22)',
                    style: AppTypography.bodySm(color: AppColors.outline).copyWith(fontSize: 11),
                  ),
                  const SizedBox(height: 10),

                  // Dedicated Clean MQTT Scan Button
                  SizedBox(
                    width: double.infinity,
                    height: 42,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        backgroundColor: _isScanningMqtt
                            ? AppColors.primary.withValues(alpha: 0.15)
                            : AppColors.surfaceContainerLowest,
                        side: BorderSide(
                          color: _isScanningMqtt
                              ? AppColors.primary
                              : AppColors.primary.withValues(alpha: 0.45),
                          width: 1.2,
                        ),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: _isScanningMqtt ? null : _runMqttHardwareScan,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_isScanningMqtt) ...[
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Scanning MQTT Network...',
                              style: AppTypography.labelMd(color: AppColors.primary).copyWith(
                                fontWeight: FontWeight.bold,
                                fontSize: 12.5,
                              ),
                            ),
                          ] else ...[
                            const Icon(Icons.radar, size: 16, color: AppColors.primary),
                            const SizedBox(width: 8),
                            Text(
                              'Scan for ESP32 Switchboards',
                              style: AppTypography.labelMd(color: AppColors.primary).copyWith(
                                fontWeight: FontWeight.bold,
                                fontSize: 12.5,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 10),

                  if (_isScanningMqtt)
                    Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: AppColors.surfaceContainerLowest,
                        border: Border.all(color: AppColors.primary.withValues(alpha: 0.2)),
                      ),
                      child: Row(
                        children: [
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Querying MQTT broker for active switchboards in room...',
                              style: AppTypography.bodySm(color: AppColors.onSurfaceVariant).copyWith(fontSize: 11),
                            ),
                          ),
                        ],
                      ),
                    ),

                  // Physical Switchboard Hardware Scan Results
                  if (onlineNodes.isEmpty) ...[
                    Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: AppColors.surfaceContainerLowest,
                        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white.withValues(alpha: 0.05),
                            ),
                            child: const Icon(Icons.sensors_off, size: 20, color: AppColors.outline),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'No ESP32 Switchboards Detected',
                                  style: AppTypography.labelMd(color: AppColors.onSurface)
                                      .copyWith(fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Power on your ESP32 controller with CLASSROOM_ID "$_selectedRoomId" and tap the scan button above.',
                                  style: AppTypography.bodySm(color: AppColors.outline).copyWith(fontSize: 10.5),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        'OR SELECT BOARD MANUALLY (OFFLINE SETUP):',
                        style: AppTypography.labelSm(color: AppColors.outline)
                            .copyWith(fontSize: 9.5, letterSpacing: 0.4),
                      ),
                    ),
                    Builder(
                      builder: (context) {
                        final int maxZones = math.max(currentRoom?.zones.length ?? 0, currentRoom?.zoneCount ?? 0);
                        final List<int> manualBoardIds = List.generate(math.max(maxZones, 1), (i) => i + 1);

                        return LayoutBuilder(
                          builder: (context, constraints) {
                            final int columns = constraints.maxWidth > 320 ? 4 : 3;
                            final double cardWidth = (constraints.maxWidth - ((columns - 1) * 8)) / columns;

                            return Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: manualBoardIds.map((bId) {
                                final isSelected = _selectedBoardId == bId;
                                final zoneKey = (currentRoom != null && bId <= currentRoom.zones.length)
                                    ? currentRoom.zones[bId - 1]
                                    : 'Zone $bId';
                                final zoneDisplayName = currentRoom?.getZoneDisplayName(zoneKey) ?? zoneKey;

                                return SizedBox(
                                  width: cardWidth,
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(8),
                                    onTap: () {
                                      HapticFeedback.selectionClick();
                                      setState(() {
                                        _selectedBoardId = bId;
                                        _selectedBoardName = 'Switchboard #$bId';
                                        _macController.text = 'ESP32_Board_$bId';
                                        if (currentRoom != null && bId <= currentRoom.zones.length) {
                                          _selectedZone = currentRoom.zones[bId - 1];
                                        }
                                        _updateDefaultDeviceName();
                                      });
                                    },
                                    child: AnimatedContainer(
                                      duration: const Duration(milliseconds: 140),
                                      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(8),
                                        color: isSelected
                                            ? AppColors.primary.withValues(alpha: 0.18)
                                            : AppColors.surfaceContainerLowest,
                                        border: Border.all(
                                          color: isSelected ? AppColors.primary : Colors.white.withValues(alpha: 0.08),
                                          width: isSelected ? 1.5 : 1.0,
                                        ),
                                      ),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Icons.developer_board,
                                            size: 16,
                                            color: isSelected ? AppColors.primary : AppColors.outline,
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            'Board #$bId',
                                            style: AppTypography.labelSm(
                                              color: isSelected ? AppColors.primary : AppColors.onSurface,
                                            ).copyWith(fontWeight: FontWeight.bold, fontSize: 11),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          Text(
                                            zoneDisplayName,
                                            style: AppTypography.bodySm(
                                              color: isSelected
                                                  ? AppColors.primary.withValues(alpha: 0.8)
                                                  : AppColors.outline,
                                            ).copyWith(fontSize: 9),
                                            overflow: TextOverflow.ellipsis,
                                            maxLines: 1,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              }).toList(),
                            );
                          },
                        );
                      },
                    ),
                    const SizedBox(height: 10),
                  ] else ...[
                    // Online Discovered Nodes
                    ...onlineNodes.map((node) {
                      final bId = node.boardId;
                      final isSelected = _selectedBoardId == bId;
                      final zoneKey = (currentRoom != null && bId <= currentRoom.zones.length)
                          ? currentRoom.zones[bId - 1]
                          : 'Zone $bId';
                      final zoneDisplay = currentRoom?.getZoneDisplayName(zoneKey) ?? zoneKey;
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () {
                            HapticFeedback.selectionClick();
                            setState(() {
                              _selectedBoardId = bId;
                              _selectedBoardName = 'Switchboard #$bId';
                              _macController.text = node.ip;
                              if (currentRoom != null && bId <= currentRoom.zones.length) {
                                _selectedZone = currentRoom.zones[bId - 1];
                              }
                              _updateDefaultDeviceName();
                            });
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 140),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              color: isSelected ? AppColors.surfaceContainerHigh : AppColors.surfaceContainerLowest,
                              border: Border.all(
                                color: isSelected ? AppColors.primary : Colors.white.withValues(alpha: 0.08),
                                width: isSelected ? 1.8 : 1.0,
                              ),
                              boxShadow: isSelected
                                  ? [
                                      BoxShadow(
                                        color: AppColors.primary.withValues(alpha: 0.2),
                                        blurRadius: 8,
                                      )
                                    ]
                                  : null,
                            ),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(7),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: AppColors.onlineMint.withValues(alpha: 0.15),
                                  ),
                                  child: const Icon(
                                    Icons.developer_board,
                                    size: 16,
                                    color: AppColors.onlineMint,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Text(
                                            'Switchboard #$bId ($zoneDisplay)',
                                            style: AppTypography.labelMd(color: AppColors.onSurface)
                                                .copyWith(fontWeight: FontWeight.bold),
                                          ),
                                          const SizedBox(width: 8),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              borderRadius: BorderRadius.circular(4),
                                              color: AppColors.onlineMint.withValues(alpha: 0.15),
                                            ),
                                            child: Text(
                                              'ONLINE',
                                              style: AppTypography.labelSm(
                                                color: AppColors.onlineMint,
                                              ).copyWith(fontSize: 8.5, fontWeight: FontWeight.bold),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        'IP: ${node.ip} • Signal: ${node.responseTimeMs} dBm • 4 Universal Relays',
                                        style: AppTypography.bodySm(color: AppColors.outline).copyWith(fontSize: 10),
                                      ),
                                    ],
                                  ),
                                ),
                                Radio<int>(
                                  value: bId,
                                  groupValue: _selectedBoardId,
                                  activeColor: AppColors.primary,
                                  onChanged: (val) {
                                    if (val != null) {
                                      setState(() {
                                        _selectedBoardId = val;
                                        _selectedBoardName = 'Switchboard #$val';
                                        _macController.text = node.ip;
                                        _updateDefaultDeviceName();
                                      });
                                    }
                                  },
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }),
                  ],

                  // Virtual Mode Option
                  InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () {
                      HapticFeedback.selectionClick();
                      setState(() {
                        _selectedBoardId = 0;
                        _selectedBoardName = 'Virtual Mode';
                        _macController.text = 'Unassigned';
                        _updateDefaultDeviceName();
                      });
                    },
                    child: Container(
                      margin: const EdgeInsets.only(top: 2, bottom: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: _selectedBoardId == 0 ? AppColors.surfaceContainerHigh : AppColors.surfaceContainerLowest,
                        border: Border.all(
                          color: _selectedBoardId == 0 ? AppColors.primary : Colors.white.withValues(alpha: 0.05),
                          width: _selectedBoardId == 0 ? 1.5 : 1.0,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.computer, size: 16, color: _selectedBoardId == 0 ? AppColors.primary : AppColors.outline),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Virtual Mode (No physical hardware binding)',
                              style: AppTypography.bodySm(
                                color: _selectedBoardId == 0 ? AppColors.primary : AppColors.onSurfaceVariant,
                              ).copyWith(fontSize: 11),
                            ),
                          ),
                          Radio<int>(
                            value: 0,
                            groupValue: _selectedBoardId,
                            activeColor: AppColors.primary,
                            onChanged: (val) {
                              if (val != null) {
                                setState(() {
                                  _selectedBoardId = 0;
                                  _selectedBoardName = 'Virtual Mode';
                                  _macController.text = 'Unassigned';
                                  _updateDefaultDeviceName();
                                });
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),

                  // =========================================================
                  // BATCH MODE: 4 UNIVERSAL RELAY CHANNELS
                  // =========================================================
                  if (_mode == AddProvisioningMode.batchZone) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.primary.withValues(alpha: 0.2)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline, size: 16, color: AppColors.primary),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Configure relay channels (Pins 18, 19, 21, 22) for fans/lights, or Optical IR (GPIO 4) for AC:',
                              style: AppTypography.bodySm(color: AppColors.primary).copyWith(fontSize: 11),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),

                    // 4 Channel Cards
                    ..._batchChannels.asMap().entries.map((entry) {
                      final idx = entry.key;
                      final ch = entry.value;

                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          color: ch.enabled
                              ? AppColors.surfaceContainerLowest
                              : AppColors.surfaceContainerLowest.withValues(alpha: 0.4),
                          border: Border.all(
                            color: ch.enabled
                                ? AppColors.primary.withValues(alpha: 0.35)
                                : Colors.white.withValues(alpha: 0.06),
                            width: ch.enabled ? 1.2 : 1.0,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Channel Header
                            Row(
                              children: [
                                SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: Checkbox(
                                    value: ch.enabled,
                                    activeColor: AppColors.primary,
                                    onChanged: (val) {
                                      HapticFeedback.selectionClick();
                                      setState(() => ch.enabled = val ?? false);
                                    },
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(6),
                                    color: ch.enabled
                                        ? (ch.category == 'AC'
                                            ? AppColors.secondary.withValues(alpha: 0.15)
                                            : AppColors.primary.withValues(alpha: 0.15))
                                        : Colors.white.withValues(alpha: 0.05),
                                  ),
                                  child: Text(
                                    ch.category == 'AC'
                                        ? 'OPTICAL IR (GPIO 4)'
                                        : 'RELAY ${ch.relayNumber} (GPIO ${ch.gpio})',
                                    style: AppTypography.labelSm(
                                      color: ch.enabled
                                          ? (ch.category == 'AC' ? AppColors.secondary : AppColors.primary)
                                          : AppColors.outline,
                                    ).copyWith(fontWeight: FontWeight.bold, fontSize: 11),
                                  ),
                                ),
                                const Spacer(),
                                if (ch.enabled)
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(4),
                                      color: (ch.category == 'AC' ? AppColors.secondary : AppColors.primary).withValues(alpha: 0.12),
                                    ),
                                    child: Text(
                                      ch.category == 'Ceiling Fan' ? 'FAN' : ch.category.toUpperCase(),
                                      style: AppTypography.labelSm(color: ch.category == 'AC' ? AppColors.secondary : AppColors.primary)
                                          .copyWith(fontSize: 9, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                              ],
                            ),

                            if (ch.enabled) ...[
                              const SizedBox(height: 10),
                              // Appliance Type Chips for this channel
                              Text(
                                ch.category == 'AC'
                                    ? 'Appliance Type (Optical IR):'
                                    : 'Appliance Type on GPIO ${ch.gpio}:',
                                style: AppTypography.labelSm(color: AppColors.onSurfaceVariant).copyWith(fontSize: 10),
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  // Light
                                  Expanded(
                                    child: _buildBatchTypeChip(
                                      title: 'Light',
                                      icon: Icons.lightbulb_outline,
                                      isSelected: ch.category == 'Light',
                                      onTap: () => _setBatchChannelCategory(idx, 'Light'),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  // Ceiling Fan
                                  Expanded(
                                    child: _buildBatchTypeChip(
                                      title: 'Ceiling Fan',
                                      isFan: true,
                                      isSelected: ch.category == 'Ceiling Fan',
                                      onTap: () => _setBatchChannelCategory(idx, 'Ceiling Fan'),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  // AC
                                  Expanded(
                                    child: _buildBatchTypeChip(
                                      title: 'AC',
                                      icon: Icons.ac_unit,
                                      isSelected: ch.category == 'AC',
                                      onTap: () => _setBatchChannelCategory(idx, 'AC'),
                                    ),
                                  ),
                                ],
                              ),
                              if (ch.category == 'AC') ...[
                                const SizedBox(height: 10),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(8),
                                    color: AppColors.secondary.withValues(alpha: 0.08),
                                    border: Border.all(
                                      color: AppColors.secondary.withValues(alpha: 0.28),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.all(6),
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(6),
                                          color: AppColors.secondary.withValues(alpha: 0.18),
                                        ),
                                        child: const Icon(Icons.settings_remote, size: 16, color: AppColors.secondary),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              'OPTICAL INFRARED TRANSMITTER',
                                              style: AppTypography.labelSm(color: AppColors.secondary)
                                                  .copyWith(fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                                            ),
                                            const SizedBox(height: 1),
                                            Text(
                                              'Direct Gree AC Controller (GPIO 4)',
                                              style: AppTypography.bodySm(color: AppColors.onSurface)
                                                  .copyWith(fontSize: 11, fontWeight: FontWeight.w600),
                                            ),
                                            Text(
                                              '38 kHz optical pulses · Relays bypassed',
                                              style: AppTypography.labelSm(color: AppColors.outline)
                                                  .copyWith(fontSize: 9.5),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(4),
                                          color: AppColors.secondary.withValues(alpha: 0.15),
                                          border: Border.all(color: AppColors.secondary.withValues(alpha: 0.3)),
                                        ),
                                        child: Text(
                                          'GPIO 4',
                                          style: AppTypography.labelSm(color: AppColors.secondary)
                                              .copyWith(fontSize: 8.5, fontWeight: FontWeight.bold),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                              const SizedBox(height: 10),

                              // Device Name Field
                              Text(
                                ch.category == 'AC' ? 'AC Appliance Label:' : 'Appliance Label:',
                                style: AppTypography.labelSm(color: AppColors.onSurfaceVariant).copyWith(fontSize: 10),
                              ),
                              const SizedBox(height: 4),
                              Container(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(8),
                                  color: AppColors.surfaceContainer,
                                  border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                                ),
                                child: TextField(
                                  controller: ch.nameController,
                                  style: AppTypography.bodyMd(color: AppColors.onSurface).copyWith(fontSize: 13),
                                  decoration: InputDecoration(
                                    isDense: true,
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                                    border: InputBorder.none,
                                    hintText: ch.category == 'AC'
                                        ? 'e.g. $_selectedZone AC Unit'
                                        : 'e.g. $_selectedZone ${ch.category} ${ch.relayNumber}',
                                  ),
                                ),
                              ),
                              const SizedBox(height: 10),

                              // Initial State Toggle
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Expanded(
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.power_settings_new,
                                          size: 14,
                                          color: ch.defaultOn ? AppColors.primary : AppColors.outline,
                                        ),
                                        const SizedBox(width: 6),
                                        Expanded(
                                          child: Text(
                                            ch.category == 'AC'
                                                ? (ch.defaultOn ? 'Default ON (Power Active)' : 'Default OFF (Standby)')
                                                : (ch.defaultOn ? 'Default ON (Relay Closed)' : 'Default OFF (Relay Open)'),
                                            style: AppTypography.bodySm(
                                              color: ch.defaultOn ? AppColors.onSurface : AppColors.outline,
                                            ).copyWith(fontSize: 11),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  CyberSwitch(
                                    width: 38,
                                    height: 22,
                                    value: ch.defaultOn,
                                    onChanged: (val) => setState(() => ch.defaultOn = val),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      );
                    }),
                  ] else ...[
                    // =========================================================
                    // SINGLE APPLIANCE MODE
                    // =========================================================
                    Text(
                      'DEVICE TYPE (FAN / LIGHT / AC)',
                      style: AppTypography.labelSm(color: AppColors.onSurfaceVariant),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: _deviceCategories.map((cat) {
                        final title = cat['title'] as String;
                        final icon = cat['icon'] as IconData;
                        final isSelected = _selectedCategory == title;

                        return Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 3),
                            child: GestureDetector(
                              onTap: () {
                                HapticFeedback.selectionClick();
                                setState(() {
                                  _selectedCategory = title;
                                  if (title == 'Ceiling Fan') {
                                    _selectedGpio = 18;
                                  } else if (title == 'Light') {
                                    _selectedGpio = 21;
                                  } else {
                                    _selectedGpio = 4;
                                  }
                                  final count = currentRoom?.devices.where((d) => d.type == cat['type']).length ?? 0;
                                  _deviceNameController.text = '${cat['defaultName']} ${count + 1}';
                                });
                              },
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 140),
                                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(10),
                                  color: isSelected ? AppColors.surfaceContainerHigh : AppColors.surfaceContainer,
                                  border: Border.all(
                                    color: isSelected ? AppColors.primary : Colors.white.withValues(alpha: 0.08),
                                    width: isSelected ? 1.5 : 1.0,
                                  ),
                                  boxShadow: isSelected
                                      ? [
                                          BoxShadow(
                                            color: AppColors.primary.withValues(alpha: 0.25),
                                            blurRadius: 10,
                                          ),
                                        ]
                                      : null,
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    title == 'Ceiling Fan'
                                        ? CeilingFanIcon(
                                            size: 22,
                                            color: isSelected ? AppColors.primary : AppColors.outline,
                                          )
                                        : Icon(
                                            icon,
                                            size: 22,
                                            color: isSelected ? AppColors.primary : AppColors.outline,
                                          ),
                                    const SizedBox(height: 5),
                                    Text(
                                      title == 'Ceiling Fan' ? 'Fan' : title,
                                      textAlign: TextAlign.center,
                                      style: AppTypography.labelSm(
                                        color: isSelected ? AppColors.primary : AppColors.onSurface,
                                      ).copyWith(fontWeight: isSelected ? FontWeight.bold : FontWeight.normal, fontSize: 11),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),

                    const SizedBox(height: 12),

                    // ESP32 Relay Pinout Card
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: AppColors.surfaceContainerLowest,
                        border: Border.all(
                          color: AppColors.primary.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (_selectedCategory == 'AC') ...[
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(6),
                                    color: AppColors.secondary.withValues(alpha: 0.15),
                                  ),
                                  child: const Icon(Icons.settings_remote, size: 16, color: AppColors.secondary),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        'OPTICAL INFRARED TRANSMITTER (GPIO 4)',
                                        style: AppTypography.labelSm(color: AppColors.secondary)
                                            .copyWith(fontSize: 8.5, letterSpacing: 0.5, fontWeight: FontWeight.bold),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        'IR TRANSMITTER (GPIO 4)',
                                        style: AppTypography.headlineSm(color: AppColors.primary)
                                            .copyWith(fontSize: 12.5, fontWeight: FontWeight.bold),
                                        maxLines: 1,
                                      ),
                                      Text(
                                        'Gree AC Optical Protocol · GPIO 4 Pin',
                                        style: AppTypography.labelSm(color: AppColors.outline)
                                            .copyWith(fontSize: 10, fontWeight: FontWeight.w500),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(6),
                                    color: AppColors.secondary.withValues(alpha: 0.12),
                                    border: Border.all(color: AppColors.secondary.withValues(alpha: 0.3)),
                                  ),
                                  child: Text(
                                    'GPIO 4 · 38 kHz',
                                    style: AppTypography.labelSm(color: AppColors.secondary)
                                        .copyWith(fontSize: 8.5, fontWeight: FontWeight.bold),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Direct optical IR signals sent from ESP32 GPIO 4 to the AC unit via modulated 38 kHz infrared packets.',
                              style: AppTypography.labelSm(color: AppColors.outline).copyWith(fontSize: 10),
                            ),
                          ] else ...[
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(6),
                                    color: AppColors.primary.withValues(alpha: 0.15),
                                  ),
                                  child: const Icon(Icons.developer_board, size: 16, color: AppColors.primary),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        'ASSIGNED SWITCHBOARD RELAY',
                                        style: AppTypography.labelSm(color: AppColors.outline)
                                            .copyWith(fontSize: 8.5, letterSpacing: 0.5),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        'RELAY $_selectedRelayNumber (GPIO $_selectedGpio)',
                                        style: AppTypography.headlineSm(color: AppColors.primary)
                                            .copyWith(fontSize: 12.5, fontWeight: FontWeight.bold),
                                        maxLines: 1,
                                      ),
                                      Text(
                                        _selectedBoardName,
                                        style: AppTypography.labelSm(color: AppColors.outline)
                                            .copyWith(fontSize: 10, fontWeight: FontWeight.w500),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(6),
                                    color: AppColors.primary.withValues(alpha: 0.12),
                                    border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
                                  ),
                                  child: Text(
                                    'ACTIVE LOW',
                                    style: AppTypography.labelSm(color: AppColors.primary)
                                        .copyWith(fontSize: 8.5, fontWeight: FontWeight.bold),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Text(
                              'Select Physical Relay Channel (1 to 4):',
                              style: AppTypography.labelSm(color: AppColors.onSurfaceVariant),
                            ),
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                ..._switchboardRelays.map((r) {
                                  final rNum = r['relay']!;
                                  final rPin = r['gpio']!;
                                  final isSelected = _selectedRelayNumber == rNum;
                                  return ChoiceChip(
                                    label: Text('Relay $rNum (GPIO $rPin)'),
                                    selected: isSelected,
                                    selectedColor: AppColors.primary.withValues(alpha: 0.25),
                                    backgroundColor: AppColors.surfaceContainer,
                                    labelStyle: TextStyle(
                                      color: isSelected ? AppColors.primary : AppColors.onSurfaceVariant,
                                      fontSize: 11,
                                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                    ),
                                    side: BorderSide(
                                      color: isSelected ? AppColors.primary : Colors.white12,
                                    ),
                                    onSelected: (_) {
                                      HapticFeedback.selectionClick();
                                      setState(() {
                                        _selectedRelayNumber = rNum;
                                        _selectedGpio = rPin;
                                      });
                                    },
                                  );
                                }),
                                ActionChip(
                                  label: const Text('+ Custom Pin'),
                                  backgroundColor: AppColors.surfaceContainer,
                                  labelStyle: const TextStyle(color: AppColors.secondary, fontSize: 11),
                                  side: BorderSide(color: AppColors.secondary.withValues(alpha: 0.3)),
                                  onPressed: _showCustomGpioDialog,
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),

                    const SizedBox(height: 14),

                    // Device Name
                    Text(
                      'DEVICE NAME',
                      style: AppTypography.labelSm(color: AppColors.onSurfaceVariant),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: AppColors.surfaceContainer,
                        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                      ),
                      child: TextField(
                        controller: _deviceNameController,
                        style: AppTypography.bodyMd(color: AppColors.onSurface),
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          border: InputBorder.none,
                          hintText: 'e.g. Ceiling Fan 1',
                        ),
                      ),
                    ),

                    const SizedBox(height: 14),

                    // Communication Protocol
                    Text(
                      'COMMUNICATION PROTOCOL',
                      style: AppTypography.labelSm(color: AppColors.onSurfaceVariant),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: AppColors.surfaceContainer,
                        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                      ),
                      child: Row(
                        children: _protocols.map((proto) {
                          final isSelected = _selectedProtocol == proto;
                          return Expanded(
                            child: GestureDetector(
                              onTap: () {
                                HapticFeedback.selectionClick();
                                setState(() => _selectedProtocol = proto);
                              },
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 140),
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(6),
                                  color: isSelected ? AppColors.surfaceContainerHigh : Colors.transparent,
                                  border: isSelected
                                      ? Border.all(color: AppColors.primary.withValues(alpha: 0.3))
                                      : null,
                                ),
                                child: Text(
                                  proto,
                                  textAlign: TextAlign.center,
                                  style: AppTypography.labelSm(
                                    color: isSelected ? AppColors.primary : AppColors.onSurfaceVariant,
                                  ).copyWith(fontWeight: isSelected ? FontWeight.bold : FontWeight.normal),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),

                    const SizedBox(height: 14),

                    // Initial State
                    Text(
                      _selectedCategory == 'AC' ? 'INITIAL POWER STATE' : 'INITIAL RELAY STATE',
                      style: AppTypography.labelSm(color: AppColors.onSurfaceVariant),
                    ),
                    const SizedBox(height: 6),
                    GestureDetector(
                      onTap: () {
                        HapticFeedback.lightImpact();
                        setState(() => _defaultOn = !_defaultOn);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          color: AppColors.surfaceContainer,
                          border: Border.all(
                            color: _defaultOn
                                ? AppColors.primary.withValues(alpha: 0.35)
                                : Colors.white.withValues(alpha: 0.1),
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                color: _defaultOn
                                    ? AppColors.primary.withValues(alpha: 0.15)
                                    : AppColors.surfaceContainerLowest,
                              ),
                              child: Icon(
                                Icons.power_settings_new,
                                size: 18,
                                color: _defaultOn ? AppColors.primary : AppColors.outline,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _selectedCategory == 'AC'
                                        ? (_defaultOn ? 'Default Power ON' : 'Default Power OFF')
                                        : (_defaultOn ? 'Default Relay Closed (ON)' : 'Default Relay Open (OFF)'),
                                    style: AppTypography.bodyMd().copyWith(fontWeight: FontWeight.w600),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    _selectedCategory == 'AC'
                                        ? (_defaultOn
                                            ? 'Transmits optical IR power command on GPIO 4 upon pairing'
                                            : 'AC unit stays in optical standby on startup')
                                        : (_defaultOn
                                            ? 'Applies AC circuit power upon pairing'
                                            : 'Relay contacts stay open on startup'),
                                    style: AppTypography.bodySm(color: AppColors.onSurfaceVariant),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            CyberSwitch(
                              value: _defaultOn,
                              onChanged: (val) => setState(() => _defaultOn = val),
                            ),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 10),

                    // Keep Open Option Tile
                    GestureDetector(
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setState(() => _keepOpenAfterSingleAdd = !_keepOpenAfterSingleAdd);
                      },
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          color: AppColors.surfaceContainerLowest,
                          border: Border.all(
                            color: _keepOpenAfterSingleAdd
                                ? AppColors.primary.withValues(alpha: 0.4)
                                : Colors.white.withValues(alpha: 0.06),
                          ),
                        ),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 20,
                              height: 20,
                              child: Checkbox(
                                value: _keepOpenAfterSingleAdd,
                                activeColor: AppColors.primary,
                                checkColor: AppColors.surfaceContainerLowest,
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                visualDensity: VisualDensity.compact,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                                onChanged: (val) => setState(() => _keepOpenAfterSingleAdd = val ?? false),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Keep form open to quickly add another appliance',
                                style: AppTypography.bodySm(
                                  color: _keepOpenAfterSingleAdd ? AppColors.primary : AppColors.onSurfaceVariant,
                                ).copyWith(fontSize: 11.5, fontWeight: _keepOpenAfterSingleAdd ? FontWeight.w600 : FontWeight.normal),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),

            const SizedBox(height: 20),

            // Register CTA Button
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: AppColors.surfaceContainerLowest,
                  elevation: 6,
                  shadowColor: AppColors.primary.withValues(alpha: 0.5),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: _mode == AddProvisioningMode.batchZone ? _registerBatchDevices : _registerSingleDevice,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.check_circle, size: 20, color: AppColors.surfaceContainerLowest),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _mode == AddProvisioningMode.batchZone
                            ? 'Provision ${_batchChannels.where((c) => c.enabled).length} Appliances to $_selectedZone'
                            : 'Pair & Save Device',
                        textAlign: TextAlign.center,
                        style: AppTypography.headlineSm(
                          color: AppColors.surfaceContainerLowest,
                        ).copyWith(
                          fontWeight: FontWeight.bold,
                          fontSize: _mode == AddProvisioningMode.batchZone ? 12.5 : 14.0,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 12),

            // Cancel
            Center(
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  'Cancel Registration',
                  style: AppTypography.bodySm(color: AppColors.onSurfaceVariant),
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Footer
            Center(
              child: Text(
                'ClassPulse IoT Universal Switchboard Provisioner • v2.6',
                style: AppTypography.labelSm(color: AppColors.outline),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBatchTypeChip({
    required String title,
    IconData? icon,
    bool isFan = false,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final displayTitle = title == 'Ceiling Fan' ? 'Fan' : title;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: isSelected ? AppColors.primary.withValues(alpha: 0.22) : AppColors.surfaceContainer,
          border: Border.all(
            color: isSelected ? AppColors.primary : Colors.white.withValues(alpha: 0.08),
            width: isSelected ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (isFan)
              CeilingFanIcon(
                size: 16,
                color: isSelected ? AppColors.primary : AppColors.outline,
              )
            else
              Icon(
                icon,
                size: 16,
                color: isSelected ? AppColors.primary : AppColors.outline,
              ),
            const SizedBox(width: 5),
            Text(
              displayTitle,
              style: AppTypography.labelSm(
                color: isSelected ? AppColors.primary : AppColors.onSurface,
              ).copyWith(fontSize: 11, fontWeight: isSelected ? FontWeight.bold : FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }
}
