import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/classroom.dart';
import '../models/device.dart';
import '../models/user_role.dart';
import '../state/classroom_state.dart';
import '../state/auth_state.dart';
import '../state/connectivity_state.dart';
import '../services/mqtt_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';
import '../widgets/app_logo.dart';
import '../widgets/pulsing_beacon.dart';
import '../widgets/route_transitions.dart';
import '../widgets/tactile_card.dart';
import '../widgets/cyber_toast.dart';
import '../widgets/connectivity_sheet.dart';
import 'add_classroom_screen.dart';
import 'add_device_screen.dart';
import 'settings_screen.dart';
import 'room_control_screen.dart';
import 'device_detail_screen.dart';
import 'auth_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final ClassroomState _state = ClassroomState();
  final ConnectivityState _connState = ConnectivityState();

  int _selectedTabIndex = 0;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  String _selectedBuildingFilter = 'All';
  bool _onlyActiveFilter = false;

  // Appliance tab filter
  String _applianceCategory = 'All';

  @override
  void initState() {
    super.initState();
    _state.addListener(_onStateChange);
    _connState.addListener(_onStateChange);
    AuthState().addListener(_onStateChange);
  }

  @override
  void dispose() {
    _state.removeListener(_onStateChange);
    _connState.removeListener(_onStateChange);
    AuthState().removeListener(_onStateChange);
    _searchController.dispose();
    super.dispose();
  }

  void _onStateChange() {
    if (mounted) setState(() {});
  }

  // --- Confirmation Modals for High-Impact Bulk Actions ---
  void _confirmMasterPowerOff() {
    HapticFeedback.heavyImpact();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
          decoration: BoxDecoration(
            color: AppColors.surfaceContainerHigh,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border.all(color: AppColors.telemetryAmber.withValues(alpha: 0.3)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.telemetryAmber.withValues(alpha: 0.15),
                ),
                child: const Icon(Icons.power_settings_new, color: AppColors.telemetryAmber, size: 28),
              ),
              const SizedBox(height: 14),
              Text(
                'Turn Off All Campus Devices?',
                style: AppTypography.headlineSm(color: AppColors.onSurface).copyWith(fontSize: 18),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'This will switch all relays and appliances across ${_state.classrooms.length} classrooms into standby power mode.',
                style: AppTypography.bodySm(color: AppColors.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 22),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: () => Navigator.pop(ctx),
                      child: Text('Cancel', style: AppTypography.labelMd(color: AppColors.onSurfaceVariant)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.telemetryAmber,
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        elevation: 4,
                      ),
                      onPressed: () {
                        Navigator.pop(ctx);
                        _state.setMasterAll(false);
                        CyberToast.show(
                          context,
                          message: 'All classroom devices powered OFF.',
                          type: ToastType.success,
                        );
                      },
                      child: Text(
                        'Power Off All',
                        style: AppTypography.labelMd(color: Colors.black).copyWith(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  void _confirmMasterPowerOn() {
    HapticFeedback.mediumImpact();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
          decoration: BoxDecoration(
            color: AppColors.surfaceContainerHigh,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.primary.withValues(alpha: 0.15),
                ),
                child: const Icon(Icons.bolt, color: AppColors.primary, size: 28),
              ),
              const SizedBox(height: 14),
              Text(
                'Power On All Campus Devices?',
                style: AppTypography.headlineSm(color: AppColors.onSurface).copyWith(fontSize: 18),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'This will activate all lights, fans, and appliances across ${_state.classrooms.length} classrooms.',
                style: AppTypography.bodySm(color: AppColors.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 22),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: () => Navigator.pop(ctx),
                      child: Text('Cancel', style: AppTypography.labelMd(color: AppColors.onSurfaceVariant)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: AppColors.surfaceContainerLowest,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        elevation: 4,
                      ),
                      onPressed: () {
                        Navigator.pop(ctx);
                        _state.setMasterAll(true);
                        CyberToast.show(
                          context,
                          message: 'All classroom devices powered ON.',
                          type: ToastType.success,
                        );
                      },
                      child: Text(
                        'Power On All',
                        style: AppTypography.labelMd(color: AppColors.surfaceContainerLowest).copyWith(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  // --- Helpers for Room Badges & Icons ---
  IconData _getRoomTypeIcon(String roomType) {
    final lower = roomType.toLowerCase();
    if (lower.contains('lab')) return Icons.science_outlined;
    if (lower.contains('seminar')) return Icons.groups_outlined;
    if (lower.contains('lecture')) return Icons.co_present_outlined;
    if (lower.contains('auditorium')) return Icons.theater_comedy_outlined;
    return Icons.school_outlined;
  }

  Color _getRoomTypeColor(String roomType) {
    final lower = roomType.toLowerCase();
    if (lower.contains('lab')) return const Color(0xFF00E5FF); // Cyan
    if (lower.contains('seminar')) return const Color(0xFFFFB300); // Amber
    if (lower.contains('lecture')) return const Color(0xFF10B981); // Emerald
    if (lower.contains('auditorium')) return const Color(0xFFA855F7); // Purple
    return AppColors.primary;
  }

  List<String> _extractUniqueBuildings() {
    final set = <String>{};
    for (final r in _state.classrooms) {
      final b = r.building.trim();
      if (b.isNotEmpty) set.add(b);
    }
    return set.toList()..sort();
  }

  List<Classroom> _getFilteredClassrooms() {
    final query = _searchQuery.trim().toLowerCase();
    return _state.classrooms.where((room) {
      // Building filter
      if (_selectedBuildingFilter != 'All') {
        if (!room.building.toLowerCase().contains(_selectedBuildingFilter.toLowerCase())) {
          return false;
        }
      }
      // Active only filter
      if (_onlyActiveFilter && !room.isMasterOn) {
        return false;
      }
      // Text search query
      if (query.isNotEmpty) {
        final matchesNumber = room.roomNumber.toLowerCase().contains(query);
        final matchesName = room.name.toLowerCase().contains(query);
        final matchesBuilding = room.building.toLowerCase().contains(query);
        final matchesType = room.roomType.toLowerCase().contains(query);
        if (!matchesNumber && !matchesName && !matchesBuilding && !matchesType) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final isOnline = MqttService().status == MqttConnectionStatus.connected;

    return Scaffold(
      backgroundColor: AppColors.surfaceContainerLowest,
      appBar: AppBar(
        titleSpacing: 20,
        automaticallyImplyLeading: false,
        backgroundColor: AppColors.surfaceContainerLowest.withValues(alpha: 0.95),
        elevation: 0,
        title: Row(
          children: [
            const ClassPulseLogo(size: 32, animated: false),
            const SizedBox(width: 10),
            Text(
              'ClassPulse',
              style: AppTypography.headlineSm(color: AppColors.primary).copyWith(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          // Live Network Status Badge
          GestureDetector(
            onTap: () => ConnectivitySheet.show(context),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                color: isOnline
                    ? AppColors.onlineMint.withValues(alpha: 0.12)
                    : AppColors.telemetryAmber.withValues(alpha: 0.12),
                border: Border.all(
                  color: isOnline
                      ? AppColors.onlineMint.withValues(alpha: 0.35)
                      : AppColors.telemetryAmber.withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PulsingBeacon(
                    size: 7,
                    color: isOnline ? AppColors.onlineMint : AppColors.telemetryAmber,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    isOnline ? 'ONLINE' : 'CONNECTING',
                    style: AppTypography.labelSm(
                      color: isOnline ? AppColors.onlineMint : AppColors.telemetryAmber,
                    ).copyWith(fontSize: 10, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),

          // User Role Pill
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: AuthState().isAdmin
                  ? AppColors.primary.withValues(alpha: 0.15)
                  : AppColors.secondary.withValues(alpha: 0.15),
              border: Border.all(
                color: AuthState().isAdmin
                    ? AppColors.primary.withValues(alpha: 0.4)
                    : AppColors.secondary.withValues(alpha: 0.4),
              ),
            ),
            child: Text(
              AuthState().userRole.badgeLabel,
              style: AppTypography.labelSm(
                color: AuthState().isAdmin ? AppColors.primary : AppColors.secondaryLight,
              ).copyWith(fontSize: 10, fontWeight: FontWeight.bold),
            ),
          ),

          // Admin Shortcuts (Add Classroom / Add Device)
          if (AuthState().isAdmin) ...[
            PopupMenuButton<String>(
              color: AppColors.surfaceContainerHigh,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: AppColors.primary.withValues(alpha: 0.3)),
              ),
              icon: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: AppColors.surfaceContainerHigh,
                  border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                ),
                child: const Icon(Icons.add, size: 18, color: AppColors.primary),
              ),
              onSelected: (val) {
                HapticFeedback.lightImpact();
                if (val == 'classroom') {
                  Navigator.push(context, Cube3DPageRoute(page: const AddClassroomScreen()));
                } else if (val == 'device') {
                  Navigator.push(context, Cube3DPageRoute(page: const AddDeviceScreen()));
                }
              },
              itemBuilder: (ctx) => [
                PopupMenuItem(
                  value: 'classroom',
                  child: Row(
                    children: [
                      const Icon(Icons.meeting_room_outlined, size: 18, color: AppColors.primary),
                      const SizedBox(width: 10),
                      Text('Add Classroom', style: AppTypography.bodySm(color: AppColors.onSurface)),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'device',
                  child: Row(
                    children: [
                      const Icon(Icons.devices, size: 18, color: AppColors.onlineMint),
                      const SizedBox(width: 10),
                      Text('Add Device / Switchboard', style: AppTypography.bodySm(color: AppColors.onSurface)),
                    ],
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(width: 12),
        ],
      ),
      body: IndexedStack(
        index: _selectedTabIndex,
        children: [
          _buildClassroomsTab(),
          _buildQuickAppliancesTab(),
          _buildConnectivityTab(),
          _buildSettingsTab(),
        ],
      ),
      bottomNavigationBar: _buildBottomNavigationBar(),
    );
  }

  // ==========================================
  // TAB 0: SIMPLIFIED CLASSROOMS HUB
  // ==========================================
  Widget _buildClassroomsTab() {
    final filteredRooms = _getFilteredClassrooms();
    final uniqueBuildings = _extractUniqueBuildings();

    return RefreshIndicator(
      color: AppColors.primary,
      backgroundColor: AppColors.surfaceContainerHigh,
      onRefresh: () async {
        HapticFeedback.mediumImpact();
        await Future.delayed(const Duration(milliseconds: 600));
        if (mounted) setState(() {});
      },
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1. Campus Summary & Safe Quick Controls
            _buildCampusOverviewCard(),

            const SizedBox(height: 16),

            // 2. Search & Filter Bar
            _buildSearchAndFilters(uniqueBuildings),

            const SizedBox(height: 16),

            // 3. Classrooms List
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'CLASSROOMS (${filteredRooms.length})',
                  style: AppTypography.labelSm(color: AppColors.onSurfaceVariant).copyWith(
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                  ),
                ),
                if (filteredRooms.isNotEmpty)
                  Text(
                    '${filteredRooms.where((r) => r.isMasterOn).length} Active Now',
                    style: AppTypography.labelSm(color: AppColors.primary),
                  ),
              ],
            ),

            const SizedBox(height: 10),

            if (_state.classrooms.isEmpty)
              _buildEmptyClassroomsState()
            else if (filteredRooms.isEmpty)
              _buildNoSearchResultsState()
            else
              ...filteredRooms.map((room) => _buildSimpleClassroomCard(room)),
          ],
        ),
      ),
    );
  }

  // --- Campus Summary & Master Controls ---
  Widget _buildCampusOverviewCard() {
    final activeRooms = _state.classrooms.where((r) => r.isMasterOn).length;
    final totalRooms = _state.classrooms.length;
    final activeDevs = _state.totalActivePeripherals;
    final totalDevs = _state.totalConfiguredPeripherals;

    final userName = AuthState().userName.isNotEmpty ? AuthState().userName : 'Educator';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: AppColors.surfaceContainerLow,
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.05),
            blurRadius: 18,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Greeting & Status Row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Welcome back, $userName',
                      style: AppTypography.headlineSm(color: AppColors.onSurface).copyWith(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$activeRooms of $totalRooms rooms active · $activeDevs of $totalDevs appliances running',
                      style: AppTypography.bodySm(color: AppColors.onSurfaceVariant).copyWith(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 14),
          Divider(color: Colors.white.withValues(alpha: 0.06), height: 1),
          const SizedBox(height: 12),

          // Safe Master Power Buttons
          Row(
            children: [
              // All On
              Expanded(
                child: SizedBox(
                  height: 42,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: AppColors.surfaceContainerLowest,
                      elevation: 2,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                    onPressed: _confirmMasterPowerOn,
                    icon: const Icon(Icons.bolt, size: 17),
                    label: Text(
                      'All On',
                      style: AppTypography.labelMd(color: AppColors.surfaceContainerLowest).copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),

              // All Off
              Expanded(
                child: SizedBox(
                  height: 42,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      backgroundColor: AppColors.surfaceContainerHigh,
                      foregroundColor: AppColors.onSurface,
                      side: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                    onPressed: _confirmMasterPowerOff,
                    icon: const Icon(Icons.power_settings_new, size: 17, color: AppColors.telemetryAmber),
                    label: Text(
                      'All Off',
                      style: AppTypography.labelMd(color: AppColors.onSurface).copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // --- Search & Filter Bar ---
  Widget _buildSearchAndFilters(List<String> uniqueBuildings) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Search Input Field
        Container(
          height: 46,
          decoration: BoxDecoration(
            color: AppColors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: TextField(
            controller: _searchController,
            onChanged: (val) => setState(() => _searchQuery = val),
            style: AppTypography.bodyMd(color: AppColors.onSurface),
            decoration: InputDecoration(
              hintText: 'Search room number, name, or building...',
              hintStyle: AppTypography.bodySm(color: AppColors.outline),
              prefixIcon: const Icon(Icons.search, size: 18, color: AppColors.outline),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 16, color: AppColors.outline),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      },
                    )
                  : null,
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),

        const SizedBox(height: 10),

        // Filter Pills Row
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              // All Filter
              _buildFilterChip(
                label: 'All Rooms',
                isSelected: _selectedBuildingFilter == 'All' && !_onlyActiveFilter,
                onTap: () {
                  HapticFeedback.selectionClick();
                  setState(() {
                    _selectedBuildingFilter = 'All';
                    _onlyActiveFilter = false;
                  });
                },
              ),

              // Active Only Filter
              _buildFilterChip(
                label: 'Active Only (ON)',
                icon: Icons.power_settings_new,
                isSelected: _onlyActiveFilter,
                onTap: () {
                  HapticFeedback.selectionClick();
                  setState(() => _onlyActiveFilter = !_onlyActiveFilter);
                },
              ),

              // Dynamic Buildings
              ...uniqueBuildings.map((building) {
                final isSelected = _selectedBuildingFilter == building;
                // Shorten building name for pill display
                final shortName = building.replaceAll('RUET ', '').replaceAll(' Building', ' Bldg');
                return _buildFilterChip(
                  label: shortName,
                  icon: Icons.apartment,
                  isSelected: isSelected,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    setState(() {
                      _selectedBuildingFilter = isSelected ? 'All' : building;
                    });
                  },
                );
              }),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFilterChip({
    required String label,
    IconData? icon,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: isSelected
                ? AppColors.primary.withValues(alpha: 0.18)
                : AppColors.surfaceContainerHigh.withValues(alpha: 0.6),
            border: Border.all(
              color: isSelected
                  ? AppColors.primary.withValues(alpha: 0.7)
                  : Colors.white.withValues(alpha: 0.08),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 13,
                  color: isSelected ? AppColors.primary : AppColors.onSurfaceVariant,
                ),
                const SizedBox(width: 5),
              ],
              Text(
                label,
                style: AppTypography.labelSm(
                  color: isSelected ? AppColors.primary : AppColors.onSurfaceVariant,
                ).copyWith(
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- Simplified Classroom Card (Clean, Readable, Direct Power) ---
  Widget _buildSimpleClassroomCard(Classroom room) {
    final isRoomActive = room.isMasterOn;
    final catColor = _getRoomTypeColor(room.roomType);
    final catIcon = _getRoomTypeIcon(room.roomType);

    // Count appliances by type
    final lights = room.devices.where((d) => d.type == DeviceType.lighting).toList();
    final activeLights = lights.where((d) => d.isOn).length;

    final fans = room.devices.where((d) => d.type == DeviceType.fan).toList();
    final activeFans = fans.where((d) => d.isOn).length;

    final acs = room.devices.where((d) => d.type == DeviceType.hvac).toList();
    final activeAcs = acs.where((d) => d.isOn).length;

    return RepaintBoundary(
      key: ValueKey('classroom_card_${room.id}'),
      child: TactileCard(
        isActive: isRoomActive,
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        borderRadius: 16,
        onTap: () {
          _state.selectRoom(room.id);
          Navigator.push(
            context,
            Cube3DPageRoute(
              page: RoomControlScreen(roomId: room.id),
            ),
          );
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top Row: Room Header + Master Power Switch
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Icon Avatar
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: catColor.withValues(alpha: isRoomActive ? 0.2 : 0.1),
                    border: Border.all(
                      color: catColor.withValues(alpha: isRoomActive ? 0.6 : 0.25),
                    ),
                  ),
                  child: Center(
                    child: Icon(catIcon, size: 22, color: catColor),
                  ),
                ),
                const SizedBox(width: 12),

                // Room Titles & Building Pill
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              room.roomNumber,
                              style: AppTypography.headlineSm(
                                color: isRoomActive ? AppColors.primary : AppColors.onSurface,
                              ).copyWith(fontSize: 16, fontWeight: FontWeight.bold),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (room.name.isNotEmpty &&
                              room.name.toLowerCase() != room.roomNumber.toLowerCase() &&
                              room.name.toLowerCase() != 'classroom') ...[
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                '• ${room.name}',
                                style: AppTypography.bodySm(color: AppColors.onSurfaceVariant).copyWith(fontSize: 12),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              room.building.isNotEmpty ? room.building : 'Main Campus',
                              style: AppTypography.bodySm(color: AppColors.outline).copyWith(fontSize: 11),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(4),
                              color: catColor.withValues(alpha: 0.12),
                            ),
                            child: Text(
                              room.roomType.toUpperCase(),
                              style: AppTypography.labelSm(color: catColor).copyWith(fontSize: 8.5, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                const SizedBox(width: 10),

                // Large, Clear Master Room Switch
                GestureDetector(
                  onTap: () {
                    HapticFeedback.mediumImpact();
                    _state.toggleRoomMaster(room.id);
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: isRoomActive
                          ? AppColors.primary
                          : AppColors.surfaceContainerHigh,
                      boxShadow: isRoomActive
                          ? [
                              BoxShadow(
                                color: AppColors.primary.withValues(alpha: 0.35),
                                blurRadius: 12,
                                offset: const Offset(0, 2),
                              ),
                            ]
                          : null,
                    ),
                    child: Center(
                      child: Icon(
                        Icons.power_settings_new,
                        size: 22,
                        color: isRoomActive
                            ? AppColors.surfaceContainerLowest
                            : AppColors.outline,
                      ),
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),
            Divider(color: Colors.white.withValues(alpha: 0.05), height: 1),
            const SizedBox(height: 10),

            // Bottom Row: Quick Glance Appliance Status Pills
            Row(
              children: [
                // Occupancy / Vision Badge
                if (room.isOccupied || room.currentOccupancy > 0) ...[
                  _buildAppliancePill(
                    icon: Icons.remove_red_eye,
                    label: '${room.currentOccupancy} Occ',
                    isActive: true,
                  ),
                  const SizedBox(width: 8),
                ],
                // Lights Badge
                if (lights.isNotEmpty) ...[
                  _buildAppliancePill(
                    icon: Icons.lightbulb_outline,
                    label: '$activeLights/${lights.length} Lights',
                    isActive: activeLights > 0,
                  ),
                  const SizedBox(width: 8),
                ],

                // Fans Badge
                if (fans.isNotEmpty) ...[
                  _buildAppliancePill(
                    icon: Icons.toys_outlined,
                    label: '$activeFans/${fans.length} Fans',
                    isActive: activeFans > 0,
                  ),
                  const SizedBox(width: 8),
                ],

                // AC Badge
                if (acs.isNotEmpty) ...[
                  _buildAppliancePill(
                    icon: Icons.ac_unit,
                    label: activeAcs > 0 ? '${acs.first.temperature}°C AC' : 'AC Off',
                    isActive: activeAcs > 0,
                  ),
                ],

                const Spacer(),

                // Chevron for entering room
                const Icon(Icons.chevron_right, size: 18, color: AppColors.outline),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAppliancePill({
    required IconData icon,
    required String label,
    required bool isActive,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        color: isActive
            ? AppColors.primary.withValues(alpha: 0.12)
            : AppColors.surfaceContainerHigh.withValues(alpha: 0.4),
        border: Border.all(
          color: isActive
              ? AppColors.primary.withValues(alpha: 0.3)
              : Colors.white.withValues(alpha: 0.05),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 12,
            color: isActive ? AppColors.primary : AppColors.outline,
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: AppTypography.labelSm(
              color: isActive ? AppColors.primary : AppColors.outline,
            ).copyWith(fontSize: 10, fontWeight: isActive ? FontWeight.bold : FontWeight.normal),
          ),
        ],
      ),
    );
  }

  // --- Empty States ---
  Widget _buildEmptyClassroomsState() {
    final isAdmin = AuthState().isAdmin;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: AppColors.surfaceContainerLow,
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
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
            style: AppTypography.headlineSm(color: AppColors.onSurface).copyWith(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            isAdmin
                ? 'Tap below to add your first classroom and configure ESP32 switches.'
                : 'Classrooms will appear here once provisioned by your system administrator.',
            textAlign: TextAlign.center,
            style: AppTypography.bodySm(color: AppColors.onSurfaceVariant).copyWith(height: 1.4),
          ),
          if (isAdmin) ...[
            const SizedBox(height: 20),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: AppColors.surfaceContainerLowest,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () {
                Navigator.push(context, Cube3DPageRoute(page: const AddClassroomScreen()));
              },
              icon: const Icon(Icons.add, size: 16),
              label: Text(
                'Add First Classroom',
                style: AppTypography.labelLg(color: AppColors.surfaceContainerLowest).copyWith(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildNoSearchResultsState() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: AppColors.surfaceContainerLow,
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        children: [
          const Icon(Icons.search_off, size: 36, color: AppColors.outline),
          const SizedBox(height: 12),
          Text(
            'No matching classrooms',
            style: AppTypography.headlineSm(color: AppColors.onSurface).copyWith(fontSize: 16),
          ),
          const SizedBox(height: 6),
          Text(
            'Try clearing your search query or selecting a different building filter.',
            textAlign: TextAlign.center,
            style: AppTypography.bodySm(color: AppColors.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: () {
              _searchController.clear();
              setState(() {
                _searchQuery = '';
                _selectedBuildingFilter = 'All';
                _onlyActiveFilter = false;
              });
            },
            child: Text('Reset Filters', style: AppTypography.labelMd(color: AppColors.primary)),
          ),
        ],
      ),
    );
  }

  // ==========================================
  // TAB 1: QUICK APPLIANCES TAB
  // ==========================================
  Widget _buildQuickAppliancesTab() {
    // Gather all devices across all classrooms
    final List<Map<String, dynamic>> allDevices = [];
    for (final room in _state.classrooms) {
      for (final dev in room.devices) {
        allDevices.add({
          'room': room,
          'device': dev,
        });
      }
    }

    final filtered = allDevices.where((item) {
      final dev = item['device'] as ClassroomDevice;
      if (_applianceCategory == 'Lights') return dev.type == DeviceType.lighting;
      if (_applianceCategory == 'Fans') return dev.type == DeviceType.fan;
      if (_applianceCategory == 'AC') return dev.type == DeviceType.hvac;
      return true;
    }).toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header & Bulk Toggle
          Text(
            'QUICK APPLIANCES',
            style: AppTypography.headlineSm(color: AppColors.onSurface).copyWith(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            'Control appliances directly across all rooms in the campus',
            style: AppTypography.bodySm(color: AppColors.onSurfaceVariant),
          ),

          const SizedBox(height: 14),

          // Appliance Category Switcher
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildApplianceCategoryChip('All', Icons.devices_other),
                _buildApplianceCategoryChip('Lights', Icons.lightbulb_outline),
                _buildApplianceCategoryChip('Fans', Icons.toys_outlined),
                _buildApplianceCategoryChip('AC', Icons.ac_unit),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Bulk Category Control Bar
          if (_applianceCategory != 'All') ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: AppColors.surfaceContainerLow,
                border: Border.all(color: AppColors.primary.withValues(alpha: 0.2)),
              ),
              child: Row(
                children: [
                  Icon(
                    _applianceCategory == 'Lights'
                        ? Icons.lightbulb_outline
                        : _applianceCategory == 'Fans'
                            ? Icons.toys_outlined
                            : Icons.ac_unit,
                    size: 18,
                    color: AppColors.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Turn all $_applianceCategory in all rooms:',
                      style: AppTypography.bodySm(color: AppColors.onSurface),
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      _bulkToggleApplianceType(_applianceCategory, false);
                    },
                    child: Text('ALL OFF', style: AppTypography.labelSm(color: AppColors.telemetryAmber).copyWith(fontWeight: FontWeight.bold)),
                  ),
                  TextButton(
                    onPressed: () {
                      _bulkToggleApplianceType(_applianceCategory, true);
                    },
                    child: Text('ALL ON', style: AppTypography.labelSm(color: AppColors.primary).copyWith(fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          // Devices List
          if (filtered.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: AppColors.surfaceContainerLow,
              ),
              child: Center(
                child: Text('No $_applianceCategory devices configured.', style: AppTypography.bodySm(color: AppColors.outline)),
              ),
            )
          else
            ...filtered.map((item) {
              final room = item['room'] as Classroom;
              final dev = item['device'] as ClassroomDevice;
              return _buildQuickApplianceCard(room, dev);
            }),
        ],
      ),
    );
  }

  void _bulkToggleApplianceType(String category, bool turnOn) {
    HapticFeedback.mediumImpact();
    for (final room in _state.classrooms) {
      for (final dev in room.devices) {
        bool match = false;
        if (category == 'Lights' && dev.type == DeviceType.lighting) match = true;
        if (category == 'Fans' && dev.type == DeviceType.fan) match = true;
        if (category == 'AC' && dev.type == DeviceType.hvac) match = true;

        if (match && dev.isOn != turnOn) {
          _state.toggleDevice(room.id, dev.id);
        }
      }
    }
    CyberToast.show(
      context,
      message: 'All $category switched ${turnOn ? "ON" : "OFF"}.',
      type: ToastType.success,
    );
  }

  Widget _buildApplianceCategoryChip(String title, IconData icon) {
    final isSelected = _applianceCategory == title;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          setState(() => _applianceCategory = title);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: isSelected ? AppColors.primary : AppColors.surfaceContainerHigh,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 15,
                color: isSelected ? AppColors.surfaceContainerLowest : AppColors.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                title,
                style: AppTypography.labelSm(
                  color: isSelected ? AppColors.surfaceContainerLowest : AppColors.onSurfaceVariant,
                ).copyWith(fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQuickApplianceCard(Classroom room, ClassroomDevice dev) {
    final isOn = dev.isOn;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: AppColors.surfaceContainerLow,
        border: Border.all(
          color: isOn ? AppColors.primary.withValues(alpha: 0.35) : Colors.white.withValues(alpha: 0.06),
        ),
      ),
      child: Row(
        children: [
          // Device Icon
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: isOn ? AppColors.primary.withValues(alpha: 0.18) : AppColors.surfaceContainerHigh,
            ),
            child: Icon(
              dev.type == DeviceType.lighting
                  ? Icons.lightbulb_outline
                  : dev.type == DeviceType.fan
                      ? Icons.toys_outlined
                      : Icons.ac_unit,
              size: 20,
              color: isOn ? AppColors.primary : AppColors.outline,
            ),
          ),
          const SizedBox(width: 12),

          // Device info & Room tag (tap to view device diagnostics)
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                HapticFeedback.lightImpact();
                Navigator.push(
                  context,
                  Cube3DPageRoute(
                    page: DeviceDetailScreen(roomId: room.id, deviceId: dev.id),
                  ),
                );
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    dev.name,
                    style: AppTypography.bodyMd(color: AppColors.onSurface).copyWith(fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${room.roomNumber} · ${dev.zone}',
                    style: AppTypography.labelSm(color: AppColors.primary).copyWith(fontSize: 10),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(width: 10),

          // Direct Power Toggle
          GestureDetector(
            onTap: () {
              HapticFeedback.lightImpact();
              _state.toggleDevice(room.id, dev.id);
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: isOn ? AppColors.primary : AppColors.surfaceContainerHigh,
              ),
              child: Icon(
                Icons.power_settings_new,
                size: 18,
                color: isOn ? AppColors.surfaceContainerLowest : AppColors.outline,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================
  // TAB 2: CONNECTIVITY & ESP32 HARDWARE TAB
  // ==========================================
  Widget _buildConnectivityTab() {
    final mqtt = MqttService();
    final isOnline = mqtt.status == MqttConnectionStatus.connected;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'NETWORK & HARDWARE',
            style: AppTypography.headlineSm(color: AppColors.onSurface).copyWith(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            'Live MQTT Broker status and ESP32 hardware switchboards',
            style: AppTypography.bodySm(color: AppColors.onSurfaceVariant),
          ),

          const SizedBox(height: 16),

          // MQTT Broker Card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: AppColors.surfaceContainerLow,
              border: Border.all(
                color: isOnline ? AppColors.onlineMint.withValues(alpha: 0.3) : AppColors.telemetryAmber.withValues(alpha: 0.3),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        PulsingBeacon(
                          size: 8,
                          color: isOnline ? AppColors.onlineMint : AppColors.telemetryAmber,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'MQTT BROKER',
                          style: AppTypography.labelSm(
                            color: isOnline ? AppColors.onlineMint : AppColors.telemetryAmber,
                          ).copyWith(fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        color: isOnline ? AppColors.onlineMint.withValues(alpha: 0.15) : AppColors.telemetryAmber.withValues(alpha: 0.15),
                      ),
                      child: Text(
                        isOnline ? 'CONNECTED' : 'DISCONNECTED',
                        style: AppTypography.labelSm(
                          color: isOnline ? AppColors.onlineMint : AppColors.telemetryAmber,
                        ).copyWith(fontSize: 10, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text('Broker: ${mqtt.broker}:${mqtt.port}', style: AppTypography.bodyMd(color: AppColors.onSurface)),
                const SizedBox(height: 2),
                Text('Base Topic: ${mqtt.baseTopic}', style: AppTypography.bodySm(color: AppColors.outline)),
                const SizedBox(height: 14),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.surfaceContainerHigh,
                    foregroundColor: AppColors.primary,
                    side: BorderSide(color: AppColors.primary.withValues(alpha: 0.3)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    mqtt.connect();
                    CyberToast.show(context, message: 'Reconnecting to MQTT broker...', type: ToastType.info);
                  },
                  icon: const Icon(Icons.sync, size: 16),
                  label: const Text('Reconnect Broker'),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Wi-Fi & ESP-NOW Provisioning Sheet Launcher
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: AppColors.surfaceContainerLow,
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: AppColors.secondary.withValues(alpha: 0.15),
                  ),
                  child: const Icon(Icons.wifi_tethering, color: AppColors.secondary, size: 24),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Wi-Fi Provisioning & Mesh Wizard', style: AppTypography.bodyMd(color: AppColors.onSurface).copyWith(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 2),
                      Text('Pair new ESP32 switchboards to campus Wi-Fi', style: AppTypography.bodySm(color: AppColors.onSurfaceVariant)),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_forward_ios, size: 16, color: AppColors.primary),
                  onPressed: () => ConnectivitySheet.show(context),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================
  // TAB 3: SETTINGS & PROFILE TAB
  // ==========================================
  Widget _buildSettingsTab() {
    final auth = AuthState();

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'ACCOUNT & SETTINGS',
            style: AppTypography.headlineSm(color: AppColors.onSurface).copyWith(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            'User identity, role privileges, and system preferences',
            style: AppTypography.bodySm(color: AppColors.onSurfaceVariant),
          ),

          const SizedBox(height: 16),

          // Profile Card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: AppColors.surfaceContainerLow,
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 26,
                  backgroundColor: AppColors.primary.withValues(alpha: 0.2),
                  child: Text(
                    auth.userName.isNotEmpty ? auth.userName[0].toUpperCase() : 'U',
                    style: AppTypography.headlineSm(color: AppColors.primary).copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        auth.userName.isNotEmpty ? auth.userName : 'Educator Account',
                        style: AppTypography.bodyLg(color: AppColors.onSurface).copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        auth.userEmail.isNotEmpty ? auth.userEmail : 'Logged in offline',
                        style: AppTypography.bodySm(color: AppColors.outline),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        auth.userDepartment,
                        style: AppTypography.labelSm(color: AppColors.primary).copyWith(fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Role Switcher Tile (Admin vs Educator)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: AppColors.surfaceContainerLow,
              border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Active Role Privilege', style: AppTypography.bodyMd(color: AppColors.onSurface).copyWith(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 2),
                    Text(auth.isAdmin ? 'Full Administrative Access' : 'Educator Control Mode', style: AppTypography.bodySm(color: AppColors.outline)),
                  ],
                ),
                Switch(
                  value: auth.isAdmin,
                  activeColor: AppColors.primary,
                  onChanged: (val) {
                    HapticFeedback.selectionClick();
                    auth.setUserRole(val ? UserRole.admin : UserRole.teacher);
                    CyberToast.show(
                      context,
                      message: val ? 'Switched to Administrator privilege' : 'Switched to Educator mode',
                      type: ToastType.info,
                    );
                  },
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // Open Full Advanced Settings Button
          ListTile(
            tileColor: AppColors.surfaceContainerLow,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            leading: const Icon(Icons.tune, color: AppColors.primary),
            title: Text('Advanced Settings & PIN', style: AppTypography.bodyMd(color: AppColors.onSurface)),
            subtitle: Text('Configure broker, MQTT topics, and emergency PIN', style: AppTypography.bodySm(color: AppColors.outline)),
            trailing: const Icon(Icons.arrow_forward_ios, size: 14, color: AppColors.outline),
            onTap: () {
              Navigator.push(context, Cube3DPageRoute(page: const SettingsScreen()));
            },
          ),



          const SizedBox(height: 20),

          // Sign Out Button
          SizedBox(
            width: double.infinity,
            height: 46,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.criticalRed,
                side: BorderSide(color: AppColors.criticalRed.withValues(alpha: 0.4)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () {
                HapticFeedback.heavyImpact();
                auth.signOut();
                Navigator.of(context).pushReplacement(Cube3DPageRoute(page: const AuthScreen()));
              },
              icon: const Icon(Icons.logout, size: 18),
              label: Text('Sign Out', style: AppTypography.labelMd(color: AppColors.criticalRed).copyWith(fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================
  // BOTTOM NAVIGATION BAR
  // ==========================================
  Widget _buildBottomNavigationBar() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLowest,
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildNavBarItem(0, Icons.meeting_room_outlined, Icons.meeting_room, 'Classrooms'),
              _buildNavBarItem(1, Icons.bolt_outlined, Icons.bolt, 'Appliances'),
              _buildNavBarItem(2, Icons.wifi_tethering_outlined, Icons.wifi_tethering, 'Network'),
              _buildNavBarItem(3, Icons.settings_outlined, Icons.settings, 'Settings'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNavBarItem(int index, IconData unselectedIcon, IconData selectedIcon, String label) {
    final isSelected = _selectedTabIndex == index;

    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() => _selectedTabIndex = index);
      },
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: isSelected ? AppColors.primary.withValues(alpha: 0.12) : Colors.transparent,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isSelected ? selectedIcon : unselectedIcon,
              size: 22,
              color: isSelected ? AppColors.primary : AppColors.outline,
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: AppTypography.labelSm(
                color: isSelected ? AppColors.primary : AppColors.outline,
              ).copyWith(
                fontSize: 10,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
