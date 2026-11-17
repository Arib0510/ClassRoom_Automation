import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/connectivity.dart';
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
  int switchGpio;
  String relayLabel;
  String switchName;
  bool enabled;
  String category; // 'Light', 'Ceiling Fan'
  DeviceType type;
  TextEditingController nameController;
  bool defaultOn;

  _BatchChannelConfig({
    required this.relayNumber,
    required this.gpio,
    required this.switchGpio,
    required this.relayLabel,
    required this.switchName,
    this.enabled = true,
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
  final String? preselectedZone;

  const AddDeviceScreen({
    super.key,
    this.preselectedRoomId,
    this.preselectedZone,
  });

  @override
  State<AddDeviceScreen> createState() => _AddDeviceScreenState();
}

class _AddDeviceScreenState extends State<AddDeviceScreen> {
  final ClassroomState _state = ClassroomState();

  AddProvisioningMode _mode = AddProvisioningMode.batchZone;
  final bool _keepOpenAfterSingleAdd = false;

  // Conditional UI Rendering state:
  // When true (selectedDevice.device_type == 'ac_unit' / zone_id == 'zone_ac'),
  // completely hides Zone 1, 2, and 3 dropdowns/panels and displays ONLY the dedicated Standalone AC layout.
  bool isAddingAC = false;

  late String _selectedRoomId;
  String _selectedZone = 'Zone 1';
  final TextEditingController _deviceNameController = TextEditingController();
  final TextEditingController _ac1NameController = TextEditingController(text: 'Gree AC 1 (Front)');
  final TextEditingController _ac2NameController = TextEditingController(text: 'Gree AC 2 (Back)');
  final TextEditingController _macController = TextEditingController();

  // Selected Hardware Node (1..3 = Switchboards, 4 = Standalone Dual-AC)
  int _selectedBoardId = 1;
  String _selectedBoardName = 'Switchboard #1';
  String _selectedZoneId = 'zone_1';
  bool _isScanningMqtt = false;
  Timer? _scanInitTimer;
  Timer? _scanQueryTimer;
  Timer? _scanCompleteTimer;

  // Single Appliance mode fields (for Switchboard Zones 1-3)
  String _selectedCategory = 'Ceiling Fan';
  final String _selectedProtocol = 'MQTT';
  final bool _defaultOn = false;
  int _selectedGpio = 15;
  int _selectedSwitchGpio = 13;
  int _selectedRelayNumber = 1;

  // Standalone Dual-AC Module State (Gree AC #1 on GPIO 33, Gree AC #2 on GPIO 12)
  bool _ac1Enabled = true;
  bool _ac1PowerOn = false;
  int _ac1Temperature = 24;
  String _ac1Mode = 'COOL';

  bool _ac2Enabled = true;
  bool _ac2PowerOn = false;
  int _ac2Temperature = 24;
  String _ac2Mode = 'COOL';
  final int _acFanSpeed = 0; // 0 = Auto, 1 = Low, 2 = Med, 3 = High
  final bool _acSwing = false;

  final List<Map<String, dynamic>> _deviceCategories = [
    {
      'title': 'Ceiling Fan',
      'icon': Icons.toys,
      'type': DeviceType.fan,
      'defaultName': 'Ceiling Fan',
    },
    {
      'title': 'Light',
      'icon': Icons.lightbulb_outline,
      'type': DeviceType.lighting,
      'defaultName': 'Classroom Light',
    },
    {
      'title': 'Standalone AC',
      'icon': Icons.ac_unit,
      'type': DeviceType.hvac,
      'defaultName': 'Standalone AC',
    },
  ];

  // Relay <-> Manual Switch pairs for the currently selected Switchboard Zone (1, 2, or 3)
  late List<_BatchChannelConfig> _batchChannels;
  bool _hasUserInteractedWithBoard = false;

  @override
  void initState() {
    super.initState();
    _selectedRoomId = widget.preselectedRoomId ??
        (_state.classrooms.isNotEmpty ? _state.classrooms.first.id : '');
    _updateDefaultZone();
    if (widget.preselectedZone != null &&
        !widget.preselectedZone!.toLowerCase().contains('ac')) {
      _hasUserInteractedWithBoard = true;
      _selectedZone = widget.preselectedZone!;
      final zMatch = RegExp(r'(\d+)').firstMatch(_selectedZone);
      if (zMatch != null) {
        _selectedBoardId = (int.tryParse(zMatch.group(1) ?? '') ?? 1).clamp(1, 3);
        _selectedBoardName = 'Switchboard #$_selectedBoardId';
        _selectedZoneId = 'zone_$_selectedBoardId';
      }
    }
    _initBatchChannelsForBoard(_selectedBoardId);
    _syncSinglePairSelection(1);
    _updateDefaultDeviceName();
    ConnectivityState().addListener(_onConnectivityChanged);
    _scanInitTimer = Timer(const Duration(milliseconds: 280), () {
      if (mounted) _runMqttHardwareScan(fromUserTap: false);
    });
  }

  void _initBatchChannelsForBoard(int boardId) {
    final pairs = ClassroomDevice.switchRelayPairsForZone(boardId);
    _batchChannels = List.generate(pairs.length, (i) {
      final p = pairs[i];
      final rNum = p['relay'] as int;
      final isLight = rNum <= 4;
      return _BatchChannelConfig(
        relayNumber: rNum,
        gpio: p['gpio'] as int,
        switchGpio: p['switchGpio'] as int,
        relayLabel: p['relayLabel'] as String,
        switchName: p['switchName'] as String,
        enabled: true,
        category: isLight ? 'Light' : 'Ceiling Fan',
        type: isLight ? DeviceType.lighting : DeviceType.fan,
        initialName: isLight
            ? '$_selectedZone Light $rNum'
            : '$_selectedZone Fan ${rNum - 4}',
        defaultOn: false,
      );
    });
  }

  void _refreshBatchChannelPinsForBoard(int boardId) {
    final oldChannels = _batchChannels;
    _initBatchChannelsForBoard(boardId);
    for (final ch in oldChannels) {
      ch.nameController.dispose();
    }
    final pairCount = ClassroomDevice.switchRelayPairsForZone(boardId).length;
    final clampedRelay = _selectedRelayNumber.clamp(1, pairCount);
    _syncSinglePairSelection(clampedRelay);
  }

  void _syncSinglePairSelection(int relayNum) {
    final pair = ClassroomDevice.pairInfoForRelay(relayNum, boardId: _selectedBoardId);
    _selectedRelayNumber = relayNum;
    _selectedGpio = pair['gpio'] as int;
    _selectedSwitchGpio = pair['switchGpio'] as int;
  }

  void _onConnectivityChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _runMqttHardwareScan({bool fromUserTap = true}) {
    if (!mounted) return;
    _scanQueryTimer?.cancel();
    _scanCompleteTimer?.cancel();
    setState(() => _isScanningMqtt = true);
    ConnectivityState().purgeAllDiscoveredNodes(force: false);

    // Ensure live MQTT connection (reconnecting cleanly if stale) & query discovery
    MqttService().ensureConnectedAndSync(
      _selectedRoomId.isNotEmpty ? _selectedRoomId : 'reb_room_301',
    );
    _scanQueryTimer = Timer(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      MqttService().publishStatusQuery(_selectedRoomId);
    });

    _scanCompleteTimer = Timer(const Duration(milliseconds: 1600), () {
      if (!mounted) return;
      setState(() {
        _isScanningMqtt = false;
        // Only auto-select on initial open if the user hasn't picked a zone/board manually.
        if (!fromUserTap && !_hasUserInteractedWithBoard) {
          final online = ConnectivityState().discoveredIpNodes;
          if (online.isNotEmpty) {
            final currentFound = online
                    .where((n) => n.zoneId == _selectedZoneId || n.boardId == _selectedBoardId)
                    .firstOrNull ??
                online.first;
            _applyDiscoveredDeviceSelection(currentFound, triggerHaptic: false);
          }
        }
      });
    });
  }

  void _applyDiscoveredDeviceSelection(
    IpDeviceNode node, {
    bool triggerHaptic = true,
  }) {
    if (triggerHaptic) {
      HapticFeedback.selectionClick();
    }
    _selectedZoneId = node.zoneId;
    _macController.text = node.ip;

    if (node.isAcUnit || node.deviceType == 'ac_unit' || node.zoneId == 'zone_ac') {
      final changed = !isAddingAC || _selectedBoardId != 4;
      isAddingAC = true;
      _selectedBoardId = 4;
      _selectedBoardName = 'Standalone AC';
      _selectedCategory = 'Standalone AC';
      _selectedGpio = 33;
      _selectedSwitchGpio = 12;
      if (changed) {
        _updateDefaultDeviceName();
      }
    } else {
      final nextBoardId = node.boardId.clamp(1, 3);
      final changed = isAddingAC || _selectedBoardId != nextBoardId;
      isAddingAC = false;
      _selectedBoardId = nextBoardId;
      _selectedBoardName = 'Switchboard #$_selectedBoardId';
      _selectedZone = 'Zone $_selectedBoardId';
      if (_selectedCategory == 'Standalone AC') {
        _selectedCategory = 'Ceiling Fan';
      }
      if (changed) {
        _refreshBatchChannelPinsForBoard(_selectedBoardId);
        _updateDefaultDeviceName();
      }
    }
  }

  // Handles selection from the Unified MQTT Scan list
  void _selectDiscoveredDevice(IpDeviceNode node) {
    _hasUserInteractedWithBoard = true;
    setState(() {
      _applyDiscoveredDeviceSelection(node, triggerHaptic: true);
    });
  }

  void _selectManualHardwareBoard({required int boardId, required bool isAc}) {
    _hasUserInteractedWithBoard = true;
    HapticFeedback.selectionClick();
    setState(() {
      if (isAc) {
        isAddingAC = true;
        _selectedBoardId = 4;
        _selectedZoneId = 'zone_ac';
        _selectedBoardName = 'Standalone AC';
        _selectedCategory = 'Standalone AC';
        _selectedGpio = 33;
        _selectedSwitchGpio = 12;
        _macController.text = 'ESP32_Standalone_AC';
      } else {
        isAddingAC = false;
        _selectedBoardId = boardId;
        _selectedZoneId = 'zone_$boardId';
        _selectedBoardName = 'Switchboard #$boardId';
        _selectedZone = 'Zone $boardId';
        _macController.text = 'ESP32_Zone_$boardId';
        if (_selectedCategory == 'Standalone AC') {
          _selectedCategory = 'Ceiling Fan';
        }
        _refreshBatchChannelPinsForBoard(boardId);
        _updateDefaultDeviceName();
      }
    });
  }

  @override
  void dispose() {
    _scanInitTimer?.cancel();
    _scanQueryTimer?.cancel();
    _scanCompleteTimer?.cancel();
    ConnectivityState().removeListener(_onConnectivityChanged);
    _deviceNameController.dispose();
    _ac1NameController.dispose();
    _ac2NameController.dispose();
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
        final bId = (int.tryParse(match.group(1) ?? '') ?? 1).clamp(1, 3);
        _selectedBoardId = bId;
        _selectedZoneId = 'zone_$bId';
        _selectedBoardName = 'Switchboard #$bId';
      }
    }
  }

  void _onZoneSelected(String zone) {
    _hasUserInteractedWithBoard = true;
    HapticFeedback.selectionClick();
    setState(() {
      isAddingAC = false;
      _selectedZone = zone;
      final match = RegExp(r'(\d+)').firstMatch(zone);
      if (match != null) {
        final bId = (int.tryParse(match.group(1) ?? '') ?? 1).clamp(1, 3);
        _selectedBoardId = bId;
        _selectedZoneId = 'zone_$bId';
        _selectedBoardName = 'Switchboard #$bId';
        _macController.text = 'ESP32_Zone_$bId';
      }
      _refreshBatchChannelPinsForBoard(_selectedBoardId);
      _updateDefaultDeviceName();
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

    _deviceNameController.text = '$_selectedZone $prefix ${countInZone + 1}';
  }

  void _setBatchChannelCategory(int index, String category) {
    HapticFeedback.selectionClick();
    setState(() {
      final ch = _batchChannels[index];
      ch.category = category;
      if (category == 'Ceiling Fan') {
        ch.type = DeviceType.fan;
        ch.nameController.text = '$_selectedZone Fan ${ch.relayNumber}';
      } else {
        ch.type = DeviceType.lighting;
        ch.nameController.text = '$_selectedZone Light ${ch.relayNumber}';
      }
    });
  }

  // --- Register Standalone Dual-Gree AC Devices (zone_ac: AC #1 on GPIO 33, AC #2 on GPIO 12) ---
  void _registerStandaloneAcDevice() {
    if (_state.classrooms.isEmpty || _selectedRoomId.isEmpty) {
      CyberToast.show(
        context,
        message: 'Please select a classroom first.',
        type: ToastType.error,
      );
      return;
    }

    if (!_ac1Enabled && !_ac2Enabled) {
      CyberToast.show(
        context,
        message: 'Please enable at least one Gree AC IR circuit (GPIO 33 or GPIO 12).',
        type: ToastType.error,
      );
      return;
    }

    HapticFeedback.mediumImpact();
    final currentRoom = _state.classrooms.firstWhere((r) => r.id == _selectedRoomId);
    final List<ClassroomDevice> acDevices = [];
    final String hwAddr = _macController.text.trim().isNotEmpty
        ? _macController.text.trim()
        : 'ESP32_Standalone_DualAC';

    if (_ac1Enabled) {
      final ac1Name = _ac1NameController.text.trim().isNotEmpty
          ? _ac1NameController.text.trim()
          : 'Gree AC 1 (Front)';
      acDevices.add(
        ClassroomDevice(
          id: 'dev-${DateTime.now().millisecondsSinceEpoch % 100000}-ac-1',
          name: ac1Name,
          type: DeviceType.hvac,
          statusDescription: _ac1PowerOn
              ? '$_ac1Mode $_ac1Temperature°C · IR GPIO 33'
              : 'Standby · IR GPIO 33',
          isOn: _ac1PowerOn,
          zone: 'Standalone AC',
          relayChannel: 'GREE AC #1 IR (GPIO 33)',
          hardwareModel: 'Standalone Dual-Gree AC IR Controller (GPIO 33 / GPIO 12)',
          zigbeeOrBleNode: 'Standalone AC',
          macAddress: hwAddr,
          protocol: 'GREE IR (MQTT)',
          temperature: _ac1Temperature,
          hvacMode: _ac1Mode,
          fanSpeed: _acFanSpeed,
          acSwing: _acSwing,
        ),
      );
      MqttService().publishAcCommand(
        currentRoom.scopedRoomId,
        1,
        isOn: _ac1PowerOn,
        temp: _ac1Temperature,
        mode: _ac1Mode,
        fanSpeed: _acFanSpeed,
        swing: _acSwing,
        irGpio: 33,
      );
    }

    if (_ac2Enabled) {
      final ac2Name = _ac2NameController.text.trim().isNotEmpty
          ? _ac2NameController.text.trim()
          : 'Gree AC 2 (Back)';
      acDevices.add(
        ClassroomDevice(
          id: 'dev-${DateTime.now().millisecondsSinceEpoch % 100000}-ac-2',
          name: ac2Name,
          type: DeviceType.hvac,
          statusDescription: _ac2PowerOn
              ? '$_ac2Mode $_ac2Temperature°C · IR GPIO 12'
              : 'Standby · IR GPIO 12',
          isOn: _ac2PowerOn,
          zone: 'Standalone AC',
          relayChannel: 'GREE AC #2 IR (GPIO 12)',
          hardwareModel: 'Standalone Dual-Gree AC IR Controller (GPIO 33 / GPIO 12)',
          zigbeeOrBleNode: 'Standalone AC',
          macAddress: hwAddr,
          protocol: 'GREE IR (MQTT)',
          temperature: _ac2Temperature,
          hvacMode: _ac2Mode,
          fanSpeed: _acFanSpeed,
          acSwing: _acSwing,
        ),
      );
      MqttService().publishAcCommand(
        currentRoom.scopedRoomId,
        2,
        isOn: _ac2PowerOn,
        temp: _ac2Temperature,
        mode: _ac2Mode,
        fanSpeed: _acFanSpeed,
        swing: _acSwing,
        irGpio: 12,
      );
    }

    _state.addDevices(_selectedRoomId, acDevices);

    CyberToast.show(
      context,
      message: 'Paired ${acDevices.length} Gree AC unit(s) (GPIO 33 & GPIO 12) to ${currentRoom.roomNumber}.',
      type: ToastType.success,
    );

    Navigator.pop(context);
  }

  // --- Register 8-Switch Batch Devices Under Selected Zone ---
  void _registerBatchDevices() {
    if (isAddingAC) {
      _registerStandaloneAcDevice();
      return;
    }

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
        message: 'Please enable at least 1 switch-relay pair to add.',
        type: ToastType.error,
      );
      return;
    }

    HapticFeedback.mediumImpact();

    final String hardwareId = _macController.text.trim().isNotEmpty
        ? _macController.text.trim()
        : 'ESP32_Zone_$_selectedBoardId';

    final List<ClassroomDevice> newDevices = [];
    final currentRoom = _state.classrooms.firstWhere((r) => r.id == _selectedRoomId);

    for (final ch in enabledChannels) {
      final devName = ch.nameController.text.trim().isNotEmpty
          ? ch.nameController.text.trim()
          : '$_selectedZone ${ch.category} ${ch.relayNumber}';

      final statusDesc = ch.type == DeviceType.fan
          ? (ch.defaultOn ? 'Speed 3 · Active' : 'Standby · Array Off')
          : (ch.defaultOn ? '100% Brightness · Relay Closed' : 'Standby · Power Off');

      final device = ClassroomDevice(
        id: 'dev-${DateTime.now().millisecondsSinceEpoch % 100000}-z$_selectedBoardId-r${ch.relayNumber}',
        name: devName,
        type: ch.type,
        statusDescription: statusDesc,
        isOn: ch.defaultOn,
        zone: _selectedZone,
        relayChannel: ClassroomDevice.defaultRelayChannelForRelay(
          ch.relayNumber,
          boardId: _selectedBoardId,
        ),
        hardwareModel: ch.type == DeviceType.fan ? 'Ceiling Fan Controller' : 'Lighting Controller',
        zigbeeOrBleNode: _selectedBoardName,
        macAddress: hardwareId,
        protocol: _selectedProtocol,
        fanSpeed: ch.type == DeviceType.fan ? (ch.defaultOn ? 3 : 0) : 0,
        brightness: ch.type == DeviceType.lighting ? 100.0 : 0.0,
      );
      newDevices.add(device);
    }

    _state.addDevices(_selectedRoomId, newDevices);

    CyberToast.show(
      context,
      message: 'Added ${newDevices.length} switch-relay pairs to $_selectedZone in ${currentRoom.roomNumber}.',
      type: ToastType.success,
    );

    Navigator.pop(context);
  }

  // --- Register Single Appliance ---
  void _registerSingleDevice() {
    if (isAddingAC) {
      _registerStandaloneAcDevice();
      return;
    }

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

    final type = _selectedCategory == 'Ceiling Fan' ? DeviceType.fan : DeviceType.lighting;
    final statusDesc = type == DeviceType.fan
        ? (_defaultOn ? 'Speed 3 · Active' : 'Standby · Array Off')
        : (_defaultOn ? '100% Brightness · Relay Closed' : 'Standby · Power Off');

    final relayChannel = ClassroomDevice.defaultRelayChannelForRelay(
      _selectedRelayNumber,
      boardId: _selectedBoardId,
    );

    final String hardwareId = _macController.text.trim().isNotEmpty
        ? _macController.text.trim()
        : 'ESP32_Zone_$_selectedBoardId';

    final newDevice = ClassroomDevice(
      id: 'dev-${DateTime.now().millisecondsSinceEpoch % 10000}-z$_selectedBoardId-r$_selectedRelayNumber',
      name: devName,
      type: type,
      statusDescription: statusDesc,
      isOn: _defaultOn,
      zone: _selectedZone,
      relayChannel: relayChannel,
      hardwareModel: type == DeviceType.fan ? 'Ceiling Fan Controller' : 'Lighting Controller',
      zigbeeOrBleNode: _selectedBoardName,
      macAddress: hardwareId,
      protocol: _selectedProtocol,
      fanSpeed: type == DeviceType.fan ? (_defaultOn ? 3 : 0) : 0,
      brightness: type == DeviceType.lighting ? 100.0 : 0.0,
    );

    _state.addDevice(_selectedRoomId, newDevice);

    final targetRoom = _state.classrooms.firstWhere((r) => r.id == _selectedRoomId);

    CyberToast.show(
      context,
      message: '$devName assigned to $_selectedZone (Pair $_selectedRelayNumber) in ${targetRoom.roomNumber}.',
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
    final currentPairs = ClassroomDevice.switchRelayPairsForZone(_selectedBoardId);

    return Scaffold(
      backgroundColor: AppColors.surfaceContainerLowest,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceContainerLowest,
        titleSpacing: 0,
        leading: IconButton(
          tooltip: 'Back',
          icon: Icon(Icons.arrow_back_rounded, color: AppColors.onSurface),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          isAddingAC ? 'Add Dual AC' : 'Add Device',
          style: AppTypography.headlineSm(color: AppColors.onSurface)
              .copyWith(fontSize: 18, fontWeight: FontWeight.w600),
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: (isAddingAC ? AppColors.secondary : AppColors.primary)
                  .withValues(alpha: 0.12),
              border: Border.all(
                color: (isAddingAC ? AppColors.secondary : AppColors.primary)
                    .withValues(alpha: 0.28),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                PulsingBeacon(
                  size: 6,
                  color: isAddingAC ? AppColors.secondary : AppColors.primary,
                ),
                const SizedBox(width: 6),
                Text(
                  isAddingAC ? 'DUAL AC · 33/12' : 'SWITCHBOARD',
                  style: AppTypography.labelSm(
                    color: isAddingAC ? AppColors.secondary : AppColors.primary,
                  ).copyWith(fontSize: 10.5, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Mode Switcher (Only shown when configuring 8-Switch Zones, hidden when isAddingAC is true)
            if (!isAddingAC)
              Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: AppColors.surfaceContainerLow,
                  border: Border.all(color: AppColors.overlay(0.08)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () {
                          HapticFeedback.selectionClick();
                          setState(() => _mode = AddProvisioningMode.batchZone);
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 8),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            color: _mode == AddProvisioningMode.batchZone ? AppColors.primary : Colors.transparent,
                            boxShadow: _mode == AddProvisioningMode.batchZone
                                ? [BoxShadow(color: AppColors.primary.withValues(alpha: 0.25), blurRadius: 8)]
                                : null,
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.dynamic_feed_rounded,
                                size: 16,
                                color: _mode == AddProvisioningMode.batchZone
                                    ? AppColors.onPrimary
                                    : AppColors.outline,
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  'Batch (8 Relays)',
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 1,
                                  style: AppTypography.labelSm(
                                    color: _mode == AddProvisioningMode.batchZone
                                        ? AppColors.onPrimary
                                        : AppColors.onSurfaceVariant,
                                  ).copyWith(fontWeight: FontWeight.w600, fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () {
                          HapticFeedback.selectionClick();
                          setState(() => _mode = AddProvisioningMode.singleAppliance);
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 8),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            color: _mode == AddProvisioningMode.singleAppliance ? AppColors.primary : Colors.transparent,
                            boxShadow: _mode == AddProvisioningMode.singleAppliance
                                ? [BoxShadow(color: AppColors.primary.withValues(alpha: 0.25), blurRadius: 8)]
                                : null,
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.electrical_services_rounded,
                                size: 16,
                                color: _mode == AddProvisioningMode.singleAppliance
                                    ? AppColors.onPrimary
                                    : AppColors.outline,
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  'Single Device',
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 1,
                                  style: AppTypography.labelSm(
                                    color: _mode == AddProvisioningMode.singleAppliance
                                        ? AppColors.onPrimary
                                        : AppColors.onSurfaceVariant,
                                  ).copyWith(fontWeight: FontWeight.w600, fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            // Main Provisioning Card
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: AppColors.surfaceContainerLow.withValues(alpha: 0.85),
                border: Border.all(
                  color: (isAddingAC ? AppColors.secondary : AppColors.primary).withValues(alpha: 0.28),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        isAddingAC
                            ? Icons.ac_unit
                            : (_mode == AddProvisioningMode.batchZone ? Icons.layers : Icons.electrical_services),
                        size: 18,
                        color: isAddingAC ? AppColors.secondary : AppColors.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          isAddingAC
                              ? 'Standalone Dual AC'
                              : (_mode == AddProvisioningMode.batchZone
                                  ? 'Zone Setup ($_selectedZone)'
                                  : 'Single Pair Setup'),
                          style: AppTypography.headlineSm(color: AppColors.onSurface).copyWith(fontSize: 15),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: (isAddingAC ? AppColors.secondary : AppColors.primary).withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: (isAddingAC ? AppColors.secondary : AppColors.primary).withValues(alpha: 0.3),
                          ),
                        ),
                        child: Text(
                          isAddingAC
                              ? 'AC UNIT'
                              : (_mode == AddProvisioningMode.batchZone ? '8 PAIRS' : 'SINGLE'),
                          style: AppTypography.labelSm(
                            color: isAddingAC ? AppColors.secondary : AppColors.primary,
                          ).copyWith(fontWeight: FontWeight.bold, fontSize: 10),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Divider(color: AppColors.overlay(0.08)),
                  const SizedBox(height: 14),

                  // Classroom Assignment Dropdown
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(child: Text(
                        'ASSIGN TO CLASSROOM',
                        style: AppTypography.labelSm(color: AppColors.onSurfaceVariant), overflow: TextOverflow.ellipsis,
                      )),
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
                        subtitle: '${room.building} · ${room.zoneCount} Switchboard Zones + AC',
                        icon: Icons.meeting_room,
                      );
                    }).toList(),
                    onChanged: (val) {
                      setState(() {
                        _selectedRoomId = val;
                        _updateDefaultZone();
                        _refreshBatchChannelPinsForBoard(_selectedBoardId);
                      });
                    },
                  ),

                  const SizedBox(height: 16),

                  // =========================================================
                  // 1. UNIFIED MQTT DEVICE SCANNING (`home/discovery`)
                  // =========================================================
                  Row(
                    children: [
                      Icon(Icons.radar, size: 16, color: AppColors.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'UNIFIED MQTT DISCOVERY (home/discovery)',
                          style: AppTypography.labelSm(color: AppColors.onSurfaceVariant)
                              .copyWith(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Scans all ESP32 Switchboards (zone_1, zone_2, zone_3) and Standalone AC (zone_ac) simultaneously:',
                    style: AppTypography.bodySm(color: AppColors.outline).copyWith(fontSize: 11),
                  ),
                  const SizedBox(height: 10),

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
                        children: [
                          if (_isScanningMqtt) ...[
                            SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                'Scanning home/discovery...',
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                                style: AppTypography.labelMd(color: AppColors.primary).copyWith(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12.0,
                                ),
                              ),
                            ),
                          ] else ...[
                            Icon(Icons.radar, size: 16, color: AppColors.primary),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                'Scan MQTT Devices (Zones & AC)',
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                                style: AppTypography.labelMd(color: AppColors.primary).copyWith(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12.0,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),

                  // Dynamic Rendering of Discovered MQTT Devices (Switchboards vs Standalone AC)
                  if (onlineNodes.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        'DISCOVERED ON MQTT (TAP TO CONFIGURE):',
                        style: AppTypography.labelSm(color: AppColors.onlineMint)
                            .copyWith(fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                      ),
                    ),
                    ...onlineNodes.map((node) {
                      final bool nodeIsAc = node.isAcUnit;
                      final bool isSelected = (nodeIsAc && isAddingAC) ||
                          (!nodeIsAc && !isAddingAC && _selectedBoardId == node.boardId);
                      final Color accentColor = nodeIsAc ? AppColors.secondary : AppColors.primary;

                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () => _selectDiscoveredDevice(node),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 140),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              color: isSelected
                                  ? AppColors.surfaceContainerHigh
                                  : AppColors.surfaceContainerLowest,
                              border: Border.all(
                                color: isSelected ? accentColor : AppColors.overlay(0.08),
                                width: isSelected ? 1.8 : 1.0,
                              ),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: accentColor.withValues(alpha: 0.15),
                                  ),
                                  child: Icon(
                                    nodeIsAc ? Icons.ac_unit : Icons.developer_board,
                                    size: 18,
                                    color: accentColor,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Flexible(
                                            child: Text(
                                              nodeIsAc
                                                  ? 'Standalone AC'
                                                  : 'Zone ${node.boardId} Switchboard',
                                              style: AppTypography.labelMd(color: AppColors.onSurface)
                                                  .copyWith(fontWeight: FontWeight.bold),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              borderRadius: BorderRadius.circular(4),
                                              color: accentColor.withValues(alpha: 0.15),
                                            ),
                                            child: Text(
                                              '${node.zoneId} • ${node.deviceType}',
                                              style: AppTypography.labelSm(color: accentColor)
                                                  .copyWith(fontSize: 9.5, fontWeight: FontWeight.bold),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        nodeIsAc
                                            ? 'IP: ${node.ip} • 2 Gree ACs: AC #1 (GPIO 33) & AC #2 (GPIO 12)'
                                            : 'IP: ${node.ip} • 8 Relays ↔ 8 Manual Switches (INPUT_PULLUP)',
                                        style: AppTypography.bodySm(color: AppColors.outline)
                                            .copyWith(fontSize: 10),
                                      ),
                                    ],
                                  ),
                                ),
                                Icon(
                                  isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
                                  color: isSelected ? accentColor : AppColors.outline,
                                  size: 20,
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }),
                  ],

                  // Always show Hardware Selector Cards (Zone 1, Zone 2, Zone 3, and Standalone AC)
                  Padding(
                    padding: const EdgeInsets.only(top: 4, bottom: 8),
                    child: Text(
                      onlineNodes.isEmpty
                          ? 'SELECT ESP32 TARGET DEVICE (ZONES 1–3 OR STANDALONE AC):'
                          : 'OR SWITCH TARGET HARDWARE TYPE:',
                      style: AppTypography.labelSm(color: AppColors.outline)
                          .copyWith(fontSize: 9.5, letterSpacing: 0.4),
                    ),
                  ),
                  // 2x2 Hardware Target Grid (Zone 1, Zone 2, Zone 3, Standalone AC)
                  Row(
                    children: [
                      Expanded(
                        child: _buildHardwareTargetTile(
                          title: 'Zone 1',
                          subtitle: 'zone_1 · 8 Pairs',
                          icon: Icons.developer_board,
                          isSelected: !isAddingAC && _selectedBoardId == 1,
                          accentColor: AppColors.primary,
                          onTap: () => _selectManualHardwareBoard(boardId: 1, isAc: false),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildHardwareTargetTile(
                          title: 'Zone 2',
                          subtitle: 'zone_2 · 8 Pairs',
                          icon: Icons.developer_board,
                          isSelected: !isAddingAC && _selectedBoardId == 2,
                          accentColor: AppColors.primary,
                          onTap: () => _selectManualHardwareBoard(boardId: 2, isAc: false),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _buildHardwareTargetTile(
                          title: 'Zone 3',
                          subtitle: 'zone_3 · 8 Pairs',
                          icon: Icons.developer_board,
                          isSelected: !isAddingAC && _selectedBoardId == 3,
                          accentColor: AppColors.primary,
                          onTap: () => _selectManualHardwareBoard(boardId: 3, isAc: false),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildHardwareTargetTile(
                          title: 'Standalone AC',
                          subtitle: 'zone_ac · GPIO 33 & 12',
                          icon: Icons.ac_unit,
                          isSelected: isAddingAC,
                          accentColor: AppColors.secondary,
                          onTap: () => _selectManualHardwareBoard(boardId: 4, isAc: true),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 16),

                  // =========================================================
                  // CONDITIONAL UI RENDERING:
                  // Rule: If isAddingAC is true, COMPLETELY HIDE the Zone 1, 2,
                  // and 3 dropdowns/panels and 8-switch layout, and display
                  // ONLY the dedicated Standalone AC control layout!
                  // =========================================================
                  if (isAddingAC) ...[
                    _buildStandaloneAcConfigurationSection(),
                  ] else ...[
                    // =======================================================
                    // STANDARD 8-SWITCH ZONE UI (ZONES 1, 2, AND 3)
                    // =======================================================
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              Icon(Icons.grid_view_rounded, size: 15, color: AppColors.primary),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  'TARGET SWITCHBOARD ZONE',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTypography.labelSm(color: AppColors.onSurfaceVariant)
                                      .copyWith(fontWeight: FontWeight.bold, letterSpacing: 0.5),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      (currentPairs.first['switchGpio'] as int) < 0
                          ? '$_selectedZone (${_selectedBoardId == 1 ? "1st Board" : (_selectedBoardId == 2 ? "Unlabeled Board" : "3rd Board")}): Relays ${currentPairs.map((p) => "G${p['gpio']}").join(", ")} · App/MQTT only'
                          : '$_selectedZone (${_selectedBoardId == 1 ? "1st Board" : (_selectedBoardId == 2 ? "Unlabeled Board" : "3rd Board")}): Relays ${currentPairs.map((p) => "D${p['gpio']}").join(", ")} ↔ Switches ${currentPairs.first['switchName']}–${currentPairs.last['switchName']}',
                      style: AppTypography.bodySm(color: AppColors.outline).copyWith(fontSize: 10.5),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: availableZones
                          .where((z) => !z.toLowerCase().contains('ac'))
                          .map((zone) {
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
                                color: isSelected ? AppColors.primary : AppColors.overlay(0.1),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.developer_board,
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
                      }).toList(),
                    ),

                    const SizedBox(height: 16),

                    if (_mode == AddProvisioningMode.batchZone) ...[
                      Container(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppColors.primary.withValues(alpha: 0.22)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.link_rounded, size: 16, color: AppColors.primary),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Quickly set up ${_batchChannels.length} switches for $_selectedZone',
                                    style: AppTypography.labelMd(color: AppColors.onSurface)
                                        .copyWith(fontSize: 12.5, fontWeight: FontWeight.w600),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                _buildQuickBatchPresetBtn('All Lights', () {
                                  setState(() {
                                    for (var i = 0; i < _batchChannels.length; i++) {
                                      _batchChannels[i].enabled = true;
                                      _setBatchChannelCategory(i, 'Light');
                                    }
                                  });
                                }),
                                _buildQuickBatchPresetBtn('All Fans', () {
                                  setState(() {
                                    for (var i = 0; i < _batchChannels.length; i++) {
                                      _batchChannels[i].enabled = true;
                                      _setBatchChannelCategory(i, 'Ceiling Fan');
                                    }
                                  });
                                }),
                                _buildQuickBatchPresetBtn('Select All', () {
                                  setState(() {
                                    for (final c in _batchChannels) {
                                      c.enabled = true;
                                    }
                                  });
                                }),
                                _buildQuickBatchPresetBtn('Clear', () {
                                  setState(() {
                                    for (final c in _batchChannels) {
                                      c.enabled = false;
                                    }
                                  });
                                }),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),

                      // 8 Relay <-> Switch Pair Cards
                      ..._batchChannels.asMap().entries.map((entry) {
                        final idx = entry.key;
                        final ch = entry.value;
                        final alreadyAdded = currentRoom?.devices.any((d) =>
                                d.zone == _selectedZone &&
                                d.relayNumber == ch.relayNumber) ??
                            false;

                        return Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            color: ch.enabled
                                ? AppColors.surfaceContainerLowest
                                : AppColors.surfaceContainerLowest.withValues(alpha: 0.4),
                            border: Border.all(
                              color: ch.enabled
                                  ? AppColors.primary.withValues(alpha: 0.35)
                                  : AppColors.overlay(0.06),
                              width: ch.enabled ? 1.2 : 1.0,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
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
                                  Expanded(
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(6),
                                        color: ch.enabled
                                            ? AppColors.primary.withValues(alpha: 0.14)
                                            : AppColors.overlay(0.05),
                                      ),
                                      child: Text(
                                        ch.switchGpio < 0
                                            ? '${ch.relayLabel} · Relay ${ch.relayNumber} (G${ch.gpio})'
                                            : 'Switch ${ch.switchName} · Relay ${ch.relayNumber} (D${ch.gpio})',
                                        style: AppTypography.labelSm(
                                          color: ch.enabled ? AppColors.primary : AppColors.outline,
                                        ).copyWith(fontWeight: FontWeight.bold, fontSize: 11),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                                  if (alreadyAdded) ...[
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(6),
                                        color: AppColors.onlineMint.withValues(alpha: 0.14),
                                      ),
                                      child: Text(
                                        'Added',
                                        style: AppTypography.labelSm(color: AppColors.onlineMint)
                                            .copyWith(fontSize: 9.5, fontWeight: FontWeight.w700),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              if (ch.enabled) ...[
                                const SizedBox(height: 10),
                                Row(
                                  children: [
                                    Expanded(
                                      child: _buildBatchTypeChip(
                                        title: 'Light',
                                        icon: Icons.lightbulb_outline,
                                        isSelected: ch.category == 'Light',
                                        onTap: () => _setBatchChannelCategory(idx, 'Light'),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: _buildBatchTypeChip(
                                        title: 'Ceiling Fan',
                                        isFan: true,
                                        isSelected: ch.category == 'Ceiling Fan',
                                        onTap: () => _setBatchChannelCategory(idx, 'Ceiling Fan'),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Container(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(8),
                                    color: AppColors.surfaceContainer,
                                    border: Border.all(color: AppColors.overlay(0.08)),
                                  ),
                                  child: TextField(
                                    controller: ch.nameController,
                                    style: AppTypography.bodyMd(color: AppColors.onSurface).copyWith(fontSize: 13),
                                    decoration: InputDecoration(
                                      isDense: true,
                                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                                      border: InputBorder.none,
                                      hintText: 'e.g. $_selectedZone ${ch.category} ${ch.relayNumber}',
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        );
                      }),
                    ] else ...[
                      // Single Switch Pair Mode (within Zones 1, 2, or 3)
                      Text(
                        'APPLIANCE CATEGORY',
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
                                  if (title == 'Standalone AC') {
                                    // Selecting Standalone AC switches to isAddingAC = true and hides Zones 1-3!
                                    _selectManualHardwareBoard(boardId: 4, isAc: true);
                                    return;
                                  }
                                  setState(() {
                                    isAddingAC = false;
                                    _selectedCategory = title;
                                    _updateDefaultDeviceName();
                                  });
                                },
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 140),
                                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(10),
                                    color: isSelected ? AppColors.surfaceContainerHigh : AppColors.surfaceContainer,
                                    border: Border.all(
                                      color: isSelected ? AppColors.primary : AppColors.overlay(0.08),
                                      width: isSelected ? 1.5 : 1.0,
                                    ),
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
                                        ).copyWith(
                                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),

                      const SizedBox(height: 14),

                      // Select 1 of 8 Relay <-> Switch Pairs for this Zone
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          color: AppColors.surfaceContainerLowest,
                          border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'SELECT RELAY ↔ SWITCH PAIR ($_selectedZone · ${currentPairs.length} Pairs):',
                              style: AppTypography.labelSm(color: AppColors.primary)
                                  .copyWith(fontWeight: FontWeight.bold, fontSize: 10.5),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _selectedSwitchGpio < 0
                                  ? 'Selected: Channel $_selectedRelayNumber — GPIO $_selectedGpio (OUTPUT) · App/MQTT only'
                                  : 'Selected: Pair $_selectedRelayNumber — GPIO $_selectedGpio (OUTPUT) ↔ Switch D$_selectedSwitchGpio (${_selectedSwitchGpio >= 34 ? "INPUT" : "INPUT_PULLUP"})',
                              style: AppTypography.bodySm(color: AppColors.onSurfaceVariant).copyWith(fontSize: 11),
                            ),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: currentPairs.map((p) {
                                final rNum = p['relay'] as int;
                                final rLabel = p['relayLabel'] as String;
                                final rPin = p['gpio'] as int;
                                final swName = p['switchName'] as String;
                                final swPin = p['switchGpio'] as int;
                                final isSelected = _selectedRelayNumber == rNum;
                                return ChoiceChip(
                                  label: Text(
                                    swPin < 0
                                        ? 'P$rNum: $rLabel (G$rPin)'
                                        : 'P$rNum: $rLabel (D$rPin) ↔ $swName (D$swPin)',
                                  ),
                                  selected: isSelected,
                                  selectedColor: AppColors.primary.withValues(alpha: 0.25),
                                  backgroundColor: AppColors.surfaceContainer,
                                  labelStyle: TextStyle(
                                    color: isSelected ? AppColors.primary : AppColors.onSurfaceVariant,
                                    fontSize: 10.5,
                                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                  ),
                                  side: BorderSide(
                                    color: isSelected ? AppColors.primary : AppColors.overlay(0.12),
                                  ),
                                  onSelected: (_) {
                                    HapticFeedback.selectionClick();
                                    setState(() {
                                      _syncSinglePairSelection(rNum);
                                    });
                                  },
                                );
                              }).toList(),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 14),

                      Text(
                        'DEVICE NAME',
                        style: AppTypography.labelSm(color: AppColors.onSurfaceVariant),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          color: AppColors.surfaceContainer,
                          border: Border.all(color: AppColors.overlay(0.1)),
                        ),
                        child: TextField(
                          controller: _deviceNameController,
                          style: AppTypography.bodyMd(color: AppColors.onSurface),
                          decoration: const InputDecoration(
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            border: InputBorder.none,
                            hintText: 'e.g. Zone 1 Ceiling Fan 1',
                          ),
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),

            const SizedBox(height: 20),

            // Primary Action CTA Button
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: isAddingAC ? AppColors.secondary : AppColors.primary,
                  foregroundColor: AppColors.onPrimary,
                  elevation: 3,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: isAddingAC
                    ? _registerStandaloneAcDevice
                    : (_mode == AddProvisioningMode.batchZone
                        ? _registerBatchDevices
                        : _registerSingleDevice),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      isAddingAC ? Icons.ac_unit_rounded : Icons.check_circle_rounded,
                      size: 20,
                      color: AppColors.onPrimary,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        isAddingAC
                            ? 'Save ${(_ac1Enabled ? 1 : 0) + (_ac2Enabled ? 1 : 0)} Gree AC(s)'
                            : (_mode == AddProvisioningMode.batchZone
                                ? 'Save ${_batchChannels.where((c) => c.enabled).length} Devices to $_selectedZone'
                                : 'Save Device to $_selectedZone'),
                        textAlign: TextAlign.center,
                        style: AppTypography.headlineSm(
                          color: AppColors.onPrimary,
                        ).copyWith(fontWeight: FontWeight.w700, fontSize: 14.5),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 12),

            Center(
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  'Cancel Registration',
                  style: AppTypography.bodySm(color: AppColors.onSurface).copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Dedicated Standalone Dual-Gree AC Control & Configuration Layout
  // Rendered ONLY when `isAddingAC == true` (while Zones 1, 2, and 3 are completely hidden).
  Widget _buildStandaloneAcConfigurationSection() {
    final currentRoom = _state.classrooms.isNotEmpty
        ? _state.classrooms.firstWhere(
            (r) => r.id == _selectedRoomId,
            orElse: () => _state.classrooms.first,
          )
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: AppColors.secondary.withValues(alpha: 0.10),
            border: Border.all(color: AppColors.secondary.withValues(alpha: 0.35)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      color: AppColors.secondary.withValues(alpha: 0.2),
                    ),
                    child: Icon(Icons.ac_unit, size: 20, color: AppColors.secondary),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'STANDALONE DUAL-GREE AC IR MODULE (ESP32)',
                          style: AppTypography.labelSm(color: AppColors.secondary)
                              .copyWith(fontSize: 9.5, fontWeight: FontWeight.bold, letterSpacing: 0.6),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'zone_id: "zone_ac" • 2 IR Transmitter/Receiver Circuits',
                          style: AppTypography.bodyMd(color: AppColors.onSurface)
                              .copyWith(fontWeight: FontWeight.bold, fontSize: 12.0),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Divider(color: AppColors.overlay(0.08), height: 1),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _buildAcPinBadge(
                      label: 'GREE AC #1 IR CIRCUIT',
                      pinText: 'GPIO 33',
                      icon: Icons.settings_remote,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildAcPinBadge(
                      label: 'GREE AC #2 IR',
                      pinText: 'GPIO 12',
                      icon: Icons.settings_remote,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Zones 1, 2, and 3 switchboards are hidden. This standalone ESP32 drives two IR transmitter/receiver circuits on GPIO 33 and GPIO 12 for the two classroom Gree ACs.',
                style: AppTypography.bodySm(color: AppColors.outline).copyWith(fontSize: 10.5),
              ),
            ],
          ),
        ),

        const SizedBox(height: 14),

        // Gree AC #1 Card (GPIO 33)
        _buildSingleAcUnitCard(
          unitNumber: 1,
          gpioPin: 33,
          enabled: _ac1Enabled,
          onEnabledChanged: (val) => setState(() => _ac1Enabled = val),
          nameController: _ac1NameController,
          powerOn: _ac1PowerOn,
          onPowerChanged: (val) {
            HapticFeedback.lightImpact();
            setState(() => _ac1PowerOn = val);
            if (currentRoom != null) {
              MqttService().publishAcCommand(
                currentRoom.scopedRoomId,
                1,
                isOn: _ac1PowerOn,
                temp: _ac1Temperature,
                mode: _ac1Mode,
                fanSpeed: _acFanSpeed,
                swing: _acSwing,
                irGpio: 33,
              );
            }
          },
          temperature: _ac1Temperature,
          onTempDelta: (d) => setState(() => _ac1Temperature = (_ac1Temperature + d).clamp(16, 30)),
          mode: _ac1Mode,
          onModeChanged: (m) => setState(() => _ac1Mode = m),
        ),

        const SizedBox(height: 12),

        // Gree AC #2 Card (GPIO 12)
        _buildSingleAcUnitCard(
          unitNumber: 2,
          gpioPin: 12,
          enabled: _ac2Enabled,
          onEnabledChanged: (val) => setState(() => _ac2Enabled = val),
          nameController: _ac2NameController,
          powerOn: _ac2PowerOn,
          onPowerChanged: (val) {
            HapticFeedback.lightImpact();
            setState(() => _ac2PowerOn = val);
            if (currentRoom != null) {
              MqttService().publishAcCommand(
                currentRoom.scopedRoomId,
                2,
                isOn: _ac2PowerOn,
                temp: _ac2Temperature,
                mode: _ac2Mode,
                fanSpeed: _acFanSpeed,
                swing: _acSwing,
                irGpio: 12,
              );
            }
          },
          temperature: _ac2Temperature,
          onTempDelta: (d) => setState(() => _ac2Temperature = (_ac2Temperature + d).clamp(16, 30)),
          mode: _ac2Mode,
          onModeChanged: (m) => setState(() => _ac2Mode = m),
        ),
      ],
    );
  }

  Widget _buildSingleAcUnitCard({
    required int unitNumber,
    required int gpioPin,
    required bool enabled,
    required ValueChanged<bool> onEnabledChanged,
    required TextEditingController nameController,
    required bool powerOn,
    required ValueChanged<bool> onPowerChanged,
    required int temperature,
    required ValueChanged<int> onTempDelta,
    required String mode,
    required ValueChanged<String> onModeChanged,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: enabled
            ? AppColors.surfaceContainerLowest
            : AppColors.surfaceContainerLowest.withValues(alpha: 0.45),
        border: Border.all(
          color: enabled
              ? AppColors.secondary.withValues(alpha: 0.45)
              : AppColors.overlay(0.08),
          width: enabled ? 1.3 : 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: Checkbox(
                  value: enabled,
                  activeColor: AppColors.secondary,
                  onChanged: (val) => onEnabledChanged(val ?? false),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    color: AppColors.secondary.withValues(alpha: 0.15),
                  ),
                  child: Text(
                    'GREE AC #$unitNumber • GPIO $gpioPin',
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: AppTypography.labelSm(color: AppColors.secondary)
                        .copyWith(fontWeight: FontWeight.bold, fontSize: 10.5),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              CyberSwitch(
                width: 38,
                height: 22,
                value: powerOn,
                onChanged: onPowerChanged,
              ),
            ],
          ),
          if (enabled) ...[
            const SizedBox(height: 10),
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: AppColors.surfaceContainer,
                border: Border.all(color: AppColors.overlay(0.08)),
              ),
              child: TextField(
                controller: nameController,
                style: AppTypography.bodyMd(color: AppColors.onSurface).copyWith(fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                  border: InputBorder.none,
                  hintText: 'Gree AC $unitNumber',
                ),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      onPressed: () => onTempDelta(-1),
                      icon: Icon(Icons.remove_circle_outline, color: AppColors.secondary, size: 18),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(
                        '$temperature°C',
                        style: AppTypography.labelLg(color: AppColors.secondary)
                            .copyWith(fontWeight: FontWeight.bold, fontSize: 15),
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      onPressed: () => onTempDelta(1),
                      icon: Icon(Icons.add_circle_outline, color: AppColors.secondary, size: 18),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: ['COOL', 'AUTO', 'DRY', 'FAN'].map((m) {
                    final selected = mode == m;
                    return GestureDetector(
                      onTap: () => onModeChanged(m),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          color: selected
                              ? AppColors.secondary.withValues(alpha: 0.25)
                              : AppColors.surfaceContainer,
                          border: Border.all(
                            color: selected ? AppColors.secondary : AppColors.overlay(0.12),
                          ),
                        ),
                        child: Text(
                          m,
                          style: TextStyle(
                            color: selected ? AppColors.secondary : AppColors.onSurfaceVariant,
                            fontSize: 9.5,
                            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAcPinBadge({
    required String label,
    required String pinText,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: AppColors.surfaceContainerLowest,
        border: Border.all(color: AppColors.secondary.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 15, color: AppColors.secondary),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: AppTypography.labelSm(color: AppColors.outline).copyWith(fontSize: 8),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  pinText,
                  style: AppTypography.labelMd(color: AppColors.secondary)
                      .copyWith(fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHardwareTargetTile({
    required String title,
    required String subtitle,
    required IconData icon,
    required bool isSelected,
    required Color accentColor,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: isSelected ? accentColor.withValues(alpha: 0.18) : AppColors.surfaceContainerLowest,
          border: Border.all(
            color: isSelected ? accentColor : AppColors.overlay(0.08),
            width: isSelected ? 1.6 : 1.0,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 17, color: isSelected ? accentColor : AppColors.outline),
            const SizedBox(height: 4),
            Text(
              title,
              style: AppTypography.labelSm(
                color: isSelected ? accentColor : AppColors.onSurface,
              ).copyWith(fontWeight: FontWeight.bold, fontSize: 10.5),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              subtitle,
              style: AppTypography.bodySm(
                color: isSelected ? accentColor.withValues(alpha: 0.85) : AppColors.outline,
              ).copyWith(fontSize: 9.5),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickBatchPresetBtn(String label, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: AppColors.surfaceContainerLow,
          border: Border.all(color: AppColors.primary.withValues(alpha: 0.35)),
        ),
        child: Text(
          label,
          style: AppTypography.labelSm(color: AppColors.primary)
              .copyWith(fontSize: 11, fontWeight: FontWeight.w600),
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
        padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: isSelected ? AppColors.primary.withValues(alpha: 0.22) : AppColors.surfaceContainer,
          border: Border.all(
            color: isSelected ? AppColors.primary : AppColors.overlay(0.08),
            width: isSelected ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (isFan)
              CeilingFanIcon(
                size: 15,
                color: isSelected ? AppColors.primary : AppColors.outline,
              )
            else
              Icon(
                icon,
                size: 15,
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
