import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../state/connectivity_state.dart';
import '../state/classroom_state.dart';
import '../state/auth_state.dart';
import '../models/user_role.dart';
import '../services/mqtt_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';
import '../widgets/connectivity_sheet.dart';
import '../widgets/pulsing_beacon.dart';
import '../widgets/route_transitions.dart';
import 'auth_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final ConnectivityState _connState = ConnectivityState();

  StreamSubscription<MqttConnectionStatus>? _mqttSub;
  late final Stream<QuerySnapshot> _usersStream;

  String _selectedDeptFilter = 'ALL';
  final TextEditingController _userSearchController = TextEditingController();
  String _userSearchQuery = '';

  @override
  void initState() {
    super.initState();
    _usersStream = FirebaseFirestore.instance.collection('users').snapshots();
    _connState.addListener(_onStateChange);
    AuthState().addListener(_onStateChange);
    ClassroomState().addListener(_onStateChange);
    _mqttSub = MqttService().statusStream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _connState.removeListener(_onStateChange);
    AuthState().removeListener(_onStateChange);
    ClassroomState().removeListener(_onStateChange);
    _mqttSub?.cancel();
    _userSearchController.dispose();
    super.dispose();
  }

  void _onStateChange() {
    if (mounted) setState(() {});
  }

  String _formatSyncTime(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  void _showMqttConfigDialog() {
    final mqtt = MqttService();
    final brokerController = TextEditingController(text: mqtt.broker);
    final portController = TextEditingController(text: mqtt.port.toString());
    final topicController = TextEditingController(text: mqtt.baseTopic);

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
              const Icon(Icons.cloud_sync, color: AppColors.primary),
              const SizedBox(width: 8),
              Text(
                'MQTT Broker Configuration',
                style: AppTypography.headlineSm(color: AppColors.onSurface, fontSize: 16),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Connect to public broker or local RUET lab Mosquitto server:',
                style: AppTypography.bodySm(color: AppColors.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: brokerController,
                style: AppTypography.bodyMd(color: AppColors.onSurface),
                decoration: InputDecoration(
                  labelText: 'Broker Host / IP',
                  hintText: 'e.g. broker.emqx.io or 192.168.0.x',
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
              ),
              const SizedBox(height: 10),
              TextField(
                controller: portController,
                keyboardType: TextInputType.number,
                style: AppTypography.bodyMd(color: AppColors.onSurface),
                decoration: InputDecoration(
                  labelText: 'Port',
                  hintText: '1883',
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
              ),
              const SizedBox(height: 10),
              TextField(
                controller: topicController,
                style: AppTypography.bodyMd(color: AppColors.onSurface),
                decoration: InputDecoration(
                  labelText: 'Base Topic',
                  hintText: 'ruet/classroom',
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
                final port = int.tryParse(portController.text) ?? 1883;
                mqtt.configure(
                  broker: brokerController.text,
                  port: port,
                  baseTopic: topicController.text,
                );
                mqtt.connect();
                Navigator.pop(context);
                if (mounted) setState(() {});
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    backgroundColor: AppColors.surfaceContainerHigh,
                    content: Text(
                      'Reconnecting to ${brokerController.text}:$port...',
                      style: AppTypography.bodySm(color: AppColors.onSurface),
                    ),
                  ),
                );
              },
              child: Text('SAVE & CONNECT', style: AppTypography.labelMd()),
            ),
          ],
        );
      },
    );
  }

  void _showEditNameDialog() {
    final nameController = TextEditingController(text: AuthState().userName);

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
              const Icon(Icons.badge_outlined, color: AppColors.primary, size: 20),
              const SizedBox(width: 8),
              Text(
                'Modify Profile Name',
                style: AppTypography.headlineSm(color: AppColors.onSurface, fontSize: 17),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Update your console operator display name across Firebase and all nodes:',
                style: AppTypography.bodySm(color: AppColors.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: nameController,
                autofocus: true,
                style: AppTypography.bodyMd(color: AppColors.onSurface),
                decoration: InputDecoration(
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
                  hintText: 'Enter new name',
                ),
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
                foregroundColor: AppColors.surfaceContainerLowest,
              ),
              onPressed: () async {
                final newName = nameController.text.trim();
                if (newName.isNotEmpty) {
                  HapticFeedback.mediumImpact();
                  await AuthState().updateUserName(newName);
                  if (context.mounted) {
                    Navigator.pop(context);
                    setState(() {});
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Profile name updated in Firestore.'),
                        backgroundColor: AppColors.onlineMint,
                        duration: Duration(seconds: 2),
                      ),
                    );
                  }
                }
              },
              child: Text(
                'SAVE CHANGES',
                style: AppTypography.labelMd(color: AppColors.surfaceContainerLowest).copyWith(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    );
  }

  void _showSwitchAccountDialog() {
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
              const Icon(Icons.switch_account, color: AppColors.primary),
              const SizedBox(width: 8),
              Text(
                'Switch Accounts',
                style: AppTypography.headlineSm(color: AppColors.onSurface),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.surfaceContainerLowest,
                    border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
                  ),
                  child: const Center(child: Icon(Icons.account_circle, color: AppColors.primary, size: 20)),
                ),
                title: Text(AuthState().userName, style: AppTypography.bodySm(color: AppColors.onSurface)),
                subtitle: Text(AuthState().userEmail, style: AppTypography.labelSm(color: AppColors.outline)),
                trailing: const Icon(Icons.check, color: AppColors.onlineMint, size: 18),
              ),
              const Divider(color: Colors.white12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.add_circle_outline, color: AppColors.secondaryLight, size: 22),
                title: Text('Sign in with another Google Account', style: AppTypography.bodySm(color: AppColors.onSurface)),
                onTap: () {
                  Navigator.pop(context);
                  _signOut();
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('CLOSE', style: AppTypography.labelMd()),
            ),
          ],
        );
      },
    );
  }

  void _signOut() async {
    HapticFeedback.mediumImpact();
    await AuthState().signOut();
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        Cube3DPageRoute(page: const AuthScreen()),
        (route) => false,
      );
    }
  }

  void _showWipeConfirmationDialog() {
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
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: AppColors.errorContainer.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.warning_amber_rounded, color: AppColors.error, size: 22),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Wipe Classroom Data?',
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
                'Are you sure you want to wipe all classroom records?',
                style: AppTypography.bodySm(color: Colors.white).copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                'This will permanently delete all classrooms and device configurations from both local storage and your Firebase Cloud Database.\n\nThis action cannot be undone.',
                style: AppTypography.bodySm(color: AppColors.onSurfaceVariant),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(
                'Cancel',
                style: AppTypography.bodySm(color: AppColors.outline),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.error,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                elevation: 0,
              ),
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                Navigator.pop(context);
                HapticFeedback.heavyImpact();
                await ClassroomState().clearAllData();
                if (!mounted) return;
                messenger.showSnackBar(
                  SnackBar(
                    backgroundColor: AppColors.surfaceContainerHigh,
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(color: AppColors.error.withValues(alpha: 0.4)),
                    ),
                    content: Row(
                      children: [
                        const Icon(Icons.check_circle_outline, color: AppColors.error, size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Classroom records cleared from local storage and Firebase.',
                            style: AppTypography.bodySm(color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                    duration: const Duration(seconds: 3),
                  ),
                );
              },
              child: const Text('Wipe All Records', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  void _showAppDetailsDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.surfaceContainerHigh,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: AppColors.primary.withValues(alpha: 0.3)),
          ),
          title: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: AppColors.primaryContainer.withValues(alpha: 0.3),
                  border: Border.all(color: AppColors.primary.withValues(alpha: 0.5)),
                ),
                child: const Center(
                  child: Icon(Icons.hub_rounded, color: AppColors.primary, size: 24),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'ClassPulse IoT',
                      style: AppTypography.headlineSm(color: Colors.white).copyWith(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      'Smart Classroom Platform',
                      style: AppTypography.labelSm(color: AppColors.secondaryLight),
                    ),
                  ],
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // App Info Card
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: AppColors.surfaceContainerLowest,
                  border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                ),
                child: Column(
                  children: [
                    _buildDetailRow(
                      icon: Icons.apps_rounded,
                      label: 'App Name',
                      value: 'ClassPulse IoT',
                    ),
                    const Divider(color: Colors.white12, height: 16),
                    _buildDetailRow(
                      icon: Icons.verified_rounded,
                      label: 'Version',
                      value: 'v2.4.1 (Build 840)',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // Developer & Student Credentials Card
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: AppColors.surfaceContainerLowest,
                  border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.code_rounded, size: 16, color: AppColors.primary),
                        const SizedBox(width: 8),
                        Text(
                          'DEVELOPER',
                          style: AppTypography.labelSm(color: AppColors.outline).copyWith(
                            fontSize: 10,
                            letterSpacing: 0.8,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(6),
                            color: AppColors.secondary.withValues(alpha: 0.15),
                            border: Border.all(color: AppColors.secondary.withValues(alpha: 0.4)),
                          ),
                          child: Text(
                            'ETE-23',
                            style: AppTypography.labelSm(color: AppColors.secondaryLight).copyWith(
                              fontWeight: FontWeight.bold,
                              fontSize: 11,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Fayem Muktadir Rahman',
                      style: AppTypography.headlineSm(color: Colors.white).copyWith(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.3,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        const Icon(Icons.badge_outlined, size: 14, color: AppColors.outline),
                        const SizedBox(width: 6),
                        Text(
                          'Roll: ',
                          style: AppTypography.bodySm(color: AppColors.onSurfaceVariant).copyWith(fontSize: 12),
                        ),
                        Text(
                          '2304005',
                          style: AppTypography.bodySm(color: AppColors.primaryLight).copyWith(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primaryContainer.withValues(alpha: 0.4),
                  foregroundColor: AppColors.primary,
                  side: BorderSide(color: AppColors.primary.withValues(alpha: 0.5)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () => Navigator.pop(context),
                child: const Text('Close', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildDetailRow({
    required IconData icon,
    required String label,
    required String value,
    bool highlightValue = false,
  }) {
    return Row(
      children: [
        Icon(icon, size: 18, color: highlightValue ? AppColors.secondaryLight : AppColors.outline),
        const SizedBox(width: 10),
        Text(label, style: AppTypography.bodySm(color: AppColors.onSurfaceVariant)),
        const Spacer(),
        Text(
          value,
          style: AppTypography.bodySm(
            color: highlightValue ? AppColors.secondaryLight : Colors.white,
          ).copyWith(fontWeight: highlightValue ? FontWeight.bold : FontWeight.w600),
        ),
      ],
    );
  }

  void _showRoleSwitchBottomSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.manage_accounts_rounded, color: AppColors.primary),
                  const SizedBox(width: 10),
                  Text('Console Role & Privileges', style: AppTypography.headlineSm(fontSize: 16)),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Switch console role between full system administrator and teacher operational mode.',
                style: AppTypography.bodySm(color: AppColors.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              ListTile(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                tileColor: AuthState().isAdmin ? AppColors.primary.withValues(alpha: 0.15) : AppColors.surfaceContainerLowest,
                leading: const Icon(Icons.admin_panel_settings_rounded, color: AppColors.primary),
                title: const Text('Administrator Mode', style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.primary)),
                subtitle: const Text('Full layout, hardware provisioning, pin mapping & cloud directory', style: TextStyle(fontSize: 11, color: AppColors.onSurfaceVariant)),
                trailing: AuthState().isAdmin ? const Icon(Icons.check_circle, color: AppColors.primary) : null,
                onTap: () async {
                  Navigator.pop(ctx);
                  await AuthState().setUserRole(UserRole.admin);
                  setState(() {});
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Switched to Administrator Mode. Role synced to Firebase.'), backgroundColor: AppColors.primary),
                    );
                  }
                },
              ),
              const SizedBox(height: 8),
              ListTile(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                tileColor: AuthState().isTeacher ? AppColors.onlineMint.withValues(alpha: 0.15) : AppColors.surfaceContainerLowest,
                leading: const Icon(Icons.school_rounded, color: AppColors.onlineMint),
                title: const Text('Teacher Mode', style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.onlineMint)),
                subtitle: const Text('Classroom monitoring and live appliance controls only', style: TextStyle(fontSize: 11, color: AppColors.onSurfaceVariant)),
                trailing: AuthState().isTeacher ? const Icon(Icons.check_circle, color: AppColors.onlineMint) : null,
                onTap: () async {
                  Navigator.pop(ctx);
                  await AuthState().setUserRole(UserRole.teacher);
                  setState(() {});
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Switched to Teacher Mode. Role synced to Firebase.'), backgroundColor: AppColors.onlineMint),
                    );
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCampusDirectorySection() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: AppColors.surfaceContainerLow,
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
                  const Icon(Icons.hub_rounded, size: 16, color: AppColors.primary),
                  const SizedBox(width: 8),
                  Text(
                    'Campus Directory & Roles',
                    style: AppTypography.bodySm(color: AppColors.onSurface)
                        .copyWith(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  color: AppColors.primary.withValues(alpha: 0.15),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.cloud_done_rounded, size: 10, color: AppColors.primary),
                    const SizedBox(width: 4),
                    Text(
                      'FIREBASE',
                      style: AppTypography.labelSm(color: AppColors.primary)
                          .copyWith(fontSize: 8.5, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Accounts registered in Firebase cloud database. Assign roles and filter by department.',
            style: AppTypography.bodySm(color: AppColors.onSurfaceVariant).copyWith(fontSize: 10.5),
          ),
          const SizedBox(height: 10),

          // Search Field
          Container(
            height: 42,
            decoration: BoxDecoration(
              color: AppColors.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: TextField(
              controller: _userSearchController,
              textAlignVertical: TextAlignVertical.center,
              onChanged: (val) => setState(() => _userSearchQuery = val.trim()),
              style: AppTypography.bodySm(color: AppColors.onSurface).copyWith(fontSize: 12.5),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Search by name, email, or dept...',
                hintStyle: AppTypography.bodySm(color: AppColors.outline).copyWith(fontSize: 12),
                prefixIconConstraints: const BoxConstraints(minWidth: 38, minHeight: 38, maxWidth: 38, maxHeight: 38),
                prefixIcon: const Icon(Icons.search, size: 16, color: AppColors.outline),
                suffixIconConstraints: const BoxConstraints(minWidth: 34, minHeight: 34, maxWidth: 34, maxHeight: 34),
                suffixIcon: _userSearchQuery.isNotEmpty
                    ? IconButton(
                        padding: EdgeInsets.zero,
                        icon: const Icon(Icons.close, size: 14, color: AppColors.outline),
                        onPressed: () {
                          _userSearchController.clear();
                          setState(() => _userSearchQuery = '');
                        },
                      )
                    : null,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                border: InputBorder.none,
              ),
            ),
          ),
          const SizedBox(height: 10),

          // Stream from Firebase Firestore 'users' collection
          StreamBuilder<QuerySnapshot>(
            stream: _usersStream,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: AppColors.errorContainer.withValues(alpha: 0.2),
                    border: Border.all(color: AppColors.error.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline, size: 16, color: AppColors.error),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Firestore stream error: ${snapshot.error}',
                          style: AppTypography.bodySm(color: AppColors.error).copyWith(fontSize: 10),
                        ),
                      ),
                    ],
                  ),
                );
              }

              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
                    ),
                  ),
                );
              }

              final docs = snapshot.data?.docs ?? [];
              if (docs.isEmpty) {
                return Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: AppColors.surfaceContainerLowest,
                  ),
                  child: Center(
                    child: Text(
                      'No accounts registered in Firebase users collection yet.',
                      style: AppTypography.bodySm(color: AppColors.outline).copyWith(fontSize: 11),
                    ),
                  ),
                );
              }

              // Collect all unique departments present
              final Set<String> deptSet = {};
              for (final doc in docs) {
                final data = doc.data() as Map<String, dynamic>? ?? {};
                final d = (data['department']?.toString().trim().isNotEmpty ?? false)
                    ? data['department'].toString().trim()
                    : 'General Administration';
                deptSet.add(d);
              }
              final List<String> allDepts = deptSet.toList()..sort();

              // Department Filter Chips
              final filterChips = <Widget>[
                _buildDeptFilterChip('ALL', docs.length),
                ...allDepts.map((d) {
                  final count = docs.where((doc) {
                    final data = doc.data() as Map<String, dynamic>? ?? {};
                    final dept = (data['department']?.toString().trim().isNotEmpty ?? false)
                        ? data['department'].toString().trim()
                        : 'General Administration';
                    return dept == d;
                  }).length;
                  // Shorten department name for chip using getDepartmentShortName
                  final label = getDepartmentShortName(d);
                  return _buildDeptFilterChip(d, count, customLabel: label);
                }),
              ];

              // Filter docs by search and selected department
              final filteredDocs = docs.where((doc) {
                final data = doc.data() as Map<String, dynamic>? ?? {};
                final name = (data['displayName'] ?? '').toString().toLowerCase();
                final email = (data['email'] ?? '').toString().toLowerCase();
                final dept = (data['department'] ?? 'General Administration').toString();
                final q = _userSearchQuery.toLowerCase();
                final matchesQuery = q.isEmpty ||
                    name.contains(q) ||
                    email.contains(q) ||
                    dept.toLowerCase().contains(q);
                final matchesDept = _selectedDeptFilter == 'ALL' || dept == _selectedDeptFilter;
                return matchesQuery && matchesDept;
              }).toList();

              // Group filtered docs by department
              final Map<String, List<QueryDocumentSnapshot>> grouped = {};
              for (final doc in filteredDocs) {
                final data = doc.data() as Map<String, dynamic>? ?? {};
                final dept = (data['department']?.toString().trim().isNotEmpty ?? false)
                    ? data['department'].toString().trim()
                    : 'General Administration';
                grouped.putIfAbsent(dept, () => []).add(doc);
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    child: Row(children: filterChips),
                  ),
                  const SizedBox(height: 12),
                  if (grouped.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Center(
                        child: Text(
                          'No users match your query or filter.',
                          style: AppTypography.bodySm(color: AppColors.outline).copyWith(fontSize: 11),
                        ),
                      ),
                    )
                  else
                    ...grouped.entries.map((entry) => _buildDepartmentAccountGroup(entry.key, entry.value)),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildDeptFilterChip(String deptKey, int count, {String? customLabel}) {
    final isSelected = _selectedDeptFilter == deptKey;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          setState(() => _selectedDeptFilter = deptKey);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: isSelected ? AppColors.primary.withValues(alpha: 0.2) : AppColors.surfaceContainerLowest,
            border: Border.all(
              color: isSelected ? AppColors.primary : Colors.white.withValues(alpha: 0.08),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                customLabel ?? deptKey,
                style: AppTypography.labelSm(
                  color: isSelected ? AppColors.primary : AppColors.onSurfaceVariant,
                ).copyWith(fontSize: 10, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal),
              ),
              const SizedBox(width: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  color: isSelected ? AppColors.primary.withValues(alpha: 0.3) : Colors.white.withValues(alpha: 0.08),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 8.5,
                    fontWeight: FontWeight.bold,
                    color: isSelected ? AppColors.primary : AppColors.outline,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDepartmentAccountGroup(String deptName, List<QueryDocumentSnapshot> userDocs) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: AppColors.surfaceContainerLowest,
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Dept Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.surfaceContainerHigh.withValues(alpha: 0.4),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(9)),
            ),
            child: Row(
              children: [
                const Icon(Icons.domain_rounded, size: 14, color: AppColors.secondaryLight),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    deptName,
                    style: AppTypography.labelSm(color: AppColors.onSurface).copyWith(
                      fontWeight: FontWeight.bold,
                      fontSize: 11,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    color: AppColors.secondaryContainer.withValues(alpha: 0.3),
                  ),
                  child: Text(
                    '${userDocs.length} ${userDocs.length == 1 ? 'user' : 'users'}',
                    style: AppTypography.labelSm(color: AppColors.secondaryLight).copyWith(fontSize: 8.5),
                  ),
                ),
              ],
            ),
          ),
          const Divider(color: Colors.white10, height: 1),
          // User Rows
          ...userDocs.map((doc) => _buildUserRow(doc)),
        ],
      ),
    );
  }

  Widget _buildUserRow(QueryDocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    final name = (data['displayName'] ?? 'Unnamed Operator').toString();
    final email = (data['email'] ?? doc.id).toString();
    final roleCode = data['role']?.toString();
    final userRole = UserRole.fromCode(roleCode);
    final isCurrent = FirebaseAuth.instance.currentUser?.uid == doc.id;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.white10, width: 0.5)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: userRole == UserRole.admin
                ? AppColors.primary.withValues(alpha: 0.2)
                : AppColors.onlineMint.withValues(alpha: 0.2),
            child: Text(
              name.isNotEmpty ? name.substring(0, 1).toUpperCase() : 'U',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: userRole == UserRole.admin ? AppColors.primary : AppColors.onlineMint,
              ),
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
                        name,
                        style: AppTypography.bodySm(color: AppColors.onSurface).copyWith(
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isCurrent) ...[
                      const SizedBox(width: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(3),
                          color: AppColors.primary.withValues(alpha: 0.2),
                        ),
                        child: const Text('YOU', style: TextStyle(fontSize: 7.5, color: AppColors.primary, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ],
                ),
                Text(
                  email,
                  style: AppTypography.labelSm(color: AppColors.onSurfaceVariant).copyWith(fontSize: 10),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Role Badge and Action
          PopupMenuButton<String>(
            tooltip: 'Assign Role / Reassign Dept',
            color: AppColors.surfaceContainerHigh,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(color: AppColors.primary.withValues(alpha: 0.3)),
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                color: userRole == UserRole.admin
                    ? AppColors.primary.withValues(alpha: 0.15)
                    : AppColors.onlineMint.withValues(alpha: 0.15),
                border: Border.all(
                  color: userRole == UserRole.admin
                      ? AppColors.primary.withValues(alpha: 0.4)
                      : AppColors.onlineMint.withValues(alpha: 0.4),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    userRole == UserRole.admin ? Icons.admin_panel_settings_rounded : Icons.school_rounded,
                    size: 12,
                    color: userRole == UserRole.admin ? AppColors.primary : AppColors.onlineMint,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    userRole.badgeLabel,
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                      color: userRole == UserRole.admin ? AppColors.primary : AppColors.onlineMint,
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(
                    Icons.arrow_drop_down,
                    size: 14,
                    color: userRole == UserRole.admin ? AppColors.primary : AppColors.onlineMint,
                  ),
                ],
              ),
            ),
            itemBuilder: (ctx) => [
              PopupMenuItem(
                value: 'admin',
                child: Row(
                  children: [
                    Icon(Icons.admin_panel_settings_rounded, size: 16, color: userRole == UserRole.admin ? AppColors.primary : AppColors.outline),
                    const SizedBox(width: 8),
                    Text(
                      'Assign Administrator',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: userRole == UserRole.admin ? FontWeight.bold : FontWeight.normal,
                        color: userRole == UserRole.admin ? AppColors.primary : Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'teacher',
                child: Row(
                  children: [
                    Icon(Icons.school_rounded, size: 16, color: userRole == UserRole.teacher ? AppColors.onlineMint : AppColors.outline),
                    const SizedBox(width: 8),
                    Text(
                      'Assign Teacher',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: userRole == UserRole.teacher ? FontWeight.bold : FontWeight.normal,
                        color: userRole == UserRole.teacher ? AppColors.onlineMint : Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'reassign_dept',
                child: const Row(
                  children: [
                    Icon(Icons.domain_rounded, size: 16, color: AppColors.secondaryLight),
                    SizedBox(width: 8),
                    Text('Reassign Department', style: TextStyle(fontSize: 12, color: Colors.white)),
                  ],
                ),
              ),
            ],
            onSelected: (action) async {
              if (action == 'admin') {
                HapticFeedback.selectionClick();
                await AuthState().updateUserRoleByAdmin(doc.id, UserRole.admin);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Assigned Administrator role to $name'),
                      backgroundColor: AppColors.primary,
                      duration: const Duration(seconds: 2),
                    ),
                  );
                }
              } else if (action == 'teacher') {
                HapticFeedback.selectionClick();
                await AuthState().updateUserRoleByAdmin(doc.id, UserRole.teacher);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Assigned Teacher role to $name'),
                      backgroundColor: AppColors.onlineMint,
                      duration: const Duration(seconds: 2),
                    ),
                  );
                }
              } else if (action == 'reassign_dept') {
                _showReassignDepartmentDialog(doc.id, name, data['department']?.toString() ?? 'General Administration');
              }
            },
          ),
        ],
      ),
    );
  }

  void _showReassignDepartmentDialog(String uid, String userName, String currentDept) {
    String pickedDept = currentDept;
    showDialog(
      context: context,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              backgroundColor: AppColors.surfaceContainerHigh,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: AppColors.primary.withValues(alpha: 0.3)),
              ),
              title: Row(
                children: [
                  const Icon(Icons.domain_rounded, color: AppColors.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Reassign Department',
                      style: AppTypography.headlineSm(fontSize: 15),
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Assign department for $userName:',
                      style: AppTypography.bodySm(color: AppColors.onSurfaceVariant).copyWith(fontSize: 12),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      constraints: const BoxConstraints(maxHeight: 240),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: kCampusDepartments.length,
                        itemBuilder: (c, idx) {
                          final dept = kCampusDepartments[idx];
                          final isSelected = dept == pickedDept;
                          return ListTile(
                            dense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                            title: Text(
                              dept,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: isSelected ? AppColors.primary : AppColors.onSurface,
                                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                              ),
                            ),
                            leading: Icon(
                              isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
                              size: 16,
                              color: isSelected ? AppColors.primary : AppColors.outline,
                            ),
                            onTap: () => setDialogState(() => pickedDept = dept),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogCtx),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: AppColors.surfaceContainerLowest,
                  ),
                  onPressed: () async {
                    Navigator.pop(dialogCtx);
                    await AuthState().updateUserDepartmentByAdmin(uid, pickedDept);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Reassigned $userName to $pickedDept'),
                          backgroundColor: AppColors.primary,
                        ),
                      );
                    }
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
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
            child: const Icon(Icons.arrow_back_ios_new, size: 16, color: AppColors.primary),
          ),
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Root', style: AppTypography.labelSm(color: AppColors.onSurfaceVariant)),
                const Icon(Icons.chevron_right, size: 12, color: AppColors.outline),
                Text('System', style: AppTypography.labelSm(color: AppColors.primary)),
              ],
            ),
            Text(
              'Settings',
              style: AppTypography.headlineSm(color: AppColors.primary),
            ),
          ],
        ),
        actions: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: AppColors.surfaceContainerLow,
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const PulsingBeacon(size: 6, color: AppColors.onlineMint),
                const SizedBox(width: 6),
                Text(
                  'SYS:OK',
                  style: AppTypography.labelSm(color: AppColors.onSurfaceVariant),
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
            // User Profile Card
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: AppColors.surfaceContainer,
                border: Border.all(color: AppColors.primary.withValues(alpha: 0.2)),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.primary.withValues(alpha: 0.08),
                    blurRadius: 20,
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Stack(
                        children: [
                          Container(
                            width: 50,
                            height: 50,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: AppColors.surfaceContainerHigh,
                              border: Border.all(
                                color: (AuthState().isAdmin ? AppColors.primary : AppColors.onlineMint).withValues(alpha: 0.4),
                              ),
                            ),
                            child: Center(
                              child: Text(
                                AuthState().userName.isNotEmpty
                                    ? AuthState().userName.substring(0, 1).toUpperCase()
                                    : 'A',
                                style: AppTypography.headlineSm(
                                  color: AuthState().isAdmin ? AppColors.primary : AppColors.onlineMint,
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: PulsingBeacon(
                              size: 8,
                              color: AuthState().isAdmin ? AppColors.primary : AppColors.onlineMint,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    AuthState().userName,
                                    style: AppTypography.headlineSm(fontSize: 15),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.edit, size: 16, color: AppColors.primary),
                                  tooltip: 'Modify Name',
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                  onPressed: _showEditNameDialog,
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              AuthState().userEmail,
                              style: AppTypography.bodySm(color: AppColors.onSurfaceVariant),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Divider(color: Colors.white10, height: 1),
                  const SizedBox(height: 10),
                  // Full-width Meta / Badges Bar
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // Department Badge
                      Flexible(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            color: AppColors.surfaceContainerLowest,
                            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.domain_rounded, size: 12, color: AppColors.secondaryLight),
                              const SizedBox(width: 5),
                              Flexible(
                                child: Text(
                                  AuthState().userDepartmentShort,
                                  style: AppTypography.labelSm(color: AppColors.secondaryLight).copyWith(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Role Badge - tap to switch/elevate role anytime
                      GestureDetector(
                        onTap: () {
                          HapticFeedback.selectionClick();
                          _showRoleSwitchBottomSheet();
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            color: AuthState().isAdmin
                                ? AppColors.primary.withValues(alpha: 0.18)
                                : AppColors.onlineMint.withValues(alpha: 0.18),
                            border: Border.all(
                              color: AuthState().isAdmin
                                  ? AppColors.primary.withValues(alpha: 0.5)
                                  : AppColors.onlineMint.withValues(alpha: 0.5),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                AuthState().isAdmin ? Icons.admin_panel_settings_rounded : Icons.school_rounded,
                                size: 13,
                                color: AuthState().isAdmin ? AppColors.primary : AppColors.onlineMint,
                              ),
                              const SizedBox(width: 5),
                              Text(
                                AuthState().isAdmin ? 'ADMINISTRATOR' : 'TEACHER',
                                style: AppTypography.labelSm(
                                  color: AuthState().isAdmin ? AppColors.primary : AppColors.onlineMint,
                                ).copyWith(fontSize: 9.5, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                              ),
                              const SizedBox(width: 4),
                              Icon(
                                Icons.swap_horiz_rounded,
                                size: 12,
                                color: AuthState().isAdmin ? AppColors.primary : AppColors.onlineMint,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            if (AuthState().isTeacher) ...[
              const SizedBox(height: 12),
              GestureDetector(
                onTap: () async {
                  HapticFeedback.selectionClick();
                  final messenger = ScaffoldMessenger.of(context);
                  await AuthState().setUserRole(UserRole.admin);
                  setState(() {});
                  messenger.showSnackBar(
                    const SnackBar(
                      content: Text('Switched to Administrator Mode. Full console and role management unlocked.'),
                      backgroundColor: AppColors.primary,
                    ),
                  );
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: AppColors.surfaceContainerLow,
                    border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          color: AppColors.primary.withValues(alpha: 0.15),
                        ),
                        child: const Icon(Icons.admin_panel_settings_rounded, size: 16, color: AppColors.primary),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Switch to Administrator Console',
                              style: AppTypography.labelSm(color: AppColors.primary).copyWith(fontWeight: FontWeight.bold),
                            ),
                            Text(
                              'Tap to regain full administrative privileges and cloud directory access',
                              style: AppTypography.bodySm(color: AppColors.onSurfaceVariant).copyWith(fontSize: 10),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.arrow_forward_ios_rounded, size: 12, color: AppColors.primary),
                    ],
                  ),
                ),
              ),
            ],

            if (AuthState().isAdmin) ...[
              const SizedBox(height: 12),

              // Active Console Role Switcher Card (Admin only)
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: AppColors.surfaceContainerLow,
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
                            Icon(
                              AuthState().isAdmin ? Icons.admin_panel_settings_rounded : Icons.school_rounded,
                              size: 16,
                              color: AuthState().isAdmin ? AppColors.primary : AppColors.onlineMint,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Active Console Role',
                              style: AppTypography.bodySm(color: AppColors.onSurface)
                                  .copyWith(fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(4),
                            color: AuthState().isAdmin
                                ? AppColors.primary.withValues(alpha: 0.15)
                                : AppColors.onlineMint.withValues(alpha: 0.15),
                          ),
                          child: Text(
                            AuthState().userRole.displayName,
                            style: AppTypography.labelSm(
                              color: AuthState().isAdmin ? AppColors.primary : AppColors.onlineMint,
                            ).copyWith(fontSize: 9, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      AuthState().isAdmin
                          ? 'Administrator: Full layout enabled. You can add classrooms, provision switchboards, remap pins, and delete hardware.'
                          : 'Teacher: Operational control only. You can view all classrooms, zones, and control appliances. Setup & destructive actions are locked.',
                      style: AppTypography.bodySm(color: AppColors.onSurfaceVariant).copyWith(fontSize: 11),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AuthState().isAdmin
                                  ? AppColors.primary
                                  : AppColors.surfaceContainerHigh,
                              foregroundColor: AuthState().isAdmin
                                  ? AppColors.surfaceContainerLowest
                                  : AppColors.onSurface,
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            onPressed: () {
                              HapticFeedback.selectionClick();
                              AuthState().setUserRole(UserRole.admin);
                              setState(() {});
                            },
                            icon: const Icon(Icons.admin_panel_settings_rounded, size: 14),
                            label: const Text('Admin Mode', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AuthState().isTeacher
                                  ? AppColors.onlineMint
                                  : AppColors.surfaceContainerHigh,
                              foregroundColor: AuthState().isTeacher
                                  ? AppColors.surfaceContainerLowest
                                  : AppColors.onSurface,
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            onPressed: () {
                              HapticFeedback.selectionClick();
                              AuthState().setUserRole(UserRole.teacher);
                              setState(() {});
                            },
                            icon: const Icon(Icons.school_rounded, size: 14),
                            label: const Text('Teacher Mode', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 14),

              // Campus Directory & Role Management Section (Firebase)
              _buildCampusDirectorySection(),
            ],

            const SizedBox(height: 20),

            // IoT & Gateway Telemetry Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Icon(Icons.hub, size: 16, color: AppColors.primary),
                    const SizedBox(width: 6),
                    Text(
                      'NETWORK & MQTT GATEWAY',
                      style: AppTypography.labelSm(color: AppColors.primary).copyWith(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                Text('CONTROLLER #01', style: AppTypography.labelSm(color: AppColors.outline)),
              ],
            ),
            const SizedBox(height: 8),

            // IoT Section Container
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: AppColors.surfaceContainer,
                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              ),
              child: Column(
                children: [
                  // Gateway Status Cardlet
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('ESP32 Gateway', style: AppTypography.bodyMd().copyWith(fontWeight: FontWeight.w500)),
                            Text('ESP32 Switchboard Controller', style: AppTypography.bodySm(color: AppColors.onSurfaceVariant)),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          color: AppColors.surfaceContainerHigh,
                          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                        ),
                        child: Row(
                          children: [
                            PulsingBeacon(
                              size: 5,
                              color: MqttService().isConnected ? AppColors.onlineMint : AppColors.telemetryAmber,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              MqttService().isConnected ? 'ONLINE' : 'STANDBY',
                              style: AppTypography.labelSm(
                                color: MqttService().isConnected ? AppColors.onlineMint : AppColors.telemetryAmber,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Divider(color: Colors.white.withValues(alpha: 0.06)),
                  const SizedBox(height: 10),

                  // Wi-Fi Connection Launcher Tile
                  GestureDetector(
                    onTap: () => ConnectivitySheet.show(context, initialTab: 0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              const Icon(Icons.wifi, size: 18, color: AppColors.primary),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Wi-Fi Mesh Link', style: AppTypography.bodyMd(fontSize: 13)),
                                    Text(
                                      _connState.isWifiEnabled ? _connState.connectedSsid : 'Disabled',
                                      style: AppTypography.bodySm(color: AppColors.primary).copyWith(fontSize: 11),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('CONFIGURE', style: AppTypography.labelSm(color: AppColors.primary)),
                            const Icon(Icons.chevron_right, size: 14, color: AppColors.primary),
                          ],
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),
                  Divider(color: Colors.white.withValues(alpha: 0.06)),
                  const SizedBox(height: 10),

                  // MQTT Hardware Mesh Bridge Tile
                  GestureDetector(
                    onTap: _showMqttConfigDialog,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              const Icon(Icons.cloud_sync, size: 18, color: AppColors.secondary),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Text('MQTT Hardware Mesh', style: AppTypography.bodyMd(fontSize: 13)),
                                        const SizedBox(width: 8),
                                        PulsingBeacon(
                                          size: 5,
                                          color: MqttService().isConnected
                                              ? AppColors.onlineMint
                                              : (MqttService().status == MqttConnectionStatus.connecting
                                                  ? AppColors.telemetryAmber
                                                  : AppColors.error),
                                        ),
                                      ],
                                    ),
                                    Text(
                                      '${MqttService().broker}:${MqttService().port} · ${MqttService().isConnected ? "Online" : "Disconnected"}',
                                      style: AppTypography.bodySm(
                                        color: MqttService().isConnected
                                            ? AppColors.onlineMint
                                            : AppColors.onSurfaceVariant,
                                      ).copyWith(fontSize: 11),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              MqttService().isConnected ? 'CONFIGURE' : 'CONNECT',
                              style: AppTypography.labelSm(
                                color: MqttService().isConnected ? AppColors.primary : AppColors.secondary,
                              ),
                            ),
                            const Icon(Icons.chevron_right, size: 14, color: AppColors.primary),
                          ],
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),
                  Divider(color: Colors.white.withValues(alpha: 0.06)),
                  const SizedBox(height: 10),

                  // Class Session Auto-Sync Indicator (3 intervals in a 50-minute class session, zero manual buttons)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            const Icon(Icons.sync_rounded, size: 18, color: AppColors.onlineMint),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Class Session Auto-Sync',
                                    style: AppTypography.bodyMd(fontSize: 13),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    ClassroomState().lastClassIntervalSyncTime != null
                                        ? 'Interval ${ClassroomState().currentClassInterval} of 3 · Synced ${_formatSyncTime(ClassroomState().lastClassIntervalSyncTime!)}'
                                        : 'Interval ${ClassroomState().currentClassInterval} of 3 · Auto (3x / 50m)',
                                    style: AppTypography.bodySm(color: AppColors.onSurfaceVariant).copyWith(fontSize: 11),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          color: AppColors.onlineMint.withValues(alpha: 0.12),
                          border: Border.all(color: AppColors.onlineMint.withValues(alpha: 0.3)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const PulsingBeacon(color: AppColors.onlineMint, size: 5),
                            const SizedBox(width: 5),
                            Text(
                              'AUTO',
                              style: AppTypography.labelSm(color: AppColors.onlineMint).copyWith(
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // Client Preferences
            Row(
              children: [
                const Icon(Icons.settings_applications, size: 16, color: AppColors.primary),
                const SizedBox(width: 6),
                Text(
                  'CLIENT PREFERENCES',
                  style: AppTypography.labelSm(color: AppColors.primary).copyWith(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 8),

            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: AppColors.surfaceContainer,
                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              ),
              child: Column(
                children: [
                  // Interface Visual Mode
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    'Interface Visual Mode',
                                    style: AppTypography.bodyMd().copyWith(fontWeight: FontWeight.w500),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                const Icon(Icons.lock, size: 12, color: AppColors.outline),
                              ],
                            ),
                            Text(
                              'Low-glare auditorium dark mode',
                              style: AppTypography.bodySm(color: AppColors.onSurfaceVariant),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          color: AppColors.surfaceContainerLow,
                          border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const PulsingBeacon(size: 6, color: AppColors.secondary),
                            const SizedBox(width: 6),
                            Text(
                              'DARK INDIGO',
                              style: AppTypography.labelSm(color: AppColors.secondaryLight).copyWith(fontSize: 9),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Divider(color: Colors.white.withValues(alpha: 0.06)),
                  const SizedBox(height: 10),

                  // Version info
                  InkWell(
                    onTap: _showAppDetailsDialog,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Text('Firmware & App Version', style: AppTypography.bodySm(color: AppColors.onSurfaceVariant)),
                              const SizedBox(width: 6),
                              const Icon(Icons.info_outline, size: 14, color: AppColors.secondaryLight),
                            ],
                          ),
                          Text('v2.4.1 - Build 840', style: AppTypography.labelSm(color: AppColors.secondaryLight)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // Danger Zone & Account Operations
            // Switch Accounts Operation
            SizedBox(
              width: double.infinity,
              height: 48,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  backgroundColor: AppColors.surfaceContainerLow,
                  foregroundColor: AppColors.secondary,
                  side: BorderSide(color: AppColors.secondary.withValues(alpha: 0.3)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _showSwitchAccountDialog,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.switch_account, size: 18),
                    const SizedBox(width: 8),
                    Text('Switch Accounts', style: AppTypography.bodyMd().copyWith(fontSize: 13, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 10),

            if (AuthState().isAdmin) ...[
              // Clear Database Action
              SizedBox(
                width: double.infinity,
                height: 44,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    backgroundColor: AppColors.surfaceContainerLow,
                    foregroundColor: AppColors.error,
                    side: BorderSide(color: AppColors.error.withValues(alpha: 0.25)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _showWipeConfirmationDialog,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.delete_sweep, size: 16, color: AppColors.error),
                      const SizedBox(width: 8),
                      Text('Wipe All Classroom Records', style: AppTypography.bodySm(color: AppColors.error).copyWith(fontWeight: FontWeight.w500)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],

            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.errorContainer.withValues(alpha: 0.25),
                  foregroundColor: AppColors.error,
                  side: BorderSide(color: AppColors.error.withValues(alpha: 0.5)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 0,
                ),
                onPressed: _signOut,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.logout, size: 18, color: AppColors.error),
                    const SizedBox(width: 8),
                    Text(
                      'Sign Out of ClassPulse Session',
                      style: AppTypography.headlineSm(color: AppColors.error).copyWith(fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 12),

            // App Details & Information Option
            SizedBox(
              width: double.infinity,
              height: 46,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  backgroundColor: AppColors.surfaceContainerLow,
                  foregroundColor: AppColors.primary,
                  side: BorderSide(color: AppColors.primary.withValues(alpha: 0.35)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _showAppDetailsDialog,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.info_outline_rounded, size: 18, color: AppColors.primary),
                    const SizedBox(width: 8),
                    Text(
                      'App Details & Information',
                      style: AppTypography.bodySm(color: AppColors.onSurface).copyWith(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
