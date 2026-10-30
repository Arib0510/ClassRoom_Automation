import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/classroom.dart';
import '../state/classroom_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';
import '../widgets/app_logo.dart';
import '../widgets/pulsing_beacon.dart';
import '../widgets/route_transitions.dart';
import '../widgets/tactile_card.dart';
import 'add_classroom_screen.dart';
import 'add_device_screen.dart';
import '../widgets/connectivity_sheet.dart';
import '../state/auth_state.dart';
import 'settings_screen.dart';
import 'room_control_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final ClassroomState _state = ClassroomState();
  bool _offButtonAlert = false;

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

  void _handleAllOff() {
    HapticFeedback.heavyImpact();
    setState(() => _offButtonAlert = true);
    _state.setMasterAll(false);
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) setState(() => _offButtonAlert = false);
    });

    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: const Color(0xFF1B2333),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: AppColors.telemetryAmber.withValues(alpha: 0.6), width: 1.2),
        ),
        content: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: AppColors.telemetryAmber.withValues(alpha: 0.2),
              ),
              child: const Icon(Icons.power_settings_new, color: AppColors.telemetryAmber, size: 20),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'All Devices Powered OFF',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'All classroom relays switched to standby.',
                    style: TextStyle(
                      color: Color(0xFFD1D5DB),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _handleAllOn() {
    HapticFeedback.mediumImpact();
    _state.setMasterAll(true);

    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: const Color(0xFF11262B),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppColors.primary, width: 1.2),
        ),
        content: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: AppColors.primary.withValues(alpha: 0.2),
              ),
              child: const Icon(Icons.bolt, color: AppColors.primary, size: 20),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'All Devices Powered ON',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'All classroom relays energized active.',
                    style: TextStyle(
                      color: Color(0xFFD1D5DB),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        duration: const Duration(seconds: 2),
      ),
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

  Color _getRoomTypeColor(String roomType) {
    final lower = roomType.toLowerCase();
    if (lower.contains('lab')) return const Color(0xFF00E5FF); // Cyan
    if (lower.contains('seminar')) return const Color(0xFFFFB300); // Amber
    if (lower.contains('lecture')) return const Color(0xFF10B981); // Emerald
    if (lower.contains('auditorium')) return const Color(0xFFA855F7); // Purple
    return AppColors.primary; // Mint
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceContainerLowest,
      appBar: AppBar(
        titleSpacing: 20,
        automaticallyImplyLeading: false,
        backgroundColor: AppColors.surface.withValues(alpha: 0.90),
        title: Row(
          children: [
            const ClassPulseLogo(size: 32, animated: false),
            const SizedBox(width: 10),
            Text(
              'ClassPulse IoT',
              style: AppTypography.headlineSm(color: AppColors.primary),
            ),
          ],
        ),
        actions: [
          // Wi-Fi & Network / MQTT Connectivity launcher
          IconButton(
            icon: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: AppColors.surfaceContainerHigh,
                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              ),
              child: const Icon(
                Icons.wifi_tethering,
                size: 18,
                color: AppColors.primary,
              ),
            ),
            tooltip: 'Wi-Fi & MQTT Connectivity',
            onPressed: () => ConnectivitySheet.show(context),
          ),

          // Settings Page Button
          IconButton(
            icon: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: AppColors.surfaceContainerHigh,
                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              ),
              child: const Icon(
                Icons.settings_outlined,
                size: 18,
                color: AppColors.primary,
              ),
            ),
            tooltip: 'Settings',
            onPressed: () {
              HapticFeedback.lightImpact();
              Navigator.push(
                context,
                Cube3DPageRoute(page: const SettingsScreen()),
              );
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // SYSTEM STATUS Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'SYSTEM STATUS',
                  style: AppTypography.labelMd(
                    color: AppColors.onSurfaceVariant,
                  ),
                ),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        color: AuthState().isAdmin
                            ? AppColors.primary.withValues(alpha: 0.15)
                            : AppColors.onlineMint.withValues(alpha: 0.15),
                      ),
                      child: Text(
                        AuthState().userRole.badgeLabel,
                        style: AppTypography.labelSm(
                          color: AuthState().isAdmin ? AppColors.primary : AppColors.onlineMint,
                        ).copyWith(fontSize: 9, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Icon(
                      Icons.check_circle,
                      size: 13,
                      color: AppColors.onlineMint,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      'System Online',
                      style: AppTypography.labelSm(
                        color: AppColors.primary,
                      ),
                    ),
                  ],
                ),
              ],
            ),

            const SizedBox(height: 10),

            // Master Control Panel Card
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: const Color(0xDA0F172A),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.08),
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.primary.withValues(alpha: 0.08),
                    blurRadius: 24,
                  ),
                ],
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Connected Devices',
                              style: AppTypography.bodySm(
                                color: AppColors.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 4),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.baseline,
                                textBaseline: TextBaseline.alphabetic,
                                children: [
                                  Text(
                                    '${_state.totalActivePeripherals}',
                                    style: AppTypography.displayLg(
                                      color: AppColors.primary,
                                    ).copyWith(fontSize: 28),
                                  ),
                                  Text(
                                    ' / ${_state.totalConfiguredPeripherals}',
                                    style: AppTypography.headlineSm(
                                      color: AppColors.onSurfaceVariant,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Devices ON',
                                    style: AppTypography.labelSm(
                                      color: AppColors.primary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            'Control Zones',
                            style: AppTypography.labelMd(
                              color: AppColors.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${_state.activeZonesCount} of ${_state.totalZonesCount} Active',
                            style: AppTypography.bodySm(
                              color: AppColors.primary,
                            ).copyWith(fontWeight: FontWeight.w500, fontSize: 12),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Divider(color: Colors.white.withValues(alpha: 0.08)),
                  const SizedBox(height: 12),

                  // Dual Master Switch Buttons: All On / All Off
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 46,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.primary,
                              foregroundColor: AppColors.surfaceContainerLowest,
                              elevation: 4,
                              shadowColor:
                                  AppColors.primary.withValues(alpha: 0.4),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            onPressed: _handleAllOn,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(
                                  Icons.power_settings_new,
                                  size: 18,
                                  color: AppColors.surfaceContainerLowest,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  'All On',
                                  style: AppTypography.headlineSm(
                                    color: AppColors.surfaceContainerLowest,
                                  ).copyWith(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: SizedBox(
                          height: 46,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: _offButtonAlert
                                    ? AppColors.error
                                    : Colors.white.withValues(alpha: 0.15),
                                width: _offButtonAlert ? 1.5 : 1.0,
                              ),
                            ),
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                backgroundColor: _offButtonAlert
                                    ? AppColors.errorContainer
                                        .withValues(alpha: 0.3)
                                    : AppColors.surfaceContainerHigh,
                                foregroundColor: AppColors.onSurface,
                                side: BorderSide.none,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              onPressed: _handleAllOff,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.power_off,
                                    size: 18,
                                    color: _offButtonAlert
                                        ? AppColors.error
                                        : AppColors.onSurface,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    'All Off',
                                    style: AppTypography.headlineSm(
                                      color: _offButtonAlert
                                          ? AppColors.error
                                          : AppColors.onSurface,
                                    ).copyWith(fontSize: 14),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // Quick Access Action Grid: Add Classroom / Add Device (Admin Only)
            if (AuthState().isAdmin) ...[
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () {
                        HapticFeedback.lightImpact();
                        Navigator.push(
                          context,
                          Cube3DPageRoute(
                            page: const AddClassroomScreen(),
                          ),
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          color: AppColors.primary.withValues(alpha: 0.12),
                          border: Border.all(
                            color: AppColors.primary.withValues(alpha: 0.5),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.primary.withValues(alpha: 0.15),
                              blurRadius: 10,
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.add,
                              size: 18,
                              color: AppColors.primary,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Add Classroom',
                              style: AppTypography.labelMd(
                                color: AppColors.primary,
                              ).copyWith(fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: GestureDetector(
                      onTap: () {
                        HapticFeedback.lightImpact();
                        Navigator.push(
                          context,
                          Cube3DPageRoute(
                            page: const AddDeviceScreen(),
                          ),
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          color: AppColors.surfaceContainer,
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.12),
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.add,
                              size: 18,
                              color: AppColors.onSurface,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Add Device',
                              style: AppTypography.labelMd(
                                color: AppColors.onSurface,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ] else ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: AppColors.surfaceContainerLow,
                  border: Border.all(color: AppColors.onlineMint.withValues(alpha: 0.25)),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(7),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.onlineMint.withValues(alpha: 0.15),
                      ),
                      child: const Icon(Icons.school_rounded, size: 18, color: AppColors.onlineMint),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                'TEACHER / EDUCATOR CONSOLE',
                                style: AppTypography.labelSm(color: AppColors.onlineMint).copyWith(
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                  fontSize: 10.5,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(4),
                                  color: AppColors.onlineMint.withValues(alpha: 0.18),
                                ),
                                child: Text(
                                  'ACTIVE',
                                  style: AppTypography.labelSm(color: AppColors.onlineMint).copyWith(
                                    fontSize: 8,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text(
                            'Classroom monitoring and live appliance controls are fully operational.',
                            style: AppTypography.bodySm(color: AppColors.onSurfaceVariant).copyWith(
                              fontSize: 11,
                              height: 1.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 24),

            // Classrooms Classified Under Buildings
            if (_state.classrooms.isEmpty)
              _buildEmptyClassroomsState()
            else
              ..._buildBuildingClassifiedSections(),

            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildBuildingClassifiedSections() {
    // Group rooms by building
    final Map<String, List<Classroom>> buildingsMap = {};
    for (final room in _state.classrooms) {
      final bldg = room.building.trim().isEmpty ? 'General Campus Building' : room.building.trim();
      buildingsMap.putIfAbsent(bldg, () => []).add(room);
    }

    final List<Widget> sections = [];

    buildingsMap.forEach((buildingName, rooms) {
      final totalDevices = rooms.fold<int>(0, (sum, r) => sum + r.totalDeviceCount);
      final activeDevices = rooms.fold<int>(0, (sum, r) => sum + r.activeDeviceCount);
      final hasActive = activeDevices > 0;

      // Group rooms within this building by Sub-Category (Room Type)
      final Map<String, List<Classroom>> subCategories = {};
      for (final room in rooms) {
        final cat = _normalizeRoomType(room.roomType);
        subCategories.putIfAbsent(cat, () => []).add(room);
      }

      sections.add(
        Container(
          margin: const EdgeInsets.only(bottom: 20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: AppColors.surfaceContainerLow.withValues(alpha: 0.5),
            border: Border.all(
              color: hasActive
                  ? AppColors.primary.withValues(alpha: 0.35)
                  : Colors.white.withValues(alpha: 0.08),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Building Header (Parent Category Card)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(15)),
                  color: AppColors.surfaceContainerHigh.withValues(alpha: 0.65),
                  border: Border(
                    bottom: BorderSide(
                      color: Colors.white.withValues(alpha: 0.07),
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: hasActive
                            ? AppColors.primary.withValues(alpha: 0.18)
                            : AppColors.surfaceContainerLowest,
                        border: Border.all(
                          color: hasActive
                              ? AppColors.primary.withValues(alpha: 0.4)
                              : Colors.white.withValues(alpha: 0.06),
                        ),
                      ),
                      child: Icon(
                        Icons.apartment,
                        size: 20,
                        color: hasActive ? AppColors.primary : AppColors.outline,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            buildingName,
                            style: AppTypography.headlineSm(color: AppColors.onSurface)
                                .copyWith(fontSize: 15, fontWeight: FontWeight.bold),
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${rooms.length} ${rooms.length == 1 ? "Room" : "Rooms"} · $activeDevices of $totalDevices Devices ON',
                            style: AppTypography.bodySm(
                              color: hasActive ? AppColors.primary : AppColors.onSurfaceVariant,
                            ).copyWith(fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                    if (hasActive)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          color: AppColors.primary.withValues(alpha: 0.15),
                          border: Border.all(
                            color: AppColors.primary.withValues(alpha: 0.4),
                          ),
                        ),
                        child: Text(
                          'ACTIVE',
                          style: AppTypography.labelSm(color: AppColors.primary)
                              .copyWith(fontSize: 9, fontWeight: FontWeight.bold),
                        ),
                      ),
                  ],
                ),
              ),

              // Sub-Categories Section with visual indentation
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: subCategories.entries.map((entry) {
                    final categoryName = entry.key;
                    final categoryRooms = entry.value;
                    final catColor = _getRoomTypeColor(categoryName);
                    final catIcon = _getRoomTypeIcon(categoryName);

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Sub-Category Bar
                        Padding(
                          padding: const EdgeInsets.only(left: 2, top: 2, bottom: 10),
                          child: Row(
                            children: [
                              Container(
                                width: 3,
                                height: 13,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(2),
                                  color: catColor,
                                ),
                              ),
                              const SizedBox(width: 7),
                              Icon(catIcon, size: 14, color: catColor),
                              const SizedBox(width: 6),
                              Text(
                                categoryName.toUpperCase(),
                                style: AppTypography.labelSm(color: catColor)
                                    .copyWith(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.8,
                                    ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '• ${categoryRooms.length} ${categoryRooms.length == 1 ? "Room" : "Rooms"}',
                                style: AppTypography.labelSm(
                                  color: AppColors.onSurfaceVariant.withValues(alpha: 0.65),
                                ).copyWith(fontSize: 10),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Container(
                                  height: 1,
                                  color: catColor.withValues(alpha: 0.15),
                                ),
                              ),
                            ],
                          ),
                        ),

                        // Sub-Category Rooms
                        ...categoryRooms.map(
                          (room) => _buildSubCategoryRoomCard(room, catColor, catIcon),
                        ),
                        const SizedBox(height: 6),
                      ],
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        ),
      );
    });

    return sections;
  }

  bool _hasCustomRoomName(Classroom room) {
    final name = room.name.trim().toLowerCase();
    final num = room.roomNumber.trim().toLowerCase();
    final type = room.roomType.trim().toLowerCase();
    if (name.isEmpty) return false;
    if (name == num) return false;
    if (name == 'classroom' || name == 'standard class' || name == 'standard classroom') return false;
    if (name == type) return false;
    return true;
  }

  Widget _buildSubCategoryRoomCard(Classroom room, Color catColor, IconData catIcon) {
    final isRoomActive = room.isMasterOn;

    return RepaintBoundary(
      key: ValueKey('room_${room.id}'),
      child: TactileCard(
        isActive: isRoomActive,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      borderRadius: 14,
      onTap: () {
        _state.selectRoom(room.id);
        Navigator.push(
          context,
          Cube3DPageRoute(
            page: RoomControlScreen(roomId: room.id),
          ),
        );
      },
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Highlight Room Icon Container
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: catColor.withValues(alpha: isRoomActive ? 0.22 : 0.12),
              border: Border.all(
                color: catColor.withValues(alpha: isRoomActive ? 0.6 : 0.25),
              ),
            ),
            child: Center(
              child: Icon(
                catIcon,
                size: 20,
                color: catColor,
              ),
            ),
          ),

          const SizedBox(width: 12),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Room Title
                Text(
                  room.roomNumber,
                  style: AppTypography.headlineSm(
                    color: isRoomActive
                        ? AppColors.primary
                        : AppColors.onSurface,
                  ).copyWith(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                if (_hasCustomRoomName(room)) ...[
                  const SizedBox(height: 2),
                  Text(
                    room.name,
                    style: AppTypography.bodySm(
                      color: AppColors.onSurfaceVariant,
                    ).copyWith(fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 3),
                Row(
                  children: [
                    PulsingBeacon(
                      size: 6,
                      color: isRoomActive
                          ? AppColors.primary
                          : AppColors.outline,
                      isPulsing: isRoomActive,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${room.activeDeviceCount} of ${room.totalDeviceCount} Devices ON',
                      style: AppTypography.labelSm(
                        color: isRoomActive
                            ? AppColors.primary
                            : AppColors.onSurfaceVariant,
                      ).copyWith(fontSize: 11),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(width: 8),

          // Room Master Power Button
          GestureDetector(
            onTap: () {
              HapticFeedback.lightImpact();
              _state.toggleRoomMaster(room.id);
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: isRoomActive
                    ? AppColors.primary.withValues(alpha: 0.18)
                    : AppColors.surfaceContainerHigh,
                border: Border.all(
                  color: isRoomActive
                      ? AppColors.primary.withValues(alpha: 0.6)
                      : Colors.white.withValues(alpha: 0.1),
                ),
                boxShadow: isRoomActive
                    ? [
                        BoxShadow(
                          color: AppColors.primary.withValues(alpha: 0.25),
                          blurRadius: 10,
                        ),
                      ]
                    : null,
              ),
              child: Center(
                child: Icon(
                  Icons.power_settings_new,
                  size: 20,
                  color: isRoomActive
                      ? AppColors.primary
                      : AppColors.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
    );
  }

  Widget _buildEmptyClassroomsState() {
    final isAdmin = AuthState().isAdmin;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: AppColors.surfaceContainerLow,
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.08),
        ),
      ),
      child: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.surfaceContainerHigh,
              border: Border.all(
                color: (isAdmin ? AppColors.primary : AppColors.onlineMint).withValues(alpha: 0.3),
              ),
            ),
            child: Icon(
              isAdmin ? Icons.meeting_room_outlined : Icons.school_outlined,
              size: 26,
              color: isAdmin ? AppColors.primary : AppColors.onlineMint,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            isAdmin ? 'No Classrooms Added Yet' : 'No Classrooms Assigned Yet',
            style: AppTypography.headlineSm(color: AppColors.onSurface)
                .copyWith(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            isAdmin
                ? 'Tap below to add your first classroom and start controlling lights, fans, and AC.'
                : 'Classrooms and connected switchboards will appear here once provisioned by your system administrator.',
            textAlign: TextAlign.center,
            style: AppTypography.bodySm(color: AppColors.onSurfaceVariant).copyWith(height: 1.4),
          ),
          if (isAdmin) ...[
            const SizedBox(height: 20),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: AppColors.surfaceContainerLowest,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: () {
                Navigator.push(
                  context,
                  Cube3DPageRoute(page: const AddClassroomScreen()),
                );
              },
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.add, size: 16),
                  const SizedBox(width: 6),
                  Text(
                    'Add First Classroom',
                    style: AppTypography.labelLg(color: AppColors.surfaceContainerLowest)
                        .copyWith(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

