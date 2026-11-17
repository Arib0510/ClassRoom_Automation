import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'screens/splash_screen.dart';
import 'services/mqtt_service.dart';
import 'theme/app_colors.dart';
import 'theme/app_theme.dart';
import 'theme/theme_controller.dart';
import 'widgets/theme_reveal.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Load environment variables securely from .env file (zero hardcoded secrets)
  try {
    await dotenv.load(fileName: ".env");
  } catch (e) {
    debugPrint('.env load notice: $e');
  }

  // Initialize Firebase using .env configuration
  try {
    final apiKey = dotenv.env['FIREBASE_API_KEY'];
    final appId = dotenv.env['FIREBASE_APP_ID'];
    final messagingSenderId = dotenv.env['FIREBASE_MESSAGING_SENDER_ID'];
    final projectId = dotenv.env['FIREBASE_PROJECT_ID'];
    final storageBucket = dotenv.env['FIREBASE_STORAGE_BUCKET'];

    if (apiKey != null && appId != null && projectId != null) {
      await Firebase.initializeApp(
        options: FirebaseOptions(
          apiKey: apiKey,
          appId: appId,
          messagingSenderId: messagingSenderId ?? '',
          projectId: projectId,
          storageBucket: storageBucket,
        ),
      );
    } else {
      await Firebase.initializeApp();
    }
  } catch (e) {
    debugPrint('Firebase initialization: $e');
  }

  // Restore the saved appearance (system / light / dark) before the first
  // frame so the app never flashes the wrong theme.
  await ThemeController().load();

  runApp(const ClassPulseApp());
}

class ClassPulseApp extends StatefulWidget {
  const ClassPulseApp({super.key});

  @override
  State<ClassPulseApp> createState() => _ClassPulseAppState();
}

class _ClassPulseAppState extends State<ClassPulseApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Re-verify MQTT socket & subscriptions when returning from background/Wi-Fi switch.
      MqttService().ensureConnectedAndSync();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ThemeController();
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        // Keep the colour roles in step with the theme Material resolves.
        AppColors.apply(controller.effectiveBrightness);
        return MaterialApp(
          title: 'ClassPulse IoT',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: controller.mode,
          // The switch is animated by ThemeReveal; a second cross-fade
          // underneath it would only muddy the wipe.
          themeAnimationDuration: Duration.zero,
          builder: (context, child) =>
              ThemeReveal(child: child ?? const SizedBox.shrink()),
          home: const SplashScreen(),
        );
      },
    );
  }
}
