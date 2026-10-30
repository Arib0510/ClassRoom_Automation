import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/classroom.dart';
import '../models/user_role.dart';
import '../state/classroom_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';
import '../widgets/pulsing_beacon.dart';
import '../widgets/cyber_toast.dart';

class AddClassroomScreen extends StatefulWidget {
  const AddClassroomScreen({super.key});

  @override
  State<AddClassroomScreen> createState() => _AddClassroomScreenState();
}

class _AddClassroomScreenState extends State<AddClassroomScreen> {
  final TextEditingController _roomNumberController = TextEditingController();
  final TextEditingController _customBuildingController = TextEditingController();

  String _selectedBuilding = 'RUET CSE Building';
  bool _isCustomBuilding = false;
  String _selectedArchetype = 'Standard Class';
  int _capacity = 35;
  int _selectedZoneCount = 2;

  final List<String> _buildings = [
    'RUET CSE Building',
    'RUET EEE Building',
    'Civil Engineering Building',
    'Mechanical Engineering Dept',
    'Academic Building 1',
    'Academic Building 2',
    'Science & Technology Complex',
    '+ Enter Custom Building Name...',
  ];

  final List<Map<String, dynamic>> _archetypes = [
    {'name': 'Standard Class', 'icon': Icons.school},
    {'name': 'Laboratory', 'icon': Icons.science},
    {'name': 'Lecture Hall', 'icon': Icons.co_present},
    {'name': 'Seminar Room', 'icon': Icons.groups},
  ];

  @override
  void dispose() {
    _roomNumberController.dispose();
    _customBuildingController.dispose();
    super.dispose();
  }

  void _createClassroom() {
    final roomNum = _roomNumberController.text.trim();

    if (roomNum.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a room identifier (e.g. Room 402).'),
        ),
      );
      return;
    }

    final buildingName = _isCustomBuilding
        ? _customBuildingController.text.trim()
        : _selectedBuilding.split(' - ').first;

    if (_isCustomBuilding && buildingName.isEmpty) {
      CyberToast.show(
        context,
        message: 'Please enter a custom building name.',
        type: ToastType.error,
      );
      return;
    }

    HapticFeedback.mediumImpact();

    final cleanNum = roomNum.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '_').replaceAll(RegExp(r'_+'), '_').trim();
    final roomTag = cleanNum.startsWith('room') ? cleanNum : 'room_$cleanNum';
    final bShort = getDepartmentShortName(buildingName).toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    final newRoomId = '${bShort}_$roomTag';
    final newRoom = Classroom(
      id: newRoomId,
      roomNumber: roomNum,
      name: _selectedArchetype,
      building: buildingName,
      floor: 'Fl 1',
      isOccupied: false,
      occupancyCeiling: _capacity,
      currentOccupancy: 0,
      gatewayId: 'HUB-ESP32-MESH',
      roomType: _selectedArchetype,
      automatedSchedules: false,
      zoneCount: _selectedZoneCount,
      zones: List.generate(_selectedZoneCount, (i) => 'Zone ${i + 1}'),
      devices: [],
    );

    ClassroomState().addClassroom(newRoom);

    CyberToast.show(
      context,
      message: '$roomNum provisioned under $buildingName with $_selectedZoneCount zones.',
      type: ToastType.success,
    );

    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
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
          'Add Classroom',
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
                  'PROVISIONING',
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
            // Ambient Telemetry Line
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'NEW CLASSROOM SETUP',
                  style: AppTypography.labelSm(color: AppColors.outline),
                ),
                Text(
                  'RUET IOT SYSTEM',
                  style: AppTypography.labelSm(color: AppColors.outlineVariant),
                ),
              ],
            ),

            const SizedBox(height: 12),

            // Form Card
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: AppColors.surfaceContainer.withValues(alpha: 0.75),
                border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.meeting_room,
                            size: 18,
                            color: AppColors.primary,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Classroom Details',
                            style: AppTypography.headlineSm(color: AppColors.onSurface),
                          ),
                        ],
                      ),
                      Text(
                        'STEP 1/1',
                        style: AppTypography.labelSm(color: AppColors.onSurfaceVariant),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Divider(color: Colors.white.withValues(alpha: 0.08)),
                  const SizedBox(height: 14),

                  // Room Identifier
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'ROOM IDENTIFIER',
                        style: AppTypography.labelSm(color: AppColors.onSurfaceVariant),
                      ),
                      Text(
                        '• REQUIRED',
                        style: AppTypography.labelSm(color: AppColors.primary),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  _buildInputBox(_roomNumberController, 'e.g. Room 402', Icons.tag),

                  const SizedBox(height: 14),

                  // Building & Wing Dropdown + Custom Building
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'CAMPUS BUILDING',
                        style: AppTypography.labelSm(color: AppColors.onSurfaceVariant),
                      ),
                      if (_isCustomBuilding)
                        GestureDetector(
                          onTap: () {
                            setState(() {
                              _isCustomBuilding = false;
                              _selectedBuilding = _buildings.first;
                            });
                          },
                          child: Text(
                            'Choose Preset',
                            style: AppTypography.labelSm(color: AppColors.primary),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  if (!_isCustomBuilding) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: AppColors.surfaceContainerLowest,
                        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _buildings.contains(_selectedBuilding) ? _selectedBuilding : _buildings.first,
                          isExpanded: true,
                          dropdownColor: AppColors.surfaceContainerHigh,
                          icon: const Icon(Icons.expand_more, color: AppColors.outline),
                          style: AppTypography.bodyMd(color: AppColors.onSurface),
                          items: _buildings.map((b) {
                            final isCustomOption = b.startsWith('+');
                            return DropdownMenuItem<String>(
                              value: b,
                              child: Row(
                                children: [
                                  Icon(
                                    isCustomOption ? Icons.add_business : Icons.apartment,
                                    size: 16,
                                    color: isCustomOption ? AppColors.primary : AppColors.outline,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      b,
                                      style: TextStyle(
                                        color: isCustomOption ? AppColors.primary : AppColors.onSurface,
                                        fontWeight: isCustomOption ? FontWeight.bold : FontWeight.normal,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }).toList(),
                          onChanged: (val) {
                            if (val != null) {
                              if (val.startsWith('+')) {
                                setState(() {
                                  _isCustomBuilding = true;
                                  _customBuildingController.clear();
                                });
                              } else {
                                setState(() {
                                  _selectedBuilding = val;
                                  _isCustomBuilding = false;
                                });
                              }
                            }
                          },
                        ),
                      ),
                    ),
                  ] else ...[
                    // Custom Building Name Input Box
                    Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: AppColors.surfaceContainerLowest,
                        border: Border.all(color: AppColors.primary.withValues(alpha: 0.5)),
                      ),
                      child: TextField(
                        controller: _customBuildingController,
                        autofocus: true,
                        style: AppTypography.bodyMd(color: AppColors.onSurface),
                        decoration: InputDecoration(
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                          prefixIcon: const Icon(Icons.apartment, size: 16, color: AppColors.primary),
                          border: InputBorder.none,
                          hintText: 'Enter custom building name (e.g. Mechanical Lab Wing)',
                          hintStyle: AppTypography.bodySm(color: AppColors.outline),
                        ),
                      ),
                    ),
                  ],

                  const SizedBox(height: 16),

                  // Separated Control Zones
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'SEPARATED CONTROL ZONES',
                        style: AppTypography.labelSm(color: AppColors.onSurfaceVariant),
                      ),
                      Text(
                        '$_selectedZoneCount ZONES SELECTED',
                        style: AppTypography.labelSm(color: AppColors.primary),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Allows assigning separate devices per zone (e.g. Zone 1 has 3 devices, Zone 2 has 4 devices)',
                    style: AppTypography.bodySm(color: AppColors.outline).copyWith(fontSize: 11),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [1, 2, 3, 4, 5, 6, 7, 8].map((count) {
                      final isSelected = _selectedZoneCount == count;
                      return Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2.0),
                          child: GestureDetector(
                            onTap: () {
                              HapticFeedback.selectionClick();
                              setState(() => _selectedZoneCount = count);
                            },
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 140),
                              padding: const EdgeInsets.symmetric(vertical: 9),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                color: isSelected
                                    ? AppColors.primary
                                    : AppColors.surfaceContainerLowest,
                                border: Border.all(
                                  color: isSelected
                                      ? AppColors.primary
                                      : Colors.white.withValues(alpha: 0.1),
                                ),
                              ),
                              child: Center(
                                child: Text(
                                  '$count',
                                  style: AppTypography.headlineSm(
                                    color: isSelected
                                        ? AppColors.surfaceContainerLowest
                                        : AppColors.onSurface,
                                  ).copyWith(fontSize: 13, fontWeight: FontWeight.bold),
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: List.generate(_selectedZoneCount, (i) {
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          color: AppColors.surfaceContainerLowest,
                          border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.grid_view, size: 12, color: AppColors.primary),
                            const SizedBox(width: 5),
                            Text(
                              'Zone ${i + 1}',
                              style: AppTypography.labelSm(color: AppColors.primaryLight).copyWith(fontSize: 11),
                            ),
                          ],
                        ),
                      );
                    }),
                  ),

                  const SizedBox(height: 16),

                  // Room Type Archetype
                  Text(
                    'ROOM TYPE ARCHETYPE',
                    style: AppTypography.labelSm(color: AppColors.onSurfaceVariant),
                  ),
                  const SizedBox(height: 8),
                  GridView.count(
                    crossAxisCount: 2,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    childAspectRatio: 2.5,
                    children: _archetypes.map((arch) {
                      final isSelected = _selectedArchetype == arch['name'];
                      return GestureDetector(
                        onTap: () {
                          HapticFeedback.selectionClick();
                          setState(() => _selectedArchetype = arch['name'] as String);
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 140),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            color: isSelected
                                ? AppColors.surfaceContainerHigh
                                : AppColors.surfaceContainerLowest,
                            border: Border.all(
                              color: isSelected
                                  ? AppColors.primary
                                  : Colors.white.withValues(alpha: 0.08),
                            ),
                            boxShadow: isSelected
                                ? [
                                    BoxShadow(
                                      color: AppColors.primary.withValues(alpha: 0.2),
                                      blurRadius: 10,
                                    ),
                                  ]
                                : null,
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                arch['icon'] as IconData,
                                size: 16,
                                color: isSelected ? AppColors.primary : AppColors.outline,
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    arch['name'] as String,
                                    style: AppTypography.labelSm(
                                      color: isSelected ? AppColors.primary : AppColors.onSurfaceVariant,
                                    ).copyWith(fontSize: 11),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),

                  const SizedBox(height: 16),

                  // Occupancy Ceiling
                  Text(
                    'OCCUPANCY CEILING (STUDENTS)',
                    style: AppTypography.labelSm(color: AppColors.onSurfaceVariant),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      color: AppColors.surfaceContainerLowest,
                      border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.remove, size: 18),
                          onPressed: () {
                            HapticFeedback.selectionClick();
                            setState(() => _capacity = (_capacity - 5).clamp(5, 300));
                          },
                        ),
                        Text(
                          '$_capacity',
                          style: AppTypography.labelLg(color: AppColors.primary).copyWith(fontSize: 16),
                        ),
                        IconButton(
                          icon: const Icon(Icons.add, size: 18),
                          onPressed: () {
                            HapticFeedback.selectionClick();
                            setState(() => _capacity = (_capacity + 5).clamp(5, 300));
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // Primary Create Button
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
                onPressed: _createClassroom,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.add_circle, size: 20, color: AppColors.surfaceContainerLowest),
                    const SizedBox(width: 8),
                    Text(
                      'Create Classroom',
                      style: AppTypography.headlineSm(
                        color: AppColors.surfaceContainerLowest,
                      ).copyWith(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 10),

            // Cancel Button
            SizedBox(
              width: double.infinity,
              height: 44,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.onSurfaceVariant,
                  side: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () => Navigator.pop(context),
                child: Text('Cancel', style: AppTypography.bodyMd()),
              ),
            ),

            const SizedBox(height: 16),

            // Footer
            Center(
              child: Text(
                'ClassPulse IoT Provisioning System • v2.4',
                style: AppTypography.labelSm(color: AppColors.outline),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputBox(TextEditingController controller, String hint, IconData icon) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: AppColors.surfaceContainerLowest,
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: TextField(
        controller: controller,
        style: AppTypography.bodyMd(color: AppColors.onSurface),
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          prefixIcon: Icon(icon, size: 16, color: AppColors.outline),
          border: InputBorder.none,
          hintText: hint,
          hintStyle: AppTypography.bodyMd(color: AppColors.outline),
        ),
      ),
    );
  }
}
