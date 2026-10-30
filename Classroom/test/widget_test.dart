import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_classroom_iot/main.dart';
import 'package:smart_classroom_iot/models/device.dart';
import 'package:smart_classroom_iot/screens/device_detail_screen.dart';
import 'package:smart_classroom_iot/state/classroom_state.dart';

void main() {
  testWidgets('ClassPulseApp loads splash screen smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const ClassPulseApp());
    expect(find.text('ClassPulse'), findsOneWidget);
    expect(find.text('IOT'), findsOneWidget);
  });

  testWidgets('DeviceDetailScreen renders Fan controls and ESP32 telemetry', (WidgetTester tester) async {
    final state = ClassroomState();
    state.loadDemoData();
    final room = state.classrooms.first;
    final fan = room.devices.firstWhere((d) => d.type == DeviceType.fan);

    await tester.pumpWidget(
      MaterialApp(
        home: DeviceDetailScreen(roomId: room.id, deviceId: fan.id),
      ),
    );

    expect(find.text('Device Diagnostics'), findsOneWidget);
    expect(find.text(fan.name), findsOneWidget);
    expect(find.text('Hardware Controls'), findsOneWidget);
    expect(find.text('Airflow Direction'), findsOneWidget);
    expect(find.text('Run ESP32 Relay Self-Test'), findsOneWidget);
  });

  testWidgets('DeviceDetailScreen renders HVAC Inverter controls and temp adjustment', (WidgetTester tester) async {
    final state = ClassroomState();
    state.loadDemoData();
    final room = state.classrooms.first;
    final ac = room.devices.firstWhere((d) => d.type == DeviceType.hvac);

    await tester.pumpWidget(
      MaterialApp(
        home: DeviceDetailScreen(roomId: room.id, deviceId: ac.id),
      ),
    );

    expect(find.text('Device Diagnostics'), findsOneWidget);
    expect(find.text(ac.name), findsOneWidget);
    expect(find.text('Inverter Target Temperature'), findsOneWidget);
    expect(find.text('${ac.temperature}°C'), findsNWidgets(2));
    expect(find.text('Operating Mode'), findsOneWidget);
  });

  testWidgets('DeviceDetailScreen renders Lighting bus controls and scenes', (WidgetTester tester) async {
    final state = ClassroomState();
    state.loadDemoData();
    final room = state.classrooms.first;
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
}
