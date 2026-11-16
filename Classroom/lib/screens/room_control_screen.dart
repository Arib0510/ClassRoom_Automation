import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/classroom.dart';
import '../models/device.dart';
import '../state/auth_state.dart';
import '../state/classroom_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';
import '../widgets/cyber_slider.dart';
import '../widgets/cyber_switch.dart';
import '../widgets/fan_spinner.dart';
import '../widgets/pulsing_beacon.dart';
import '../widgets/route_transitions.dart';
import '../widgets/cyber_toast.dart';
import 'add_device_screen.dart';
import 'device_detail_screen.dart';
import '../widgets/app_sheet.dart';
import '../widgets/motion.dart';
import '../widgets/segmented_picker.dart';

class RoomControlScreen extends StatefulWidget {
  final String roomId;

  const RoomControlScreen({super.key, required this.roomId});

  @override
  State<RoomControlScreen> createState() => _RoomControlScreenState();
}

class _RoomControlScreenState extends State<RoomControlScreen> {
  final ClassroomState _state = ClassroomState();
  String _selectedCategory = 'All';
  static bool _cachedGridView = false;
  bool _isGridView = false;

  @override
  void initState() {
    super.initState();
    _isGridView = _cachedGridView;
    _loadGridPreference();
    _state.addListener(_onStateChange);
  }

  Future<void> _loadGridPreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getBool('room_control_is_grid_view');
      if (saved != null) {
        _cachedGridView = saved;
        if (mounted && _isGridView != saved) {
          setState(() => _isGridView = saved);
        }
      }
    } catch (_) {}
  }

  Future<void> _setGridView(bool isGrid) async {
    HapticFeedback.selectionClick();
    _cachedGridView = isGrid;
    setState(() => _isGridView = isGrid);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('room_control_is_grid_view', isGrid);
    } catch (_) {}
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

  // Filter ONLY Ceiling Fan, Light, and AC
  List<ClassroomDevice> _getFilteredDevicesForZone(String zoneName) {
    final room = _room;
    if (room == null) return [];

    final zoneDevices = room.devicesInZone(zoneName);

    switch (_selectedCategory) {
      case 'Ceiling Fan':
        return zoneDevices.where((d) => d.type == DeviceType.fan).toList();
      case 'Light':
        return zoneDevices.where((d) => d.type == DeviceType.lighting).toList();
      case 'AC':
        return zoneDevices.where((d) => d.type == DeviceType.hvac).toList();
      default:
        return zoneDevices.where((d) =>
            d.type == DeviceType.fan ||
            d.type == DeviceType.lighting ||
            d.type == DeviceType.hvac).toList();
    }
  }

  void _showRenameDialog() {
    final room = _room;
    if (room == null) return;

    final nameController = TextEditingController(text: room.name);
    final roomNumberController = TextEditingController(text: room.roomNumber);

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.sheet,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: AppColors.primary.withValues(alpha: 0.3)),
          ),
          title: Text(
            'Rename Classroom',
            style: AppTypography.headlineSm(color: AppColors.primary),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: roomNumberController,
                style: AppTypography.bodyMd(color: AppColors.onSurface),
                decoration: const InputDecoration(
                  labelText: 'Room Identifier',
                  hintText: 'e.g. Room 101',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: nameController,
                style: AppTypography.bodyMd(color: AppColors.onSurface),
                decoration: const InputDecoration(
                  labelText: 'Classroom Name',
                  hintText: 'e.g. Science Lab',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(
                'CANCEL',
                style: AppTypography.labelMd(color: AppColors.onSurface).copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: AppColors.onPrimaryFixed,
              ),
              onPressed: () {
                _state.renameClassroom(
                  widget.roomId,
                  nameController.text.trim(),
                  roomNumberController.text.trim(),
                );
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Classroom identifier updated successfully.'),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
              child: Text('SAVE', style: AppTypography.labelMd(color: AppColors.surfaceContainerLowest).copyWith(fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  void _showDeleteDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.sheet,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: AppColors.error.withValues(alpha: 0.4)),
          ),
          title: Row(
            children: [
              Icon(Icons.delete_forever, color: AppColors.error),
              const SizedBox(width: 8),
              Text(
                'Delete Classroom',
                style: AppTypography.headlineSm(color: AppColors.error),
              ),
            ],
          ),
          content: Text(
            'Are you sure you want to delete this classroom? All configured devices in this room will be removed.',
            style: AppTypography.bodyMd(color: AppColors.onSurfaceVariant),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('CANCEL', style: AppTypography.labelMd(color: AppColors.onSurface).copyWith(fontWeight: FontWeight.bold)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.error,
                foregroundColor: AppColors.onError,
              ),
              onPressed: () {
                _state.deleteClassroom(widget.roomId);
                Navigator.pop(context); // Close dialog
                Navigator.pop(context); // Return to Dashboard
              },
              child: Text('DELETE', style: AppTypography.labelMd()),
            ),
          ],
        );
      },
    );
  }

  void _showRenameZoneDialog(Classroom room, String zoneName) {
    final currentDisplayName = room.getZoneDisplayName(zoneName);
    final hasAlias = currentDisplayName.toLowerCase() != zoneName.toLowerCase();
    final controller = TextEditingController(text: hasAlias ? currentDisplayName : '');

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.sheet,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: AppColors.primary.withValues(alpha: 0.3)),
          ),
          title: Row(
            children: [
              Icon(Icons.drive_file_rename_outline, color: AppColors.primary, size: 20),
              const SizedBox(width: 8),
              Text(
                'Rename Zone',
                style: AppTypography.headlineSm(color: AppColors.primary),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: AppColors.surfaceContainerLowest,
                  border: Border.all(color: AppColors.overlay(0.06)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.developer_board, size: 14, color: AppColors.onlineMint),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Hardware: $zoneName (Board #${RegExp(r'\d+').firstMatch(zoneName)?.group(0) ?? "1"})',
                        style: AppTypography.labelSm(color: AppColors.onlineMint).copyWith(fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                style: AppTypography.bodyMd(color: AppColors.onSurface),
                decoration: InputDecoration(
                  labelText: 'Custom Display Name',
                  hintText: 'e.g. Front Podium, Lab Station A',
                  labelStyle: AppTypography.labelSm(color: AppColors.onSurfaceVariant),
                  hintStyle: AppTypography.bodySm(color: AppColors.outline.withValues(alpha: 0.6)),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Renaming only affects this app interface. Internal routing remains strictly isolated as $zoneName for your ESP32 switchboard.',
                style: AppTypography.bodySm(color: AppColors.outline).copyWith(fontSize: 10.5),
              ),
            ],
          ),
          actions: [
            if (hasAlias)
              TextButton(
                onPressed: () {
                  _state.renameZone(widget.roomId, zoneName, '');
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Reset $zoneName back to default.'),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                },
                child: Text(
                  'RESET TO DEFAULT',
                  style: AppTypography.labelSm(color: AppColors.telemetryAmber).copyWith(fontWeight: FontWeight.bold),
                ),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(
                'CANCEL',
                style: AppTypography.labelMd(color: AppColors.onSurface).copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: AppColors.onPrimaryFixed,
              ),
              onPressed: () {
                final newName = controller.text.trim();
                _state.renameZone(widget.roomId, zoneName, newName);
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(newName.isNotEmpty
                        ? 'Zone display name set to "$newName".'
                        : 'Zone display name reset.'),
                    duration: const Duration(seconds: 2),
                  ),
                );
              },
              child: Text('SAVE', style: AppTypography.labelMd(color: AppColors.surfaceContainerLowest).copyWith(fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  void _safeToggleDevice(ClassroomDevice device) {
    HapticFeedback.mediumImpact();
    final error = _state.toggleDevice(widget.roomId, device.id);
    if (error != null && mounted) {
      CyberToast.show(context, message: error, type: ToastType.error);
    }
  }

  void _safeToggleZone(String zoneName) {
    HapticFeedback.mediumImpact();
    final error = _state.toggleZone(widget.roomId, zoneName);
    if (error != null && mounted) {
      CyberToast.show(context, message: error, type: ToastType.error);
    }
  }

  void _showDeleteZoneDialog(Classroom room, String zoneName) {
    HapticFeedback.lightImpact();
    final displayName = room.getZoneDisplayName(zoneName);
    final count = room.devicesInZone(zoneName).length;

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: AppColors.sheet,
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
                child: Icon(Icons.delete_sweep, color: AppColors.criticalRed, size: 22),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Delete Zone?',
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
                'Are you sure you want to delete "$displayName" ($zoneName) from ${room.roomNumber}?',
                style: AppTypography.bodyMd(color: AppColors.onSurface),
              ),
              if (count > 0) ...[
                const SizedBox(height: 10),
                Text(
                  'This will also remove all $count devices assigned to this zone.',
                  style: AppTypography.bodySm(color: AppColors.criticalRed).copyWith(fontSize: 11.5),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('CANCEL', style: AppTypography.labelMd(color: AppColors.onSurface).copyWith(fontWeight: FontWeight.bold)),
            ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.criticalRed,
                foregroundColor: AppColors.onError,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () {
                Navigator.pop(ctx);
                _state.deleteZone(widget.roomId, zoneName);
                CyberToast.show(
                  context,
                  message: 'Zone "$displayName" removed.',
                  type: ToastType.success,
                );
              },
              icon: const Icon(Icons.delete, size: 16),
              label: Text('DELETE', style: AppTypography.labelMd(color: AppColors.onError)),
            ),
          ],
        );
      },
    );
  }

  String _normalizeRoomType(String roomType) {
    final t = roomType.trim();
    if (t.isEmpty) return 'Standard Class';
    final lower = t.toLowerCase();
    if (lower.contains('standard')) return 'Standard Class';
    if (lower.contains('lab')) return 'Laboratory';
    if (lower.contains('seminar')) return 'Seminar Room';
    if (lower.contains('lecture')) return 'Lecture Hall';
    if (lower.contains('auditorium')) return 'Auditorium';
    if (lower.contains('class')) return 'Standard Class';
    return t;
  }

  IconData _getRoomTypeIcon(String roomType) {
    final lower = roomType.toLowerCase();
    if (lower.contains('lab')) return Icons.science;
    if (lower.contains('seminar')) return Icons.groups;
    if (lower.contains('lecture')) return Icons.co_present;
    if (lower.contains('auditorium')) return Icons.theater_comedy;
    return Icons.school;
  }

  String _getRoomHeaderTitle(Classroom room) {
    final name = room.name.trim();
    final num = room.roomNumber.trim();
    final type = _normalizeRoomType(room.roomType);
    if (name.isNotEmpty &&
        name.toLowerCase() != 'classroom' &&
        name.toLowerCase() != 'standard class' &&
        name.toLowerCase() != num.toLowerCase() &&
        name.toLowerCase() != type.toLowerCase()) {
      return '$num · $name';
    }
    return num;
  }


  void _showRoomHardwareInfo(Classroom room) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return AppSheet(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.memory_rounded, color: AppColors.primary, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Hardware details',
                      style: AppTypography.headlineSm(color: AppColors.onSurface)
                          .copyWith(fontSize: 17, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Use this ID when flashing the ESP32 firmware for this room.',
                style: AppTypography.bodySm(color: AppColors.onSurfaceVariant)
                    .copyWith(fontSize: 13),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.fromLTRB(14, 6, 6, 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: AppColors.surfaceContainerLowest,
                  border: Border.all(color: AppColors.overlay(0.08)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Room ID',
                                style: AppTypography.labelSm(
                                  color: AppColors.outline,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                room.id,
                                style: AppTypography.labelLg(
                                  color: AppColors.primary,
                                ).copyWith(fontSize: 15),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Copy room ID',
                          icon: Icon(Icons.copy_rounded,
                              size: 18, color: AppColors.primary),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: room.id));
                            CyberToast.show(
                              ctx,
                              message: 'Copied "${room.id}".',
                              type: ToastType.success,
                            );
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '#define CLASSROOM_ID "${room.id}"',
                      style: AppTypography.bodySm(color: AppColors.onSurfaceVariant)
                          .copyWith(fontSize: 12.5),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '${room.zoneCount} zones · ${room.devices.length} devices',
                      style: AppTypography.bodySm(color: AppColors.outline)
                          .copyWith(fontSize: 12.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final room = _room;
    if (room == null) {
      return Scaffold(
        backgroundColor: AppColors.surfaceContainerLowest,
        appBar: AppBar(),
        body: Center(
          child: Text('This classroom no longer exists.',
              style: AppTypography.bodyLg()),
        ),
      );
    }

    final typeColor = AppColors.roomType(room.roomType);
    final activeCount = room.activeDeviceCount;
    final zones =
        room.zones.where((z) => !z.toLowerCase().contains('ac')).toList();
    final hasAc = room.devices
        .any((d) => d.type == DeviceType.hvac || d.zone == 'Standalone AC');

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
        title: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: typeColor.withValues(alpha: 0.14),
              ),
              child: Icon(_getRoomTypeIcon(room.roomType),
                  size: 20, color: typeColor),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _getRoomHeaderTitle(room),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.headlineSm(color: AppColors.onSurface)
                        .copyWith(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    '$activeCount on · ${_normalizeRoomType(room.roomType)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.bodySm(
                      color: activeCount > 0
                          ? AppColors.primary
                          : AppColors.outline,
                    ).copyWith(fontSize: 12, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Hardware details',
            icon: Icon(Icons.memory_rounded,
                size: 22, color: AppColors.onSurfaceVariant),
            onPressed: () => _showRoomHardwareInfo(room),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 14, left: 2),
            child: Center(
              child: PowerButton(
                isOn: room.isMasterOn,
                size: 38,
                radius: 12,
                semanticLabel: 'Power for the whole room',
                onTap: () {
                  HapticFeedback.mediumImpact();
                  _state.toggleRoomMaster(room.id);
                },
              ),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildVisionTelemetryBanner(room),

            if (AuthState().isAdmin) ...[
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 44,
                      child: ElevatedButton.icon(
                        onPressed: () {
                          Navigator.push(
                            context,
                            Cube3DPageRoute(
                              page:
                                  AddDeviceScreen(preselectedRoomId: room.id),
                            ),
                          );
                        },
                        icon: const Icon(Icons.add_rounded, size: 19),
                        label: const Text('Add Device', maxLines: 1),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _squareAction(
                    icon: Icons.edit_outlined,
                    color: AppColors.secondary,
                    tooltip: 'Rename classroom',
                    onTap: _showRenameDialog,
                  ),
                  const SizedBox(width: 8),
                  _squareAction(
                    icon: Icons.delete_outline_rounded,
                    color: AppColors.error,
                    tooltip: 'Delete classroom',
                    onTap: _showDeleteDialog,
                  ),
                ],
              ),
              const SizedBox(height: 14),
            ],

            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              child: Row(
                children: [
                  _buildCategoryChip('All'),
                  _buildCategoryChip('Ceiling Fan'),
                  _buildCategoryChip('Light'),
                  _buildCategoryChip('AC'),
                ],
              ),
            ),

            const SizedBox(height: 18),

            // Choosing "AC" shows only the standalone AC panel; the zone
            // switchboards carry no AC units.
            if (_selectedCategory == 'AC') ...[
              _buildStandaloneAcSection(room),
            ] else ...[
              if (_selectedCategory == 'All' && hasAc)
                _buildStandaloneAcSection(room),

              Row(
                children: [
                  Text(
                    'Zones',
                    style:
                        AppTypography.headlineSm(color: AppColors.onSurface)
                            .copyWith(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 8),
                  StatusChip(
                    label: '${room.zoneCount}',
                    color: AppColors.primary,
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildViewModeToggle(
                            Icons.view_agenda_outlined, false, 'List view'),
                        _buildViewModeToggle(
                            Icons.grid_view_rounded, true, 'Grid view'),
                      ],
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              if (room.zones.isEmpty)
                _buildEmptyDevicesState(room)
              else
                for (var i = 0; i < zones.length; i++)
                  _buildZoneCard(room, zones[i]),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStandaloneAcSection(Classroom room) {
    final acDevices = room.devices
        .where((d) => d.type == DeviceType.hvac || d.zone == 'Standalone AC')
        .toList();
    final anyOn = acDevices.any((d) => d.isOn);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 260),
      margin: const EdgeInsets.only(bottom: 20),
      decoration: _panelDecoration(
        borderColor:
            anyOn ? AppColors.secondary.withValues(alpha: 0.40) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
            child: Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 240),
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: anyOn
                        ? AppColors.secondary
                        : AppColors.secondary.withValues(alpha: 0.14),
                  ),
                  child: Icon(
                    Icons.ac_unit_rounded,
                    size: 20,
                    color: anyOn ? Colors.white : AppColors.secondary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Air conditioning',
                        style: AppTypography.headlineSm(
                          color: AppColors.onSurface,
                        ).copyWith(fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        'Standalone IR controller · zone_ac',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.bodySm(color: AppColors.outline)
                            .copyWith(fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: acDevices.isEmpty
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(2, 0, 2, 10),
                    child: Text(
                      'No AC paired yet. Tap "Add Device" and choose Standalone AC.',
                      style: AppTypography.bodySm(
                        color: AppColors.onSurfaceVariant,
                      ).copyWith(fontSize: 13),
                    ),
                  )
                : Column(
                    children:
                        acDevices.map((dev) => _buildDeviceCard(dev)).toList(),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildViewModeToggle(IconData icon, bool isGrid, String tooltip) {
    final isSelected = _isGridView == isGrid;
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _setGridView(isGrid),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 38,
          height: 30,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: isSelected ? AppColors.primary : Colors.transparent,
          ),
          child: Icon(
            icon,
            size: 17,
            color: isSelected ? AppColors.onPrimary : AppColors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _buildZoneCard(Classroom room, String zoneName) {
    final filteredDevices = _getFilteredDevicesForZone(zoneName);
    final totalInZone = room.devicesInZone(zoneName).length;
    final activeInZone = room.activeDevicesInZone(zoneName);
    final isZoneActive = room.isZoneActive(zoneName);
    final displayName = room.getZoneDisplayName(zoneName);
    final hasAlias = displayName.toLowerCase() != zoneName.toLowerCase();

    return AnimatedContainer(
      duration: const Duration(milliseconds: 260),
      margin: const EdgeInsets.only(bottom: 16),
      decoration: _panelDecoration(
        borderColor:
            isZoneActive ? AppColors.primary.withValues(alpha: 0.38) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 10),
            child: Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 240),
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: isZoneActive
                        ? AppColors.primary
                        : AppColors.surfaceContainerHigh,
                  ),
                  child: Icon(
                    Icons.grid_view_rounded,
                    size: 19,
                    color: isZoneActive
                        ? AppColors.onPrimary
                        : AppColors.outline,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.headlineSm(
                          color: AppColors.onSurface,
                        ).copyWith(fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        hasAlias
                            ? '$zoneName · $activeInZone of $totalInZone on'
                            : '$activeInZone of $totalInZone on',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.bodySm(
                          color: isZoneActive
                              ? AppColors.primary
                              : AppColors.outline,
                        ).copyWith(fontSize: 12, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                ),
                if (AuthState().isAdmin) ...[
                  IconButton(
                    tooltip: 'Add device to $zoneName',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.add_circle_outline_rounded,
                        size: 19, color: AppColors.primary),
                    onPressed: () {
                      Navigator.push(
                        context,
                        Cube3DPageRoute(
                          page: AddDeviceScreen(
                            preselectedRoomId: room.id,
                            preselectedZone: zoneName,
                          ),
                        ),
                      );
                    },
                  ),
                  IconButton(
                    tooltip: 'Rename zone',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.edit_outlined,
                        size: 18, color: AppColors.onSurfaceVariant),
                    onPressed: () => _showRenameZoneDialog(room, zoneName),
                  ),
                  IconButton(
                    tooltip: 'Delete zone',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.delete_outline_rounded,
                        size: 18, color: AppColors.criticalRed),
                    onPressed: () => _showDeleteZoneDialog(room, zoneName),
                  ),
                ] else
                  IconButton(
                    tooltip: 'Rename zone',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.edit_outlined,
                        size: 18, color: AppColors.onSurfaceVariant),
                    onPressed: () => _showRenameZoneDialog(room, zoneName),
                  ),
                const SizedBox(width: 4),
                CyberSwitch(
                  value: isZoneActive,
                  onChanged: (val) => _safeToggleZone(zoneName),
                ),
              ],
            ),
          ),
          Divider(color: AppColors.overlay(0.07), height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: filteredDevices.isEmpty
                ? Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _buildEmptyZoneState(room, zoneName, totalInZone),
                  )
                : AnimatedSwitcher(
                    duration: const Duration(milliseconds: 240),
                    child: _isGridView
                        ? Padding(
                            key: const ValueKey('grid'),
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _buildZoneGridView(filteredDevices),
                          )
                        : KeyedSubtree(
                            key: const ValueKey('list'),
                            child:
                                _buildZoneCategorizedListView(filteredDevices),
                          ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyZoneState(Classroom room, String zoneName, int totalInZone) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: AppColors.surfaceContainerLowest,
        border: Border.all(color: AppColors.overlay(0.05)),
      ),
      child: Column(
        children: [
          Text(
            totalInZone == 0
                ? 'No devices assigned to $zoneName.'
                : 'No devices match "$_selectedCategory" in $zoneName.',
            style: AppTypography.bodySm(color: AppColors.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
          if (AuthState().isAdmin) ...[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: AppColors.primary.withValues(alpha: 0.4)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              ),
              onPressed: () {
                Navigator.push(
                  context,
                  Cube3DPageRoute(
                    page: AddDeviceScreen(preselectedRoomId: room.id),
                  ),
                );
              },
              icon: Icon(Icons.add, size: 14, color: AppColors.primary),
              label: Text(
                'Add Device to $zoneName',
                style: AppTypography.labelSm(color: AppColors.primary),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildZoneCategorizedListView(List<ClassroomDevice> devices) {
    if (_selectedCategory != 'All') {
      return Column(
        children: devices.map((dev) => _buildDeviceCard(dev)).toList(),
      );
    }

    final lights = devices.where((d) => d.type == DeviceType.lighting).toList();
    final fans = devices.where((d) => d.type == DeviceType.fan).toList();
    final acs = devices.where((d) => d.type == DeviceType.hvac).toList();
    final others = devices.where((d) =>
        d.type != DeviceType.lighting &&
        d.type != DeviceType.fan &&
        d.type != DeviceType.hvac).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (lights.isNotEmpty) ...[
          _buildDeviceGroupHeader('Lights', Icons.lightbulb_outline, lights),
          ...lights.map((dev) => _buildDeviceCard(dev)),
        ],
        if (fans.isNotEmpty) ...[
          _buildDeviceGroupHeader('Ceiling Fans', Icons.mode_fan_off_outlined, fans),
          ...fans.map((dev) => _buildDeviceCard(dev)),
        ],
        if (acs.isNotEmpty) ...[
          _buildDeviceGroupHeader('Air Conditioning', Icons.ac_unit, acs),
          ...acs.map((dev) => _buildDeviceCard(dev)),
        ],
        if (others.isNotEmpty) ...[
          _buildDeviceGroupHeader('Other Devices', Icons.devices, others),
          ...others.map((dev) => _buildDeviceCard(dev)),
        ],
      ],
    );
  }

  Widget _buildZoneGridView(List<ClassroomDevice> devices) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final itemWidth = (constraints.maxWidth - 8) / 2;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: devices.map((dev) {
            return SizedBox(
              width: itemWidth,
              child: _buildDeviceGridTile(dev),
            );
          }).toList(),
        );
      },
    );
  }

  Widget _buildDeviceGroupHeader(
      String title, IconData icon, List<ClassroomDevice> devices) {
    final activeCount = devices.where((d) => d.isOn).length;
    final totalCount = devices.length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 2, 2, 8),
      child: Row(
        children: [
          Icon(icon,
              size: 15,
              color: activeCount > 0 ? AppColors.primary : AppColors.outline),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.labelMd(
                color: AppColors.onSurfaceVariant,
              ).copyWith(fontSize: 12.5),
            ),
          ),
          Text(
            '$activeCount of $totalCount on',
            style: AppTypography.labelSm(
              color: activeCount > 0 ? AppColors.primary : AppColors.outline,
            ).copyWith(fontSize: 11.5, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  BoxDecoration _deviceTileDecoration({required bool isOn, bool isAc = false}) {
    final accent = isAc ? AppColors.secondary : AppColors.primary;
    return BoxDecoration(
      borderRadius: BorderRadius.circular(14),
      color: isOn
          ? Color.alphaBlend(
              accent.withValues(alpha: AppColors.isDark ? 0.14 : 0.12),
              AppColors.surfaceContainerLow,
            )
          : AppColors.surfaceContainerLowest,
      border: Border.all(
        color: isOn
            ? accent.withValues(alpha: AppColors.isDark ? 0.52 : 0.72)
            : AppColors.overlay(AppColors.isDark ? 0.08 : 0.11),
        width: isOn ? 1.5 : 1.0,
      ),
      boxShadow: isOn
          ? [
              BoxShadow(
                color: accent.withValues(alpha: AppColors.isDark ? 0.22 : 0.16),
                blurRadius: 10,
                spreadRadius: -2,
                offset: const Offset(0, 3),
              ),
            ]
          : null,
    );
  }

  Widget _buildDeviceGridTile(ClassroomDevice device) {
    final isOn = device.isOn;
    final isAc = device.type == DeviceType.hvac;
    final accent = isAc ? AppColors.secondary : AppColors.primary;
    return RepaintBoundary(
      key: ValueKey('grid_${device.id}'),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 240),
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
        decoration: _deviceTileDecoration(isOn: isOn, isAc: isAc),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                GestureDetector(
                  onTap: () => _safeToggleDevice(device),
                  child: _buildDeviceIconBox(device, size: 36),
                ),
                CyberSwitch(
                  value: isOn,
                  onChanged: (val) => _safeToggleDevice(device),
                ),
              ],
            ),
            const SizedBox(height: 10),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _openDeviceDetail(device),
              onLongPress: AuthState().isAdmin
                  ? () => _confirmDeleteDevice(device)
                  : null,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _deviceLabel(device),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.bodyMd(color: AppColors.onSurface)
                        .copyWith(fontSize: 13.5, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _deviceStatusText(device),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.bodySm(
                            color: isOn ? accent : AppColors.outline,
                          ).copyWith(
                            fontSize: 12,
                            fontWeight:
                                isOn ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                      ),
                      Icon(Icons.tune_rounded,
                          size: 14, color: AppColors.outline),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryChip(String title) {
    final isSelected = _selectedCategory == title;
    final fg = isSelected ? AppColors.onPrimary : AppColors.onSurfaceVariant;
    final IconData icon;
    switch (title) {
      case 'Ceiling Fan':
        icon = Icons.mode_fan_off_outlined;
        break;
      case 'Light':
        icon = Icons.lightbulb_outline_rounded;
        break;
      case 'AC':
        icon = Icons.ac_unit_rounded;
        break;
      default:
        icon = Icons.apps_rounded;
    }

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: PressScale(
        onTap: () {
          HapticFeedback.selectionClick();
          setState(() => _selectedCategory = title);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            color:
                isSelected ? AppColors.primary : AppColors.surfaceContainerLow,
            border: Border.all(
              color: isSelected ? AppColors.primary : AppColors.overlay(0.10),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: fg),
              const SizedBox(width: 6),
              Text(
                _categoryLabel(title),
                style: AppTypography.labelMd(color: fg).copyWith(
                  fontSize: 12.5,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openDeviceDetail(ClassroomDevice device) {
    HapticFeedback.selectionClick();
    Navigator.push(
      context,
      Cube3DPageRoute(
        page: DeviceDetailScreen(
          roomId: widget.roomId,
          deviceId: device.id,
        ),
      ),
    );
  }

  void _confirmDeleteDevice(ClassroomDevice device) {
    HapticFeedback.lightImpact();
    final room = _room;
    if (room == null) return;

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: AppColors.sheet,
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
                child: Icon(Icons.delete_forever, color: AppColors.criticalRed, size: 22),
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
                'Are you sure you want to delete "${device.name}" from ${room.name}?',
                style: AppTypography.bodyMd(color: AppColors.onSurface),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: AppColors.surfaceContainerLowest,
                  border: Border.all(color: AppColors.overlay(0.08)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.type == DeviceType.hvac
                          ? '• Controller: Optical IR Transmitter'
                          : '• Relay Mapping: ${device.relayChannel}',
                      style: AppTypography.bodySm(color: AppColors.onSurfaceVariant).copyWith(fontSize: 11),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '• Switchboard: ${device.zigbeeOrBleNode}',
                      style: AppTypography.bodySm(color: AppColors.onSurfaceVariant).copyWith(fontSize: 11),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '• Zone: ${device.zone}',
                      style: AppTypography.bodySm(color: AppColors.onSurfaceVariant).copyWith(fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'This will detach relay controls and permanently remove this peripheral.',
                style: AppTypography.bodySm(color: AppColors.outline).copyWith(fontSize: 11),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('CANCEL', style: AppTypography.labelMd(color: AppColors.onSurface).copyWith(fontWeight: FontWeight.bold)),
            ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.criticalRed,
                foregroundColor: AppColors.onError,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () {
                Navigator.pop(ctx);
                _state.deleteDevice(widget.roomId, device.id);
                CyberToast.show(
                  context,
                  message: '${device.name} successfully deleted.',
                  type: ToastType.success,
                );
              },
              icon: const Icon(Icons.delete, size: 16),
              label: Text('DELETE', style: AppTypography.labelMd(color: AppColors.onError)),
            ),
          ],
        );
      },
    );
  }

  Widget _buildEmptyDevicesState(Classroom room) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: AppColors.surfaceContainer,
        border: Border.all(
          color: AppColors.overlay(0.08),
        ),
      ),
      child: Column(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.surfaceContainerHigh,
              border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
            ),
            child: Icon(
              Icons.electrical_services,
              size: 24,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'No Devices Configured',
            style: AppTypography.headlineSm(color: AppColors.onSurface)
                .copyWith(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            'Tap below to add Ceiling Fans, Lights, or AC units to this classroom.',
            textAlign: TextAlign.center,
            style: AppTypography.bodySm(color: AppColors.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: AppColors.surfaceContainerLowest,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: () {
              Navigator.push(
                context,
                Cube3DPageRoute(
                  page: AddDeviceScreen(preselectedRoomId: room.id),
                ),
              );
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.add, size: 16),
                const SizedBox(width: 6),
                Text(
                  'Add First Device',
                  style: AppTypography.labelLg(color: AppColors.surfaceContainerLowest)
                      .copyWith(fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceCard(ClassroomDevice device) {
    final isOn = device.isOn;
    final isAc = device.type == DeviceType.hvac;
    final accent = isAc ? AppColors.secondary : AppColors.primary;

    return RepaintBoundary(
      key: ValueKey('card_${device.id}'),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 240),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
        decoration: _deviceTileDecoration(isOn: isOn, isAc: isAc),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _safeToggleDevice(device),
                  child: _buildDeviceIconBox(device),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _openDeviceDetail(device),
                    onLongPress: AuthState().isAdmin
                        ? () => _confirmDeleteDevice(device)
                        : null,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _deviceLabel(device),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.bodyMd(
                            color: AppColors.onSurface,
                          ).copyWith(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          device.type == DeviceType.hvac && !isOn
                              ? 'Off · IR GPIO ${device.gpioPinNumber}'
                              : _deviceStatusText(device),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.bodySm(
                            color: isOn ? accent : AppColors.outline,
                          ).copyWith(
                            fontSize: 12,
                            fontWeight:
                                isOn ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'More',
                  padding: EdgeInsets.zero,
                  icon: Icon(Icons.more_vert_rounded,
                      size: 20, color: AppColors.outline),
                  onSelected: (val) {
                    if (val == 'settings') _openDeviceDetail(device);
                    if (val == 'delete') _confirmDeleteDevice(device);
                  },
                  itemBuilder: (ctx) => [
                    PopupMenuItem(
                      value: 'settings',
                      child: Row(
                        children: [
                          Icon(Icons.tune_rounded,
                              size: 18, color: AppColors.primary),
                          const SizedBox(width: 12),
                          const Text('Details & settings'),
                        ],
                      ),
                    ),
                    if (AuthState().isAdmin) ...[
                      const PopupMenuDivider(),
                      PopupMenuItem(
                        value: 'delete',
                        child: Row(
                          children: [
                            Icon(Icons.delete_outline_rounded,
                                size: 18, color: AppColors.criticalRed),
                            const SizedBox(width: 12),
                            Text(
                              'Delete device',
                              style: TextStyle(color: AppColors.criticalRed),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
                CyberSwitch(
                  value: isOn,
                  onChanged: (val) => _safeToggleDevice(device),
                ),
              ],
            ),

            // Inline controls appear only while the device is on.
            AnimatedSize(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: !isOn
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: _buildInlineControls(device),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceIconBox(ClassroomDevice device, {double size = 40}) {
    final isOn = device.isOn;
    final isAc = device.type == DeviceType.hvac;
    final accent = isAc ? AppColors.secondary : AppColors.primary;
    Widget iconWidget;
    final iconSize = size * 0.52;

    if (device.type == DeviceType.fan) {
      iconWidget = FanSpinner(
        isSpinning: isOn,
        speed: device.fanSpeed,
        reverse: device.fanReverse,
        size: iconSize,
        color: isOn ? AppColors.onPrimary : AppColors.outline,
      );
    } else {
      IconData iconData;
      switch (device.type) {
        case DeviceType.hvac:
          iconData = Icons.ac_unit_rounded;
          break;
        case DeviceType.lighting:
          iconData = isOn ? Icons.lightbulb_rounded : Icons.lightbulb_outline_rounded;
          break;
        default:
          iconData = Icons.developer_board;
      }

      iconWidget = Icon(
        iconData,
        size: iconSize,
        color: isOn ? AppColors.onPrimary : AppColors.outline,
      );
    }

    // A lit tile glows cleanly when energized in both Light & Dark themes.
    final glow = !isOn
        ? 0.0
        : (device.type == DeviceType.lighting
            ? (device.brightness / 100).clamp(0.45, 1.0)
            : 0.75);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 240),
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.3),
        color: isOn ? accent : AppColors.surfaceContainerHigh,
        boxShadow: isOn
            ? [
                BoxShadow(
                  color: accent.withValues(alpha: 0.35 * glow),
                  blurRadius: 10 * glow + 2,
                  offset: const Offset(0, 2),
                ),
              ]
            : null,
      ),
      child: Center(child: iconWidget),
    );
  }

  Widget _buildVisionTelemetryBanner(Classroom room) {
    final bool visionEnabled = _state.visionControlEnabled;
    final bool isOffline = room.visionMode == 'OFFLINE';
    final bool isOcc = room.isOccupied || room.currentOccupancy > 0;
    final int total = room.currentOccupancy;
    final int moving = room.movingOccupancy;
    final int seated = room.stationaryOccupancy > 0
        ? room.stationaryOccupancy
        : (total - moving > 0 ? total - moving : 0);
    final bool isLive =
        room.visionMode == 'LIVE_APPLIANCE' || room.visionMode == 'AUTO' || room.visionMode == 'LIVE';

    final Color accent = !visionEnabled
        ? AppColors.primary
        : (isOffline
            ? AppColors.outline
            : (isOcc ? AppColors.primary : AppColors.onSurfaceVariant));

    final String headline;
    final String detail;
    if (!visionEnabled) {
      headline = 'Direct App Control';
      detail = 'Vision auto-control disabled · Turn devices ON/OFF freely from app.';
    } else if (isOffline) {
      headline = 'Camera offline';
      detail = 'Occupancy automation paused. Turn off Vision Control for manual override.';
    } else if (isOcc) {
      headline = total == 1 ? '1 person in the room' : '$total people in the room';
      detail =
          'Front ${room.frontOccupancy} · Back ${room.backOccupancy} · $moving moving · $seated seated';
    } else {
      headline = 'Room is empty';
      detail = 'Vision Gate active · Turn off Vision Control to switch devices directly.';
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 240),
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        color: (!visionEnabled || (isOcc && !isOffline))
            ? Color.alphaBlend(
                accent.withValues(alpha: AppColors.isDark ? 0.10 : 0.08),
                AppColors.surfaceContainerLow,
              )
            : AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: (!visionEnabled || (isOcc && !isOffline))
              ? accent.withValues(alpha: 0.40)
              : AppColors.overlay(0.08),
          width: !visionEnabled ? 1.3 : 1.0,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 240),
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: !visionEnabled
                  ? AppColors.primary
                  : accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              !visionEnabled
                  ? Icons.touch_app_rounded
                  : (isOffline
                      ? Icons.videocam_off_outlined
                      : (isOcc ? Icons.groups_rounded : Icons.event_seat_outlined)),
              size: 20,
              color: !visionEnabled ? AppColors.onPrimary : accent,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        headline,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.bodyMd(color: AppColors.onSurface)
                            .copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (!visionEnabled)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          color: AppColors.primary.withValues(alpha: 0.16),
                        ),
                        child: Text(
                          'MANUAL',
                          style: AppTypography.labelSm(color: AppColors.primary)
                              .copyWith(fontSize: 9.5, fontWeight: FontWeight.bold),
                        ),
                      )
                    else if (!isOffline) ...[
                      PulsingBeacon(
                        size: 6,
                        color: isLive
                            ? AppColors.onlineMint
                            : AppColors.telemetryAmber,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        isLive ? 'Live' : room.visionMode,
                        style: AppTypography.labelSm(
                          color: isLive
                              ? AppColors.onlineMint
                              : AppColors.telemetryAmber,
                        ).copyWith(fontSize: 11),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: AppTypography.bodySm(color: AppColors.onSurfaceVariant)
                      .copyWith(fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                'Vision',
                style: AppTypography.labelSm(
                  color: visionEnabled ? AppColors.primary : AppColors.outline,
                ).copyWith(fontSize: 10.5, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              CyberSwitch(
                width: 44,
                height: 24,
                value: visionEnabled,
                onChanged: (val) async {
                  HapticFeedback.mediumImpact();
                  await _state.setVisionControlEnabled(val);
                  if (!mounted) return;
                  CyberToast.show(
                    context,
                    message: val
                        ? 'Vision auto control enabled.'
                        : 'Vision control disabled · Direct app control active.',
                    type: ToastType.info,
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Device names usually repeat their zone ("Zone 1 Front Light 1"). Inside
  /// a zone card that prefix is noise and pushes the useful part off-screen.
  String _deviceLabel(ClassroomDevice device) {
    final short = device.name
        .replaceFirst(RegExp(r'^Zone\s*\d+\s+', caseSensitive: false), '')
        .trim();
    return short.isEmpty ? device.name : short;
  }

  String _categoryLabel(String category) {
    switch (category) {
      case 'Ceiling Fan':
        return 'Fans';
      case 'Light':
        return 'Lights';
      default:
        return category;
    }
  }

  Widget _squareAction({
    required IconData icon,
    required Color color,
    required String tooltip,
    required VoidCallback onTap,
    double size = 44,
    double iconSize = 20,
  }) {
    return Tooltip(
      message: tooltip,
      child: PressScale(
        onTap: onTap,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(size * 0.3),
            color: color.withValues(alpha: 0.10),
            border: Border.all(color: color.withValues(alpha: 0.22)),
          ),
          child: Icon(icon, size: iconSize, color: color),
        ),
      ),
    );
  }

  BoxDecoration _panelDecoration({Color? borderColor}) {
    return BoxDecoration(
      borderRadius: BorderRadius.circular(18),
      color: AppColors.surfaceContainerLow,
      border: Border.all(color: borderColor ?? AppColors.overlay(0.08)),
      boxShadow: AppColors.cardShadow(strength: 0.7),
    );
  }

  String _deviceStatusText(ClassroomDevice device) {
    if (!device.isOn) return 'Off';
    switch (device.type) {
      case DeviceType.fan:
        return 'Speed ${device.fanSpeed}';
      case DeviceType.lighting:
        return '${device.brightness.round()}% brightness';
      case DeviceType.hvac:
        final mode = device.hvacMode;
        final pretty = mode.isEmpty
            ? ''
            : ' · ${mode[0].toUpperCase()}${mode.substring(1).toLowerCase()}';
        return '${device.temperature}°C$pretty';
      default:
        return 'On';
    }
  }

  Widget _controlLabel(String text) {
    return SizedBox(
      width: 46,
      child: Text(
        text,
        style: AppTypography.labelSm(color: AppColors.onSurfaceVariant)
            .copyWith(fontSize: 12, fontWeight: FontWeight.w500),
      ),
    );
  }

  Widget _buildInlineControls(ClassroomDevice device) {
    if (device.type == DeviceType.fan) {
      return Row(
        children: [
          _controlLabel('Speed'),
          Expanded(
            child: SegmentedPicker<int>(
              values: const [1, 2, 3, 4, 5],
              selected: device.fanSpeed,
              labelOf: (v) => '$v',
              onChanged: (v) =>
                  _state.setFanSpeed(widget.roomId, device.id, v),
            ),
          ),
        ],
      );
    }

    if (device.type == DeviceType.lighting) {
      return CyberSlider(
        value: device.brightness,
        label: 'Level',
        unit: '%',
        maxMetric: 100,
        onChanged: (val) {
          _state.setBrightness(widget.roomId, device.id, val);
        },
      );
    }

    if (device.type == DeviceType.hvac) {
      Widget stepButton(IconData icon, int delta, String tooltip) {
        return Tooltip(
          message: tooltip,
          child: PressScale(
            pressedScale: 0.88,
            onTap: () {
              HapticFeedback.selectionClick();
              _state.setTemperature(widget.roomId, device.id, delta);
            },
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(11),
                color: AppColors.surfaceContainerHigh,
              ),
              child: Icon(icon, size: 18, color: AppColors.onSurface),
            ),
          ),
        );
      }

      return Column(
        children: [
          Row(
            children: [
              stepButton(Icons.remove_rounded, -1, 'Cooler'),
              SizedBox(
                width: 64,
                child: Center(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    transitionBuilder: (child, anim) => FadeTransition(
                      opacity: anim,
                      child: ScaleTransition(
                        scale:
                            Tween<double>(begin: 0.85, end: 1).animate(anim),
                        child: child,
                      ),
                    ),
                    child: Text(
                      '${device.temperature}°C',
                      key: ValueKey(device.temperature),
                      style: AppTypography.headlineSm(color: AppColors.primary)
                          .copyWith(fontSize: 19, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ),
              stepButton(Icons.add_rounded, 1, 'Warmer'),
              const SizedBox(width: 8),
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: PressScale(
                onTap: () {
                  HapticFeedback.selectionClick();
                  _state.toggleAcSwing(widget.roomId, device.id);
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  height: 36,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(11),
                    color: device.acSwing
                        ? AppColors.onlineMint.withValues(alpha: 0.14)
                        : AppColors.surfaceContainerHigh,
                    border: Border.all(
                      color: device.acSwing
                          ? AppColors.onlineMint.withValues(alpha: 0.45)
                          : Colors.transparent,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.swap_vert_rounded,
                        size: 16,
                        color: device.acSwing
                            ? AppColors.onlineMint
                            : AppColors.onSurfaceVariant,
                      ),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          device.acSwing ? 'Swing on' : 'Swing off',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.labelSm(
                            color: device.acSwing
                                ? AppColors.onlineMint
                                : AppColors.onSurfaceVariant,
                          ).copyWith(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _controlLabel('Mode'),
              Expanded(
                child: SegmentedPicker<String>(
                  values: const ['AUTO', 'COOL', 'DRY', 'FAN', 'HEAT'],
                  selected: device.hvacMode,
                  labelOf: (m) => m[0] + m.substring(1).toLowerCase(),
                  onChanged: (m) =>
                      _state.setHvacMode(widget.roomId, device.id, m),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _controlLabel('Fan'),
              Expanded(
                child: SegmentedPicker<int>(
                  values: const [0, 1, 2, 3],
                  selected: device.fanSpeed.clamp(0, 3),
                  labelOf: (v) => v == 0 ? 'Auto' : '$v',
                  accent: AppColors.onlineMint,
                  onChanged: (v) =>
                      _state.setAcFanSpeed(widget.roomId, device.id, v),
                ),
              ),
            ],
          ),
        ],
      );
    }

    return const SizedBox.shrink();
  }
}
