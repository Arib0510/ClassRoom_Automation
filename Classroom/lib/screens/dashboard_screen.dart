import 'dart:async';
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
import '../theme/theme_controller.dart';
import '../widgets/app_logo.dart';
import '../widgets/app_sheet.dart';
import '../widgets/cyber_switch.dart';
import '../widgets/motion.dart';
import '../widgets/pulsing_beacon.dart';
import '../widgets/route_transitions.dart';
import '../widgets/tactile_card.dart';
import '../widgets/theme_reveal.dart';
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
  StreamSubscription<MqttConnectionStatus>? _mqttSub;

  int _selectedTabIndex = 0;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  String _selectedBuildingFilter = 'All';
  bool _onlyActiveFilter = false;
  final Set<String> _collapsedBuildings = {};

  // Appliance tab filter
  String _applianceCategory = 'All';

  @override
  void initState() {
    super.initState();
    _state.addListener(_onStateChange);
    _connState.addListener(_onStateChange);
    AuthState().addListener(_onStateChange);
    // Keep the connection badge live: broker status changes do not go
    // through any of the notifiers above.
    _mqttSub = MqttService().statusStream.listen((_) => _onStateChange());
  }

  @override
  void dispose() {
    _state.removeListener(_onStateChange);
    _connState.removeListener(_onStateChange);
    AuthState().removeListener(_onStateChange);
    _mqttSub?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onStateChange() {
    if (mounted) setState(() {});
  }

  // ---------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------

  Future<void> _confirmMasterPowerOff() async {
    HapticFeedback.heavyImpact();
    final confirmed = await showConfirmSheet(
      context,
      icon: Icons.power_settings_new_rounded,
      accent: AppColors.telemetryAmber,
      title: 'Turn off every device?',
      message:
          'All relays and appliances across ${_state.classrooms.length} classrooms will switch to standby.',
      confirmLabel: 'Power off all',
    );
    if (confirmed != true || !mounted) return;
    _state.setMasterAll(false);
    CyberToast.show(
      context,
      message: 'All classroom devices powered off.',
      type: ToastType.success,
    );
  }

  Future<void> _confirmMasterPowerOn() async {
    HapticFeedback.mediumImpact();
    final confirmed = await showConfirmSheet(
      context,
      icon: Icons.bolt_rounded,
      accent: AppColors.primary,
      onAccent: AppColors.onPrimary,
      title: 'Turn on every device?',
      message:
          'All lights, fans and appliances across ${_state.classrooms.length} classrooms will switch on.',
      confirmLabel: 'Power on all',
    );
    if (confirmed != true || !mounted) return;
    _state.setMasterAll(true);
    CyberToast.show(
      context,
      message: 'All classroom devices powered on.',
      type: ToastType.success,
    );
  }

  /// Toggles one appliance and tells the user if the vision gate refused it,
  /// instead of leaving the tap looking like it did nothing.
  void _toggleAppliance(Classroom room, ClassroomDevice dev) {
    HapticFeedback.lightImpact();
    final error = _state.toggleDevice(room.id, dev.id);
    if (error != null && mounted) {
      CyberToast.show(context, message: error, type: ToastType.error);
    }
  }

  bool _matchesCategory(ClassroomDevice dev, String category) {
    switch (category) {
      case 'Lights':
        return dev.type == DeviceType.lighting;
      case 'Fans':
        return dev.type == DeviceType.fan;
      case 'AC':
        return dev.type == DeviceType.hvac;
      default:
        return true;
    }
  }

  void _bulkToggleApplianceType(String category, bool turnOn) {
    HapticFeedback.mediumImpact();
    var changed = 0;
    var blocked = 0;
    for (final room in _state.classrooms) {
      for (final dev in room.devices) {
        if (!_matchesCategory(dev, category) || dev.isOn == turnOn) continue;
        final error = _state.toggleDevice(room.id, dev.id);
        if (error == null) {
          changed++;
        } else {
          blocked++;
        }
      }
    }

    final verb = turnOn ? 'on' : 'off';
    final String message;
    final ToastType type;
    if (blocked == 0) {
      message = changed == 0
          ? 'All $category are already $verb.'
          : 'All $category switched $verb.';
      type = ToastType.success;
    } else if (changed == 0) {
      message =
          'No $category switched on — the rooms are empty, so the vision gate kept them off.';
      type = ToastType.error;
    } else {
      message =
          '$changed switched on. $blocked stayed off because their zones are empty.';
      type = ToastType.info;
    }
    CyberToast.show(context, message: message, type: type);
  }

  void _openRoom(Classroom room) {
    _state.selectRoom(room.id);
    Navigator.push(
      context,
      Cube3DPageRoute(page: RoomControlScreen(roomId: room.id)),
    );
  }

  // ---------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------

  IconData _getRoomTypeIcon(String roomType) {
    final lower = roomType.toLowerCase();
    if (lower.contains('lab')) return Icons.science_outlined;
    if (lower.contains('seminar')) return Icons.groups_outlined;
    if (lower.contains('lecture')) return Icons.co_present_outlined;
    if (lower.contains('auditorium')) return Icons.theater_comedy_outlined;
    return Icons.school_outlined;
  }

  String _titleCase(String value) {
    return value
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .map((w) => w[0].toUpperCase() + w.substring(1).toLowerCase())
        .join(' ');
  }

  IconData _deviceIcon(DeviceType type) {
    switch (type) {
      case DeviceType.lighting:
        return Icons.lightbulb_outline_rounded;
      case DeviceType.fan:
        return Icons.mode_fan_off_outlined;
      case DeviceType.hvac:
        return Icons.ac_unit_rounded;
      default:
        return Icons.power_outlined;
    }
  }

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 17) return 'Good afternoon';
    return 'Good evening';
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
      if (_selectedBuildingFilter != 'All') {
        if (!room.building
            .toLowerCase()
            .contains(_selectedBuildingFilter.toLowerCase())) {
          return false;
        }
      }
      if (_onlyActiveFilter && !room.isMasterOn) {
        return false;
      }
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

  BoxDecoration _panel({Color? borderColor, double radius = 18}) {
    return BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      color: AppColors.surfaceContainerLow,
      border: Border.all(color: borderColor ?? AppColors.overlay(0.08)),
      boxShadow: AppColors.cardShadow(strength: 0.7),
    );
  }

  Widget _pageHeader(String title, String subtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: AppTypography.headlineMd(color: AppColors.onSurface)
              .copyWith(fontSize: 22, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: AppTypography.bodySm(color: AppColors.onSurfaceVariant)
              .copyWith(fontSize: 13),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------
  // Scaffold
  // ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceContainerLowest,
      appBar: AppBar(
        titleSpacing: 16,
        automaticallyImplyLeading: false,
        backgroundColor: AppColors.surfaceContainerLowest,
        elevation: 0,
        title: Row(
          children: [
            const ClassPulseLogo(size: 30, animated: false, showGlow: false),
            const SizedBox(width: 9),
            Flexible(
              child: Text(
                'ClassPulse',
                maxLines: 1,
                overflow: TextOverflow.fade,
                softWrap: false,
                style: AppTypography.headlineSm(color: AppColors.onSurface)
                    .copyWith(fontSize: 18, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        actions: [
          _buildConnectionBadge(),
          const SizedBox(width: 6),
          const ThemeToggleButton(),
          if (AuthState().isAdmin) ...[
            const SizedBox(width: 6),
            _buildAddMenu(),
          ],
          const SizedBox(width: 14),
        ],
      ),
      body: FadeIndexedStack(
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

  Widget _buildConnectionBadge() {
    final status = MqttService().status;
    final Color color;
    final String label;
    switch (status) {
      case MqttConnectionStatus.connected:
        color = AppColors.onlineMint;
        label = 'Online';
        break;
      case MqttConnectionStatus.connecting:
        color = AppColors.telemetryAmber;
        label = 'Connecting';
        break;
      default:
        color = AppColors.criticalRed;
        label = 'Offline';
    }

    return Tooltip(
      message: 'Connection details',
      child: PressScale(
        onTap: () => ConnectivitySheet.show(context),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          height: 38,
          constraints: const BoxConstraints(minWidth: 38),
          padding: const EdgeInsets.symmetric(horizontal: 11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(19),
            color: color.withValues(alpha: 0.12),
            border: Border.all(color: color.withValues(alpha: 0.30)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              PulsingBeacon(
                size: 7,
                color: color,
                isPulsing: status != MqttConnectionStatus.disconnected,
              ),
              // On very narrow phones the dot alone carries the status so
              // the app name is never squeezed out.
              if (MediaQuery.sizeOf(context).width >= 350) ...[
                const SizedBox(width: 8),
                Text(
                  label,
                  style: AppTypography.labelSm(color: color)
                      .copyWith(fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAddMenu() {
    return PopupMenuButton<String>(
      tooltip: 'Add',
      padding: EdgeInsets.zero,
      offset: const Offset(0, 46),
      onSelected: (val) {
        HapticFeedback.lightImpact();
        if (val == 'classroom') {
          Navigator.push(
            context,
            Cube3DPageRoute(page: const AddClassroomScreen()),
          );
        } else if (val == 'device') {
          Navigator.push(
            context,
            Cube3DPageRoute(page: const AddDeviceScreen()),
          );
        }
      },
      itemBuilder: (ctx) => [
        PopupMenuItem(
          value: 'classroom',
          child: Row(
            children: [
              Icon(Icons.meeting_room_outlined,
                  size: 19, color: AppColors.primary),
              const SizedBox(width: 12),
              const Text('Add classroom'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'device',
          child: Row(
            children: [
              Icon(Icons.developer_board_outlined,
                  size: 19, color: AppColors.onlineMint),
              const SizedBox(width: 12),
              const Text('Add device or switchboard'),
            ],
          ),
        ),
      ],
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: AppColors.primary,
        ),
        child: Icon(Icons.add_rounded, size: 22, color: AppColors.onPrimary),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Tab 0 — Classrooms
  // ---------------------------------------------------------------------

  Map<String, List<Classroom>> _groupRoomsByBuilding(List<Classroom> rooms) {
    final grouped = <String, List<Classroom>>{};
    for (final room in rooms) {
      final b = room.building.trim().isNotEmpty ? room.building.trim() : 'Main Campus';
      grouped.putIfAbsent(b, () => []).add(room);
    }
    final sortedKeys = grouped.keys.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final result = <String, List<Classroom>>{};
    for (final k in sortedKeys) {
      final list = grouped[k]!
        ..sort((a, b) => a.roomNumber.toLowerCase().compareTo(b.roomNumber.toLowerCase()));
      result[k] = list;
    }
    return result;
  }

  Widget _buildBuildingSectionHeader(String building, List<Classroom> rooms) {
    final activeRooms = rooms.where((r) => r.isMasterOn).length;
    final isCollapsed = _collapsedBuildings.contains(building);
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          HapticFeedback.selectionClick();
          setState(() {
            if (isCollapsed) {
              _collapsedBuildings.remove(building);
            } else {
              _collapsedBuildings.add(building);
            }
          });
        },
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: AppColors.surfaceContainerLow,
            border: Border.all(
              color: activeRooms > 0
                  ? AppColors.primary.withValues(alpha: 0.28)
                  : AppColors.overlay(0.08),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: activeRooms > 0
                      ? AppColors.primary.withValues(alpha: 0.14)
                      : AppColors.surfaceContainerHigh,
                ),
                child: Icon(
                  Icons.apartment_rounded,
                  size: 18,
                  color: activeRooms > 0 ? AppColors.primary : AppColors.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      building,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.labelLg(color: AppColors.onSurface)
                          .copyWith(fontSize: 13.5, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      '${rooms.length} ${rooms.length == 1 ? 'room' : 'rooms'} · $activeRooms active',
                      style: AppTypography.labelSm(
                        color: activeRooms > 0 ? AppColors.primary : AppColors.outline,
                      ).copyWith(fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              Icon(
                isCollapsed ? Icons.expand_more_rounded : Icons.expand_less_rounded,
                size: 22,
                color: AppColors.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildClassroomsTab() {
    final filteredRooms = _getFilteredClassrooms();
    final uniqueBuildings = _extractUniqueBuildings();
    final activeCount = filteredRooms.where((r) => r.isMasterOn).length;
    final groupedByBuilding = _groupRoomsByBuilding(filteredRooms);

    return RefreshIndicator(
      color: AppColors.primary,
      backgroundColor: AppColors.sheet,
      onRefresh: () async {
        HapticFeedback.mediumImpact();
        MqttService().requestHardwareSync();
        await Future.delayed(const Duration(milliseconds: 600));
        if (mounted) setState(() {});
      },
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildCampusOverviewCard(),
            const SizedBox(height: 18),
            _buildSearchAndFilters(uniqueBuildings),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _selectedBuildingFilter == 'All'
                        ? 'Buildings & classrooms'
                        : _selectedBuildingFilter,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.headlineSm(color: AppColors.onSurface)
                        .copyWith(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (filteredRooms.isNotEmpty)
                  Text(
                    '$activeCount of ${filteredRooms.length} active',
                    style: AppTypography.labelSm(
                      color: activeCount > 0
                          ? AppColors.primary
                          : AppColors.outline,
                    ).copyWith(fontSize: 12),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            if (_state.classrooms.isEmpty)
              _buildEmptyClassroomsState()
            else if (filteredRooms.isEmpty)
              _buildNoSearchResultsState()
            else
              for (final entry in groupedByBuilding.entries) ...[
                _buildBuildingSectionHeader(entry.key, entry.value),
                if (!_collapsedBuildings.contains(entry.key))
                  for (final room in entry.value) _buildClassroomCard(room),
              ],
          ],
        ),
      ),
    );
  }

  Widget _buildCampusOverviewCard() {
    final activeRooms = _state.classrooms.where((r) => r.isMasterOn).length;
    final totalRooms = _state.classrooms.length;
    final activeDevs = _state.totalActivePeripherals;
    final totalDevs = _state.totalConfiguredPeripherals;
    final auth = AuthState();
    final userName = auth.userName.isNotEmpty ? auth.userName : 'Educator';

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        color: AppColors.surfaceContainerLow,
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.18)),
        boxShadow: AppColors.cardShadow(),
      ),
      child: Stack(
        children: [
          const Positioned.fill(child: AmbientBackground(intensity: 0.9)),
          Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _greeting(),
                        style: AppTypography.bodySm(
                          color: AppColors.onSurfaceVariant,
                        ).copyWith(fontSize: 13),
                      ),
                    ),
                    StatusChip(
                      label: auth.userRole.displayName,
                      icon: auth.isAdmin
                          ? Icons.shield_outlined
                          : Icons.school_outlined,
                      color:
                          auth.isAdmin ? AppColors.primary : AppColors.secondary,
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  userName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.headlineMd(color: AppColors.onSurface)
                      .copyWith(fontSize: 22, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: _buildStatTile(
                        icon: Icons.meeting_room_outlined,
                        label: 'Rooms active',
                        value: activeRooms,
                        total: totalRooms,
                        color: AppColors.primary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildStatTile(
                        icon: Icons.bolt_rounded,
                        label: 'Devices on',
                        value: activeDevs,
                        total: totalDevs,
                        color: AppColors.onlineMint,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 46,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            foregroundColor: AppColors.onPrimary,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(13),
                            ),
                          ),
                          onPressed: _confirmMasterPowerOn,
                          icon: const Icon(Icons.bolt_rounded, size: 18),
                          label: const Text('All on', maxLines: 1),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: SizedBox(
                        height: 46,
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            backgroundColor: AppColors.surfaceContainerLow
                                .withValues(alpha: 0.6),
                            foregroundColor: AppColors.onSurface,
                            side: BorderSide(color: AppColors.overlay(0.14)),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(13),
                            ),
                          ),
                          onPressed: _confirmMasterPowerOff,
                          icon: Icon(
                            Icons.power_settings_new_rounded,
                            size: 18,
                            color: AppColors.telemetryAmber,
                          ),
                          label: const Text('All off', maxLines: 1),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatTile({
    required IconData icon,
    required String label,
    required int value,
    required int total,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: AppColors.surfaceContainerLowest.withValues(alpha: 0.55),
        border: Border.all(color: AppColors.overlay(0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.labelSm(
                    color: AppColors.onSurfaceVariant,
                  ).copyWith(fontSize: 11.5, fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              AnimatedCount(
                value: value,
                style: AppTypography.headlineLg(color: AppColors.onSurface)
                    .copyWith(fontSize: 26, fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 4),
              Text(
                'of $total',
                style: AppTypography.bodySm(color: AppColors.outline)
                    .copyWith(fontSize: 12.5),
              ),
            ],
          ),
          const SizedBox(height: 8),
          AnimatedMeter(
            fraction: total == 0 ? 0 : value / total,
            color: color,
          ),
        ],
      ),
    );
  }

  Widget _buildSearchAndFilters(List<String> uniqueBuildings) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          height: 48,
          decoration: BoxDecoration(
            color: AppColors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.overlay(0.08)),
          ),
          child: TextField(
            controller: _searchController,
            onChanged: (val) => setState(() => _searchQuery = val),
            textAlignVertical: TextAlignVertical.center,
            style: AppTypography.bodyMd(color: AppColors.onSurface),
            decoration: InputDecoration(
              isCollapsed: true,
              hintText: 'Search rooms or buildings',
              hintStyle: AppTypography.bodyMd(color: AppColors.outline),
              prefixIcon: Icon(Icons.search_rounded,
                  size: 20, color: AppColors.outline),
              prefixIconConstraints:
                  const BoxConstraints(minWidth: 46, minHeight: 48),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      tooltip: 'Clear search',
                      icon: Icon(Icons.close_rounded,
                          size: 18, color: AppColors.outline),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      },
                    )
                  : null,
              border: InputBorder.none,
              contentPadding: const EdgeInsets.only(right: 14),
            ),
          ),
        ),
        const SizedBox(height: 12),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          child: Row(
            children: [
              _buildFilterChip(
                label: 'All rooms',
                isSelected:
                    _selectedBuildingFilter == 'All' && !_onlyActiveFilter,
                onTap: () {
                  HapticFeedback.selectionClick();
                  setState(() {
                    _selectedBuildingFilter = 'All';
                    _onlyActiveFilter = false;
                  });
                },
              ),
              _buildFilterChip(
                label: 'Active',
                icon: Icons.power_settings_new_rounded,
                isSelected: _onlyActiveFilter,
                onTap: () {
                  HapticFeedback.selectionClick();
                  setState(() => _onlyActiveFilter = !_onlyActiveFilter);
                },
              ),
              ...uniqueBuildings.map((building) {
                final isSelected = _selectedBuildingFilter == building;
                final shortName = building
                    .replaceAll('RUET ', '')
                    .replaceAll(' Building', ' Bldg');
                return _buildFilterChip(
                  label: shortName,
                  icon: Icons.apartment_rounded,
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
    final fg = isSelected ? AppColors.onPrimary : AppColors.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: PressScale(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            color: isSelected ? AppColors.primary : AppColors.surfaceContainerLow,
            border: Border.all(
              color: isSelected ? AppColors.primary : AppColors.overlay(0.10),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 15, color: fg),
                const SizedBox(width: 6),
              ],
              Text(
                label,
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

  Widget _buildClassroomCard(Classroom room) {
    final isRoomActive = room.isMasterOn;
    final catColor = AppColors.roomType(room.roomType);
    final catIcon = _getRoomTypeIcon(room.roomType);

    final lights =
        room.devices.where((d) => d.type == DeviceType.lighting).toList();
    final activeLights = lights.where((d) => d.isOn).length;
    final fans = room.devices.where((d) => d.type == DeviceType.fan).toList();
    final activeFans = fans.where((d) => d.isOn).length;
    final acs = room.devices.where((d) => d.type == DeviceType.hvac).toList();
    final activeAcs = acs.where((d) => d.isOn).length;

    final showName = room.name.isNotEmpty &&
        room.name.toLowerCase() != room.roomNumber.toLowerCase() &&
        room.name.toLowerCase() != 'classroom';
    final building = room.building.isNotEmpty ? room.building : 'Main Campus';
    final subtitle = showName ? '${room.name} · $building' : building;

    return RepaintBoundary(
      key: ValueKey('classroom_card_${room.id}'),
      child: TactileCard(
        isActive: isRoomActive,
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
        borderRadius: 18,
        onTap: () => _openRoom(room),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 240),
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    color: isRoomActive
                        ? catColor
                        : catColor.withValues(alpha: 0.12),
                    boxShadow: isRoomActive
                        ? [
                            BoxShadow(
                              color: catColor.withValues(alpha: 0.30),
                              blurRadius: 10,
                              offset: const Offset(0, 3),
                            ),
                          ]
                        : null,
                  ),
                  child: Icon(
                    catIcon,
                    size: 23,
                    color: isRoomActive ? Colors.white : catColor,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        room.roomNumber,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.headlineSm(
                          color: AppColors.onSurface,
                        ).copyWith(fontSize: 17, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.bodySm(
                          color: AppColors.onSurfaceVariant,
                        ).copyWith(fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                PowerButton(
                  isOn: isRoomActive,
                  semanticLabel: 'Power for ${room.roomNumber}',
                  onTap: () {
                    HapticFeedback.mediumImpact();
                    _state.toggleRoomMaster(room.id);
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            Divider(color: AppColors.overlay(0.07), height: 1),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      StatusChip(
                        label: _titleCase(room.roomType),
                        color: catColor,
                      ),
                      if (room.isOccupied || room.currentOccupancy > 0)
                        StatusChip(
                          icon: Icons.people_alt_outlined,
                          label: '${room.currentOccupancy}',
                          color: AppColors.primary,
                        ),
                      if (lights.isNotEmpty)
                        StatusChip(
                          icon: Icons.lightbulb_outline_rounded,
                          label: '$activeLights/${lights.length}',
                          color: activeLights > 0
                              ? AppColors.primary
                              : AppColors.outline,
                          filled: activeLights > 0,
                        ),
                      if (fans.isNotEmpty)
                        StatusChip(
                          icon: Icons.mode_fan_off_outlined,
                          label: '$activeFans/${fans.length}',
                          color: activeFans > 0
                              ? AppColors.primary
                              : AppColors.outline,
                          filled: activeFans > 0,
                        ),
                      if (acs.isNotEmpty)
                        StatusChip(
                          icon: Icons.ac_unit_rounded,
                          label: activeAcs > 0
                              ? '${acs.firstWhere((d) => d.isOn).temperature}°C'
                              : 'Off',
                          color: activeAcs > 0
                              ? AppColors.primary
                              : AppColors.outline,
                          filled: activeAcs > 0,
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Icon(Icons.chevron_right_rounded,
                    size: 22, color: AppColors.outline),
              ],
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
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 34),
      decoration: _panel(),
      child: Column(
        children: [
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.primary.withValues(alpha: 0.12),
            ),
            child: Icon(
              isAdmin ? Icons.meeting_room_outlined : Icons.school_outlined,
              size: 28,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            isAdmin ? 'No classrooms yet' : 'No classrooms assigned yet',
            textAlign: TextAlign.center,
            style: AppTypography.headlineSm(color: AppColors.onSurface)
                .copyWith(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            isAdmin
                ? 'Add your first classroom to start configuring its switchboards.'
                : 'Classrooms appear here once your administrator sets them up.',
            textAlign: TextAlign.center,
            style: AppTypography.bodySm(color: AppColors.onSurfaceVariant)
                .copyWith(fontSize: 13, height: 1.45),
          ),
          if (isAdmin) ...[
            const SizedBox(height: 20),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
              ),
              onPressed: () {
                Navigator.push(
                  context,
                  Cube3DPageRoute(page: const AddClassroomScreen()),
                );
              },
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add classroom'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildNoSearchResultsState() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 30),
      decoration: _panel(),
      child: Column(
        children: [
          Icon(Icons.search_off_rounded, size: 38, color: AppColors.outline),
          const SizedBox(height: 12),
          Text(
            'No matching classrooms',
            style: AppTypography.headlineSm(color: AppColors.onSurface)
                .copyWith(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            'Try a different search or clear the filters.',
            textAlign: TextAlign.center,
            style: AppTypography.bodySm(color: AppColors.onSurfaceVariant)
                .copyWith(fontSize: 13),
          ),
          const SizedBox(height: 14),
          TextButton(
            onPressed: () {
              _searchController.clear();
              setState(() {
                _searchQuery = '';
                _selectedBuildingFilter = 'All';
                _onlyActiveFilter = false;
              });
            },
            child: const Text('Clear filters'),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Tab 1 — Quick appliances
  // ---------------------------------------------------------------------

  Widget _buildQuickAppliancesTab() {
    final sections = <Widget>[];
    var anyDevice = false;

    for (final room in _state.classrooms) {
      final devices = room.devices
          .where((d) => _matchesCategory(d, _applianceCategory))
          .toList();
      if (devices.isEmpty) continue;
      anyDevice = true;
      final onCount = devices.where((d) => d.isOn).length;

      sections.add(
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${room.roomNumber} · ${room.buildingShort.toUpperCase()}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.labelLg(color: AppColors.onSurface)
                      .copyWith(fontSize: 13.5),
                ),
              ),
              Text(
                '$onCount of ${devices.length} on',
                style: AppTypography.labelSm(
                  color: onCount > 0 ? AppColors.primary : AppColors.outline,
                ).copyWith(fontSize: 12),
              ),
            ],
          ),
        ),
      );
      for (final dev in devices) {
        sections.add(_buildQuickApplianceCard(room, dev));
      }
      sections.add(const SizedBox(height: 8));
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _pageHeader(
            'Quick Appliances',
            'Switch any appliance on campus without opening its room.',
          ),
          const SizedBox(height: 16),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            child: Row(
              children: [
                _buildApplianceCategoryChip('All', Icons.apps_rounded),
                _buildApplianceCategoryChip(
                    'Lights', Icons.lightbulb_outline_rounded),
                _buildApplianceCategoryChip(
                    'Fans', Icons.mode_fan_off_outlined),
                _buildApplianceCategoryChip('AC', Icons.ac_unit_rounded),
              ],
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _applianceCategory == 'All' || !anyDevice
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: _buildBulkBar(),
                  ),
          ),
          const SizedBox(height: 12),
          if (!anyDevice)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(26),
              decoration: _panel(),
              child: Column(
                children: [
                  Icon(Icons.power_off_outlined,
                      size: 34, color: AppColors.outline),
                  const SizedBox(height: 10),
                  Text(
                    _applianceCategory == 'All'
                        ? 'No appliances configured yet.'
                        : 'No $_applianceCategory configured yet.',
                    textAlign: TextAlign.center,
                    style: AppTypography.bodySm(
                      color: AppColors.onSurfaceVariant,
                    ).copyWith(fontSize: 13),
                  ),
                ],
              ),
            )
          else
            ...sections,
        ],
      ),
    );
  }

  Widget _buildBulkBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: AppColors.primary.withValues(alpha: 0.08),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.20)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'All $_applianceCategory, every room',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.bodySm(color: AppColors.onSurface)
                  .copyWith(fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: AppColors.telemetryAmber,
              minimumSize: const Size(52, 40),
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
            onPressed: () => _bulkToggleApplianceType(_applianceCategory, false),
            child: const Text('All off'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              minimumSize: const Size(52, 40),
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
            onPressed: () => _bulkToggleApplianceType(_applianceCategory, true),
            child: const Text('All on'),
          ),
        ],
      ),
    );
  }

  Widget _buildApplianceCategoryChip(String title, IconData icon) {
    return _buildFilterChip(
      label: title,
      icon: icon,
      isSelected: _applianceCategory == title,
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() => _applianceCategory = title);
      },
    );
  }

  Widget _buildQuickApplianceCard(Classroom room, ClassroomDevice dev) {
    final isOn = dev.isOn;

    String detail;
    if (dev.isPendingConfirmation) {
      detail = 'Pending…';
    } else if (!isOn) {
      detail = 'Off';
    } else if (dev.type == DeviceType.fan) {
      detail = 'Speed ${dev.fanSpeed}';
    } else if (dev.type == DeviceType.lighting) {
      detail = '${dev.brightness.round()}%';
    } else if (dev.type == DeviceType.hvac) {
      detail = '${dev.temperature}°C';
    } else {
      detail = 'On';
    }

    final isAc = dev.type == DeviceType.hvac;
    final accent = isAc ? AppColors.secondary : AppColors.primary;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 240),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: isOn
            ? Color.alphaBlend(
                accent.withValues(alpha: AppColors.isDark ? 0.14 : 0.11),
                AppColors.surfaceContainerLow,
              )
            : AppColors.surfaceContainerLow,
        border: Border.all(
          color: isOn
              ? accent.withValues(alpha: AppColors.isDark ? 0.50 : 0.70)
              : AppColors.overlay(AppColors.isDark ? 0.08 : 0.10),
          width: isOn ? 1.5 : 1.0,
        ),
        boxShadow: isOn
            ? [
                BoxShadow(
                  color: accent.withValues(alpha: AppColors.isDark ? 0.18 : 0.14),
                  blurRadius: 10,
                  spreadRadius: -2,
                  offset: const Offset(0, 3),
                ),
              ]
            : AppColors.cardShadow(strength: 0.6),
      ),
      child: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 240),
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: isOn ? accent : AppColors.surfaceContainerHigh,
              boxShadow: isOn
                  ? [
                      BoxShadow(
                        color: accent.withValues(alpha: 0.30),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : null,
            ),
            child: Icon(
              _deviceIcon(dev.type),
              size: 21,
              color: isOn ? AppColors.onPrimary : AppColors.outline,
            ),
          ),
          const SizedBox(width: 12),
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
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.bodyMd(color: AppColors.onSurface)
                        .copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${dev.zone} · $detail',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.bodySm(
                      color: isOn ? AppColors.primary : AppColors.outline,
                    ).copyWith(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          PowerButton(
            isOn: isOn,
            size: 42,
            radius: 12,
            semanticLabel: 'Power for ${dev.name}',
            onTap: () => _toggleAppliance(room, dev),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Tab 2 — Network
  // ---------------------------------------------------------------------

  Widget _buildConnectivityTab() {
    final mqtt = MqttService();
    final isOnline = mqtt.status == MqttConnectionStatus.connected;
    final isConnecting = mqtt.status == MqttConnectionStatus.connecting;
    final statusColor = isOnline
        ? AppColors.onlineMint
        : (isConnecting ? AppColors.telemetryAmber : AppColors.criticalRed);
    final statusLabel =
        isOnline ? 'Connected' : (isConnecting ? 'Connecting' : 'Disconnected');

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _pageHeader(
            'Network & Hardware',
            'Broker status and ESP32 switchboard setup.',
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration:
                _panel(borderColor: statusColor.withValues(alpha: 0.30)),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          color: statusColor.withValues(alpha: 0.14),
                        ),
                        child: Icon(Icons.hub_outlined,
                            size: 21, color: statusColor),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'MQTT broker',
                              style: AppTypography.bodyMd(
                                color: AppColors.onSurface,
                              ).copyWith(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 3),
                            Row(
                              children: [
                                PulsingBeacon(
                                  size: 7,
                                  color: statusColor,
                                  isPulsing: isOnline || isConnecting,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  statusLabel,
                                  style: AppTypography.labelSm(
                                    color: statusColor,
                                  ).copyWith(fontSize: 12),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _buildInfoRow('Host', '${mqtt.broker}:${mqtt.port}'),
                  const SizedBox(height: 8),
                  _buildInfoRow('Base topic', mqtt.baseTopic),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    height: 44,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.primary,
                        side: BorderSide(
                          color: AppColors.primary.withValues(alpha: 0.4),
                        ),
                      ),
                      onPressed: () {
                        HapticFeedback.lightImpact();
                        mqtt.connect();
                        CyberToast.show(
                          context,
                          message: 'Reconnecting to the broker…',
                          type: ToastType.info,
                        );
                      },
                      icon: const Icon(Icons.sync_rounded, size: 18),
                      label: const Text('Reconnect'),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          _buildNavTile(
            icon: Icons.wifi_tethering_rounded,
            iconColor: AppColors.secondary,
            title: 'Wi-Fi provisioning',
            subtitle: 'Pair new ESP32 switchboards to campus Wi-Fi.',
            onTap: () => ConnectivitySheet.show(context),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 84,
          child: Text(
            label,
            style: AppTypography.bodySm(color: AppColors.outline)
                .copyWith(fontSize: 12.5),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: AppTypography.bodySm(color: AppColors.onSurface)
                .copyWith(fontSize: 12.5, fontWeight: FontWeight.w500),
          ),
        ),
      ],
    );
  }

  Widget _buildNavTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: _panel(),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () {
            HapticFeedback.lightImpact();
            onTap();
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: iconColor.withValues(alpha: 0.14),
                  ),
                  child: Icon(icon, color: iconColor, size: 21),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: AppTypography.bodyMd(color: AppColors.onSurface)
                            .copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: AppTypography.bodySm(
                          color: AppColors.onSurfaceVariant,
                        ).copyWith(fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Icon(Icons.chevron_right_rounded,
                    size: 22, color: AppColors.outline),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Tab 3 — Settings
  // ---------------------------------------------------------------------

  Widget _buildSettingsTab() {
    final auth = AuthState();
    final name = auth.userName.isNotEmpty ? auth.userName : 'Educator account';

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _pageHeader(
            'Account & Settings',
            'Your profile, appearance and access level.',
          ),
          const SizedBox(height: 16),

          // Profile
          Container(
            padding: const EdgeInsets.all(16),
            decoration: _panel(),
            child: Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: AppColors.primaryGradient,
                  ),
                  child: Text(
                    name[0].toUpperCase(),
                    style: AppTypography.headlineMd(color: Colors.white)
                        .copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.bodyLg(
                          color: AppColors.onSurface,
                        ).copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        auth.userEmail.isNotEmpty
                            ? auth.userEmail
                            : 'Signed in offline',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.bodySm(color: AppColors.outline)
                            .copyWith(fontSize: 12.5),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        auth.userDepartment,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.labelSm(color: AppColors.primary)
                            .copyWith(fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Appearance
          _buildAppearanceCard(),
          const SizedBox(height: 12),

          // Vision Control Toggle (Vision Auto Control vs Direct App Control)
          Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
            decoration: _panel(
              borderColor: !_state.visionControlEnabled
                  ? AppColors.primary.withValues(alpha: 0.45)
                  : null,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Vision occupancy control',
                        style: AppTypography.bodyMd(
                          color: AppColors.onSurface,
                        ).copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _state.visionControlEnabled
                            ? 'Camera gates relays by room occupancy.'
                            : 'Disabled: direct app control active.',
                        style: AppTypography.bodySm(
                          color: _state.visionControlEnabled
                              ? AppColors.onSurfaceVariant
                              : AppColors.primary,
                        ).copyWith(fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                CyberSwitch(
                  value: _state.visionControlEnabled,
                  onChanged: (val) async {
                    HapticFeedback.mediumImpact();
                    await _state.setVisionControlEnabled(val);
                    if (!mounted) return;
                    CyberToast.show(
                      context,
                      message: val
                          ? 'Vision occupancy control enabled.'
                          : 'Vision control disabled. Direct app control active.',
                      type: ToastType.info,
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Role
          Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
            decoration: _panel(),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Administrator access',
                        style: AppTypography.bodyMd(
                          color: AppColors.onSurface,
                        ).copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        auth.isAdmin
                            ? 'Full access, including hardware setup.'
                            : 'Educator mode: view and control only.',
                        style: AppTypography.bodySm(
                          color: AppColors.onSurfaceVariant,
                        ).copyWith(fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                CyberSwitch(
                  value: auth.isAdmin,
                  onChanged: (val) {
                    auth.setUserRole(val ? UserRole.admin : UserRole.teacher);
                    CyberToast.show(
                      context,
                      message: val
                          ? 'Switched to administrator access.'
                          : 'Switched to educator mode.',
                      type: ToastType.info,
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          _buildNavTile(
            icon: Icons.tune_rounded,
            iconColor: AppColors.primary,
            title: 'Advanced settings',
            subtitle: 'Broker, MQTT topics, emergency PIN and app updates.',
            onTap: () {
              Navigator.push(
                context,
                Cube3DPageRoute(page: const SettingsScreen()),
              );
            },
          ),
          const SizedBox(height: 22),

          SizedBox(
            width: double.infinity,
            height: 48,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.criticalRed,
                side: BorderSide(
                  color: AppColors.criticalRed.withValues(alpha: 0.4),
                ),
              ),
              onPressed: () {
                HapticFeedback.heavyImpact();
                auth.signOut();
                Navigator.of(context).pushReplacement(
                  Cube3DPageRoute(page: const AuthScreen()),
                );
              },
              icon: const Icon(Icons.logout_rounded, size: 18),
              label: const Text('Sign out'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAppearanceCard() {
    return ListenableBuilder(
      listenable: ThemeController(),
      builder: (context, _) {
        final mode = ThemeController().mode;
        const options = <(ThemeMode, IconData, String)>[
          (ThemeMode.system, Icons.brightness_auto_rounded, 'System'),
          (ThemeMode.light, Icons.light_mode_rounded, 'Light'),
          (ThemeMode.dark, Icons.dark_mode_rounded, 'Dark'),
        ];
        final selected = options.indexWhere((o) => o.$1 == mode);

        return Container(
          padding: const EdgeInsets.all(16),
          decoration: _panel(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Appearance',
                style: AppTypography.bodyMd(color: AppColors.onSurface)
                    .copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text(
                mode == ThemeMode.system
                    ? 'Following your phone\'s setting.'
                    : 'Always use ${mode == ThemeMode.dark ? 'dark' : 'light'} mode.',
                style: AppTypography.bodySm(color: AppColors.onSurfaceVariant)
                    .copyWith(fontSize: 12.5),
              ),
              const SizedBox(height: 12),
              Container(
                height: 46,
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: AppColors.surfaceContainerHigh,
                  border: Border.all(color: AppColors.overlay(0.08)),
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final segment = constraints.maxWidth / options.length;
                    final safeSelected = selected < 0 ? 0 : selected;
                    return Stack(
                      children: [
                        AnimatedPositioned(
                          duration: const Duration(milliseconds: 280),
                          curve: Curves.easeOutCubic,
                          left: segment * safeSelected,
                          top: 0,
                          bottom: 0,
                          width: segment,
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              color: AppColors.primary,
                              boxShadow: [
                                BoxShadow(
                                  color: AppColors.primary.withValues(alpha: 0.28),
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                          ),
                        ),
                        Positioned.fill(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (var i = 0; i < options.length; i++)
                                Expanded(
                                  child: Builder(
                                    builder: (segmentContext) {
                                      final isSelected = i == safeSelected;
                                      final color = isSelected
                                          ? AppColors.onPrimary
                                          : AppColors.onSurfaceVariant;
                                      return GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onTap: () {
                                          HapticFeedback.selectionClick();
                                          final box = segmentContext
                                              .findRenderObject() as RenderBox?;
                                          ThemeReveal.switchTo(
                                            options[i].$1,
                                            origin: box?.localToGlobal(
                                              box.size.center(Offset.zero),
                                            ),
                                          );
                                        },
                                        child: Center(
                                          child: Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(options[i].$2,
                                                  size: 16, color: color),
                                              const SizedBox(width: 6),
                                              Flexible(
                                                child: Text(
                                                  options[i].$3,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: AppTypography.labelMd(
                                                    color: color,
                                                  ).copyWith(
                                                    fontSize: 12.5,
                                                    fontWeight: isSelected
                                                        ? FontWeight.w700
                                                        : FontWeight.w500,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------
  // Bottom navigation
  // ---------------------------------------------------------------------

  Widget _buildBottomNavigationBar() {
    const items = <(IconData, IconData, String)>[
      (Icons.meeting_room_outlined, Icons.meeting_room_rounded, 'Classrooms'),
      (Icons.bolt_outlined, Icons.bolt_rounded, 'Appliances'),
      (Icons.wifi_tethering_outlined, Icons.wifi_tethering_rounded, 'Network'),
      (Icons.settings_outlined, Icons.settings_rounded, 'Settings'),
    ];

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        border: Border(top: BorderSide(color: AppColors.overlay(0.08))),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 64,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final segment = constraints.maxWidth / items.length;
              const pillWidth = 60.0;
              return Stack(
                children: [
                  // The indicator glides between tabs rather than each tab
                  // fading its own highlight in and out.
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 380),
                    curve: Curves.easeOutBack,
                    left: segment * _selectedTabIndex +
                        (segment - pillWidth) / 2,
                    top: 8,
                    width: pillWidth,
                    height: 30,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(15),
                        color: AppColors.primary.withValues(alpha: 0.16),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      for (var i = 0; i < items.length; i++)
                        Expanded(
                          child: _buildNavBarItem(
                            i,
                            items[i].$1,
                            items[i].$2,
                            items[i].$3,
                          ),
                        ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildNavBarItem(
    int index,
    IconData unselectedIcon,
    IconData selectedIcon,
    String label,
  ) {
    final isSelected = _selectedTabIndex == index;
    final color = isSelected ? AppColors.primary : AppColors.outline;

    return Semantics(
      selected: isSelected,
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (isSelected) return;
          HapticFeedback.selectionClick();
          setState(() => _selectedTabIndex = index);
        },
        child: Column(
          children: [
            const SizedBox(height: 8),
            SizedBox(
              height: 30,
              child: AnimatedScale(
                scale: isSelected ? 1.08 : 1.0,
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutBack,
                child: Icon(
                  isSelected ? selectedIcon : unselectedIcon,
                  size: 22,
                  color: color,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.labelSm(color: color).copyWith(
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
