// Renders every screen in both themes at several phone widths using the
// app's real fonts, and fails if anything overflows or throws during layout.
//
// Set the SCREENSHOT_DIR environment variable to also write a PNG of each
// render there, e.g.
//   SCREENSHOT_DIR=/tmp/shots flutter test test/layout_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_classroom_iot/models/classroom.dart';
import 'package:smart_classroom_iot/models/device.dart';
import 'package:smart_classroom_iot/models/user_role.dart';
import 'package:smart_classroom_iot/screens/add_classroom_screen.dart';
import 'package:smart_classroom_iot/screens/add_device_screen.dart';
import 'package:smart_classroom_iot/screens/auth_screen.dart';
import 'package:smart_classroom_iot/screens/dashboard_screen.dart';
import 'package:smart_classroom_iot/screens/device_detail_screen.dart';
import 'package:smart_classroom_iot/screens/room_control_screen.dart';
import 'package:smart_classroom_iot/screens/settings_screen.dart';
import 'package:smart_classroom_iot/services/mqtt_service.dart';
import 'package:smart_classroom_iot/state/auth_state.dart';
import 'package:smart_classroom_iot/state/classroom_state.dart';
import 'package:smart_classroom_iot/theme/app_colors.dart';
import 'package:smart_classroom_iot/theme/app_theme.dart';

final String? _shotDir = Platform.environment['SCREENSHOT_DIR'];
final GlobalKey _boundaryKey = GlobalKey();

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final path in paths) {
    final bytes = File(path).readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

Future<void> _loadAppFonts() async {
  await _loadFont('Inter', [
    'assets/fonts/Inter-Regular.ttf',
    'assets/fonts/Inter-Medium.ttf',
    'assets/fonts/Inter-SemiBold.ttf',
    'assets/fonts/Inter-Bold.ttf',
    'assets/fonts/Inter-ExtraBold.ttf',
  ]);
  await _loadFont('SpaceGrotesk', [
    'assets/fonts/SpaceGrotesk-Medium.ttf',
    'assets/fonts/SpaceGrotesk-SemiBold.ttf',
    'assets/fonts/SpaceGrotesk-Bold.ttf',
  ]);

  // Icons, so screenshots show glyphs rather than placeholder boxes.
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    final icons = File(
      '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    if (icons.existsSync()) {
      await _loadFont('MaterialIcons', [icons.path]);
    }
  }
}

Widget _host(Widget screen, Brightness brightness) {
  AppColors.apply(brightness);
  return RepaintBoundary(
    key: _boundaryKey,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: brightness == Brightness.dark
          ? AppTheme.darkTheme
          : AppTheme.lightTheme,
      home: screen,
    ),
  );
}

Future<void> _snapshot(WidgetTester tester, String name) async {
  final dir = _shotDir;
  if (dir == null || dir.isEmpty) return;
  final boundary =
      _boundaryKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2.0);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    Directory(dir).createSync(recursive: true);
    File('$dir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

typedef _ScreenBuilder = Widget Function();

void main() {
  late ClassroomState state;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    // Never let a test reach the real broker: classroom hardware listens on
    // the production topics.
    MqttService().configure(broker: '127.0.0.1', port: 9);
    await _loadAppFonts();

    state = ClassroomState();
    state.loadDemoData();
    await AuthState().setUserRole(UserRole.admin);

    // Give the demo campus some life so "on" states are exercised too.
    for (final room in state.classrooms) {
      room.currentOccupancy = 12;
      room.frontOccupancy = 7;
      room.backOccupancy = 5;
      room.isOccupied = true;
      var i = 0;
      for (final device in room.devices) {
        device.isOn = i.isEven;
        if (device.type == DeviceType.fan && device.isOn) device.fanSpeed = 3;
        if (device.type == DeviceType.lighting && device.isOn) {
          device.brightness = 70;
        }
        i++;
      }
    }
  });

  tearDown(() {
    state.cancelAllTimers();
  });

  Classroom hvacRoom() => state.classrooms
      .firstWhere((r) => r.devices.any((d) => d.type == DeviceType.hvac));
  ClassroomDevice deviceOf(DeviceType type) =>
      hvacRoom().devices.firstWhere((d) => d.type == type);

  final screens = <String, _ScreenBuilder>{
    'dashboard': () => const DashboardScreen(),
    'room_control': () => RoomControlScreen(roomId: hvacRoom().id),
    'device_fan': () => DeviceDetailScreen(
          roomId: hvacRoom().id,
          deviceId: deviceOf(DeviceType.fan).id,
        ),
    'device_light': () => DeviceDetailScreen(
          roomId: hvacRoom().id,
          deviceId: deviceOf(DeviceType.lighting).id,
        ),
    'device_ac': () => DeviceDetailScreen(
          roomId: hvacRoom().id,
          deviceId: deviceOf(DeviceType.hvac).id,
        ),
    'settings': () => const SettingsScreen(),
    'add_classroom': () => const AddClassroomScreen(),
    'add_device': () => AddDeviceScreen(preselectedRoomId: hvacRoom().id),
    'auth': () => const AuthScreen(),
  };

  // Narrow, common and large phones.
  const widths = <double>[320, 360, 412];

  for (final brightness in Brightness.values) {
    for (final entry in screens.entries) {
      for (final width in widths) {
        final label = '${entry.key}_${brightness.name}_${width.toInt()}';

        testWidgets('lays out cleanly: $label', (tester) async {
          debugDisableShadows = false;
          tester.view.devicePixelRatio = 1.0;
          // Tall enough that long pages render in full, so nothing below
          // the fold escapes the check.
          tester.view.physicalSize = Size(width, 2600);
          addTearDown(tester.view.reset);

          final problems = <String>[];
          final previous = FlutterError.onError;
          FlutterError.onError = (details) {
            // Keep the headline plus the source location of the widget
            // that caused it, which is what you need to go and fix it.
            final where = RegExp(r'lib/[\w/]+\.dart:\d+:\d+')
                .firstMatch(details.toString())
                ?.group(0);
            final headline = details.exceptionAsString().split('\n').first;
            problems.add(where == null ? headline : '$headline ($where)');
          };

          await tester.pumpWidget(_host(entry.value(), brightness));
          await tester.pump(const Duration(milliseconds: 900));
          await tester.pump(const Duration(milliseconds: 900));

          FlutterError.onError = previous;

          await _snapshot(tester, label);

          // Screens that query hardware on open kick off a broker connection
          // attempt; cancel its retry timer so it does not outlive the test.
          MqttService().disconnect();

          // Unmount before the test ends so repeating animations stop.
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 50));
          // The framework checks this is back to its default before the
          // test body returns.
          debugDisableShadows = true;

          expect(problems, isEmpty, reason: 'Layout problems in $label');
        });
      }
    }

    // Also exercise AddDeviceScreen in Standalone Dual-AC mode (`isAddingAC = true`)
    // and Single Pair mode across narrow and wide phones.
    for (final width in widths) {
      for (final mode in ['single_pair', 'standalone_ac']) {
        final label = 'add_device_${mode}_${brightness.name}_${width.toInt()}';
        testWidgets('lays out cleanly: $label', (tester) async {
          debugDisableShadows = false;
          tester.view.devicePixelRatio = 1.0;
          tester.view.physicalSize = Size(width, 2600);
          addTearDown(tester.view.reset);

          final problems = <String>[];
          final previous = FlutterError.onError;
          FlutterError.onError = (details) {
            final where = RegExp(r'lib/[\w/]+\.dart:\d+:\d+')
                .firstMatch(details.toString())
                ?.group(0);
            final headline = details.exceptionAsString().split('\n').first;
            problems.add(where == null ? headline : '$headline ($where)');
          };
          addTearDown(() => FlutterError.onError = previous);

          await tester.pumpWidget(
            _host(AddDeviceScreen(preselectedRoomId: hvacRoom().id), brightness),
          );
          await tester.pump(const Duration(milliseconds: 900));
          await tester.pump(const Duration(milliseconds: 900));

          if (mode == 'single_pair') {
            await tester.tap(find.text('Single Device'));
          } else {
            await tester.tap(find.text('Standalone AC').first);
          }
          await tester.pump(const Duration(milliseconds: 500));

          FlutterError.onError = previous;

          await _snapshot(tester, label);
          MqttService().disconnect();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 50));
          debugDisableShadows = true;

          expect(problems, isEmpty, reason: 'Layout problems in $label');
        });
      }
    }
  }
}
