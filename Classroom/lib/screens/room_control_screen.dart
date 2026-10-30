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
          backgroundColor: AppColors.surfaceContainerHigh,
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
                style: AppTypography.labelMd(color: AppColors.outline),
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
              child: Text('SAVE', style: AppTypography.labelMd()),
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
          backgroundColor: AppColors.surfaceContainerHigh,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: AppColors.error.withValues(alpha: 0.4)),
          ),
          title: Row(
            children: [
              const Icon(Icons.delete_forever, color: AppColors.error),
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
              child: Text('CANCEL', style: AppTypography.labelMd()),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.error,
                foregroundColor: Colors.white,
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
          backgroundColor: AppColors.surfaceContainerHigh,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: AppColors.primary.withValues(alpha: 0.3)),
          ),
          title: Row(
            children: [
              const Icon(Icons.drive_file_rename_outline, color: AppColors.primary, size: 20),
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
                  border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.developer_board, size: 14, color: AppColors.onlineMint),
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
                style: AppTypography.labelMd(color: AppColors.outline),
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
              child: Text('SAVE', style: AppTypography.labelMd()),
            ),
          ],
        );
      },
    );
  }

  void _showDeleteZoneDialog(Classroom room, String zoneName) {
    HapticFeedback.lightImpact();
    final displayName = room.getZoneDisplayName(zoneName);
    final count = room.devicesInZone(zoneName).length;

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
                child: const Icon(Icons.delete_sweep, color: AppColors.criticalRed, size: 22),
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
              child: Text('CANCEL', style: AppTypography.labelMd(color: AppColors.outline)),
            ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.criticalRed,
                foregroundColor: Colors.white,
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
              label: Text('DELETE', style: AppTypography.labelMd(color: Colors.white)),
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

  Color _getRoomTypeColor(String roomType) {
    final lower = roomType.toLowerCase();
    if (lower.contains('lab')) return const Color(0xFF00E5FF);
    if (lower.contains('seminar')) return const Color(0xFFFFB300);
    if (lower.contains('lecture')) return const Color(0xFF10B981);
    if (lower.contains('auditorium')) return const Color(0xFFA855F7);
    return AppColors.primary;
  }

  @override
  Widget build(BuildContext context) {
    final room = _room;
    if (room == null) {
      return Scaffold(
        backgroundColor: AppColors.surfaceContainerLowest,
        body: Center(
          child: Text('Classroom node not found.', style: AppTypography.bodyLg()),
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.surfaceContainerLowest,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceContainerLowest.withValues(alpha: 0.90),
        leading: IconButton(
          icon: Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: AppColors.surfaceContainerHigh.withValues(alpha: 0.8),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: const Icon(
              Icons.arrow_back,
              size: 18,
              color: AppColors.primary,
            ),
          ),
          onPressed: () => Navigator.pop(context),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: _getRoomTypeColor(room.roomType).withValues(alpha: 0.15),
                border: Border.all(color: _getRoomTypeColor(room.roomType).withValues(alpha: 0.4)),
              ),
              child: Icon(
                _getRoomTypeIcon(room.roomType),
                size: 18,
                color: _getRoomTypeColor(room.roomType),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _getRoomHeaderTitle(room),
                    style: AppTypography.headlineSm(color: AppColors.onSurface)
                        .copyWith(fontSize: 15, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      PulsingBeacon(
                        size: 6,
                        color: room.isMasterOn
                            ? AppColors.primary
                            : AppColors.outline,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${room.activeDeviceCount} ON · ${_normalizeRoomType(room.roomType)}',
                        style: AppTypography.labelSm(color: AppColors.primary).copyWith(fontSize: 11),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Action Buttons (Admin Only: Teachers view & control only)
            if (AuthState().isAdmin) ...[
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: AppColors.onPrimaryFixed,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 10),
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
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(
                            Icons.add,
                            size: 16,
                            color: AppColors.surfaceContainerLowest,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Add Device',
                            style: AppTypography.headlineSm(
                              color: AppColors.surfaceContainerLowest,
                            ).copyWith(fontSize: 13, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Rename Classroom',
                    style: IconButton.styleFrom(
                      backgroundColor: AppColors.surfaceContainer,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: BorderSide(
                          color: AppColors.secondary.withValues(alpha: 0.3),
                        ),
                      ),
                    ),
                    icon: const Icon(Icons.edit_note, size: 18, color: AppColors.secondary),
                    onPressed: _showRenameDialog,
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    style: IconButton.styleFrom(
                      backgroundColor: AppColors.surfaceContainer,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: BorderSide(
                          color: AppColors.error.withValues(alpha: 0.3),
                        ),
                      ),
                    ),
                    icon: const Icon(Icons.delete, size: 16, color: AppColors.error),
                    onPressed: _showDeleteDialog,
                  ),
                ],
              ),
              const SizedBox(height: 10),
            ],

            // ESP32 Classroom Identifier Badge
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: AppColors.surfaceContainerHigh.withValues(alpha: 0.45),
                border: Border.all(color: AppColors.primary.withValues(alpha: 0.22)),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      color: AppColors.primary.withValues(alpha: 0.12),
                    ),
                    child: const Icon(Icons.developer_board, size: 16, color: AppColors.primary),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Text(
                              'ESP32 ROOM ID',
                              style: AppTypography.labelSm(color: AppColors.outline).copyWith(
                                fontSize: 9.5,
                                letterSpacing: 0.6,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(4),
                                color: AppColors.primary.withValues(alpha: 0.15),
                              ),
                              child: Text(
                                room.id,
                                style: AppTypography.labelSm(color: AppColors.primary).copyWith(
                                  fontSize: 10.5,
                                  fontFamily: 'monospace',
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '#define CLASSROOM_ID "${room.id}"',
                          style: AppTypography.bodySm(color: AppColors.onSurfaceVariant).copyWith(
                            fontSize: 10,
                            fontFamily: 'monospace',
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: room.id));
                      CyberToast.show(
                        context,
                        message: 'Copied "${room.id}" to clipboard',
                        type: ToastType.success,
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        color: AppColors.surfaceContainerLowest,
                        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                      ),
                      child: const Icon(Icons.copy, size: 13, color: AppColors.primary),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // Device Filter Chips (ONLY Ceiling Fan, Light, AC)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
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

            // Separated Zones Section Header with View Toggle
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Text(
                      'SEPARATED CONTROL ZONES',
                      style: AppTypography.labelSm(color: AppColors.onSurfaceVariant),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '${room.zoneCount} ZONES',
                        style: AppTypography.labelSm(color: AppColors.primary)
                            .copyWith(fontSize: 10, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                // View Mode Toggle (List vs Grid)
                Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildViewModeToggle(Icons.view_agenda_rounded, false, 'List View'),
                      _buildViewModeToggle(Icons.grid_view_rounded, true, 'Grid View'),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 10),

            // Display each separated Zone
            if (room.zones.isEmpty)
              _buildEmptyDevicesState(room)
            else
              ...room.zones.map((zoneName) => _buildZoneCard(room, zoneName)),

            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildViewModeToggle(IconData icon, bool isGrid, String tooltip) {
    final isSelected = _isGridView == isGrid;
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: () => _setGridView(isGrid),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            color: isSelected ? AppColors.primary : Colors.transparent,
          ),
          child: Icon(
            icon,
            size: 15,
            color: isSelected ? AppColors.surfaceContainerLowest : AppColors.onSurfaceVariant,
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

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: AppColors.surfaceContainerLow.withValues(alpha: 0.9),
        border: Border.all(
          color: isZoneActive
              ? AppColors.primary.withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.08),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Zone Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
              color: AppColors.surfaceContainerHigh.withValues(alpha: 0.5),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: isZoneActive
                        ? AppColors.primary.withValues(alpha: 0.15)
                        : AppColors.surfaceContainerLowest,
                    border: Border.all(
                      color: isZoneActive
                          ? AppColors.primary.withValues(alpha: 0.4)
                          : Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                  child: Icon(
                    Icons.grid_view,
                    size: 16,
                    color: isZoneActive ? AppColors.primary : AppColors.outline,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              displayName.toUpperCase(),
                              style: AppTypography.headlineSm(color: AppColors.onSurface)
                                  .copyWith(fontSize: 13, fontWeight: FontWeight.bold),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          // Rename Zone Icon
                          GestureDetector(
                            onTap: () => _showRenameZoneDialog(room, zoneName),
                            child: Container(
                              padding: const EdgeInsets.all(4),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(5),
                                color: AppColors.primary.withValues(alpha: 0.12),
                                border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
                              ),
                              child: const Icon(
                                Icons.edit_outlined,
                                size: 12,
                                color: AppColors.primary,
                              ),
                            ),
                          ),
                          if (AuthState().isAdmin) ...[
                            const SizedBox(width: 5),
                            // Delete Zone Icon
                            GestureDetector(
                              onTap: () => _showDeleteZoneDialog(room, zoneName),
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(5),
                                  color: AppColors.criticalRed.withValues(alpha: 0.12),
                                  border: Border.all(color: AppColors.criticalRed.withValues(alpha: 0.25)),
                                ),
                                child: const Icon(
                                  Icons.delete_outline,
                                  size: 12,
                                  color: AppColors.criticalRed,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        hasAlias
                            ? '$zoneName · $activeInZone of $totalInZone Active'
                            : '$activeInZone of $totalInZone Active',
                        style: AppTypography.labelSm(
                          color: isZoneActive ? AppColors.primary : AppColors.onSurfaceVariant,
                        ).copyWith(fontSize: 10),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      isZoneActive ? 'ZONE ON' : 'ZONE OFF',
                      style: AppTypography.labelSm(
                        color: isZoneActive ? AppColors.primary : AppColors.outline,
                      ).copyWith(fontSize: 10, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(width: 8),
                    CyberSwitch(
                      value: isZoneActive,
                      onChanged: (val) {
                        _state.toggleZone(room.id, zoneName);
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Zone Device Cards
          Padding(
            padding: const EdgeInsets.all(12),
            child: filteredDevices.isEmpty
                ? _buildEmptyZoneState(room, zoneName, totalInZone)
                : (_isGridView
                    ? _buildZoneGridView(filteredDevices)
                    : _buildZoneCategorizedListView(filteredDevices)),
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
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
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
              icon: const Icon(Icons.add, size: 14, color: AppColors.primary),
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

  Widget _buildDeviceGroupHeader(String title, IconData icon, List<ClassroomDevice> devices) {
    final activeCount = devices.where((d) => d.isOn).length;
    final totalCount = devices.length;

    return Container(
      margin: const EdgeInsets.only(top: 4, bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerHigh.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 14, color: activeCount > 0 ? AppColors.primary : AppColors.outline),
          const SizedBox(width: 8),
          Text(
            title.toUpperCase(),
            style: AppTypography.labelSm(
              color: activeCount > 0 ? AppColors.onSurface : AppColors.onSurfaceVariant,
            ).copyWith(fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.5),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: activeCount > 0
                  ? AppColors.primary.withValues(alpha: 0.15)
                  : Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              activeCount > 0 ? '$activeCount of $totalCount ON' : '$totalCount Units · OFF',
              style: AppTypography.labelSm(
                color: activeCount > 0 ? AppColors.primary : AppColors.outline,
              ).copyWith(fontSize: 10, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceGridTile(ClassroomDevice device) {
    return RepaintBoundary(
      key: ValueKey('grid_${device.id}'),
      child: Container(
        decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(13),
        gradient: LinearGradient(
          colors: device.isOn
              ? [
                  AppColors.primary,
                  AppColors.onlineMint.withValues(alpha: 0.85),
                ]
              : [
                  Colors.white.withValues(alpha: 0.18),
                  AppColors.primary.withValues(alpha: 0.08),
                  Colors.white.withValues(alpha: 0.03),
                ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: device.isOn
            ? [
                BoxShadow(
                  color: AppColors.primary.withValues(alpha: 0.15),
                  blurRadius: 8,
                  spreadRadius: 0.5,
                ),
              ]
            : null,
      ),
      child: Container(
        margin: const EdgeInsets.all(1.2), // Gradient border thickness
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(11.8),
          color: device.isOn
              ? AppColors.surfaceContainerHigh.withValues(alpha: 0.95)
              : AppColors.surfaceContainerLowest,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                GestureDetector(
                  onTap: () {
                    HapticFeedback.mediumImpact();
                    _state.toggleDevice(widget.roomId, device.id);
                  },
                  child: _buildDeviceIconBox(device, size: 32),
                ),
                CyberSwitch(
                  value: device.isOn,
                  onChanged: (val) {
                    _state.toggleDevice(widget.roomId, device.id);
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _openDeviceDetail(device),
              onLongPress: AuthState().isAdmin ? () => _confirmDeleteDevice(device) : null,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    device.name,
                    style: AppTypography.headlineSm(
                      color: device.isOn ? AppColors.onSurface : AppColors.onSurfaceVariant,
                    ).copyWith(fontSize: 12, fontWeight: FontWeight.bold),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(4),
                          color: device.isOn
                              ? AppColors.onlineMint.withValues(alpha: 0.15)
                              : Colors.white.withValues(alpha: 0.05),
                        ),
                        child: Text(
                          device.isOn
                              ? (device.type == DeviceType.fan
                                  ? 'SPD ${device.fanSpeed}'
                                  : (device.type == DeviceType.hvac
                                      ? '${device.temperature}°C'
                                      : 'ON'))
                              : 'OFF',
                          style: AppTypography.labelSm(
                            color: device.isOn ? AppColors.onlineMint : AppColors.outline,
                          ).copyWith(fontSize: 9, fontWeight: FontWeight.bold),
                        ),
                      ),
                      const Spacer(),
                      Icon(Icons.tune, size: 12, color: AppColors.outline.withValues(alpha: 0.6)),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
    );
  }

  Widget _buildCategoryChip(String title) {
    final isSelected = _selectedCategory == title;

    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          setState(() => _selectedCategory = title);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            color: isSelected
                ? AppColors.primary
                : AppColors.surfaceContainerLow,
            border: Border.all(
              color: isSelected
                  ? AppColors.primary
                  : Colors.white.withValues(alpha: 0.08),
            ),
          ),
          child: Text(
            title,
            style: AppTypography.labelSm(
              color: isSelected
                  ? AppColors.surfaceContainerLowest
                  : AppColors.onSurfaceVariant,
            ).copyWith(fontWeight: isSelected ? FontWeight.bold : FontWeight.normal),
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
                  border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
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
              child: Text('CANCEL', style: AppTypography.labelMd(color: AppColors.outline)),
            ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.criticalRed,
                foregroundColor: Colors.white,
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
              label: Text('DELETE', style: AppTypography.labelMd(color: Colors.white)),
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
          color: Colors.white.withValues(alpha: 0.08),
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
            child: const Icon(
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
    return RepaintBoundary(
      key: ValueKey('card_${device.id}'),
      child: Container(
        margin: const EdgeInsets.only(bottom: 9),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(13),
        gradient: LinearGradient(
          colors: device.isOn
              ? [
                  AppColors.primary,
                  AppColors.onlineMint.withValues(alpha: 0.85),
                ]
              : [
                  Colors.white.withValues(alpha: 0.18),
                  AppColors.primary.withValues(alpha: 0.08),
                  Colors.white.withValues(alpha: 0.03),
                ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: device.isOn
            ? [
                BoxShadow(
                  color: AppColors.primary.withValues(alpha: 0.14),
                  blurRadius: 10,
                  spreadRadius: 0.5,
                ),
              ]
            : null,
      ),
      child: Container(
        margin: const EdgeInsets.all(1.2), // Gradient border thickness
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(11.8),
          color: device.isOn
              ? AppColors.surfaceContainerHigh.withValues(alpha: 0.95)
              : AppColors.surfaceContainerLowest,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Device Header: Icon, Name, Status chip, Tune icon, Switch
            Row(
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    HapticFeedback.mediumImpact();
                    _state.toggleDevice(widget.roomId, device.id);
                  },
                  child: _buildDeviceIconBox(device),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _openDeviceDetail(device),
                    onLongPress: AuthState().isAdmin ? () => _confirmDeleteDevice(device) : null,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                device.name,
                                style: AppTypography.headlineSm(
                                  color: device.isOn ? AppColors.onSurface : AppColors.onSurfaceVariant,
                                ).copyWith(fontSize: 13, fontWeight: FontWeight.w600),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 6),
                            PulsingBeacon(
                              size: 5,
                              color: device.isOn ? AppColors.onlineMint : AppColors.outline,
                              isPulsing: device.isOn,
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(4),
                                color: device.isOn
                                    ? AppColors.onlineMint.withValues(alpha: 0.15)
                                    : Colors.white.withValues(alpha: 0.05),
                              ),
                              child: Text(
                                device.isOn
                                    ? (device.type == DeviceType.fan
                                        ? 'SPEED ${device.fanSpeed}'
                                        : (device.type == DeviceType.lighting
                                            ? '${device.brightness.round()}%'
                                            : (device.type == DeviceType.hvac
                                                ? '${device.temperature}°C • ${device.hvacMode}'
                                                : 'ACTIVE')))
                                    : 'OFF',
                                style: AppTypography.labelSm(
                                  color: device.isOn ? AppColors.onlineMint : AppColors.outline,
                                ).copyWith(fontSize: 9, fontWeight: FontWeight.bold),
                              ),
                            ),
                            if (device.isOn) ...[
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  device.statusDescription.replaceFirst(RegExp(r'^Zone \d+ • '), ''),
                                  style: AppTypography.labelSm(color: AppColors.onSurfaceVariant)
                                      .copyWith(fontSize: 10),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                PopupMenuButton<String>(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  icon: Icon(Icons.more_vert, size: 18, color: AppColors.outline.withValues(alpha: 0.8)),
                  color: AppColors.surfaceContainerHigh,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: BorderSide(color: AppColors.primary.withValues(alpha: 0.2)),
                  ),
                  onSelected: (val) {
                    if (val == 'settings') _openDeviceDetail(device);
                    if (val == 'delete') _confirmDeleteDevice(device);
                  },
                  itemBuilder: (ctx) => [
                    PopupMenuItem(
                      value: 'settings',
                      child: Row(
                        children: [
                          const Icon(Icons.tune, size: 16, color: AppColors.primary),
                          const SizedBox(width: 8),
                          Text('Diagnostics & Settings', style: AppTypography.bodySm()),
                        ],
                      ),
                    ),
                    if (AuthState().isAdmin) ...[
                      const PopupMenuDivider(),
                      PopupMenuItem(
                        value: 'delete',
                        child: Row(
                          children: [
                            const Icon(Icons.delete_outline, size: 16, color: AppColors.criticalRed),
                            const SizedBox(width: 8),
                            Text('Delete Device', style: AppTypography.bodySm(color: AppColors.criticalRed)),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(width: 4),
                CyberSwitch(
                  value: device.isOn,
                  onChanged: (val) {
                    _state.toggleDevice(widget.roomId, device.id);
                  },
                ),
              ],
            ),

            // Custom Controls ONLY when device is ON!
            if (device.isOn) ...[
              if (device.type == DeviceType.fan) ...[
                const SizedBox(height: 8),
                Divider(color: Colors.white.withValues(alpha: 0.06), height: 1),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Text(
                      'SPEED:',
                      style: AppTypography.labelSm(color: AppColors.onSurfaceVariant).copyWith(fontSize: 10),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        color: AppColors.surfaceContainerLowest,
                        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [1, 2, 3, 4, 5].map((spd) {
                          final isSelected = device.fanSpeed == spd;
                          return GestureDetector(
                            onTap: () => _state.setFanSpeed(widget.roomId, device.id, spd),
                            child: Container(
                              width: 26,
                              height: 22,
                              margin: const EdgeInsets.symmetric(horizontal: 1),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(4),
                                color: isSelected ? AppColors.primary : Colors.transparent,
                              ),
                              child: Center(
                                child: Text(
                                  '$spd',
                                  style: AppTypography.labelSm(
                                    color: isSelected
                                        ? AppColors.surfaceContainerLowest
                                        : AppColors.onSurfaceVariant,
                                  ).copyWith(fontSize: 11, fontWeight: FontWeight.bold),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ],
                ),
              ],

              if (device.type == DeviceType.lighting) ...[
                const SizedBox(height: 8),
                Divider(color: Colors.white.withValues(alpha: 0.06), height: 1),
                const SizedBox(height: 6),
                CyberSlider(
                  value: device.brightness,
                  label: 'BRIGHTNESS:',
                  unit: '%',
                  maxMetric: 100,
                  onChanged: (val) {
                    _state.setBrightness(widget.roomId, device.id, val);
                  },
                ),
              ],

              if (device.type == DeviceType.hvac) ...[
                const SizedBox(height: 8),
                Divider(color: Colors.white.withValues(alpha: 0.06), height: 1),
                const SizedBox(height: 6),
                // Temperature Stepper & Mode Row
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        GestureDetector(
                          onTap: () => _state.setTemperature(widget.roomId, device.id, -1),
                          child: Container(
                            width: 24,
                            height: 24,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(6),
                              color: AppColors.surfaceContainerHigh,
                              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                            ),
                            child: const Icon(Icons.remove, size: 14, color: AppColors.onSurface),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Text(
                            '${device.temperature}°C',
                            style: AppTypography.labelLg(color: AppColors.primary)
                                .copyWith(fontSize: 13, fontWeight: FontWeight.bold),
                          ),
                        ),
                        GestureDetector(
                          onTap: () => _state.setTemperature(widget.roomId, device.id, 1),
                          child: Container(
                            width: 24,
                            height: 24,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(6),
                              color: AppColors.surfaceContainerHigh,
                              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                            ),
                            child: const Icon(Icons.add, size: 14, color: AppColors.onSurface),
                          ),
                        ),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        color: AppColors.surfaceContainerLowest,
                        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: ['AUTO', 'COOL', 'DRY', 'FAN', 'HEAT'].map((mode) {
                          final isSelected = device.hvacMode == mode;
                          return GestureDetector(
                            onTap: () => _state.setHvacMode(widget.roomId, device.id, mode),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(4),
                                color: isSelected ? AppColors.primary : Colors.transparent,
                              ),
                              child: Text(
                                mode,
                                style: AppTypography.labelSm(
                                  color: isSelected
                                      ? AppColors.surfaceContainerLowest
                                      : AppColors.onSurfaceVariant,
                                ).copyWith(fontSize: 9, fontWeight: FontWeight.bold),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                // Fan Speed & Vertical Swing Row
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // AC Fan Speeds: 0 = Auto, 1 = Low, 2 = Med, 3 = High
                    Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        color: AppColors.surfaceContainerLowest,
                        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          {'label': 'A', 'val': 0},
                          {'label': '1', 'val': 1},
                          {'label': '2', 'val': 2},
                          {'label': '3', 'val': 3},
                        ].map((fanOpt) {
                          final val = fanOpt['val'] as int;
                          final isSelected = (device.fanSpeed == val);
                          return GestureDetector(
                            onTap: () => _state.setAcFanSpeed(widget.roomId, device.id, val),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(4),
                                color: isSelected ? AppColors.onlineMint.withValues(alpha: 0.25) : Colors.transparent,
                              ),
                              child: Text(
                                fanOpt['label'] as String,
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                  color: isSelected ? AppColors.onlineMint : AppColors.outline,
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                    // Louver Swing Button
                    GestureDetector(
                      onTap: () => _state.toggleAcSwing(widget.roomId, device.id),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(5),
                          color: device.acSwing
                              ? AppColors.onlineMint.withValues(alpha: 0.2)
                              : AppColors.surfaceContainerLowest,
                          border: Border.all(
                            color: device.acSwing
                                ? AppColors.onlineMint
                                : Colors.white.withValues(alpha: 0.08),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.swap_vert,
                              size: 11,
                              color: device.acSwing ? AppColors.onlineMint : AppColors.outline,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              device.acSwing ? 'SWING' : 'FIXED',
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                                color: device.acSwing ? AppColors.onlineMint : AppColors.outline,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // IR Badge
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        color: AppColors.primary.withValues(alpha: 0.12),
                        border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
                      ),
                      child: const Text(
                        'IR: GPIO 4',
                        style: TextStyle(
                          fontSize: 8.5,
                          fontWeight: FontWeight.bold,
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
    ),
    );
  }

  Widget _buildDeviceIconBox(ClassroomDevice device, {double size = 36}) {
    Widget iconWidget;
    final iconSize = size * 0.5;

    if (device.type == DeviceType.fan) {
      iconWidget = FanSpinner(
        isSpinning: device.isOn,
        speed: device.fanSpeed,
        reverse: device.fanReverse,
        size: iconSize,
        color: AppColors.primary,
      );
    } else {
      IconData iconData;
      switch (device.type) {
        case DeviceType.hvac:
          iconData = Icons.ac_unit;
          break;
        case DeviceType.lighting:
          iconData = Icons.lightbulb_outline;
          break;
        default:
          iconData = Icons.developer_board;
      }

      iconWidget = Icon(
        iconData,
        size: iconSize,
        color: device.isOn ? AppColors.primary : AppColors.outline,
      );
    }

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: device.isOn
            ? AppColors.primary.withValues(alpha: 0.12)
            : AppColors.surfaceContainerLowest,
        border: Border.all(
          color: device.isOn
              ? AppColors.primary.withValues(alpha: 0.3)
              : Colors.white.withValues(alpha: 0.08),
        ),
      ),
      child: Center(child: iconWidget),
    );
  }
}
