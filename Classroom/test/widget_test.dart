import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_classroom_iot/main.dart';
import 'package:smart_classroom_iot/models/device.dart';
import 'package:smart_classroom_iot/screens/dashboard_screen.dart';
import 'package:smart_classroom_iot/screens/device_detail_screen.dart';
import 'package:smart_classroom_iot/services/mqtt_service.dart';
import 'package:smart_classroom_iot/state/classroom_state.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    MqttService().configure(broker: '127.0.0.1', port: 9, persist: false);
  });

  tearDown(() {
    ClassroomState().cancelAllTimers();
  });

  testWidgets('ClassPulseApp loads splash screen smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const ClassPulseApp());
    expect(find.text('ClassPulse'), findsOneWidget);
    expect(find.text('IOT'), findsOneWidget);
  });

  testWidgets('DeviceDetailScreen renders Fan controls and ESP32 telemetry', (WidgetTester tester) async {
    final state = ClassroomState();
    state.loadDemoData();
    final room = state.classrooms.firstWhere((r) => r.devices.any((d) => d.type == DeviceType.hvac));
    final fan = room.devices.firstWhere((d) => d.type == DeviceType.fan);

    await tester.pumpWidget(
      MaterialApp(
        home: DeviceDetailScreen(roomId: room.id, deviceId: fan.id),
      ),
    );

    expect(find.text('Device Diagnostics'), findsOneWidget);
    expect(find.text(fan.name), findsOneWidget);
    expect(find.text('Hardware Controls'), findsOneWidget);
    expect(find.text('Fan Speed Control'), findsOneWidget);
    expect(find.text('Run ESP32 Relay Self-Test'), findsOneWidget);
  });

  testWidgets('DeviceDetailScreen renders HVAC Inverter controls and temp adjustment', (WidgetTester tester) async {
    final state = ClassroomState();
    state.loadDemoData();
    final room = state.classrooms.firstWhere((r) => r.devices.any((d) => d.type == DeviceType.hvac));
    final ac = room.devices.firstWhere((d) => d.type == DeviceType.hvac);

    await tester.pumpWidget(
      MaterialApp(
        home: DeviceDetailScreen(roomId: room.id, deviceId: ac.id),
      ),
    );

    expect(find.text('Device Diagnostics'), findsOneWidget);
    expect(find.text(ac.name), findsOneWidget);
    expect(find.text('Target Temperature'), findsOneWidget);
    expect(find.text('${ac.temperature}°C'), findsNWidgets(2));
    expect(find.text('Operating Mode'), findsOneWidget);
  });

  testWidgets('DeviceDetailScreen renders Lighting bus controls and scenes', (WidgetTester tester) async {
    final state = ClassroomState();
    state.loadDemoData();
    final room = state.classrooms.firstWhere((r) => r.devices.any((d) => d.type == DeviceType.hvac));
    final light = room.devices.firstWhere((d) => d.type == DeviceType.lighting);

    await tester.pumpWidget(
      MaterialApp(
        home: DeviceDetailScreen(roomId: room.id, deviceId: light.id),
      ),
    );

    expect(find.text('Device Diagnostics'), findsOneWidget);
    expect(find.text(light.name), findsOneWidget);
    expect(find.text('Quick Lighting Scenes'), findsOneWidget);
  });

  testWidgets('DashboardScreen renders simplified main interface with bottom nav and search', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: DashboardScreen(),
      ),
    );

    expect(find.text('ClassPulse'), findsOneWidget);
    expect(find.text('Classrooms'), findsOneWidget);
    expect(find.text('Appliances'), findsOneWidget);
    expect(find.text('Network'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
  });

  test('Switchboard pin mappings match Board 1 (6 pairs), Board 2 (8 pairs), Board 3 (5 pairs)', () {
    final b1 = ClassroomDevice.switchRelayPairsForZone(1);
    expect(b1.length, 6);
    expect(b1.map((p) => [p['relayLabel'], p['gpio'], p['switchGpio']]).toList(), [
      ['In1 [L]', 16, 14],
      ['In2 [L]', 4, 27],
      ['In3 [L]', 2, 26],
      ['In4 [L]', 15, 25],
      ['In5 [R]', 21, 33],
      ['In6 [R]', 19, 34],
    ]);

    final b2 = ClassroomDevice.switchRelayPairsForZone(2);
    expect(b2.length, 8);

    final b3 = ClassroomDevice.switchRelayPairsForZone(3);
    expect(b3.length, 5);
    expect(b3.map((p) => [p['relayLabel'], p['gpio'], p['switchGpio']]).toList(), [
      ['In1', 5, 32],
      ['In2', 4, 33],
      ['In3', 2, 25],
      ['In4', 15, 26],
      ['In5', 18, 27],
    ]);

    expect(() => ClassroomDevice.defaultRelayChannelForRelay(8, boardId: 1), returnsNormally);
    expect(() => ClassroomDevice.defaultRelayChannelForRelay(8, boardId: 3), returnsNormally);

    final migrated = ClassroomDevice.fromMap({
      'id': 'dev-301-z1-r1',
      'name': 'Zone 1 Front Light 1',
      'type': 'lighting',
      'zone': 'Zone 1',
      'relayChannel': 'RELAY 1 [In4 R] (GPIO 15) ↔ S1 (D13)',
    });
    expect(migrated.relayChannel, 'RELAY 1 [In1 [L]] (GPIO 16) ↔ S1 (D14)');

    final state = ClassroomState();
    state.loadDemoData();
    final reb = state.findRoom('reb_room_301');
    expect(reb, isNotNull);
    expect(reb!.devices.any((d) => d.id == 'dev-301-z1-r5'), isTrue);
    expect(reb.devices.any((d) => d.id == 'dev-301-z1-r6'), isTrue);
    expect(reb.devices.any((d) => d.id == 'dev-301-z3-r5'), isTrue);
  });
}
