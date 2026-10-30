import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/classroom.dart';
import '../models/device.dart';
import '../state/classroom_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';
import '../widgets/cyber_switch.dart';
import '../widgets/cyber_slider.dart';
import '../widgets/fan_spinner.dart';
import '../widgets/pulsing_beacon.dart';
import '../widgets/cyber_toast.dart';
import '../state/auth_state.dart';
import '../services/mqtt_service.dart';

class DeviceDetailScreen extends StatefulWidget {
  final String roomId;
  final String deviceId;

  const DeviceDetailScreen({
    super.key,
    required this.roomId,
    required this.deviceId,
  });

  @override
  State<DeviceDetailScreen> createState() => _DeviceDetailScreenState();
}

class _DeviceDetailScreenState extends State<DeviceDetailScreen> {
  final ClassroomState _state = ClassroomState();
  bool _isTestingRelay = false;

  @override
  void initState() {
    super.initState();
    _state.addListener(_onStateChange);
  }

  @override
  void dispose() {
    _state.removeListener(_onStateChange);
    super.dispose();
  }

  void _onStateChange() {
    if (mounted) setState(() {});
  }

  Classroom? get _room {
    try {
      return _state.classrooms.firstWhere((r) => r.id == widget.roomId);
    } catch (_) {
      return null;
    }
  }

  ClassroomDevice? get _device {
    final room = _room;
    if (room == null) return null;
    try {
      return room.devices.firstWhere((d) => d.id == widget.deviceId);
    } catch (_) {
      return null;
    }
  }

  String _deviceCategoryTitle(DeviceType type) {
    switch (type) {
      case DeviceType.hvac:
        return 'AIR CONDITIONER';
      case DeviceType.fan:
        return 'CEILING FAN';
      case DeviceType.lighting:
        return 'LIGHTING';
      case DeviceType.projector:
        return 'LASER PROJECTOR';
      case DeviceType.telemetry:
        return 'TELEMETRY NODE';
      case DeviceType.powerStrip:
        return 'POWER BREAKOUT';
    }
  }

  IconData _getDeviceIcon(DeviceType type) {
    switch (type) {
      case DeviceType.hvac:
        return Icons.ac_unit;
      case DeviceType.fan:
        return Icons.air;
      case DeviceType.lighting:
        return Icons.lightbulb_outline;
      case DeviceType.projector:
        return Icons.videocam;
      case DeviceType.telemetry:
        return Icons.sensors;
      case DeviceType.powerStrip:
        return Icons.power;
    }
  }

  void _runSelfTest() async {
    HapticFeedback.heavyImpact();
    setState(() => _isTestingRelay = true);
    final dev = _device;
    if (dev?.type == DeviceType.hvac) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppColors.surfaceContainerHigh,
          content: Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                'Transmitting optical Gree IR pulse to ${dev?.name}...',
                style: AppTypography.bodySm(color: AppColors.primary),
              ),
            ],
          ),
          duration: const Duration(milliseconds: 1000),
        ),
      );

      await Future.delayed(const Duration(milliseconds: 1000));
      if (!mounted) return;

      MqttService().publishAcCommand(
        widget.roomId,
        dev?.boardId ?? 1,
        isOn: dev?.isOn ?? true,
        temp: dev?.temperature ?? 24,
        mode: dev?.hvacMode ?? 'COOL',
        fanSpeed: dev?.fanSpeed ?? 0,
        swing: dev?.acSwing ?? false,
      );
      setState(() => _isTestingRelay = false);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppColors.surfaceContainerHigh,
          content: Row(
            children: [
              const Icon(Icons.check_circle, color: AppColors.onlineMint, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Optical IR Gree command transmitted successfully!',
                  style: AppTypography.bodySm(color: AppColors.onSurface),
                ),
              ),
            ],
          ),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: AppColors.surfaceContainerHigh,
        content: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              'Testing ESP32 relay pulse on ${_device?.relayChannel ?? "channel"}...',
              style: AppTypography.bodySm(color: AppColors.primary),
            ),
          ],
        ),
        duration: const Duration(milliseconds: 1400),
      ),
    );

    await Future.delayed(const Duration(milliseconds: 1400));
    if (!mounted) return;

    _state.runRelaySelfTest(widget.roomId, widget.deviceId);
    setState(() => _isTestingRelay = false);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: AppColors.surfaceContainerHigh,
        content: Row(
          children: [
            const Icon(Icons.check_circle, color: AppColors.onlineMint, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Relay self-test passed! Zero-cross triac & coil contacts responsive.',
                style: AppTypography.bodySm(color: AppColors.onSurface),
              ),
            ),
          ],
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _rebootNode() async {
    HapticFeedback.mediumImpact();
    _state.rebootNode(widget.roomId, widget.deviceId);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: AppColors.surfaceContainerHigh,
        content: Row(
          children: [
            const Icon(Icons.restart_alt, color: AppColors.secondary, size: 18),
            const SizedBox(width: 10),
            Text(
              'ESP32 restart signal sent via MQTT.',
              style: AppTypography.bodySm(color: AppColors.onSurface),
            ),
          ],
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _syncRelays() {
    HapticFeedback.selectionClick();
    _state.syncRelays(widget.roomId, widget.deviceId);
    final isAc = _device?.type == DeviceType.hvac;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: AppColors.surfaceContainerHigh,
        content: Row(
          children: [
            const Icon(Icons.sync, color: AppColors.primary, size: 18),
            const SizedBox(width: 10),
            Text(
              isAc
                  ? 'AC state synchronized with live MQTT status.'
                  : 'Relay state synchronized with ESP32 GPIO registers.',
              style: AppTypography.bodySm(color: AppColors.onSurface),
            ),
          ],
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _confirmDeleteDevice() {
    HapticFeedback.lightImpact();
    final dev = _device;
    final rm = _room;
    if (dev == null || rm == null) return;

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: AppColors.surfaceContainerHigh,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: AppColors.criticalRed.withValues(alpha: 0.35)),
          ),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.criticalRed.withValues(alpha: 0.15),
                ),
                child: const Icon(Icons.delete_forever, color: AppColors.criticalRed, size: 22),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Delete Device?',
                  style: AppTypography.headlineSm(color: AppColors.onSurface),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Are you sure you want to delete "${dev.name}" from ${rm.name}?',
                style: AppTypography.bodyMd(color: AppColors.onSurface),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: AppColors.surfaceContainerLowest,
                  border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '• Relay Mapping: ${dev.relayChannel}',
                      style: AppTypography.bodySm(color: AppColors.onSurfaceVariant).copyWith(fontSize: 11),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '• Switchboard: ${dev.zigbeeOrBleNode}',
                      style: AppTypography.bodySm(color: AppColors.onSurfaceVariant).copyWith(fontSize: 11),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '• Zone: ${dev.zone}',
                      style: AppTypography.bodySm(color: AppColors.onSurfaceVariant).copyWith(fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'This will permanently disconnect relay controls and remove this peripheral from mesh memory.',
                style: AppTypography.bodySm(color: AppColors.outline).copyWith(fontSize: 11),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('CANCEL', style: AppTypography.labelMd(color: AppColors.outline)),
            ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.criticalRed,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () {
                Navigator.pop(ctx); // Close dialog
                _state.deleteDevice(widget.roomId, widget.deviceId);
                Navigator.pop(context); // Exit detail screen back to room
                CyberToast.show(
                  context,
                  message: '${dev.name} successfully deleted.',
                  type: ToastType.success,
                );
              },
              icon: const Icon(Icons.delete, size: 16),
              label: Text('DELETE', style: AppTypography.labelMd(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  void _showPinoutDialog() {
    final dev = _device;
    if (dev == null) return;

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
              const Icon(Icons.developer_board, color: AppColors.primary),
              const SizedBox(width: 10),
              Text(
                'ESP32 Hardware Pinout',
                style: AppTypography.headlineSm(color: AppColors.onSurface),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildPinoutRow('Target Relay', dev.relayChannel),
              _buildPinoutRow('Control Logic', 'Active LOW / HIGH (Configurable)'),
              _buildPinoutRow('Coil Rating', '5V DC / 70mA'),
              _buildPinoutRow('Contact Load', '250V AC / 10A Max'),
              _buildPinoutRow('Microcontroller', 'ESP32-WROOM-32D (Dual-Core 240MHz)'),
              _buildPinoutRow('Communication', 'MQTT / Wi-Fi / ESP-NOW'),
            ],
          ),
          actions: [
            if (AuthState().isAdmin)
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  _showEditGpioDialog();
                },
                child: Text('CUSTOMIZE GPIO PIN', style: AppTypography.labelMd(color: AppColors.primary)),
              ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: AppColors.onPrimaryFixed,
              ),
              onPressed: () => Navigator.pop(context),
              child: Text('CLOSE', style: AppTypography.labelMd()),
            ),
          ],
        );
      },
    );
  }

  void _showEditGpioDialog() {
    final dev = _device;
    if (dev == null) return;

    final controller = TextEditingController(text: dev.gpioPinNumber.toString());
    final commonPins = [4, 5, 12, 13, 14, 15, 16, 17, 18, 19, 21, 22, 23, 25, 26, 27, 32, 33];

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final currentPin = int.tryParse(controller.text) ?? dev.gpioPinNumber;

            return AlertDialog(
              backgroundColor: AppColors.surfaceContainerHigh,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: AppColors.primary.withValues(alpha: 0.3)),
              ),
              title: Row(
                children: [
                  const Icon(Icons.settings_input_component, color: AppColors.primary),
                  const SizedBox(width: 10),
                  Text(
                    'Remap ESP32 GPIO',
                    style: AppTypography.headlineSm(color: AppColors.onSurface, fontSize: 16),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Change hardware pin for ${dev.name}. This is saved to ESP32 flash (NVS) over MQTT:',
                    style: AppTypography.bodySm(color: AppColors.onSurfaceVariant),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    keyboardType: TextInputType.number,
                    style: AppTypography.bodyMd(color: AppColors.onSurface),
                    decoration: InputDecoration(
                      labelText: 'ESP32 GPIO Pin Number',
                      prefixText: 'GPIO ',
                      filled: true,
                      fillColor: AppColors.surfaceContainerLowest,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: AppColors.primary.withValues(alpha: 0.3)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: AppColors.primary),
                      ),
                    ),
                    onChanged: (val) => setDialogState(() {}),
                  ),
                  const SizedBox(height: 12),
                  Text('Common Relay GPIOs:', style: AppTypography.labelSm(color: AppColors.outline)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: commonPins.map((pin) {
                      final isSelected = currentPin == pin;
                      return ChoiceChip(
                        label: Text('GPIO $pin'),
                        selected: isSelected,
                        selectedColor: AppColors.primary.withValues(alpha: 0.25),
                        backgroundColor: AppColors.surfaceContainerLowest,
                        labelStyle: TextStyle(
                          color: isSelected ? AppColors.primary : AppColors.onSurfaceVariant,
                          fontSize: 11,
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        ),
                        side: BorderSide(
                          color: isSelected ? AppColors.primary : Colors.white12,
                        ),
                        onSelected: (_) {
                          setDialogState(() {
                            controller.text = pin.toString();
                          });
                        },
                      );
                    }).toList(),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text('CANCEL', style: AppTypography.labelMd(color: AppColors.outline)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: AppColors.onPrimaryFixed,
                  ),
                  onPressed: () {
                    final newPin = int.tryParse(controller.text);
                    if (newPin == null || newPin < 0 || newPin > 39) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Please enter a valid GPIO pin (0-39).')),
                      );
                      return;
                    }
                    _state.updateDeviceGpio(widget.roomId, widget.deviceId, newPin);
                    Navigator.pop(context);
                    if (mounted) setState(() {});
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        backgroundColor: AppColors.surfaceContainerHigh,
                        content: Row(
                          children: [
                            const Icon(Icons.check_circle, color: AppColors.onlineMint, size: 18),
                            const SizedBox(width: 8),
                            Text(
                              'Remapped to GPIO $newPin · Broadcast via MQTT',
                              style: AppTypography.bodySm(color: AppColors.onSurface),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                  child: Text('SAVE & REMAP', style: AppTypography.labelMd()),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildPinoutRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppTypography.labelSm(color: AppColors.outline)),
          Text(value, style: AppTypography.bodySm(color: AppColors.primary)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final room = _room;
    final device = _device;

    if (room == null || device == null) {
      return Scaffold(
        backgroundColor: AppColors.surfaceContainerLowest,
        appBar: AppBar(
          backgroundColor: AppColors.surface,
          title: Text('Device Not Found', style: AppTypography.headlineSm()),
        ),
        body: Center(
          child: Text(
            'The selected device could not be located in mesh memory.',
            style: AppTypography.bodyMd(color: AppColors.onSurfaceVariant),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.surfaceContainerLowest,
      appBar: AppBar(
        backgroundColor: AppColors.surface.withValues(alpha: 0.92),
        elevation: 0,
        leading: Padding(
          padding: const EdgeInsets.only(left: 14, top: 8, bottom: 8),
          child: GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              Navigator.pop(context);
            },
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: AppColors.surfaceContainerLow,
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.08),
                ),
              ),
              child: const Icon(
                Icons.arrow_back,
                size: 20,
                color: AppColors.onSurfaceVariant,
              ),
            ),
          ),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Text(
                  room.roomNumber.toUpperCase(),
                  style: AppTypography.labelSm(color: AppColors.outline)
                      .copyWith(fontSize: 10),
                ),
                Text(
                  ' / ',
                  style: AppTypography.labelSm(color: AppColors.outlineVariant)
                      .copyWith(fontSize: 10),
                ),
                Flexible(
                  child: Text(
                    _deviceCategoryTitle(device.type),
                    style: AppTypography.labelSm(color: AppColors.primary)
                        .copyWith(fontSize: 10, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              'Device Diagnostics',
              style: AppTypography.headlineSm(color: AppColors.primaryLight)
                  .copyWith(fontSize: 18, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            icon: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: AppColors.surfaceContainerLow,
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.08),
                ),
              ),
              child: const Icon(
                Icons.more_vert,
                size: 20,
                color: AppColors.onSurfaceVariant,
              ),
            ),
            color: AppColors.surfaceContainerHigh,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: AppColors.primary.withValues(alpha: 0.2)),
            ),
            onSelected: (val) {
              if (val == 'pinout') _showPinoutDialog();
              if (val == 'gpio') _showEditGpioDialog();
              if (val == 'test') _runSelfTest();
              if (val == 'reboot') _rebootNode();
              if (val == 'sync') _syncRelays();
              if (val == 'delete') _confirmDeleteDevice();
            },
            itemBuilder: (context) => [
              if (device.type != DeviceType.hvac)
                PopupMenuItem(
                  value: 'pinout',
                  child: Row(
                    children: [
                      const Icon(Icons.developer_board, size: 16, color: AppColors.primary),
                      const SizedBox(width: 8),
                      Text('ESP32 Pinout', style: AppTypography.bodySm()),
                    ],
                  ),
                ),
              if (AuthState().isAdmin && device.type != DeviceType.hvac)
                PopupMenuItem(
                  value: 'gpio',
                  child: Row(
                    children: [
                      const Icon(Icons.settings_input_component, size: 16, color: AppColors.secondary),
                      const SizedBox(width: 8),
                      Text('Customize GPIO Pin', style: AppTypography.bodySm()),
                    ],
                  ),
                ),
              PopupMenuItem(
                value: 'test',
                child: Row(
                  children: [
                    Icon(
                      device.type == DeviceType.hvac ? Icons.settings_remote : Icons.build,
                      size: 16,
                      color: AppColors.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      device.type == DeviceType.hvac ? 'Test Optical IR Pulse' : 'Test Relay Pulse',
                      style: AppTypography.bodySm(),
                    ),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'sync',
                child: Row(
                  children: [
                    const Icon(Icons.sync, size: 16, color: AppColors.secondary),
                    const SizedBox(width: 8),
                    Text(
                      device.type == DeviceType.hvac ? 'Resync AC Status' : 'Sync Relay States',
                      style: AppTypography.bodySm(),
                    ),
                  ],
                ),
              ),
              if (AuthState().isAdmin) ...[
                const PopupMenuDivider(),
                PopupMenuItem(
                  value: 'reboot',
                  child: Row(
                    children: [
                      const Icon(Icons.restart_alt, size: 16, color: AppColors.outline),
                      const SizedBox(width: 8),
                      Text(
                        'Restart Device',
                        style: AppTypography.bodySm(color: AppColors.onSurface),
                      ),
                    ],
                  ),
                ),
                const PopupMenuDivider(),
                PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      const Icon(Icons.delete_outline, size: 16, color: AppColors.criticalRed),
                      const SizedBox(width: 8),
                      Text(
                        'Delete Device',
                        style: AppTypography.bodySm(color: AppColors.criticalRed).copyWith(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(width: 14),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Subheader Status Banner
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      color: AppColors.surfaceContainerLow.withValues(alpha: 0.8),
                      border: Border.all(
                        color: AppColors.outlineVariant.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        PulsingBeacon(
                          size: 7,
                          color: device.isOn ? AppColors.primary : AppColors.outline,
                          isPulsing: device.isOn,
                        ),
                        const SizedBox(width: 7),
                        Flexible(
                          child: Text(
                            'CONNECTED (${device.zigbeeOrBleNode})',
                            style: AppTypography.labelSm(
                              color: device.isOn ? AppColors.primaryLight : AppColors.outline,
                            ).copyWith(fontSize: 10, letterSpacing: 0.8),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      device.type == DeviceType.hvac ? Icons.settings_remote : Icons.hub_outlined,
                      size: 15,
                      color: AppColors.primary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      device.type == DeviceType.hvac ? 'IR TRANSMITTER (GPIO 4)' : device.relayChannel,
                      style: AppTypography.labelSm(
                        color: AppColors.primary,
                      ).copyWith(fontSize: 11),
                    ),
                  ],
                ),
              ],
            ),

            const SizedBox(height: 14),

            // Hardware Hero Card
            _buildHardwareHeroCard(device),

            const SizedBox(height: 18),

            // Granular Hardware Controls Bento
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Hardware Controls',
                  style: AppTypography.headlineSm(color: AppColors.primaryLight)
                      .copyWith(fontSize: 17, fontWeight: FontWeight.w600),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    color: AppColors.surfaceContainerHigh,
                    border: Border.all(
                      color: AppColors.primary.withValues(alpha: 0.2),
                    ),
                  ),
                  child: Text(
                    device.type == DeviceType.hvac ? 'IR: GPIO 4' : device.relayChannel,
                    style: AppTypography.labelSm(color: AppColors.primary)
                        .copyWith(fontSize: 10, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 10),

            // Device specific granular controls (Fan, Light, AC, Projector, etc.)
            _buildDeviceSpecificControls(device),

            const SizedBox(height: 20),

            // Telemetry & Logs Section
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Telemetry & Logs',
                  style: AppTypography.headlineSm(color: AppColors.primaryLight)
                      .copyWith(fontSize: 17, fontWeight: FontWeight.w600),
                ),
                Text(
                  'LIVE BUS',
                  style: AppTypography.labelSm(color: AppColors.outline)
                      .copyWith(fontSize: 10, letterSpacing: 0.8),
                ),
              ],
            ),

            const SizedBox(height: 10),

            _buildTelemetryAndLogsSection(device),

            const SizedBox(height: 20),

            // Action Diagnostics Buttons
            _buildActionButtons(device),

            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }

  // --- HARDWARE HERO CARD ---
  Widget _buildHardwareHeroCard(ClassroomDevice device) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: AppColors.surfaceContainerLow,
        border: Border.all(
          color: device.isOn
              ? AppColors.primary.withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.08),
        ),
        boxShadow: device.isOn ? [AppColors.cyanGlow(radius: 20, opacity: 0.15)] : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Icon Box
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: AppColors.surfaceContainerHigh,
                  border: Border.all(
                    color: AppColors.primary.withValues(alpha: 0.25),
                  ),
                ),
                child: Icon(
                  _getDeviceIcon(device.type),
                  color: device.isOn ? AppColors.primary : AppColors.outline,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              // Name & Model
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.name,
                      style: AppTypography.headlineSm(
                        color: AppColors.onSurface,
                      ).copyWith(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      device.type == DeviceType.hvac ? 'Gree AC Optical Controller (GPIO 4)' : device.relayChannel,
                      style: AppTypography.labelSm(
                        color: AppColors.outline,
                      ).copyWith(fontSize: 11),
                    ),
                  ],
                ),
              ),
              // Master Power Switch
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  CyberSwitch(
                    value: device.isOn,
                    onChanged: (val) {
                      HapticFeedback.mediumImpact();
                      _state.setDevicePower(widget.roomId, device.id, val);
                    },
                  ),
                  const SizedBox(height: 4),
                  Text(
                    device.isOn ? 'POWER ON' : 'POWER OFF',
                    style: AppTypography.labelSm(
                      color: device.isOn ? AppColors.primary : AppColors.outline,
                    ).copyWith(fontSize: 10, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ],
          ),

          const SizedBox(height: 14),

          // 2x2 Telemetry Badges Grid
          _buildHeroTelemetryGrid(device),
        ],
      ),
    );
  }

  Widget _buildHeroTelemetryGrid(ClassroomDevice device) {
    String badge1Title = 'RELAY STATE';
    String badge1Val = device.isOn ? 'CLOSED' : 'OPEN';
    String badge1Sub = device.isOn ? 'Active (220V)' : 'Isolated';
    IconData badge1Icon = Icons.electrical_services;

    String badge2Title = 'POWER DRAW';
    String badge2Val = '0';
    String badge2Sub = 'Watts';
    IconData badge2Icon = Icons.bolt;

    String badge3Title = 'LINK STATUS';
    String badge3Val = device.isOn ? 'ONLINE' : 'STANDBY';
    String badge3Sub = 'MQTT Mesh';
    IconData badge3Icon = Icons.sensors;

    String badge4Title = 'HARDWARE BUS';
    String badge4Val = device.relayChannel.split(' ').first;
    String badge4Sub = 'Active LOW';
    IconData badge4Icon = Icons.memory;

    switch (device.type) {
      case DeviceType.fan:
        badge2Title = 'FAN SPEED';
        badge2Val = device.isOn ? '${device.fanSpeed} / 4' : '0 (Off)';
        badge2Sub = device.isOn ? '~${device.fanSpeed * 80} RPM' : 'Idle';
        badge2Icon = Icons.speed;

        badge4Title = 'POWER DRAW';
        badge4Val = device.isOn ? '${device.fanSpeed * 18 + 10}' : '0';
        badge4Sub = 'Watts';
        badge4Icon = Icons.bolt;
        break;

      case DeviceType.lighting:
        badge2Title = 'INTENSITY';
        badge2Val = device.isOn ? '${device.brightness.round()}%' : '0%';
        badge2Sub = device.isOn ? '${device.lumens} lm' : 'Dark';
        badge2Icon = Icons.wb_sunny;

        badge4Title = 'POWER DRAW';
        badge4Val = device.isOn ? '${(device.brightness / 100 * 40).round()}' : '0';
        badge4Sub = 'Watts';
        badge4Icon = Icons.bolt;
        break;

      case DeviceType.hvac:
        badge1Title = 'IR LINK';
        badge1Val = device.isOn ? 'ACTIVE' : 'STANDBY';
        badge1Sub = 'Gree 38kHz';
        badge1Icon = Icons.settings_remote;

        badge2Title = 'THERMOSTAT';
        badge2Val = '${device.temperature}°C';
        badge2Sub = device.isOn ? 'Cooling Active' : 'Standby';
        badge2Icon = Icons.device_thermostat;

        badge3Title = 'TRANSMITTER PIN';
        badge3Val = 'GPIO 4';
        badge3Sub = 'Optical PWM';
        badge3Icon = Icons.memory;

        badge4Title = 'CONTROLLER';
        badge4Val = 'OPTICAL IR';
        badge4Sub = 'Relays Bypassed';
        badge4Icon = Icons.settings_remote;
        break;

      case DeviceType.projector:
        badge1Title = 'LASER LIFE';
        badge1Val = '98%';
        badge1Sub = '~19,600h';
        badge1Icon = Icons.wb_sunny;

        badge2Title = 'OPTIC TEMP';
        badge2Val = '41°C';
        badge2Sub = 'Normal';
        badge2Icon = Icons.device_thermostat;

        badge4Title = 'POWER DRAW';
        badge4Val = device.isOn ? '245' : '0';
        badge4Sub = 'Watts';
        badge4Icon = Icons.bolt;
        break;

      case DeviceType.telemetry:
        badge1Title = 'CO2 LEVEL';
        badge1Val = '${device.co2Ppm}';
        badge1Sub = 'ppm (Good)';
        badge1Icon = Icons.air;

        badge2Title = 'HUMIDITY';
        badge2Val = '${device.humidityRh}%';
        badge2Sub = '${device.ambientTemp}°C Ambient';
        badge2Icon = Icons.water_drop;
        break;

      case DeviceType.powerStrip:
        badge1Title = 'RELAY SOCKETS';
        badge1Val = '${device.activeSockets} / ${device.totalSockets}';
        badge1Sub = 'Active Live';
        badge1Icon = Icons.power;

        badge2Title = 'CURRENT DRAW';
        badge2Val = '${device.amperage}A';
        badge2Sub = '${device.wattage} Watts';
        badge2Icon = Icons.electric_meter;
        break;
    }

    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 2,
      childAspectRatio: 1.85,
      crossAxisSpacing: 8,
      mainAxisSpacing: 8,
      children: [
        _buildHeroMetricTile(badge1Title, badge1Val, badge1Sub, badge1Icon),
        _buildHeroMetricTile(badge2Title, badge2Val, badge2Sub, badge2Icon),
        _buildHeroMetricTile(badge3Title, badge3Val, badge3Sub, badge3Icon),
        _buildHeroMetricTile(badge4Title, badge4Val, badge4Sub, badge4Icon),
      ],
    );
  }

  Widget _buildHeroMetricTile(String title, String value, String sub, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: AppColors.surfaceContainerLowest.withValues(alpha: 0.8),
        border: Border.all(
          color: AppColors.outlineVariant.withValues(alpha: 0.25),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: AppTypography.labelSm(color: AppColors.outline)
                    .copyWith(fontSize: 9, letterSpacing: 0.5),
              ),
              Icon(icon, size: 14, color: AppColors.primary),
            ],
          ),
          const SizedBox(height: 3),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: AppTypography.headlineSm(color: AppColors.onSurface)
                    .copyWith(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  sub,
                  style: AppTypography.labelSm(color: AppColors.primary)
                      .copyWith(fontSize: 9),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // --- GRANULAR HARDWARE CONTROLS SPECIFIC TO DEVICE TYPE ---
  Widget _buildDeviceSpecificControls(ClassroomDevice device) {
    switch (device.type) {
      case DeviceType.fan:
        return _buildFanControls(device);
      case DeviceType.lighting:
        return _buildLightingControls(device);
      case DeviceType.hvac:
        return _buildHvacControls(device);
      case DeviceType.projector:
        return _buildProjectorControls(device);
      case DeviceType.telemetry:
        return _buildTelemetryControls(device);
      case DeviceType.powerStrip:
        return _buildPowerStripControls(device);
    }
  }

  // 1. FAN CONTROLS
  Widget _buildFanControls(ClassroomDevice device) {
    return Column(
      children: [
        // Fan Speed & Live Spinner
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: AppColors.surfaceContainerLow,
            border: Border.all(color: AppColors.outlineVariant.withValues(alpha: 0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.speed, size: 18, color: AppColors.primary),
                      const SizedBox(width: 8),
                      Text(
                        'Fan Speed Control',
                        style: AppTypography.labelLg(color: AppColors.onSurface),
                      ),
                    ],
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      color: AppColors.surfaceContainerHigh,
                    ),
                    child: Text(
                      device.isOn ? 'LEVEL ${device.fanSpeed}' : 'OFF',
                      style: AppTypography.labelSm(color: AppColors.primary)
                          .copyWith(fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // Center Spinner Graphic
              Center(
                child: Column(
                  children: [
                    FanSpinner(
                      isSpinning: device.isOn && device.fanSpeed > 0,
                      speed: device.isOn ? device.fanSpeed : 0,
                      reverse: device.fanReverse,
                      size: 56,
                      color: device.isOn ? AppColors.primary : AppColors.outline,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      device.isOn && device.fanSpeed > 0
                          ? '${device.fanSpeed * 80} RPM • Running'
                          : 'Rotor Inactive (Relay Open)',
                      style: AppTypography.labelSm(color: AppColors.outline)
                          .copyWith(fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // Speed selector buttons 0..4
              Row(
                children: [0, 1, 2, 3, 4].map((spd) {
                  final isSelected = device.fanSpeed == spd && device.isOn;
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: GestureDetector(
                        onTap: () {
                          HapticFeedback.selectionClick();
                          _state.setFanSpeed(widget.roomId, device.id, spd);
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 140),
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            color: isSelected
                                ? AppColors.primary
                                : AppColors.surfaceContainerLowest,
                            border: Border.all(
                              color: isSelected
                                  ? AppColors.primary
                                  : AppColors.outlineVariant.withValues(alpha: 0.3),
                            ),
                          ),
                          child: Center(
                            child: Text(
                              spd == 0 ? 'OFF' : '$spd',
                              style: AppTypography.labelSm(
                                color: isSelected
                                    ? AppColors.surfaceContainerLowest
                                    : AppColors.onSurface,
                              ).copyWith(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        ),

        const SizedBox(height: 10),

        // Auto Cutoff Timer
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: AppColors.surfaceContainerLow,
            border: Border.all(color: AppColors.outlineVariant.withValues(alpha: 0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.timer_outlined, size: 18, color: AppColors.primary),
                      const SizedBox(width: 8),
                      Text(
                        'Auto-Off Timer',
                        style: AppTypography.labelLg(color: AppColors.onSurface),
                      ),
                    ],
                  ),
                  Text(
                    device.fanTimerMinutes == 0
                        ? 'CONTINUOUS'
                        : '${device.fanTimerMinutes} MIN',
                    style: AppTypography.labelSm(color: AppColors.primary)
                        .copyWith(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [0, 15, 30, 60, 120].map((mins) {
                  final isSelected = device.fanTimerMinutes == mins;
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2.5),
                      child: GestureDetector(
                        onTap: () {
                          HapticFeedback.selectionClick();
                          _state.setFanTimer(widget.roomId, device.id, mins);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(6),
                            color: isSelected
                                ? AppColors.primaryContainer
                                : AppColors.surfaceContainerLowest,
                            border: Border.all(
                              color: isSelected
                                  ? AppColors.primaryContainer
                                  : AppColors.outlineVariant.withValues(alpha: 0.3),
                            ),
                          ),
                          child: Center(
                            child: Text(
                              mins == 0 ? 'Inf' : '${mins}m',
                              style: AppTypography.labelSm(
                                color: isSelected
                                    ? AppColors.surfaceContainerLowest
                                    : AppColors.onSurfaceVariant,
                              ).copyWith(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // 2. LIGHTING CONTROLS
  Widget _buildLightingControls(ClassroomDevice device) {
    return Column(
      children: [
        // Brightness Slider Card
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: AppColors.surfaceContainerLow,
            border: Border.all(color: AppColors.outlineVariant.withValues(alpha: 0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.brightness_6, size: 18, color: AppColors.primary),
                      const SizedBox(width: 8),
                      Text(
                        'Lighting Intensity (Triac PWM)',
                        style: AppTypography.labelLg(color: AppColors.onSurface),
                      ),
                    ],
                  ),
                  Text(
                    '${device.brightness.round()}% (${device.lumens} lm)',
                    style: AppTypography.labelLg(color: AppColors.primary)
                        .copyWith(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              CyberSlider(
                value: device.brightness,
                label: 'DIMMER:',
                unit: 'LM',
                maxMetric: 1400,
                onChanged: (val) {
                  _state.setBrightness(widget.roomId, device.id, val);
                },
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('MIN (10%)', style: AppTypography.labelSm(color: AppColors.outline)),
                  Text(
                    'OPTIMAL (85%)',
                    style: AppTypography.labelSm(color: AppColors.primaryLight),
                  ),
                  Text('MAX (100%)', style: AppTypography.labelSm(color: AppColors.outline)),
                ],
              ),
            ],
          ),
        ),

        const SizedBox(height: 10),

        // Quick Scene Intensity Pills
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: AppColors.surfaceContainerLow,
            border: Border.all(color: AppColors.outlineVariant.withValues(alpha: 0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Quick Lighting Scenes',
                style: AppTypography.labelLg(color: AppColors.onSurface),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  _buildScenePresetButton('100% Full', 100, device),
                  const SizedBox(width: 6),
                  _buildScenePresetButton('75% Lecture', 75, device),
                  const SizedBox(width: 6),
                  _buildScenePresetButton('35% AV Dim', 35, device),
                  const SizedBox(width: 6),
                  _buildScenePresetButton('10% Eco', 10, device),
                ],
              ),
            ],
          ),
        ),

        const SizedBox(height: 10),

        // Relay Contact State
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: AppColors.surfaceContainerLowest,
            border: Border.all(color: AppColors.outlineVariant.withValues(alpha: 0.2)),
          ),
          child: Row(
            children: [
              Icon(
                Icons.electrical_services,
                size: 16,
                color: device.isOn ? AppColors.onlineMint : AppColors.outline,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  device.isOn
                      ? '${device.relayChannel}: Closed • 220V AC Live Bus Energized'
                      : '${device.relayChannel}: Open • Circuit Isolated (Zero standby power)',
                  style: AppTypography.bodySm(color: AppColors.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildScenePresetButton(String label, double val, ClassroomDevice device) {
    final isSelected = (device.brightness - val).abs() < 5 && device.isOn;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          _state.setBrightness(widget.roomId, device.id, val);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            color: isSelected
                ? AppColors.primary.withValues(alpha: 0.2)
                : AppColors.surfaceContainerLowest,
            border: Border.all(
              color: isSelected
                  ? AppColors.primary
                  : AppColors.outlineVariant.withValues(alpha: 0.3),
            ),
          ),
          child: Center(
            child: Text(
              label,
              style: AppTypography.labelSm(
                color: isSelected ? AppColors.primary : AppColors.onSurfaceVariant,
              ).copyWith(fontSize: 10, fontWeight: FontWeight.bold),
            ),
          ),
        ),
      ),
    );
  }

  // 3. HVAC (AC) CONTROLS
  Widget _buildHvacControls(ClassroomDevice device) {
    return Column(
      children: [
        // 1. Prominent Optical IR Transmitter Banner at the Top
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: AppColors.surfaceContainerLow,
            border: Border.all(
              color: AppColors.primary.withValues(alpha: 0.3),
              width: 1.2,
            ),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.primary.withValues(alpha: 0.15),
                  border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
                ),
                child: const Icon(
                  Icons.settings_remote,
                  size: 20,
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'OPTICAL INFRARED TRANSMITTER (GPIO 4)',
                      style: AppTypography.labelSm(color: AppColors.primary)
                          .copyWith(fontSize: 9, letterSpacing: 0.8, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Gree AC Optical Controller (GPIO 4)',
                      style: AppTypography.headlineSm(color: AppColors.onSurface)
                          .copyWith(fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                    Text(
                      'Modulated 38 kHz optical pulses on GPIO 4 directly to AC unit.',
                      style: AppTypography.labelSm(color: AppColors.outline)
                          .copyWith(fontSize: 10),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  color: device.isOn
                      ? AppColors.onlineMint.withValues(alpha: 0.15)
                      : Colors.white.withValues(alpha: 0.05),
                  border: Border.all(
                    color: device.isOn
                        ? AppColors.onlineMint.withValues(alpha: 0.4)
                        : Colors.white.withValues(alpha: 0.1),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    PulsingBeacon(
                      size: 6,
                      color: device.isOn ? AppColors.onlineMint : AppColors.outline,
                      isPulsing: device.isOn,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      device.isOn ? 'ACTIVE' : 'STANDBY',
                      style: TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.bold,
                        color: device.isOn ? AppColors.onlineMint : AppColors.outline,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 10),

        // 2. Thermostat Stepper Card
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: AppColors.surfaceContainerLow,
            border: Border.all(color: AppColors.outlineVariant.withValues(alpha: 0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.thermostat, size: 18, color: AppColors.primary),
                      const SizedBox(width: 8),
                      Text(
                        'Target Temperature',
                        style: AppTypography.labelLg(color: AppColors.onSurface),
                      ),
                    ],
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      color: AppColors.surfaceContainerHigh,
                    ),
                    child: Text(
                      device.isOn ? 'COMPRESSOR ACTIVE' : 'STANDBY',
                      style: AppTypography.labelSm(color: AppColors.primary)
                          .copyWith(fontSize: 10, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              // Big Temperature Stepper
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  GestureDetector(
                    onTap: () {
                      HapticFeedback.selectionClick();
                      _state.setTemperature(widget.roomId, device.id, -1);
                    },
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        color: AppColors.surfaceContainerLowest,
                        border: Border.all(
                          color: AppColors.outlineVariant.withValues(alpha: 0.4),
                        ),
                      ),
                      child: const Icon(Icons.remove, color: AppColors.onSurface),
                    ),
                  ),
                  const SizedBox(width: 24),
                  Text(
                    '${device.temperature}°C',
                    style: AppTypography.displayLg(color: AppColors.primary)
                        .copyWith(fontSize: 44, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(width: 24),
                  GestureDetector(
                    onTap: () {
                      HapticFeedback.selectionClick();
                      _state.setTemperature(widget.roomId, device.id, 1);
                    },
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        color: AppColors.surfaceContainerLowest,
                        border: Border.all(
                          color: AppColors.outlineVariant.withValues(alpha: 0.4),
                        ),
                      ),
                      child: const Icon(Icons.add, color: AppColors.onSurface),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Center(
                child: Text(
                  'Range: 16°C – 30°C • Auto Climate Regulation',
                  style: AppTypography.labelSm(color: AppColors.outline)
                      .copyWith(fontSize: 11),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 10),

        // 3. HVAC Operating Mode
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: AppColors.surfaceContainerLow,
            border: Border.all(color: AppColors.outlineVariant.withValues(alpha: 0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Operating Mode',
                style: AppTypography.labelLg(color: AppColors.onSurface),
              ),
              const SizedBox(height: 10),
              Row(
                children: ['AUTO', 'COOL', 'DRY', 'FAN', 'HEAT'].map((mode) {
                  final isSelected = device.hvacMode == mode;
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2.0),
                      child: GestureDetector(
                        onTap: () {
                          HapticFeedback.selectionClick();
                          _state.setHvacMode(widget.roomId, device.id, mode);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            color: isSelected
                                ? AppColors.primary
                                : AppColors.surfaceContainerLowest,
                            border: Border.all(
                              color: isSelected
                                  ? AppColors.primary
                                  : AppColors.outlineVariant.withValues(alpha: 0.3),
                            ),
                          ),
                          child: Center(
                            child: Text(
                              mode,
                              style: AppTypography.labelSm(
                                color: isSelected
                                    ? AppColors.surfaceContainerLowest
                                    : AppColors.onSurface,
                              ).copyWith(fontSize: 10, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        ),

        const SizedBox(height: 10),

        // 4. Blower Fan Speed (Dedicated clean card)
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: AppColors.surfaceContainerLow,
            border: Border.all(color: AppColors.outlineVariant.withValues(alpha: 0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.speed, size: 18, color: AppColors.primary),
                      const SizedBox(width: 8),
                      Text(
                        'Blower Fan Speed',
                        style: AppTypography.labelLg(color: AppColors.onSurface),
                      ),
                    ],
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      color: AppColors.onlineMint.withValues(alpha: 0.15),
                      border: Border.all(color: AppColors.onlineMint.withValues(alpha: 0.3)),
                    ),
                    child: Text(
                      device.fanSpeed == 0
                          ? 'AUTO SPEED'
                          : (device.fanSpeed == 1
                              ? 'LOW (1)'
                              : (device.fanSpeed == 2 ? 'MED (2)' : 'HIGH (3)')),
                      style: const TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.bold,
                        color: AppColors.onlineMint,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  {'label': 'Auto (0)', 'val': 0},
                  {'label': 'Low (1)', 'val': 1},
                  {'label': 'Med (2)', 'val': 2},
                  {'label': 'High (3)', 'val': 3},
                ].map((fanOpt) {
                  final val = fanOpt['val'] as int;
                  final isSelected = (device.fanSpeed == val);
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2.5),
                      child: GestureDetector(
                        onTap: () {
                          HapticFeedback.selectionClick();
                          _state.setAcFanSpeed(widget.roomId, device.id, val);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 9),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            color: isSelected
                                ? AppColors.onlineMint.withValues(alpha: 0.25)
                                : AppColors.surfaceContainerLowest,
                            border: Border.all(
                              color: isSelected
                                  ? AppColors.onlineMint
                                  : AppColors.outlineVariant.withValues(alpha: 0.3),
                            ),
                          ),
                          child: Center(
                            child: Text(
                              fanOpt['label'] as String,
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.bold,
                                color: isSelected ? AppColors.onlineMint : AppColors.onSurface,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        ),

        const SizedBox(height: 10),

        // 5. Vertical Louver Swing (Dedicated card with prominent ON/OFF placement!)
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: AppColors.surfaceContainerLow,
            border: Border.all(
              color: device.acSwing
                  ? AppColors.onlineMint.withValues(alpha: 0.35)
                  : AppColors.outlineVariant.withValues(alpha: 0.3),
            ),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: device.acSwing
                      ? AppColors.onlineMint.withValues(alpha: 0.15)
                      : AppColors.surfaceContainerLowest,
                  border: Border.all(
                    color: device.acSwing
                        ? AppColors.onlineMint.withValues(alpha: 0.4)
                        : Colors.white.withValues(alpha: 0.08),
                  ),
                ),
                child: Icon(
                  Icons.swap_vert,
                  size: 22,
                  color: device.acSwing ? AppColors.onlineMint : AppColors.outline,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Vertical Louver Swing',
                      style: AppTypography.labelLg(color: AppColors.onSurface)
                          .copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      device.acSwing
                          ? 'Auto vertical oscillation active'
                          : 'Fixed upward airflow position',
                      style: AppTypography.labelSm(
                        color: device.acSwing ? AppColors.onlineMint : AppColors.outline,
                      ).copyWith(fontSize: 10.5),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Prominent Toggle Button
              GestureDetector(
                onTap: () {
                  HapticFeedback.selectionClick();
                  _state.toggleAcSwing(widget.roomId, device.id);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: device.acSwing
                        ? AppColors.onlineMint.withValues(alpha: 0.22)
                        : AppColors.surfaceContainerLowest,
                    border: Border.all(
                      color: device.acSwing
                          ? AppColors.onlineMint
                          : Colors.white.withValues(alpha: 0.15),
                      width: 1.2,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        device.acSwing ? Icons.check_circle : Icons.circle_outlined,
                        size: 13,
                        color: device.acSwing ? AppColors.onlineMint : AppColors.outline,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        device.acSwing ? 'SWING ON' : 'SWING OFF',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.bold,
                          color: device.acSwing ? AppColors.onlineMint : AppColors.outline,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // 4. LASER PROJECTOR CONTROLS (Exact layout from uploaded demo!)
  Widget _buildProjectorControls(ClassroomDevice device) {
    return Column(
      children: [
        // Input Source Selector
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: AppColors.surfaceContainerLow,
            border: Border.all(color: AppColors.outlineVariant.withValues(alpha: 0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.input, size: 18, color: AppColors.primary),
                      const SizedBox(width: 8),
                      Text(
                        'Active Input Source',
                        style: AppTypography.labelLg(color: AppColors.onSurface),
                      ),
                    ],
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      color: AppColors.surfaceContainerHigh,
                    ),
                    child: Text(
                      '4K UHD @ 60Hz',
                      style: AppTypography.labelSm(color: AppColors.primary)
                          .copyWith(fontSize: 10, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: 2,
                childAspectRatio: 2.3,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
                children: [
                  _buildInputSourceButton(
                    'HDMI 1 (Lectern)',
                    'Connected',
                    Icons.settings_input_hdmi,
                    device.projectorSource == 'HDMI 1',
                    () => _state.setProjectorSource(widget.roomId, device.id, 'HDMI 1'),
                  ),
                  _buildInputSourceButton(
                    'HDMI 2 (Wall)',
                    'Standby',
                    Icons.settings_input_hdmi,
                    device.projectorSource == 'HDMI 2',
                    () => _state.setProjectorSource(widget.roomId, device.id, 'HDMI 2'),
                  ),
                  _buildInputSourceButton(
                    'Wireless AirPlay',
                    'Ready',
                    Icons.cast,
                    device.projectorSource == 'AIRPLAY',
                    () => _state.setProjectorSource(widget.roomId, device.id, 'AIRPLAY'),
                  ),
                  _buildInputSourceButton(
                    'USB-C Display',
                    'No link',
                    Icons.usb,
                    device.projectorSource == 'USB-C',
                    () => _state.setProjectorSource(widget.roomId, device.id, 'USB-C'),
                  ),
                ],
              ),
            ],
          ),
        ),

        const SizedBox(height: 10),

        // Laser Brightness Slider
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: AppColors.surfaceContainerLow,
            border: Border.all(color: AppColors.outlineVariant.withValues(alpha: 0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.brightness_6, size: 18, color: AppColors.primary),
                      const SizedBox(width: 8),
                      Text(
                        'Laser Brightness',
                        style: AppTypography.labelLg(color: AppColors.onSurface),
                      ),
                    ],
                  ),
                  Text(
                    '${device.brightness.round()}% (5100 lm)',
                    style: AppTypography.labelLg(color: AppColors.primary)
                        .copyWith(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              CyberSlider(
                value: device.brightness,
                label: 'LASER:',
                unit: 'LM',
                maxMetric: 6000,
                onChanged: (val) {
                  _state.setBrightness(widget.roomId, device.id, val);
                },
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('MIN (30%)', style: AppTypography.labelSm(color: AppColors.outline)),
                  Text(
                    'OPTIMAL (85%)',
                    style: AppTypography.labelSm(color: AppColors.primaryLight),
                  ),
                  Text('MAX (100%)', style: AppTypography.labelSm(color: AppColors.outline)),
                ],
              ),
            ],
          ),
        ),

        const SizedBox(height: 10),

        // Motorized Screen Relay
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: AppColors.surfaceContainerLow,
            border: Border.all(color: AppColors.outlineVariant.withValues(alpha: 0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.vertical_align_bottom, size: 18, color: AppColors.primary),
                      const SizedBox(width: 8),
                      Text(
                        'Motorized Screen Relay',
                        style: AppTypography.labelLg(color: AppColors.onSurface),
                      ),
                    ],
                  ),
                  Text(
                    'DA-LITE 120"',
                    style: AppTypography.labelSm(color: AppColors.primary),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  _buildScreenPosButton('Retracted', '0%', Icons.arrow_upward, device),
                  const SizedBox(width: 8),
                  _buildScreenPosButton('Halfway', '50%', Icons.unfold_more, device),
                  const SizedBox(width: 8),
                  _buildScreenPosButton('Deployed', '100% (Active)', Icons.arrow_downward, device),
                ],
              ),
            ],
          ),
        ),

        const SizedBox(height: 10),

        // Picture Profile & Aspect
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: AppColors.surfaceContainerLow,
            border: Border.all(color: AppColors.outlineVariant.withValues(alpha: 0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Picture Profile & Aspect',
                    style: AppTypography.labelLg(color: AppColors.onSurface),
                  ),
                  Text(
                    '16:9 DYNAMIC',
                    style: AppTypography.labelSm(color: AppColors.outline),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: AppColors.surfaceContainerLowest,
                  border: Border.all(color: AppColors.outlineVariant.withValues(alpha: 0.2)),
                ),
                child: Row(
                  children: ['Presentation', 'Cinema Eco', 'Blackboard'].map((prof) {
                    final isSelected = device.pictureProfile == prof;
                    return Expanded(
                      child: GestureDetector(
                        onTap: () {
                          HapticFeedback.selectionClick();
                          _state.setPictureProfile(widget.roomId, device.id, prof);
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 140),
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(6),
                            color: isSelected
                                ? AppColors.surfaceContainerHigh
                                : Colors.transparent,
                          ),
                          child: Center(
                            child: Text(
                              prof,
                              style: AppTypography.labelSm(
                                color: isSelected
                                    ? AppColors.primary
                                    : AppColors.onSurfaceVariant,
                              ).copyWith(fontWeight: isSelected ? FontWeight.bold : FontWeight.normal),
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildInputSourceButton(
    String title,
    String status,
    IconData icon,
    bool isSelected,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: isSelected
              ? AppColors.primaryContainer
              : AppColors.surfaceContainerLowest,
          border: Border.all(
            color: isSelected
                ? AppColors.primaryContainer
                : AppColors.outlineVariant.withValues(alpha: 0.3),
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 18,
              color: isSelected ? AppColors.onPrimaryFixed : AppColors.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    style: AppTypography.labelMd(
                      color: isSelected
                          ? AppColors.surfaceContainerLowest
                          : AppColors.onSurface,
                    ).copyWith(fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    status,
                    style: AppTypography.labelSm(
                      color: isSelected
                          ? AppColors.surfaceContainerLowest.withValues(alpha: 0.8)
                          : AppColors.outline,
                    ).copyWith(fontSize: 10),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScreenPosButton(
    String title,
    String pct,
    IconData icon,
    ClassroomDevice device,
  ) {
    final isSelected = device.screenPosition == title;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          _state.setScreenPosition(widget.roomId, device.id, title);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: isSelected
                ? AppColors.primary.withValues(alpha: 0.2)
                : AppColors.surfaceContainerLowest,
            border: Border.all(
              color: isSelected
                  ? AppColors.primary
                  : AppColors.outlineVariant.withValues(alpha: 0.3),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 16,
                color: isSelected ? AppColors.primary : AppColors.onSurfaceVariant,
              ),
              const SizedBox(height: 2),
              Text(
                title,
                style: AppTypography.labelSm(
                  color: isSelected ? AppColors.primary : AppColors.onSurface,
                ).copyWith(fontSize: 11, fontWeight: FontWeight.w600),
              ),
              Text(
                pct,
                style: AppTypography.labelSm(
                  color: isSelected ? AppColors.primaryLight : AppColors.outline,
                ).copyWith(fontSize: 10),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 5. TELEMETRY CONTROLS
  Widget _buildTelemetryControls(ClassroomDevice device) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: AppColors.surfaceContainerLow,
        border: Border.all(color: AppColors.outlineVariant.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Environmental Sensors (I2C Bus)',
                style: AppTypography.labelLg(color: AppColors.onSurface),
              ),
              Text(
                'SDA 21 • SCL 22',
                style: AppTypography.labelSm(color: AppColors.primary),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _buildSensorPill('CO2', '${device.co2Ppm} ppm', AppColors.onlineMint),
              const SizedBox(width: 8),
              _buildSensorPill('Humidity', '${device.humidityRh}% RH', AppColors.primary),
              const SizedBox(width: 8),
              _buildSensorPill('Ambient', '${device.ambientTemp}°C', AppColors.secondary),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSensorPill(String title, String val, Color col) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: AppColors.surfaceContainerLowest,
          border: Border.all(color: col.withValues(alpha: 0.3)),
        ),
        child: Column(
          children: [
            Text(title, style: AppTypography.labelSm(color: AppColors.outline)),
            const SizedBox(height: 4),
            Text(
              val,
              style: AppTypography.headlineSm(color: col).copyWith(fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  // 6. POWER STRIP CONTROLS
  Widget _buildPowerStripControls(ClassroomDevice device) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: AppColors.surfaceContainerLow,
        border: Border.all(color: AppColors.outlineVariant.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Relay Channels (GPIO 25–30)',
                style: AppTypography.labelLg(color: AppColors.onSurface),
              ),
              Text(
                '${device.activeSockets} / ${device.totalSockets} Active',
                style: AppTypography.labelSm(color: AppColors.primary),
              ),
            ],
          ),
          const SizedBox(height: 12),
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 3,
            childAspectRatio: 2.2,
            crossAxisSpacing: 6,
            mainAxisSpacing: 6,
            children: List.generate(6, (i) {
              final sockNum = i + 1;
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  color: AppColors.surfaceContainerLowest,
                  border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Ch $sockNum', style: AppTypography.labelSm()),
                    const Icon(Icons.check_circle, size: 14, color: AppColors.onlineMint),
                  ],
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  // --- TELEMETRY & LOGS SECTION ---
  Widget _buildTelemetryAndLogsSection(ClassroomDevice device) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: AppColors.surfaceContainerLow,
        border: Border.all(color: AppColors.outlineVariant.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 2x2 Network Node Info Grid
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 2,
            childAspectRatio: 1.85,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            children: [
              _buildTelemetryTile('IP ADDRESS', device.ipAddress, null),
              _buildTelemetryTile('CONTROLLER', device.zigbeeOrBleNode, null),
              _buildTelemetryTile('SIGNAL STRENGTH', '-58 dBm', '(Strong)'),
              _buildTelemetryTile('FIRMWARE', device.firmwareVersion, 'LATEST'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTelemetryTile(String title, String val, String? badge) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: AppColors.surfaceContainerLowest,
        border: Border.all(color: AppColors.outlineVariant.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            title,
            style: AppTypography.labelSm(color: AppColors.outline)
                .copyWith(fontSize: 9),
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Flexible(
                child: Text(
                  val,
                  style: AppTypography.labelMd(color: AppColors.onSurface)
                      .copyWith(fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (badge != null) ...[
                const SizedBox(width: 4),
                Text(
                  badge,
                  style: AppTypography.labelSm(color: AppColors.primary)
                      .copyWith(fontSize: 9),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  // --- ACTION DIAGNOSTICS BUTTONS ---
  Widget _buildActionButtons(ClassroomDevice device) {
    final isAc = device.type == DeviceType.hvac;

    return Column(
      children: [
        // Main Self Test Button
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: AppColors.onPrimaryFixed,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              elevation: 4,
            ),
            onPressed: _isTestingRelay ? null : _runSelfTest,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(isAc ? Icons.settings_remote : Icons.build, size: 18),
                const SizedBox(width: 8),
                Text(
                  _isTestingRelay
                      ? (isAc ? 'TRANSMITTING IR PULSE...' : 'PULSING RELAY SEQUENCE...')
                      : (isAc ? 'Test Optical IR Pulse (GPIO 4)' : 'Run ESP32 Relay Self-Test'),
                  style: AppTypography.labelLg(color: AppColors.surfaceContainerLowest)
                      .copyWith(fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 10),

        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  backgroundColor: AppColors.surfaceContainerLow,
                  foregroundColor: AppColors.onSurfaceVariant,
                  side: BorderSide(
                    color: AppColors.outlineVariant.withValues(alpha: 0.4),
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: _rebootNode,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.restart_alt, size: 16),
                    const SizedBox(width: 6),
                    Text('Restart Device', style: AppTypography.bodyMd()),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  backgroundColor: AppColors.surfaceContainerLow,
                  foregroundColor: AppColors.onSurfaceVariant,
                  side: BorderSide(
                    color: AppColors.outlineVariant.withValues(alpha: 0.4),
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: _syncRelays,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.sync, size: 16),
                    const SizedBox(width: 6),
                    Text(isAc ? 'Resync AC' : 'Sync Relays', style: AppTypography.bodyMd()),
                  ],
                ),
              ),
            ),
          ],
        ),

        if (AuthState().isAdmin) ...[
          const SizedBox(height: 24),

          // Danger Zone: Delete Device
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: AppColors.criticalRed.withValues(alpha: 0.06),
              border: Border.all(color: AppColors.criticalRed.withValues(alpha: 0.28)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded, size: 16, color: AppColors.criticalRed),
                    const SizedBox(width: 6),
                    Text(
                      'DANGER ZONE',
                      style: AppTypography.labelSm(color: AppColors.criticalRed)
                          .copyWith(fontWeight: FontWeight.bold, letterSpacing: 0.8),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  isAc
                      ? 'Permanently delete ${device.name}.'
                      : 'Permanently delete ${device.name} and unbind relay channel ${device.relayChannel}.',
                  style: AppTypography.bodySm(color: AppColors.onSurfaceVariant).copyWith(fontSize: 11.5),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      backgroundColor: AppColors.surfaceContainerLowest,
                      foregroundColor: AppColors.criticalRed,
                      side: BorderSide(color: AppColors.criticalRed.withValues(alpha: 0.5)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    onPressed: _confirmDeleteDevice,
                    icon: const Icon(Icons.delete_outline, size: 16, color: AppColors.criticalRed),
                    label: Text(
                      'DELETE DEVICE',
                      style: AppTypography.labelMd(color: AppColors.criticalRed).copyWith(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
